#!/usr/bin/env bash
# TradePad: deploy PonsRouter to Robinhood Chain in one go (Git Bash on Windows, macOS or Linux).
#   bash deploy.sh
# Asks for the fee wallet and fee, then asks for the deployer's private key (hidden, never saved).
set -euo pipefail
cd "$(dirname "$0")"

lime() { printf '\033[1;38;5;190m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;38;5;190m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mStopped:\033[0m %s\n' "$*"; exit 1; }

lime "TradePad router deploy · Robinhood Chain (4663)"

# ---------------------------------------------------------------- 1. Foundry
step "1/5 Foundry"
export PATH="$HOME/.foundry/bin:$PATH"
if ! command -v forge >/dev/null 2>&1; then
  echo "Installing Foundry (first run only)..."
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|UCRT*|CLANG*|*_NT*)
      # Windows (Git Bash / MSYS2, including UCRT64): use the official Windows release zip directly
      mkdir -p "$HOME/.foundry/bin"
      ZIP="$(mktemp -d)/foundry.zip"
      curl -fL --progress-bar -o "$ZIP" https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_win32_amd64.zip \
        || fail "could not download Foundry. Check your internet connection."
      unzip -oq "$ZIP" -d "$HOME/.foundry/bin" 2>/dev/null \
        || powershell.exe -NoProfile -Command "Expand-Archive -Force '$(cygpath -w "$ZIP")' '$(cygpath -w "$HOME/.foundry/bin")'" \
        || fail "could not unpack Foundry."
      rm -f "$ZIP" ;;
    *)
      curl -sSfL https://foundry.paradigm.xyz | bash >/dev/null
      export PATH="$HOME/.foundry/bin:$PATH"
      foundryup ;;
  esac
  export PATH="$HOME/.foundry/bin:$PATH"
fi
command -v forge >/dev/null 2>&1 || fail "Foundry is not available. Install it from https://getfoundry.sh and run this again."
forge --version | head -1

# ---------------------------------------------------------------- 2. Libraries
step "2/5 Libraries"
if [ ! -f lib/forge-std/src/Script.sol ]; then
  forge install foundry-rs/forge-std --no-git
else
  echo "forge-std already installed."
fi

# ---------------------------------------------------------------- 3. Tests
step "3/5 Running the tests"
forge test || fail "tests failed, nothing was deployed."

# ---------------------------------------------------------------- 4. Settings
step "4/5 Settings"
RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
if [ -z "${FEE_RECIPIENT:-}" ]; then
  read -rp "Wallet that receives your fees (0x...): " FEE_RECIPIENT
fi
FEE_RECIPIENT="$(echo "$FEE_RECIPIENT" | tr -d '[:space:]')"
[[ "$FEE_RECIPIENT" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "'$FEE_RECIPIENT' is not a wallet address."
if [ -z "${FEE_BPS:-}" ]; then
  read -rp "Fee in basis points, 50 = 0.5%, max 100 [50]: " FEE_BPS
fi
FEE_BPS="${FEE_BPS:-50}"
[[ "$FEE_BPS" =~ ^[0-9]+$ ]] && [ "$FEE_BPS" -le 100 ] || fail "fee must be a number from 0 to 100."
export FEE_RECIPIENT FEE_BPS
echo "RPC:           $RPC_URL"
echo "Fee recipient: $FEE_RECIPIENT"
echo "Fee:           $FEE_BPS bps ($(awk "BEGIN{printf \"%.2f\", $FEE_BPS/100}")%)"

# ---------------------------------------------------------------- 5. Deploy
step "5/5 Deploying"
echo "The deployer wallet needs a little ETH on Robinhood Chain for gas and becomes the router owner."
if [ -z "${PRIVATE_KEY:-}" ]; then
  # read by bash itself: Windows terminals (Git Bash / UCRT64) often can't show forge's own hidden prompt
  read -rsp "Paste the deployer PRIVATE KEY (hidden, not saved), then Enter: " PRIVATE_KEY; echo
fi
PRIVATE_KEY="$(printf '%s' "$PRIVATE_KEY" | tr -d '[:space:]')"
[[ "$PRIVATE_KEY" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || { unset PRIVATE_KEY; fail "that is not a private key (64 hex characters)."; }
[[ "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY="0x$PRIVATE_KEY"
DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || true)"
[ -n "$DEPLOYER" ] && echo "Deployer / router owner: $DEPLOYER"
OUT="$(mktemp)"
set +e
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PRIVATE_KEY" 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}
set -e
unset PRIVATE_KEY
[ "$STATUS" -eq 0 ] || { rm -f "$OUT"; fail "deploy did not complete. Read the message above."; }
ROUTER="$(grep -o 'PonsRouter deployed at 0x[0-9a-fA-F]\{40\}' "$OUT" | awk '{print $4}' | tail -1)"
rm -f "$OUT"
[ -n "$ROUTER" ] || fail "could not find the router address in the output above."

echo "ROUTER_ADDRESS=$ROUTER" > router-address.txt
if command -v clip.exe >/dev/null 2>&1; then printf '%s' "$ROUTER" | clip.exe; COPIED=" (copied to clipboard)"
elif command -v pbcopy >/dev/null 2>&1; then printf '%s' "$ROUTER" | pbcopy; COPIED=" (copied to clipboard)"
else COPIED=""; fi

echo
lime "Done. Router deployed."
echo "ROUTER_ADDRESS = $ROUTER$COPIED"
echo "Saved in router-address.txt"
echo
echo "Next: Railway > your service > Variables:"
echo "  ROUTER_ADDRESS  = $ROUTER"
echo "  DEFAULT_FEE_BPS = $FEE_BPS"
