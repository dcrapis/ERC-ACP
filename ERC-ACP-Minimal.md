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
- **Funded → Submitted**: Provider calls `submit(jobId)`; signals that work has been completed and is ready for evaluation.
- **Funded → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Funded → Expired**: When `block.timestamp >= job.expiredAt`, anyone (or client) may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.
- **Submitted → Completed**: Evaluator calls `complete(jobId, reason?)`; contract distributes escrow to provider (and optional fee to treasury).
- **Submitted → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Submitted → Expired**: When `block.timestamp >= job.expiredAt`, anyone (or client) may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.

No other transitions are valid.

### Roles

- **Client**: Creates job (with optional description), may set provider via `setProvider(jobId, provider)` when job was created with no provider, sets budget with `setBudget(jobId, amount)`, funds escrow with `fund(jobId)`, may reject **only when status is Open**. Receives refund on Rejected/Expired.
- **Provider**: Set at creation or later via `setProvider`. May call `acceptJob(jobId)` when job is Funded to signal they have taken the job. Calls `submit(jobId)` when work is done to move the job from Funded to Submitted for evaluation. Receives payment when job is Completed. Does not call `complete` or `reject`.
- **Evaluator**: Single address per job, set at creation. When status is Submitted, **only** the evaluator MAY call `complete(jobId, reason?)` or `reject(jobId, reason?)`. When status is Funded, the evaluator MAY call `reject(jobId, reason?)` (before submission). MAY be the client (e.g. `evaluator = client`) so the client can complete or reject the job without a third party.

### Job Data

Each job SHALL have at least:

- `client`, `provider`, `evaluator` (addresses). **Provider MAY be zero at creation** (see Optional provider below).
- `description` (string) — set at creation (e.g. job brief, scope reference).
- `budget` (uint256)
- `expiredAt` (uint256 timestamp)
- `status` (Open | Funded | Submitted | Completed | Rejected | Expired)
- `accepted` (boolean) — set when the provider has signaled they have taken the job (see Provider acceptance below).
- `hook` (address) — OPTIONAL. External hook contract called before and after core functions (see Hooks below). MAY be `address(0)` (no hook).

Payment SHALL use a single ERC-20 token (global for the contract or specified at creation). Implementations MAY support a per-job token; the specification only requires one token per contract.

### Optional provider (set later)

Jobs MAY be created **without a provider** by passing `provider = address(0)` to `createJob`. In that case the client SHALL set the provider later via `setProvider(jobId, provider)` before funding. This supports flows such as auctions or assignment after creation.

- **setProvider(jobId, provider)**  
  Called by **client** only. SHALL revert if job is not Open, current `job.provider != address(0)`, or `provider == address(0)`. SHALL set `job.provider = provider` and SHALL emit an event (e.g. ProviderSet). Implementations MAY allow an operator role to call setProvider in the future; this specification only requires client-only for the minimal protocol.
- **fund(jobId)**  
  SHALL revert if `job.provider == address(0)` (provider MUST be set before funding).

### Core Functions

