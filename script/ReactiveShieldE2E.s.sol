// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockPoolManager} from "../test/mocks/MockPoolManager.sol";
import {TestReactiveShieldHook} from "../test/mocks/TestReactiveShieldHook.sol";

contract ReactiveShieldE2E is Script {
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant SQRT_2_X96 = 112_045_541_949_572_279_837_463_876_454;
    bytes32 internal constant POOL_ID = keccak256("ReactiveShield demo pool");

    function run() external {
        address lp = vm.addr(1);
        address callbackProxy = vm.addr(2);
        address reactiveSender = vm.addr(3);
        address funder = vm.addr(4);

        console2.log("ReactiveShield local e2e demo");
        console2.log("Phase 1: deploy local PoolManager mock, USDC mock, and hook harness");
        MockPoolManager manager = new MockPoolManager();
        MockERC20 usdc = new MockERC20("Demo USDC", "dUSDC", 18);
        TestReactiveShieldHook hook = new TestReactiveShieldHook(manager.asPoolManager(), callbackProxy, reactiveSender, 20);
        hook.setMockPrice(Q96);
        console2.log("Hook:", address(hook));
        console2.log("Token1:", address(usdc));

        console2.log("Phase 2: mint demo funds, approve hook, enroll insured LP");
        usdc.mint(lp, 100_000 ether);
        vm.startPrank(lp);
        usdc.approve(address(hook), type(uint256).max);
        uint256 premium = hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 500);
        vm.stopPrank();
        console2.log("Premium paid:", premium);

        console2.log("Phase 3: seed reserve so the pool is healthy");
        usdc.mint(funder, 100_000 ether);
        vm.startPrank(funder);
        usdc.approve(address(hook), type(uint256).max);
        hook.fundReserve(POOL_ID, 5_000 ether);
        vm.stopPrank();
        console2.log("Reserve funded");

        console2.log("Phase 4: simulate epoch passage and Reactive observed price deviation");
        vm.warp(block.timestamp + 21);
        uint256 beforeBal = usdc.balanceOf(lp);

        console2.log("Phase 5: Reactive callback proxy calls settlePoolFromReactive(sender,poolId,price)");
        vm.prank(callbackProxy);
        hook.settlePoolFromReactive(reactiveSender, POOL_ID, SQRT_2_X96);
        uint256 payout = usdc.balanceOf(lp) - beforeBal;

        console2.log("Phase 6: payout proof");
        console2.log("Insurance payout:", payout);
        console2.log("Expected: about 72 dUSDC for 2x price move minus 5% deductible");
        console2.log("Local proof complete");
    }
}
