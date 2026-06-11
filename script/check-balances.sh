#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "Deployer: $DEPLOYER"
echo

check_balance() {
  local name="$1"
  local rpc="$2"
  local explorer="$3"
  local bal
  bal="$(cast balance "$DEPLOYER" --rpc-url "$rpc" || true)"
  echo "$name balance: $bal wei"
  echo "$name explorer: $explorer/address/$DEPLOYER"
  echo
}

check_balance "Ethereum Sepolia" "$ETH_SEPOLIA_RPC_URL" "https://sepolia.etherscan.io"
check_balance "Base Sepolia" "$BASE_SEPOLIA_RPC_URL" "https://sepolia.basescan.org"
check_balance "Unichain Sepolia" "$UNICHAIN_SEPOLIA_RPC_URL" "https://sepolia.uniscan.xyz"
check_balance "Reactive Lasna" "$REACTIVE_LASNA_RPC_URL" "https://lasna.reactscan.net"

