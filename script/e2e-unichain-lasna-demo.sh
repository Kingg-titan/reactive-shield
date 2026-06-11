#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

mkdir -p logs
LOG="logs/e2e-unichain-lasna-demo.log"

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
POOL_ID="${REACTIVE_SHIELD_DEMO_POOL_ID:-$(cast keccak "ReactiveShield demo pool")}"
RVM_ID="${REACTIVE_SHIELD_RVM_ID:-$DEPLOYER}"
PRICE_DEVIATION_TOPIC="$(cast sig-event "PriceDeviation(bytes32,uint160,uint256,uint256)")"
Q96="79228162514264337593543950336"
SQRT_2_X96="112045541949572279837463876454"
POSITION_VALUE="10000000000000000000000"
RESERVE_SEED="5000000000000000000000"
MINT_AMOUNT="100000000000000000000000"
MAX_UINT="0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
LAST_TX_HASH=""

u_tx_url() {
  echo "https://sepolia.uniscan.xyz/tx/$1"
}

l_tx_url() {
  echo "https://lasna.reactscan.net/tx/$1"
}

send_and_hash() {
  local label="$1"
  shift
  local output
  local status
  for attempt in 1 2 3 4 5; do
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      break
    fi
    if printf '%s\n' "$output" | grep -qi "nonce too low"; then
      echo "$label retry $attempt: RPC returned nonce too low; waiting for nonce indexer"
      sleep 3
      continue
    fi
    printf '%s\n' "$output"
    exit "$status"
  done
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output"
    exit "$status"
  fi
  local hash
  hash="$(extract_hash "$output")"
  if [[ -z "$hash" ]]; then
    printf '%s\n' "$output"
    echo "Unable to parse transaction hash for $label"
    exit 1
  fi
  LAST_TX_HASH="$hash"
  echo "$label tx: $hash"
  echo "$label url: $(u_tx_url "$hash")"
  sleep 2
}

extract_hash() {
  printf '%s\n' "$1" | grep -Eo 'transactionHash[" ]*[: ][" ]*0x[a-fA-F0-9]+' | head -n 1 | grep -Eo '0x[a-fA-F0-9]+$'
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

require_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$(lower "$actual")" != "$(lower "$expected")" ]]; then
    echo "$label mismatch"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "$label: $actual"
}