- **createJob(provider, evaluator, expiredAt, description, hook?)**
Called by client. Creates job in Open with `client = msg.sender`, `provider`, `evaluator`, `expiredAt`, `description`, and optional `hook` address. SHALL revert if `evaluator` is zero or `expiredAt` is not in the future. **Provider MAY be zero**; if so, client MUST call `setProvider` before `fund`. `hook` MAY be `address(0)` (no hook). Returns `jobId`.
- **setBudget(jobId, amount, optParams?)**
Called by client. Sets `job.budget = amount`. SHALL revert if job is not Open or caller is not client. `optParams` (bytes, OPTIONAL) is forwarded to the hook contract if set (see Hooks).
- **fund(jobId, optParams?)**
Called by client. SHALL revert if job is not Open, caller is not client, budget is zero, or **provider is not set** (`job.provider == address(0)`). SHALL transfer `job.budget` of the payment token from client to the contract (escrow) and set status to Funded. `optParams` forwarded to hook if set.
- **submit(jobId, optParams?)**
Called by provider only. SHALL revert if job is not Funded or caller is not the job’s provider. SHALL set status to Submitted. SHALL emit an event (e.g. JobSubmitted). `optParams` forwarded to hook if set.
- **complete(jobId, reason, optParams?)**
Called by evaluator only. SHALL revert if job is not Submitted or caller is not the job’s evaluator. SHALL set status to Completed. SHALL transfer escrowed funds to provider (minus optional platform fee to a configurable treasury). `reason` MAY be `bytes32(0)` or an attestation hash (OPTIONAL). SHALL emit an event including `reason` if provided. `optParams` forwarded to hook if set.
- **reject(jobId, reason, optParams?)**
Called by **client when job is Open** or by **evaluator when job is Funded or Submitted**. SHALL revert if job is not Open, Funded, or Submitted, or caller is not the client (when Open) or the evaluator (when Funded or Submitted). SHALL set status to Rejected. If Funded or Submitted, SHALL refund escrow to client. `reason` OPTIONAL. SHALL emit an event including `reason` and the caller (rejector) if provided. `optParams` forwarded to hook if set.
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

### Hooks (OPTIONAL)

Implementations MAY support an optional **hook contract** per job to extend the core protocol without modifying it. The hook address is set at job creation (or `address(0)` for no hook) and stored on the job.

A hook contract SHALL implement the `IACPHook` interface — just two functions:

```solidity
interface IACPHook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata optParams) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata optParams) external;
}
```

The `selector` parameter identifies which core function is being called (e.g. `ACPMinimal.fund.selector`). The hook uses it to route internally:

```solidity
function beforeAction(uint256 jobId, bytes4 selector, bytes calldata optParams) external {
    if (selector == IACPMinimal.fund.selector) {
        // custom pre-fund logic
    } else if (selector == IACPMinimal.complete.selector) {
        // custom pre-complete logic
    }
}
```

When a job has a hook set, the core contract SHALL call `hook.beforeAction(...)` and `hook.afterAction(...)` around each hookable function:

| Core function  | Hookable |
| -------------- | -------- |
| `setBudget`    | Yes      |
| `fund`         | Yes      |
| `submit`       | Yes      |
| `complete`     | Yes      |
| `reject`       | Yes      |
| `claimRefund`  | **No** — permissionless safety mechanism, SHALL NOT be hookable |

- The `optParams` field (`bytes`, OPTIONAL) on each hookable core function is an opaque payload forwarded to the hook. Callers that do not use hooks MAY pass empty bytes. The core contract SHALL NOT interpret `optParams`; it is for the hook only.
- **Before hooks** (`beforeAction`) are called before the core logic executes. A before hook MAY revert to block the action (e.g. enforce custom validation, allowlists, or preconditions).
- **After hooks** (`afterAction`) are called after the core logic completes (including state changes and token transfers). An after hook MAY perform side effects (e.g. emit events, update external state, trigger notifications) or revert to roll back the entire transaction.
- If `job.hook == address(0)`, the core contract SHALL skip hook calls and execute normally.

**Example use cases for hooks:**
- Pre-fund validation (e.g. KYC check, allowlist gate)
- Post-complete reputation updates (e.g. writing attestations to ERC-8004)
- Custom fee logic or payment splitting
- Event relaying to off-chain indexers

### Events

Implementations SHOULD emit at least:

- **JobCreated**(jobId, client, provider, evaluator, expiredAt)
- **ProviderSet**(jobId, provider) — when provider is set on a job that was created without one
- **BudgetSet**(jobId, amount)
- **JobFunded**(jobId, client, amount)
- **JobAccepted**(jobId, provider) — when provider signals they have taken the job
- **JobSubmitted**(jobId, provider) — when provider submits work for evaluation
- **JobCompleted**(jobId, evaluator, reason)
- **JobRejected**(jobId, rejector, reason)
- **JobExpired**(jobId)
- **PaymentReleased**(jobId, provider, amount)
- **Refunded**(jobId, client, amount)

