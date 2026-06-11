#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p logs deployments

NETWORK="${1:-unichain-sepolia}"
LOG="logs/e2e-${NETWORK}.log"

{
  echo "ReactiveShield testnet e2e runbook: $NETWORK"
  echo "This script is the operator-facing proof checklist."
  echo
  echo "Phase 0: verify deployer balances"
  ./script/check-balances.sh
  echo
  echo "Phase 1: deploy destination hook with mined v4 hook address"
  echo "TODO: run DeployReactiveShield.s.sol after funding deployer and callback proxy."
  echo
  echo "Phase 2: deploy RSC on Reactive Lasna"
  echo "Expected tx label: RSC deploy"
  echo "Explorer: https://lasna.reactscan.net"
  echo
  echo "Phase 3: configure subscription on Lasna"
  echo "Expected tx label: Subscription"
  echo "Verify rnk_getFilters includes origin chain id, hook address, topic0, RVM id, active=true"
  echo
  echo "Phase 4: origin-chain PriceDeviation"
  echo "Expected tx label: Origin PriceDeviation"
  echo
  echo "Phase 5: Lasna RVM queued callback"
  echo "Expected tx label: RVM queued callback"
  echo "Poll near rnk_getVm(rvmId).lastTxNumber; do not scan from genesis."
  echo
  echo "Phase 6: destination callback"
  echo "Expected tx label: Destination InsurancePaid callback"
  echo "Verify InsurancePaid(poolId, lp, amount, ilBps)."
} | tee "$LOG"

echo "Wrote $LOG"