find_rvm_tx_for_origin() {
  local origin_tx="$1"
  local vm_json
  local last_hex
  local last_dec
  local start_dec
  local start_hex
  local txs

  vm_json="$(cast rpc --rpc-url "$REACTIVE_LASNA_RPC_URL" rnk_getVm "$RVM_ID")"
  last_hex="$(printf '%s\n' "$vm_json" | jq -r '.lastTxNumber')"
  last_dec=$((16#${last_hex#0x}))
  start_dec=$((last_dec > 96 ? last_dec - 96 : 0))
  start_hex="$(printf '0x%x' "$start_dec")"
  txs="$(cast rpc --rpc-url "$REACTIVE_LASNA_RPC_URL" rnk_getTransactions "$RVM_ID" "$start_hex" "0x80")"
  printf '%s\n' "$txs" | jq -r --arg origin "$(lower "$origin_tx")" '
    .[]
    | select((.refTx // "" | ascii_downcase) == $origin)
    | .hash
  ' | tail -n 1
}

find_destination_insurance_paid_tx() {
  local from_block="$1"
  cast logs \
    --address "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" \
    --from-block "$from_block" \
    --to-block latest \
    "InsurancePaid(bytes32 indexed,address indexed,uint256,uint256)" \
    --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
    --json \
    | jq -r '.[-1].transactionHash // empty'
}

{
  echo "ReactiveShield Unichain Sepolia <-> Lasna demo e2e"
  echo "Purpose: prove the full LP insurance journey plus the three Reactive proof layers."
  echo "User story: an LP opts into IL insurance, the pool reserve is funded, a price deviation is emitted, Lasna reacts, and the destination hook pays the LP automatically."
  echo "Deployer: $DEPLOYER"
  echo "Demo token: $REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS"
  echo "Demo hook: $REACTIVE_SHIELD_DEMO_HOOK_ADDRESS"
  echo "Demo RSC: $REACTIVE_SHIELD_DEMO_RSC_ADDRESS"
  echo "Callback proxy: $UNICHAIN_SEPOLIA_CALLBACK_PROXY"
  echo "RVM sender/id: $RVM_ID"
  echo "Pool id: $POOL_ID"
  echo
  echo "Proof model:"
  echo "  1. Origin chain: Unichain Sepolia transaction emits PriceDeviation."
  echo "  2. Reactive layer: Lasna RVM transaction processes that exact origin tx."
  echo "  3. Destination chain: callback proxy submits a payout tx that emits InsurancePaid."
  echo

  echo "Phase 1: verify live callback proxy, RVM sender, subscription, filter, and callback debt"
  echo "What this proves: the deployed hook trusts the expected callback proxy and RVM sender, the RSC is subscribed to this hook's PriceDeviation topic, and callback payment debt will not block the relay."
  SUBSCRIBED="$(cast call "$REACTIVE_SHIELD_DEMO_RSC_ADDRESS" "subscriptionConfigured()(bool)" --rpc-url "$REACTIVE_LASNA_RPC_URL")"
  DEBT_RAW="$(cast call "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "callbackDebt()(uint256)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  DEBT="$(printf '%s\n' "$DEBT_RAW" | awk '{print $1}')"
  HOOK_CALLBACK_PROXY="$(cast call "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "callbackProxy()(address)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  HOOK_REACTIVE_SENDER="$(cast call "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "reactiveSender()(address)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  RSC_HOOK="$(cast call "$REACTIVE_SHIELD_DEMO_RSC_ADDRESS" "HOOK_ADDRESS()(address)" --rpc-url "$REACTIVE_LASNA_RPC_URL")"
  RSC_ORIGIN_CHAIN="$(cast call "$REACTIVE_SHIELD_DEMO_RSC_ADDRESS" "ORIGIN_CHAIN_ID()(uint256)" --rpc-url "$REACTIVE_LASNA_RPC_URL")"
  RSC_DEST_CHAIN="$(cast call "$REACTIVE_SHIELD_DEMO_RSC_ADDRESS" "DESTINATION_CHAIN_ID()(uint256)" --rpc-url "$REACTIVE_LASNA_RPC_URL")"
  FILTER_MATCH="$(
    cast rpc --rpc-url "$REACTIVE_LASNA_RPC_URL" rnk_getFilters \
      | jq -r \
        --argjson chain "$REACTIVE_SHIELD_ORIGIN_CHAIN_ID" \
        --arg contract "$(lower "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS")" \
        --arg topic "$(lower "$PRICE_DEVIATION_TOPIC")" \
        --arg rsc "$(lower "$REACTIVE_SHIELD_DEMO_RSC_ADDRESS")" \
        --arg rvm "$(lower "$RVM_ID")" '
          [
            .[]
            | select(.ChainId == $chain)
            | select((.Contract // "" | ascii_downcase) == $contract)
            | select((.Topics[0] // "" | ascii_downcase) == $topic)
            | .Configs[]
            | select((.Contract // "" | ascii_downcase) == $rsc)
            | select((.RvmId // "" | ascii_downcase) == $rvm)
            | select(.Active == true)
          ]
          | length
        '
  )"
  require_equal "Hook callback proxy" "$HOOK_CALLBACK_PROXY" "$UNICHAIN_SEPOLIA_CALLBACK_PROXY"
  require_equal "Hook reactive sender" "$HOOK_REACTIVE_SENDER" "$RVM_ID"
  require_equal "RSC subscribed hook" "$RSC_HOOK" "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS"
  echo "RSC origin chain: $RSC_ORIGIN_CHAIN"
  echo "RSC destination chain: $RSC_DEST_CHAIN"
  echo "subscriptionConfigured: $SUBSCRIBED"
  echo "active RNK filter matches: $FILTER_MATCH"
  echo "callbackDebt: $DEBT"
  if [[ "$SUBSCRIBED" != "true" || "$FILTER_MATCH" == "0" ]]; then
    echo "Reactive preflight failed"
    exit 1
  fi
  if [[ "$DEBT" != "0" ]]; then
    echo "Callback debt is nonzero; funding hook and calling coverCallbackDebt()"
    send_and_hash "Fund hook native debt balance" \
      cast send "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" --value "$DEBT" \
        --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
    send_and_hash "Cover callback debt" \
      cast send "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "coverCallbackDebt()" \
        --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
    DEBT_RAW="$(cast call "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "callbackDebt()(uint256)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
    DEBT="$(printf '%s\n' "$DEBT_RAW" | awk '{print $1}')"
    echo "callbackDebt after cover: $DEBT"
    if [[ "$DEBT" != "0" ]]; then
      echo "Callback debt remains nonzero after cover"
      exit 1
    fi
  fi
  echo
  echo "Phase 1 result: Reactive preflight passed. A live Lasna filter is active for this hook/topic/RVM tuple."
  echo

  echo "Phase 2: mint demo reserve token and approve hook"
  echo "User perspective: the demo account receives quote/reserve tokens and grants the hook allowance so it can collect the LP premium and reserve seed."
  send_and_hash "Mint demo token" \
    cast send "$REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS" "mint(address,uint256)" "$DEPLOYER" "$MINT_AMOUNT" \
      --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
  MINT_TX="$LAST_TX_HASH"
  send_and_hash "Approve hook" \
    cast send "$REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS" "approve(address,uint256)" "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "$MAX_UINT" \
      --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
  APPROVE_TX="$LAST_TX_HASH"
  echo
  echo "Phase 2 result: the LP account has spendable demo assets and the hook is approved."
  echo

  echo "Phase 3: enroll insured LP and seed reserve"
  echo "User perspective: the LP opts into insurance with a 5% IL deductible. The hook records entry price, position value, premium, coverage cap, and active coverage."
  echo "Protocol perspective: the reserve is funded so an eligible Reactive payout has capital available."
  send_and_hash "Enroll insured LP" \
    cast send "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "enrollPosition(bytes32,address,address,uint160,uint256,uint256)(uint256)" \
      "$POOL_ID" "$REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS" "$DEPLOYER" "$Q96" "$POSITION_VALUE" 500 \
      --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
  ENROLL_TX="$LAST_TX_HASH"
  send_and_hash "Fund reserve" \
    cast send "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "fundReserve(bytes32,uint256)" "$POOL_ID" "$RESERVE_SEED" \
      --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
  FUND_TX="$LAST_TX_HASH"
  echo
  echo "Phase 3 result: coverage is active and the insurance reserve is funded."
  echo

  echo "Phase 4: wait for demo epoch gate"
  echo "What this proves: payouts are epoch-gated, so the demo waits until the minimum coverage period has elapsed before trying to claim."
  sleep "${REACTIVE_SHIELD_DEMO_WAIT_SECONDS:-25}"
  echo "epoch wait complete"
  echo

  echo "Phase 5: emit origin PriceDeviation event from demo hook"
  echo "What this proves: an origin-chain event exists for Reactive Network to observe. This is not a payout yet; it is only the source signal."
  FROM_BLOCK="$(cast block-number --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  BEFORE_BALANCE="$(cast call "$REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  send_and_hash "Origin PriceDeviation" \
    cast send "$REACTIVE_SHIELD_DEMO_HOOK_ADDRESS" "emitDemoPriceDeviation(bytes32,uint160)" "$POOL_ID" "$SQRT_2_X96" \
      --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
  ORIGIN_TX="$LAST_TX_HASH"
  echo
  echo "Phase 5 result: origin event transaction submitted. This tx is the anchor used to find the Lasna RVM processing tx."
  echo

  echo "Phase 6: poll destination payout"
  echo "What this proves: the Reactive callback proxy eventually calls the destination hook, the hook verifies proxy + RVM sender, and the LP receives an insurance payout."
  PAID="false"
  DESTINATION_TX=""
  for i in $(seq 1 "${REACTIVE_SHIELD_DEMO_POLL_ATTEMPTS:-30}"); do
    sleep "${REACTIVE_SHIELD_DEMO_POLL_SECONDS:-10}"
    AFTER_BALANCE="$(cast call "$REACTIVE_SHIELD_DEMO_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
    if [[ "$AFTER_BALANCE" != "$BEFORE_BALANCE" ]]; then
      echo "Payout observed on attempt $i"
      echo "Balance before: $BEFORE_BALANCE"
      echo "Balance after:  $AFTER_BALANCE"
      DESTINATION_TX="$(find_destination_insurance_paid_tx "$FROM_BLOCK")"
      if [[ -n "$DESTINATION_TX" ]]; then
        echo "Destination InsurancePaid tx: $DESTINATION_TX"
        echo "Destination InsurancePaid url: $(u_tx_url "$DESTINATION_TX")"
      fi
      PAID="true"
      break
    fi
    echo "Attempt $i: no destination payout yet"
  done
  echo
  echo "Phase 6 result: destination callback/payout proof collected."
  echo

  echo "Phase 7: poll Lasna RVM processing tx"
  echo "What this proves: Lasna processed the exact origin PriceDeviation tx and queued the callback. This is the Reactive Network proof layer between origin and destination."
  RVM_TX=""
  for i in $(seq 1 "${REACTIVE_SHIELD_DEMO_RVM_POLL_ATTEMPTS:-12}"); do
    RVM_TX="$(find_rvm_tx_for_origin "$ORIGIN_TX")"
    if [[ -n "$RVM_TX" ]]; then
      echo "Lasna RVM processing tx: $RVM_TX"
      echo "Lasna RVM processing url: $(l_tx_url "$RVM_TX")"
      break
    fi
    echo "Attempt $i: RVM tx not indexed yet"
    sleep "${REACTIVE_SHIELD_DEMO_RVM_POLL_SECONDS:-5}"
  done
  if [[ -z "$RVM_TX" ]]; then
    echo "RVM tx was not found near the RVM tail"
    exit 1
  fi
  if [[ "$PAID" != "true" || -z "$DESTINATION_TX" ]]; then
    echo "Destination callback proof was not found"
    exit 1
  fi
  echo
  echo "Phase 7 result: RVM processing proof collected."
  echo

  echo "Phase 8: proof summary"
  echo "Read this section as the judge/user proof trail:"
  echo "  - Mint/approve/enroll/fund show the user's setup and reserve funding."
  echo "  - Origin event shows the hook emitted PriceDeviation on Unichain Sepolia."
  echo "  - RVM processing shows Lasna observed and reacted to that origin tx."
  echo "  - Destination callback shows the hook paid the insured LP through the Reactive relay."
  echo "Mint url: $(u_tx_url "$MINT_TX")"
  echo "Approve url: $(u_tx_url "$APPROVE_TX")"
  echo "Enroll url: $(u_tx_url "$ENROLL_TX")"
  echo "Fund reserve url: $(u_tx_url "$FUND_TX")"
  echo "Origin event url: $(u_tx_url "$ORIGIN_TX")"
  echo "RVM processing url: $(l_tx_url "$RVM_TX")"
  echo "Destination callback url: $(u_tx_url "$DESTINATION_TX")"
  echo "Destination payout observed: $PAID"
} | tee "$LOG"

echo "Wrote $LOG"
