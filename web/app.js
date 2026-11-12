/* TailFeed live engine — reads the chain straight from the visitor's browser.
   No backend, no keys, no analytics. eth_call to the public testnet RPC.
   Sections: boot animation → live feeds table → gap grid → tabs → copy →
   random price → refresh loop. */

const RPC = 'https://rpc.testnet.chain.robinhood.com';
const REGISTRY = '0x96012E165CC81CfB56be3AF9F6ABBB72A39B6C9c'; // FeedRegistryV2 — round history
const EXPLORER = 'https://explorer.testnet.chain.robinhood.com/address/';
const FEEDS = [
  { id: 1, sym: 'CRM', company: 'Salesforce' },
  { id: 2, sym: 'CIEN', company: 'Ciena' },
  { id: 3, sym: 'WDAY', company: 'Workday' },
  { id: 4, sym: 'DIS', company: 'Disney' },
  { id: 5, sym: 'BA', company: 'Boeing' },
  { id: 6, sym: 'F', company: 'Ford Motor' },
  { id: 7, sym: 'ADBE', company: 'Adobe' },
  { id: 8, sym: 'CSCO', company: 'Cisco Systems' },
  { id: 9, sym: 'QCOM', company: 'Qualcomm' },
  { id: 10, sym: 'PYPL', company: 'PayPal' },
  { id: 11, sym: 'UBER', company: 'Uber' },
  { id: 12, sym: 'XOM', company: 'ExxonMobil Holdings Corporation' },
  { id: 13, sym: 'JPM', company: 'JPMorgan Chase' },
  { id: 14, sym: 'PFE', company: 'Pfizer' },
  { id: 15, sym: 'LLY', company: 'Eli Lilly' },
  { id: 16, sym: 'GE', company: 'General Electric' },
  { id: 17, sym: 'IBM', company: 'IBM' },
  { id: 18, sym: 'COST', company: 'Costco' },
  { id: 19, sym: 'UNH', company: 'UnitedHealth' },
  { id: 20, sym: 'V', company: 'Visa' },
  { id: 21, sym: 'NFLX', company: 'Netflix' },
  { id: 22, sym: 'SOFI', company: 'SoFi Technologies' },
  { id: 23, sym: 'SNOW', company: 'Snowflake' },
  { id: 24, sym: 'CRWD', company: 'CrowdStrike Holdings' },
  { id: 25, sym: 'DDOG', company: 'Datadog' },
  { id: 26, sym: 'NET', company: 'Cloudflare,' },
  { id: 27, sym: 'SHOP', company: 'Shopify' },
  { id: 28, sym: 'ZM', company: 'Zoom' },
  { id: 29, sym: 'MDB', company: 'MongoDB' },
  { id: 30, sym: 'TEAM', company: 'Atlassian Corporation' },
  { id: 31, sym: 'SNAP', company: 'Snap' },
  { id: 32, sym: 'ZS', company: 'Zscaler' },
  { id: 33, sym: 'SMCI', company: 'Super Micro Computer' },
  { id: 34, sym: 'RBLX', company: 'Roblox' },
  { id: 35, sym: 'P', company: 'Everpure' },
  { id: 36, sym: 'ON', company: 'ON Semiconductor' },
  { id: 37, sym: 'APLD', company: 'Applied Digital' },
  { id: 38, sym: 'AEHR', company: 'Aehr' },
  { id: 39, sym: 'QBTS', company: 'D-Wave Quantum' },
  { id: 40, sym: 'SATS', company: 'EchoStar' },
  { id: 41, sym: 'FIX', company: 'Comfort Systems' },
  { id: 42, sym: 'MTSI', company: 'MACOM' },
  { id: 43, sym: 'DELL', company: 'Dell' },
  { id: 44, sym: 'MXL', company: 'MaxLinear' },
  { id: 45, sym: 'RUN', company: 'Sunrun' },
  { id: 46, sym: 'GLXY', company: 'Galaxy Digital' },
  { id: 47, sym: 'AVGO', company: 'Broadcom' },
  { id: 48, sym: 'CCL', company: 'Carnival Corporation' },
  { id: 49, sym: 'FICO', company: 'Fair Isaac' },
  { id: 50, sym: 'PR', company: 'Permian Resources' },
  { id: 51, sym: 'WYFI', company: 'WhiteFiber,' },
  { id: 52, sym: 'NNE', company: 'Nano Nuclear Energy' },
  { id: 53, sym: 'SKHY', company: 'SK hynix' },
  { id: 54, sym: 'CBRS', company: 'Cerebras Systems' },
  { id: 55, sym: 'FUTU', company: 'Futu Holdings' },
  { id: 56, sym: 'NU', company: 'Nu' },
  { id: 57, sym: 'RCAT', company: 'Red Cat' },
  { id: 58, sym: 'TTWO', company: 'Take-Two Interactive Software' },
  { id: 59, sym: 'VICR', company: 'Vicor' },
  { id: 60, sym: 'TSEM', company: 'Tower Semiconductor' },
];
const HEARTBEAT_S = 300;

