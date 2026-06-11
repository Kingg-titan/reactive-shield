// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILComputer} from "../src/ILComputer.sol";
import {ReactiveShieldHook} from "../src/ReactiveShieldHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {TestReactiveShieldHook} from "./mocks/TestReactiveShieldHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

contract MockCallbackProxy {
    mapping(address => uint256) public debt;

    function setDebt(address account, uint256 amount) external {
        debt[account] = amount;
    }

    receive() external payable {
        debt[msg.sender] = 0;
    }
}

contract RevertingCallbackProxy {
    function debt(address) external pure returns (uint256) {
        revert("debt unavailable");
    }

    receive() external payable {
        revert("cannot receive");
    }
}

contract RevertingReceiveCallbackProxy {
    mapping(address => uint256) public debt;

    function setDebt(address account, uint256 amount) external {
        debt[account] = amount;
    }

    receive() external payable {
        revert("cannot receive");
    }
}

contract BadERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract PoolManagerPriceHook is ReactiveShieldHook {
    constructor(IPoolManager manager, address callbackProxy, address reactiveSender, uint256 epochLength)
        ReactiveShieldHook(manager, callbackProxy, reactiveSender, epochLength)
    {}

    function exposedCurrentSqrtPrice(PoolId poolId) external view returns (uint160) {
        return _currentSqrtPrice(poolId);
    }

    function validateHookAddress(BaseHook) internal pure override {}
}