### Security

- Reentrancy: Functions that transfer tokens SHALL be protected (e.g. reentrancy guard).
- Tokens: Use SafeERC20 or equivalent for ERC-20.
- Evaluator MUST be set at creation; if “client completes”, pass `evaluator = client`.

## Hooks (Extension)

Implementations MAY support an optional **hook** contract per job. A hook is an address stored on the job at creation (`createJob(..., hook)`). When set, `ACPMinimal` calls into the hook before and after specific core functions, forwarding `optParams` for context. The hook MAY revert to block or roll back the action.

Hooks enable powerful extensions without changing the core protocol. Implementors inherit `BaseACPHook` (all no-ops) and override only what they need.

### Hook Interface

```solidity
interface IACPHook {
    function preSetBudget(uint256 jobId, bytes calldata optParams) external;
    function postSetBudget(uint256 jobId, bytes calldata optParams) external;
    function preSetProvider(uint256 jobId, address provider, bytes calldata optParams) external;
    function postSetProvider(uint256 jobId, address provider, bytes calldata optParams) external;
    function preFund(uint256 jobId, bytes calldata optParams) external;
    function postFund(uint256 jobId, bytes calldata optParams) external;
    function preComplete(uint256 jobId, bytes32 reason) external;
    function postComplete(uint256 jobId, bytes32 reason) external;
    function preReject(uint256 jobId, bytes32 reason) external;
    function postReject(uint256 jobId, bytes32 reason) external;
}
```

### Hook Call Points in ACPMinimal

| Function | Hook calls |
|----------|-----------|
| `setBudget(jobId, amount, optParams)` | `preSetBudget` → set budget → `postSetBudget` |
| `setProvider(jobId, provider, optParams)` | `preSetProvider` → set provider → `postSetProvider` |
| `fund(jobId, optParams)` | `preFund` → escrow → `postFund` |
| `complete(jobId, reason)` | `preComplete` → release escrow → `postComplete` |
| `reject(jobId, reason)` | `preReject` → refund → `postReject` |
| `submit`, `claimRefund` | No hook calls |

---

### Example 1 — Fund Transfer Hook

**Problem:** A client hires a payment agent whose job is to move tokens on the client's behalf. The agent fee (escrow) and the side token transfer must either both succeed or both revert.

**Solution:** A `FundTransferHook` that (a) lets the seller commit the transfer params at `setBudget` time and (b) executes the transfer atomically inside `postFund`.

**Why the split between `setBudget` and `fund` matters:** `setBudget` is called by the **seller (provider/agent)** — they commit their fee and the transfer destination + amount. `fund` is called by the **buyer (client)** — but they cannot alter the transfer params because the hook already has the seller's binding commitment. This prevents a dishonest buyer from redirecting or undercutting the transfer.

```
Step 1 — createJob
  Client → ACPMinimal.createJob(provider, evaluator, expiredAt, desc, hook=FundTransferHook)
  ACPMinimal: job created (Open), hook address stored on job.

Step 2 — setBudget  [called by SELLER / provider]
  Provider → ACPMinimal.setBudget(jobId, agentFee, optParams: abi.encode(dest, transferAmount))
    → hook.preSetBudget(jobId, optParams)
         FundTransferHook: decode optParams, store {dest, transferAmount} as commitment for jobId.
    → ACPMinimal: job.budget = agentFee
    → hook.postSetBudget(jobId, optParams)   [no-op]

Step 3 — fund  [called by BUYER / client]
  Client must approve: ACPMinimal for agentFee, FundTransferHook for transferAmount.
  Client → ACPMinimal.fund(jobId, optParams: "")
    → hook.preFund(jobId, optParams)
         FundTransferHook: read commitment, verify client has approved hook for transferAmount. Revert if not.
    → ACPMinimal: pull agentFee from client into escrow, set status = Funded.
    → hook.postFund(jobId, optParams)
         FundTransferHook: pull transferAmount from client, forward to dest. Delete commitment (no replay).

Step 4 — work happens off-chain

Step 5 — submit / complete
  Provider → ACPMinimal.submit(jobId)
  Evaluator → ACPMinimal.complete(jobId, reason)
    ACPMinimal: release escrowed agentFee to provider (minus platform fee).
```

