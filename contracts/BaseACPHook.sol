// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IACPHook.sol";

/**
 * @title BaseACPHook
 * @dev Abstract base contract for ERC-ACP-Minimal hooks. All hook functions are
 *      no-ops by default. Inherit and override only the functions you need.
 *
 *      Example:
 *          contract MyHook is BaseACPHook {
 *              function postFund(uint256 jobId, bytes calldata optParams) external override {
 *                  // custom logic after fund
 *              }
 *          }
 */
abstract contract BaseACPHook is IACPHook {
    // setBudget
    function preSetBudget(uint256, bytes calldata) external virtual override {}
    function postSetBudget(uint256, bytes calldata) external virtual override {}

    // setProvider
    function preSetProvider(uint256, address, bytes calldata) external virtual override {}
    function postSetProvider(uint256, address, bytes calldata) external virtual override {}

    // fund
    function preFund(uint256, bytes calldata) external virtual override {}
    function postFund(uint256, bytes calldata) external virtual override {}

    // complete
    function preComplete(uint256, bytes32) external virtual override {}
    function postComplete(uint256, bytes32) external virtual override {}

    // reject
    function preReject(uint256, bytes32) external virtual override {}
    function postReject(uint256, bytes32) external virtual override {}
}
