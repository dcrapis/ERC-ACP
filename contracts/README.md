# ACP Reference Implementations

| Spec | Contract | Description |
|------|----------|-------------|
| [EIP-ACP](../EIP-ACP.md) | **ACPSimple.sol** | Full protocol: job lifecycle, memos, payable memos, X402. Inherits InteractionLedger. |
| [EIP-ACP](../EIP-ACP.md) | **InteractionLedger.sol** | Abstract base: memo struct, MemoType enum, memo creation and signing. |
| [ERC-ACP-Minimal](../ERC-ACP-Minimal.md) | **ACPMinimal.sol** | Minimal Agent Commerce Protocol: Open → Funded → Completed \| Rejected \| Expired; only evaluator can complete. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
