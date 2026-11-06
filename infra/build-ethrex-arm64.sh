#!/usr/bin/env bash
# Build ethrex (forshtat/ethrex @ eip8141-tracer 9aa3645d, the commit the chain-1337 devnet reports) natively
# for linux/arm64 with ethrex's own Dockerfile. release-fast = opt-level 3 without LTO; -j 3 fits a 3 GB VM.
set -euo pipefail
SRC="${1:-vendor/ethrex-src}"
REV=9aa3645d795945c64400f41a70aace0edfa7f383
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC" && git -C "$SRC" init -q && git -C "$SRC" remote add origin https://github.com/forshtat/ethrex.git
  git -C "$SRC" fetch -q --depth 1 origin "$REV" && git -C "$SRC" checkout -q FETCH_HEAD
fi
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 --build-arg PROFILE=release-fast --build-arg BUILD_FLAGS="-j 3" \
  --build-arg GIT_SHA="$REV" --build-arg GIT_BRANCH=eip8141-tracer -t ethrex:eip8141-tracer-9aa3645d-arm64 "$SRC"
echo "ETHREX_IMAGE=ethrex:eip8141-tracer-9aa3645d-arm64 ./infra/local-devnet.sh up"
