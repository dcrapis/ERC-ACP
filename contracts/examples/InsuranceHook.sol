// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseACPHook.sol";

/**
 * @title InsuranceHook
 * @notice Example ACP hook illustrating how a job can be insured.
 *
 * NOTE: This is a CONCEPTUAL example to demonstrate hook composition.
 *       A real insurance product would require actuarial pricing, external
 *       oracles, dispute resolution, and regulatory consideration. The logic
 *       here is intentionally simplified to illustrate the hook flow.
 *
 * USE CASE
 * --------
 * A client wants protection in case an agent fails to deliver (job is
 * rejected). They pay a small insurance premium at fund time. If the job
 * completes successfully, the premium is kept by the insurer. If the job is
 * rejected, the insurer pays out a coverage amount to the client on top of
 * the normal escrow refund.
 *
 * ROLES
 * -----
 *  - Client: funds the job and pays the insurance premium.
 *  - Insurer (this contract's owner / treasury): collects premiums, pays claims.
 *  - ACPMinimal: manages the job lifecycle; calls this hook at fund/complete/reject.
 *
 * FLOW
 * ----
 *  1. createJob(provider, evaluator, expiredAt, desc, hook=InsuranceHook)
 *     └─ Job created in Open state.
 *
 *  2. setBudget(jobId, agentFee, optParams: abi.encode(premium, coverage))
 *     └─ preSetBudget: decode and store {premium, coverage} for jobId.
 *     └─ ACPMinimal: set job.budget = agentFee.
 *
 *  3. fund(jobId, optParams: "")
 *     └─ preFund: verify client has approved hook for premium amount.
 *     └─ ACPMinimal: pull agentFee into escrow, set Funded.
 *     └─ postFund: pull premium from client. Policy is now active.
 *
 *  4a. complete(jobId, reason)   — happy path
 *     └─ preComplete:  (no-op; no checks needed)
 *     └─ ACPMinimal:   release escrow to provider.
 *     └─ postComplete: mark policy as closed (no claim). Premium stays with insurer.
 *
 *  4b. reject(jobId, reason)   — claim path
 *     └─ preReject:  (no-op)
 *     └─ ACPMinimal: refund escrow to client.
 *     └─ postReject: insurer pays coverage amount to client. Policy closed.
 *
 * SECURITY NOTES
 * --------------
 *  - The insurer treasury must hold enough funds to pay claims; this example
 *    does not enforce solvency — a real implementation must.
 *  - Client must approve this hook for the premium before calling fund.
 *  - Only ACPMinimal may call hook functions (onlyACP modifier).
 */
contract InsuranceHook is BaseACPHook {
    using SafeERC20 for IERC20;

    struct Policy {
        uint256 premium;
        uint256 coverage;
        bool active;
        bool claimed;
    }

    IERC20 public immutable token;
    address public immutable acpMinimal;
    address public immutable insurerTreasury;

    mapping(uint256 => Policy) public policies;

    error OnlyACPMinimal();
    error PolicyNotSet();
    error PolicyNotActive();
    error PolicyAlreadyClaimed();
    error InsufficientAllowance();
    error ZeroAddress();
    error ZeroAmount();

    modifier onlyACP() {
        if (msg.sender != acpMinimal) revert OnlyACPMinimal();
        _;
    }

    constructor(address token_, address acpMinimal_, address insurerTreasury_) {
        if (token_ == address(0) || acpMinimal_ == address(0) || insurerTreasury_ == address(0))
            revert ZeroAddress();
        token = IERC20(token_);
        acpMinimal = acpMinimal_;
        insurerTreasury = insurerTreasury_;
    }

    // -------------------------------------------------------------------------
    // Hook: setBudget — seller (or client) commits insurance terms
    // -------------------------------------------------------------------------

    /**
     * @notice Store insurance terms for a job.
     * @param optParams abi.encode(uint256 premium, uint256 coverage)
     */
    function preSetBudget(uint256 jobId, bytes calldata optParams) external override onlyACP {
        if (optParams.length == 0) return; // no insurance for this job
        (uint256 premium, uint256 coverage) = abi.decode(optParams, (uint256, uint256));
        if (premium == 0 || coverage == 0) revert ZeroAmount();
        policies[jobId] = Policy({
            premium: premium,
            coverage: coverage,
            active: false,
            claimed: false
        });
    }

    // -------------------------------------------------------------------------
    // Hook: fund — collect premium, activate policy
    // -------------------------------------------------------------------------

    /**
     * @notice Verify client has approved this hook for the premium.
     */
    function preFund(uint256 jobId, bytes calldata) external override onlyACP {
        Policy storage p = policies[jobId];
        if (p.premium == 0) return; // no insurance on this job
        (,address client,,,,,,,, ) = _getJob(jobId);
        if (token.allowance(client, address(this)) < p.premium) revert InsufficientAllowance();
    }

    /**
     * @notice Pull premium from client and activate policy.
     */
    function postFund(uint256 jobId, bytes calldata) external override onlyACP {
        Policy storage p = policies[jobId];
        if (p.premium == 0) return; // no insurance on this job
        (,address client,,,,,,,, ) = _getJob(jobId);
        token.safeTransferFrom(client, insurerTreasury, p.premium);
        p.active = true;
    }

    // -------------------------------------------------------------------------
    // Hook: complete — close policy, no claim
    // -------------------------------------------------------------------------

    /**
     * @notice Job completed successfully. Close the policy; premium stays with insurer.
     */
    function postComplete(uint256 jobId, bytes32) external override onlyACP {
        Policy storage p = policies[jobId];
        if (!p.active) return;
        p.active = false; // policy closed, no claim
    }

    // -------------------------------------------------------------------------
    // Hook: reject — trigger insurance claim payout
    // -------------------------------------------------------------------------

    /**
     * @notice Job rejected. Pay coverage amount to client from insurer treasury.
     *         Client already receives the escrow refund from ACPMinimal;
     *         this hook adds the insurance coverage on top.
     */
    function postReject(uint256 jobId, bytes32) external override onlyACP {
        Policy storage p = policies[jobId];
        if (!p.active) return;
        if (p.claimed) revert PolicyAlreadyClaimed();
        p.active = false;
        p.claimed = true;
        (,address client,,,,,,,, ) = _getJob(jobId);
        // Insurer treasury must have approved this hook to transfer coverage.
        // In production, the hook contract itself would hold a reserve fund.
        token.safeTransferFrom(insurerTreasury, client, p.coverage);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _getJob(uint256 jobId) internal view returns (
        uint256, address, address, address, address, string memory, uint256, uint256, uint8, bool
    ) {
        (bool ok, bytes memory data) = acpMinimal.staticcall(
            abi.encodeWithSignature("getJob(uint256)", jobId)
        );
        require(ok, "getJob failed");
        return abi.decode(data, (uint256, address, address, address, address, string, uint256, uint256, uint8, bool));
    }
}
