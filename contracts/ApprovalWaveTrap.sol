// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ApprovalWaveTrap
 * @author Gemini
 * @notice A Drosera trap to detect suspicious, high-value ERC20 approvals.
 *
 * The `check` function is designed to be called by Drosera operators.
 * Operators will monitor ERC20 `Approval` events off-chain and use the event
 * parameters (`owner`, `spender`, `value`) to call this function.
 *
 * The trap is considered "sprung" (returns true) if:
 * 1. The approval value is excessively large (greater than half of a uint255).
 * 2. The spender address is NOT a known, whitelisted contract.
 */
contract ApprovalWaveTrap {

    // A testnet WETH contract. This can be any major ERC20 token you wish to monitor.
    // Hoodi Testnet Wrapped Ether (WETH)
    address public constant TARGET_TOKEN = 0x2424FE754e388b6a32CeC12744A39d51A6e340aA;

    // Uniswap's Universal Router - a common, trusted spender.
    // On mainnet, this is 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD. We use a placeholder for Hoodi.
    // For this PoC, we will use a known address on Hoodi as a stand-in.
    // Example: A known contract from the Hoodi block explorer.
    address public constant WHITELISTED_SPENDER = 0x183D78491555cb69B68d2354F7373cc2632508C7; // Placeholder

    // A very high approval amount, often a sign of a malicious "infinite approve" trick.
    uint256 public constant APPROVAL_THRESHOLD = 0.5 * 1e76; // Approx. type(uint255).max / 2

    /**
     * @notice Checks if a specific approval is suspicious.
     * @param owner The address that granted the approval.
     * @param spender The address that received the approval.
     * @return a boolean indicating if the trap condition is met.
     *
     * Note: This function relies on the *current* on-chain allowance, which reflects
     * the state set by the `Approval` event the operator just witnessed.
     */
    function check(address owner, address spender) external view returns (bool) {
        // Condition 1: The spender must not be a known-good contract.
        if (spender == WHITELISTED_SPENDER) {
            return false;
        }

        // Condition 2: The allowance granted must exceed the defined threshold.
        uint256 currentAllowance = IERC20(TARGET_TOKEN).allowance(owner, spender);
        if (currentAllowance > APPROVAL_THRESHOLD) {
            return true;
        }

        return false;
    }
}
