// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/// ApprovalWave trap that produces response bytes matching emitApprovalAlert(address,address,bytes32)
contract ApprovalTrap is ITrap {
    uint256 public constant THRESHOLD = 5;
    uint256 public constant WINDOW_BLOCKS = 10;

    /// Hardcoded response contract
    address public constant RESPONSE_CONTRACT = 0xF184E255aCeD3eEa94acEdC233144e65863d1dcc;

    // Track approvals per origin
    mapping(address => bytes32[]) internal approvalTxs;
    mapping(address => uint256[]) internal approvalBlocks;
    mapping(address => address[]) internal approvalSpenders; // stores actual spender for each approval

    // Keep list of origins that have recorded approvals (for collect())
    address[] internal trackedOrigins;
    mapping(address => bool) internal originTracked;

    // Events left for off-chain observability
    event ApprovalObserved(address indexed origin, address indexed spender, bytes32 txHash, uint256 blockNumber);

    // record an observed approval (called by off-chain reporters)
    function reportApproval(address origin, address spender, bytes32 txHash) external {
        // record origin if new
        if (!originTracked[origin]) {
            originTracked[origin] = true;
            trackedOrigins.push(origin);
        }

        approvalTxs[origin].push(txHash);
        approvalBlocks[origin].push(block.number);
        approvalSpenders[origin].push(spender);

        emit ApprovalObserved(origin, spender, txHash, block.number);
    }

    /// collect() returns all evidence the Drosera node will pass to shouldRespond
    /// ABI-encoded as (address[] origins, address[] spenders, bytes32[][] txs, uint256[][] blks, uint256 currentBlock)
    function collect() external view override returns (bytes memory) {
        uint256 n = trackedOrigins.length;

        address[] memory origins = new address[](n);
        address[] memory spenders = new address[](n);
        bytes32[][] memory txs = new bytes32[][](n);
        uint256[][] memory blks = new uint256[][](n);

        for (uint256 i = 0; i < n; i++) {
            address org = trackedOrigins[i];
            origins[i] = org;

            // choose a representative spender for this origin: last recorded spender (if any)
            uint256 sLen = approvalSpenders[org].length;
            address repSpender = address(0);
            if (sLen > 0) {
                repSpender = approvalSpenders[org][sLen - 1];
            }
            spenders[i] = repSpender;

            // copy tx hashes
            uint256 tLen = approvalTxs[org].length;
            bytes32[] memory h = new bytes32[](tLen);
            uint256[] memory b = new uint256[](tLen);
            for (uint256 j = 0; j < tLen; j++) {
                h[j] = approvalTxs[org][j];
                b[j] = approvalBlocks[org][j];
            }
            txs[i] = h;
            blks[i] = b;
        }

        uint256 currentBlock = block.number;
        return abi.encode(origins, spenders, txs, blks, currentBlock);
    }

    /// shouldRespond must be pure: decode the collected payload and decide using only its contents.
    /// If a threshold is met for any origin, return (true, abi.encode(origin, spender, quote))
    /// where the response bytes exactly match emitApprovalAlert(address,address,bytes32).
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
            // count evidence inside sliding window
            for (uint256 j = 0; j < blks[i].length; j++) {
                if (blks[i][j] >= minAllowed) cnt++;
            }

            if (cnt >= THRESHOLD) {
                // compute deterministic quote only when threshold reached
                bytes32 quote = keccak256(abi.encodePacked(origins[i], spenders[i], cnt, currentBlock, txs[i], blks[i]));
                // Encode exactly (address origin, address spender, bytes32 quote)
                return (true, abi.encode(origins[i], spenders[i], quote));
            }
        }

        return (false, bytes(""));
    }

    // helper getters (view-only) to inspect stored evidence per origin
    function getApprovalEvidence(address origin) external view returns (bytes32[] memory, uint256[] memory, address[] memory) {
        return (approvalTxs[origin], approvalBlocks[origin], approvalSpenders[origin]);
    }
}