**Key property:** Atomicity. The client cannot fund the job without the side transfer executing, and the side transfer cannot execute without the job being funded.

---

### Example 2 — Auction / Bidding Hook

**Problem:** A client wants to hire the best agent for a job but does not know upfront who to assign. The selection should be determined by an open bidding process, not unilaterally by the client after the fact.

**Solution:** An `AuctionHook` that manages a bidding window. `preSetProvider` validates that the address the client submits is the auction winner — the hook enforces the outcome.

```
Step 1 — createJob
  Client → ACPMinimal.createJob(provider=0, evaluator, expiredAt, desc, hook=AuctionHook)
  ACPMinimal: job created (Open), provider = address(0).
  Client → AuctionHook.openAuction(jobId, deadline)
  AuctionHook: bidding window opened until deadline.

Step 2 — bidding  [called directly on AuctionHook by agents/providers]
  AgentA → AuctionHook.placeBid(jobId, bidAmount)
  AgentB → AuctionHook.placeBid(jobId, bidAmount)
  ...
  AuctionHook: records all bids. ACP contract is unaware of bids.

Step 3 — close auction  [after deadline]
  Client → AuctionHook.closeAuction(jobId)
  AuctionHook: picks winner (e.g. lowest bid), stores winnerFor[jobId].

Step 4 — setProvider  [called by client on ACPMinimal]
  Client → ACPMinimal.setProvider(jobId, winnerAddress, optParams: "")
    → hook.preSetProvider(jobId, winnerAddress, optParams)
         AuctionHook: verify auction is closed, verify winnerAddress == winner. Revert if not.
    → ACPMinimal: job.provider = winnerAddress
    → hook.postSetProvider(jobId, winnerAddress, optParams)
         AuctionHook: mark auction as finalised (no further setProvider possible).

Step 5 — job continues normally
  Provider → ACPMinimal.setBudget(jobId, amount, "")   [no hook needed here]
  Client   → ACPMinimal.fund(jobId, "")
  Provider → ACPMinimal.submit(jobId)
  Evaluator → ACPMinimal.complete(jobId, reason)
```

**Key property:** The client cannot assign a provider that did not win the auction. The hook is the authority on the selection outcome.

---

---

### Example 3 — Insurance Hook *(conceptual)*

> **Note:** This example illustrates the hook composition pattern. A production insurance product would require actuarial pricing, oracle integration, dispute resolution, and regulatory consideration. The logic here is intentionally simplified.

**Problem:** A client wants protection in case an agent fails to deliver. If the job is rejected, they should receive a payout on top of their escrow refund. If the job completes successfully, the insurer keeps the premium.

**Solution:** An `InsuranceHook` that collects a premium at `fund` time, keeps it on completion, and pays out coverage on rejection.

