// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// ApprovalWave Trap (updated)
/// - keeps reportApproval(...) for off-chain reporters
/// - adds collect() and shouldRespond(bytes[] calldata) expected by Drosera CLI
contract ApprovalTrap {
    uint256 public constant THRESHOLD = 5;
    uint256 public constant WINDOW_BLOCKS = 10;

    address public constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;
    mapping(address => bool) public trustedSpender; // extra whitelists

    // evidence storage per origin
    mapping(address => uint256[]) internal approvalBlocks;
    mapping(address => bytes32[]) internal approvalTxHashes;

    // track origins seen so collect() can iterate
    address[] internal trackedOrigins;
    mapping(address => bool) internal originTracked;

    event ApprovalObserved(
        address indexed token,
        address indexed origin,
        address indexed spender,
        bytes32 txHash,
        uint256 blockNumber,
        address reporter
    );

    event ApprovalWaveAlert(
        address indexed origin,
        address indexed spender,
        uint256 count,
        bytes32 quote,
        bytes32[] evidenceTxHashes,
        uint256[] evidenceBlocks
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // no constructor args — set deployer as owner
    constructor() {
        owner = msg.sender;
    }

    function setTrustedSpender(address spender, bool trusted) external onlyOwner {
        trustedSpender[spender] = trusted;
    }

    /// @notice report observed Approval logs (off-chain watchers call this)
    function reportApproval(
        address token,
        address origin,
        address spender,
        bytes32 txHash
    ) external {
        emit ApprovalObserved(token, origin, spender, txHash, block.number, msg.sender);

        // record origin for collect() iteration
        if (!originTracked[origin]) {
            originTracked[origin] = true;
            trackedOrigins.push(origin);
        }

        // ignore whitelisted spenders (persist evidence though)
        approvalBlocks[origin].push(block.number);
        approvalTxHashes[origin].push(txHash);

        _pruneOld(origin);

        uint256 cnt = countApprovalsInWindow(origin);
        if (cnt >= THRESHOLD && spender != UNISWAP_V3_ROUTER && !trustedSpender[spender]) {
            // prepare evidence arrays to emit in the event
            uint256 len = approvalBlocks[origin].length;
            bytes32[] memory evidenceHashes = new bytes32[](len);
            uint256[] memory evidenceBlocks = new uint256[](len);

            for (uint256 i = 0; i < len; i++) {
                evidenceHashes[i] = approvalTxHashes[origin][i];
                evidenceBlocks[i] = approvalBlocks[origin][i];
            }

            bytes32 quote = keccak256(
                abi.encodePacked(origin, spender, cnt, block.number, evidenceHashes, evidenceBlocks, block.timestamp)
            );

            emit ApprovalWaveAlert(origin, spender, cnt, quote, evidenceHashes, evidenceBlocks);
        }
    }

    /// @notice collect() is called by Drosera CLI/operator. It must be view and return bytes.
    /// We encode arrays of origins, spenders (we return placeholder spender = address(0) here),
    /// and a nested arrays of evidenceTxHashes and evidenceBlocks for each origin. The response
    /// `shouldRespond` will decode this and apply policy.
    function collect() external view returns (bytes memory) {
        uint256 n = trackedOrigins.length;

        address[] memory origins = new address[](n);
        address[] memory spenders = new address[](n); // in this PoC we return address(0) as spender placeholder
        bytes32[][] memory txs = new bytes32[][](n);
        uint256[][] memory blks = new uint256[][](n);

        for (uint256 i = 0; i < n; i++) {
            address org = trackedOrigins[i];
            origins[i] = org;
            spenders[i] = address(0); // collectors don't always know a single spender; reporter included it in events
            uint256 len = approvalBlocks[org].length;
            bytes32[] memory h = new bytes32[](len);
            uint256[] memory b = new uint256[](len);
            for (uint256 j = 0; j < len; j++) {
                h[j] = approvalTxHashes[org][j];
                b[j] = approvalBlocks[org][j];
            }
            txs[i] = h;
            blks[i] = b;
        }

        // encode everything as a single bytes payload; CLI will pass it into shouldRespond as data[0]
        return abi.encode(origins, spenders, txs, blks);
    }

    /// @notice shouldRespond is called with array of bytes (the collected payloads).
    /// We decode and check each (origin, spender placeholder, txs, blocks) for threshold >=5 in WINDOW.
    /// Return (true, abi.encode(quote)) when triggered; else (false, bytes("")).
    function shouldRespond(bytes[] calldata data) external view returns (bool, bytes memory) {
        if (data.length == 0) return (false, bytes(""));

        // For our PoC we expect data[0] to be the payload produced by collect()
        (address[] memory origins, address[] memory spenders, bytes32[][] memory txs, uint256[][] memory blks) =
            abi.decode(data[0], (address[], address[], bytes32[][], uint256[][]));

        uint256 minAllowed = block.number > WINDOW_BLOCKS ? block.number - WINDOW_BLOCKS + 1 : 0;

        for (uint256 i = 0; i < origins.length; i++) {
            address origin = origins[i];
            address spender = spenders[i]; // might be zero; but we'll ignore spender==UNISWAP check below conservatively
            uint256 cnt = 0;

            for (uint256 j = 0; j < blks[i].length; j++) {
                if (blks[i][j] >= minAllowed) cnt++;
            }

            if (cnt >= THRESHOLD) {
                // If any evidence exists and spender is not whitelisted -> respond
                // Because collect() may not include spender in PoC, we conservatively allow respond if txs exist.
                // But we still check trustedSpender/UNISWAP if spender is populated.
                if (spender == UNISWAP_V3_ROUTER || trustedSpender[spender]) {
                    continue;
                }

                bytes32 quote = keccak256(abi.encodePacked(origin, spender, cnt, block.number, txs[i], blks[i]));
                return (true, abi.encode(quote));
            }
        }

        return (false, bytes(""));
    }

    /// @notice retrieve raw evidence for an origin (unchanged)
    function getApprovalEvidence(address origin) external view returns (uint256[] memory, bytes32[] memory) {
        return (approvalBlocks[origin], approvalTxHashes[origin]);
    }

    function countApprovalsInWindow(address origin) public view returns (uint256) {
        uint256[] storage arr = approvalBlocks[origin];
        if (arr.length == 0) return 0;
        uint256 minAllowed = block.number > WINDOW_BLOCKS ? block.number - WINDOW_BLOCKS + 1 : 0;
        uint256 c = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] >= minAllowed) c++;
        }
        return c;
    }

    function _pruneOld(address origin) internal {
        uint256 len = approvalBlocks[origin].length;
        if (len == 0) return;
        uint256 minAllowed = block.number > WINDOW_BLOCKS ? block.number - WINDOW_BLOCKS + 1 : 0;
        uint256 keepFrom = 0;
        while (keepFrom < len && approvalBlocks[origin][keepFrom] < minAllowed) {
            keepFrom++;
        }
        if (keepFrom == 0) return;
        uint256 newLen = len - keepFrom;
        for (uint256 i = 0; i < newLen; i++) {
            approvalBlocks[origin][i] = approvalBlocks[origin][i + keepFrom];
            approvalTxHashes[origin][i] = approvalTxHashes[origin][i + keepFrom];
        }
        for (uint256 i = 0; i < keepFrom; i++) {
            approvalBlocks[origin].pop();
            approvalTxHashes[origin].pop();
        }
    }
}
