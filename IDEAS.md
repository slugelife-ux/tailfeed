# IDEAS — the gap ledger

Every idea here is a gap: something a chain has, that nobody serves. Ideas move
through the same five questions before any code is written. This file is the
record; the `universal build` workspace drives the hunting.

## The five questions (an idea must survive all five)

1. **The gap.** What exists onchain that has no tool/feed/service serving it? Evidence, not vibes: count the things, show the number.
2. **The wedge.** Why can we ship it and the incumbents won't? (Usually: the tail is too small for them and exactly our size.)
3. **The build.** Is it shippable by a small team in weeks, on testnet, with public verification?
4. **The user.** Who is already building something that needs this *today*? Named protocols, not "developers".
5. **The earn.** Does it start free, get adopted, and have a paid tier that the product itself makes obvious?

## Ledger

### SHIPPED — TailFeed (Robinhood Chain, chain 46630/4663)
- **Gap:** 203 Stock Tokens onchain; Chainlink prices 33 of them. 170 tokens with no onchain price at all. Verified: live registry vs Chainlink feed list.
- **Wedge:** deviation-gated batch pushing makes the tail affordable — one tx for every moved feed. Incumbents optimize for head names.
- **Build:** shipped. 60 live feeds, round history (v1.1), hourly health audits, public uptime log. https://tailfeed.dev
- **User:** lending/basket/index builders on the chain (dossier in progress).
- **Earn:** reads free forever; paid tier = alerts, history API, feed subscriptions.

### CANDIDATE — Base B20 tail feeds (chain 8453) — RESEARCHED 2026-11-13, awaiting owner go
- **Gap:** 348 Coinbase tokenized stocks (B20) on Base; 12 have a Chainlink feed; 60 are minted with real supply and zero onchain price; 276 not yet minted (tail grows). Verified live: issuer API + onchain reads (`research/BASE_GAP.md`).
- **Wedge:** same as TailFeed — deviation-gated batch push makes the tail affordable; Chainlink optimizes for the 12 head names. Multiplier already onchain per token (`uiMultiplier`, ERC-8056 scheduled updates) so the Robinhood Chain position math ports 1:1.
- **Build:** two new repos under slugelife-ux: `b20-feeds` (contracts + pusher + health checker + status page, e2e on anvil fork of Base) and `b20-kit` (npm/PyPI SDK, free forever).
- **User:** Aave stock-backed lending (live, head-12 only), Base Request for Builders cohort (Greek, Grow, Tribeca, Renn, BitRepo) — all need per-token reference prices. npm/PyPI empty: data lane unclaimed.
- **Earn:** reads free forever; paid tiers = alerts, history API, feed subscriptions (paid-incumbent proof on sister chain: RobinhoodRPC $50–200/mo).
- Demand honesty: institutional signal strong (chain's own RFB + live Aave), direct user complaints unverified. 3.5/5, no 5/5 claimed.
- Failed/rejected this pass: neobrokerage/lending/exchange products (regulated, cohort-funded teams own them); read-only NAV viewer as the whole business (shop window only); Base Flashblocks migration tooling (no payment path).

### PARKED — xStocks (Backed) EVM feeds — researched 2026-11-13, failed the demand question
- **Gap (counted):** 61 xStocks ERC-20s on Ethereum alone (Backed's own CoW tokenlist); Chainlink's tokenized-equity issuers are Ondo/Robinhood/Coinbase only — 0 xStocks NAV feeds. The 13 Ethereum "Equities" feeds are underlying market data, not token feeds.
- **Why parked:** xStocks traction is Solana-side ($3B volume, 57k holders); EVM-side volume thin, no builder complaints found. Tokens are plain 1:1 (no multiplier system), so the tooling angle is weak too. Re-test if Backed EVM activity grows.

### CANDIDATE — Base consumer/games via Onchain Content Network — researched 2026-11-13, product lane, owner-gated
- **Gap (counted):** Base's distribution network (12 platforms incl. Coinbase Wallet, OpenSea, Rainbow) features projects from the Onchain Registry; only 25 games are in it, exactly 1 Curated, 0 Featured. Onchain Summer paid $5M+ to builders. Competition for featured game distribution is thin; our game-building capacity (Casino3D, Ball Arena) fits.
- **Wedge:** polished, playable onchain game submitted to the registry; Base's own distribution does the marketing.
- **Build:** a game product, not infra — separate decision, owner's call. Registry API counted and public.
- **User:** Base's own Onchain Content Network curators (they are asking for exactly this).
- **Earn:** game revenue + distribution reach; not a data business.
- Verdict: hold until b20-feeds Stage A–B ship; then this is the next bet.

### WATCH — B20-analog on other chains (monthly re-scan)
- B20 is Base-only; other OP Stack chains do not implement it. If any chain ships a chain-native asset standard (precompile tokens + multipliers + factory), port b20-kit there first. Checked 2026-11-13: none found (Monad, MegaETH, Arc, World Chain are plain ERC-20).

### TAKEN — Ink tokenized-equity oracles (2026-11-13)
- RedStone is Ink's official oracle provider (Nado RWA markets, xStocks infra). No lane for us. Ink Spark grants (500–20K USDC) fund RWA/agent infra — possible future small tool, application needs owner approval.


### NOTES — pass 2 lanes folded into existing products (2026-11-13)
- **x402 paid-API rail:** real rail, thin demand — 33,901 endpoints, only 738 with 10+ payers, top provider ≈ $4K/30d (ChainReport 2026-11-12). Base settles 99.2% of it. No tokenized-equity price endpoint on x402 yet → Stage E add-on for TailFeed/b20-feeds, not a standalone repo. Generic Robinhood Chain x402 data lane is TAKEN (MadeOnSol, bkrigmo1, covenant).
- **Feed-health alerting:** no dominant paid incumbent found; Chainlink puts data-quality burden on integrators; tokenized-equity feeds freeze during corporate actions. → Stage E alerts tier on our own products (health checker already runs hourly on Robinhood Chain).
- Full record: `research/CHAIN_LANES_PASS2.md`.



## Rules

- One idea = one entry = one owner = one status line.
- Numbers or it didn't happen: "170 of 203" beats "lots of tokens".
- A candidate that fails a question is kept with the failure written down —
  dead ideas are cheap to re-test, forgotten ones aren't.
- Shipped ideas link their repo, their site, and their uptime log.
