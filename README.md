# PQ-Vault

**A t-of-n post-quantum guardian wallet for EIP-8141 frame transactions (n guardians and threshold t fixed at
creation), plus research on keeping *stateful* hash-based signatures safe through crashes, stale backups, cloned
devices and rollback.**

Built for ETHGlobal Mumbai 2026. Devnet only — research prototype, not audited, never use real funds.

- **No ECDSA in the wallet.** Every approval is a JARDIN hash-based signature (SPHINCS-/FORS family,
  keccak-based) carried in an EIP-8141 `ARBITRARY` signature entry and checked against the protocol's
  canonical signature hash `TXPARAM(0x08)`. The only ECDSA key in the repo is a throwaway devnet
  deployer that publishes contracts.
- **No custom cryptography.** Signing and verification are the upstream JARDIN reference code
  ([`nconsigny/JARDIN`](https://github.com/nconsigny/JARDIN), pinned as `third_party/JARDIN`, unmodified):
  `JardinForsPlainVerifier` / `JardinSpxVerifier` on-chain, the JARDIN Python signers off-chain.
- **Official workshop tooling.** Frame-transaction layout, opcode helpers and RPC flow follow the
  ETHGlobal Mumbai alt-mempool workshop (`forshtat/mempool-workshop`, `@forshtat/hegota-support`,
  `forshtat/mempool-workshop-sidecar`, `forshtat/ethrex@eip8141-tracer`).

## What it does

| Feature | How |
|---|---|
| Guardian authorization (t-of-n) | Three frames, the ERC-8421 `[only_verify, pay]` prefix plus one body frame. Frame 0 `VERIFY` (scope execution) and frame 1 `VERIFY` (scope payment) each run `validate()` over their share `[0,k)` / `[k,t)` of the t approvals (compact FORS *or* stateless SPX), pin the frame list and cap the fee. Frame 2 `SENDER` → `execute()` consumes every approval's leaf and runs the batch atomically. Every signature is verified before payment is approved: a missing, corrupted, stale or duplicate approval makes the transaction invalid and costs the vault nothing. All guardians sign the same message, independently and in any order. |
| Replay protection | Protocol nonce + `TXPARAM(0x08)` (chain id, sender, nonce, fees, all frames) + domain tag; distinct guardians; and per-leaf replay protection through the **LeafLedger** (a stateful leaf can never be accepted twice). |
| Key rotation | `registerSlot` / `revokeSlot`: a guardian gets a fresh compact slot (new randomness), approved t-of-n. |
| Key-loss recovery | `replaceGuardian`: t remaining guardians install new master + slot keys; bumping the guardian epoch revokes every old slot. |
| Stateful-signature safety (research result) | LeafLedger high-water marks enforced in `VERIFY`, chain-anchored signer, in-flight window, and permissionless **equivocation reports** that revoke a slot that signed two messages with one leaf. |
| ERC-8421 alt mempool | `VERIFY` reads the shared LeafLedger — storage not associated with the sender, which the EIP-8141 canonical mempool refuses and the alt mempool admits for a **staked** sender; the vault stakes itself in its constructor. |
| Two-frame fallback | For mempools that cap the whole prefix at EIP-8141's 100k (e.g. the stock workshop sidecar image `2e22ff0a`): frame 0 `VERIFY` (`self_verify`) → `validateAndCommit()` checks one compact approval that signs *last* over the exact bytes of all the others; frame 1 `SENDER` → `execute()` verifies the other t−1, consumes leaves, runs the batch. Residual cost of this shape only: an invalid later approval wastes the fee (≤ `MAX_TX_COST`) and the committer's leaf. Select it with `--frames 2` (default: 3 frames). |
| Validation budget (100k cap) | t PQ approvals need ~86k (first compact approval in a frame) + ~68k per further compact approval, so t ≥ 2 exceeds EIP-8141's combined `MAX_VERIFY_GAS` (100k). ERC-8421 `[BUDGET-010]` gives each **staked** entity its own 1,000,000 budget; every validation frame here belongs to the staked vault. The deployed workshop sidecar does not implement `[BUDGET-010]`; `infra/sidecar-budget010/` adds it (patch + 7 tests + image build). |

## Layout

```
contracts/          Foundry project: PQVault, PQVaultFactory, LeafLedger, PQVaultFrameOps.yul (+ tests)
pqv/                Python toolkit: frame-tx codec, JARDIN key wrapper, leaf-state stores, devnet driver, UI server
app/                Single-page UI (no external scripts or trackers)
research/           Simulator, crash experiment, results/, REPORT.md
infra/              Local EIP-8141 devnet (Kurtosis; ethrex eip8141-tracer + Lighthouse); sidecar-budget010/ (ERC-8421 per-entity budgets)
third_party/        JARDIN and SPHINCS- (git submodules, pinned)
```

## Quick start

Requirements: Foundry, Python ≥ 3.10 linked against OpenSSL ≥ 3.2 (for native `KECCAK-256`; e.g. Homebrew
`python3.12`, or a uv-managed CPython on Linux), `git submodule update --init`. No pip packages are needed.
Vault transactions with t ≥ 2 PQ approvals need an ERC-8421 mempool with per-entity budgets ([BUDGET-010]):
`infra/sidecar-budget010/build.sh` builds one from the workshop sidecar.

```sh
# contracts + tests
(cd contracts && forge build && forge test)
python3.12 -m unittest discover -s tests -t .

# research
python3.12 research/run_experiments.py --seeds 20     # -> research/results/experiments.{json,md}
python3.12 research/crash_test.py --kills 150         # -> research/results/crash_test.json

# devnet: `public` (chain-1337 hackathon devnet) or `local` (Kurtosis: ethrex eip8141-tracer + Lighthouse + sidecar)
infra/local-net.sh up            # Kurtosis ethrex (eip8141-tracer) + Lighthouse + skandha [BUDGET-010] sidecar,
                                 # funded deployer, infra contracts; waits for Hegota (~10 min). `up stock` = stock sidecar
python3.12 -m pqv.devnet local new-guardians --n 4
python3.12 -m pqv.devnet local deploy-vault --threshold 2 --fund 2 --stake 0.02      # t-of-n, staked
python3.12 -m pqv.devnet local transfer 0x<to> 1000000000000000 --guardians 0,1 [--stateless 1]
python3.12 -m pqv.devnet local transfer 0x<to> 1000000000000000 --guardians 0,1 --frames 2   # fallback shape
infra/local-net.sh status | down
python3.12 -m pqv.server local       # UI on http://127.0.0.1:8141
```

Full local-devnet bring-up (including the native arm64 ethrex build for Apple Silicon): see
[research/REPORT.md §10](research/REPORT.md#10-reproduce).

## Results at a glance

- **Three-frame t-of-n vault (current design), local devnet** (ethrex `9aa3645d`): 2-of-4, 3-of-4 and
  compact+stateless transfers, key rotation, recovery and the live attack, all included through a sidecar with
  ERC-8421 [BUDGET-010]. The stock sidecar and ethrex's canonical mempool reject the same transactions
  (combined 100k cap), and the [BUDGET-010] sidecar rejects an *unstaked* copy. VERIFY frames: 84,596 / 78,720 gas
  (one compact approval each). Billed gas of a 2-of-n transfer: 379,769 (two-frame design: 378,782).
  Receipts: [docs/RECEIPTS-three-frame.md](docs/RECEIPTS-three-frame.md); write-up: REPORT §8.1.
- **Two-frame fallback, same contract** (REPORT §8.2): with the *stock* workshop sidecar image 2-of-4, 3-of-4 and compact+stateless transfers, rotation, recovery and the live attack were all
  admitted and included on the local devnet; the stock sidecar rejects the three-frame shape. A two-frame 2-of-n
  transfer costs 378,782 gas, the same as the original public-devnet transfers. Receipts:
  [docs/RECEIPTS-two-frame-fallback.md](docs/RECEIPTS-two-frame-fallback.md).
- **Earlier two-frame 2-of-3 design — PQ-signed EIP-8141 frame transactions on the public chain-1337 hackathon devnet**, admitted by the workshop's
  ERC-8421 gateway: 2-of-3 transfers (compact+compact, compact+stateless), key rotation, key-loss recovery, a
  transfer by the recovered guardian, a UI-initiated transfer, plus the live attack below — e.g. the first one,
  [`0x1a38358a…9cc1`](https://explorer.altmempool.wtf/tx/0x1a38358af26665a862b8a1b27eb9817565f08119d1aea3678d9c5bddaf6c9cc1)
  (block 366). VERIFY frame: **82,049 gas** on chain. Everything was also reproduced on a local Kurtosis devnet of
  the same client. Receipts: [docs/RECEIPTS.md](docs/RECEIPTS.md).
- **Alt mempool is required, measured:** the canonical mempool rejects the vault (`StorageReadNonSender`); the alt
  mempool rejects an unstaked copy (`unstaked payer accessed … LeafLedger slot`) and admits the staked vault.
- **Live attack:** a JARDIN-style vault with no on-chain leaf state included two transactions signed with the
  same few-time leaf after a stale backup restore; the slot was then revoked by a permissionless equivocation
  proof; PQ-Vault refused the same restored signer with `StaleLeaf`.
- **Research:** under stale restores, rollbacks and lost state the baseline reaches γ = 9 (35.6-bit forgery cost)
  and hundreds of double-accepted signatures; PQ-Vault keeps γ = 1 with zero double acceptance. Clones remain
  γ = n, bounded to ~1 block of exposure by equivocation revocation. A persist-after-sign signer under fault
  injection reached γ = 100. Details and limitations: [research/REPORT.md](research/REPORT.md).

See [research/REPORT.md](research/REPORT.md) for the research write-up, [docs/RECEIPTS.md](docs/RECEIPTS.md)
for devnet transaction receipts, and [demo/pq-vault-demo.mp4](demo/pq-vault-demo.mp4) (2:56) for the demo video
(narration: [demo/NARRATION.md](demo/NARRATION.md); rebuilt from recorded data by `python3.12 demo/build_demo.py`).

## CROPS

- **C**ensorship resistance: transactions go to the permissionless ERC-8421 alt mempool; admission depends on
  published rules and an on-chain stake, not on a relayer's discretion.
- **O**pen source: MIT (this repo); dependencies are MIT/Apache upstream code, pinned.
- **P**rivacy: the UI makes no third-party requests and has no analytics; keys never leave the local process.
- **S**ecurity (lead property): post-quantum hash-based authorization with no ECDSA fallback, and on-chain
  protection against the failure mode stateful hash-based signatures are known for (state reuse).

## License

MIT for code in this repository. `third_party/` keeps its upstream licenses (JARDIN Solidity files are
MIT-tagged; SPHINCS- is MIT). `contracts/src/external/NaiveStakingRegistry.sol` and
`infra/kurtosis/eip8141-single-node.yaml` are copied from forshtat/mempool-workshop-sidecar (MIT).
