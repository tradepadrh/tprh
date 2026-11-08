// TradePad server for Railway (no dependencies).
// - Serves files from ./web
// - /dp/*  : cached proxy to the DexPaprika API (browsers can't call it directly: no CORS).
//            Adds DEXPAPRIKA_API_KEY server-side when set, so the key never reaches the browser.
// - /config.js : runtime config built from environment variables
// - /healthz   : Railway health check
"use strict";

const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");
const path = require("node:path");
const dns = require("node:dns");
const net = require("node:net");

const PORT = Number(process.env.PORT) || 3000; // Railway injects PORT
const ROOT = path.join(__dirname, "web");
const NETWORK = "robinhood";

const API_ORIGIN = (process.env.DEXPAPRIKA_API || "https://api.dexpaprika.com").replace(/\/+$/, "");
const API_KEY = (process.env.DEXPAPRIKA_API_KEY || "").trim();
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
// ---------------------------------------------------------------- official site address
// SITE_URL = your public https address (for example https://tradepad.xyz). When set:
//  - requests on any other host name are sent there with a 301 (one official address, no look-alike copies on Railway URLs)
//  - /rpc and /verify only answer pages served from that address (other sites can't use your relays)
//  - browsers are told to always use HTTPS (HSTS)
//  - the page shows a warning if someone serves a copy of it from another address
// verification requests go to the team's Telegram chat and/or Discord channel (both optional)
const VERIFY_TG_BOT = (process.env.VERIFY_TG_BOT_TOKEN || "").trim(), VERIFY_TG_CHAT = (process.env.VERIFY_TG_CHAT_ID || "").trim();
const VERIFY_DISCORD = /^https:\/\/(discord\.com|discordapp\.com)\/api\/webhooks\/\d+\/[\w-]+$/.test((process.env.VERIFY_DISCORD_WEBHOOK || "").trim()) ? process.env.VERIFY_DISCORD_WEBHOOK.trim() : "";
const SUBMIT_ON = Boolean((/^\d+:[\w-]{30,}$/.test(VERIFY_TG_BOT) && /^-?\d+$|^@\w+$/.test(VERIFY_TG_CHAT)) || VERIFY_DISCORD);
let SITE = null;
try { const u = new URL((process.env.SITE_URL || "").trim()); if (u.protocol === "https:" && !u.username && !u.password) SITE = u; } catch {}
const hostOf = (req) => String(req.headers["x-forwarded-host"] || req.headers.host || "").split(",")[0].trim().toLowerCase();
function sameSite(origin) { if (!SITE) return true; try { return new URL(origin).host.toLowerCase() === SITE.host.toLowerCase(); } catch { return false; } }