const SEL_GETFEED = '0xecb76d90'; // getFeed(uint256) — registry
const SEL_GETROUND = '0x9a6fc8f5'; // getRoundData(uint80) — proxy, v1.1 history

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
  '> chain 46630 · registry 0x9601…C9c',
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

    // single-shot reads + click-to-expand sparkline from onchain round history
    const rows = feeds.map((feed, i) => {
      const f = FEEDS[i];
      const age = Math.max(0, nowTs - feed.updatedAt);
      const ageTxt = age < 90 ? 'just now' : Math.floor(age / 60) + 'm';
      const fresh = age < HEARTBEAT_S * 3 || !marketOpen(nowTs);
      const shortAddr = window.matchMedia('(max-width: 760px)').matches
        ? (a) => a.slice(0, 6) + '…' : short;
      return `<tr class="feed-row" data-i="${i}" title="click for round history">
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
    bindSparkRows();
  } catch (e) {
    document.getElementById('sync-msg').textContent = 'rpc unreachable — retrying on the next tick';
    tbody.innerHTML = `<tr><td colspan="5" class="loading">rpc unreachable: ${e.message} — will retry<span class="cursor">█</span></td></tr>`;
  }
}

/* ---------- sparklines from onchain round history (v1.1) ---------- */

function bindSparkRows() {
  document.querySelectorAll('tr.feed-row').forEach((tr) => {
    tr.onclick = () => toggleSpark(Number(tr.dataset.i), tr);
  });
}

async function toggleSpark(i, tr) {
  const next = tr.nextElementSibling;
  if (next && next.classList.contains('spark-row')) { next.remove(); return; }
  document.querySelectorAll('tr.spark-row').forEach((r) => r.remove());

  const row = document.createElement('tr');
  row.className = 'spark-row';
  const cell = document.createElement('td');
  cell.colSpan = 5;
  cell.innerHTML = 'reading rounds…';
  row.appendChild(cell);
  tr.after(row);

  try {
    const meta = FEEDS[i];
    const feed = parseFeed(await call(REGISTRY, SEL_GETFEED + padU(BigInt(meta.id))));
    const latest = Number(feed.roundId);
    if (latest === 0) {
      cell.innerHTML = `<span class="spark-note">${meta.sym}: no rounds yet — waiting for first push (halted or new)</span>`;
      return;
    }
    const first = Math.max(1, latest - 11);
    const ids = [];
    for (let r = first; r <= latest; ++r) ids.push(r);
    const answers = await Promise.all(ids.map((r) =>
      call(feed.proxy, SEL_GETROUND + padU(BigInt(r)))
        .then((h) => BigInt.asIntN(256, word(h, 1)))
        .catch(() => null)
    ));
    const pts = answers.map((a) => (a === null ? null : Number(a) / 1e8));
    const valid = pts.filter((p) => p !== null);
    if (valid.length < 2) {
      cell.innerHTML = `<span class="spark-note">${meta.sym}: only ${valid.length} round(s) onchain so far</span>`;
      return;
    }
    const W = 180, H = 40, PAD = 3;
    const min = Math.min(...valid), max = Math.max(...valid);
    const span = max - min || 1e-9;
    const step = (W - PAD * 2) / Math.max(1, pts.length - 1);
    const xy = pts.map((p, k) => (p === null ? null :
      `${(PAD + k * step).toFixed(1)},${(PAD + (1 - (p - min) / span) * (H - PAD * 2)).toFixed(1)}`))
      .filter(Boolean);
    const delta = ((valid[valid.length - 1] - valid[0]) / valid[0] * 100).toFixed(2);
    const up = valid[valid.length - 1] >= valid[0];
    cell.innerHTML =
      `<svg class="spark" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" aria-hidden="true">
         <polyline points="${xy.join(' ')}" fill="none" stroke="${up ? '#25FF45' : '#FF4545'}" stroke-width="1.5"/>
       </svg>
       <span class="spark-note">${meta.sym} · rounds ${first}\u2013${latest} · ${min.toFixed(2)}\u2013${max.toFixed(2)} · ${up ? '+' : ''}${delta}% over window</span>`;
  } catch (e) {
    cell.innerHTML = `<span class="spark-note">history read failed: ${e.message}</span>`;
  }
}

function bindProxyCopy() {
  document.querySelectorAll('.f-proxy').forEach((el) => {
    el.onclick = async (e) => {
      e.stopPropagation(); // don't toggle the sparkline when copying
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
