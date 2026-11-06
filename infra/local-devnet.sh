#!/usr/bin/env bash
# Local EIP-8141 (Hegota) devnet: one ethrex (eip8141-tracer) + one Lighthouse, via Kurtosis and
# ethpandaops/ethereum-package, exactly as forshtat/mempool-workshop-sidecar's mining e2e does
# (test/e2e/ethrex-mining-devnet.sh, revision pins copied from there).
#   ./infra/local-devnet.sh up     # start (several minutes: Osaka -> Amsterdam -> Hegota over ~2 epochs)
#   ./infra/local-devnet.sh rpc    # print the ethrex RPC URL
#   ./infra/local-devnet.sh down
# Apple Silicon: the published ethrex image is amd64-only and segfaults under emulation; build it
# natively from the pinned commit and point ETHREX_IMAGE at it (see infra/build-ethrex-arm64.sh).
set -euo pipefail
ETHREX_IMAGE="${ETHREX_IMAGE:-ghcr.io/forshtat/ethrex:eip8141-tracer-latest}"
ENCLAVE="${PQV_ENCLAVE:-pqvault-devnet}"
PKG="github.com/ethpandaops/ethereum-package@b5b3af65248f11702216e377d0377bcd8ccf4caf"
CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kurtosis/eip8141-single-node.yaml"
el_service() { kurtosis enclave inspect "$ENCLAVE" 2>/dev/null | grep -o -E 'el-1-ethrex-[a-z0-9-]+' | head -1; }
case "${1:-}" in
  up)
    if ! docker image inspect "$ETHREX_IMAGE" >/dev/null 2>&1; then
      docker pull --platform linux/amd64 "$ETHREX_IMAGE"  # published image is linux/amd64 only
    fi
    docker tag "$ETHREX_IMAGE" ethrex:local
    docker image inspect "$ETHREX_IMAGE" --format 'ethrex image: {{.Id}} {{.Architecture}}'
    kurtosis engine start
    kurtosis enclave rm "$ENCLAVE" --force >/dev/null 2>&1 || true
    kurtosis run --enclave "$ENCLAVE" "$PKG" --args-file "$CFG"
    ;;
  rpc)
    echo "http://127.0.0.1:$(kurtosis port print "$ENCLAVE" "$(el_service)" rpc --format number)"
    ;;
  down)
    kurtosis enclave rm "$ENCLAVE" --force
    ;;
  *) echo "usage: $0 up|rpc|down" >&2; exit 2 ;;
esac
