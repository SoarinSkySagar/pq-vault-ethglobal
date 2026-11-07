#!/usr/bin/env bash
# Everything the PQ-Vault demo needs, in one command (devnet only, never real funds):
#
#   ./demo.sh                 same as ./demo.sh up
#   ./demo.sh up [--fresh] [--no-lan] [--wallets "alice bob carol"]
#   ./demo.sh status
#   ./demo.sh stop [--chain]  stop the wallets and the explorer (--chain: also pause the network; `up` resumes it)
#
# `up` is safe to re-run. It
#   1. brings up the local EIP-8141 network: reuses a running one, resumes stopped containers after a Docker
#      restart (same chain, contracts and wallets), or builds a fresh one with infra/local-net.sh up (~10 min;
#      also with --fresh, which archives the old local state)
#   2. makes sure the ERC-8421 [BUDGET-010] alt-mempool sidecar runs (the stock one rejects PQ-Vault)
#   3. starts the personal wallets (infra/wallets.sh), by default with phone access (HTTPS + pairing code)
#   4. creates each wallet's account if it has none, and tops up wallets below 0.1 ETH from the devnet faucet
#   5. starts the block explorer (pqv/explorer.py) and prints every URL and pairing code
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
LOCAL=.devnet/local
ENCLAVE="${PQV_ENCLAVE:-pqvault-devnet}"
EXPLORER_PORT="${EXPLORER_PORT:-8300}"
BASE_PORT="${BASE_PORT:-8201}"
HEGOTA_BLOCK=66        # frame transactions are enabled from here (infra/local-net.sh)
LOW_BALANCE_WEI=100000000000000000   # 0.1 ETH

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

pick_python() {   # a Python whose hashlib has KECCAK-256 (OpenSSL >= 3.2)
  local c
  for c in "${PQV_PYTHON:-}" python3.12 python3.13 python3 "$HOME"/.local/share/uv/python/cpython-3.1*/bin/python3; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || [ -x "$c" ] || continue
    "$c" -c 'import hashlib; hashlib.new("KECCAK-256")' >/dev/null 2>&1 && { echo "$c"; return; }
  done
  die "no Python with KECCAK-256 (needs OpenSSL >= 3.2); set PQV_PYTHON"
}

json_get() {  # json_get <file> <key>   (prints nothing if missing)
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except Exception: pass' "$1" "$2"
}

