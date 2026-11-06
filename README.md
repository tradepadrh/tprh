# TradePad — a DEX for Pons v2 tokens on Robinhood Chain

## Repository layout
| Path | What it is |
|---|---|
| `web/index.html` | The DEX frontend. One self-contained file (DexPaprika data, ethers v6 wallet, lightweight-charts, Three.js, GSAP; background photo embedded). |
| `server.js` | Zero-dependency Node server for Railway. Serves `web/`, builds `/config.js` from env vars, exposes `/healthz`. |
| `package.json`, `railway.json` | Railway start command and health check. |
| `contracts/PonsRouter.sol` | Router with a frontend fee (max 1%). Routes to the Pons bonding curve (phase 0) or the Uniswap v4 pool + pons hook (phase 2). |
| `test/PonsRouter.t.sol` | 12 Foundry tests with mocks. |
| `script/Deploy.s.sol` | Contract deploy script for Robinhood Chain (chain id 4663). |
| `logo/` | TP logo SVGs. |

## 1. Push to GitHub
```bash
cd tradepad
git init
git add .
git commit -m "TradePad initial commit"
git branch -M main
git remote add origin https://github.com/<you>/tradepad.git
git push -u origin main
```
`.gitignore` already excludes `.env`, Foundry build output (`out/`, `cache/`, `broadcast/`) and `lib/`.

## 2. Deploy the frontend on Railway
1. Railway → **New Project → Deploy from GitHub repo** → pick `tradepad`.
2. Railway detects Node from `package.json` and runs `node server.js` (see `railway.json`). No build step is needed.
3. **Variables** (Settings → Variables):

| Variable | Required | Example | Notes |
|---|---|---|---|
| `ROUTER_ADDRESS` | after step 3 | `0xAbC…` | Your deployed PonsRouter. Leave empty until then. |
| `DEFAULT_FEE_BPS` | no | `50` | Fee shown before the router is read (50 = 0.5%). |
| `DEXPAPRIKA_API_KEY` | recommended | `api_…` | Free key from console.dexpaprika.com. Unlocks 15m/6H/1D charts and 7 days of history, and raises rate limits. Stays on the server. |
| `EXPLORER_URL` | no | `https://robinhoodchain.blockscout.com` | Override block explorer. |
| `DEXPAPRIKA_API` | no | `https://api.dexpaprika.com` | Override API base. |
| `ROADMAP_PHASE` | no | `1` | Roadmap phase that is live in the navbar (1 Trade, 2 Launch, 3 Radar, 4 Portfolio). Default 1. |
| `WALLETCONNECT_PROJECT_ID` | recommended | `3f2c…` (32 hex) | Free project id from cloud.reown.com. Turns on WalletConnect (QR + mobile wallets). Public value, not a secret. In Reown, add your site domain to the allowlist. |
| `PUBLIC_RPC_URL` | no | `https://rpc.mainnet.chain.robinhood.com` | Read-only RPC the browser uses for the Pons curve list. Public URLs only (it is visible to visitors). |

The assets table has a three-way menu: **Pons curve** (Pons v2 launches still on the bonding curve, read
on-chain from the Pons factory, with graduation progress), **Pons graduated** (Pons v2 graduates and Pons v1
tokens trading on Uniswap) and **Uniswap** (every other pair).

   `PORT` is set by Railway automatically. Do **not** add private keys or RPC keys here; the frontend never needs them (users sign with their own wallet).
4. Settings → Networking → **Generate Domain** (or add your own domain).
5. After changing a variable, Railway redeploys; `/config.js` picks up the new values.

## Market data (DexPaprika)
DexPaprika does not allow direct browser calls (no CORS), so live data needs `server.js`:
the page calls `/dp/...` and the server forwards to DexPaprika, caches each answer for about
60 seconds (all visitors share it), and adds `DEXPAPRIKA_API_KEY` if you set one.
Only Robinhood Chain endpoints used by the DEX are forwarded.

| | Without a key | With a free key |
|---|---|---|
| Pools, prices, gainers, new pairs, search | yes | yes |
| Chart | 1H candles, last 24h | 15m / 1H / 6H / 1D, last 7 days |
| Buy/sell activity | yes | yes |
| Trade list | no (DexPaprika Dev plan only) | no (Dev plan only) |

Static hosts (Netlify drop, Cloudflare Pages upload) have no server, so the page falls back to
sample data there. Use Railway (or any Node host) for live data.

## 3. Deploy the router contract (from your own computer, not Railway)
The router supports:
- **Pons v1 launches** (most live Pons tokens): Uniswap V3 pool against WETH, 1% fee tier.
- **Pons v2 launches**: bonding curve, then the Uniswap v4 pool with the pons hook.
- Any other token with a Uniswap V3 WETH pool.

Local values (put them in your terminal only; never on Railway or GitHub):

| Variable | Example | What it is |
|---|---|---|
| `RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | Public Robinhood Chain RPC (from the Pons docs) |
| `FEE_RECIPIENT` | `0xYourWallet` | Wallet that receives the frontend fees when you withdraw |
| `FEE_BPS` | `50` | Frontend fee: 50 = 0.5% (max 100 = 1%) |
| private key | asked by `deploy.sh` (hidden, not saved) | Deployer wallet with a little ETH on Robinhood Chain. It becomes the router **owner** (withdraw fees, change fee). |

Windows: open **Git Bash** and paste this one line (it unzips, installs Foundry if needed, runs the
tests, asks for the fee wallet and fee, then asks for the deployer private key without saving it):
```bash
cd ~/Downloads && { unzip -oq tradepad.zip || powershell.exe -NoProfile -Command "Expand-Archive -Force tradepad.zip ."; } && bash tradepad/deploy.sh
```
The router address is printed, copied to the clipboard and saved in `tradepad/router-address.txt`.

Manual alternative:
```bash
forge install foundry-rs/forge-std --no-git && forge test
export RPC_URL=https://rpc.mainnet.chain.robinhood.com FEE_RECIPIENT=0xYourWallet FEE_BPS=50
forge script script/Deploy.s.sol --rpc-url $RPC_URL --interactives 1 --broadcast
```
In the manual alternative, `--interactives 1` asks for the private key (on Windows terminals that prompt may not show; use `deploy.sh`).
The script first checks every address on-chain (Pons v2 factory, v4 PoolManager, SwapRouter02, its WETH
and V3 factory) and stops without deploying if anything does not match. It prints the router address.

Then on Railway set `ROUTER_ADDRESS` to that address (and `DEFAULT_FEE_BPS` to the same value as
`FEE_BPS`). Railway redeploys and the swap box starts working.

Withdraw fees: connect the owner wallet on the site and use "Withdraw fees" on the Revenue card,
or call `withdrawFees(0x0000000000000000000000000000000000000000)`. To move ownership to another
wallet: `transferOwnership(newOwner)` from the owner, then `acceptOwnership()` from the new wallet.

## Important notes
- The contract is NOT AUDITED, and Pons v2 itself has not finished its audits. Test on a fork first (`anvil --fork-url $RPC_URL`) with small amounts.
- For v4 pools the frontend quote is an estimate from DexPaprika prices; the router enforces the minimum output on-chain. For production, add an on-chain v4 quoter.
- Tokens with no Pons v2 launch and no Uniswap V3 WETH pool (for example USDG-only pools) are marked "not supported".
- Pons v1 launch protection: in the first blocks after a launch, each wallet can hold at most 5% of supply. Buys above that revert.
- Launching new tokens on Pons v2 is currently limited to whitelisted addresses (`canLaunch`).
- A value saved in the swap Settings (browser) overrides `ROUTER_ADDRESS` for that browser.
