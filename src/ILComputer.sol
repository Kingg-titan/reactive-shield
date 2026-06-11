// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library ILComputer {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant BPS = 10_000;

    error InvalidPrice();

    function computeILBps(uint160 entryPrice, uint160 currentPrice) internal pure returns (uint256 ilBps) {
        if (entryPrice == 0 || currentPrice == 0) revert InvalidPrice();

        uint256 sqrtRatioX96 = FullMath.mulDiv(uint256(currentPrice), Q96, uint256(entryPrice));
        uint256 priceRatioX96 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, Q96);
        uint256 denominator = Q96 + priceRatioX96;
        uint256 numerator = 2 * sqrtRatioX96;

        if (numerator >= denominator) return 0;
        ilBps = FullMath.mulDiv(denominator - numerator, BPS, denominator);
        if (ilBps > BPS) return BPS;
    }

    function excessILBps(uint160 entryPrice, uint160 currentPrice, uint256 thresholdBps)
        internal
        pure
        returns (uint256 ilBps, uint256 excessBps)
    {
        ilBps = computeILBps(entryPrice, currentPrice);
        excessBps = ilBps > thresholdBps ? ilBps - thresholdBps : 0;
    }
}

