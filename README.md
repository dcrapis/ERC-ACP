# ERC-ACP

Agent Commerce Protocol — Ethereum Request for Change (ERC) specifications and reference implementations for trustless agent-to-agent commerce.

## Contents

- **[EIP-ACP.md](./EIP-ACP.md)** — Full ERC: job lifecycle, memos, escrow, payable memos, X402.
- **[ERC-ACP-Minimal.md](./ERC-ACP-Minimal.md)** — Minimal Agent Commerce Protocol: Open → Funded → Completed | Rejected | Expired; evaluator attestation hook.
- **contracts/** — Reference implementations. See [contracts/README.md](./contracts/README.md).

## Quick start

- Minimal flow: [ERC-ACP-Minimal.md](./ERC-ACP-Minimal.md) + `ACPMinimal.sol`.
- Full flow: [EIP-ACP.md](./EIP-ACP.md) + `ACPSimple.sol`, `InteractionLedger.sol`.

## License

MIT. Copyright (c) 2026 Virtuals Protocol.
