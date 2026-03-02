# ERC-XXXX: Agentic Commerce

### Job escrow with evaluator attestation


| Authors  | XXXX                                                                 |
| -------- | -------------------------------------------------------------------- |
| Created  | 2026-02-25                                                           |
| Status   | Draft                                                                |
| Requires | [EIP-20](https://eips.ethereum.org/EIPS/eip-20) (for payment tokens) |


## Abstract

This specification defines the **Agentic Commerce Protocol**: a **job** with escrowed budget, four states (Open → Funded → Submitted → Terminal), and an **evaluator** who alone may mark the job completed. The client funds the job; the provider submits work; the evaluator attests completion or rejection once submitted (or the evaluator rejects while Funded before submission, or the client rejects while Open, or the job expires and the client is refunded). Optional attestation **reason** (e.g. hash) on complete/reject enables audit and composition with reputation (e.g. [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004)).

## Motivation

Many use cases need only: client locks funds, provider submits work, one attester (evaluator) signals “done” and triggers payment—or client rejects or timeout triggers refund. The Agentic Commerce Protocol specifies that minimal surface so implementations stay small and composable. The evaluator can be the client (e.g. `evaluator = client` at creation) when there is no third-party attester.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### State Machine

A **job** has exactly one of five states:


| State         | Meaning                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Open**      | Created; budget not yet set or not yet funded. Client may set budget, then fund or reject.                        |
| **Funded**    | Budget escrowed. Provider may submit work; evaluator may reject. After `expiredAt`, anyone may trigger refund.    |
| **Submitted** | Provider has submitted work. Only evaluator may complete or reject. After `expiredAt`, anyone may trigger refund. |
| **Completed** | Terminal. Escrow released to provider (minus optional platform fee).                                              |
| **Rejected**  | Terminal. Escrow refunded to client.                                                                              |
| **Expired**   | Terminal. Same as Rejected; escrow refunded to client.                                                            |


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
- **Provider**: Set at creation or later via `setProvider`. Calls `submit(jobId, deliverable)` when work is done to move the job from Funded to Submitted for evaluation. Receives payment when job is Completed. Does not call `complete` or `reject`.
- **Evaluator**: Single address per job, set at creation. When status is Submitted, **only** the evaluator MAY call `complete(jobId, reason?)` or `reject(jobId, reason?)`. When status is Funded, the evaluator MAY call `reject(jobId, reason?)` (before submission). MAY be the client (e.g. `evaluator = client`) so the client can complete or reject the job without a third party.

### Job Data

Each job SHALL have at least:

- `client`, `provider`, `evaluator` (addresses). **Provider MAY be zero at creation** (see Optional provider below).
- `description` (string) — set at creation (e.g. job brief, scope reference).
- `budget` (uint256)
- `expiredAt` (uint256 timestamp)
- `status` (Open | Funded | Submitted | Completed | Rejected | Expired)
- `hook` (address) — OPTIONAL. External hook contract called before and after core functions (see Hooks below). MAY be `address(0)` (no hook).

Payment SHALL use a single ERC-20 token (global for the contract or specified at creation). Implementations MAY support a per-job token; the specification only requires one token per contract.

### Optional provider (set later)

Jobs MAY be created **without a provider** by passing `provider = address(0)` to `createJob`. In that case the client SHALL set the provider later via `setProvider(jobId, provider)` before funding. This supports flows such as bidding or assignment after creation.

- **setProvider(jobId, provider)**  
Called by **client** only. SHALL revert if job is not Open, current `job.provider != address(0)`, or `provider == address(0)`. SHALL set `job.provider = provider` and SHALL emit an event (e.g. ProviderSet). Implementations MAY allow an operator role to call setProvider in the future; this specification only requires client-only for the minimal protocol.
- **fund(jobId)**  
SHALL revert if `job.provider == address(0)` (provider MUST be set before funding).

### Core Functions

- **createJob(provider, evaluator, expiredAt, description, hook?)**
Called by client. Creates job in Open with `client = msg.sender`, `provider`, `evaluator`, `expiredAt`, `description`, and optional `hook` address. SHALL revert if `evaluator` is zero or `expiredAt` is not in the future. **Provider MAY be zero**; if so, client MUST call `setProvider` before `fund`. `hook` MAY be `address(0)` (no hook). Returns `jobId`.
- **setProvider(jobId, provider, optParams?)**
Called by client. SHALL revert if job is not Open, current `job.provider != address(0)`, or `provider == address(0)`. SHALL set `job.provider = provider`. `optParams` (bytes, OPTIONAL) is forwarded to the hook contract if set (see Hooks).
- **setBudget(jobId, amount, optParams?)**
Called by client. Sets `job.budget = amount`. SHALL revert if job is not Open or caller is not client. `optParams` forwarded to hook if set.
- **fund(jobId, optParams?)**
Called by client. SHALL revert if job is not Open, caller is not client, budget is zero, or **provider is not set** (`job.provider == address(0)`). SHALL transfer `job.budget` of the payment token from client to the contract (escrow) and set status to Funded. `optParams` forwarded to hook if set.
- **submit(jobId, deliverable, optParams?)**
Called by provider only. SHALL revert if job is not Funded or caller is not the job’s provider. SHALL set status to Submitted. `deliverable` (`bytes32`) is a reference to submitted work (e.g. hash of off-chain deliverable, IPFS CID, attestation commitment). SHALL emit an event including `deliverable` (e.g. JobSubmitted). `optParams` forwarded to hook if set.
- **complete(jobId, reason, optParams?)**
Called by evaluator only. SHALL revert if job is not Submitted or caller is not the job’s evaluator. SHALL set status to Completed. SHALL transfer escrowed funds to provider (minus optional platform fee to a configurable treasury). `reason` MAY be `bytes32(0)` or an attestation hash (OPTIONAL). SHALL emit an event including `reason` if provided. `optParams` forwarded to hook if set.
- **reject(jobId, reason, optParams?)**
Called by **client when job is Open** or by **evaluator when job is Funded or Submitted**. SHALL revert if job is not Open, Funded, or Submitted, or caller is not the client (when Open) or the evaluator (when Funded or Submitted). SHALL set status to Rejected. If Funded or Submitted, SHALL refund escrow to client. `reason` OPTIONAL. SHALL emit an event including `reason` and the caller (rejector) if provided. `optParams` forwarded to hook if set.
- **claimRefund(jobId)**
Callable when job is Funded or Submitted and `block.timestamp >= expiredAt`, or when job is already Rejected/Expired. SHALL transfer full escrow to client and set status to Expired if not already terminal. MAY restrict caller (e.g. client only) or allow anyone; the specification RECOMMENDS allowing anyone to trigger refund after expiry.

### Attestation

- **complete(jobId, reason)**: `reason` is an optional attestation commitment (e.g. `bytes32` hash of off-chain evidence). Implementations MAY use `string` and hash it internally. Events SHOULD include `reason` for indexing and composition with reputation systems.
- **reject(jobId, reason)**: Optional `reason` for audit; same treatment as above.

### Fees

Implementations MAY charge a **platform fee** (basis points) on Completed, paid to a configurable treasury. The specification does not require a fee. If present, fee SHALL be deducted only on completion (not on refund).

### Hooks (OPTIONAL)

Implementations MAY support an optional **hook contract** per job to extend the core protocol without modifying it. The hook address is set at job creation (or `address(0)` for no hook) and stored on the job.

A hook contract SHALL implement the `IACPHook` interface — just two functions:

```solidity
interface IACPHook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

The `selector` parameter identifies which core function is being called (e.g. the function selector for `fund`). The `data` parameter contains function-specific parameters encoded as bytes (see Data encoding below). The hook uses the selector to route internally:

```solidity
function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
    if (selector == FUND_SELECTOR) {
        // custom pre-fund logic using data (optParams)
    } else if (selector == COMPLETE_SELECTOR) {
        // custom pre-complete logic using data (reason, optParams)
    }
}
```

When a job has a hook set, the core contract SHALL call `hook.beforeAction(...)` and `hook.afterAction(...)` around each hookable function:

| Core function  | Hookable |
| -------------- | -------- |
| `setProvider`  | Yes      |
| `setBudget`    | Yes      |
| `fund`         | Yes      |
| `submit`       | Yes      |
| `complete`     | Yes      |
| `reject`       | Yes      |
| `claimRefund`  | **No** — permissionless safety mechanism, SHALL NOT be hookable |

#### Data encoding

The `data` parameter passed to hooks contains the core function's parameters encoded as bytes. The encoding per selector:

| Core function  | `data` encoding                                      |
| -------------- | ---------------------------------------------------- |
| `setProvider`  | `abi.encode(address provider, bytes optParams)`       |
| `setBudget`    | `abi.encode(uint256 amount, bytes optParams)`         |
| `fund`         | `optParams` (raw bytes)                               |
| `submit`       | `abi.encode(bytes32 deliverable, bytes optParams)`    |
| `complete`     | `abi.encode(bytes32 reason, bytes optParams)`         |
| `reject`       | `abi.encode(bytes32 reason, bytes optParams)`         |

#### Hook behaviour

- The `optParams` field (`bytes`, OPTIONAL) on each hookable core function is an opaque payload forwarded to the hook via the `data` parameter. Callers that do not use hooks MAY pass empty bytes. The core contract SHALL NOT interpret `optParams`; it is for the hook only.
- **Before hooks** (`beforeAction`) are called before the core logic executes. A before hook MAY revert to block the action (e.g. enforce custom validation, allowlists, or preconditions).
- **After hooks** (`afterAction`) are called after the core logic completes (including state changes and token transfers). An after hook MAY perform side effects (e.g. emit events, update external state, trigger notifications) or revert to roll back the entire transaction.
- If `job.hook == address(0)`, the core contract SHALL skip hook calls and execute normally.

#### Hook security

- Hooks are **trusted** contracts chosen by the client at job creation. A malicious hook can revert valid actions or execute arbitrary logic in after-callbacks. Clients SHOULD audit or use well-known hook implementations.
- After-callbacks run after state changes but within the same transaction. If an after-callback reverts, the entire transaction (including the core state change) is rolled back.
- `onlyACP` modifiers on hooks are RECOMMENDED so that hook functions cannot be called directly by external actors.
- Hooks SHOULD NOT be upgradeable after a job is created, as this would allow the hook to change behaviour mid-job.
- `claimRefund` is deliberately not hookable so that refunds after expiry cannot be blocked by a malicious hook.

#### Convenience base contract (non-normative)

Implementations MAY provide a `BaseACPHook` that routes the generic `beforeAction`/`afterAction` calls to named virtual functions (e.g. `_preFund`, `_postComplete`) so hook developers only override what they need. This is NOT part of the standard — only `IACPHook` is normative.

#### Example use cases

- Pre-fund validation (e.g. KYC check, allowlist gate)
- Post-complete reputation updates (e.g. writing attestations to ERC-8004)
- Custom fee logic or payment splitting
- Atomic side transfers (e.g. fund transfer hook)
- Provider bidding (e.g. bidding hook)

---

#### Example 1 — Fund Transfer Hook

**Problem:** A client hires a payment agent whose job is to move tokens on the client's behalf. The agent fee (escrow) and the side token transfer must either both succeed or both revert.

**Solution:** A `FundTransferHook` that (a) stores a transfer commitment at `setBudget` time and (b) executes the transfer atomically inside the `afterAction` callback for `fund`.

```
Step 1 — createJob
  Client → createJob(provider, evaluator, expiredAt, desc, hook=FundTransferHook)
  Job created (Open), hook address stored.