// ---------------------------------------------------------------- config.js
function buildConfig() {
  const cfg = { API: "/dp", HAS_KEY: Boolean(API_KEY), RPC_PROXY: "/rpc", IMG_PROXY: "/img/ipfs/", VERIFY: "/verify" };
  const router = (process.env.ROUTER_ADDRESS || "").trim();
  if (router) {
    if (ADDRESS_RE.test(router)) cfg.ROUTER = router;
    else console.warn("[config] ROUTER_ADDRESS is not a valid 0x address, ignoring it");
  }
  const fee = Number(process.env.DEFAULT_FEE_BPS);
  if (Number.isInteger(fee) && fee >= 0 && fee <= 100) cfg.DEFAULT_FEE_BPS = fee;
  if (process.env.EXPLORER_URL) cfg.EXPLORER = process.env.EXPLORER_URL.replace(/\/+$/, "");
  const phase = Number(process.env.ROADMAP_PHASE);
  cfg.PHASE = Number.isInteger(phase) && phase >= 1 && phase <= 5 ? phase : 3;   // roadmap: phases up to this one are live
  if (SITE) cfg.SITE_URL = SITE.origin;
  // "Verified by TradePad": tokens the team approved (comma or space separated list on Railway)
  const team = [...new Set((process.env.VERIFIED_TOKENS || "").split(/[\s,]+/).filter(a => ADDRESS_RE.test(a)).map(a => a.toLowerCase()))].slice(0, 1000);
  if (team.length) cfg.TEAM_VERIFIED = team;
  if (SUBMIT_ON) cfg.SUBMIT = "/submit";
  // project info shown at the top of the page: edit these on Railway, no code change needed
  const ca = (process.env.TOKEN_CA || "").trim();
  if (ADDRESS_RE.test(ca)) cfg.TOKEN_CA = ca;
  const sym = (process.env.TOKEN_SYMBOL || "").trim().replace(/^\$/, "");
  if (/^[A-Za-z0-9]{1,12}$/.test(sym)) cfg.TOKEN_SYMBOL = sym;
  const x = (process.env.X_URL || "").trim();
  if (/^@?[A-Za-z0-9_]{1,15}$/.test(x)) cfg.X_URL = "https://x.com/" + x.replace(/^@/, "");
  else if (/^https:\/\/(x|twitter)\.com\/[A-Za-z0-9_]{1,15}\/?$/i.test(x)) cfg.X_URL = x.replace(/\/$/, "");
  const tg = (process.env.TELEGRAM_URL || "").trim();
  if (/^https:\/\/t\.me\/[A-Za-z0-9_+]{3,64}\/?$/i.test(tg)) cfg.TELEGRAM_URL = tg;
  // WalletConnect (mobile wallets, QR). A public project id from cloud.reown.com, not a secret.
  if (/^[0-9a-f]{32}$/i.test((process.env.WALLETCONNECT_PROJECT_ID || "").trim())) cfg.WC_PROJECT_ID = process.env.WALLETCONNECT_PROJECT_ID.trim();
  // public read-only RPC used by the browser for the Pons launch list (never put a private RPC key here)
  if (/^https:\/\//.test(process.env.PUBLIC_RPC_URL || "")) cfg.RPC = process.env.PUBLIC_RPC_URL.trim();
  return "window.TRADEPAD_CONFIG = " + JSON.stringify(cfg) + ";\n";
}
const CONFIG_JS = buildConfig();

// ---------------------------------------------------------------- helpers
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
};
const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  ...(SITE ? { "Strict-Transport-Security": "max-age=15552000" } : {}),
};
// Page CSP: scripts only from this site and the pinned CDNs; nobody may frame the DEX (clickjacking).
// connect-src stays open to https/wss because wallets (WalletConnect relay, Coinbase) talk to their own hosts.
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://esm.sh",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' data: https://fonts.gstatic.com https://fonts.reown.com",
  "img-src 'self' data: blob: https:",
  "connect-src 'self' https: wss:",
  "frame-src https://verify.walletconnect.com https://verify.walletconnect.org https://secure.walletconnect.org https://keys.coinbase.com",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
].join("; ");
function send(res, status, body, headers = {}) {
  res.writeHead(status, { ...SECURITY_HEADERS, ...headers });
  res.end(body);
}
const json = (res, status, obj) => send(res, status, JSON.stringify(obj), { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });

// ---------------------------------------------------------------- DexPaprika proxy
// Only the endpoints the DEX uses, only for Robinhood Chain.
const ALLOWED = [
  new RegExp(`^/networks/${NETWORK}/pools/search$`),
  new RegExp(`^/networks/${NETWORK}/pools/0x[0-9a-fA-F]{40,64}/ohlcv$`),
  new RegExp(`^/networks/${NETWORK}/pools/0x[0-9a-fA-F]{40,64}$`),
  new RegExp(`^/networks/${NETWORK}/tokens/0x[0-9a-fA-F]{40}$`),
  /^\/search$/,
  /^\/networks$/,
];
const cache = new Map();      // key -> { status, type, body, exp }
const inflight = new Map();   // key -> Promise
const MAX_ENTRIES = 400;

