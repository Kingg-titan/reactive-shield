// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IReactiveCallbackProxy {
    function debt(address payer) external view returns (uint256);
}

