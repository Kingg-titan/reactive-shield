# ReactiveShield Technical Specification

## Summary

ReactiveShield is an opt-in impermanent-loss insurance system for Uniswap v4 LPs. It combines a hook-side insurance reserve, LP position accounting, optional Aave-style yield on idle reserve assets, and Reactive Network callbacks for autonomous settlement.

The target hackathon product is a judge-ready full-stack prototype:

- Solidity v4 hook with insured LP registry and payout accounting.
- Pure IL math library with fixed-point tests and fuzz coverage.
- Reactive Smart Contract using the legacy Lasna endpoint/library.
- Deployment and e2e scripts that prove origin event, RVM processing, and destination callback.
- Frontend for users and judges to inspect reserves, enroll coverage, simulate IL, and trigger/observe demos.

## Invariants

1. Payouts cannot exceed `maxCoverageAmount - totalPayoutsReceived`.
2. One LP cannot receive more than one payout for the same pool epoch.
3. Depleted reserves cannot pay claims.
4. Reserve debits happen before token transfers.
5. Reactive settlement requires two identities:
   - `msg.sender == callbackProxy`
   - encoded callback sender equals `reactiveSender`
6. IL below the LP threshold is never paid.
7. The production default epoch length remains long, while demos can pass a short constructor epoch.

## Contracts

### `ReactiveShieldHook.sol`

Primary hook contract. Responsibilities:

- Record insured positions from `afterAddLiquidity` hook data.
- Keep first-party demo enrollment helpers for tests and frontend.
- Emit price deviation events from `afterSwap`.
- Track reserve state and dynamic fee diversion.
- Accept Reactive callbacks through `triggerPayoutFromReactive(address sender, bytes32 poolId, address lp, uint256 excessILBps)`.
- Support a permissionless `triggerSettlement` fallback for demos.

Hook permissions:

- `afterAddLiquidity`: position enrollment and premium accounting.
- `beforeRemoveLiquidity`: final settlement and deactivation.
- `afterSwap`: reserve fee diversion and Reactive event emission.

The implementation must not enable any return-delta hook flags.

### `ILComputer.sol`

Pure math library:

```text
IL = 1 - 2 * sqrt(k) / (1 + k)
```

Inputs are `sqrtPriceX96` values. Output is basis points. The library must pass known-value tests for 0%, 10%, 25%, 50%, 2x, 3x, 4x, and symmetric down moves.

### `AaveV3Adapter.sol`

Adapter boundary for reserve yield:

- `deposit(token, amount, onBehalfOf)`
- `withdraw(token, amount, recipient)`
- `currentBalance(account)`
- `harvestYield(token, depositedPrincipal, recipient)`

For local and fork tests, a mock-compatible adapter is acceptable. Production deployments must use real Aave v3 pool and aToken addresses for the destination chain.

### `ReactiveShieldRSC.sol`

Reactive Smart Contract deployed on Lasna:

- Uses legacy `Reactive-Network/reactive-lib`.
- Subscribes to origin-chain `PriceDeviation(bytes32,uint160,uint256,uint256)`.
- Allows constructor subscription to fail gracefully.
- Exposes `configureSubscription()` for explicit post-deploy subscription.
- Encodes callback sender explicitly in the payload.
- Emits callback for one event epoch only, avoiding stale callback spam.

## Data Model

```solidity
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
```

Reserve state:

```solidity
enum ReserveState {
    HEALTHY,
    STRESSED,
    DEPLETED
}
```

Thresholds:

- Healthy: total reserve greater than 30% of target.
- Stressed: 10% to 30%.
- Depleted: less than 10%.

State effects:

- Healthy: 100% payouts, 10% fee diversion.
- Stressed: 50% payouts, 20% fee diversion.
- Depleted: payouts paused, 30% fee diversion.

## Events

```solidity
event PriceDeviation(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 timestamp, uint256 insuredLPCount);
event InsurancePaid(bytes32 indexed poolId, address indexed lp, uint256 amount, uint256 ilBps);
event PremiumCollected(bytes32 indexed poolId, address indexed lp, uint256 amount);
event ReserveStateChanged(bytes32 indexed poolId, ReserveState newState);
event ReserveYieldHarvested(bytes32 indexed poolId, uint256 yieldAmount);
event CallbackDebtCovered(uint256 amount);
```

## Errors

- `NotReactiveCallback()`
- `CoveragePeriodNotElapsed()`
- `AlreadyClaimedThisEpoch()`
- `ReserveDepleted()`
- `ThresholdOutOfRange()`
- `PositionNotActive()`
- `MaxCoverageExceeded()`
- `InvalidReactiveSender()`
- `InvalidAmount()`

## Reactive Integration Requirements

Use the legacy Lasna stack:

- RPC: `https://lasna-rpc.rnk.dev/`
- Chain ID: `5318007`
- Currency: `lREACT`
- System contract: `0x0000000000000000000000000000000000fffFfF`
- Library install: `forge install Reactive-Network/reactive-lib`

The e2e script must treat Reactive as three proof layers:

1. Origin chain event.
2. Lasna/ReactVM reaction.
3. Destination callback.

Do not report success until all three layers are observed or a clear blocker is recorded.

## Deployment Targets

Official Uniswap v4 addresses are sourced from the Uniswap deployment docs.

| Network | Chain ID | PoolManager | Universal Router | PositionManager |
| --- | ---: | --- | --- | --- |
| Sepolia | 11155111 | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` |
| Base Sepolia | 84532 | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | `0x492e6456d9528771018deb9e87ef7750ef184104` | `0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80` |
| Unichain Sepolia | 1301 | `0x00b036b58a818b1bc34d502d3fe730db729e62ac` | `0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d` | `0xf969aee60879c54baaed9f3ed26147db216fd664` |
| Unichain | 130 | `0x1f98400000000000000000000000000000000004` | `0xef740bf23acae26f6492b10de645d6b98dc8eaf3` | `0x4529A01c7A0410167c5740C487A8DE60232617bf` |

## Test Plan

Unit tests:

- Enrollment with and without coverage.
- Threshold validation.
- Premium accounting.
- Fee diversion and reserve state transitions.
- Authorized and unauthorized Reactive payout.
- Double-claim prevention.
- Stressed and depleted payout behavior.
- Max coverage cap.
- Final withdrawal settlement.
- IL known values.

Fuzz tests:

- IL is bounded by 100%.
- Payout never exceeds coverage cap.
- Reserve debits never underflow.
- Symmetric up/down price moves return equivalent IL within tolerance.

Integration tests:

- Full normal-market lifecycle.
- Moderate move with payout.
- Catastrophic move causing stress/depletion.
- Multiple LPs with different thresholds.
- Mock Reactive callback path.
- Mock Aave deposit/withdraw path.

Fork/e2e:

- Deploy hook and RSC.
- Configure subscription.
- Emit `PriceDeviation`.
- Poll RVM tail transactions.
- Observe destination callback and `InsurancePaid`.
- Print clickable transaction URLs for all proof layers.