// With a key: if DexPaprika rejects it (401/403), answer the same request keyless instead of failing.
let keyWarned = false;
async function fetchUpstream(apiPath, search) {
  const r = await fetchOnce(apiPath, search, true);
  if (API_KEY && (r.status === 401 || r.status === 403)) {
    const free = await fetchOnce(apiPath, search, false);
    if (!keyWarned && free.status !== 401 && free.status !== 403) { keyWarned = true; console.warn("[dexpaprika] DEXPAPRIKA_API_KEY was rejected (" + r.status + "); answering keyless. Check the key in Railway variables."); }
    return free.status === 200 ? free : r;
  }
  return r;
}
function fetchOnce(apiPath, search, useKey) {
  return new Promise((resolve, reject) => {
    const url = new URL(API_ORIGIN + apiPath + search);
    const lib = url.protocol === "http:" ? http : https;
    const headers = { Accept: "application/json", "User-Agent": "TradePad/1.0 (+server.js)" };
    if (API_KEY && useKey) headers.Authorization = API_KEY;   // DexPaprika: the key is the whole header value
    const req = lib.get(url, { headers, timeout: 15000 }, (up) => {
      const chunks = [];
      up.on("data", (c) => chunks.push(c));
      up.on("end", () => {
        const body = Buffer.concat(chunks);
        const cc = String(up.headers["cache-control"] || "");
        const m = /max-age=(\d+)/.exec(cc);
        // successful responses: follow upstream max-age (15s..300s); errors: retry soon
        const ttl = up.statusCode === 200 ? Math.min(300, Math.max(15, m ? Number(m[1]) : 30)) : up.statusCode === 429 ? 20 : 5;
        resolve({ status: up.statusCode || 502, type: String(up.headers["content-type"] || "application/json"), body, ttl, exp: Date.now() + ttl * 1000 });
      });
      up.on("error", reject);
    });
    req.on("timeout", () => req.destroy(new Error("upstream timeout")));
    req.on("error", reject);
  });
}

function proxy(req, res, apiPath, search) {
  if (!ALLOWED.some((r) => r.test(apiPath))) return json(res, 404, { error: "not_allowed", message: "This API path is not proxied." });
  if (search.length > 600) return json(res, 414, { error: "query_too_long" });
  const key = apiPath + search;
  const reply = (e) => send(res, e.status, req.method === "HEAD" ? undefined : e.body, {
    "Content-Type": e.type,
    "Cache-Control": e.status === 200 ? `public, max-age=${Math.max(5, Math.round((e.exp - Date.now()) / 1000))}` : "no-store",
    "X-TradePad-Cache": e.hit ? "HIT" : "MISS",
  });
  const hit = cache.get(key);
  if (hit && hit.exp > Date.now()) return reply({ ...hit, hit: true });

  let p = inflight.get(key);
  if (!p) {
    p = fetchUpstream(apiPath, search)
      .then((e) => {
        cache.set(key, e);
        if (cache.size > MAX_ENTRIES) { const now = Date.now(); for (const [k, v] of cache) if (v.exp < now || cache.size > MAX_ENTRIES) cache.delete(k); }
        return e;
      })
      .finally(() => inflight.delete(key));
    inflight.set(key, p);
  }
  p.then(reply, (err) => {
    console.warn("[dp] upstream error:", err.message);
    if (hit) return reply({ ...hit, hit: true });        // serve stale data if DexPaprika is unreachable
    json(res, 502, { error: "upstream_unreachable", message: "DexPaprika could not be reached." });
  });
}

// ---------------------------------------------------------------- chain RPC relay
// The page reads Pons launches through /rpc, so visitors whose network blocks the public RPC still get data.
// Read-only methods only; nothing that can send a transaction.
const RPC_UPSTREAM = /^https?:\/\//.test(process.env.RPC_UPSTREAM || "") ? process.env.RPC_UPSTREAM.trim()      // local testing only
  : /^https:\/\//.test(process.env.PUBLIC_RPC_URL || "") ? process.env.PUBLIC_RPC_URL.trim() : "https://rpc.mainnet.chain.robinhood.com";
