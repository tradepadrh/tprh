// TradePad static server for Railway (no dependencies).
// - Serves files from ./web
// - Serves /config.js built from environment variables, so the frontend can be
//   reconfigured on Railway without editing the HTML
// - /healthz for Railway health checks
"use strict";

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const PORT = Number(process.env.PORT) || 3000; // Railway injects PORT
const ROOT = path.join(__dirname, "web");

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

function buildConfig() {
  const cfg = {};
  const router = (process.env.ROUTER_ADDRESS || "").trim();
  if (router) {
    if (ADDRESS_RE.test(router)) cfg.ROUTER = router;
    else console.warn("[config] ROUTER_ADDRESS is not a valid 0x address, ignoring it");
  }
  const fee = Number(process.env.DEFAULT_FEE_BPS);
  if (Number.isInteger(fee) && fee >= 0 && fee <= 100) cfg.DEFAULT_FEE_BPS = fee;
  if (process.env.EXPLORER_URL) cfg.EXPLORER = process.env.EXPLORER_URL.replace(/\/+$/, "");
  if (process.env.DEXPAPRIKA_API) cfg.API = process.env.DEXPAPRIKA_API.replace(/\/+$/, "");
  return "window.TRADEPAD_CONFIG = " + JSON.stringify(cfg) + ";\n";
}
const CONFIG_JS = buildConfig();

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

const server = http.createServer((req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "Method Not Allowed", { Allow: "GET, HEAD" });

  let urlPath;
  try { urlPath = decodeURIComponent(new URL(req.url, "http://x").pathname); }
  catch { return send(res, 400, "Bad Request"); }

  if (urlPath === "/healthz") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  if (urlPath === "/config.js") return send(res, 200, CONFIG_JS, { "Content-Type": TYPES[".js"], "Cache-Control": "no-cache" });

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
      "Cache-Control": isHtml ? "no-cache" : "public, max-age=86400",
    });
    if (req.method === "HEAD") return res.end();
    fs.createReadStream(target).on("error", () => res.destroy()).pipe(res);
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`TradePad listening on :${PORT}`);
  console.log("[config]", CONFIG_JS.trim());
});
