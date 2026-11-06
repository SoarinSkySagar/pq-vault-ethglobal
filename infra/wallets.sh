#!/usr/bin/env bash
# Start / stop several PQ-Vault personal wallets for a demo (one browser tab each).
#
#   infra/wallets.sh start alice bob carol     # -> http://127.0.0.1:8201, :8202, :8203
#   infra/wallets.sh status
#   infra/wallets.sh stop
#
# Needs a running network with PQ-Vault contracts (infra/local-net.sh up). Each wallet keeps its keys and
# account under .devnet/local/wallets/<name>/; open its page and press "Create wallet" the first time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RUN=.devnet/local/wallets
BASE_PORT="${BASE_PORT:-8201}"

pick_python() {
  local c
  for c in "${PQV_PYTHON:-}" python3.12 python3.13 python3 "$HOME"/.local/share/uv/python/cpython-3.1*/bin/python3; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || [ -x "$c" ] || continue
    "$c" -c 'import hashlib; hashlib.new("KECCAK-256")' >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo "no Python with KECCAK-256 (OpenSSL >= 3.2); set PQV_PYTHON" >&2; exit 1
}

cmd_start() {
  [ $# -gt 0 ] || { echo "usage: $0 start <name> [<name> ...]" >&2; exit 2; }
  local py port=$BASE_PORT name
  py="$(pick_python)"
  mkdir -p "$RUN"
  for name in "$@"; do
    if [ -f "$RUN/$name/server.pid" ] && kill -0 "$(cat "$RUN/$name/server.pid")" 2>/dev/null; then
      echo "$name: already running on http://127.0.0.1:$(cat "$RUN/$name/server.port")"
    else
      mkdir -p "$RUN/$name"
      nohup "$py" -m pqv.wallet "$name" --port "$port" > "$RUN/$name/server.log" 2>&1 &
      echo $! > "$RUN/$name/server.pid"; echo "$port" > "$RUN/$name/server.port"
      until curl -sf "http://127.0.0.1:$port/api/state" >/dev/null 2>&1; do
        kill -0 "$(cat "$RUN/$name/server.pid")" 2>/dev/null || { echo "$name: failed, see $RUN/$name/server.log" >&2; exit 1; }
        sleep 1
      done
      echo "$name: http://127.0.0.1:$port"
    fi
    port=$((port + 1))
  done
}

cmd_status() {
  local d name
  for d in "$RUN"/*/; do
    [ -f "$d/server.pid" ] || continue
    name="$(basename "$d")"
    if kill -0 "$(cat "$d/server.pid")" 2>/dev/null; then echo "$name: http://127.0.0.1:$(cat "$d/server.port")"
    else echo "$name: stopped"; fi
  done
}

cmd_stop() {
  local d
  for d in "$RUN"/*/; do
    [ -f "$d/server.pid" ] || continue
    kill "$(cat "$d/server.pid")" 2>/dev/null || true
    rm -f "$d/server.pid"
    echo "$(basename "$d"): stopped"
  done
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  *) echo "usage: $0 start <name>... | status | stop" >&2; exit 2 ;;
esac
