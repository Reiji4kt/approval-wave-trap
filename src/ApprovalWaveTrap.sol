// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// ApprovalWave Trap (Drosera-compatible)
/// - reportApproval() for off-chain watchers
/// - collect() returns encoded payload including current block
/// - shouldRespond(bytes[] calldata) is PURE and uses only the decoded payload
contract ApprovalTrap {
    uint256 public constant THRESHOLD = 5;
    uint256 public constant WINDOW_BLOCKS = 10;

    // Uniswap V3 Router (mainnet) - compile-time constant allowed in pure fn
    address public constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;
    mapping(address => bool) public trustedSpender; // optional owner-managed whitelist

    // evidence storage per origin
    mapping(address => uint256[]) internal approvalBlocks;
    mapping(address => bytes32[]) internal approvalTxHashes;

    // tracked origins
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

    constructor() {
        owner = msg.sender;
    }

    function setTrustedSpender(address spender, bool trusted) external onlyOwner {
        trustedSpender[spender] = trusted;
    }

    /// @notice Report observed Approval logs (off-chain watchers call this)
    function reportApproval(
        address token,
        address origin,
        address spender,
        bytes32 txHash
    ) external {
        emit ApprovalObserved(token, origin, spender, txHash, block.number, msg.sender);

        // track origin
        if (!originTracked[origin]) {
            originTracked[origin] = true;
            trackedOrigins.push(origin);
        }

        // always persist evidence (we prune older blocks later)
        approvalBlocks[origin].push(block.number);
        approvalTxHashes[origin].push(txHash);

        _pruneOld(origin);

        // emit immediate event if wave meets threshold and spender not whitelisted (best-effort)
        uint256 cnt = countApprovalsInWindow(origin);
        if (cnt >= THRESHOLD && spender != UNISWAP_V3_ROUTER && !trustedSpender[spender]) {
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

    /// @notice collect() returns a single encoded payload with everything shouldRespond needs.
    /// Format: abi.encode(origins, spenders, txs, blks, currentBlock)
    function collect() external view returns (bytes memory) {
        uint256 n = trackedOrigins.length;

        address[] memory origins = new address[](n);
        address[] memory spenders = new address[](n);
        bytes32[][] memory txs = new bytes32[][](n);
        uint256[][] memory blks = new uint256[][](n);

        for (uint256 i = 0; i < n; i++) {
            address org = trackedOrigins[i];
            origins[i] = org;

            // pick a best-effort spender placeholder: last observed tx's spender is not stored,
            // so we use address(0) here. If you want exact spender returned, add lastSpender[origin] storage.
            spenders[i] = address(0);

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

        uint256 currentBlock = block.number;
        return abi.encode(origins, spenders, txs, blks, currentBlock);
    }

    /// @notice shouldRespond MUST BE PURE for Drosera. It decodes the payload only.
    /// Expected input: data[0] == collect() output (encoded as above).
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        if (data.length == 0) return (false, bytes(""));

        (
            address[] memory origins,
            address[] memory spenders,
            bytes32[][] memory txs,
            uint256[][] memory blks,
            uint256 currentBlock
        ) = abi.decode(data[0], (address[], address[], bytes32[][], uint256[][], uint256));

        uint256 minAllowed = currentBlock > WINDOW_BLOCKS ? currentBlock - WINDOW_BLOCKS + 1 : 0;

        for (uint256 i = 0; i < origins.length; i++) {
            uint256 cnt = 0;
            for (uint256 j = 0; j < blks[i].length; j++) {
                if (blks[i][j] >= minAllowed) cnt++;
            }

            if (cnt >= THRESHOLD) {
                address spender = spenders[i];
                // skip Uniswap V3 router if present in payload
                if (spender == UNISWAP_V3_ROUTER) {
                    continue;
                }
                // prepare deterministic quote from the evidence
                bytes32 quote = keccak256(abi.encodePacked(origins[i], spender, cnt, currentBlock, txs[i], blks[i]));
                return (true, abi.encode(quote));
            }
        }
        return (false, bytes(""));
    }

    // getter used by tests/off-chain
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
