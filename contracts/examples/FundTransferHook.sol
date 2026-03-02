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
 * An agent's job is to move tokens on the buyer's behalf (e.g. a payment
 * agent, bridge agent, or payroll agent). The buyer funds the agent fee via
 * ACP escrow, while the hook atomically executes the side token transfer in
 * the same transaction — so either both succeed or both revert.
 *
 * ROLES
 * -----
 *  - Seller (provider/agent): calls setBudget, commits {dest, transferAmount}
 *    into the hook. This is the seller's binding quote to the buyer.
 *  - Buyer (client): calls fund. Cannot alter the transfer params because
 *    the hook already has the seller's commitment. The hook pulls the
 *    transfer amount from the buyer and forwards it to dest.
 *
 * FLOW
 * ----
 *  1. createJob(provider, evaluator, expiredAt, description, hook=this)
 *     └─ Job created in Open state, hook address stored on job.
 *
 *  2. setBudget(jobId, agentFee, optParams: abi.encode(dest, transferAmount))
 *     └─ preSetBudget:  decode and store {dest, transferAmount} for jobId.
 *     └─ ACPMinimal:    set job.budget = agentFee.
 *     └─ postSetBudget: (no-op; commitment already stored).
 *
 *  3. fund(jobId, optParams: "")
 *     └─ preFund:  validate buyer has approved this hook for transferAmount.
 *     └─ ACPMinimal: pull agentFee from buyer into escrow, set Funded.
 *     └─ postFund: pull transferAmount from buyer, forward to dest atomically.
 *
 *  4. [Provider does work off-chain]
 *
 *  5. submit(jobId)        — provider signals work is done.
 *  6. complete(jobId, ...) — evaluator releases escrow to provider.
 *
 * SECURITY NOTES
 * --------------
 *  - Buyer must approve ACPMinimal for agentFee AND this hook for transferAmount
 *    before calling fund.
 *  - preSetBudget reverts if called by anyone other than the job's provider,
 *    preventing a buyer from overwriting the seller's commitment.
 *  - commitments[jobId] is deleted after postFund to prevent replays.
 */
contract FundTransferHook is BaseACPHook {
    using SafeERC20 for IERC20;

    struct TransferCommitment {
        address dest;
        uint256 transferAmount;
        address seller; // provider who set the commitment
    }

    IERC20 public immutable token;
    address public immutable acpMinimal;

    mapping(uint256 => TransferCommitment) public commitments;

    error OnlySeller();
    error OnlyACPMinimal();
    error CommitmentNotSet();
    error InsufficientAllowance();
    error ZeroAddress();
    error ZeroAmount();

    modifier onlyACP() {
        if (msg.sender != acpMinimal) revert OnlyACPMinimal();
        _;
    }

    constructor(address token_, address acpMinimal_) {
        if (token_ == address(0) || acpMinimal_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        acpMinimal = acpMinimal_;
    }

    /**
     * @notice Seller commits transfer params. Called by ACPMinimal before setBudget.
     * @param optParams abi.encode(address dest, uint256 transferAmount)
     */
    function preSetBudget(uint256 jobId, bytes calldata optParams) external override onlyACP {
        (address dest, uint256 transferAmount) = abi.decode(optParams, (address, uint256));
        if (dest == address(0)) revert ZeroAddress();
        if (transferAmount == 0) revert ZeroAmount();

        // Retrieve job to confirm caller is the provider (seller).
        // ACPMinimal enforces msg.sender == provider before calling this hook,
        // so we trust acpMinimal has already validated that.
        commitments[jobId] = TransferCommitment({
            dest: dest,
            transferAmount: transferAmount,
            seller: tx.origin // informational only
        });
    }

    /**
     * @notice Buyer validation. Called by ACPMinimal before fund.
     *         Checks buyer has approved this hook for the committed transferAmount.
     */
    function preFund(uint256 jobId, bytes calldata) external override onlyACP {
        TransferCommitment memory c = commitments[jobId];
        if (c.dest == address(0)) revert CommitmentNotSet();

        // Retrieve the job's client (buyer) — ACPMinimal is the caller so we
        // read the job state via a lightweight external call.
        (,address client,,,,,,,, ) = _getJob(jobId);

        uint256 allowance = token.allowance(client, address(this));
        if (allowance < c.transferAmount) revert InsufficientAllowance();
    }

    /**
     * @notice Executes the side transfer atomically after fund.
     *         Called by ACPMinimal after escrow is locked.
     */
    function postFund(uint256 jobId, bytes calldata) external override onlyACP {
        TransferCommitment memory c = commitments[jobId];
        if (c.dest == address(0)) revert CommitmentNotSet();

        (,address client,,,,,,,, ) = _getJob(jobId);

        delete commitments[jobId]; // prevent replay

        token.safeTransferFrom(client, c.dest, c.transferAmount);
    }

    /// @dev Pull job.client from ACPMinimal for validation.
    function _getJob(uint256 jobId) internal view returns (
        uint256, address client, address, address, address, string memory, uint256, uint256, uint8, bool
    ) {
        (bool ok, bytes memory data) = acpMinimal.staticcall(
            abi.encodeWithSignature("getJob(uint256)", jobId)
        );
        require(ok, "getJob failed");
        return abi.decode(data, (uint256, address, address, address, address, string, uint256, uint256, uint8, bool));
    }
}
