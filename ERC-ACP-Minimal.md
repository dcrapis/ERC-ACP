# ERC-XXXX: Minimal Agent Commerce Protocol

### Job escrow with evaluator attestation


| Authors  | XXXX                                                                 |
| -------- | -------------------------------------------------------------------- |
| Created  | 2026-02-25                                                           |
| Status   | Draft                                                                |
| Requires | [EIP-20](https://eips.ethereum.org/EIPS/eip-20) (for payment tokens) |


## Abstract

This specification defines the **Minimal Agent Commerce Protocol**: a **job** with escrowed budget, three states (Open → Funded → Terminal), and an **evaluator** who alone may mark the job completed. The client funds the job; the evaluator attests completion (or the client rejects / job expires and the client is refunded). Optional attestation **reason** (e.g. hash) on complete/reject enables audit and composition with reputation (e.g. [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004)).

## Motivation

Many use cases need only: client locks funds, work happens off-chain, one attester (evaluator) signals “done” and triggers payment—or client rejects or timeout triggers refund. The Minimal Agent Commerce Protocol specifies that minimal surface so implementations stay small and composable. The evaluator can be the client (e.g. `evaluator = client` at creation) when there is no third-party attester.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### State Machine

A **job** has exactly one of four states:


| State         | Meaning                                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| **Open**      | Created; budget set but not escrowed. Client may fund or reject.                                                    |
| **Funded**    | Budget escrowed. Only evaluator may complete; only client may reject. After `expiredAt`, anyone may trigger refund. |
| **Completed** | Terminal. Escrow released to provider (minus optional platform fee).                                                |
| **Rejected**  | Terminal. Escrow refunded to client.                                                                                |
| **Expired**   | Terminal. Same as Rejected; escrow refunded to client.                                                              |


Allowed transitions:

- **Open → Funded**: Client calls `fund(jobId)` (or equivalent); contract pulls `budget` from client into escrow.
- **Open → Rejected**: Client calls `reject(jobId, reason?)`.
- **Funded → Completed**: Evaluator calls `complete(jobId, reason?)`; contract distributes escrow to provider (and optional fee to treasury).
- **Funded → Rejected**: Client calls `reject(jobId, reason?)`; contract refunds client.
- **Funded → Expired**: When `block.timestamp >= job.expiredAt`, anyone (or client) may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.

No other transitions are valid.

### Roles

- **Client**: Creates job, sets budget, funds escrow, may reject before or after funding. Receives refund on Rejected/Expired.
- **Provider**: Receives payment when job is Completed. Does not call `complete` or `reject`.
- **Evaluator**: Single address per job, set at creation. **Only** role that MAY call `complete(jobId, reason?)`. MAY be the client (e.g. `evaluator = client`) so the client can complete the job without a third party.

### Job Data

Each job SHALL have at least:

- `client`, `provider`, `evaluator` (addresses)
- `budget` (uint256)
- `expiredAt` (uint256 timestamp)
- `status` (Open | Funded | Completed | Rejected | Expired)

Payment SHALL use a single ERC-20 token (global for the contract or specified at creation). Implementations MAY support a per-job token; the specification only requires one token per contract.

### Core Functions

- **createJob(provider, evaluator, expiredAt)**  
Called by client. Creates job in Open with `client = msg.sender`, `provider`, `evaluator`, `expiredAt`. SHALL revert if `provider` or `evaluator` is zero, or `expiredAt` is not in the future. Returns `jobId`.
- **setBudget(jobId, amount)**  
Called by client. Sets `job.budget = amount`. SHALL revert if job is not Open or caller is not client.
- **fund(jobId)**  
Called by client. SHALL revert if job is not Open or budget is zero. SHALL transfer `budget` of the payment token from client to the contract (escrow). SHALL set status to Funded.
- **complete(jobId, reason)**  
Called by evaluator only. SHALL revert if job is not Funded or caller is not the job’s evaluator. SHALL set status to Completed. SHALL transfer escrowed funds to provider (minus optional platform fee to a configurable treasury). `reason` MAY be `bytes32(0)` or an attestation hash (OPTIONAL). SHALL emit an event including `reason` if provided.
- **reject(jobId, reason)**  
Called by client. SHALL revert if job is not Open or Funded, or caller is not client. SHALL set status to Rejected. If Funded, SHALL refund escrow to client. `reason` OPTIONAL. SHALL emit an event including `reason` if provided.
- **claimRefund(jobId)**  
Callable when job is Funded and `block.timestamp >= expiredAt`, or when job is already Rejected/Expired. SHALL transfer full escrow to client and set status to Expired if not already terminal. MAY restrict caller (e.g. client only) or allow anyone; the specification RECOMMENDS allowing anyone to trigger refund after expiry.

### Attestation

- **complete(jobId, reason)**: `reason` is an optional attestation commitment (e.g. `bytes32` hash of off-chain evidence). Implementations MAY use `string` and hash it internally. Events SHOULD include `reason` for indexing and composition with reputation systems.
- **reject(jobId, reason)**: Optional `reason` for audit; same treatment as above.

### Fees

Implementations MAY charge a **platform fee** (basis points) on Completed, paid to a configurable treasury. The specification does not require a fee. If present, fee SHALL be deducted only on completion (not on refund).

### Events

Implementations SHOULD emit at least:

- **JobCreated**(jobId, client, provider, evaluator, expiredAt)
- **BudgetSet**(jobId, amount)
- **JobFunded**(jobId, client, amount)
- **JobCompleted**(jobId, evaluator, reason)
- **JobRejected**(jobId, client, reason)
- **JobExpired**(jobId)
- **PaymentReleased**(jobId, provider, amount)
- **Refunded**(jobId, client, amount)

### Security

- Reentrancy: Functions that transfer tokens SHALL be protected (e.g. reentrancy guard).
- Tokens: Use SafeERC20 or equivalent for ERC-20.
- Evaluator MUST be set at creation; if “client completes”, pass `evaluator = client`.

## Rationale

- **Single attester**: Only the evaluator can complete; no ambiguity. Evaluator = client covers the “no third party” case.
- **Minimal surface**: Attestation is the optional `reason` on complete/reject; no additional ledger is required.
- **Three states + terminal**: Open, Funded, and three terminal states are enough for “fund → work → complete or refund”.
- **Expiry**: Refund after `expiredAt` gives client a way to reclaim funds without an explicit reject.

## Security Considerations

- Evaluator is trusted for completion; a malicious evaluator can complete and pay the provider even if work was not done. Use reputation (e.g. ERC-8004) or staking for high-value jobs.
- No dispute resolution or arbitration; reject/expire is final.
- Single payment token per contract reduces attack surface; per-job tokens are an extension.

## Copyright

Copyright and related rights waived via CC0.