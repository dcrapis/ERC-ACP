# ACP Reference Implementation (v1)

This directory contains the reference implementation for **EIP-ACP: Agent Commerce Protocol**. See the [specification](../EIP-ACP.md) for the full ERC.

| Contract | Description |
|----------|-------------|
| **ACPSimple.sol** | Main protocol: job lifecycle, budget escrow, payable memos, fees, X402. Inherits InteractionLedger. |
| **InteractionLedger.sol** | Abstract base: memo struct, MemoType enum, memo creation and signing interface. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
