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
| `EXPLORER_URL` | no | `https://robinhoodchain.blockscout.com` | Override block explorer. |
| `DEXPAPRIKA_API` | no | `https://api.dexpaprika.com` | Override API base. |

   `PORT` is set by Railway automatically. Do **not** add private keys or RPC keys here; the frontend never needs them (users sign with their own wallet).
4. Settings → Networking → **Generate Domain** (or add your own domain).
5. After changing a variable, Railway redeploys; `/config.js` picks up the new values.

## 3. Deploy the router contract (from your own computer, not Railway)
```bash
forge install foundry-rs/forge-std
forge test
# verify addresses in script/Deploy.s.sol on https://robinhoodchain.blockscout.com first
FEE_RECIPIENT=0xYourWallet FEE_BPS=50 forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --private-key $PK --broadcast
```
Then put the printed address into Railway's `ROUTER_ADDRESS`.

Withdraw fees with `withdrawFees(0x0000000000000000000000000000000000000000)` for ETH (or the pair token address), or use the "Withdraw fees" button on the Revenue card while connected as the owner.

## Important notes
- The contract is NOT AUDITED, and Pons v2 itself has not finished its audits. Test on a fork first (`anvil --fork-url $RPC_URL`) with small amounts.
- For v4 pools the frontend quote is an estimate from DexPaprika prices; the router enforces the minimum output on-chain. For production, add an on-chain v4 quoter.
- The router only supports Pons v2 tokens. Pons v1 / non-Pons tokens are marked "not supported".
- Launching new tokens on Pons v2 is currently limited to whitelisted addresses (`canLaunch`).
- A value saved in the swap Settings (browser) overrides `ROUTER_ADDRESS` for that browser.
