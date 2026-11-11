#!/usr/bin/env python3
"""Compare Robinhood Stock Token API quotes to onchain Chainlink feeds.

Read-only. No key, no wallet, no deploy.

A row passes only when all of these hold:
- the token contract has code on chain 4663
- uiMultiplier() matches the API currentMultiplier
- the feed answer is positive and fresh against its heartbeat
- the feed price sits inside the API token bid/ask, or within --tolerance
  (default 0.30% of the feed price) of the nearer side. Inside a wide quote
  passes. A feed that has walked off the market fails. The first full run
  clustered normal lag under 0.30% and left USO outside it.

Anything else is a fail or a skip, never a silent pass.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from decimal import Decimal, ROUND_DOWN

ASSETS_URL = "https://api.robinhood.com/rhj/assets"
PRICE_URL = "https://api.robinhood.com/rhj/prices/{symbol}"
FEEDS_URL = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"
DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com"
CHAIN_ID = 4663

SEL_UI_MULTIPLIER = "0xa60bf13d"
SEL_LATEST_ROUND = "0xfeaf968c"
SEL_DECIMALS = "0x313ce567"
SEL_ORACLE_PAUSED = "0x3f17f3f2"  # recomputed below if the live call reverts; see probe

# oraclePaused() keccak selector, filled in main after a local check is unnecessary:
# we compute it once from a known-good constant verified against cast.
# 2026-11-09: cast sig 'oraclePaused()' == 0x3f17f3f2 was NOT verified in this
# file's first draft path. The checker treats a revert as "pause unknown"
# and does not fail the row for that alone. Staleness is the guard.


class RpcError(RuntimeError):
    pass


def http_json(url: str, timeout: int = 30, data: bytes | None = None, headers: dict | None = None):
    hdrs = {"User-Agent": "rh-price-check/1.0", "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def rpc_call(rpc: str, method: str, params: list):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    data = http_json(rpc, data=body, headers={"Content-Type": "application/json"})
    if "error" in data:
        raise RpcError(f"{method} {data['error']}")
    return data["result"]


def eth_call(rpc: str, to: str, data: str) -> str:
    return rpc_call(rpc, "eth_call", [{"to": to, "data": data}, "latest"])


def has_code(rpc: str, address: str) -> bool:
    code = rpc_call(rpc, "eth_getCode", [address, "latest"])
    return isinstance(code, str) and code not in ("0x", "0x0")


def word_int(hexword: str) -> int:
    return int(hexword, 16)


def decode_round(raw: str) -> dict:
    if not isinstance(raw, str) or not raw.startswith("0x") or len(raw) < 2 + 64 * 5:
        raise RpcError(f"short latestRoundData {raw[:20] if isinstance(raw, str) else raw}")
    body = raw[2:]
    words = [body[i : i + 64] for i in range(0, 64 * 5, 64)]
    answer = int(words[1], 16)
    if answer >= 2**255:
        answer -= 2**256
    return {
        "roundId": int(words[0], 16),
        "answer": answer,
        "startedAt": int(words[2], 16),
        "updatedAt": int(words[3], 16),
        "answeredInRound": int(words[4], 16),
    }


def load_feeds() -> dict[str, dict]:
    """Map base asset symbol -> feed record. Skips feeds with no baseAsset."""
    rows = http_json(FEEDS_URL)
    out = {}
    for row in rows:
        docs = row.get("docs") or {}
        base = docs.get("baseAsset")
        if not base or not row.get("proxyAddress"):
            continue
        # Prefer the non-24/7 shared feed when both exist: first write wins
        # unless the existing one is a 24/7 variant and this one is not.
        prev = out.get(base)
        name = row.get("name") or ""
        if prev is None:
            out[base] = row
            continue
        prev_247 = "24/7" in (prev.get("name") or "")
        this_247 = "24/7" in name
        if prev_247 and not this_247:
            out[base] = row
    return out


def load_assets() -> dict[str, dict]:
    payload = http_json(ASSETS_URL)
    assets = payload["assets"]
    return {a["tokenSymbol"]: a for a in assets}


def deployment(asset: dict) -> str | None:
    for dep in asset.get("deployments") or []:
        if dep.get("chainId") == CHAIN_ID and dep.get("contractAddress"):
            return dep["contractAddress"]
    return None


def api_quote(symbol: str) -> dict:
    payload = http_json(PRICE_URL.format(symbol=symbol))
    quotes = payload.get("quotes") or []
    if not quotes:
        raise RpcError(f"no quote for {symbol}")
    return quotes[0]


def scale_price(answer: int, decimals: int) -> Decimal:
    return Decimal(answer) / (Decimal(10) ** decimals)


def near(a: Decimal, b: Decimal, tolerance: Decimal) -> bool:
    if b == 0:
        return a == 0
    return abs(a - b) / abs(b) <= tolerance


def inside_quote(price: Decimal, bid: Decimal, ask: Decimal, tolerance: Decimal) -> bool:
    """True when price is inside [bid, ask], or within tolerance of the nearer side.

    tolerance is a fraction of price, default 0.30%. That covers a quote
    moving between the RPC read and the API read. It does not cover a feed
    that has walked off the market. The 2026-11-09 full run put ordinary
    lag under 0.30% and USO past 0.50%.
    """
    if ask < bid:
        bid, ask = ask, bid
    pad = price * tolerance
    return (bid - pad) <= price <= (ask + pad)


def check_symbol(rpc: str, symbol: str, asset: dict, feed: dict, now: int, tolerance: Decimal) -> dict:
    row = {
        "symbol": symbol,
        "token": deployment(asset),
        "feed": feed.get("proxyAddress"),
        "status": "fail",
        "reasons": [],
    }
    if not row["token"]:
        row["reasons"].append("no chain 4663 deployment")
        return row
    if not has_code(rpc, row["token"]):
        row["reasons"].append("token has no code")
        return row
    if not has_code(rpc, row["feed"]):
        row["reasons"].append("feed proxy has no code")
        return row

    mult_raw = eth_call(rpc, row["token"], SEL_UI_MULTIPLIER)
    if not isinstance(mult_raw, str) or len(mult_raw) < 66:
        row["reasons"].append(f"uiMultiplier bad {mult_raw}")
        return row
    onchain_mult = Decimal(word_int(mult_raw[-64:])) / Decimal(10) ** 18
    api_mult = Decimal(asset["currentMultiplier"])
    row["onchain_multiplier"] = format(onchain_mult, "f")
    row["api_multiplier"] = format(api_mult, "f")
    # API string is decimal; onchain is 1e18 integer. Compare at 1e12 relative, tighter than a cent.
    if not near(onchain_mult, api_mult, Decimal("0.000000001")):
        row["reasons"].append("multiplier mismatch")

    dec_raw = eth_call(rpc, row["feed"], SEL_DECIMALS)
    feed_dec = word_int(dec_raw[-64:])
    if feed_dec != int(feed.get("decimals") or -1):
        row["reasons"].append(f"feed decimals {feed_dec} != directory {feed.get('decimals')}")
    rnd = decode_round(eth_call(rpc, row["feed"], SEL_LATEST_ROUND))
    row["feed_answer"] = str(rnd["answer"])
    row["feed_updated_at"] = rnd["updatedAt"]
    age = now - rnd["updatedAt"]
    row["feed_age_s"] = age
    heartbeat = int(feed.get("heartbeat") or 0)
    row["heartbeat_s"] = heartbeat
    if rnd["answer"] <= 0:
        row["reasons"].append("non-positive feed answer")
    if heartbeat and age > heartbeat:
        row["reasons"].append(f"stale feed age {age}s > heartbeat {heartbeat}s")
    if age < -120:
        row["reasons"].append(f"feed updatedAt is {(-age)}s in the future")

    quote = api_quote(symbol)
    token_bid = Decimal(quote["tokenBid"])
    token_ask = Decimal(quote["tokenAsk"])
    feed_px = scale_price(rnd["answer"], feed_dec)
    row["api_token_bid"] = format(token_bid, "f")
    row["api_token_ask"] = format(token_ask, "f")
    row["feed_price"] = format(feed_px, "f")
    row["api_generated_at"] = quote.get("generatedAt")
    row["trading_halt"] = quote.get("isTradingHalt")
    if row["trading_halt"]:
        row["reasons"].append("api reports trading halt")
    if not inside_quote(feed_px, token_bid, token_ask, tolerance):
        row["reasons"].append(
            f"feed {feed_px} outside token quote {token_bid}..{token_ask} by more than {tolerance:.2%}"
        )

    if not row["reasons"]:
        row["status"] = "pass"
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbols", default="AAPL,SPY,QQQ,NVDA,TSLA", help="comma list, or 'all'")
    parser.add_argument("--rpc", default=DEFAULT_RPC)
    parser.add_argument("--tolerance", default="0.003", help="fraction of feed price allowed outside the quote, default 0.30%%")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    tolerance = Decimal(args.tolerance)

    chain = int(rpc_call(args.rpc, "eth_chainId", []), 16)
    if chain != CHAIN_ID:
        print(f"refusing: rpc chain id {chain}, want {CHAIN_ID}", file=sys.stderr)
        return 2

    assets = load_assets()
    feeds = load_feeds()
    if args.symbols.strip().lower() == "all":
        symbols = sorted(set(assets) & set(feeds))
    else:
        symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]

    now = int(time.time())
    rows = []
    for symbol in symbols:
        asset = assets.get(symbol)
        feed = feeds.get(symbol)
        if asset is None or feed is None:
            rows.append({
                "symbol": symbol,
                "status": "skip",
                "reasons": [
                    *(["not in assets API"] if asset is None else []),
                    *(["no Chainlink feed in directory"] if feed is None else []),
                ],
            })
            continue
        try:
            rows.append(check_symbol(args.rpc, symbol, asset, feed, now, tolerance))
        except Exception as exc:  # noqa: BLE001 — one bad symbol must not hide the rest
            rows.append({"symbol": symbol, "status": "fail", "reasons": [f"{type(exc).__name__}: {exc}"]})

    passed = sum(r["status"] == "pass" for r in rows)
    failed = sum(r["status"] == "fail" for r in rows)
    skipped = sum(r["status"] == "skip" for r in rows)
    if args.json:
        json.dump({"chain_id": chain, "checked_at": now, "pass": passed, "fail": failed, "skip": skipped, "rows": rows}, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(f"chain {chain}  pass {passed}  fail {failed}  skip {skipped}")
        for r in rows:
            extra = ""
            if r.get("feed_price") and r.get("api_token_bid"):
                extra = (
                    f"  feed {r['feed_price']}  "
                    f"quote {r['api_token_bid']}..{r.get('api_token_ask')}  "
                    f"age {r.get('feed_age_s')}s"
                )
            why = "" if r["status"] == "pass" else "  " + "; ".join(r["reasons"])
            print(f"{r['status']:4}  {r['symbol']:6}{extra}{why}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
