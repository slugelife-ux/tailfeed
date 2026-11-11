/**
 * tailfeed — zero-dependency client for TailFeed onchain price feeds.
 * Works in browsers and Node 18+ (global fetch). AggregatorV3-compatible.
 */

const SEL_GETFEED = '0xecb76d90'; // getFeed(uint256)
const SEL_LATEST_ROUND = '0xfeaf968c'; // latestRoundData()
const SEL_LATEST_ANSWER = '0x668a6e40'; // latestAnswer()
const SEL_DESCRIPTION = '0x728339aa'; // description()

const word = (hex, i) => BigInt('0x' + hex.slice(2 + i * 64, 2 + (i + 1) * 64));

function strip0x(h) { return h.startsWith('0x') ? h.slice(2) : h; }
function padId(id) { return strip0x(id.toString(16)).padStart(64, '0'); }

async function rpcCall(rpc, method, params) {
  const r = await fetch(rpc, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}

/**
 * @param {object} opts
 * @param {string} opts.rpc       JSON-RPC endpoint (default: public Robinhood Chain testnet)
 * @param {string} opts.registry  FeedRegistry address (default: testnet deployment)
 */
export function createClient(opts = {}) {
  const rpc = opts.rpc || 'https://rpc.testnet.chain.robinhood.com';
  const registry = opts.registry || '0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af';

  const call = (to, data) => rpcCall(rpc, 'eth_call', [{ to, data }, 'latest']);

  /** @param {number|bigint} feedId @returns {Promise<Feed>} */
  async function getFeed(feedId) {
    const hex = await call(registry, SEL_GETFEED + padId(feedId));
    return {
      feedId: BigInt(feedId),
      roundId: word(hex, 0),
      answer: BigInt.asIntN(256, word(hex, 1)),
      startedAt: Number(word(hex, 2)),
      updatedAt: Number(word(hex, 3)),
      proxy: '0x' + hex.slice(2 + 4 * 64 + 24, 2 + 5 * 64),
    };
  }

  /** Read a feed directly through its AggregatorV3 proxy address. */
  async function readProxy(proxy) {
    const hex = await call(proxy, SEL_LATEST_ROUND);
    return {
      roundId: word(hex, 0),
      answer: BigInt.asIntN(256, word(hex, 1)),
      startedAt: Number(word(hex, 2)),
      updatedAt: Number(word(hex, 3)),
      answeredInRound: word(hex, 4),
    };
  }

  /** Human-readable price: answer / 1e8, as a number (informational — keep BigInt for exact math). */
  function priceOf(feed) { return Number(feed.answer) / 1e8; }

  /** Age of the newest round in seconds (vs your local clock). */
  function ageOf(feed) { return Math.max(0, Math.floor(Date.now() / 1000) - feed.updatedAt); }

  return { rpc, registry, getFeed, readProxy, priceOf, ageOf };
}

export const TESTNET = {
  chainId: 46630,
  registry: '0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af',
  rpc: 'https://rpc.testnet.chain.robinhood.com',
  feeds: { CRM: 1, CIEN: 2, WDAY: 3 },
};
