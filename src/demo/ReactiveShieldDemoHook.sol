// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ReactiveShieldHook} from "../ReactiveShieldHook.sol";

contract ReactiveShieldDemoHook is ReactiveShieldHook {
    constructor(IPoolManager manager, address callbackProxy_, address reactiveSender_, uint256 epochLength_)
        ReactiveShieldHook(manager, callbackProxy_, reactiveSender_, epochLength_)
    {}

    function emitDemoPriceDeviation(bytes32 poolId, uint160 sqrtPriceX96) external {
        poolState[poolId].lastSqrtPriceX96 = sqrtPriceX96;
        emit PriceDeviation(poolId, sqrtPriceX96, block.timestamp, this.insuredLPCount(poolId));
    }
}
