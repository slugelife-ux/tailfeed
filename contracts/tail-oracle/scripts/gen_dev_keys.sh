#!/usr/bin/env bash
# Generate two throwaway local dev keys (fresh random, never used anywhere else),
# store them 0600, restart anvil with the deployer key as account 0, fund the
# pusher address via anvil_setBalance.
set -euo pipefail
export PATH="$PATH:/root/.foundry/bin"

ENVFILE=/root/onchain-studio/contracts/tail-oracle/scripts/.anvil-dev.env

DEPLOYER_KEY=$(cast wallet new | grep -o '0x[0-9a-fA-F]\{64\}' | head -1)
PUSHER_KEY=$(cast wallet new | grep -o '0x[0-9a-fA-F]\{64\}' | head -1)
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
PUSHER_ADDR=$(cast wallet address --private-key "$PUSHER_KEY")

umask 077
cat > "$ENVFILE" <<EOF
DEPLOYER_KEY=$DEPLOYER_KEY
PUSHER_KEY=$PUSHER_KEY
DEPLOYER_ADDR=$DEPLOYER_ADDR
PUSHER_ADDR=$PUSHER_ADDR
EOF
chmod 600 "$ENVFILE"
echo "keys written to $ENVFILE (0600), locally generated throwaways"
echo "deployer $DEPLOYER_ADDR"
echo "pusher   $PUSHER_ADDR"
