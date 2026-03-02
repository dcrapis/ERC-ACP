// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseACPHook.sol";

/**
 * @title FundTransferHook
 * @notice Example ACP hook for atomic fund transfer jobs.
 *
 * USE CASE
 * --------
 * An agent's job is to move tokens on the client's behalf (e.g. a payment
 * agent, bridge agent, or payroll agent). The client funds the agent fee via
 * ACP escrow, while the hook atomically executes the side token transfer in
 * the same transaction — so either both succeed or both revert.
 *
 * FLOW (hook callbacks marked with →)
 * ----
 *  1. createJob(provider, evaluator, expiredAt, description, hook=this)
 *
 *  2. Client calls setBudget(jobId, agentFee, optParams: abi.encode(dest, transferAmount)):
 *     → _preSetBudget: decode optParams, store {dest, transferAmount} as commitment.
 *     → AgenticCommerceHooked: set job.budget = agentFee.
 *
 *  3. Client approves AgenticCommerceHooked for agentFee AND this hook for transferAmount.
 *     Client calls fund(jobId, ""):
 *     → _preFund: verify client has approved this hook for transferAmount.
 *     → AgenticCommerceHooked: pull agentFee from client into escrow, set Funded.
 *     → _postFund: pull transferAmount from client, forward to dest atomically.
 *
 *  4. Provider does work off-chain.
 *
 *  5. Provider calls submit(jobId, deliverable, "").
 *  6. Evaluator calls complete(jobId, reason, ""). Escrow released to provider.
 *
 * KEY PROPERTY: Atomicity. The client cannot fund the job without the side
 * transfer executing, and the side transfer cannot execute without the job
 * being funded. Both succeed or both revert.
 */
contract FundTransferHook is BaseACPHook {
    using SafeERC20 for IERC20;

    struct TransferCommitment {
        address dest;
        uint256 transferAmount;
    }

    IERC20 public immutable token;

    mapping(uint256 => TransferCommitment) public commitments;

    error CommitmentNotSet();
    error InsufficientAllowance();
    error ZeroAddress();
    error ZeroAmount();

    constructor(address token_, address acpContract_) BaseACPHook(acpContract_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
    }

    // -------------------------------------------------------------------------
    // Hook callbacks (called by AgenticCommerceHooked via beforeAction/afterAction)
    // -------------------------------------------------------------------------

    /// @dev Store transfer commitment from setBudget optParams.
    function _preSetBudget(uint256 jobId, uint256, bytes memory optParams) internal override {
        if (optParams.length == 0) return;
        (address dest, uint256 transferAmount) = abi.decode(optParams, (address, uint256));
        if (dest == address(0)) revert ZeroAddress();
        if (transferAmount == 0) revert ZeroAmount();
        commitments[jobId] = TransferCommitment({
            dest: dest,
            transferAmount: transferAmount
        });
    }

    /// @dev Verify client has approved this hook for the committed transferAmount.
    function _preFund(uint256 jobId, bytes memory) internal override {
        TransferCommitment memory c = commitments[jobId];
        if (c.dest == address(0)) revert CommitmentNotSet();
        address client = _getJobClient(jobId);
        uint256 allowance = token.allowance(client, address(this));
        if (allowance < c.transferAmount) revert InsufficientAllowance();
    }

    /// @dev Execute the side transfer atomically after escrow is locked.
    function _postFund(uint256 jobId, bytes memory) internal override {
        TransferCommitment memory c = commitments[jobId];
        if (c.dest == address(0)) revert CommitmentNotSet();
        address client = _getJobClient(jobId);
        delete commitments[jobId]; // prevent replay
        token.safeTransferFrom(client, c.dest, c.transferAmount);
    }
}
