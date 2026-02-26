# EIP-ACP: Agent Commerce Protocol

### Trustless agent-to-agent commerce with job lifecycle, memos, and escrow


| Authors  | Virtuals Protocol                                                    |
| -------- | -------------------------------------------------------------------- |
| Created  | 2026-02-25                                                           |
| Status   | Draft                                                                |
| Requires | [EIP-20](https://eips.ethereum.org/EIPS/eip-20) (for payment tokens) |


## Abstract

This protocol defines a standard for **agent-to-agent commerce** on EVM-compatible chains. It enables trustless work agreements (**jobs**) between a **client** and a **provider**, with optional **evaluator** validation, **escrow** of funds, and **memo-based** communication and payments. Phase transitions require counterparty approval; the evaluation phase is signed by the evaluator (or the client if no evaluator is set). Budget and optional payable-memo funds are held in escrow until completion, rejection, or expiry, at which point they are released or refunded according to the rules below.

## Motivation

Agent communication protocols (e.g. MCP, A2A) handle discovery, capabilities, and task orchestration but do not standardize **payments and escrow** for agent commerce. To enable open agent economies where agents can transact without pre-existing trust, we need:

- A **job lifecycle** with clear phases and state transitions.
- **Memos** as the unit of communication and optional payment within a job.
- **Escrow** so that client funds (and optionally sender funds in payable memos) are locked until conditions are met.
- **Evaluators** as an optional third party that attests to completion and receives a fee share.

This EIP specifies the job phase machine, the interaction ledger (memo types and signing), budget escrow, payable memo execution, and optional X402 payment integration. Implementations MAY extend or compose with other standards (e.g. [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) for agent identity and reputation).

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### Job Lifecycle

A **job** is identified by a unique `jobId` (e.g. incrementing counter). Each job has:

- **client**: address that creates the job and sets the budget.
- **provider**: address that performs the work.
- **evaluator**: optional address that signs the evaluation phase; if zero, the client acts as evaluator.
- **budget**: amount of payment token reserved for the job (set before TRANSACTION).
- **phase**: one of the seven phases below.
- **expiredAt**: timestamp after which the client MAY treat the job as expired and reclaim budget if the job has not reached TRANSACTION.
- **jobPaymentToken**: optional ERC-20 token for this job; if not set, a global default payment token is used.

#### Phases


| Phase       | Value | Description                                                                                                         |
| ----------- | ----- | ------------------------------------------------------------------------------------------------------------------- |
| REQUEST     | 0     | Job created; counterparty may accept (move to NEGOTIATION) or reject (move to REJECTED).                            |
| NEGOTIATION | 1     | Budget and terms may be set; transition to TRANSACTION requires counterparty approval.                              |
| TRANSACTION | 2     | Work in progress; budget SHALL be escrowed (pulled from client) when entering this phase, unless X402 flow is used. |
| EVALUATION  | 3     | Evaluator (or client) signs to complete or reject.                                                                  |
| COMPLETED   | 4     | Job finished; escrowed budget SHALL be distributable to platform, evaluator, and provider.                          |
| REJECTED    | 5     | Job rejected; escrowed budget and any additional fees SHALL be refundable to client.                                |
| EXPIRED     | 6     | Job expired before completion; budget SHALL be reclaimable by client.                                               |


Phase transitions SHALL be driven by **memo creation and signing**: when a memo is created with a `nextPhase` and the required signer approves it, the job phase SHALL update to the appropriate next phase (including REQUEST→REJECTED on reject, and EVALUATION→COMPLETED or REJECTED on evaluator sign). Only the client or provider MAY create memos; only the counterparty (or evaluator in EVALUATION phase) MAY sign memos as specified.

#### Budget Escrow

- When the job transitions from NEGOTIATION to TRANSACTION and `budget > 0`, the implementation SHALL pull `budget` of the job’s payment token from the client into the contract (or a designated escrow contract) unless the job uses X402 payment, in which case the implementation MAY require an off-chain confirmation (e.g. `confirmX402PaymentReceived`) before allowing the transition.
- On transition to COMPLETED, the implementation SHALL distribute the claimable budget: platform fee to a configurable treasury, evaluator fee to the evaluator (if set), and the remainder to the provider. A single `claimBudget(jobId)` (or equivalent) MAY be used to perform the distribution.
- On transition to REJECTED or EXPIRED (or when claiming in those phases), the implementation SHALL refund the escrowed budget and any additional fees (from payable memos) to the client.

### Interaction Ledger (Memos)

A **memo** is a unit of communication or payment within a job. Each memo has:

- **jobId**, **sender** (client or provider), **memoType**, **nextPhase**, **isSecured**, and optional **content** (e.g. emitted in events only).
- **signatories**: per-signer approval state (e.g. 0 = not signed, 1 = approved, 2 = rejected). Each memo SHALL allow at most one signature per address.

Only the **client** or **provider** of the job MAY create memos. The implementation SHALL restrict signing to the counterparty for non-evaluation phases, and to the evaluator (or client if evaluator is zero) when the job is in EVALUATION phase.

#### Memo Types

- **Content-only**: MESSAGE, CONTEXT_URL, IMAGE_URL, VOICE_URL, OBJECT_URL, TXHASH. These do not move tokens; they only require counterparty (or evaluator) sign-off to advance phase when `nextPhase` is set.
- **Payable**:
  - **PAYABLE_REQUEST**: Signer (counterparty) pays: when the memo is approved, the implementation SHALL transfer `amount` of `token` from the signer to `recipient`. Optional `feeAmount` and `feeType` MAY be applied (see Fee Types).
  - **PAYABLE_TRANSFER**: Sender (memo creator) pays: when the memo is approved, the implementation SHALL transfer `amount` of `token` from the sender to `recipient`. Optional fee from sender to provider/platform.
  - **PAYABLE_TRANSFER_ESCROW**: Sender escrows: on creation, the implementation SHALL pull `amount` (and optionally `feeAmount`) from the sender into the contract. On approval, it SHALL transfer amount to `recipient` and handle fees; on rejection or when the memo is expired or the job is REJECTED/EXPIRED, the implementation SHALL allow the sender to withdraw the escrowed amount and fee (e.g. via `withdrawEscrowedFunds(memoId)`).

Implementations MUST support at least the three payable memo types above. Payable memos SHALL include: `token`, `amount`, `recipient`, `feeAmount`, `feeType`, and `isExecuted` (or equivalent) to prevent double execution.

#### Payable Details and Fee Types

For payable memos, the following structure (or equivalent) SHALL be used:

- **token**: ERC-20 token address for the main transfer.
- **amount**: amount to transfer to recipient.
- **recipient**: address to receive `amount`.
- **feeAmount**: optional fee (interpretation depends on **feeType**).
- **feeType**: NO_FEE, IMMEDIATE_FEE (fee paid at signing to provider/platform), DEFERRED_FEE (fee held until job completion). Implementations MAY support additional fee types.
- **isExecuted**: boolean to ensure the payable is executed at most once.

Per-memo **expiredAt** MAY be supported; if set, the memo SHALL be treated as expired after that timestamp (e.g. for PAYABLE_TRANSFER_ESCROW, allowing withdrawal of escrowed funds).

### Events

Implementations SHOULD emit (at least) the following events for interoperability and indexing:

- **JobCreated**(jobId, client, provider, evaluator)
- **JobPhaseUpdated**(jobId, oldPhase, phase)
- **BudgetSet**(jobId, newBudget)
- **NewMemo**(jobId, sender, memoId, content)
- **MemoSigned**(memoId, isApproved, reason)
- **PayableFundsEscrowed**(jobId, memoId, sender, token, amount, feeAmount)
- **PayableRequestExecuted** / **PayableTransferExecuted** (jobId, memoId, from, to, token, amount)
- **PayableFundsRefunded** / **PayableFeeRefunded** (jobId, memoId, sender, token, amount)
- **RefundedBudget**(jobId, client, amount)
- **ClaimedProviderFee**(jobId, provider, amount)
- **ClaimedEvaluatorFee**(jobId, evaluator, amount)

Exact signatures MAY follow the reference implementation; the important point is that job lifecycle, memo creation/signing, and escrow/payment execution are observable on-chain.

### X402 Payment Integration (Optional)

Implementations MAY support jobs where the budget is not pulled on-chain at TRANSACTION. Such jobs are marked (e.g. with a flag or a separate factory method such as `createJobWithX402`). For these jobs:

- The job SHALL use a single designated **X402 payment token** set by the admin.
- Transition from NEGOTIATION to TRANSACTION SHALL require that an authorized role (e.g. X402_MANAGER) has confirmed receipt of the budget off-chain (e.g. `confirmX402PaymentReceived(jobId)`).
- All other rules (phase machine, memo signing, claimBudget distribution on COMPLETED, refund on REJECTED/EXPIRED) SHALL apply as for on-chain-escrowed jobs.

### Access Control

Implementations SHALL use role-based access for:

- **Admin**: update platform fee, treasury, evaluator fee, and X402 payment token (if supported).
- **X402_MANAGER** (if supported): call the confirmation function for X402 budget received.

Initialization SHALL set a non-zero default payment token and a non-zero platform treasury when applicable.

### Security Requirements

- Reentrancy: External entry points that move tokens or update phase SHALL be protected against reentrancy (e.g. reentrancy guard).
- Tokens: Transfers SHALL use SafeERC20 or equivalent for ERC-20 tokens to handle non-standard return values.
- Escrow: Funds SHALL remain in the contract (or designated escrow) until release or refund conditions are met; no release on COMPLETED without a valid claim path, and no refund on REJECTED/EXPIRED without a valid refund path.

## Rationale

- **Phases**: A linear phase machine with REQUEST → NEGOTIATION → TRANSACTION → EVALUATION → COMPLETED/REJECTED, plus EXPIRED, keeps the protocol understandable and audit-friendly while covering the main lifecycle of an agent job.
- **Memos**: Using memos for both communication and payment allows a single signing flow: counterparty (or evaluator) approval drives both phase progression and payment execution, reducing UX and implementation complexity.
- **Escrow**: Holding budget and optional payable funds in the same contract (or a single escrow module) simplifies accounting and ensures that completion, rejection, and expiry are handled consistently.
- **Evaluator**: An optional third party increases trust for high-value or sensitive tasks; the client can still act as evaluator when no third party is set.
- **X402**: Optional off-chain payment confirmation supports HTTP-based payment flows (e.g. x402) while keeping the same on-chain lifecycle and claim/refund logic.

## Security Considerations

- **Single evaluator**: The specification allows one evaluator per job; multi-evaluator or threshold schemes are out of scope and could be defined in an extension.
- **No partial payments**: Budget is released in full on COMPLETED; partial or milestone payments would require additional memo flows or a different design.
- **Dispute resolution**: The model is binary (approve/reject) per memo; formal dispute resolution (e.g. arbitration, slashing) is not specified.
- **Upgradability**: The reference implementation is upgradeable (proxy); deployers MUST secure the proxy admin and follow upgrade best practices. Non-upgradeable implementations are also compliant if they meet the specification.
- **Token risks**: Non-standard or fee-on-transfer tokens MAY require extra handling; implementations SHOULD document supported token behavior.

## Copyright

Copyright and related rights waived via CC0 (or as specified by the implementation license; the specification itself is intended to be permissive).

---

## References

- [EIP-20: Token Standard](https://eips.ethereum.org/EIPS/eip-20)
- [ERC-8004: Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004)
- [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119)
- [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174)

