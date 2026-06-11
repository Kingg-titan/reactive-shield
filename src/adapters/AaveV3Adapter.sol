// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface IAaveV3PoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract AaveV3Adapter {
    IAaveV3PoolLike public immutable AAVE_POOL;
    address public immutable A_TOKEN;

    constructor(address aavePool, address aToken) {
        AAVE_POOL = IAaveV3PoolLike(aavePool);
        A_TOKEN = aToken;
    }

    function deposit(address token, uint256 amount, address onBehalfOf) external {
        IERC20Minimal(token).approve(address(AAVE_POOL), amount);
        AAVE_POOL.supply(token, amount, onBehalfOf, 0);
    }

    function withdraw(address token, uint256 amount, address recipient) external returns (uint256) {
        return AAVE_POOL.withdraw(token, amount, recipient);
    }

    function currentBalance(address account) external view returns (uint256) {
        return IERC20Minimal(A_TOKEN).balanceOf(account);
    }

    function harvestYield(address token, uint256 depositedPrincipal, address recipient)
        external
        returns (uint256 yieldAmount)
    {
        uint256 currentBal = IERC20Minimal(A_TOKEN).balanceOf(address(this));
        if (currentBal <= depositedPrincipal) return 0;
        yieldAmount = currentBal - depositedPrincipal;
        AAVE_POOL.withdraw(token, yieldAmount, recipient);
    }
}

