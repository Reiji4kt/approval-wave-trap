// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract ApprovalTrap {
    uint256 public constant THRESHOLD = 5;
    uint256 public constant WINDOW_BLOCKS = 10;

    // Uniswap V3 Router (mainnet address) — treated as whitelist in PoC
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;
    mapping(address => bool) public trustedSpender; // extra whitelists
    mapping(address => uint256[]) internal approvalBlocks;
    mapping(address => bytes32[]) internal approvalTxHashes;

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

    /// @notice Report an observed approve() call
    function reportApproval(
        address token,
        address origin,
        address spender,
        bytes32 txHash
    ) external {
        emit ApprovalObserved(token, origin, spender, txHash, block.number, msg.sender);

        // ignore whitelisted spenders
        if (spender == UNISWAP_V3_ROUTER || trustedSpender[spender]) {
            return;
        }

        approvalBlocks[origin].push(block.number);
        approvalTxHashes[origin].push(txHash);

        _pruneOld(origin);

        uint256 cnt = approvalBlocks[origin].length;
        if (cnt >= THRESHOLD) {
            uint256 len = approvalBlocks[origin].length;
            bytes32[] memory evidenceHashes = new bytes32[](len);
            uint256[] memory evidenceBlocks = new uint256[](len);

            for (uint256 i = 0; i < len; i++) {
                evidenceHashes[i] = approvalTxHashes[origin][i];
                evidenceBlocks[i] = approvalBlocks[origin][i];
            }

            // deterministic quote (support citation)
            bytes32 quote = keccak256(
                abi.encodePacked(origin, spender, cnt, block.number, evidenceHashes, evidenceBlocks, block.timestamp)
            );

            emit ApprovalWaveAlert(origin, spender, cnt, quote, evidenceHashes, evidenceBlocks);
        }
    }

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