Step 2 — setBudget
  Client → setBudget(jobId, agentFee, optParams=abi.encode(dest, transferAmount))
    → hook.beforeAction: decode optParams, store {dest, transferAmount} as commitment.
    → core: job.budget = agentFee
    → hook.afterAction: [no-op]

Step 3 — fund
  Client approves: contract for agentFee, hook for transferAmount.
  Client → fund(jobId, "")
    → hook.beforeAction: verify client approved hook for transferAmount. Revert if not.
    → core: pull agentFee into escrow, set Funded.
    → hook.afterAction: pull transferAmount from client, forward to dest. Delete commitment.

Step 4 — work happens off-chain

Step 5 — submit + complete
  Provider → submit(jobId, deliverable, "")
  Evaluator → complete(jobId, reason, "")
    → core: release escrowed agentFee to provider (minus platform fee).
```

**Key property:** Atomicity. The client cannot fund the job without the side transfer executing, and the side transfer cannot execute without the job being funded. Both succeed or both revert.

---

#### Example 2 — Bidding Hook

**Problem:** A client wants to hire the cheapest (or best) agent for a job but does not know upfront who to assign. The selection should be determined by an open bidding process, not unilaterally by the client after the fact.

**Solution:** A `BiddingHook` that verifies off-chain signed bids. Providers sign bid commitments off-chain; the client collects bids, selects the winner, and submits the winning bid's signature via `setProvider`. The hook's `beforeAction` callback recovers the signer and verifies it matches the chosen provider — proving the provider actually committed to that price.

Zero direct calls to the hook. All interactions flow through the core contract → hook callbacks.

```
Step 1 — createJob
  Client → createJob(provider=0, evaluator, expiredAt, desc, hook=BiddingHook)
  Job created (Open), provider = address(0).