```
Step 1 — createJob
  Client → ACPMinimal.createJob(provider, evaluator, expiredAt, desc, hook=InsuranceHook)
  ACPMinimal: job created (Open), hook address stored on job.

Step 2 — setBudget  [called by seller/provider]
  Provider → ACPMinimal.setBudget(jobId, agentFee, optParams: abi.encode(premium, coverage))
    → hook.preSetBudget(jobId, optParams)
         InsuranceHook: decode and store {premium, coverage} as policy for jobId.
    → ACPMinimal: job.budget = agentFee
    → hook.postSetBudget(jobId, optParams)   [no-op]

Step 3 — fund  [called by BUYER / client]
  Client must approve: ACPMinimal for agentFee, InsuranceHook for premium.
  Client → ACPMinimal.fund(jobId, optParams: "")
    → hook.preFund(jobId, optParams)
         InsuranceHook: verify client has approved hook for premium. Revert if not.
    → ACPMinimal: pull agentFee from client into escrow, set Funded.
    → hook.postFund(jobId, optParams)
         InsuranceHook: pull premium from client, send to insurer treasury. Policy activated.

Step 4 — work happens off-chain

Step 5a — HAPPY PATH: complete(jobId, reason)
  Evaluator → ACPMinimal.complete(jobId, reason)
    → hook.preComplete(jobId, reason)   [no-op]
    → ACPMinimal: release escrowed agentFee to provider.
    → hook.postComplete(jobId, reason)
         InsuranceHook: close policy. Premium stays with insurer. No claim.

Step 5b — CLAIM PATH: reject(jobId, reason)
  Evaluator → ACPMinimal.reject(jobId, reason)
    → hook.preReject(jobId, reason)   [no-op]
    → ACPMinimal: refund escrowed agentFee to client.
    → hook.postReject(jobId, reason)
         InsuranceHook: insurer pays coverage amount to client. Policy closed.
         Client receives: escrow refund (from ACP) + coverage (from insurer).
```

**Key property:** The client's downside on a failed job is bounded. The insurer takes the premium risk in exchange for covering the gap between the refund and the expected outcome. The hook composes cleanly on top of the core lifecycle — no changes to `ACPMinimal` are needed.

---

### Hook Security Considerations

- Hooks are **trusted** contracts. A malicious hook can revert valid actions or execute arbitrary logic in `post*` callbacks. Clients SHOULD audit or use well-known hook implementations.
- Hook `post*` callbacks run after state changes but within the same transaction. If a `post*` callback reverts, the entire transaction (including the core state change) is rolled back.
- `onlyACP` modifiers on hooks are RECOMMENDED so that hook functions cannot be called directly by external actors.
- Hooks SHOULD NOT be upgradeable after a job is created, as this would allow the hook to change behaviour mid-job.

## Rationale

- **Single attester after submission**: Once Submitted, only the evaluator can complete or reject; the client cannot pull funds back unilaterally, so the provider is protected after starting work. Evaluator = client covers the “no third party” case.
- **Explicit submission**: The Submitted state gives the evaluator (and indexers/UIs) a clear signal that the provider considers work done and ready for evaluation, separating “funded and in progress” from “work delivered”.
- **Minimal surface**: Attestation is the optional `reason` on complete/reject; no additional ledger is required.
- **Four states + terminal**: Open, Funded, Submitted, and three terminal states are enough for “fund → work → submit → evaluate or refund”.
- **Expiry**: Refund after `expiredAt` gives client a way to reclaim funds without an explicit reject.
- **Hooks over inheritance**: Optional hook contracts let integrators extend the protocol (validation, reputation, fees) without modifying or inheriting from the core contract. The core stays minimal; complexity lives in the hook.

## Security Considerations

- Evaluator is trusted for completion and rejection once the job is Submitted; a malicious evaluator can complete or reject arbitrarily. Use reputation (e.g. ERC-8004) or staking for high-value jobs.
- Once Funded, only the evaluator can reject, and only the provider can submit; the client cannot unilaterally withdraw, which protects the provider after they start work.
- No dispute resolution or arbitration; reject/expire is final.
- Single payment token per contract reduces attack surface; per-job tokens are an extension.
- Hook contracts are client-supplied and untrusted; implementations SHOULD use a gas limit on hook calls to prevent griefing, and MUST NOT allow hooks to modify core escrow state directly. `claimRefund` is deliberately not hookable so that refunds after expiry cannot be blocked by a malicious hook.

## Copyright

Copyright and related rights waived via CC0.