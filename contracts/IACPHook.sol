// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IACPHook
 * @dev Interface for ERC-ACP-Minimal hook contracts. Implementations receive
 *      before/after callbacks on core job functions. The `selector` identifies
 *      which core function is being called (e.g. ACPMinimal.fund.selector).
 */
interface IACPHook {
    /// @dev Called before the core function executes. MAY revert to block the action.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata optParams) external;

    /// @dev Called after the core function completes. MAY revert to roll back the transaction.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata optParams) external;
}
