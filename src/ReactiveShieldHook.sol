// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILComputer} from "./ILComputer.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IReactiveCallbackProxy} from "./interfaces/IReactiveCallbackProxy.sol";

contract ReactiveShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant NORMAL_FEE_DIVERSION_BPS = 1_000;
    uint256 public constant STRESSED_FEE_DIVERSION_BPS = 2_000;
    uint256 public constant DEPLETED_FEE_DIVERSION_BPS = 3_000;
    uint256 public constant DEFAULT_PREMIUM_BPS = 50;
    uint256 public constant MIN_THRESHOLD_BPS = 200;
    uint256 public constant MAX_THRESHOLD_BPS = 2_000;
    uint256 public constant MAX_COVERAGE_MULTIPLIER = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_EPOCH_LENGTH = 7 days;

    address public immutable callbackProxy;
    address public immutable reactiveSender;
    uint256 public immutable epochLength;

    enum ReserveState {
        HEALTHY,
        STRESSED,
        DEPLETED
    }

    struct InsuredPosition {
        bool active;
        uint160 entryPrice;
        uint256 entryLiquidity;
        uint256 depositTimestamp;
        uint256 thresholdBps;
        uint256 premiumPaid;
        uint256 totalPayoutsReceived;
        uint256 lastClaimEpoch;
        uint256 maxCoverageAmount;
    }

    struct PoolInsuranceState {
        address token1;
        uint256 reserveBalance;
        uint256 aaveDepositedBalance;
        uint256 totalPremiumsCollected;
        uint256 totalPayoutsSettled;
        uint256 maxReserveTarget;
        uint256 feeDiversionBps;
        ReserveState state;
        uint160 lastSqrtPriceX96;
    }

    mapping(bytes32 => PoolInsuranceState) public poolState;
    mapping(bytes32 => mapping(address => InsuredPosition)) public positions;
    mapping(bytes32 => address[]) private insuredLPs;
    mapping(bytes32 => mapping(address => uint256)) private insuredIndexPlusOne;

    event PriceDeviation(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 timestamp, uint256 insuredLPCount);
    event InsurancePaid(bytes32 indexed poolId, address indexed lp, uint256 amount, uint256 ilBps);
    event PremiumCollected(bytes32 indexed poolId, address indexed lp, uint256 amount);
    event ReserveStateChanged(bytes32 indexed poolId, ReserveState newState);
    event ReserveFunded(bytes32 indexed poolId, address indexed funder, uint256 amount);
    event CallbackDebtCovered(uint256 amount);

    error NotReactiveCallback();
    error InvalidReactiveSender();
    error CoveragePeriodNotElapsed();
    error AlreadyClaimedThisEpoch();
    error ReserveDepleted();
    error ThresholdOutOfRange();
    error PositionNotActive();
    error MaxCoverageExceeded();
    error InvalidAmount();
    error InvalidPool();
    error TransferFailed();

    constructor(IPoolManager manager, address callbackProxy_, address reactiveSender_, uint256 epochLength_)
        BaseHook(manager)
    {
        callbackProxy = callbackProxy_;
        reactiveSender = reactiveSender_;
        epochLength = epochLength_ == 0 ? DEFAULT_EPOCH_LENGTH : epochLength_;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function configurePool(bytes32 poolId, address token1, uint256 maxReserveTarget, uint160 initialSqrtPriceX96)
        external
    {
        PoolInsuranceState storage state = poolState[poolId];
        if (state.token1 != address(0) && state.token1 != token1) revert InvalidPool();
        state.token1 = token1;
        state.maxReserveTarget = maxReserveTarget == 0 ? 1 : maxReserveTarget;
        state.feeDiversionBps = state.feeDiversionBps == 0 ? NORMAL_FEE_DIVERSION_BPS : state.feeDiversionBps;
        if (initialSqrtPriceX96 != 0) state.lastSqrtPriceX96 = initialSqrtPriceX96;
        _updateReserveState(poolId);
    }

    function fundReserve(bytes32 poolId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        address token = poolState[poolId].token1;
        if (token == address(0)) revert InvalidPool();
        _safeTransferFrom(token, msg.sender, address(this), amount);
        poolState[poolId].reserveBalance += amount;
        emit ReserveFunded(poolId, msg.sender, amount);
        _updateReserveState(poolId);
    }

    function enrollPosition(
        bytes32 poolId,
        address token1,
        address lp,
        uint160 entryPrice,
        uint256 positionValueToken1,
        uint256 thresholdBps
    ) external returns (uint256 premium) {
        premium = _enroll(poolId, token1, lp, entryPrice, positionValueToken1, thresholdBps, true);
    }

    function getInsuredLPs(bytes32 poolId) external view returns (address[] memory) {
        return insuredLPs[poolId];
    }

    function insuredLPCount(bytes32 poolId) external view returns (uint256) {
        return insuredLPs[poolId].length;
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochLength;
    }

    function callbackDebt() public view returns (uint256) {
        if (callbackProxy == address(0)) return 0;
        try IReactiveCallbackProxy(callbackProxy).debt(address(this)) returns (uint256 debt) {
            return debt;
        } catch {
            return 0;
        }
    }

    function coverCallbackDebt() external {
        uint256 debt = callbackDebt();
        if (debt == 0) {
            emit CallbackDebtCovered(0);
            return;
        }
        if (address(this).balance < debt) revert InvalidAmount();
        (bool ok,) = payable(callbackProxy).call{value: debt}("");
        if (!ok) revert TransferFailed();
        emit CallbackDebtCovered(debt);
    }

    function settlePoolFromReactive(address sender, bytes32 poolId, uint160 currentSqrtPriceX96) external {
        if (msg.sender != callbackProxy) revert NotReactiveCallback();
        if (sender != reactiveSender) revert InvalidReactiveSender();
        _settlePool(poolId, currentSqrtPriceX96);
    }

    function triggerPayoutFromReactive(address sender, bytes32 poolId, address lp, uint256 excessILBps) external {
        if (msg.sender != callbackProxy) revert NotReactiveCallback();
        if (sender != reactiveSender) revert InvalidReactiveSender();
        _processPayout(poolId, lp, excessILBps, 0);
    }

    function triggerSettlement(bytes32 poolId, uint160 currentSqrtPriceX96) external {
        _settlePool(poolId, currentSqrtPriceX96);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length > 0) {
            (bool wantsCoverage, address lp, uint256 thresholdBps, uint256 positionValueToken1) =
                abi.decode(hookData, (bool, address, uint256, uint256));
            if (wantsCoverage) {
                PoolId poolId = key.toId();
                uint160 sqrtPriceX96 = _currentSqrtPrice(poolId);
                uint256 value = positionValueToken1 == 0 ? _abs(delta.amount1()) : positionValueToken1;
                _enroll(PoolId.unwrap(poolId), Currency.unwrap(key.currency1), lp == address(0) ? sender : lp, sqrtPriceX96, value, thresholdBps, false);
            }
        }
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        address lp = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;
        bytes32 poolId = PoolId.unwrap(key.toId());
        InsuredPosition storage pos = positions[poolId][lp];
        if (pos.active) {
            uint160 price = _currentSqrtPrice(key.toId());
            (uint256 ilBps, uint256 excessBps) = ILComputer.excessILBps(pos.entryPrice, price, pos.thresholdBps);
            if (excessBps > 0 && block.timestamp >= pos.depositTimestamp + epochLength) {
                _processPayout(poolId, lp, excessBps, ilBps);
            }
            pos.active = false;
            _removeInsuredLP(poolId, lp);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        uint160 sqrtPriceX96 = hookData.length >= 32 ? abi.decode(hookData, (uint160)) : _currentSqrtPrice(key.toId());
        poolState[poolId].lastSqrtPriceX96 = sqrtPriceX96;

        uint256 feeBase = _abs(delta.amount1());
        uint256 diversion = FullMath.mulDiv(feeBase, _feeDiversionBps(poolId), BPS_DENOMINATOR);
        if (diversion > 0) poolState[poolId].reserveBalance += diversion;
        _updateReserveState(poolId);

        emit PriceDeviation(poolId, sqrtPriceX96, block.timestamp, insuredLPs[poolId].length);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _enroll(
        bytes32 poolId,
        address token1,
        address lp,
        uint160 entryPrice,
        uint256 positionValueToken1,
        uint256 thresholdBps,
        bool pullPremium
    ) internal returns (uint256 premium) {
        if (thresholdBps < MIN_THRESHOLD_BPS || thresholdBps > MAX_THRESHOLD_BPS) revert ThresholdOutOfRange();
        if (lp == address(0) || token1 == address(0) || entryPrice == 0 || positionValueToken1 == 0) revert InvalidAmount();

        PoolInsuranceState storage state = poolState[poolId];
        if (state.token1 == address(0)) state.token1 = token1;
        if (state.token1 != token1) revert InvalidPool();
        if (state.maxReserveTarget == 0) state.maxReserveTarget = positionValueToken1;
        if (state.feeDiversionBps == 0) state.feeDiversionBps = NORMAL_FEE_DIVERSION_BPS;
        state.lastSqrtPriceX96 = entryPrice;

        premium = FullMath.mulDiv(positionValueToken1, DEFAULT_PREMIUM_BPS, BPS_DENOMINATOR);
        if (pullPremium && premium > 0) _safeTransferFrom(token1, msg.sender, address(this), premium);

        state.reserveBalance += premium;
        state.totalPremiumsCollected += premium;

        positions[poolId][lp] = InsuredPosition({
            active: true,
            entryPrice: entryPrice,
            entryLiquidity: positionValueToken1,
            depositTimestamp: block.timestamp,
            thresholdBps: thresholdBps,
            premiumPaid: premium,
            totalPayoutsReceived: 0,
            lastClaimEpoch: currentEpoch(),
            maxCoverageAmount: premium * MAX_COVERAGE_MULTIPLIER
        });
        _addInsuredLP(poolId, lp);
        emit PremiumCollected(poolId, lp, premium);
        _updateReserveState(poolId);
    }

    function _settlePool(bytes32 poolId, uint160 currentSqrtPriceX96) internal {
        if (currentSqrtPriceX96 == 0) revert InvalidAmount();
        poolState[poolId].lastSqrtPriceX96 = currentSqrtPriceX96;
        address[] memory lps = insuredLPs[poolId];
        for (uint256 i; i < lps.length; i++) {
            InsuredPosition storage pos = positions[poolId][lps[i]];
            if (!pos.active) continue;
            if (block.timestamp < pos.depositTimestamp + epochLength) continue;
            if (pos.lastClaimEpoch >= currentEpoch()) continue;
            (uint256 ilBps, uint256 excessBps) = ILComputer.excessILBps(pos.entryPrice, currentSqrtPriceX96, pos.thresholdBps);
            if (excessBps > 0) _processPayout(poolId, lps[i], excessBps, ilBps);
        }
    }

    function _processPayout(bytes32 poolId, address lp, uint256 excessILBps, uint256 knownIlBps) internal {
        InsuredPosition storage pos = positions[poolId][lp];
        if (!pos.active) revert PositionNotActive();
        if (block.timestamp < pos.depositTimestamp + epochLength) revert CoveragePeriodNotElapsed();
        if (pos.lastClaimEpoch >= currentEpoch()) revert AlreadyClaimedThisEpoch();
        if (poolState[poolId].state == ReserveState.DEPLETED) revert ReserveDepleted();

        uint256 payout = FullMath.mulDiv(pos.entryLiquidity, excessILBps, BPS_DENOMINATOR);
        uint256 remaining = pos.maxCoverageAmount - pos.totalPayoutsReceived;
        if (payout > remaining) payout = remaining;
        if (payout == 0) revert MaxCoverageExceeded();
        if (poolState[poolId].state == ReserveState.STRESSED) payout /= 2;
        if (poolState[poolId].reserveBalance < payout) revert ReserveDepleted();

        poolState[poolId].reserveBalance -= payout;
        poolState[poolId].totalPayoutsSettled += payout;
        pos.totalPayoutsReceived += payout;
        pos.lastClaimEpoch = currentEpoch();

        _safeTransfer(poolState[poolId].token1, lp, payout);
        emit InsurancePaid(poolId, lp, payout, knownIlBps == 0 ? pos.thresholdBps + excessILBps : knownIlBps);
        _updateReserveState(poolId);
    }

    function _currentSqrtPrice(PoolId poolId) internal view virtual returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _feeDiversionBps(bytes32 poolId) internal view returns (uint256) {
        uint256 bps = poolState[poolId].feeDiversionBps;
        return bps == 0 ? NORMAL_FEE_DIVERSION_BPS : bps;
    }

    function _updateReserveState(bytes32 poolId) internal {
        PoolInsuranceState storage state = poolState[poolId];
        uint256 target = state.maxReserveTarget == 0 ? 1 : state.maxReserveTarget;
        uint256 totalReserve = state.reserveBalance + state.aaveDepositedBalance;
        ReserveState nextState;
        uint256 ratioBps = FullMath.mulDiv(totalReserve, BPS_DENOMINATOR, target);
        if (ratioBps < 1_000) {
            nextState = ReserveState.DEPLETED;
            state.feeDiversionBps = DEPLETED_FEE_DIVERSION_BPS;
        } else if (ratioBps < 3_000) {
            nextState = ReserveState.STRESSED;
            state.feeDiversionBps = STRESSED_FEE_DIVERSION_BPS;
        } else {
            nextState = ReserveState.HEALTHY;
            state.feeDiversionBps = NORMAL_FEE_DIVERSION_BPS;
        }
        if (state.state != nextState) emit ReserveStateChanged(poolId, nextState);
        state.state = nextState;
    }

    function _addInsuredLP(bytes32 poolId, address lp) internal {
        if (insuredIndexPlusOne[poolId][lp] != 0) return;
        insuredLPs[poolId].push(lp);
        insuredIndexPlusOne[poolId][lp] = insuredLPs[poolId].length;
    }

    function _removeInsuredLP(bytes32 poolId, address lp) internal {
        uint256 indexPlusOne = insuredIndexPlusOne[poolId][lp];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = insuredLPs[poolId].length - 1;
        if (index != lastIndex) {
            address last = insuredLPs[poolId][lastIndex];
            insuredLPs[poolId][index] = last;
            insuredIndexPlusOne[poolId][last] = index + 1;
        }
        insuredLPs[poolId].pop();
        delete insuredIndexPlusOne[poolId][lp];
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return value < 0 ? uint256(uint128(-value)) : uint256(uint128(value));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

