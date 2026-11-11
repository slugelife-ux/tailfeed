/* TailFeed live engine — reads the chain straight from the visitor's browser.
   No backend, no keys, no analytics. eth_call to the public testnet RPC.
   Sections: boot animation → live feeds table → gap grid → tabs → copy →
   random price → refresh loop. */

const RPC = 'https://rpc.testnet.chain.robinhood.com';
const REGISTRY = '0x05128EC5a91Ee365e1E8b38f83157A84A5b7f2Af';
const EXPLORER = 'https://explorer.testnet.chain.robinhood.com/address/';
const FEEDS = [
  { id: 1, sym: 'CRM',  company: 'Salesforce' },
  { id: 2, sym: 'CIEN', company: 'Ciena' },
  { id: 3, sym: 'WDAY', company: 'Workday' },
  { id: 4, sym: 'DIS',  company: 'Disney' },
  { id: 5, sym: 'BA',   company: 'Boeing' },
  { id: 6, sym: 'F',    company: 'Ford' },
  { id: 7, sym: 'ADBE', company: 'Adobe' },
  { id: 8, sym: 'CSCO', company: 'Cisco' },
  { id: 9, sym: 'QCOM', company: 'Qualcomm' },
  { id: 10, sym: 'PYPL', company: 'PayPal' },
  { id: 11, sym: 'UBER', company: 'Uber' },
  { id: 12, sym: 'XOM',  company: 'Exxon Mobil' },
  { id: 13, sym: 'JPM',  company: 'JPMorgan' },
  { id: 14, sym: 'PFE',  company: 'Pfizer' },
  { id: 15, sym: 'LLY',  company: 'Eli Lilly' },
  { id: 16, sym: 'GE',   company: 'GE' },
  { id: 17, sym: 'IBM',  company: 'IBM' },
  { id: 18, sym: 'COST', company: 'Costco' },
  { id: 19, sym: 'UNH',  company: 'UnitedHealth' },
  { id: 20, sym: 'V',    company: 'Visa' },
  { id: 21, sym: 'NFLX', company: 'Netflix' },
  { id: 22, sym: 'SOFI', company: 'SoFi' },
  { id: 23, sym: 'SNOW', company: 'Snowflake' },
  { id: 24, sym: 'CRWD', company: 'CrowdStrike' },
  { id: 25, sym: 'DDOG', company: 'Datadog' },
  { id: 26, sym: 'NET',  company: 'Cloudflare' },
  { id: 27, sym: 'SHOP', company: 'Shopify' },
  { id: 28, sym: 'ZM',   company: 'Zoom' },
  { id: 29, sym: 'MDB',  company: 'MongoDB' },
  { id: 30, sym: 'TEAM', company: 'Atlassian' },
];
const HEARTBEAT_S = 300;

const SEL_GETFEED = '0xecb76d90'; // getFeed(uint256) — registry
// NOTE: the proxy deliberately exposes no getRoundData — history is a v1.1 item.

/* ---------- chain plumbing ---------- */

function rpc(method, params) {
  return fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  }).then((r) => r.json());
}

function call(to, data) {
  return rpc('eth_call', [{ to, data }, 'latest']).then((j) => {
    if (!j.result) throw new Error(j.error ? j.error.message : 'empty result');
    return j.result;
  });
}

const word = (hex, i) => BigInt('0x' + hex.slice(2 + i * 64, 2 + (i + 1) * 64));

// getFeed(uint256) -> (uint80 roundId, int256 answer, uint64 startedAt, uint64 updatedAt, address proxy)
function parseFeed(hex) {
  return {
    roundId: word(hex, 0),
    answer: BigInt.asIntN(256, word(hex, 1)),
    startedAt: Number(word(hex, 2)),
    updatedAt: Number(word(hex, 3)),
    proxy: '0x' + hex.slice(2 + 4 * 64 + 24, 2 + 5 * 64),
  };
}

const padU = (n) => n.toString(16).padStart(64, '0');
const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);
const fmtPrice = (ans) => (Number(ans) / 1e8).toFixed(5);

/* ---------- market hours ---------- */

function marketOpen(nowTs) {
  const d = new Date(nowTs * 1000);
  const day = d.getUTCDay();
  if (day === 0 || day === 6) return false;
  const m = d.getUTCHours() * 60 + d.getUTCMinutes();
  return m >= 870 && m < 1260; // 14:30–21:00 UTC
}

/* ---------- boot animation ---------- */

const BOOT_LINES = [
  '$ ssh oracle@tailfeed',
  '> rpc.testnet…robinhood.com ok',
  '> chain 46630 · registry 0x0512…f2Af',
  '> source verified · pulling rounds …',
];

async function bootAnimation() {
  const el = document.getElementById('boot');
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let text = '';
  for (const line of BOOT_LINES) {
    for (const ch of line) {
      text += ch;
      el.textContent = text + '█';
      await sleep(14);
    }
    text += '\n';
    el.textContent = text;
    await sleep(160);
  }
}

/* ---------- live table ---------- */