rpc_up() { [ -n "${1:-}" ] && cast chain-id --rpc-url "$1" >/dev/null 2>&1; }
sidecar_up() {
  curl -sf -m 5 -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------- 0. preflight
preflight() {
  log "checking tools"
  local t missing=()
  for t in docker cast forge curl openssl; do command -v "$t" >/dev/null || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "missing: ${missing[*]} (docker, foundry, curl, openssl)"
  docker info >/dev/null 2>&1 || die "Docker is not running"
  PY="$(pick_python)"
  ok "python: $PY"
  if [ ! -e third_party/JARDIN/.git ] || [ -z "$(ls -A third_party/JARDIN 2>/dev/null)" ]; then
    log "fetching the JARDIN / SPHINCS- submodules"
    git submodule update --init
  fi
  command -v qrencode >/dev/null || warn "qrencode not installed: no QR codes for phones (sudo apt install qrencode)"
}

# ----------------------------------------------------------------------------- 1. network
resume_chain() {   # restart this enclave's stopped node containers (execution, consensus, validator)
  local role ids
  for role in el cl vc; do
    ids="$(docker ps -a --filter "label=kurtosis_enclave_name=$ENCLAVE" --filter status=exited --format '{{.ID}} {{.Names}}' \
           | awk -v r="^$role-[0-9]+-" '$2 ~ r {print $1}')"
    [ -n "$ids" ] || continue
    # shellcheck disable=SC2086
    docker start $ids >/dev/null
    ok "restarted $role container(s)"
    if [ "$role" = el ]; then sleep 3; fi
  done
}

ensure_chain() {
  local rpc fresh="$1"
  rpc="$(json_get "$LOCAL/network.json" ethrex)"
  if [ "$fresh" = 1 ]; then
    log "fresh network requested"
  elif rpc_up "$rpc"; then
    ok "network already running: $rpc"
  elif [ -n "$rpc" ] && docker ps -a --filter "label=kurtosis_enclave_name=$ENCLAVE" --format '{{.Names}}' | grep -q '^el-'; then
    log "network stopped (Docker restart?): resuming the existing chain"
    resume_chain
    local i
    for i in $(seq 1 60); do rpc_up "$rpc" && break; sleep 2; done
    rpc_up "$rpc" || die "ethrex did not come back at $rpc; run ./demo.sh up --fresh for a new chain"
    ok "network resumed: $rpc"
  else
    log "no local network found"
    fresh=1
  fi
  if [ "$fresh" = 1 ]; then
    command -v kurtosis >/dev/null || die "a fresh network needs kurtosis"
    log "building a fresh network with infra/local-net.sh up (about 10 minutes)"
    infra/local-net.sh up budget010
    rpc="$(json_get "$LOCAL/network.json" ethrex)"
  fi
  [ -n "$(json_get "$LOCAL/deployment.json" factory)" ] \
    || die "the network has no PQ-Vault contracts (.devnet/local/deployment.json); run ./demo.sh up --fresh"

  # blocks must be advancing (a resumed beacon node takes a moment) and past the frame-tx fork
  local b0 b1 i
  b0="$(cast block-number --rpc-url "$rpc")"
  for i in $(seq 1 45); do
    sleep 2; b1="$(cast block-number --rpc-url "$rpc")"
    [ "$b1" -gt "$b0" ] && break
  done
  [ "$b1" -gt "$b0" ] || die "no new blocks after 90 s (block $b0); check: docker ps -a | grep -E '^(el|cl|vc)-'"
  if [ "$b1" -lt "$HEGOTA_BLOCK" ]; then
    log "waiting for frame transactions (block $HEGOTA_BLOCK, now $b1)"
    until [ "$(cast block-number --rpc-url "$rpc")" -ge "$HEGOTA_BLOCK" ]; do sleep 10; done
  fi
  ok "blocks advancing (block $(cast block-number --rpc-url "$rpc"))"
  RPC="$rpc"
}

ensure_sidecar() {
  local url image
  url="$(json_get "$LOCAL/network.json" sidecar)"
  if ! sidecar_up "$url"; then
    if docker ps -a --format '{{.Names}}' | grep -qx pqvault-sidecar; then
      log "starting the stopped alt-mempool sidecar"
      docker start pqvault-sidecar >/dev/null
    else
      log "starting the alt-mempool sidecar ([BUDGET-010])"
      infra/local-net.sh sidecar budget010
    fi
    local i
    for i in $(seq 1 60); do sidecar_up "$url" && break; sleep 2; done
    sidecar_up "$url" || die "the sidecar does not answer at $url (docker logs pqvault-sidecar)"
  fi
  image="$(docker inspect pqvault-sidecar --format '{{.Config.Image}}' 2>/dev/null || echo unknown)"
  case "$image" in
    *budget-010*) ok "alt mempool: $url ($image)" ;;
    *) warn "alt mempool runs $image: the stock image rejects PQ-Vault (100k validation cap)."
       warn "switch with: infra/local-net.sh sidecar budget010" ;;
  esac
}