Step 2 — setBudget (opens bidding via hook callback)
  Client → setBudget(jobId, maxBudget, optParams=abi.encode(biddingDeadline))
    → hook.beforeAction: store deadline for this jobId.

Step 3 — bidding happens OFF-CHAIN
  Providers sign: keccak256(abi.encode(chainId, hookAddress, jobId, bidAmount))
  Client collects signed bids and selects the winner.
  Core contract is unaware of bids.

Step 4 — setProvider (hook verifies winning bid signature)
  Client → setProvider(jobId, winnerAddress, optParams=abi.encode(bidAmount, signature))
    → hook.beforeAction: verify deadline passed, recover signer from signature,
      validate signer == provider, store committed bidAmount. Revert if invalid.
    → core: job.provider = winnerAddress
    → hook.afterAction: mark bidding finalised (no further setProvider possible).

Step 5 — job continues normally
  Client → fund(jobId, "")
  Provider → submit(jobId, deliverable, "")
  Evaluator → complete(jobId, reason, "")
```

**Key property:** The client cannot fabricate a provider commitment. The hook verifies the chosen provider actually signed a bid at the claimed price. The client is incentivised to pick the lowest bidder since they are the one paying.

---

### Events

Implementations SHOULD emit at least:

- **JobCreated**(jobId, client, provider, evaluator, expiredAt)
- **ProviderSet**(jobId, provider) — when provider is set on a job that was created without one
- **BudgetSet**(jobId, amount)
- **JobFunded**(jobId, client, amount)
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
- **Hooks over inheritance**: Optional hook contracts let integrators extend the protocol (validation, reputation, fees) without modifying or inheriting from the core contract. The core stays minimal; complexity lives in the hook.
- **Generic hook interface**: The `IACPHook` interface uses just two functions (`beforeAction`/`afterAction`) with a selector parameter rather than named functions per action. This keeps the interface stable as the core protocol evolves — new hookable functions simply produce new selector values without changing the interface.

## Security Considerations

- Evaluator is trusted for completion and rejection once the job is Submitted; a malicious evaluator can complete or reject arbitrarily. Use reputation (e.g. ERC-8004) or staking for high-value jobs.
- Once Funded, only the evaluator can reject, and only the provider can submit; the client cannot unilaterally withdraw, which protects the provider after they start work.
- No dispute resolution or arbitration; reject/expire is final.
- Single payment token per contract reduces attack surface; per-job tokens are an extension.
- Hook contracts are client-supplied and trusted by the client; implementations SHOULD use a gas limit on hook calls to prevent griefing, and MUST NOT allow hooks to modify core escrow state directly. `claimRefund` is deliberately not hookable so that refunds after expiry cannot be blocked by a malicious hook.

## Copyright

Copyright and related rights waived via CC0.