# ERC-XXXX: Minimal Agent Commerce Protocol

### Job escrow with evaluator attestation


| Authors  | XXXX                                                                 |
| -------- | -------------------------------------------------------------------- |
| Created  | 2026-02-25                                                           |
| Status   | Draft                                                                |
| Requires | [EIP-20](https://eips.ethereum.org/EIPS/eip-20) (for payment tokens) |


## Abstract

This specification defines the **Minimal Agent Commerce Protocol**: a **job** with escrowed budget, four states (Open → Funded → Submitted → Terminal), and an **evaluator** who alone may mark the job completed. The client funds the job; the provider submits work; the evaluator attests completion or rejection once submitted (or the evaluator rejects while Funded before submission, or the client rejects while Open, or the job expires and the client is refunded). Optional attestation **reason** (e.g. hash) on complete/reject enables audit and composition with reputation (e.g. [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004)).

## Motivation

Many use cases need only: client locks funds, provider submits work, one attester (evaluator) signals “done” and triggers payment—or client rejects or timeout triggers refund. The Minimal Agent Commerce Protocol specifies that minimal surface so implementations stay small and composable. The evaluator can be the client (e.g. `evaluator = client` at creation) when there is no third-party attester.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### State Machine

A **job** has exactly one of five states:


| State         | Meaning                                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| **Open**      | Created; budget not yet set or not yet funded. Client may set budget, then fund or reject.                            |
| **Funded**    | Budget escrowed. Provider may submit work; evaluator may reject. After `expiredAt`, anyone may trigger refund.        |
| **Submitted** | Provider has submitted work. Only evaluator may complete or reject. After `expiredAt`, anyone may trigger refund.     |
| **Completed** | Terminal. Escrow released to provider (minus optional platform fee).                                                |
| **Rejected**  | Terminal. Escrow refunded to client.                                                                                |
| **Expired**   | Terminal. Same as Rejected; escrow refunded to client.                                                              |


Allowed transitions:

- **Open → Funded**: Client calls `setBudget(jobId, amount)` then `fund(jobId)`; contract pulls `job.budget` from client into escrow.
- **Open → Rejected**: Client calls `reject(jobId, reason?)`.
- **Funded → Submitted**: Provider calls `submit(jobId, deliverable)`; signals that work has been completed and is ready for evaluation.
- **Funded → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Funded → Expired**: When `block.timestamp >= job.expiredAt`, anyone (or client) may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.
- **Submitted → Completed**: Evaluator calls `complete(jobId, reason?)`; contract distributes escrow to provider (and optional fee to treasury).
- **Submitted → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Submitted → Expired**: When `block.timestamp >= job.expiredAt`, anyone (or client) may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.

No other transitions are valid.

### Roles

- **Client**: Creates job (with optional description), may set provider via `setProvider(jobId, provider)` when job was created with no provider, sets budget with `setBudget(jobId, amount)`, funds escrow with `fund(jobId)`, may reject **only when status is Open**. Receives refund on Rejected/Expired.
- **Provider**: Set at creation or later via `setProvider`. May call `acceptJob(jobId)` when job is Funded to signal they have taken the job. Calls `submit(jobId, deliverable)` when work is done to move the job from Funded to Submitted for evaluation. Receives payment when job is Completed. Does not call `complete` or `reject`.
- **Evaluator**: Single address per job, set at creation. When status is Submitted, **only** the evaluator MAY call `complete(jobId, reason?)` or `reject(jobId, reason?)`. When status is Funded, the evaluator MAY call `reject(jobId, reason?)` (before submission). MAY be the client (e.g. `evaluator = client`) so the client can complete or reject the job without a third party.

### Job Data

Each job SHALL have at least:

- `client`, `provider`, `evaluator` (addresses). **Provider MAY be zero at creation** (see Optional provider below).
- `description` (string) — set at creation (e.g. job brief, scope reference).
- `budget` (uint256)
- `expiredAt` (uint256 timestamp)
- `status` (Open | Funded | Submitted | Completed | Rejected | Expired)
- `accepted` (boolean) — set when the provider has signaled they have taken the job (see Provider acceptance below).

Payment SHALL use a single ERC-20 token (global for the contract or specified at creation). Implementations MAY support a per-job token; the specification only requires one token per contract.

### Optional provider (set later)

Jobs MAY be created **without a provider** by passing `provider = address(0)` to `createJob`. In that case the client SHALL set the provider later via `setProvider(jobId, provider)` before funding. This supports flows such as auctions or assignment after creation.

- **setProvider(jobId, provider)**  
  Called by **client** only. SHALL revert if job is not Open, current `job.provider != address(0)`, or `provider == address(0)`. SHALL set `job.provider = provider` and SHALL emit an event (e.g. ProviderSet). Implementations MAY allow an operator role to call setProvider in the future; this specification only requires client-only for the minimal protocol.
- **fund(jobId)**  
  SHALL revert if `job.provider == address(0)` (provider MUST be set before funding).

### Core Functions

- **createJob(provider, evaluator, expiredAt, description)**  
Called by client. Creates job in Open with `client = msg.sender`, `provider`, `evaluator`, `expiredAt`, `description`. SHALL revert if `evaluator` is zero or `expiredAt` is not in the future. **Provider MAY be zero**; if so, client MUST call `setProvider` before `fund`. Returns `jobId`.
- **setBudget(jobId, amount)**  
Called by client. Sets `job.budget = amount`. SHALL revert if job is not Open or caller is not client.
- **fund(jobId)**  
Called by client. SHALL revert if job is not Open, caller is not client, budget is zero, or **provider is not set** (`job.provider == address(0)`). SHALL transfer `job.budget` of the payment token from client to the contract (escrow) and set status to Funded.
- **submit(jobId, deliverable)**
Called by provider only. SHALL revert if job is not Funded or caller is not the job’s provider. SHALL set status to Submitted. `deliverable` (`bytes32`) is a reference to submitted work (e.g. hash of off-chain deliverable, IPFS CID, attestation commitment). SHALL emit an event including `deliverable` (e.g. JobSubmitted).
- **complete(jobId, reason)**
Called by evaluator only. SHALL revert if job is not Submitted or caller is not the job’s evaluator. SHALL set status to Completed. SHALL transfer escrowed funds to provider (minus optional platform fee to a configurable treasury). `reason` MAY be `bytes32(0)` or an attestation hash (OPTIONAL). SHALL emit an event including `reason` if provided.
- **reject(jobId, reason)**
Called by **client when job is Open** or by **evaluator when job is Funded or Submitted**. SHALL revert if job is not Open, Funded, or Submitted, or caller is not the client (when Open) or the evaluator (when Funded or Submitted). SHALL set status to Rejected. If Funded or Submitted, SHALL refund escrow to client. `reason` OPTIONAL. SHALL emit an event including `reason` and the caller (rejector) if provided.
- **claimRefund(jobId)**
Callable when job is Funded or Submitted and `block.timestamp >= expiredAt`, or when job is already Rejected/Expired. SHALL transfer full escrow to client and set status to Expired if not already terminal. MAY restrict caller (e.g. client only) or allow anyone; the specification RECOMMENDS allowing anyone to trigger refund after expiry.

### Provider acceptance (flag only)

To track that the provider has “taken” the job (e.g. for UIs and indexers), implementations SHALL support:

- A boolean on the job (e.g. `accepted` or `providerAccepted`), initially false.
- **acceptJob(jobId)**  
  Callable only by the job’s **provider**. SHALL revert if job is not Funded or the flag is already true. SHALL set the flag to true and SHALL emit an event (e.g. JobAccepted(jobId, provider)). The lifecycle state does NOT change; complete, reject, expire, and refund logic are unchanged.

### Attestation

- **complete(jobId, reason)**: `reason` is an optional attestation commitment (e.g. `bytes32` hash of off-chain evidence). Implementations MAY use `string` and hash it internally. Events SHOULD include `reason` for indexing and composition with reputation systems.
- **reject(jobId, reason)**: Optional `reason` for audit; same treatment as above.

### Fees

Implementations MAY charge a **platform fee** (basis points) on Completed, paid to a configurable treasury. The specification does not require a fee. If present, fee SHALL be deducted only on completion (not on refund).

### Events

Implementations SHOULD emit at least:

- **JobCreated**(jobId, client, provider, evaluator, expiredAt)
- **ProviderSet**(jobId, provider) — when provider is set on a job that was created without one
- **BudgetSet**(jobId, amount)
- **JobFunded**(jobId, client, amount)
- **JobAccepted**(jobId, provider) — when provider signals they have taken the job
- **JobSubmitted**(jobId, provider, deliverable) — when provider submits work for evaluation
- **JobCompleted**(jobId, evaluator, reason)
- **JobRejected**(jobId, rejector, reason)
- **JobExpired**(jobId)
- **PaymentReleased**(jobId, provider, amount)
- **Refunded**(jobId, client, amount)

### Security

- Reentrancy: Functions that transfer tokens SHALL be protected (e.g. reentrancy guard).
- Tokens: Use SafeERC20 or equivalent for ERC-20.
- Evaluator MUST be set at creation; if “client completes”, pass `evaluator = client`.

## Rationale

- **Single attester after submission**: Once Submitted, only the evaluator can complete or reject; the client cannot pull funds back unilaterally, so the provider is protected after starting work. Evaluator = client covers the “no third party” case.
- **Explicit submission**: The Submitted state gives the evaluator (and indexers/UIs) a clear signal that the provider considers work done and ready for evaluation, separating “funded and in progress” from “work delivered”.
- **Minimal surface**: Attestation is the optional `reason` on complete/reject; no additional ledger is required.
- **Four states + terminal**: Open, Funded, Submitted, and three terminal states are enough for “fund → work → submit → evaluate or refund”.
- **Expiry**: Refund after `expiredAt` gives client a way to reclaim funds without an explicit reject.

## Security Considerations

- Evaluator is trusted for completion and rejection once the job is Submitted; a malicious evaluator can complete or reject arbitrarily. Use reputation (e.g. ERC-8004) or staking for high-value jobs.
- Once Funded, only the evaluator can reject, and only the provider can submit; the client cannot unilaterally withdraw, which protects the provider after they start work.
- No dispute resolution or arbitration; reject/expire is final.
- Single payment token per contract reduces attack surface; per-job tokens are an extension.

## Copyright

Copyright and related rights waived via CC0.