# ----------------------------------------------------------------------------- 2. wallets
sync_wallet_network() {   # a wallet that saved its own node URLs follows the demo network after a fresh chain
  local d own shared
  shared="$(cat "$LOCAL/network.json")"
  for d in "$LOCAL"/wallets/*/; do
    [ -f "$d/network.json" ] || continue
    own="$(json_get "$d/network.json" ethrex)"
    if [ "$own" != "$(json_get "$LOCAL/network.json" ethrex)" ] && ! rpc_up "$own"; then
      echo "$shared" > "$d/network.json"
      ok "$(basename "$d"): node URL updated to the demo network"
    fi
  done
}

wallet_port() { cat "$LOCAL/wallets/$1/server.port"; }

api() {   # api <wallet> GET|POST <path>
  local port; port="$(wallet_port "$1")"
  if [ "$2" = POST ]; then curl -sf -m 30 -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$port$3"
  else curl -sf -m 30 "http://127.0.0.1:$port$3"; fi
}

run_job() {   # run_job <wallet> <path> <label>
  local job state
  job="$(api "$1" POST "$2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"])')" \
    || die "$1: could not start $3"
  while :; do
    sleep 2
    state="$(api "$1" GET "/api/jobs/$job" | python3 -c 'import json,sys
d = json.load(sys.stdin); print(d["state"] if d["state"] != "error" else "error: " + str(d.get("error"))[:200])')" || continue
    [ "$state" = running ] || break
  done
  [ "$state" = done ] || die "$1: $3 failed: $state"
}

ensure_wallets() {
  local lan="$1" name; shift
  sync_wallet_network
  log "starting wallets: $*"
  infra/wallets.sh stop >/dev/null 2>&1 || true
  if [ "$lan" = 1 ]; then BASE_PORT="$BASE_PORT" infra/wallets.sh start --lan "$@"
  else BASE_PORT="$BASE_PORT" infra/wallets.sh start "$@"; fi

  for name in "$@"; do
    local st has bal
    st="$(api "$name" GET /api/state)" || die "$name: wallet not answering"
    has="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d.get("account") else 0)' <<<"$st")"
    if [ "$has" = 0 ]; then
      log "$name: creating the account (three PQ keys, smart account, 1 test ETH; ~20 s)"
      run_job "$name" /api/create "account creation"
      ok "$name: account created"
    fi
    bal="$(api "$name" GET /api/state | python3 -c 'import json,sys; print(json.load(sys.stdin)["account"]["balanceWei"])')"
    if python3 -c 'import sys; sys.exit(int(sys.argv[1]) >= int(sys.argv[2]))' "$bal" "$LOW_BALANCE_WEI"; then
      log "$name: balance low, adding 1 test ETH"
      run_job "$name" /api/faucet "faucet"
    fi
  done
}

# ----------------------------------------------------------------------------- 3. explorer
explorer_running() { [ -f "$LOCAL/explorer.pid" ] && kill -0 "$(cat "$LOCAL/explorer.pid")" 2>/dev/null; }

ensure_explorer() {
  if explorer_running && curl -sf -m 5 -o /dev/null "http://127.0.0.1:$EXPLORER_PORT/"; then
    ok "explorer already running"
    return
  fi
  explorer_running && kill "$(cat "$LOCAL/explorer.pid")" 2>/dev/null || true
  nohup "$PY" -m pqv.explorer --network local --port "$EXPLORER_PORT" > "$LOCAL/explorer.log" 2>&1 &
  echo $! > "$LOCAL/explorer.pid"
  local i
  for i in $(seq 1 30); do curl -sf -m 5 -o /dev/null "http://127.0.0.1:$EXPLORER_PORT/" && break
    kill -0 "$(cat "$LOCAL/explorer.pid")" 2>/dev/null || die "explorer failed: see $LOCAL/explorer.log"; sleep 1; done
  ok "explorer started"
}

# ----------------------------------------------------------------------------- summary
summary() {
  local name port lan bal
  echo
  printf '\033[1mPQ-Vault demo is ready\033[0m  (chain %s, block %s)\n\n' "$(cast chain-id --rpc-url "$RPC")" "$(cast block-number --rpc-url "$RPC")"
  printf '  %-8s %-24s %-32s %-16s %s\n' wallet computer phone "pairing code" balance
  for name in "$@"; do
    port="$(wallet_port "$name")"
    lan="$(json_get "$LOCAL/wallets/$name/lan.json" url)"
    bal="$(api "$name" GET /api/state | python3 -c 'import json,sys; print("%.4f ETH" % (int(json.load(sys.stdin)["account"]["balanceWei"]) / 1e18))')"
    printf '  %-8s %-24s %-32s %-16s %s\n' "$name" "http://127.0.0.1:$port" "${lan:--}" \
      "$([ -n "$lan" ] && cat "$LOCAL/wallets/$name/pair-code" || echo -)" "$bal"
  done
  echo
  echo "  explorer  http://127.0.0.1:$EXPLORER_PORT"
  if [ -n "$(json_get "$LOCAL/wallets/$1/lan.json" url)" ]; then
    echo
    echo "  Phones (same Wi-Fi): install the devnet CA once from <phone url>/ca.crt, then open the wallet's"
    echo "  Phone screen on the computer and scan its QR code (or: infra/wallets.sh pair <name>)."
    echo "  Android over USB instead: adb reverse tcp:$BASE_PORT tcp:$BASE_PORT, open http://localhost:$BASE_PORT"
  fi
  echo
  echo "  ./demo.sh status | ./demo.sh stop [--chain]"
}

# ----------------------------------------------------------------------------- commands
cmd_up() {
  local fresh=0 lan=1 wallets="${DEMO_WALLETS:-alice bob carol}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh) fresh=1 ;;
      --no-lan) lan=0 ;;
      --wallets) shift; wallets="${1:?--wallets needs a list, e.g. \"alice bob carol\"}" ;;
      *) die "unknown option $1 (up [--fresh] [--no-lan] [--wallets \"a b c\"])" ;;
    esac
    shift
  done
  # shellcheck disable=SC2086
  set -- $wallets
  [ $# -ge 1 ] || die "no wallets given"
  [ $# -ge 3 ] || warn "shared 2-of-3 vaults need three wallets"
  preflight
  ensure_chain "$fresh"
  ensure_sidecar
  ensure_wallets "$lan" "$@"
  ensure_explorer
  summary "$@"
}

cmd_status() {
  local rpc; rpc="$(json_get "$LOCAL/network.json" ethrex)"
  if rpc_up "$rpc"; then echo "network:  $rpc  block $(cast block-number --rpc-url "$rpc")"; else echo "network:  down"; fi
  if sidecar_up "$(json_get "$LOCAL/network.json" sidecar)"; then
    echo "mempool:  $(json_get "$LOCAL/network.json" sidecar)  $(docker inspect pqvault-sidecar --format '{{.Config.Image}}' 2>/dev/null)"
  else echo "mempool:  down"; fi
  infra/wallets.sh status | sed 's/^/wallet:   /'
  if explorer_running; then echo "explorer: http://127.0.0.1:$EXPLORER_PORT"; else echo "explorer: stopped"; fi
}

cmd_stop() {
  infra/wallets.sh stop || true
  if explorer_running; then kill "$(cat "$LOCAL/explorer.pid")"; echo "explorer: stopped"; fi
  rm -f "$LOCAL/explorer.pid"
  if [ "${1:-}" = "--chain" ]; then
    docker stop pqvault-sidecar >/dev/null 2>&1 && echo "mempool: stopped" || true
    local ids
    ids="$(docker ps --filter "label=kurtosis_enclave_name=$ENCLAVE" --format '{{.ID}} {{.Names}}' | awk '$2 ~ /^(vc|cl|el)-[0-9]+-/ {print $1}')"
    # shellcheck disable=SC2086
    [ -z "$ids" ] || { docker stop $ids >/dev/null; echo "network: paused (./demo.sh up resumes it)"; }
  fi
}

case "${1:-up}" in
  up)     [ $# -gt 0 ] && shift; cmd_up "$@" ;;
  status) cmd_status ;;
  stop)   shift; cmd_stop "${1:-}" ;;
  -h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) die "usage: ./demo.sh [up [--fresh] [--no-lan] [--wallets \"a b c\"] | status | stop [--chain]]" ;;
esac
