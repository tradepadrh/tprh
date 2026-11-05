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

const PORT = Number(process.env.PORT) || 3000; // Railway injects PORT
const ROOT = path.join(__dirname, "web");
const NETWORK = "robinhood";

const API_ORIGIN = (process.env.DEXPAPRIKA_API || "https://api.dexpaprika.com").replace(/\/+$/, "");
const API_KEY = (process.env.DEXPAPRIKA_API_KEY || "").trim();
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

// ---------------------------------------------------------------- config.js
function buildConfig() {
  const cfg = { API: "/dp", HAS_KEY: Boolean(API_KEY) };
  const router = (process.env.ROUTER_ADDRESS || "").trim();
  if (router) {
    if (ADDRESS_RE.test(router)) cfg.ROUTER = router;
    else console.warn("[config] ROUTER_ADDRESS is not a valid 0x address, ignoring it");
  }
  const fee = Number(process.env.DEFAULT_FEE_BPS);
  if (Number.isInteger(fee) && fee >= 0 && fee <= 100) cfg.DEFAULT_FEE_BPS = fee;
  if (process.env.EXPLORER_URL) cfg.EXPLORER = process.env.EXPLORER_URL.replace(/\/+$/, "");
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
};
const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};
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

function fetchUpstream(apiPath, search) {
  return new Promise((resolve, reject) => {
    const url = new URL(API_ORIGIN + apiPath + search);
    const lib = url.protocol === "http:" ? http : https;
    const headers = { Accept: "application/json", "User-Agent": "TradePad/1.0 (+server.js)" };
    if (API_KEY) headers.Authorization = API_KEY;   // DexPaprika: the key is the whole header value
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

// ---------------------------------------------------------------- server
const server = http.createServer((req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "Method Not Allowed", { Allow: "GET, HEAD" });

  let url;
  try { url = new URL(req.url, "http://x"); } catch { return send(res, 400, "Bad Request"); }
  let urlPath;
  try { urlPath = decodeURIComponent(url.pathname); } catch { return send(res, 400, "Bad Request"); }

  if (urlPath === "/healthz") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  if (urlPath === "/config.js") return send(res, 200, CONFIG_JS, { "Content-Type": TYPES[".js"], "Cache-Control": "no-cache" });
  if (url.pathname.startsWith("/dp/")) return proxy(req, res, url.pathname.slice(3), url.search);

  if (urlPath.endsWith("/")) urlPath += "index.html";
  const file = path.normalize(path.join(ROOT, urlPath));
  if (!file.startsWith(ROOT + path.sep)) return send(res, 403, "Forbidden");

  fs.stat(file, (err, st) => {
    const target = !err && st.isFile() ? file : path.join(ROOT, "index.html"); // unknown paths fall back to the app
    const ext = path.extname(target).toLowerCase();
    const isHtml = ext === ".html";
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": TYPES[ext] || "application/octet-stream",
      "Cache-Control": isHtml || target.endsWith("config.js") ? "no-cache" : "public, max-age=86400",
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
