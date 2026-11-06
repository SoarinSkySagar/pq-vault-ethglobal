# AGENTS.md — handoff for agents (and humans) picking up PQ-Vault

Read this first. It is the state of the project as of 2026-11-06, what works, how to run it, where the
non-obvious traps are, and what is left. User-facing docs: `README.md`; research: `research/REPORT.md`;
devnet evidence: `docs/RECEIPTS.md`.

## 1. What this project is

**PQ-Vault**: a 2-of-3 post-quantum guardian wallet on **EIP-8141 frame transactions** submitted through the
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
| Contracts (`contracts/src`) | `PQVault`, `PQVaultFactory`, `LeafLedger`, `PQVaultFrameOps.yul`. Foundry: **20/20 pass** |
| Python toolkit (`pqv/`) | frame-tx codec (matches ethrex golden vector), JARDIN wrapper, leaf stores, devnet driver, UI server, receipts generator. **19/19 unittest pass** |
| Public hackathon devnet (chain 1337) | Infra + staked vault deployed; 9 frame txs incl. transfers, stateless 2nd approval, rotation, recovery, UI transfer, live attack. All status 0x1. See `docs/RECEIPTS.md` |
| Local devnet (Kurtosis) | Same flow reproduced (chain 3151908) |
| Research | `research/REPORT.md` complete (§1–10), results in `research/results/*.json|md` |
| Demo | `demo/pq-vault-demo.mp4` (2:55), `demo/NARRATION.md`, `docs/DEMO.md` |
| UI | `app/index.html` served by `python -m pqv.server <network>` |

## 3. Repo map

```
contracts/src/PQVault.sol          2-of-3 vault: validate() [VERIFY frame], execute() [SENDER frame], guardian mgmt
contracts/src/LeafLedger.sol       per-slot high-water mark (monotone nullifier) + reportEquivocation
contracts/src/PQVaultFactory.sol   CREATE2 factory; owns the ledger; useLedger=false = JARDIN baseline vault
contracts/src/PQVaultFrameOps.yul  EIP-8141 opcode helper (TXPARAM/SIGPARAM/SIGDATACOPY/FRAMEPARAM/FRAMEDATALOAD/APPROVE)
contracts/src/Verifiers.sol        imports upstream JardinForsPlainVerifier / JardinSpxVerifier
contracts/src/external/            NaiveStakingRegistry (copied, MIT) — only deployed on local devnets
contracts/test/                    PQVault.t.sol, mocks (MockFrameOps, CodeBlobFrameOps), fixtures + generator
pqv/frametx.py, rlp.py             EIP-8141 frame tx codec (chain-1337 / ethrex 9aa3645d layout)
pqv/jardin.py                      guardian keys over upstream JARDIN signers; entry encoding; vault_message/first_message
pqv/state.py                       DurableLeafStore (burn-before-sign), AnchoredLeafStore (chain-anchored)
pqv/devnet.py                      CLI: deploy-infra, new-guardians, deploy-vault, transfer, rotate, recover, attack-stale-restore
pqv/server.py, app/index.html      local UI (127.0.0.1 only)
pqv/receipts.py                    regenerates docs/RECEIPTS.md from the chain
pqv/_shim/Crypto/Hash/keccak.py    stdlib KECCAK-256 adapter so JARDIN's Python imports work without pycryptodome
research/                          policies.py, sim.py, run_experiments.py, sweeps.py, crash_test.py, REPORT.md, results/
infra/                             local-devnet.sh (Kurtosis), build-ethrex-arm64.sh, sidecar-local.sh, kurtosis/*.yaml
demo/build_demo.py                 rebuilds the video from recorded data (Chrome headless + `say` + ffmpeg)
third_party/JARDIN, SPHINCS-       git submodules, pinned (JARDIN has no LICENSE file → never copy it, keep as submodule)
```

## 4. How to run

```sh
git submodule update --init
(cd contracts && forge build && forge test)                    # 20 tests
python3.12 -m unittest discover -s tests -t .                  # 19 tests
python3.12 research/run_experiments.py --seeds 20              # ~10 min
python3.12 research/sweeps.py --seeds 10
python3.12 research/crash_test.py --kills 100
python3.12 -m pqv.devnet public status                         # public devnet
python3.12 -m pqv.server public --port 8143                    # UI
python3.12 -m pqv.receipts public local                        # regenerate docs/RECEIPTS.md
```
Devnet flow (fresh machine): `deploy-infra` → `new-guardians` → `deploy-vault --fund 0.3 --stake 0.02` →
`transfer <to> <wei> --guardians 0,1 [--second stateless]` → `rotate <g>` → `recover <g>` → `attack-stale-restore`.
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

- **Python**: use Homebrew `python3.12` (OpenSSL ≥ 3.2 → native `KECCAK-256`). System `python3` 3.9/LibreSSL has no keccak.
- **Frame-tx sig hash** elides the bytes of every *empty-msg* signature entry; frame data is covered. PQ signatures
  go in `ARBITRARY` entries. Guardian B signs `messageFor(sigHash)` *first*; guardian A signs
  `firstMessageFor(sigHash, keccak(entryB))` — otherwise a relayer can corrupt entry B (fixed bug, see REPORT G6).
- **`ethrex_simulateFrameTransaction`**: `valid`/`canonicalMempoolViolation` is the *canonical* mempool verdict. PQ-Vault
  is expected to show `StorageReadNonSender` there; gate on `executionStatus == success`, not `valid`.
- **Validation budget**: VERIFY limit 99,800 + 2×100 (ARBITRARY entries) = MAX_VERIFY_GAS. `validate()` ≈ 82k on chain.
  The deployed sidecar caps the whole prefix at 100k even for staked senders (ERC-8421's 1M per-entity budget is not deployed).
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
3. Both signatures in VERIFY once an alt mempool deploys ERC-8421's `MAX_VERIFY_GAS_STAKED_ENTITY` (1M).
4. Light-client verification of the LeafLedger mark (removes trust in the host/RPC).
5. Hardware secure-element testing; real power-loss testing (SIGKILL ≠ power loss).
6. Hackathon submission (repo link, video, CROPS section in README) — confirm with the user.
7. Optional HyperFrames version of the demo video (needs the user to allow `npx hyperframes`).

## 8. Conventions

- Regenerate, don't hand-edit: `docs/RECEIPTS.md` (`pqv.receipts`), `research/results/*` (scripts), video (`demo/build_demo.py`).
- Every new claim in the report needs a script that produces it; record failed experiments in REPORT §9.
- Keep upstream code unmodified; attribute anything copied (MIT only).
- Commits end with the attribution line the harness provides; push only when the user asks.
