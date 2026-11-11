#!/usr/bin/env python3
"""Push one Stock Token price round to a TailPriceOracle and read it back.

E2E proof of the loop: Robinhood public REST price -> multiplier-adjusted
token price at 8 decimals, Chainlink convention -> signed push round ->
latestRoundData() read back through the AggregatorV3 surface.

Local/dev: expects `cast` on PATH. The private key is a throwaway dev key
(anvil well-known account) — NEVER a real key, NEVER a production pusher.
"""

import argparse
import json
import subprocess
import sys
import urllib.request
from decimal import Decimal, ROUND_HALF_UP

ASSETS_URL = "https://api.robinhood.com/rhj/assets"
PRICE_URL = "https://api.robinhood.com/rhj/prices/{}"
FEEDS_URL = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "tail-push-e2e/1.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode())


def cast(*args):
    out = subprocess.run(["cast", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"cast {' '.join(args)} failed:\n{out.stderr}")
    return out.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--symbol", default="CRM")
    ap.add_argument("--oracle", required=True, help="deployed TailPriceOracle address")
    ap.add_argument("--rpc", default="http://localhost:8545")
    ap.add_argument("--private-key", required=True, help="pusher key (dev key on anvil only)")
    ap.add_argument("--heartbeat", type=int, default=60)
    args = ap.parse_args()
    sym = args.symbol.upper()

    # Refuse to double-cover: the tail oracle exists only for symbols Chainlink does not price.
    feeds = http_json(FEEDS_URL)
    bases = {(f.get("docs") or {}).get("baseAsset") for f in feeds}
    if sym in bases:
        sys.exit(f"{sym} already has a Chainlink feed; the tail oracle does not double-cover it")

    asset = next((a for a in http_json(ASSETS_URL)["assets"] if a["tokenSymbol"] == sym), None)
    if asset is None:
        sys.exit(f"{sym} not in assets API")
    multiplier = Decimal(asset["currentMultiplier"])

    quote = http_json(PRICE_URL.format(sym))["quotes"][0]
    if quote.get("isTradingHalt"):
        sys.exit(f"{sym} is halted; refusing to push a price into a halted market")
    bid, ask = Decimal(quote["bid"]), Decimal(quote["ask"])
    mid = (bid + ask) / 2

    # Chainlink convention for these feeds: Token Price = underlying price x multiplier, 8 decimals.
    token_price = mid * multiplier
    price_8dp = (token_price * Decimal(10) ** 8).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    if price_8dp <= 0:
        sys.exit("computed price is not positive; refusing to push")

    print(f"symbol {sym}")
    print(f"  underlying bid/ask {bid} / {ask}  mid {mid}")
    print(f"  multiplier {multiplier}")
    print(f"  token price {token_price} -> push {price_8dp} (8 dp)")

    tx = cast(
        "send", args.oracle,
        "pushPrice(int256,uint64)",
        str(int(price_8dp)), str(args.heartbeat),
        "--rpc-url", args.rpc, "--private-key", args.private_key,
    )
    print(f"  tx {tx}")

    round_raw = cast(
        "call", args.oracle,
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)",
        "--rpc-url", args.rpc,
    )
    print(f"  readback latestRoundData: {round_raw}")

    answer = int(round_raw.split()[1].replace("[", "").replace(",", ""))
    if answer != int(price_8dp):
        sys.exit(f"MISMATCH: pushed {price_8dp}, read back {answer}")
    print("E2E_OK: pushed price equals readback answer")


if __name__ == "__main__":
    main()
