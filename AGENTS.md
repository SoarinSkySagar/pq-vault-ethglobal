# AGENTS.md — handoff for agents (and humans) picking up PQ-Vault

Read this first. It is the state of the project as of 2026-11-06, what works, how to run it, where the
non-obvious traps are, and what is left. User-facing docs: `README.md`; research: `research/REPORT.md`;
devnet evidence: `docs/RECEIPTS.md`.

## 1. What this project is

**PQ-Vault**: a t-of-n post-quantum guardian wallet (n ≤ 16 guardians, threshold 2 ≤ t ≤ n, fixed at creation) on **EIP-8141 frame transactions** submitted through the
**ERC-8421 alternative mempool**, using **JARDIN** hash-based signatures (SPHINCS- family). Built for ETHGlobal
Mumbai 2026. Plus **research** on whether *stateful* hash-based signing survives crashes, stale backups, cloned
devices, interrupted signing and state rollback — with attacks, a mitigation, and measurements.

Hard rules the user set (keep them):
- **No ECDSA in the wallet** (the only ECDSA key is the throwaway devnet *deployer* that publishes contracts).
- **No custom cryptography** — signing/verification is upstream JARDIN code, unmodified (`third_party/JARDIN`).
- **Never fabricate results**; every number in docs must come from code in this repo. **Don't claim novelty**
  without evidence ("not found in the sources we reviewed" is the strongest allowed phrasing).
- **Devnet only, never real funds.**

## 2. Current state

