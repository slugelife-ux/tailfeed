#!/usr/bin/env python3
"""Multipliers made visible: read a wallet's Stock Token positions on Robinhood Chain.

For each Stock Token the address holds, this prints:
- raw balanceOf (what generic tooling shows)
- uiMultiplier and the share-equivalent (balance x multiplier / 1e18)
- the token contract's own balanceOfUI as an independent cross-check
- the Chainlink feed price and USD value when a feed exists (feed is already
  multiplier-adjusted: USD = raw balance x feed price, never multiplied again)

Read-only. No key, no wallet, no signing. Fails loudly rather than guessing.

Usage: python3 rh_position_check.py --address 0x... [--rpc URL]
Exit 0 = every held position cross-checked clean. Exit 1 = any failure.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from urllib.request import Request, urlopen

ASSETS_URL = "https://api.robinhood.com/rhj/assets"
FEEDS_URL = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"
DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com"
CHAIN_ID = 4663
EXPLORER = "https://robinhoodchain.blockscout.com/address"

SEL_BALANCE = "70a08231"        # balanceOf(address)
SEL_BALANCE_UI = "437a9958"     # balanceOfUI(address)
SEL_UI_MULT = "a60bf13d"        # uiMultiplier()
SEL_ROUND = "feaf968c"          # latestRoundData()
SEL_DECIMALS = "313ce567"       # decimals()


class Fail(RuntimeError):
    pass


def http_json(url: str, data: bytes | None = None, timeout: int = 30):
    headers = {"User-Agent": "rh-position-check/1.0", "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    with urlopen(Request(url, data=data, headers=headers), timeout=timeout) as r:
        return json.loads(r.read().decode())


def rpc_call(rpc: str, method: str, params: list) -> dict:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    out = http_json(rpc, data=body, timeout=30)
    if "error" in out:
        raise Fail(f"{method}: {out['error']}")
    return out["result"]


def eth_call(rpc: str, to: str, data: str) -> str:
    return rpc_call(rpc, "eth_call", [{"to": to, "data": data}, "latest"])


def pad_addr(addr: str) -> str:
    a = addr.lower().replace("0x", "")
    if len(a) != 40:
        raise Fail(f"bad address: {addr}")
    return "0x" + "0" * 24 + a


def word(hexret: str) -> int:
    if not isinstance(hexret, str) or not hexret.startswith("0x") or len(hexret) < 66:
        raise Fail(f"short return {hexret}")
    return int(hexret[-64:], 16)


def load_tokens() -> list[dict]:
    assets = http_json(ASSETS_URL)["assets"]
    out = []
    for a in assets:
        for dep in a.get("deployments") or []:
            if dep.get("chainId") == CHAIN_ID and dep.get("contractAddress"):
                out.append({
                    "symbol": a["tokenSymbol"],
                    "name": a.get("tokenName") or "",
                    "token": dep["contractAddress"],
                    "api_multiplier": a.get("currentMultiplier") or "",
                })
                break
    return out


def load_feeds() -> dict[str, str]:
    feeds = http_json(FEEDS_URL)
    out = {}
    for f in feeds:
        base = (f.get("docs") or {}).get("baseAsset")
        if not base or not f.get("proxyAddress"):
            continue
        prev = out.get(base)
        if prev is None or ("24/7" in (f.get("name") or "") and "24/7" not in (prev or "")):
            out[base] = f["proxyAddress"]
    return out


def scan_balances(rpc: str, tokens: list[dict], address: str, workers: int = 8) -> dict[str, int]:
    """Return symbol -> nonzero raw balance. One failure marks the token unreadable."""
    def one(t):
        try:
            raw = eth_call(rpc, t["token"], "0x" + SEL_BALANCE + pad_addr(address)[2:])
            return t["symbol"], word(raw)
        except Exception as exc:
            return t["symbol"], Fail(f"balanceOf unreadable: {exc}")

    results = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for symbol, value in pool.map(one, tokens):
            results[symbol] = value
    return results


def read_feed(rpc: str, proxy: str) -> dict:
    dec = word(eth_call(rpc, proxy, "0x" + SEL_DECIMALS))
    raw = eth_call(rpc, proxy, "0x" + SEL_ROUND)
    body = raw[2:]
    if len(body) < 64 * 5:
        raise Fail(f"short latestRoundData from {proxy}")
    words = [body[i : i + 64] for i in range(0, 64 * 5, 64)]
    answer = int(words[1], 16)
    if answer >= 2**255:
        answer -= 2**256
    updated = int(words[3], 16)
    return {"answer": answer, "decimals": dec, "updatedAt": updated}


def check_position(rpc: str, token: dict, address: str, feed_proxy: str | None, now: int) -> dict:
    row = {
        "symbol": token["symbol"],
        "token": token["token"],
        "explorer": f"{EXPLORER}/{token['token']}",
        "status": "fail",
        "reasons": [],
    }
    raw_bal = word(eth_call(rpc, token["token"], "0x" + SEL_BALANCE + pad_addr(address)[2:]))
    row["raw_balance"] = raw_bal
    mult = word(eth_call(rpc, token["token"], "0x" + SEL_UI_MULT))
    row["ui_multiplier"] = mult
    share_equiv = Decimal(raw_bal) * Decimal(mult) / Decimal(10) ** 18
    row["share_equivalent"] = share_equiv

    if mult == 0:
        row["reasons"].append("uiMultiplier is zero")
    if token["api_multiplier"]:
        api_mult = Decimal(token["api_multiplier"])
        if abs(Decimal(mult) / Decimal(10) ** 18 - api_mult) > Decimal("1e-12"):
            row["reasons"].append(f"onchain multiplier {mult} != API {token['api_multiplier']}")

    ui = word(eth_call(rpc, token["token"], "0x" + SEL_BALANCE_UI + pad_addr(address)[2:]))
    row["balance_of_ui"] = ui
    if abs(Decimal(ui) - share_equiv) > Decimal(1):
        row["reasons"].append(
            f"cross-check failed: computed {share_equiv} != contract balanceOfUI {ui}"
        )

    if feed_proxy:
        feed = read_feed(rpc, feed_proxy)
        row["feed_proxy"] = feed_proxy
        row["feed_updated_at"] = feed["updatedAt"]
        row["feed_age_s"] = now - feed["updatedAt"]
        if feed["answer"] <= 0:
            row["reasons"].append("feed answer non-positive")
        price = Decimal(feed["answer"]) / Decimal(10) ** feed["decimals"]
        row["feed_price"] = price
        usd = Decimal(raw_bal) / Decimal(10) ** 18 * price
        row["usd_value"] = usd
    else:
        row["unpriced"] = True

    if not row["reasons"]:
        row["status"] = "pass"
    return row


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--address", required=True)
    ap.add_argument("--rpc", default=DEFAULT_RPC)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    addr = pad_addr(args.address)

    chain = int(rpc_call(args.rpc, "eth_chainId", []), 16)
    if chain != CHAIN_ID:
        print(f"refusing: rpc chain id {chain}, want {CHAIN_ID}", file=sys.stderr)
        return 2

    tokens = load_tokens()
    feeds = load_feeds()
    balances = scan_balances(args.rpc, tokens, args.address)
    held = {s: v for s, v in balances.items() if isinstance(v, int) and v > 0}
    unreadable = [s for s, v in balances.items() if isinstance(v, Fail)]

    now = int(time.time())
    rows = []
    for t in tokens:
        if t["symbol"] in held:
            try:
                rows.append(check_position(args.rpc, t, args.address, feeds.get(t["symbol"]), now))
            except Exception as exc:
                rows.append({"symbol": t["symbol"], "status": "fail", "reasons": [f"{type(exc).__name__}: {exc}"]})

    passed = [r for r in rows if r["status"] == "pass"]
    failed = [r for r in rows if r["status"] == "fail"]
    priced = [r for r in rows if r.get("usd_value") is not None]
    unpriced = [r for r in rows if r.get("unpriced")]
    total_usd = sum((r["usd_value"] for r in priced), Decimal(0))

    if args.json:
        json.dump({
            "chain_id": chain, "address": args.address, "checked_at": now,
            "tokens_scanned": len(tokens), "held": len(rows), "pass": len(passed),
            "fail": len(failed), "unreadable": unreadable,
            "total_usd": format(total_usd, "f"), "rows": rows,
        }, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
    else:
        print(f"chain {chain}  tokens scanned {len(tokens)}  held {len(rows)}  pass {len(passed)}  fail {len(failed)}")
        if unreadable:
            print(f"unreadable: {', '.join(unreadable)}")
        for r in rows:
            price = f"  feed {r['feed_price']}  ${r['usd_value']}" if r.get("feed_price") else "  no feed"
            print(
                f"{r['status']:4}  {r['symbol']:6}  raw {Decimal(r['raw_balance'])/Decimal(10)**18}  "
                f"mult {Decimal(r['ui_multiplier'])/Decimal(10)**18}  "
                f"shares {Decimal(r['share_equivalent'])/Decimal(10)**18}{price}"
            )
            if r["status"] == "fail":
                for reason in r["reasons"]:
                    print(f"         FAIL {reason}")
        if not rows:
            print("no Stock Token positions at this address")
        print(f"priced total ${total_usd}  unpriced positions {len(unpriced)}")
    return 0 if not failed and not unreadable else 1


if __name__ == "__main__":
    raise SystemExit(main())
