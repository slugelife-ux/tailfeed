#!/usr/bin/env bash
# FeedRegistry local anvil e2e: deploy, register 3 tail feeds, one batch push
# from real REST prices, readback through proxies, non-pusher rejection.
# Throwaway dev keys only (0600 env file). Never a real key.
set -euo pipefail
source "$(dirname "$0")/.anvil-dev.env"
export PATH="$PATH:/root/.foundry/bin"
cd "$(dirname "$0")/.."

RPC=http://localhost:8545
HEARTBEAT=60

cast rpc anvil_setBalance "$PUSHER_ADDR" 0x8AC7230489E80000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$DEPLOYER_ADDR" 0x8AC7230489E80000 --rpc-url "$RPC" >/dev/null

NONCE=$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$RPC")
REGISTRY=$(cast compute-address "$DEPLOYER_ADDR" --nonce "$NONCE")
forge create src/FeedRegistry.sol:FeedRegistry \
  --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --json \
  --constructor-args "$PUSHER_ADDR" >/dev/null 2>&1
[ ${#REGISTRY} -ge 42 ] || { echo "deploy failed"; exit 1; }
echo "REGISTRY=$REGISTRY"

echo "--- register 3 tail feeds (pusher) ---"
cast send "$REGISTRY" "register(uint256,string)" 1 "TAILCRM/USD" --rpc-url "$RPC" --private-key "$PUSHER_KEY" >/dev/null
cast send "$REGISTRY" "register(uint256,string)" 2 "TAILCIEN/USD" --rpc-url "$RPC" --private-key "$PUSHER_KEY" >/dev/null
cast send "$REGISTRY" "register(uint256,string)" 3 "TAILWDAY/USD" --rpc-url "$RPC" --private-key "$PUSHER_KEY" >/dev/null
for id in 1 2 3; do
  P=$(cast call "$REGISTRY" "proxyOf(uint256)(address)" $id --rpc-url "$RPC")
  echo "feed $id proxy $P"
done

echo "--- non-pusher rejection (deployer tries batchPush) ---"
OUT=$(mktemp)
if cast send "$REGISTRY" "batchPush(uint256[],int256[],uint64[])" "[1]" "[100]" "[$HEARTBEAT]" \
     --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" >"$OUT" 2>&1; then
  echo "UNEXPECTED: non-pusher push succeeded"; exit 1
fi
grep -q "NotPusher" "$OUT" && echo "NotPusher revert seen (good)"

echo "--- pusher v2: real prices -> one batch -> proxy readback ---"
cat > /tmp/tailfeed_feeds.json <<'EOF'
[{"id":1,"symbol":"CRM"},{"id":2,"symbol":"CIEN"},{"id":3,"symbol":"WDAY"}]
EOF
python3 scripts/pusher.py --registry "$REGISTRY" --feeds /tmp/tailfeed_feeds.json --private-key "$PUSHER_KEY" --heartbeat "$HEARTBEAT"

echo "--- second run: deviation threshold should suppress a new batch ---"
python3 scripts/pusher.py --registry "$REGISTRY" --feeds /tmp/tailfeed_feeds.json --private-key "$PUSHER_KEY" --heartbeat "$HEARTBEAT"
echo "REGISTRY_E2E_OK"
