// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {DemoERC20} from "../src/demo/DemoERC20.sol";
import {ReactiveShieldDemoHook} from "../src/demo/ReactiveShieldDemoHook.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract MockAavePool {
    DemoERC20 public immutable aToken;

    constructor(DemoERC20 aToken_) {
        aToken = aToken_;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        DemoERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        DemoERC20(asset).transfer(to, amount);
        return amount;
    }
}

contract TestReactiveShieldDemoHook is ReactiveShieldDemoHook {
    constructor(IPoolManager manager, address callbackProxy_, address reactiveSender_, uint256 epochLength_)
        ReactiveShieldDemoHook(manager, callbackProxy_, reactiveSender_, epochLength_)
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract AdapterAndDemoTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;

    event PriceDeviation(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 timestamp, uint256 insuredLPCount);

    function testDemoERC20MintApproveTransferAndAllowanceModes() external {
        DemoERC20 token = new DemoERC20("Demo", "D", 18);
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address spender = address(0x5157);

        token.mint(alice, 100 ether);
        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.decimals(), 18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);

        vm.prank(alice);
        assertTrue(token.approve(spender, 20 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 5 ether));
        assertEq(token.allowance(alice, spender), 15 ether);

        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, bob, 5 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);

        address underapproved = address(0xBAD);
        vm.prank(alice);
        token.approve(underapproved, 1);
        vm.prank(underapproved);
        vm.expectRevert(bytes("DemoERC20: allowance"));
        token.transferFrom(alice, bob, 2);

        vm.prank(alice);
        vm.expectRevert(bytes("DemoERC20: balance"));
        token.transfer(bob, 2 ** 200);
    }

    function testAaveAdapterDepositWithdrawBalanceAndHarvest() external {
        DemoERC20 asset = new DemoERC20("Asset", "AST", 18);
        DemoERC20 aToken = new DemoERC20("AAsset", "aAST", 18);
        MockAavePool pool = new MockAavePool(aToken);
        AaveV3Adapter adapter = new AaveV3Adapter(address(pool), address(aToken));
        address recipient = address(0xBEEF);

        asset.mint(address(adapter), 1_000 ether);
        asset.mint(address(pool), 1_000 ether);

        adapter.deposit(address(asset), 100 ether, address(adapter));
        assertEq(adapter.currentBalance(address(adapter)), 100 ether);

        assertEq(adapter.withdraw(address(asset), 40 ether, recipient), 40 ether);
        assertEq(asset.balanceOf(recipient), 40 ether);

        assertEq(adapter.harvestYield(address(asset), 100 ether, recipient), 0);
        aToken.mint(address(adapter), 25 ether);
        uint256 before = asset.balanceOf(recipient);
        assertEq(adapter.harvestYield(address(asset), 100 ether, recipient), 25 ether);
        assertEq(asset.balanceOf(recipient) - before, 25 ether);
    }

    function testDemoHookEmitsPriceDeviation() external {
        MockPoolManager manager = new MockPoolManager();
        DemoERC20 token = new DemoERC20("Demo", "D", 18);
        TestReactiveShieldDemoHook hook =
            new TestReactiveShieldDemoHook(manager.asPoolManager(), address(0xCA11BAC), address(this), 20);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        bytes32 poolId = PoolId.unwrap(PoolIdLibrary.toId(key));

        vm.expectEmit(true, false, false, true, address(hook));
        emit PriceDeviation(poolId, Q96, block.timestamp, 0);
        hook.emitDemoPriceDeviation(poolId, Q96);
    }
}
