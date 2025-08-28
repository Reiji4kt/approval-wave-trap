// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ITrap.sol";

contract ApprovalTrap is ITrap {
    uint256 constant WINDOW_BLOCKS = 100; // sliding window length
    uint256 constant THRESHOLD = 3;       // number of approvals to trigger

    // Drosera Response contract that will be called when the trap fires
    address constant RESPONSE_CONTRACT = 0x676e30a705C53B2a3963009bC7B72629a4d81E96;

    // Track approvals per origin
    mapping(address => bytes32[]) internal approvalTxs;
    mapping(address => uint256[]) internal approvalBlocks;
    mapping(address => address[]) internal approvalSpenders; // store actual spender

    // Record the last spender for each origin
    mapping(address => address) internal lastSpender;

    // === Collect side (called by Drosera node) ===
    function collect() external view override returns (bytes memory) {
        address ;
        address ;
        bytes32 ;
        uint256 ;

        // In production, this should be populated by logging approvals onchain.
        // For PoC, we leave arrays empty (Drosera off-chain node fills them).
        return abi.encode(origins, spenders, txs, blks, block.number);
    }

    // === ShouldRespond side (decision logic) ===
    function shouldRespond(bytes[] calldata data) external pure override returns (bool, bytes memory) {
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
                if (blks[i][j] >= minAllowed) {
                    cnt++;
                }
            }

            if (cnt >= THRESHOLD) {
                // Hash quote only if threshold met
                bytes32 quote = keccak256(
                    abi.encodePacked(origins[i], spenders[i], cnt, currentBlock, txs[i], blks[i])
                );

                return (true, abi.encode(quote));
            }
        }

        return (false, bytes(""));
    }

    // === Example logging function (to be called off-chain or by custom infra) ===
    function reportApproval(address origin, address spender, bytes32 txHash, uint256 blk) external {
        approvalTxs[origin].push(txHash);
        approvalBlocks[origin].push(blk);
        approvalSpenders[origin].push(spender);
        lastSpender[origin] = spender;
    }
}
