// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ReactiveShieldHook} from "../../src/ReactiveShieldHook.sol";

contract TestReactiveShieldHook is ReactiveShieldHook {
    uint160 public mockPrice;

    constructor(IPoolManager manager, address callbackProxy, address reactiveSender, uint256 epochLength)
        ReactiveShieldHook(manager, callbackProxy, reactiveSender, epochLength)
    {}

    function setMockPrice(uint160 price) external {
        mockPrice = price;
    }

    function validateHookAddress(BaseHook) internal pure override {}

    function _currentSqrtPrice(PoolId) internal view override returns (uint160) {
        return mockPrice;
    }
}