const RPC_METHODS = new Set(["eth_chainId", "net_version", "eth_blockNumber", "eth_getBlockByNumber", "eth_getLogs", "eth_call", "eth_getCode", "eth_getBalance", "eth_getTransactionByHash"]);
const rpcCache = new Map(), rpcInflight = new Map();
function rpcUpstream(body) {
  return new Promise((resolve) => {
    const u = new URL(RPC_UPSTREAM);
    const req = (u.protocol === "http:" ? http : https).request({ hostname: u.hostname, port: u.port || (u.protocol === "http:" ? 80 : 443), path: u.pathname + u.search, method: "POST", timeout: 20000,
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), "User-Agent": "tradepad-rpc" } }, (up) => {
      const chunks = []; let size = 0;
      up.on("data", (c) => { size += c.length; if (size > 25e6) up.destroy(); else chunks.push(c); });
      up.on("end", () => resolve({ status: up.statusCode || 502, body: Buffer.concat(chunks) }));
      up.on("error", () => resolve({ status: 502, body: Buffer.from('{"error":"upstream"}') }));
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve({ status: 502, body: Buffer.from('{"error":"upstream unreachable"}') }));
    req.end(body);
  });
}
function rpcRelay(req, res) {
  const chunks = []; let size = 0;
  req.on("data", (c) => { size += c.length; if (size > 256 * 1024) req.destroy(); else chunks.push(c); });
  req.on("end", async () => {
    const body = Buffer.concat(chunks).toString("utf8"); let msg;
    try { msg = JSON.parse(body); } catch { return json(res, 400, { error: "bad json" }); }
    const calls = Array.isArray(msg) ? msg : [msg];
    if (!calls.length || calls.length > 50 || calls.some(c => !c || !RPC_METHODS.has(c.method))) return json(res, 403, { error: "method not allowed" });
    const now = Date.now(), hit = rpcCache.get(body);
    if (hit && hit.exp > now) return send(res, hit.status, hit.body, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    let p = rpcInflight.get(body);
    if (!p) { p = rpcUpstream(body).finally(() => rpcInflight.delete(body)); rpcInflight.set(body, p); }
    const r = await p;
    if (r.status === 200) { rpcCache.set(body, { ...r, exp: now + 2000 }); if (rpcCache.size > 300) rpcCache.delete(rpcCache.keys().next().value); }
    send(res, r.status, r.body, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  });
}

// ---------------------------------------------------------------- IPFS images (Pons token logos)
// Token logos are ipfs:// links. The server fetches them once from public gateways and keeps them in memory.
const IPFS_GATEWAYS = ["https://gateway.pinata.cloud/ipfs/", "https://ipfs.io/ipfs/", "https://dweb.link/ipfs/"];
const CID_RE = /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{50,100})(\/[\w.\-]{1,80})?$/;
const imgCache = new Map(); let imgBytes = 0; const imgInflight = new Map();
function getOnce(url, max) {
  return new Promise((resolve) => {
    const req = https.get(url, { timeout: 15000, headers: { "User-Agent": "tradepad-img" } }, (up) => {
      if (up.statusCode >= 300 && up.statusCode < 400 && up.headers.location) { up.resume(); return resolve(getOnce(new URL(up.headers.location, url).href, max)); }
      const type = String(up.headers["content-type"] || "");
      if (up.statusCode !== 200 || !/^image\/(png|jpe?g|gif|webp|avif|svg\+xml)/.test(type)) { up.resume(); return resolve(null); }
      const chunks = []; let size = 0;
      up.on("data", (c) => { size += c.length; if (size > max) up.destroy(); else chunks.push(c); });
      up.on("end", () => resolve(size <= max ? { type, body: Buffer.concat(chunks) } : null));
      up.on("error", () => resolve(null));
    });
    req.on("timeout", () => req.destroy()); req.on("error", () => resolve(null));
  });
}
async function ipfsImage(req, res, cid) {
  if (!CID_RE.test(cid)) return send(res, 400, "bad cid");
  let hit = imgCache.get(cid);
  if (!hit) {
    let p = imgInflight.get(cid);
    if (!p) { p = (async () => { for (const g of IPFS_GATEWAYS) { const r = await getOnce(g + cid, 4e6); if (r) return r; } return null; })().finally(() => imgInflight.delete(cid)); imgInflight.set(cid, p); }
    hit = await p;
    if (!hit) return send(res, 404, "not found", { "Cache-Control": "public, max-age=300" });
    imgCache.set(cid, hit); imgBytes += hit.body.length;
    while (imgBytes > 80e6) { const [k, v] = imgCache.entries().next().value; imgCache.delete(k); imgBytes -= v.body.length; }
  }
  // SVGs are served as files the page only shows in <img>, with a strict sandbox
  send(res, 200, hit.body, { "Content-Type": hit.type, "Cache-Control": "public, max-age=31536000, immutable", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox" });
}

// ---------------------------------------------------------------- CA check on a token's own website / Telegram
// "Does the project's website or public Telegram channel show this exact contract address?"
// Fetches are SSRF-safe: public http(s) hosts only, no private or local addresses, size and time capped.
function privateIp(ip) {
  if (net.isIPv4(ip)) { const [a, b] = ip.split(".").map(Number);
    return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224; }
  const x = ip.toLowerCase(); return x === "::1" || x === "::" || x.startsWith("fc") || x.startsWith("fd") || x.startsWith("fe80") || x.startsWith("::ffff:") && privateIp(x.slice(7));
}
function safeLookup(host, opts, cb) {
  dns.lookup(host, { family: 0 }, (err, address, family) => {
    if (err) return cb(err);
    if (privateIp(address)) return cb(new Error("blocked address"));
    if (opts && opts.all) return cb(null, [{ address, family }]);
    cb(null, address, family);
  });
}
function fetchText(url, hops = 0) {
  return new Promise((resolve) => {
    let u; try { u = new URL(url); } catch { return resolve(null); }
    if (!/^https?:$/.test(u.protocol) || (u.port && !["80", "443"].includes(u.port)) || net.isIP(u.hostname) && privateIp(u.hostname)) return resolve(null);
    const lib = u.protocol === "http:" ? http : https;
    const req = lib.get(u, { lookup: safeLookup, timeout: 8000, headers: { "User-Agent": "Mozilla/5.0 (compatible; TradePadVerify/1.0)", Accept: "text/html,*/*" } }, (up) => {
      if (up.statusCode >= 300 && up.statusCode < 400 && up.headers.location && hops < 3) { up.resume(); return resolve(fetchText(new URL(up.headers.location, u).href, hops + 1)); }
      if (up.statusCode !== 200) { up.resume(); return resolve(null); }
      const chunks = []; let size = 0;
      up.on("data", (c) => { size += c.length; if (size > 1.5e6) up.destroy(); else chunks.push(c); });
      up.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      up.on("close", () => resolve(Buffer.concat(chunks).toString("utf8")));
      up.on("error", () => resolve(null));
    });
    req.on("timeout", () => req.destroy()); req.on("error", () => resolve(null));
  });
}
const verifyCache = new Map();
async function checkSite(ca, url, kind) {
  if (!url) return null;
  let target = url;
  if (kind === "tg") { const m = String(url).match(/^https?:\/\/(?:t\.me|telegram\.me)\/(?:s\/)?([A-Za-z0-9_]{4,32})\/?$/i); if (!m) return null; target = `https://t.me/s/${m[1]}`; }
  const key = ca + "|" + target, hit = verifyCache.get(key);
  if (hit && hit.exp > Date.now()) return hit.v;
  const text = await fetchText(target);
  const v = text == null ? null : text.toLowerCase().includes(ca.toLowerCase());
  verifyCache.set(key, { v, exp: Date.now() + (v == null ? 600e3 : 3600e3) });
  if (verifyCache.size > 3000) verifyCache.delete(verifyCache.keys().next().value);
  return v;
}
function verifyRoute(req, res) {
  const chunks = []; let size = 0;
  req.on("data", (c) => { size += c.length; if (size > 64 * 1024) req.destroy(); else chunks.push(c); });
  req.on("end", async () => {
    let list; try { list = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return json(res, 400, { error: "bad json" }); }
    if (!Array.isArray(list) || list.length > 30) return json(res, 400, { error: "send up to 30 items" });
    const items = list.filter(x => x && ADDRESS_RE.test(x.ca || "")).map(x => ({ ca: x.ca.toLowerCase(), web: typeof x.web === "string" ? x.web.slice(0, 200) : null, tg: typeof x.tg === "string" ? x.tg.slice(0, 200) : null }));
    const out = []; let i = 0;
    const worker = async () => { while (i < items.length) { const it = items[i++];
      const [web, tg] = await Promise.all([checkSite(it.ca, it.web, "web"), checkSite(it.ca, it.tg, "tg")]);
      out.push({ ca: it.ca, web, tg }); } };
    await Promise.all([worker(), worker(), worker(), worker()]);
    json(res, 200, out);
  });
}

// ---------------------------------------------------------------- verification requests ("Verified by TradePad")
// A project sends its CA and links with the form on the site. The server runs the automatic checks (is it a Pons launch,
// do its website / Telegram show the CA) and forwards everything to the team. The team approves a token by adding its
// CA to VERIFIED_TOKENS on Railway. Nothing here changes on-chain state; requests are rate limited per visitor.
const PONS_FACTORY = "0x7ed598bcef8bd9edd8c97a195c6d13f40801ec7e";
const submitHits = new Map(); let submitDay = { d: "", n: 0 };
const cleanText = (v, n) => typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f<>`]/g, " ").replace(/\s+/g, " ").trim().slice(0, n) : "";
function cleanUrl(v) {
  v = cleanText(v, 200); if (!v) return "";
  if (!/^https?:\/\//i.test(v)) v = "https://" + v;
  try { const u = new URL(v); return /^https?:$/.test(u.protocol) && u.hostname.includes(".") ? u.href : ""; } catch { return ""; }
}
function postJson(url, obj) {
  return new Promise((resolve) => {
    const body = JSON.stringify(obj), u = new URL(url);
    const r = https.request({ hostname: u.hostname, path: u.pathname + u.search, method: "POST", timeout: 10000, headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } },
      (up) => { up.resume(); up.on("end", () => resolve(up.statusCode >= 200 && up.statusCode < 300)); });
    r.on("timeout", () => r.destroy()); r.on("error", () => resolve(false)); r.end(body);
  });
}
async function ponsLaunch(ca) {   // factory.getLaunchedToken(ca): exists, deployer, phase
  const call = { jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: PONS_FACTORY, data: "0x3cf28b5a" + ca.slice(2).toLowerCase().padStart(64, "0") }, "latest"] };
  try {
    const r = await rpcUpstream(JSON.stringify(call)); const out = JSON.parse(r.body.toString("utf8")).result || "";
    const w = (out.slice(2).match(/.{64}/g) || []); if (w.length < 15) return null;
    return { exists: BigInt("0x" + w[14]) !== 0n, deployer: "0x" + w[2].slice(24), phase: Number(BigInt("0x" + w[10])) };
  } catch { return null; }
}
// ---- link previews (X, Telegram, Discord read these tags; the #t= part of a URL never reaches the server, /t/<CA> does)
const tokMeta = new Map();                          // ca -> { at, name, symbol }
function abiString(hex) {
  try { const h = String(hex || "").slice(2); if (h.length < 128) return ""; const len = Number(BigInt("0x" + h.slice(64, 128))); if (len > 64) return "";
    return Buffer.from(h.slice(128, 128 + len * 2), "hex").toString("utf8").replace(/[\u0000-\u001f]/g, "").trim(); } catch { return ""; }
}
async function tokenInfo(ca) {
  const hit = tokMeta.get(ca); if (hit && Date.now() - hit.at < 3600e3) return hit;
  const call = (data, id) => ({ jsonrpc: "2.0", id, method: "eth_call", params: [{ to: ca, data }, "latest"] });
  const timeout = new Promise((r) => setTimeout(() => r(null), 2500));
  const r = await Promise.race([rpcUpstream(JSON.stringify([call("0x06fdde03", 1), call("0x95d89b41", 2)])), timeout]);
  let name = "", symbol = "";
  try { const arr = JSON.parse(r.body.toString("utf8")); for (const x of arr) { if (x.id === 1) name = abiString(x.result); if (x.id === 2) symbol = abiString(x.result); } } catch {}
  const v = { at: Date.now(), name: name.slice(0, 48), symbol: symbol.slice(0, 16) };
  if (tokMeta.size > 2000) tokMeta.clear();
  if (symbol) tokMeta.set(ca, v);
  return v;
}
const htmlEsc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
async function appPage(req, res, ca) {
  let html;
  try { html = await fs.promises.readFile(path.join(ROOT, "index.html"), "utf8"); } catch { return send(res, 500, "Server error"); }
  const host = String(req.headers.host || "").toLowerCase();
  const origin = SITE ? SITE.origin : /^[a-z0-9.-]+(:\d+)?$/.test(host) ? `${req.headers["x-forwarded-proto"] === "http" ? "http" : "https"}://${host}` : "";
  let title = "TradePad · Native DEX on Robinhood Chain";
  let desc = "Trade Pons launches and Uniswap pairs on Robinhood Chain. Radar alerts, one-tap buys, safety checks. Your wallet confirms every trade.";
  let url = origin + "/";
  if (ca) {
    const t = await tokenInfo(ca);
    if (t.symbol) { title = `${t.symbol}${t.name && t.name !== t.symbol ? " (" + t.name + ")" : ""} · Trade on TradePad`; desc = `Chart, safety checks and one-tap buy for ${t.symbol} on Robinhood Chain. CA ${ca}`; }
    else desc = `Open token ${ca} on TradePad: chart, safety checks and one-tap buy on Robinhood Chain.`;
    url = origin + "/t/" + ca;
  }
  const img = origin + "/og.png";
  const meta = [
    `<meta name="description" content="${htmlEsc(desc)}">`,
    `<meta property="og:type" content="website">`, `<meta property="og:site_name" content="TradePad">`,
    `<meta property="og:title" content="${htmlEsc(title)}">`, `<meta property="og:description" content="${htmlEsc(desc)}">`,
    origin ? `<meta property="og:url" content="${htmlEsc(url)}">` : "",
    origin ? `<meta property="og:image" content="${htmlEsc(img)}">` : "", `<meta property="og:image:width" content="1200">`, `<meta property="og:image:height" content="630">`,
    `<meta name="twitter:card" content="summary_large_image">`, `<meta name="twitter:title" content="${htmlEsc(title)}">`, `<meta name="twitter:description" content="${htmlEsc(desc)}">`,
    origin ? `<meta name="twitter:image" content="${htmlEsc(img)}">` : "",
  ].filter(Boolean).join("\n");
  const body = html.replace("<!--META-->", meta);
  res.writeHead(200, { ...SECURITY_HEADERS, "Content-Security-Policy": CSP, "Content-Type": TYPES[".html"], "Cache-Control": "no-store, max-age=0" });
  res.end(req.method === "HEAD" ? undefined : body);
}
function submitRoute(req, res) {
  const ip = String(req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
  const now = Date.now(), day = new Date().toISOString().slice(0, 10);
  const hits = (submitHits.get(ip) || []).filter(t => now - t < 3600e3);
  if (hits.length >= 5) return json(res, 429, { error: "Too many requests. Try again in an hour." });
  if (submitDay.d !== day) submitDay = { d: day, n: 0 };
  if (submitDay.n >= 300) return json(res, 429, { error: "Requests are paused for today. Try again tomorrow." });
  const chunks = []; let size = 0;
  req.on("data", (c) => { size += c.length; if (size > 16 * 1024) req.destroy(); else chunks.push(c); });
  req.on("end", async () => {
    let b; try { b = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return json(res, 400, { error: "bad json" }); }
    const ca = cleanText(b && b.ca, 42).toLowerCase();
    if (!ADDRESS_RE.test(ca)) return json(res, 400, { error: "Enter the token's 0x contract address." });
    const contact = cleanText(b.contact, 80);
    if (contact.length < 3) return json(res, 400, { error: "Add a Telegram handle or email so we can reach you." });
    const web = cleanUrl(b.website), tgm = cleanText(b.telegram, 80).match(/^(?:https?:\/\/)?(?:t\.me\/|@)?([A-Za-z0-9_]{4,32})\/?$/), tg = tgm ? "https://t.me/" + tgm[1] : "";
    const xm = cleanText(b.x, 80).match(/^(?:https?:\/\/)?(?:www\.)?(?:x|twitter)\.com\/([A-Za-z0-9_]{1,15})|^@?([A-Za-z0-9_]{1,15})$/i), x = xm ? "@" + (xm[1] || xm[2]) : "";
    const name = cleanText(b.name, 40), note = cleanText(b.note, 400);
    hits.push(now); submitHits.set(ip, hits); submitDay.n++;
    if (submitHits.size > 5000) submitHits.delete(submitHits.keys().next().value);
    const [pons, onWeb, onTg] = await Promise.all([ponsLaunch(ca), checkSite(ca, web, "web"), checkSite(ca, tg, "tg")]);
    const yn = (v) => v === true ? "YES" : v === false ? "no" : "could not check";
    const lines = [
      "New verification request" + (name ? ": " + name : ""),
      "CA: " + ca,
      "Pons launch: " + (pons ? (pons.exists ? `YES (${pons.phase === 0 ? "on the curve" : pons.phase === 2 ? "graduated" : "phase " + pons.phase})` : "NO, not a Pons v2 launch") : "could not check"),
      pons && pons.exists ? "Creator: " + pons.deployer : "",
      "Website: " + (web || "none") + (web ? " | CA on page: " + yn(onWeb) : ""),
      "Telegram: " + (tg || "none") + (tg ? " | CA in channel: " + yn(onTg) : ""),
      "X: " + (x || "none") + (x ? " (check manually)" : ""),
      "Contact: " + contact,
      note ? "Note: " + note : "",
      "Explorer: https://robinhoodchain.blockscout.com/token/" + ca,
      "Approve: add this CA to VERIFIED_TOKENS on Railway.",
    ].filter(Boolean);
    const text = lines.join("\n");
    console.log("[verify-request]\n" + text);
    const sent = await Promise.all([
      VERIFY_TG_BOT && VERIFY_TG_CHAT ? postJson(`https://api.telegram.org/bot${VERIFY_TG_BOT}/sendMessage`, { chat_id: VERIFY_TG_CHAT, text, disable_web_page_preview: true }) : false,
      VERIFY_DISCORD ? postJson(VERIFY_DISCORD, { content: text.slice(0, 1900), allowed_mentions: { parse: [] } }) : false,
    ]);
    if (!sent.some(Boolean)) return json(res, 502, { error: "We could not deliver your request right now. Try again later." });
    json(res, 200, { ok: true, checks: { pons: pons ? pons.exists : null, web: web ? onWeb : null, tg: tg ? onTg : null } });
  });
}

// ---------------------------------------------------------------- server
const server = http.createServer((req, res) => {
  // health checks come from Railway itself on its own host name: always answer them
  if (req.url === "/healthz") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  // one official address: everything else is redirected there
  if (SITE && hostOf(req) !== SITE.host.toLowerCase()) {
    if (req.method !== "GET" && req.method !== "HEAD") return json(res, 403, { error: "use " + SITE.origin });
    return send(res, 301, "", { Location: SITE.origin + (req.url.startsWith("/") ? req.url : "/"), "Cache-Control": "no-store" });
  }
  if (req.method === "POST" && (req.url === "/rpc" || req.url === "/verify" || req.url === "/submit")) {
    if (SITE && !sameSite(req.headers.origin || "")) return json(res, 403, { error: "forbidden origin" });
    if (req.url === "/submit") return SUBMIT_ON ? submitRoute(req, res) : json(res, 503, { error: "Verification requests are not open yet." });
    return req.url === "/rpc" ? rpcRelay(req, res) : verifyRoute(req, res);
  }
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "Method Not Allowed", { Allow: "GET, HEAD, POST" });

  let url;
  try { url = new URL(req.url, "http://x"); } catch { return send(res, 400, "Bad Request"); }
  let urlPath;
  try { urlPath = decodeURIComponent(url.pathname); } catch { return send(res, 400, "Bad Request"); }

  if (urlPath === "/healthz") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  if (urlPath === "/config.js") return send(res, 200, CONFIG_JS, { "Content-Type": TYPES[".js"], "Cache-Control": "no-store, max-age=0" });
  if (url.pathname.startsWith("/dp/")) return proxy(req, res, url.pathname.slice(3), url.search);
  if (url.pathname.startsWith("/img/ipfs/")) return ipfsImage(req, res, url.pathname.slice(10));

  // the app page gets link-preview tags; /t/<CA> is a shared token link with that token's name in the preview
  const tok = /^\/t\/(0x[0-9a-fA-F]{40})\/?$/.exec(urlPath);
  if (urlPath === "/" || urlPath === "/index.html" || tok) return appPage(req, res, tok ? tok[1].toLowerCase() : "");
  if (urlPath.endsWith("/")) urlPath += "index.html";
  const file = path.normalize(path.join(ROOT, urlPath));
  if (!file.startsWith(ROOT + path.sep)) return send(res, 403, "Forbidden");

  fs.stat(file, (err, st) => {
    const target = !err && st.isFile() ? file : path.join(ROOT, "index.html"); // unknown paths fall back to the app
    const ext = path.extname(target).toLowerCase();
    const isHtml = ext === ".html";
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      ...(isHtml ? { "Content-Security-Policy": CSP } : {}),
      "Content-Type": TYPES[ext] || "application/octet-stream",
      // the app is one HTML file: never let a browser or CDN keep an old copy after a deploy
      "Cache-Control": isHtml || target.endsWith("config.js") || target.endsWith("sw.js") || ext === ".webmanifest" ? "no-store, max-age=0" : "public, max-age=3600",
    });
    if (req.method === "HEAD") return res.end();
    fs.createReadStream(target).on("error", () => res.destroy()).pipe(res);
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`TradePad listening on :${PORT}`);
  console.log("[config]", CONFIG_JS.trim());
  console.log(`[dp] proxy -> ${API_ORIGIN} (${API_KEY ? "with API key" : "keyless"})`);
});
