# approval-wave-trap
ApprovalTrap
A Drosera-compatible trap for detecting waves of ERC20 approvals to non-whitelisted spenders.

Logic:

Each reportApproval(origin, spender) logs evidence.

If approvals ≥ THRESHOLD within WINDOW_BLOCKS, trap fires.

Evidence (origins, spenders, txs, blocks) is collected and encoded.

Response contracts or off-chain agents decode and decide action.

Security Notes:

Tracks real spenders (not address(0)).

Whitelists trusted routers (isRouter).

Uses deterministic keccak256 quotes for alerts.

Still vulnerable to batching / revokes (must be handled off-chain).
