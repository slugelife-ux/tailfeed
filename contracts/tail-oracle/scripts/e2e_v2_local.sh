#!/usr/bin/env bash
# FeedRegistryV2 local anvil e2e: deploy, register, 3 rounds, history reads,
# negative push test. Per foundry skill: script file, not inline commands.
set -euo pipefail
export PATH="$PATH:/root/.foundry/bin"
cd /root/onchain-studio/contracts/tail-oracle
RPC=http://localhost:8545

KEY=$(cast wallet new 2>&1 | grep 'Private key:' | awk '{print $3}')
ADDR=$(cast wallet address "$KEY")
cast rpc anvil_setBalance "$ADDR" 0x8AC7230489E80000 --rpc-url $RPC > /dev/null
echo "deployer: $ADDR"

REG=$(forge create src/FeedRegistryV2.sol:FeedRegistryV2 \
  --rpc-url $RPC --private-key "$KEY" --broadcast \
  --constructor-args "$ADDR" 2>&1 \
  | grep 'Deployed to:' | awk '{print $3}')
[ -n "$REG" ] || { echo "deploy failed"; exit 1; }
echo "V2 registry: $REG"

cast send "$REG" "register(uint256,string)" 1 "TAIL CRM/USD" \
  --rpc-url $RPC --private-key "$KEY" > /dev/null
PROXY=$(cast call "$REG" "proxyOf(uint256)(address)" 1 --rpc-url $RPC | tr -d '\r\n ')
echo "proxy: $PROXY"

cast send "$REG" "batchPush(uint256[],int256[],uint64[])" "[1]" "[100000000]" "[60]" \
  --rpc-url $RPC --private-key "$KEY" > /dev/null
cast rpc evm_increaseTime 120 --rpc-url $RPC > /dev/null
cast send "$REG" "batchPush(uint256[],int256[],uint64[])" "[1]" "[101000000]" "[60]" \
  --rpc-url $RPC --private-key "$KEY" > /dev/null
cast rpc evm_increaseTime 120 --rpc-url $RPC > /dev/null
cast send "$REG" "batchPush(uint256[],int256[],uint64[])" "[1]" "[102000000]" "[60]" \
  --rpc-url $RPC --private-key "$KEY" > /dev/null

echo "--- getRoundData(1) via proxy ---"
cast call "$PROXY" "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)" 1 --rpc-url $RPC
echo "--- getRoundData(2) via proxy ---"
cast call "$PROXY" "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)" 2 --rpc-url $RPC
echo "--- latestRoundData via proxy ---"
cast call "$PROXY" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC

KEY2=$(cast wallet new 2>&1 | grep 'Private key:' | awk '{print $3}')
ADDR2=$(cast wallet address "$KEY2")
cast rpc anvil_setBalance "$ADDR2" 0x8AC7230489E80000 --rpc-url $RPC > /dev/null
echo "--- negative: funded stranger push (expect NotPusher revert) ---"
cast send "$REG" "batchPush(uint256[],int256[],uint64[])" "[1]" "[999]" "[60]" \
  --rpc-url $RPC --private-key "$KEY2" 2>&1 | grep -oE 'NotPusher\([a-zA-Z0-9x]+\)' | head -1 || echo "NO REVERT SEEN"

echo "--- round 1 unchanged after stranger attempt ---"
cast call "$PROXY" "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)" 1 --rpc-url $RPC | head -2
echo "E2E_SCRIPT_OK"