async function loadFeeds() {
  const tbody = document.querySelector('#feed-table tbody');
  const nowTs = Math.floor(Date.now() / 1000);
  try {
    const raw = await Promise.all(
      FEEDS.map((f) => call(REGISTRY, SEL_GETFEED + padU(BigInt(f.id))))
    );
    const feeds = raw.map(parseFeed);
    document.getElementById('stat-feeds').textContent = feeds.length;
    document.getElementById('stat-rounds').textContent =
      feeds.reduce((s, f) => s + Number(f.roundId), 0);
    document.getElementById('gap-tf').textContent = feeds.length;

    // single-shot reads, no history fetch (proxies expose no getRoundData yet)
    const rows = feeds.map((feed, i) => {
      const f = FEEDS[i];
      const age = Math.max(0, nowTs - feed.updatedAt);
      const ageTxt = age < 90 ? 'just now' : Math.floor(age / 60) + 'm';
      const fresh = age < HEARTBEAT_S * 3 || !marketOpen(nowTs);
      const shortAddr = window.matchMedia('(max-width: 760px)').matches
        ? (a) => a.slice(0, 6) + '…' : short;
      return `<tr>
        <td><span class="f-sym">${f.sym}</span><span class="f-name">${f.company}<span class="fq"> · TAIL ${f.sym}/USD</span></span></td>
        <td class="f-price">${fmtPrice(feed.answer)}</td>
        <td class="f-round">${feed.roundId}</td>
        <td class="f-age ${fresh ? 'f-fresh' : ''}">${ageTxt}</td>
        <td><span class="f-proxy" data-addr="${feed.proxy}" title="click to copy">${shortAddr(feed.proxy)}</span></td>
      </tr>`;
    }).join('');

    tbody.innerHTML = rows;

    document.getElementById('sync-msg').textContent =
      `synced ${new Date().toLocaleTimeString()} · chain 46630 · ${marketOpen(nowTs) ? 'market open' : 'market closed'} · ${feeds.length} feeds read live`;
    bindProxyCopy();
  } catch (e) {
    document.getElementById('sync-msg').textContent = 'rpc unreachable — retrying on the next tick';
    tbody.innerHTML = `<tr><td colspan="5" class="loading">rpc unreachable: ${e.message} — will retry<span class="cursor">█</span></td></tr>`;
  }
}

function bindProxyCopy() {
  document.querySelectorAll('.f-proxy').forEach((el) => {
    el.onclick = async () => {
      try {
        await navigator.clipboard.writeText(el.dataset.addr);
        el.classList.add('copied');
        setTimeout(() => el.classList.remove('copied'), 1200);
      } catch { /* clipboard blocked — do nothing dramatic */ }
    };
  });
}

/* ---------- gap grid: 203 tokens, 33 chainlink, FEEDS.length ours, rest dark ---------- */

function buildGapGrid() {
  const grid = document.getElementById('gap-grid');
  const cells = [];
  for (let i = 0; i < 33; i++) cells.push('ch');
  for (let i = 0; i < FEEDS.length; i++) cells.push('tf');
  for (let i = 0; i < 203 - 33 - FEEDS.length; i++) cells.push('dark');
  grid.innerHTML = cells.map((c) => `<div class="cell ${c}"></div>`).join('');
}

/* ---------- tabs ---------- */

document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
    document.querySelectorAll('.tab-body').forEach((b) => b.classList.remove('active'));
    tab.classList.add('active');
    document.getElementById('tab-' + tab.dataset.tab).classList.add('active');
  });
});

/* ---------- random price button ---------- */

document.getElementById('btn-random').addEventListener('click', async (ev) => {
  const btn = ev.currentTarget;
  btn.textContent = 'reading chain…';
  try {
    const f = FEEDS[Math.floor(Math.random() * FEEDS.length)];
    const hex = await call(REGISTRY, SEL_GETFEED + padU(BigInt(f.id)));
    const feed = parseFeed(hex);
    btn.textContent = `feed me a random price`;
    document.getElementById('sync-msg').textContent =
      `${f.sym} $${fmtPrice(feed.answer)} · round ${feed.roundId} · read from chain just now — that's the whole product`;
  } catch {
    btn.textContent = 'rpc hiccup — click again';
  }
});

/* ---------- resync + refresh loop ---------- */

document.getElementById('btn-refresh').addEventListener('click', loadFeeds);

/* ---------- scrollspy: light the nav link of the section in view ---------- */

(() => {
  const links = [...document.querySelectorAll('.top nav a')];
  const map = new Map(links.map((l) => [l.getAttribute('href').slice(1), l]));
  const obs = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      links.forEach((l) => l.style.color = '');
      const link = map.get(e.target.id);
      if (link) link.style.color = '#25FF45';
    }
  }, { rootMargin: '-30% 0px -60% 0px' });
  map.forEach((_, id) => { const s = document.getElementById(id); if (s) obs.observe(s); });
})();

/* ---------- go ---------- */

buildGapGrid();
bootAnimation();
loadFeeds();
setInterval(() => { if (!document.hidden) loadFeeds(); }, 60_000);
