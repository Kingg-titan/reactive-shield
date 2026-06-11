// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ReactiveShieldRSC} from "../src/rsc/ReactiveShieldRSC.sol";

contract MockReactiveSystemContract {
    event Subscribed(uint256 chainId, address indexed target, uint256 topic0);

    function subscribe(
        uint256 chainId,
        address target,
        uint256 topic0,
        uint256,
        uint256,
        uint256
    ) external {
        emit Subscribed(chainId, target, topic0);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract ReactiveShieldRSCTest is Test {
    uint256 internal constant ORIGIN_CHAIN = 1301;
    uint256 internal constant DESTINATION_CHAIN = 1301;
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    address internal constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    address internal hook = address(0xC890A568b2BCedF0dBF80b40e0D1D31CBfac0640);
    bytes32 internal poolId = keccak256("ReactiveShield RSC test pool");

    function testConstructorConfiguresConstants() external {
        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        assertEq(rsc.ORIGIN_CHAIN_ID(), ORIGIN_CHAIN);
        assertEq(rsc.DESTINATION_CHAIN_ID(), DESTINATION_CHAIN);
        assertEq(rsc.HOOK_ADDRESS(), hook);
        assertEq(rsc.CALLBACK_SENDER(), address(this));
        assertEq(rsc.PRICE_DEVIATION_TOPIC0(), uint256(keccak256("PriceDeviation(bytes32,uint160,uint256,uint256)")));
        assertTrue(rsc.subscriptionConfigured());
    }

    function testConfigureSubscriptionRevertsOnVmCopy() external {
        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        vm.expectRevert(bytes("Reactive Network only"));
        rsc.configureSubscription();
    }

    function testConfigureSubscriptionOnReactiveNetworkCopy() external {
        MockReactiveSystemContract system = new MockReactiveSystemContract();
        vm.etch(SYSTEM_CONTRACT, address(system).code);

        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        assertTrue(rsc.subscriptionConfigured());

        vm.expectEmit(true, false, false, true, address(rsc));
        emit ReactiveShieldRSC.SubscriptionConfigured(ORIGIN_CHAIN, hook, rsc.PRICE_DEVIATION_TOPIC0());
        rsc.configureSubscription();

        IReactive.LogRecord memory record = _record(hook, rsc.PRICE_DEVIATION_TOPIC0(), 1);
        vm.expectRevert(bytes("VM only"));
        rsc.react(record);
    }

    function testReactIgnoresMismatchedLog() external {
        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        IReactive.LogRecord memory record = _record(address(0xBAD), 1, 1);
        rsc.react(record);
    }

    function testReactIgnoresNoInsuredLPs() external {
        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        IReactive.LogRecord memory record = _record(hook, rsc.PRICE_DEVIATION_TOPIC0(), 0);

        vm.expectEmit(true, false, false, true, address(rsc));
        emit ReactiveShieldRSC.PriceDeviationIgnored(poolId, "NO_INSURED_LPS");
        rsc.react(record);
    }

    function testReactQueuesCallbackAndRejectsDuplicate() external {
        ReactiveShieldRSC rsc = new ReactiveShieldRSC(ORIGIN_CHAIN, DESTINATION_CHAIN, hook);
        IReactive.LogRecord memory record = _record(hook, rsc.PRICE_DEVIATION_TOPIC0(), 1);

        bytes memory payload =
            abi.encodeWithSignature("settlePoolFromReactive(address,bytes32,uint160)", address(this), poolId, Q96);

        vm.expectEmit(true, false, false, true, address(rsc));
        emit ReactiveShieldRSC.SettlementQueued(poolId, Q96, block.timestamp);
        vm.expectEmit(true, true, true, true, address(rsc));
        emit IReactive.Callback(DESTINATION_CHAIN, hook, rsc.CALLBACK_GAS_LIMIT(), payload);
        rsc.react(record);

        bytes32 queueKey = keccak256(abi.encode(poolId, Q96, block.timestamp));
        assertTrue(rsc.settlementQueued(queueKey));

        vm.expectEmit(true, false, false, true, address(rsc));
        emit ReactiveShieldRSC.PriceDeviationIgnored(poolId, "ALREADY_QUEUED");
        rsc.react(record);
    }

    function _record(address emitter, uint256 topic0, uint256 insuredLPCount)
        internal
        view
        returns (IReactive.LogRecord memory record)
    {
        record.chain_id = ORIGIN_CHAIN;
        record._contract = emitter;
        record.topic_0 = topic0;
        record.topic_1 = uint256(poolId);
        record.data = abi.encode(Q96, block.timestamp, insuredLPCount);
    }
}