| Area | State |
|---|---|
| Contracts (`contracts/src`) | t-of-n `PQVault` accepting two shapes: three frames (2 VERIFY + 1 SENDER, all approvals in VERIFY) and the two-frame fallback (1 VERIFY + SENDER) for combined-100k mempools; `PQVaultFactory`, `LeafLedger`, `PQVaultFrameOps.yul` (introspection with `maxCopy`). Foundry: **39/39 pass** |
| Python toolkit (`pqv/`) | frame-tx codec (matches ethrex golden vector), JARDIN wrapper, leaf stores, devnet driver for both shapes (`--frames`, default 3), UI server, receipts generator. **29/29 unittest pass** |
| Alt mempool | `infra/sidecar-budget010/`: ERC-8421 [BUDGET-010] per-entity budgets for the workshop sidecar (patch, 7 new tests, 393/393 executor tests pass, image build). Draft upstream PR text in its README, **not submitted** |
| Public hackathon devnet (chain 1337) | **No longer a target.** Historical: the old 2-of-3 two-frame design, 9 frame txs (`docs/RECEIPTS.md`). Current contract deployed 2026-11-06 (vault `0x9635f90861b370f6bd28fd98ddb1c1ae470b880f`, vault34 `0x605297343bb5669e259b73af0ceb15d855b0ead1`, factory `0xe0f42daea392db0bc42f1e7d2cece926b157fa02`; secrets in `.devnet/public/` on Sagar's machine only): its gateway admitted a 3-frame tx (no 100k cap any more) but included nothing in 15 min — see REPORT §8.1 |
| Local network (`infra/local-net.sh`) | **The target.** One command: Kurtosis ethrex eip8141-tracer + Lighthouse + skandha sidecar ([BUDGET-010] or stock). Run 1 `docs/RECEIPTS-three-frame.md` (commit ad291d5); run 2 `docs/RECEIPTS-two-frame-fallback.md`; run 3 (fresh, via local-net.sh, current code) `docs/RECEIPTS-local.md`. Old state archived under `.devnet/local/archive-*` and `run1-three-frame/` |
| Research | `research/REPORT.md` complete (§1–10), results in `research/results/*.json|md` |
| Demo | `demo/pq-vault-demo.mp4` (2:55), `demo/NARRATION.md`, `docs/DEMO.md` |
| UI | `app/index.html` served by `python -m pqv.server <network>` |

## 3. Repo map

```
contracts/src/PQVault.sol          t-of-n vault: validate() [both VERIFY frames], execute() [SENDER frame], guardian mgmt
contracts/src/LeafLedger.sol       per-slot high-water mark (monotone nullifier) + reportEquivocation
contracts/src/PQVaultFactory.sol   CREATE2 factory; owns the ledger; useLedger=false = JARDIN baseline vault
contracts/src/PQVaultFrameOps.yul  EIP-8141 opcode helper (TXPARAM/SIGPARAM/SIGDATACOPY/FRAMEPARAM/FRAMEDATALOAD/APPROVE)
contracts/src/Verifiers.sol        imports upstream JardinForsPlainVerifier / JardinSpxVerifier
contracts/src/external/            NaiveStakingRegistry (copied, MIT) — only deployed on local devnets
contracts/test/                    PQVault.t.sol, mocks (MockFrameOps, CodeBlobFrameOps), fixtures + generator
pqv/frametx.py, rlp.py             EIP-8141 frame tx codec (chain-1337 / ethrex 9aa3645d layout)
pqv/jardin.py                      guardian keys over upstream JARDIN signers; entry encoding; vault_message (domain PQ-Vault/v2)
pqv/state.py                       DurableLeafStore (burn-before-sign), AnchoredLeafStore (chain-anchored)
pqv/devnet.py                      CLI: deploy-infra, new-guardians, deploy-vault, transfer, rotate, recover, attack-stale-restore
pqv/server.py, app/index.html      local UI (127.0.0.1 only)
pqv/receipts.py                    regenerates docs/RECEIPTS.md from the chain
pqv/_shim/Crypto/Hash/keccak.py    stdlib KECCAK-256 adapter so JARDIN's Python imports work without pycryptodome
research/                          policies.py, sim.py, run_experiments.py, sweeps.py, crash_test.py, mempool_admission.py, REPORT.md, results/
infra/                             local-devnet.sh (Kurtosis), build-ethrex-arm64.sh, sidecar-local.sh, kurtosis/*.yaml,
                                   sidecar-budget010/ (ERC-8421 per-entity budget patch + build.sh)
demo/build_demo.py                 rebuilds the video from recorded data (Chrome headless + `say` + ffmpeg)
third_party/JARDIN, SPHINCS-       git submodules, pinned (JARDIN has no LICENSE file → never copy it, keep as submodule)
```

## 4. How to run

```sh
git submodule update --init
(cd contracts && forge build && forge test)                    # 39 tests
python3.12 -m unittest discover -s tests -t .                  # 29 tests (Ubuntu: use the uv python3.13, see §6)
python3.12 research/run_experiments.py --seeds 20              # ~10 min
python3.12 research/sweeps.py --seeds 10
python3.12 research/crash_test.py --kills 100
infra/local-net.sh up [budget010|stock]                        # local ethrex + Lighthouse + skandha (~10 min)
python3.12 -m pqv.server local --port 8143                     # UI
python3.12 -m pqv.receipts local --out docs/RECEIPTS-local.md  # receipts of the current local run
```
Devnet flow (fresh machine): `deploy-infra` → `new-guardians [--n 4]` → `deploy-vault --threshold 2 --fund 0.3 --stake 0.02
[--vault label]` → `transfer <to> <wei> --guardians 0,1 [--stateless 1] [--vault label]` → `rotate <g>` → `recover <g>` →
`attack-stale-restore`. `infra/local-net.sh up` brings up the network, funds the deployer, runs `deploy-infra` and the
[BUDGET-010] sidecar (`infra/local-net.sh sidecar stock` swaps in the stock image; use `--frames 2` with it).
Local devnet bring-up: `research/REPORT.md` §10.

## 5. State that is NOT in git (by design)

`.devnet/` holds secrets and per-machine state: `deployer.json` (throwaway ECDSA deployer key),
`<network>/guardians.json` (guardian master secrets + slot randomness), `guardian-*-leaves.json` (signer
leaf counters — **never hand-edit; reusing a leaf is the bug this project studies**), `deployment.json`,
`receipts.json`, `network.json`, relayer key. A new machine starts with `new-guardians` and redeploys; public
addresses and receipts of the existing deployment are recorded in `docs/RECEIPTS.md`.

Public devnet deployment (2026-11-06): vault `0x9127b9f1297eda2f04916c82d4b41fa53bb179a5`, factory
`0x7ad28d46e98df621776558fc7bfa3269da875ac6`, ledger `0x15c9a7285c8c45881616a7986f1303199e1bde23`,
FrameOps `0xa359c5aab9277c8234733a9a0d4f6daa22d03dac`, staking registry `0xd51c04d7a0b01124e84de152f4e56d9eecb22d2f`.
Without the guardian secrets in `.devnet/public/` that vault cannot be operated; deploy a new one.

## 6. Traps that cost hours (read before debugging)

- **Python**: needs OpenSSL ≥ 3.2 for native `KECCAK-256`: Homebrew `python3.12` on macOS; on the Ubuntu box the system
  `python3.12` has OpenSSL 3.0 (no keccak) → use the uv-managed `~/.local/share/uv/python/cpython-3.13.14-linux-x86_64-gnu/bin/python3`
  (OpenSSL 3.5). `'KECCAK-256' in hashlib.algorithms_available` is False there but `hashlib.new("KECCAK-256")` works.
- **Frame-tx sig hash** elides the bytes of every *empty-msg* signature entry; frame data is covered. PQ signatures
  go in `ARBITRARY` entries. Since the three-frame redesign every entry is verified in a VERIFY frame, so all guardians
  sign the same `messageFor(sigHash)` (domain `PQ-Vault/v2`) in any order; a relayer that corrupts any entry makes the
  tx invalid (no fee). The old two-frame `firstMessageFor` chaining (REPORT G6) is gone.
- **Two shapes, chosen by frame count.** `execute()` branches on `len(frames)`: 3 → every entry was verified in
  VERIFY (decode + consume only); 2 → `validateAndCommit()` verified entry 0 only, `execute()` verifies 1..t-1.
  Two-frame entry 0 (committer, compact only) signs `firstMessageFor(sigHash, restHash)` *after* the others sign
  `messageFor(sigHash)`; `restHash = keccak(keccak(e1)‖…‖keccak(e_{t-1}))`. VERIFY limit = 100,000 − 100·t.
  The driver's default shape: `network.json` "frames", else 3 (`--frames` overrides).
- **Shared guardians, per-vault governance**: rotate/recover act on one vault (`vault` label); other vaults that use
  the same guardians keep the old slots and refuse the new ones (`BadEntry(i, 5)`) until rotated there too.
- **Debugging a silently dropped privileged tx**: ethrex logs the payload builder's skip reason only at debug level;
  enable at runtime with `cast rpc --rpc-url <ethrex> admin_setLogLevel '"info,ethrex_blockchain=debug"'` and grep
  `skipping IL tx`. A local reading copy of ethrex @ 9aa3645d can live in `vendor/` (gitignored).
- **Transaction shape** (three frames; PQVault.validate pins it): sigs = t ARBITRARY entries, guardian indices strictly increasing;
  frame 0 VERIFY flags=2 (only_verify, target null) data `validate()‖0‖k`; frame 1 VERIFY flags=1 (pay, target vault)
  data `validate()‖k‖t`; frame 2 SENDER target vault, flags 0, `execute(calls)`. ERC-8421 PREFIX-010 allows at most
  these two VERIFY frames, so more approvals go *into* the two frames (k is chosen by `pqv.devnet.split_point`).
- **`ethrex_simulateFrameTransaction`**: `valid`/`canonicalMempoolViolation` is the *canonical* mempool verdict. PQ-Vault
  is expected to show `StorageReadNonSender` there; gate on `executionStatus == success`, not `valid`.
- **Validation budget**: a VERIFY frame costs ~86k with one compact approval, +~68k per further compact approval,
  ~295k with one stateless (SPX) approval (Foundry gas tests). t ≥ 2 exceeds EIP-8141's combined MAX_VERIFY_GAS (100k).
  The deployed workshop sidecar enforces that combined 100k even for staked senders; ERC-8421 [BUDGET-010] (per-entity,
  1M staked) is implemented in `infra/sidecar-budget010/` (build.sh → `pqvault/mempool-sidecar:budget-010`; run with
  `SIDECAR_IMAGE=pqvault/mempool-sidecar:budget-010 infra/sidecar-local.sh …`). ethrex's own simulate RPC only *notes*
  the 100k overage in `canonicalMempoolViolation` and still traces, so ethrex needs no reconfiguration.
- **Calldata floor**: ethrex bills frame txs at max(standard, 13,150 + 64 gas × bytes of frame data + signatures)
  (EIP-7623/7976 floor, `transaction.rs:calldata_floor_gas`). PQ-Vault txs are floor-bound: execution-gas savings do
  not lower the bill; fewer bytes do.
- **Fresh contract accounts start at nonce 1.** The driver reads the nonce from the chain.
- **Public devnet gas**: contract creation costs far more gas than locally (factory ~18M) — the driver estimates gas; don't hardcode.
- **ethrex privileged relay** (local sidecar) gives each tx ONE payload build; the sidecar must re-relay
  (`maxSubmitAttempts: 40` in `infra/sidecar-local.sh`) or txs end `Cancelled` despite simulating fine.
- **Apple Silicon**: `ghcr.io/forshtat/ethrex:eip8141-tracer-latest` is amd64-only and segfaults (exit 139) under
  emulation → `infra/build-ethrex-arm64.sh`. Docker Desktop has only 3 GB RAM here; stop Kurtosis telemetry containers when building.
- **Foundry tests**: no forge-std (local `TestBase`/`Vm`); fixture JSON is read on demand (storing it costs ~80M gas);
  `vm.expectRevert` binds to the *next external call* (including view calls) — compute args first.
- **FrameOps** is deployed from the *unoptimized* solc build (`pqv/devnet.py:frameops_initcode`) so bytecode maps 1:1
  to the reviewed opcode/stack order; forge's optimized artifact is not used for deployment.
- **zsh**: never name a loop variable `path` (it clobbers `$PATH`).
- Tool permissions: installing/running external npm code (e.g. `yarn install` in vendored repos, `npx hyperframes`)
  was blocked by the auto-mode classifier; ask the user before retrying.

## 7. Open work (priority order)

1. **Withhold-and-rollback attack** (REPORT §9): a malicious host withholds the tx for leaf q, rolls storage back,
   gets leaf q signed again — current `anchored_w1` re-signs unboundedly and nothing is published. Add it to
   `research/sim.py` (host withholds + rollback), measure γ, then implement and measure the candidate fix:
   per-boot instance IDs from hardware RNG + on-chain leaf *leases* above all previous leases (authorised by the
   stateless key) + on-device light-client verification of the lease.
2. **Per-vault nullifier variant** (REPORT §7.0): ledger in the vault's own storage — likely passes the canonical
   mempool; loses cross-vault protection. Build + measure admission on the public devnet.
3. Get `[BUDGET-010]` into the deployed alt mempool: the patch + draft PR text are in `infra/sidecar-budget010/README.md`
   (not submitted — the user decides). The stock image admits only the two-frame fallback.
4. (dropped) Public chain-1337 gateway: unreproducible rules and no inclusion observed (REPORT §8.1); use `infra/local-net.sh`.
5. Light-client verification of the LeafLedger mark (removes trust in the host/RPC).
6. Hardware secure-element testing; real power-loss testing (SIGKILL ≠ power loss).
7. Hackathon submission (repo link, video, CROPS section in README). The demo video still shows the old 2-of-3
   two-frame design; rebuild it (`demo/build_demo.py`, needs macOS `say`) from the local-net receipts.
8. Optional HyperFrames version of the demo video (needs the user to allow `npx hyperframes`).

## 8. Conventions

- Regenerate, don't hand-edit: `docs/RECEIPTS.md` (`pqv.receipts`), `research/results/*` (scripts), video (`demo/build_demo.py`).
- Every new claim in the report needs a script that produces it; record failed experiments in REPORT §9.
- Keep upstream code unmodified; attribute anything copied (MIT only).
- Commits end with the attribution line the harness provides; push only when the user asks.
