#!/usr/bin/env bash
# Local anvil e2e for TailPriceOracle.
# Uses ONLY well-known anvil dev keys (public, zero value). Never a real key.
set -euo pipefail
export PATH="$PATH:/root/.foundry/bin"
cd "$(dirname "$0")/.."

RPC=http://localhost:8545
# locally generated throwaway keys (0600 env file); never anvil defaults, never real keys
source "$(dirname "$0")/.anvil-dev.env"
export PATH="$PATH:/root/.foundry/bin"
cd "$(dirname "$0")/.."

echo "anvil block: $(cast block-number --rpc-url $RPC)"
cast rpc anvil_setBalance "$PUSHER_ADDR" 0x8AC7230489E80000 --rpc-url "$RPC" >/dev/null  # 10 ETH gas for the pusher
cast rpc anvil_setBalance "$DEPLOYER_ADDR" 0x8AC7230489E80000 --rpc-url "$RPC" >/dev/null  # 10 ETH gas for the deployer
echo "pusher funded: $(cast balance "$PUSHER_ADDR" --rpc-url "$RPC" --ether) ETH"
echo "deployer funded: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC" --ether) ETH"

FORGE_OUT=$(mktemp)
# forge's non-tty --json omits deployedTo; compute the address deterministically instead
NONCE=$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$RPC")
ORACLE=$(cast compute-address "$DEPLOYER_ADDR" --nonce "$NONCE")
forge create src/TailPriceOracle.sol:TailPriceOracle \
  --rpc-url "$RPC" \
  --private-key "$DEPLOYER_KEY" \
  --broadcast \
  --json \
  --constructor-args "$PUSHER_ADDR" "TAILCRM/USD" > "$FORGE_OUT" 2>&1 || { cat "$FORGE_OUT"; exit 1; }
CODE=$(cast code "$ORACLE" --rpc-url "$RPC")
[ ${#CODE} -gt 4 ] || { echo "no bytecode at $ORACLE"; exit 1; }
echo "ORACLE=$ORACLE"

echo "--- non-pusher rejection (deployer tries; expect revert NotPusher, oracle stays empty) ---"
CAST_OUT=$(mktemp)
if cast send "$ORACLE" "pushPrice(int256,uint64)" 123 60 \
     --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" >"$CAST_OUT" 2>&1; then
  echo "UNEXPECTED: push from deployer succeeded"
  exit 1
fi
grep -c "NotPusher" "$CAST_OUT" >/dev/null && echo "NotPusher revert seen (good)"
echo "isEmpty after rejected push: $(cast call "$ORACLE" 'isEmpty()(bool)' --rpc-url "$RPC")"

echo "--- pusher e2e: CRM from Robinhood REST -> multiplier-adjusted -> push -> readback ---"
python3 scripts/push_and_readback.py --symbol CRM --oracle "$ORACLE" --private-key "$PUSHER_KEY"

echo "--- headline readback ---"
cast call "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC"
echo "LOCAL_E2E_OK"
