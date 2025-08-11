// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract ApprovalResponse {
    uint256 public constant THRESHOLD = 5;
    uint256 public constant WINDOW_BLOCKS = 10;
    address public owner;

    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    mapping(address => bool) public trustedSpender;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    function setTrustedSpender(address spender, bool trusted) external onlyOwner {
        trustedSpender[spender] = trusted;
    }

    /// @notice Evaluate evidence, return (shouldRespond, quote)
    function shouldRespond(
        address origin,
        address spender,
        bytes32[] calldata evidenceTxHashes,
        uint256[] calldata evidenceBlocks
    ) external view returns (bool, bytes32) {
        if (spender == UNISWAP_V3_ROUTER || trustedSpender[spender]) {
            return (false, bytes32(0));
        }
        if (evidenceTxHashes.length != evidenceBlocks.length) {
            return (false, bytes32(0));
        }

        uint256 minAllowed = block.number > WINDOW_BLOCKS ? block.number - WINDOW_BLOCKS + 1 : 0;
        uint256 cnt = 0;
        for (uint256 i = 0; i < evidenceBlocks.length; i++) {
            if (evidenceBlocks[i] >= minAllowed) cnt++;
        }

        bytes32 quote = keccak256(abi.encodePacked(origin, spender, cnt, block.number, evidenceTxHashes, evidenceBlocks));
        return (cnt >= THRESHOLD, quote);
    }
}
