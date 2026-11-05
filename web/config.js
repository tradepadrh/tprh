// TradePad runtime config used only without server.js (static hosting shows sample data).
// On Railway this file is ignored: server.js builds /config.js from env vars instead.
// After deploying PonsRouter, put its address here and re-upload the web folder.
window.TRADEPAD_CONFIG = {
  ROUTER: "",          // e.g. "0xYourPonsRouterAddress"
  DEFAULT_FEE_BPS: 50, // 50 = 0.5%
};
