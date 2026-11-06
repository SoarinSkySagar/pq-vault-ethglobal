# PQ-Vault

**A 2-of-3 post-quantum guardian wallet for EIP-8141 frame transactions, plus research on keeping
*stateful* hash-based signatures safe through crashes, stale backups, cloned devices and rollback.**

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
| Guardian authorization (2-of-3) | Frame 0 `VERIFY` → `validate()` checks guardian A's compact JARDIN signature (fits the 100k validation budget), binds approval to the exact frame list, caps the fee. Frame 1 `SENDER` → `execute()` checks guardian B (compact *or* stateless SPX), then runs the batch atomically. |
| Replay protection | Protocol nonce + `TXPARAM(0x08)` (chain id, sender, nonce, fees, all frames) + domain tag; distinct guardians; and per-leaf replay protection through the **LeafLedger** (a stateful leaf can never be accepted twice). |
| Key rotation | `registerSlot` / `revokeSlot`: a guardian gets a fresh compact slot (new randomness), approved 2-of-3. |
| Key-loss recovery | `replaceGuardian`: the two remaining guardians install new master + slot keys; bumping the guardian epoch revokes every old slot. |
| Stateful-signature safety (research result) | LeafLedger high-water marks enforced in `VERIFY`, chain-anchored signer, in-flight window, and permissionless **equivocation reports** that revoke a slot that signed two messages with one leaf. |
| ERC-8421 alt mempool | `VERIFY` reads the shared LeafLedger — storage not associated with the sender, which the EIP-8141 canonical mempool refuses and the alt mempool admits for a **staked** sender; the vault stakes itself in its constructor. |

## Layout

```
contracts/          Foundry project: PQVault, PQVaultFactory, LeafLedger, PQVaultFrameOps.yul (+ tests)
pqv/                Python toolkit: frame-tx codec, JARDIN key wrapper, leaf-state stores, devnet driver, UI server
app/                Single-page UI (no external scripts or trackers)
research/           Simulator, crash experiment, results/, REPORT.md
infra/              Local EIP-8141 devnet (Kurtosis; ethrex eip8141-tracer + Lighthouse)
third_party/        JARDIN and SPHINCS- (git submodules, pinned)
```

## Quick start

Requirements: Foundry, Python ≥ 3.10 linked against OpenSSL ≥ 3.2 (for native `KECCAK-256`; e.g. Homebrew
`python3.12`), `git submodule update --init`. No pip packages are needed.

```sh
# contracts + tests
(cd contracts && forge build && forge test)
python3.12 -m unittest discover -s tests -t .

# research
python3.12 research/run_experiments.py --seeds 20     # -> research/results/experiments.{json,md}
python3.12 research/crash_test.py --kills 150         # -> research/results/crash_test.json

# devnet: `public` (chain-1337 hackathon devnet) or `local` (Kurtosis: ethrex eip8141-tracer + Lighthouse + sidecar)
python3.12 -m pqv.devnet local deploy-infra
python3.12 -m pqv.devnet local new-guardians
python3.12 -m pqv.devnet local deploy-vault --fund 2 --stake 0.02
python3.12 -m pqv.devnet local transfer 0x<to> 1000000000000000 --guardians 0,1
python3.12 -m pqv.server local       # UI on http://127.0.0.1:8141
```

Full local-devnet bring-up (including the native arm64 ethrex build for Apple Silicon): see
[research/REPORT.md §10](research/REPORT.md#10-reproduce).

## Results at a glance

- **PQ-signed EIP-8141 frame transactions on the public chain-1337 hackathon devnet**, admitted by the workshop's
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
