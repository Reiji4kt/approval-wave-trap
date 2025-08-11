// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ApprovalWaveResponse
 * @author Gemini
 * @notice This contract logs suspicious activity detected by the ApprovalWaveTrap.
 * Its `logSuspiciousActivity` function is called by the Drosera network when
 * the corresponding trap is triggered.
 */
contract ApprovalWaveResponse {

    // The address of the Drosera network contract on the Hoodi testnet.
    // This ensures only the Drosera network can call the response function.
    address public constant DROSERA_CONTRACT = 0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D;

    /**
     * @dev An event to create an on-chain log of the suspicious activity.
     * @param owner The address that granted the suspicious approval.
     * @param spender The address of the contract that received the approval.
     * @param detectedAt The timestamp of the detection.
     */
    event SuspiciousApprovalDetected(
        address indexed owner,
        address indexed spender,
        uint256 detectedAt
    );

    // Public state variables to easily verify a successful trap execution.
    address public lastSuspiciousOwner;
    address public lastSuspiciousSpender;
    uint256 public lastDetectionTimestamp;
    uint public detectionCount;

    modifier onlyDrosera() {
        require(msg.sender == DROSERA_CONTRACT, "Caller is not the Drosera network");
        _;
    }

    /**
     * @notice The response function called by Drosera operators.
     * @param owner The address of the EOA that made the suspicious approval.
     * @param spender The address of the contract that received the approval.
     *
     * This function's signature "logSuspiciousActivity(address,address)" must
     * match the one specified in the drosera.toml file.
     */
    function logSuspiciousActivity(address owner, address spender) external onlyDrosera {
        lastSuspiciousOwner = owner;
        lastSuspiciousSpender = spender;
        lastDetectionTimestamp = block.timestamp;
        detectionCount++;

        emit SuspiciousApprovalDetected(owner, spender, block.timestamp);
    }
}
