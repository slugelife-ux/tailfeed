# TailFeed

Onchain price feeds for the Stock Tokens Chainlink doesn't cover — plus feed-health monitoring for every feed on Robinhood Chain.

**203 Stock Tokens trade on Robinhood Chain. Chainlink prices 33. The other 170 have no contract-readable price at all.** TailFeed publishes those missing prices as AggregatorV3-compatible feeds: if your contract already reads Chainlink, you swap one address and change nothing else.

- Status: **live on testnet** (chain 46630). Mainnet after a stable testnet window.
- Reads are free. Source is verified on the chain's own explorer. No token — none is needed.

## Live testnet deployment

| | address |
|---|---|
| FeedRegistry | [`0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af`](https://explorer.testnet.chain.robinhood.com/address/0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af) |
| TAIL CRM/USD | `0x4028E40d8596fB18870e63C3a9f1aa0109B96888` |
| TAIL CIEN/USD | `0xD320f571eC76eD9430B31e22bB2650bB4cfaae9C` |
| TAIL WDAY/USD | `0xf68E4699FC82708F76928eEDa90F553A80d013fa` |

Feeds are pushed every 5 minutes when a price moves ≥ 0.5% (deviation thresholded, like Chainlink) or on heartbeat. Rounds pause while the US market is closed — by design.

## Integrate

**Solidity — unchanged Chainlink pattern:**

```solidity
interface AggregatorV3Interface {
    function latestRoundData() external view
      returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

AggregatorV3Interface feed = AggregatorV3Interface(0xD320f571eC76eD9430B31e22bB2650bB4cfaae9C);
(, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
require(block.timestamp - updatedAt < 300, "stale");
// answer = 26401500000 → 264.015 USD at 8 decimals
```

**JavaScript — no library needed:**

```js
const r = await fetch('https://rpc.testnet.chain.robinhood.com', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call',
    params: [{ to: '0xD320f571eC76eD9430B31e22bB2650bB4cfaae9C',
               data: '0xfeaf968c' }, 'latest'] }),
});
const { result } = await r.json();
const answer = BigInt('0x' + result.slice(66, 130)); // int256, 8 decimals
```

**npm SDK** (`sdk/`): `tailfeed` — zero-dependency, typed, works in browser and node.

## How it works

- `FeedRegistry` holds all feeds. One pusher — fixed at construction, no owner functions, no mint, no upgrade — publishes rounds in a **single batch transaction** for all feeds that moved.
- Each feed gets its own `TailFeedProxy` at registration: a permanent, AggregatorV3-compatible read surface. Consumers integrate against the proxy address exactly like a Chainlink feed.
- Prices are derived with the Stock Token convention: underlying mid × `uiMultiplier`, 8 decimals — the same formula Robinhood's own `balanceOfUI` uses, cross-checked against live holder balances.
- Staleness is the reader's job (as with Chainlink): check `block.timestamp - updatedAt`. The registry also emits `StaleRound` events when a feed exceeded its heartbeat before an update.
- A scheduled pusher (cron) reads Robinhood's public REST API, applies the deviation threshold, and pushes. Runs on a throwaway testnet key; the mainnet pusher will sit behind a timelock/multisig with a full dry-run package first.

## Contract rules, kept

- Source verified for every contract, click it on the explorer.
- Fixed supply feeds (no token exists), no hidden mint, no upgrade path.
- One admin power, stated plainly: the pusher address. Set at construction, immutable.
- Reads free forever. Fees exist only if a product tier charges one — onchain reads never will.

## Repo layout

- `contracts/tail-oracle/` — Foundry project: `FeedRegistry`, `TailFeedProxy`, `TailPriceOracle` (standalone reference), tests (20 passing incl. invariant fuzz), e2e scripts, pusher.
- `web/` — static status site; reads the chain from the visitor's browser, no backend.
- `sdk/` — the npm package.
- `tools/` — feed-health checker (feed vs exchange quote) and position verifier.

## Monitoring

`tools/rh_price_check.py` checks every feed against the exchange's own quotes — ours and Chainlink's. It already caught a Chainlink feed sitting 0.40% off with a fresh heartbeat. Health alerts become a product tier later; the checker runs today.

## Not affiliated with Robinhood

"Stock Tokens" is Robinhood's own term for its tokenized-equity products. TailFeed is independent infrastructure. Testnet prices are for testing — not investment data.

## License

MIT
