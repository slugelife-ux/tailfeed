/* TailFeed live status — reads the chain directly from the browser.
 * No backend, no keys: eth_call to the public Robinhood Chain testnet RPC.
 */
const RPC = 'https://rpc.testnet.chain.robinhood.com';
const REGISTRY = '0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af';
const EXPLORER = 'https://explorer.testnet.chain.robinhood.com/address/';
const FEEDS = [
  { id: 1, name: 'TAIL CRM/USD' },
  { id: 2, name: 'TAIL CIEN/USD' },
  { id: 3, name: 'TAIL WDAY/USD' },
  { id: 4, name: 'TAIL DIS/USD' },
  { id: 5, name: 'TAIL BA/USD' },
  { id: 6, name: 'TAIL F/USD' },
  { id: 7, name: 'TAIL ADBE/USD' },
  { id: 8, name: 'TAIL CSCO/USD' },
];
const HEARTBEAT_S = 300;

const SEL_GETFEED = '0xecb76d90'; // getFeed(uint256)

function rpc(method, params) {
  return fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  }).then((r) => r.json());
}

function call(to, data) {
  return rpc('eth_call', [{ to, data }, 'latest']).then((j) => j.result);
}

const word = (hex, i) => BigInt('0x' + hex.slice(2 + i * 64, 2 + (i + 1) * 64));

function parseFeed(hex) {
  // getFeed(uint256) -> (uint80 roundId, int256 answer, uint64 startedAt, uint64 updatedAt, address proxy)
  return {
    roundId: word(hex, 0),
    answer: BigInt.asIntN(256, word(hex, 1)),
    startedAt: Number(word(hex, 2)),
    updatedAt: Number(word(hex, 3)),
    proxy: '0x' + hex.slice(2 + 4 * 64 + 24, 2 + 5 * 64),
  };
}

const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);

function marketOpen(nowTs) {
  // US equity hours, 14:30–21:00 UTC Mon–Fri (no holiday handling)
  const d = new Date(nowTs * 1000);
  const day = d.getUTCDay();
  if (day === 0 || day === 6) return false;
  const m = d.getUTCHours() * 60 + d.getUTCMinutes();
  return m >= 870 && m < 1260;
}

async function load() {
  const tbody = document.querySelector('#feed-table tbody');
  const nowTs = Math.floor(Date.now() / 1000);
  try {
    const feeds = await Promise.all(
      FEEDS.map((f) => call(REGISTRY, SEL_GETFEED + f.id.toString(16).padStart(64, '0')))
    );
    const rows = [];
    let anyFresh = false;
    for (let i = 0; i < FEEDS.length; i++) {
      const feed = parseFeed(feeds[i]);
      const age = Math.max(0, nowTs - feed.updatedAt);
      const fresh = age < HEARTBEAT_S * 3;
      if (fresh) anyFresh = true;
      rows.push(`<tr>
        <td>${FEEDS[i].name}</td>
        <td class="price">${(Number(feed.answer) / 1e8).toFixed(5)}</td>
        <td>${feed.roundId}</td>
        <td>${age < 90 ? 'just now' : Math.floor(age / 60) + 'm'}</td>
        <td><span class="dot ${fresh ? 'fresh' : 'stale'}"></span>${fresh ? 'fresh' : marketOpen(nowTs) ? 'moving' : 'closed'}</td>
        <td><a href="${EXPLORER}${feed.proxy}" target="_blank" rel="noopener">${short(feed.proxy)}</a></td>
      </tr>`);
    }
    tbody.innerHTML = rows.join('');
    const note = document.getElementById('market-note');
    if (!anyFresh) {
      note.hidden = false;
      note.textContent = marketOpen(nowTs)
        ? 'feeds are waiting for a ≥0.5% move — deviation-thresholded pushes are the gas design'
        : 'US market closed — prices only move when trading does. Rounds resume on the next real move.';
    } else {
      note.hidden = true;
    }
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="6" class="loading">rpc unreachable: ${e.message}</td></tr>`;
  }
}

load();
setInterval(load, 60_000);
