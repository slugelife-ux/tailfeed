#!/usr/bin/env python3
"""TailFeed health run: one pass, one log line.

Checks BOTH oracle layers against the exchange's own quotes:
1. Chainlink's 33 mainnet feeds (wraps tools/rh_price_check.py)
2. TailFeed's own registry feeds on testnet (proxy readback vs API quote)

Appends a JSON line per run to ops/health_log/<date>.jsonl and prints a
human summary. Read-only; no keys.
"""

import json
import subprocess
import sys
import urllib.request
from decimal import Decimal, ROUND_HALF_UP
from datetime import datetime, timezone

ROOT = "/root/onchain-studio"
LOG_DIR = f"{ROOT}/ops/health_log"
TESTNET_RPC = "https://rpc.testnet.chain.robinhood.com"
REGISTRY = "0x96012E165CC81CfB56be3AF9F6ABBB72A39B6C9c"
HEARTBEAT_S = 300
TOLERANCE = Decimal("0.005")  # our feeds publish on >=0.5% moves; allow that


def http_json(url, retries=2):
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "rh-price-check/1.0", "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read().decode())
        except Exception:
            if attempt == retries:
                raise
            import time
            time.sleep(2 * (attempt + 1))


def read_feed(feed_id):
    """One chain read via cast — the RPC's WAF rejects python urllib, cast passes.
    getFeed(uint256) -> (roundId, answer, startedAt, updatedAt, proxy)"""
    out = subprocess.run(
        ["cast", "call", REGISTRY,
         "getFeed(uint256)(uint80,int256,uint256,uint256,address)",
         str(feed_id), "--rpc-url", TESTNET_RPC],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:100])
    lines = [l.strip().replace(",", "").split()[0]
             for l in out.stdout.strip().splitlines() if l.strip()]
    return {"roundId": int(lines[0]), "answer": int(lines[1]), "updatedAt": int(lines[3]),
            "proxy": lines[4]}


def market_open(ts):
    d = datetime.fromtimestamp(ts, tz=timezone.utc)
    if d.weekday() >= 5:
        return False
    m = d.hour * 60 + d.minute
    return 870 <= m < 1260  # 14:30-21:00 UTC


def main():
    now = int(datetime.now(tz=timezone.utc).timestamp())
    summary = {"ts": now, "utc": datetime.now(tz=timezone.utc).isoformat(timespec="seconds")}

    # 1. Chainlink feeds on mainnet
    try:
        out = subprocess.run(
            [sys.executable, f"{ROOT}/tools/rh_price_check.py", "--symbols", "all", "--json"],
            capture_output=True, text=True, timeout=600,
        )
        cl = json.loads(out.stdout)
        summary["chainlink"] = {"pass": cl["pass"], "fail": cl["fail"], "skip": cl["skip"],
                                "bad": [r["symbol"] for r in cl["rows"] if r.get("status") == "fail"]}
    except Exception as e:
        summary["chainlink"] = {"error": str(e)[:200]}

    # 2. Our feeds on testnet — compare onchain answer vs the API's own token quote
    import time as _time
    ours = {"pass": 0, "fail": 0, "bad": []}
    open_now = market_open(now)
    for f in json.load(open(f"{ROOT}/ops/testnet_feeds.json")):
        sym, fid = f["symbol"], f["id"]
        _time.sleep(4)  # burst limit: never hammer the quotes endpoint
        try:
            feed = read_feed(fid)
            answer = feed["answer"]
            updated = feed["updatedAt"]
            q = http_json(f"https://api.robinhood.com/rhj/prices/{sym}")["quotes"][0]
            tlo = (Decimal(q["tokenBid"]) * Decimal(10) ** 8).quantize(Decimal(1), rounding=ROUND_HALF_UP)
            thi = (Decimal(q["tokenAsk"]) * Decimal(10) ** 8).quantize(Decimal(1), rounding=ROUND_HALF_UP)
            if tlo <= answer <= thi:
                gap = Decimal(0)  # inside the exchange's own token quote
            else:
                nearer = min(abs(Decimal(answer) - tlo), abs(Decimal(answer) - thi))
                gap = nearer / Decimal(answer)
            stale = open_now and (now - updated) > HEARTBEAT_S * 6
            ok = gap <= TOLERANCE and not stale
            ours["pass" if ok else "fail"] += 1
            if not ok:
                ours["bad"].append(f"{sym}(gap={float(gap):.4%}{',stale' if stale else ''})")
        except Exception as e:
            ours["fail"] += 1
            ours["bad"].append(f"{sym}(error={str(e)[:80]})")
    summary["tailfeed"] = ours
    summary["market_open"] = open_now

    import os
    os.makedirs(LOG_DIR, exist_ok=True)
    day = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    with open(f"{LOG_DIR}/{day}.jsonl", "a") as fh:
        fh.write(json.dumps(summary) + "\n")

    cl_s = summary["chainlink"]
    cl_txt = f"chainlink {cl_s.get('pass','?')}P/{cl_s.get('fail','?')}F" + (f" bad={','.join(cl_s['bad'])}" if cl_s.get("bad") else "") if "error" not in cl_s else f"chainlink ERROR {cl_s['error'][:60]}"
    print(f"[{summary['utc']}] market={'open' if open_now else 'closed'} | tailfeed {ours['pass']}P/{ours['fail']}F"
          + (f" bad={','.join(ours['bad'])}" if ours["bad"] else " all-good") + f" | {cl_txt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
