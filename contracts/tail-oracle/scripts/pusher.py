#!/usr/bin/env python3
"""TailFeed pusher v2: fetch tail-symbol prices, push ONE batch transaction.

Reads Robinhood's public REST prices, applies the Chainlink convention
(token price = underlying mid x uiMultiplier, 8 decimals), compares each
against the feed's CURRENT onchain answer, and pushes only feeds that
moved at least --deviation (default 0.5%) or have never been pushed.

Local/dev only: the private key is a throwaway anvil key. Never a real key.
"""

import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

ASSETS_URL = "https://api.robinhood.com/rhj/assets"
PRICE_URL = "https://api.robinhood.com/rhj/prices/{}"


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "tailfeed-pusher/1.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode())


def cast(*args):
    out = subprocess.run(["cast", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"cast {' '.join(args[:3])}... failed:\n{out.stderr.strip()[:400]}")
    return out.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--feeds", required=True, help="JSON file: [{\"id\":1,\"symbol\":\"CRM\"}, ...]")
    ap.add_argument("--rpc", default="http://localhost:8545")
    ap.add_argument("--private-key", required=True)
    ap.add_argument("--deviation", default="0.005")
    ap.add_argument("--heartbeat", type=int, default=60)
    args = ap.parse_args()
    feeds = json.load(open(args.feeds))

    assets = {a["tokenSymbol"]: a for a in http_json(ASSETS_URL)["assets"]}

    push_ids, push_answers = [], []
    for f in feeds:
        sym, fid = f["symbol"].upper(), f["id"]
        asset = assets.get(sym)
        if asset is None:
            sys.exit(f"{sym}: not in assets API")

        proxy = cast("call", args.registry, "proxyOf(uint256)(address)", str(fid), "--rpc-url", args.rpc)
        if int(proxy, 16) == 0:
            sys.exit(f"{sym} (feed {fid}): not registered onchain")

        # current onchain answer + timestamp for deviation & heartbeat check
        # (latestRoundData: roundId, answer, startedAt, updatedAt, answeredInRound)
        rd = cast("call", proxy, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--rpc-url", args.rpc)
        parts = rd.replace("[", "").replace("]", "").replace(",", "").split()
        current, updated = int(parts[1]), int(parts[3])

        quote = http_json(PRICE_URL.format(sym))["quotes"][0]
        if quote.get("isTradingHalt"):
            print(f"{sym}: halted, skipping")
            continue
        bid, ask = Decimal(quote["bid"]), Decimal(quote["ask"])
        mult = Decimal(asset["currentMultiplier"])
        token_price = (bid + ask) / 2 * mult
        px = int((token_price * Decimal(10) ** 8).quantize(Decimal(1), rounding=ROUND_HALF_UP))
        if px <= 0:
            sys.exit(f"{sym}: computed non-positive price")

        # market hours gate for heartbeat enforcement (US equities, UTC)
        dt = datetime.now(timezone.utc)
        market_open = dt.weekday() < 5 and 14*60+30 <= dt.hour*60 + dt.minute <= 21*60
        stale = market_open and updated > 0 and (int(dt.timestamp()) - updated) > args.heartbeat

        if current > 0 and not stale:
            moved = abs(Decimal(px) - Decimal(current)) / Decimal(current)
            if moved < Decimal(args.deviation):
                print(f"{sym}: onchain {current}, computed {px}, moved {moved:.4%} < threshold, skip")
                continue
            print(f"{sym}: onchain {current}, computed {px}, moved {moved:.4%} -> PUSH")
        elif stale:
            age = int(dt.timestamp()) - updated
            print(f"{sym}: onchain {current}, computed {px}, age {age}s > heartbeat {args.heartbeat}s -> PUSH (heartbeat)")
        else:
            print(f"{sym}: never pushed, computed {px} -> PUSH")

        push_ids.append(fid)
        push_answers.append(px)

    if not push_ids:
        print("NOTHING_TO_PUSH: all feeds within deviation threshold")
        return 0

    ids_arg = "[" + ",".join(str(i) for i in push_ids) + "]"
    ans_arg = "[" + ",".join(str(a) for a in push_answers) + "]"
    hb_arg = "[" + ",".join(str(args.heartbeat) for _ in push_ids) + "]"

    tx = cast("send", args.registry,
              "batchPush(uint256[],int256[],uint64[])",
              ids_arg, ans_arg, hb_arg,
              "--rpc-url", args.rpc, "--private-key", args.private_key)
    txhash = next(l.split()[1] for l in tx.splitlines() if l.startswith("transactionHash"))
    print(f"batch tx {txhash} with {len(push_ids)} feeds")

    # readback through the AggregatorV3 proxy surface
    ok = True
    for fid, px in zip(push_ids, push_answers):
        proxy = cast("call", args.registry, "proxyOf(uint256)(address)", str(fid), "--rpc-url", args.rpc)
        out = cast("call", proxy, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--rpc-url", args.rpc)
        answer = int(out.split()[1].replace("[", "").replace(",", ""))
        status = "OK" if answer == px else "MISMATCH"
        if answer != px:
            ok = False
        print(f"feed {fid}: pushed {px}, proxy readback {answer} {status}")
    print("PUSHER_E2E_OK" if ok else "PUSHER_E2E_FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
