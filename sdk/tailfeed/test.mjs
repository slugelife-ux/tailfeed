// SDK smoke test against the live testnet registry — no mocks.
import { createClient, TESTNET } from './index.js';

const c = createClient({ rpc: TESTNET.rpc, registry: TESTNET.registry });

let failures = 0;
for (const [sym, id] of Object.entries(TESTNET.feeds)) {
  const feed = await c.getFeed(id);
  const viaProxy = await c.readProxy(feed.proxy);
  const ok = feed.answer > 0n && feed.answer === viaProxy.answer && feed.roundId === viaProxy.roundId;
  console.log(`${sym}: price ${c.priceOf(feed)} round ${feed.roundId} age ${c.ageOf(feed)}s ` +
    `registry-vs-proxy ${feed.answer === viaProxy.answer ? 'MATCH' : 'MISMATCH'} ${ok ? 'OK' : 'FAIL'}`);
  if (!ok) failures++;
}
process.exit(failures ? 1 : 0);
