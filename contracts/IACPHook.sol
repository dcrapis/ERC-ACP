// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IACPHook
 * @dev Interface for ERC-ACP-Minimal hook contracts. Implementations receive
 *      before/after callbacks on core job functions. Deploy a contract that
 *      implements this interface and pass its address to createJob.
 *
 *      Each hook function MAY revert to block the action (before hooks) or
 *      roll back the transaction (after hooks).
 *
 *      Use BaseACPHook for a no-op base that you can selectively override.
 */
interface IACPHook {
    /// @dev Called before setBudget executes. Seller commits transfer params here.
    function preSetBudget(uint256 jobId, bytes calldata optParams) external;

    /// @dev Called after setBudget executes. Hook may store commitment confirmation.
    function postSetBudget(uint256 jobId, bytes calldata optParams) external;

    /// @dev Called before setProvider executes. Hook may validate provider (e.g. auction winner check).
    function preSetProvider(uint256 jobId, address provider, bytes calldata optParams) external;

    /// @dev Called after setProvider executes. Hook may finalize selection logic (e.g. close auction).
    function postSetProvider(uint256 jobId, address provider, bytes calldata optParams) external;

    /// @dev Called before fund executes. Hook may validate buyer intent against seller's committed params.
    function preFund(uint256 jobId, bytes calldata optParams) external;

    /// @dev Called after fund executes. Hook may execute side effects (e.g. atomic token transfer, insurance policy registration).
    function postFund(uint256 jobId, bytes calldata optParams) external;

    /// @dev Called before complete executes. Hook may run pre-completion checks (e.g. insurer sign-off).
    function preComplete(uint256 jobId, bytes32 reason) external;

    /// @dev Called after complete executes. Hook may trigger post-completion logic (e.g. close insurance policy).
    function postComplete(uint256 jobId, bytes32 reason) external;

    /// @dev Called before reject executes. Hook may run pre-rejection checks.
    function preReject(uint256 jobId, bytes32 reason) external;

    /// @dev Called after reject executes. Hook may trigger post-rejection logic (e.g. insurance claim payout).
    function postReject(uint256 jobId, bytes32 reason) external;
}