contract ReactiveShieldHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant SQRT_2_X96 = 112_045_541_949_572_279_837_463_876_454;
    uint256 internal constant EPOCH = 20;

    bytes32 internal constant POOL_ID = keccak256("ETH/USDC ReactiveShield");
    address internal lp = address(0xA11CE);
    address internal callbackProxy = address(0xCA11BAC);
    address internal reactiveSender = address(0xBEEF);

    MockPoolManager internal manager;
    MockERC20 internal usdc;
    TestReactiveShieldHook internal hook;

    function setUp() external {
        manager = new MockPoolManager();
        usdc = new MockERC20("Mock USDC", "mUSDC", 18);
        hook = new TestReactiveShieldHook(manager.asPoolManager(), callbackProxy, reactiveSender, EPOCH);
        hook.setMockPrice(Q96);

        usdc.mint(lp, 100_000 ether);
        usdc.mint(address(this), 100_000 ether);

        vm.prank(lp);
        usdc.approve(address(hook), type(uint256).max);
        usdc.approve(address(hook), type(uint256).max);
    }

    function testEnrollmentCollectsPremiumAndTracksLP() external {
        vm.prank(lp);
        uint256 premium = hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 500);

        assertEq(premium, 50 ether);
        assertEq(usdc.balanceOf(address(hook)), 50 ether);
        assertEq(hook.insuredLPCount(POOL_ID), 1);

        (bool active, uint160 entryPrice, uint256 entryLiquidity,,,,,, uint256 maxCoverageAmount) =
            hook.positions(POOL_ID, lp);
        assertTrue(active);
        assertEq(entryPrice, Q96);
        assertEq(entryLiquidity, 10_000 ether);
        assertEq(maxCoverageAmount, 1_000 ether);
    }

    function testThresholdOutOfRangeReverts() external {
        vm.prank(lp);
        vm.expectRevert(ReactiveShieldHook.ThresholdOutOfRange.selector);
        hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 199);

        vm.prank(lp);
        vm.expectRevert(ReactiveShieldHook.ThresholdOutOfRange.selector);
        hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 2_001);
    }

    function testConfigurePoolSetsDefaultsAndRejectsTokenMutation() external {
        bytes32 poolId = keccak256("configured pool");

        vm.expectEmit(true, false, false, true, address(hook));
        emit ReactiveShieldHook.ReserveStateChanged(poolId, ReactiveShieldHook.ReserveState.DEPLETED);
        hook.configurePool(poolId, address(usdc), 0, Q96);

        (address token1,,,,, uint256 target, uint256 feeBps, ReactiveShieldHook.ReserveState state, uint160 price) =
            hook.poolState(poolId);

        assertEq(token1, address(usdc));
        assertEq(target, 1);
        assertEq(feeBps, hook.DEPLETED_FEE_DIVERSION_BPS());
        assertEq(uint8(state), uint8(ReactiveShieldHook.ReserveState.DEPLETED));
        assertEq(price, Q96);

        hook.configurePool(poolId, address(usdc), 123 ether, 0);
        vm.expectRevert(ReactiveShieldHook.InvalidPool.selector);
        hook.configurePool(poolId, address(0xBAD), 123 ether, Q96);
    }

    function testHookPermissionsAndPoolManagerPriceRead() external {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterAddLiquidity);
        assertTrue(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeSwap);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);

        PoolManagerPriceHook priceHook =
            new PoolManagerPriceHook(manager.asPoolManager(), callbackProxy, reactiveSender, EPOCH);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: priceHook
        });
        PoolId poolId = key.toId();
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));

        manager.setExtsload(slot, bytes32(uint256(Q96)));
        assertEq(priceHook.exposedCurrentSqrtPrice(poolId), Q96);
    }

    function testEnrollmentRejectsInvalidArgumentsAndTokenMismatch() external {
        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.enrollPosition(POOL_ID, address(usdc), address(0), Q96, 10_000 ether, 500);

        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.enrollPosition(POOL_ID, address(0), lp, Q96, 10_000 ether, 500);

        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.enrollPosition(POOL_ID, address(usdc), lp, 0, 10_000 ether, 500);

        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 0, 500);

        hook.configurePool(POOL_ID, address(usdc), 10_000 ether, Q96);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        vm.expectRevert(ReactiveShieldHook.InvalidPool.selector);
        hook.enrollPosition(POOL_ID, address(other), lp, Q96, 10_000 ether, 500);
    }

    function testPermissionlessSettlementPaysModerateIL() external {
        _enrollAndFundHealthy();
        vm.warp(block.timestamp + EPOCH + 1);

        uint256 beforeBal = usdc.balanceOf(lp);
        hook.triggerSettlement(POOL_ID, SQRT_2_X96);
        uint256 afterBal = usdc.balanceOf(lp);

        assertApproxEqAbs(afterBal - beforeBal, 72 ether, 1 ether);
    }

    function testSettlementRejectsZeroPrice() external {
        _enrollAndFundHealthy();
        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.triggerSettlement(POOL_ID, 0);
    }

    function testReactiveCallbackRequiresProxyAndSender() external {
        _enrollAndFundHealthy();
        vm.warp(block.timestamp + EPOCH + 1);

        vm.expectRevert(ReactiveShieldHook.NotReactiveCallback.selector);
        hook.settlePoolFromReactive(reactiveSender, POOL_ID, SQRT_2_X96);

        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.InvalidReactiveSender.selector);
        hook.settlePoolFromReactive(address(0xBAD), POOL_ID, SQRT_2_X96);
    }

    function testReactiveCallbackPays() external {
        _enrollAndFundHealthy();
        vm.warp(block.timestamp + EPOCH + 1);

        uint256 beforeBal = usdc.balanceOf(lp);
        vm.prank(callbackProxy);
        hook.settlePoolFromReactive(reactiveSender, POOL_ID, SQRT_2_X96);
        assertGt(usdc.balanceOf(lp), beforeBal);
    }

    function testDoubleClaimSameEpochReverts() external {
        _enrollAndFundHealthy();
        vm.warp(block.timestamp + EPOCH + 1);

        hook.triggerSettlement(POOL_ID, SQRT_2_X96);
        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.AlreadyClaimedThisEpoch.selector);
        hook.triggerPayoutFromReactive(reactiveSender, POOL_ID, lp, 100);
    }

    function testReactivePayoutGuardsCoverageAndInactivePosition() external {
        _enrollAndFundHealthy();

        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.CoveragePeriodNotElapsed.selector);
        hook.triggerPayoutFromReactive(reactiveSender, POOL_ID, lp, 100);

        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.PositionNotActive.selector);
        hook.triggerPayoutFromReactive(reactiveSender, POOL_ID, address(0xDEAD), 100);
    }

    function testDepletedReserveBlocksPayout() external {
        vm.prank(lp);
        hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 500);
        vm.warp(block.timestamp + EPOCH + 1);

        vm.expectRevert(ReactiveShieldHook.ReserveDepleted.selector);
        hook.triggerSettlement(POOL_ID, SQRT_2_X96);
    }

    function testPayoutNeverExceedsCoverageCap() external {
        _enrollAndFundHealthy();
        vm.warp(block.timestamp + EPOCH + 1);

        uint256 beforeBal = usdc.balanceOf(lp);
        hook.triggerSettlement(POOL_ID, Q96 * 2);
        assertEq(usdc.balanceOf(lp) - beforeBal, 1_000 ether);
    }

    function testStressedReservePaysHalfAndUpdatesState() external {
        bytes32 poolId = keccak256("stressed payout");

        vm.prank(lp);
        hook.enrollPosition(poolId, address(usdc), lp, Q96, 10_000 ether, 500);
        hook.fundReserve(poolId, 2_000 ether);

        (,,,,,, uint256 feeBps, ReactiveShieldHook.ReserveState state,) = hook.poolState(poolId);
        assertEq(uint8(state), uint8(ReactiveShieldHook.ReserveState.STRESSED));
        assertEq(feeBps, hook.STRESSED_FEE_DIVERSION_BPS());

        vm.warp(block.timestamp + EPOCH + 1);
        uint256 beforeBal = usdc.balanceOf(lp);
        hook.triggerSettlement(poolId, SQRT_2_X96);

        assertApproxEqAbs(usdc.balanceOf(lp) - beforeBal, 36 ether, 1 ether);
    }

    function testMaxCoverageExceededWhenRemainingCoverageIsZero() external {
        _enrollAndFundHealthy();
        vm.warp(EPOCH + 2);
        hook.triggerSettlement(POOL_ID, Q96 * 2);

        vm.warp((EPOCH + 2) * 2);
        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.MaxCoverageExceeded.selector);
        hook.triggerPayoutFromReactive(reactiveSender, POOL_ID, lp, 100);
    }

    function testFundReserveGuardsAndTransferFailure() external {
        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        hook.fundReserve(POOL_ID, 0);

        vm.expectRevert(ReactiveShieldHook.InvalidPool.selector);
        hook.fundReserve(POOL_ID, 1 ether);

        bytes32 poolId = keccak256("bad token");
        BadERC20 bad = new BadERC20();
        hook.configurePool(poolId, address(bad), 100 ether, Q96);

        vm.expectRevert(ReactiveShieldHook.TransferFailed.selector);
        hook.fundReserve(poolId, 1 ether);
    }

    function testCallbackDebtCoveringAndFallbackBranches() external {
        MockCallbackProxy proxy = new MockCallbackProxy();
        TestReactiveShieldHook debtHook =
            new TestReactiveShieldHook(manager.asPoolManager(), address(proxy), reactiveSender, EPOCH);

        proxy.setDebt(address(debtHook), 0.01 ether);
        assertEq(debtHook.callbackDebt(), 0.01 ether);

        vm.expectRevert(ReactiveShieldHook.InvalidAmount.selector);
        debtHook.coverCallbackDebt();

        vm.deal(address(debtHook), 0.01 ether);
        vm.expectEmit(false, false, false, true, address(debtHook));
        emit ReactiveShieldHook.CallbackDebtCovered(0.01 ether);
        debtHook.coverCallbackDebt();
        assertEq(debtHook.callbackDebt(), 0);

        vm.expectEmit(false, false, false, true, address(debtHook));
        emit ReactiveShieldHook.CallbackDebtCovered(0);
        debtHook.coverCallbackDebt();

        TestReactiveShieldHook zeroProxyHook =
            new TestReactiveShieldHook(manager.asPoolManager(), address(0), reactiveSender, EPOCH);
        assertEq(zeroProxyHook.callbackDebt(), 0);

        RevertingCallbackProxy revertingProxy = new RevertingCallbackProxy();
        TestReactiveShieldHook revertingDebtHook =
            new TestReactiveShieldHook(manager.asPoolManager(), address(revertingProxy), reactiveSender, EPOCH);
        assertEq(revertingDebtHook.callbackDebt(), 0);

        RevertingReceiveCallbackProxy revertingReceive = new RevertingReceiveCallbackProxy();
        TestReactiveShieldHook failedCoverHook =
            new TestReactiveShieldHook(manager.asPoolManager(), address(revertingReceive), reactiveSender, EPOCH);
        revertingReceive.setDebt(address(failedCoverHook), 0.01 ether);
        vm.deal(address(failedCoverHook), 0.01 ether);
        vm.expectRevert(ReactiveShieldHook.TransferFailed.selector);
        failedCoverHook.coverCallbackDebt();
    }

    function testTriggerPayoutFromReactiveRejectsBadCallerAndSender() external {
        _enrollAndFundHealthy();
        vm.warp(EPOCH + 2);

        vm.expectRevert(ReactiveShieldHook.NotReactiveCallback.selector);
        hook.triggerPayoutFromReactive(reactiveSender, POOL_ID, lp, 100);

        vm.prank(callbackProxy);
        vm.expectRevert(ReactiveShieldHook.InvalidReactiveSender.selector);
        hook.triggerPayoutFromReactive(address(0xBAD), POOL_ID, lp, 100);
    }

    function testReserveCanBeNonDepletedButInsufficientForPayout() external {
        bytes32 poolId = keccak256("insufficient stressed reserve");
        hook.configurePool(poolId, address(usdc), 50_000 ether, Q96);

        vm.prank(lp);
        hook.enrollPosition(poolId, address(usdc), lp, Q96, 1_000_000 ether, 500);
        hook.fundReserve(poolId, 1_000 ether);

        (,,,,,, uint256 feeBps, ReactiveShieldHook.ReserveState state,) = hook.poolState(poolId);
        assertEq(uint8(state), uint8(ReactiveShieldHook.ReserveState.STRESSED));
        assertEq(feeBps, hook.STRESSED_FEE_DIVERSION_BPS());

        vm.warp(EPOCH + 2);
        vm.expectRevert(ReactiveShieldHook.ReserveDepleted.selector);
        hook.triggerSettlement(poolId, Q96 * 2);
    }

    function testHookAddLiquiditySwapAndRemoveLifecycle() external {
        PoolKey memory key = _poolKey();
        bytes32 poolId = PoolId.unwrap(key.toId());
        hook.setMockPrice(Q96);

        BalanceDelta delta = toBalanceDelta(0, -10_000 ether);
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: bytes32(0)});
        bytes memory enrollmentData = abi.encode(true, lp, uint256(500), uint256(10_000 ether));

        vm.prank(address(manager));
        (bytes4 addSelector, BalanceDelta hookDelta) =
            hook.afterAddLiquidity(lp, key, addParams, delta, BalanceDelta.wrap(0), enrollmentData);

        assertEq(addSelector, hook.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0);
        assertEq(hook.insuredLPCount(poolId), 1);

        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: SQRT_2_X96});

        vm.prank(address(manager));
        (bytes4 swapSelector, int128 hookDeltaSpecified) =
            hook.afterSwap(lp, key, swapParams, toBalanceDelta(0, -1_000 ether), abi.encode(SQRT_2_X96));

        assertEq(swapSelector, hook.afterSwap.selector);
        assertEq(hookDeltaSpecified, 0);

        (,, uint256 deposited, uint256 premiums,, uint256 target, uint256 feeBps,, uint160 lastPrice) =
            hook.poolState(poolId);
        assertEq(deposited, 0);
        assertEq(premiums, 50 ether);
        assertEq(target, 10_000 ether);
        assertEq(feeBps, hook.DEPLETED_FEE_DIVERSION_BPS());
        assertEq(lastPrice, SQRT_2_X96);

        hook.fundReserve(poolId, 5_000 ether);
        vm.warp(block.timestamp + EPOCH + 1);
        hook.setMockPrice(SQRT_2_X96);

        uint256 beforeBal = usdc.balanceOf(lp);
        vm.prank(address(manager));
        bytes4 removeSelector = hook.beforeRemoveLiquidity(lp, key, addParams, abi.encode(lp));

        assertEq(removeSelector, hook.beforeRemoveLiquidity.selector);
        assertGt(usdc.balanceOf(lp), beforeBal);
        assertEq(hook.insuredLPCount(poolId), 0);
    }

    function testHookAddLiquidityNoopPathsAndRemoveInactive() external {
        PoolKey memory key = _poolKey();
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: bytes32(0)});

        vm.prank(address(manager));
        hook.afterAddLiquidity(lp, key, params, toBalanceDelta(0, -1 ether), BalanceDelta.wrap(0), "");

        vm.prank(address(manager));
        hook.afterAddLiquidity(lp, key, params, toBalanceDelta(0, -1 ether), BalanceDelta.wrap(0), abi.encode(false, lp, uint256(500), uint256(1 ether)));

        vm.prank(address(manager));
        bytes4 selector = hook.beforeRemoveLiquidity(lp, key, params, "");

        assertEq(selector, hook.beforeRemoveLiquidity.selector);
    }

    function testInsuredLPListDeduplicatesAndSwapPopsOnRemoval() external {
        PoolKey memory key = _poolKey();
        bytes32 poolId = PoolId.unwrap(key.toId());
        address lp2 = address(0xB0B);
        usdc.mint(lp2, 100_000 ether);

        vm.prank(lp);
        hook.enrollPosition(poolId, address(usdc), lp, Q96, 10_000 ether, 500);
        vm.prank(lp);
        hook.enrollPosition(poolId, address(usdc), lp, Q96, 10_000 ether, 500);

        vm.startPrank(lp2);
        usdc.approve(address(hook), type(uint256).max);
        hook.enrollPosition(poolId, address(usdc), lp2, Q96, 10_000 ether, 500);
        vm.stopPrank();

        assertEq(hook.insuredLPCount(poolId), 2);
        address[] memory lps = hook.getInsuredLPs(poolId);
        assertEq(lps.length, 2);

        hook.fundReserve(poolId, 5_000 ether);
        vm.warp(block.timestamp + EPOCH + 1);
        hook.setMockPrice(Q96);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1 ether, salt: bytes32(0)});
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(lp, key, params, abi.encode(lp));

        assertEq(hook.insuredLPCount(poolId), 1);
        address[] memory remaining = hook.getInsuredLPs(poolId);
        assertEq(remaining[0], lp2);
    }

    function testFuzzPayoutCap(uint96 positionValue, uint16 threshold) external {
        uint256 value = bound(uint256(positionValue), 1_000 ether, 50_000 ether);
        threshold = uint16(bound(threshold, 200, 1_500));
        bytes32 poolId = keccak256(abi.encode(value, threshold));

        vm.prank(lp);
        uint256 premium = hook.enrollPosition(poolId, address(usdc), lp, Q96, value, threshold);
        usdc.approve(address(hook), type(uint256).max);
        hook.fundReserve(poolId, value);

        vm.warp(block.timestamp + EPOCH + 1);
        uint256 beforeBal = usdc.balanceOf(lp);
        hook.triggerSettlement(poolId, Q96 * 2);
        assertLe(usdc.balanceOf(lp) - beforeBal, premium * hook.MAX_COVERAGE_MULTIPLIER());
    }

    function _enrollAndFundHealthy() internal {
        vm.prank(lp);
        hook.enrollPosition(POOL_ID, address(usdc), lp, Q96, 10_000 ether, 500);
        hook.fundReserve(POOL_ID, 5_000 ether);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: hook
        });
    }
}
