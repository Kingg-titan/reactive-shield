# Build Prompt: ReactiveShield Production Build

You are building ReactiveShield, a Uniswap v4 impermanent-loss insurance hook with Reactive Network settlement.

## Mandatory Context Pass

Before writing or modifying code:

1. Read `README.md`.
2. Read `spec.md`.
3. Read every relevant file under `context/`, prioritizing:
   - `context/README.md`
   - Reactive Network legacy examples and `reactive-lib`
   - Reactive demo projects using callbacks and subscriptions
   - Uniswap v4 docs and hook examples
4. Inspect all repository files:
   - `src/`
   - `test/`
   - `script/`
   - `frontend/`
   - `foundry.toml`
   - `remappings.txt`
5. Confirm dependencies:
   - `lib/forge-std`
   - `lib/v4-hooks-public`
   - `lib/reactive-lib`

Write down any mismatch between the spec and the available libraries before implementation.

## Build Objective

Build the entire project to production-demo quality:

- Compiling Solidity contracts.
- Full Foundry unit, integration, fuzz, and fork-test coverage.
- Reactive Lasna RSC with explicit subscription configuration.
- End-to-end script that proves:
  1. RSC deploy tx.
  2. Subscription tx and active filter.
  3. Origin `PriceDeviation` tx.
  4. Lasna RVM tx that handled the event.
  5. Destination callback tx that emitted `InsurancePaid`.
- Demo frontend for judges and users.
- Clear deployment files and logs.

## Implementation Rules

- Use legacy Reactive Lasna:
  - RPC `https://lasna-rpc.rnk.dev/`
  - Chain ID `5318007`
  - Currency `lREACT`
  - System contract `0x0000000000000000000000000000000000fffFfF`
  - `forge install Reactive-Network/reactive-lib`
- Do not mix legacy and omni Reactive libraries.
- Treat Reactive as a two-chain, three-proof system.
- Do not assume a callback succeeded because the origin event or RVM event exists.
- Encode the RVM sender explicitly in callback payloads.
- Destination hook auth must check both callback proxy and encoded RSC sender.
- Keep a permissionless fallback demo function, but make the Reactive path the primary proof.
- Preserve production defaults and pass short epoch lengths only for demos/tests.
- Never enable Uniswap v4 return-delta hook permissions unless the implementation truly needs them.

## Test Requirements

Reach 100% practical coverage across protocol behavior:

- `forge test`
- `forge coverage`
- Known-value math tests.
- Invariant/fuzz tests.
- Mock Aave reserve tests.
- Mock Reactive callback tests.
- Fork tests for deployed Uniswap v4 PoolManager addresses where RPC and balances permit.

If exact line coverage is blocked by external library instrumentation, document the excluded paths and why.

## E2E Logging Requirements

The e2e script must write human-readable logs explaining every phase and print clickable explorer URLs:

- `logs/e2e-<network>.log`
- `deployments/<network>.json`

Log labels must distinguish:

- `RSC deploy`
- `Subscription`
- `Origin PriceDeviation`
- `RVM queued callback`
- `Destination InsurancePaid callback`

Never label a subscription transaction as a callback transaction.

## Frontend Requirements

Build a Next.js frontend in `frontend/` that lets judges:

- Connect wallet.
- Select network.
- View deployed contract addresses.
- View reserve health and fee diversion state.
- Enroll an insured LP demo position.
- Simulate a price deviation.
- Trigger/check Reactive settlement.
- Inspect transaction URLs and event logs.

Do not make a marketing landing page as the first screen; the first screen must be the usable demo console.

## Completion Definition

The project is complete only when:

- `forge build` passes.
- `forge test` passes.
- Fuzz tests pass.
- Demo script runs on local/anvil or a configured testnet.
- Frontend builds.
- Deployment/e2e logs clearly report success or a precise external blocker, such as missing faucet funds or unavailable RPC.

