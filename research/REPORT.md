# Keeping stateful post-quantum wallets safe through crashes, stale backups, clones and rollback

*PQ-Vault research report — ETHGlobal Mumbai 2026. Every number below is produced by code in this
repository (commands in §10). Results are from a simulator driven by real JARDIN signatures, real-process
crash runs, Foundry tests against the real JARDIN verifier contracts, and EIP-8141 devnet transactions.
Nothing here has been audited; claims of novelty are limited to "not found in the sources we reviewed" (§3).*

## 1. Question

JARDIN makes post-quantum Ethereum accounts cheap by signing most transactions on a **compact, stateful**
path: a registered *slot* is a Merkle tree of 2^h few-time FORS keys (k = 32, a = 4, h ≤ 8), and the
device must never sign two different messages with the same leaf q. The FORS reuse curve for these
parameters is steep:

| leaf reuse γ (distinct messages on one leaf) | 1 | 2 | 3 | 5 | 10 | 20 |
|---|---|---|---|---|---|---|
| forgery cost, bits | 128.0 | 97.5 | 80.2 | 59.5 | 34.3 | 14.9 |

(−k·log2(1 − (1 − 2^−a)^γ); identical to the table in the JARDIN README; checked in
`tests/test_sim_invariants.py`.) We ask whether a stateful PQ wallet stays secure when its signing state
goes wrong in the ways real devices do — **crashes, interrupted signing, outdated backup restoration,
device cloning, and state rollback** — and what can be done about the cases that are not already solved.

## 2. Systems studied

- **JARDIN** (`nconsigny/JARDIN` @ 23939d6, write-up notes.ethereum.org/@niard/JARDIN): SPX (plain
  SPHINCS+, stateless, 6,512 B, ~276k gas) registers slots and is the fallback; plain FORS (2,593 + 16h B,
  ~55k gas measured here) is the compact path. Device-side protections: **burn-before-sign** (increment q in
  NVRAM before signing), per-device random `r` for slot derivation, fresh `r` after a mnemonic restore,
  SPX fallback when state is lost. **On-chain state: none** — the account stores registered slots and
  verifies any q (no counter, "no SSTORE on Type 2").
- **SPHINCS-** (`nconsigny/SPHINCS-` @ 4c76aaf): stateless EVM-optimised SPHINCS+ variants (C11, C13,
  SLH-DSA-128-24 …). Stateless, so not subject to the failures studied here, but 3.7–6.6 KB and 94k–276k gas.
- Our own **PQ-Vault** (this repo): 2-of-3 guardian wallet on EIP-8141 using the JARDIN verifiers unmodified.

## 3. What is already solved (literature and implementations)

| Failure | Existing answer | Source |
|---|---|---|
| Crash between signing and persisting state | Persist the advanced state (non-volatile, atomic) **before** releasing a signature | NIST SP 800-208 §8; JARDIN burn-before-sign; McGrew et al., *State Management for Hash-Based Signatures*, SSR 2016 (ePrint 2016/357) |
| Losing the state entirely | Static backup = seed; on restore use a stateless path (SHRINCS) or a fresh slot / fresh device randomness (JARDIN); bounded re-initialisations (SHRIMPS) | SHRINCS (delvingbitcoin, Dec 2025); SHRIMPS (Mar 2026); JARDIN write-up |
| Accidental copying (cloning) | Hybrid stateful/stateless key so security degrades gracefully; never export state; keep state in tamper-resistant hardware | McGrew et al. 2016; NIST SP 800-208; draft-ietf-pquip-hbs-state-02 §2–5 |
| Reserving state ahead | Interval/reservation schemes (McGrew), sectorization, distributed multi-trees, key/state transfer | draft-ietf-pquip-hbs-state-02 §5 |
| Detecting reuse | A public log of all signatures makes "detecting if an index was used more than once … trivial" (verifier-side; noted as an external dependency with costs) | draft-ietf-pquip-hbs-state-02 §3–4 |

**Explicitly open in those sources.** The SHRINCS thread lists host-forced state resets, cloned disks,
TPM-backed state that a restored disk image still unlocks, and parallel signing races as unresolved;
the author states "security requires secure state management". SHRIMPS does not discuss rollback or
clones. The IETF draft notes that rollback-resistant counters "can be difficult to achieve in a
software-only fashion" and that VM snapshots/live cloning "can easily lead to a state re-use".
Equivocation (two signatures on one leaf) as a *revocation trigger* is not discussed in any of these;
the closest analogue we know of is equivocation slashing in proof-of-stake consensus.

## 4. Gaps we target

- **G1 – silent stale restore.** A device restored from an OS/VM/disk backup sees a valid-looking state
  file; JARDIN's "fresh r on restore" only fires when the device *knows* it was restored.
- **G2 – rollback / fault injection** of the counter (the JARDIN write-up names it a practical threat on
  secure elements).
- **G3 – concurrent clones**: two live copies sign the same fresh leaf.
- **G4 – no on-chain enforcement**: a JARDIN account accepts a reused leaf; it cannot tell.
- **G5 (found while building)** – JARDIN's EIP-8141 frame account takes `sigHash` from calldata, so the
  SENDER frame payload is not bound (documented as a known limitation in its source). PQ-Vault binds to
  `TXPARAM(0x08)` instead.
- **G6 (found while building, our own bug)** – with split verification (one guardian in `VERIFY`, one in
  the body), the second guardian's `ARBITRARY` bytes are elided from the canonical signature hash, so a
  relayer could corrupt them and rebroadcast a copy that passes validation but executes nothing while the
  vault pays the fee. Fixed by making guardian A sign over keccak(entry B); covered by
  `test_mutatedSecondEntry_notApproved`.

## 5. Method

**Controlled test wallets only.** All attacks target keys and vaults we created (fixed test seeds or
fresh devnet keys).

1. **Simulator** (`research/sim.py`, `research/policies.py`): every signature is produced by the upstream
   JARDIN plain-FORS signer (h = 7, Q = 128) and accepted only if the upstream reference verifier accepts
   it. The attacker's view is the exact set of FORS secrets the released signatures reveal, from which we
   compute the *empirical* forgery cost of each leaf (−Σ_t log2(revealed_t / 16)). Device storage is
   modelled as committed vs. not-yet-fsync'd; the chain processes transactions in order. Scenarios: random
   power-loss crashes (S1/S4), silent and known stale-backup restores (S2), lost state, a cloned device whose
   transactions race (S3), periodic counter rollback (S5), rollback with delayed/dropped transactions, and a
   host that lies about chain state. 20 seeds each.
2. **Real-process crash experiment** (`research/crash_test.py`): a signer process is SIGKILLed hundreds of
   times, at random moments and (fault-injection mode) the instant a signature is released; we count leaves
   that released two messages.
3. **On-chain adversarial tests** (`contracts/test/PQVault.t.sol`): real JARDIN signatures verified by the
   real JARDIN verifier contracts inside PQ-Vault; only the EIP-8141 opcodes are simulated.
4. **Devnet**: real EIP-8141 frame transactions through the ERC-8421 sidecar (§8).

Signer policies compared: `naive` (persist after signing, no fsync), `durable` (burn-before-sign, atomic
fsync — JARDIN / SP 800-208), `fallback` (+ stateless path when state is missing — SHRINCS-style), `reslot`
(+ fresh slot when the device knows it was restored — JARDIN), and ours: `anchored` and `anchored_w1`.
Chain models: no on-chain leaf state (JARDIN), LeafLedger, LeafLedger + equivocation reports.

## 6. Attacks (reproducible)

Worst case over 20 seeds (`research/results/experiments.md` has every policy × chain combination).

| Attack | Baseline: JARDIN-style durable signer, no on-chain state | Result |
|---|---|---|
| Silent stale backup (restore 10 signatures old) | γ = 2 on 10 leaves; forgery cost 96.0 bits; **200 signatures on already-used leaves accepted on chain** (10/run) | broken (G1) |
| Known restore | same as silent unless the device re-slots (`reslot` fixes it at the cost of one slot registration) | solved only if detected |
| Lost state, restart from q = 1 | γ = 2; 300 double acceptances; `fallback` and `reslot` fix it | solved (SHRINCS/JARDIN) |
| Counter rollback by 3 every 5 signatures | γ = 3; forgery cost 78.5 bits; 420 double acceptances | broken (G2) |
| Rollback with late/dropped transactions | γ = 3; 77.9 bits | broken |
| Cloned device, both copies signing | γ = 2; 380 double acceptances; exposure 20 blocks/run | broken (G3) |
| Power-loss crashes with a naive persist-after-sign signer | γ up to 9; forgery cost 36.4 bits | broken (implementation bug class) |
| Same crashes with burn-before-sign | γ = 1 | solved |

On-chain confirmation: `test_baseline_acceptsRolledBackLeaf` executes three transfers on a vault without
leaf tracking, the third approved by a guardian whose device re-signed leaf 2 for a different transaction.
The real-process crash results are in §7.4.

### 6.1 How bad does it get? (sensitivity sweeps, 10 seeds, `research/sweeps.py`)

| Sweep | baseline worst γ → lowest forgery cost | PQ-Vault (anchored, W=1, LeafLedger) |
|---|---|---|
| same stale backup restored r = 1, 2, 4, 8 times | γ 2 / 3 / 5 / 9 → **96.0 / 78.5 / 57.2 / 35.6 bits** | γ 1 at every r |
| counter rewound by d = 1, 2, 3, 5 every 5 signatures | γ 2 / 2 / 3 / 8 → 96.0 / 96.0 / 78.5 / **39.4 bits** | γ 1 at every d |
| n = 2, 3, 4 live clones | γ = n → 96.0 / 77.3 / 65.7 bits | γ = n as well (anchoring cannot help); with equivocation reports exposure 25 → **1 block**, at the cost of n re-slots |

Repeated restores of one snapshot (a VM revert loop, a re-imaged disk) are the most damaging case:
reuse is unbounded under burn-before-sign alone, and each restore costs ~20 bits at the start of the
curve. The empirical forgery costs sit slightly below the expectation formula because the realised
coverage of revealed FORS leaves is random.

## 7. Mitigation

Four layers, each aimed at a gap; all are implemented.

1. **LeafLedger (on-chain, G4).** A shared contract stores, per slot (keyed by keccak(seed‖root), not by
   account), the highest leaf any PQ-Vault consumed. The vault's `VERIFY` frame rejects q ≤ mark
   (`StaleLeaf`), and the body frame advances the mark. Keying by slot means one guardian device protecting
   several vaults has one counter. Reading it from `VERIFY` touches storage not associated with the sender:
   the canonical EIP-8141 mempool refuses that, the ERC-8421 alt mempool admits it for a staked sender.
2. **Anchored signer (G1, G2).** Before burning a leaf, the device takes `max(local, ledger mark + 1)`
   (`pqv/state.py: AnchoredLeafStore`). A stale restore, a wiped device or a rolled-back counter resumes
   above every leaf that reached the chain, with no need to *detect* the restore.
3. **In-flight window W = 1.** Never sign q > mark + 1 while one of the device's transactions is pending, so
   at most one signed-but-unconfirmed leaf exists; a leaf burned but never released (crash) is skipped
   (moving forward never reuses a leaf).
4. **Equivocation reports (G3).** `LeafLedger.reportEquivocation` is permissionless: given two valid JARDIN
   signatures from one slot, same leaf, different messages, it revokes the slot everywhere (mark := max, so no
   extra gas on the vault's validation path). Only the key holder can create such a pair, so it cannot be used
   to grief an honest slot. Each device then registers a new slot from its *own* fresh randomness (2-of-3),
   which separates two clones permanently.

### 7.0 Why not "just a nullifier"? (design note)

The LeafLedger *is* a nullifier set for leaves, stored in compressed, monotone form: one high-water mark per
slot means "every leaf ≤ q is spent". A plain nullifier closes only part of the problem:

- It stops **double acceptance on chain**, not the **leak**: reuse happens when the device signs, and the second
  signature is public as soon as it is broadcast. A forgery at a nullified leaf is rejected, but a reused leaf whose
  transactions have not landed yet is not nullified, and a forged transaction can race them.
- The device must **read** it (layer 2), or restored devices keep producing reuse that only the chain rejects.
- A **per-leaf** nullifier (spent bit) leaves burned-but-never-landed leaves open forever; the monotone mark retires
  them as soon as any higher leaf lands.
- **Clones** sign a fresh leaf in parallel before either lands; only the equivocation report bounds that.

Design trade-off: we keep the ledger in one *shared* contract so a guardian device protecting several vaults has a
single counter (no reuse "once per vault"). That shared read is exactly what the canonical mempool rejects
(`StorageReadNonSender`). A per-vault nullifier in the vault's own storage would very likely pass the canonical
mempool (reading the sender's own storage is not that violation), at the cost of cross-vault protection unless each
guardian uses a distinct slot per vault. We did not build or measure the per-vault variant.

### 7.1 Comparison (worst case over 20 seeds)

| Scenario | JARDIN-style durable | durable + LeafLedger | PQ-Vault (anchored, W=1, LeafLedger) | PQ-Vault + equivocation reports |
|---|---|---|---|---|
| silent stale backup | γ 2 · 200 double-accepted | γ 2 · 0 · exposure 0 | **γ 1** · 0 | **γ 1** · 0 |
| counter rollback | γ 3 · 78.5 bits · 420 | γ 3 · 0 · exposure 0 | **γ 1** | **γ 1** |
| lost state | γ 2 · 300 | γ 2 · 0 | **γ 1** | **γ 1** |
| cloned device | γ 2 · 380 · exposure 20 | γ 2 · 0 · exposure 20 | γ 2 · 0 · exposure 10 | γ 2 · 0 · **exposure 1** (2 re-slots) |
| rollback + in-flight txs | γ 3 · 211 | γ 3 · 0 · exposure 11.4 | γ **2** · 0 · exposure 8.5 | γ 2 · 0 · **exposure 2.75** |
| lying host + stale backup | γ 2 · 200 | γ 2 · 0 | **γ 1** (refuses: 29 waits) | **γ 1** |
| crashes (modelled power loss) | γ 1 | γ 1 | γ 1 | γ 1 |

"Exposure" = mean number of blocks during which a reused leaf was still acceptable on chain (a forgery
window). The ledger alone already prevents any double acceptance; the anchored signer prevents the reuse
from happening at all in the stale-backup / rollback / lost-state cases; revocation is what bounds clones.

### 7.2 Costs

- Liveness: W = 1 makes a device wait for its previous transaction (25 waits per 30 signatures when two
  clones race with one-block delays); revocation forces a 2-of-3 `registerSlot` per affected device.
- Gas: `validate()` measured at **85,205 gas** with a gas-faithful opcode stand-in (Foundry) — inside the
  100k validation budget with one compact JARDIN verification (~55k), the frame-binding checks, the ledger
  read and the hash binding guardian A to guardian B's entry (+5.5k over the unbound version, 79,701).
  Devnet figures: §8.
- Storage: one slot per JARDIN slot in the ledger; first use of a slot pays a new-slot SSTORE.

### 7.3 What the mitigation does not do

See §9.

### 7.4 Real-process crash experiment (`research/crash_test.py --kills 100`, `results/crash_test.json`)

| signer | random SIGKILL while signing | SIGKILL the instant a signature is released (fault injection) |
|---|---|---|
| naive: sign, release, then non-atomic write, no fsync | 911 signatures on 355 leaves; **272 reused leaves, γ up to 5** (a kill mid-write leaves a torn state file, the signer restarts at leaf 1) | **100 signatures on one leaf (γ = 100)** |
| persist-after-sign with atomic write + fsync | 6 reused leaves, γ = 2 | **γ = 100** |
| burn-before-sign (JARDIN / SP 800-208) | 0 reuse | 0 reuse |

At γ = 100 essentially every FORS secret of the leaf is public (expected forgery cost
−32·log2(1−(15/16)^100) ≈ 0.07 bits): a signer that persists *after* releasing can be fully broken by an
adversary who controls power or reset timing. Burn-before-sign removes this, which is why every PQ-Vault
signer burns first; the residual problems are the ones it cannot see (stale restore, rollback, clones).

## 8. Devnet results

All receipts, contract addresses and raw node responses: [`docs/RECEIPTS.md`](../docs/RECEIPTS.md)
(regenerated from the chain by `python -m pqv.receipts local`).

**Networks.** Primary: the **public chain-1337 hackathon alt-mempool devnet** (`altmempool.forshtat.com`,
ethrex `eip8141-tracer`, submissions through the workshop's ERC-8421 gateway `altmempoolgateway.forshtat.com`,
deployer funded by the devnet's own faucet). It stalled for several hours during the work (head fixed at block
408,262, faucet empty) and was later reset to a fresh genesis; every result below was then reproduced on it.
Before that, the same flow ran on a local devnet built from the same components (ethrex
`v23.0.0-eip8141-tracer-9aa3645d`, the commit the public devnet reports, compiled natively for arm64, driven by
a Lighthouse `focil` consensus client via Kurtosis, plus the published ERC-8421 sidecar image); its receipts
are kept in `docs/RECEIPTS.md` as a second, independent run. Gas figures are identical on both.

**PQ-signed frame transactions on the public hackathon devnet (all status 0x1;
explorer: https://explorer.altmempool.wtf/tx/<hash>).**

| # | action | block | tx | gas used | VERIFY frame gas | SENDER frame gas |
|---|---|---|---|---|---|---|
| 1 | transfer, guardians 0+1 (compact+compact) | 366 | `0x1a38358a…9cc1` | 574,622 | 82,049 | 121,216 |
| 2 | transfer, guardians 1+2 (compact+**stateless SPX**) | 378 | `0xe079a5d3…33b7bd` | 620,382 | 84,389 | 319,520 |
| 3 | key rotation for guardian 0 (approved by 1+2) | 386 | `0xe9191360…c05674` | 597,150 | 82,049 | 140,489 |
| 4 | key-loss recovery of guardian 2 (approved by 0+1) | 391 | `0x040e7d0e…f1a2b2` | 684,830 | 82,049 | 161,793 |
| 5 | transfer by the *recovered* guardian 2 + guardian 0 | 399 | `0x5aa7760e…91f8f4` | 476,702 | 82,049 | 121,216 |
| 6–7 | baseline vault: two transfers on the **same** leaf after a stale restore | 416, 421 | `0xf05a88db…aa648`, `0x2e8d4dd2…64834` | 378,782 each | 76,279 | 85,354 |
| 8 | watcher's equivocation proof revokes that slot | 423 | `0x09e6c4ae…19ed1` | (legacy tx) | | |
| 9 | transfer sent from the UI backend (`/api/transfer`) | 433 | `0x920c2437…62c105` | 378,782 | 82,049 | 121,216 |

The VERIFY frame (one JARDIN plain-FORS verification, frame binding, fee cap, LeafLedger read, hash binding to
guardian B) costs **82,049 gas on chain** (84,389 when guardian B's entry is the 6.5 KB SPX signature), inside
the 99,800 limit we declare so that limit + 2 × 100 (ARBITRARY entries) = MAX_VERIFY_GAS. A first-use ledger slot
costs state gas (EIP-8037) in the body frame. Contract deployment on the public devnet consumed far more gas
than locally (factory 18.06M vs 2.55M), consistent with a different state-gas price; frame-tx gas was identical.

**Why the alt mempool is necessary (recorded node responses).**
Recorded on both networks, identical outcome:
- Staked PQ-Vault → ethrex canonical mempool: rejected, `validation-prefix simulation failed: StorageReadNonSender`.
- Unstaked copy of the same vault → ERC-8421 gateway/sidecar: rejected, `unstaked payer accessed <LeafLedger> slot …`
  (public: `0x15c9…de23`).
- Staked PQ-Vault → ERC-8421 gateway/sidecar: admitted and included (transactions 1–5, 9).

**Live attack (controlled test wallets).** On the public devnet, a baseline vault (no leaf tracking,
JARDIN-style burn-before-sign signer) included two transfers authorised with leaf 1 of the same slot for
different transactions after the device state file was restored from a backup (blocks 416 and 421). A third
party then submitted the two public signatures to `LeafLedger.reportEquivocation`, which verified both with the
JARDIN verifier and revoked the slot (block 423). The same restored signer against PQ-Vault (re-signing guardian
0's consumed leaf 2) was refused by the vault's VERIFY frame in simulation and by the gateway: revert data
`0x7dced17e…02` = `StaleLeaf(slotId, 2)`. (Local run: blocks 211/212/213, `StaleLeaf(slotId, 4)`.)

**Infrastructure finding (local devnet).** ethrex's `ethrex_submitPrivilegedFrameTransaction` (the path the sidecar uses to
hand admitted transactions to the builder) gives each submission exactly one payload build and drops it
silently otherwise. With the sidecar's default 3 relay attempts, 2 of our first 7 admitted transactions were
cancelled ("relayed 4 times without being included in a block") although they simulated successfully;
raising `maxSubmitAttempts` fixed it (the next one needed 2 relays). This is an availability issue of the
demo-grade relay path, not of the vault.

### 8.1 Three frames, t-of-n, and the 100k validation cap (local devnet, `docs/RECEIPTS-three-frame.md`)

The results above are for the earlier two-frame 2-of-3 design (guardian A in VERIFY, guardian B in SENDER). The
vault is now t-of-n (n ≤ 16 and 2 ≤ t ≤ n fixed at creation) and **every approval is verified before payment is
approved**:

```
signatures: t ARBITRARY entries (guardian indices strictly increasing), all over messageFor(sigHash)
frame 0  VERIFY  scope EXECUTION (only_verify)   validate()‖0‖k   approvals [0, k)
frame 1  VERIFY  scope PAYMENT   (pay, = vault)  validate()‖k‖t   approvals [k, t)
frame 2  SENDER                                  execute(calls)   consume every leaf, run the batch
```

ERC-8421 [PREFIX-010] admits at most these two VERIFY frames (`[only_verify, pay]`, each optionally after one
`pre_verify` DEFAULT frame) and [PREFIX-050] forbids VERIFY after the prefix, so "one VERIFY frame per guardian"
is standard-compliant only for t = 2; for larger t the approvals are split across the two frames (k chosen by the
driver to balance gas). ethrex itself accepts any number of VERIFY frames; the limit is mempool policy.

What changed in security terms: a missing, corrupted, stale, duplicated or wrong-message approval now reverts a
VERIFY frame, which makes the transaction invalid — no fee, no leaf consumed. This removes the two-frame design's
"lone guardian can make the vault pay up to `MAX_TX_COST`" weakness and the relayer-corruption issue (G6) without
the `firstMessageFor` chaining, so guardians sign the same message independently and in any order. VERIFY frames
only *check* leaves (static); the SENDER frame *consumes* them with `LeafLedger.consume` (atomic check-and-update),
so a leaf consumed by another transaction after validation is caught there (`LeafRaced`: nothing executes, the
other leaves are still consumed because their signatures are public). Tests: `contracts/test/PQVault.t.sol`
(29 tests, real JARDIN signatures and verifiers, opcodes mocked).

**Validation gas** (Foundry, gas-faithful FrameOps stand-in / ethrex simulation on the local devnet):

| VERIFY frame content | Foundry (current code) | ethrex, run 1 (commit `ad291d5`) | ethrex, current code |
|---|---|---|---|
| frame 0, 1 compact approval | 86,135 | 84,596 | 84,718 |
| frame 1, 1 compact approval | 85,110 | 78,720 | 78,872 |
| frame 1, 2 compact approvals (3-of-4) | 154,630 | 146,790 | — |
| frame 1, 1 stateless SPX approval | 295,410 | 291,470 | — |

So any t ≥ 2 exceeds EIP-8141's combined `MAX_VERIFY_GAS` (100,000). ERC-8421 [BUDGET-010] replaces the combined
sum, for alternative mempools, with a per-entity sum capped at 1,000,000 for a **staked** entity
(`MAX_VERIFY_GAS_STAKED_ENTITY`; 100,000 unstaked). Both VERIFY frames belong to the vault (sender and payer),
which stakes itself, so t ≈ 12 compact approvals fit. The deployed workshop sidecar (`2e22ff0a`, also the current
upstream head) intentionally does not implement [BUDGET-010]; `infra/sidecar-budget010/` adds it (two source
files; 7 new unit tests; executor suite 393 passed vs 386 before, same 5 pre-existing load failures; built on the
published image digest without any npm download). ethrex needs no change: its simulate RPC records the overage in
`canonicalMempoolViolation` and still executes and traces.

**Admission, local devnet (ethrex `9aa3645d`, chain 3151908), recorded node responses:**

| transaction | ethrex canonical mempool | stock sidecar (combined 100k) | [BUDGET-010] sidecar |
|---|---|---|---|
| staked 2-of-4, compact+compact | rejected: prefix gas budget exceeds MAX_VERIFY_GAS | rejected: `… sum 200000 + signature-verification cost 200 = 200200 exceeds MAX_VERIFY_GAS 100000` | admitted, included (block 75 and 4 more) |
| staked 3-of-4, 3 compact (k=1) | rejected | — | admitted, block 85 |
| staked 2-of-4, compact + stateless SPX | rejected | — | admitted, block 86 |
| **unstaked** 2-of-4 (control) | rejected | — | rejected: `validation gas of unstaked entity … 200200 … exceeds MAX_VERIFY_GAS_PER_ENTITY 100000 [BUDGET-010]` |

Key rotation (block 89), lost-guardian recovery (block 90), a transfer by the rotated + recovered guardians
(block 92) and the live stale-backup attack (baseline vault included two transfers on one leaf, blocks 95/96;
equivocation report revoked the slot, block 97; PQ-Vault refused the restored signer in VERIFY frame 0 with
`StaleLeaf(slotId, 2)`) all ran on three-frame transactions through the [BUDGET-010] sidecar.

**Cost.** ethrex bills a frame transaction at `max(standard, 12,000 + 475·frames + 100·signatures + 64·bytes)`
plus state gas (EIP-7623/7976 calldata floor, `transaction.rs`); PQ-Vault transactions are floor-bound, so the
bill is set by bytes, not by execution gas. A 2-of-n transfer costs **379,769** gas (= 13,625 + 64 × 5,721 bytes),
versus 378,782 for the two-frame design (+987: one more frame and 8 more bytes of frame data); a 3-of-4 transfer
with two first-use ledger slots costs 751,005 (= 13,725 + 64 × 8,460 + 195,840 state gas). About 91% of a 2-of-n
transfer's bytes are the two 2,705-byte FORS signatures.

**Not shown:** admission on the public chain-1337 gateway. It runs the stock sidecar, so it rejects every t ≥ 2
three-frame transaction with the combined-cap error above; the draft upstream change is in
`infra/sidecar-budget010/README.md` (not submitted). §8.2 is the fallback that works with it today.

### 8.2 Two-frame fallback for combined-100k mempools (local devnet, `docs/RECEIPTS-two-frame-fallback.md`)

The vault accepts a second shape, selected by the frame count, for mempools that apply EIP-8141's combined
`MAX_VERIFY_GAS` (the deployed workshop gateway):

```
signatures: entry 0 = the committer's compact approval; entries 1..t-1 in increasing guardian order
frame 0  VERIFY  scope EXECUTION+PAYMENT (self_verify)  validateAndCommit()  entry 0 only
frame 1  SENDER                                         execute(calls)       verify entries 1..t-1, consume, run
```

Only one JARDIN verification fits 100k, so entries 1..t-1 are verified after payment is approved. Their bytes are
elided from the signature hash, so entry 0 signs **last**, over `firstMessageFor(sigHash, restHash)` with
`restHash = keccak256(keccak256(e1) ‖ … ‖ keccak256(e_{t-1}))`: a relayer that alters any later entry invalidates
the VERIFY frame (test `test_twoFrame_relayerMutatedLaterEntry_invalid`). Any guardian may be the committer, but
its approval must be compact (SPX does not fit). The residual cost is the old two-frame one, now bounded by the
same rule for every t: if a later approval is invalid, nothing executes, the fee (≤ `MAX_TX_COST`) is paid and the
committer's leaf is consumed (`ApprovalRejected`). The driver picks the shape per network (`--frames`, default 2
on `public`, 3 elsewhere). VERIFY gas: 89,647 (t = 2) and 89,996 (t = 3) in Foundry, 85,506 / 89,468 on chain;
declared limit `100,000 − 100·t`, so prefix + signature cost is exactly 100,000.

Run 2 on the local devnet (fresh factory/ledger/vaults with the current code), **stock** sidecar (same image
digest as the workshop's), recorded responses:

| transaction | ethrex canonical mempool | stock sidecar | included |
|---|---|---|---|
| 2-of-4, 2 frames, compact+compact | rejected (`StorageReadNonSender`, the shared ledger read) | admitted | block 337 (574,622 gas incl. 2 first-use ledger slots) and 708 (378,782) |
| 2-of-4, 2 frames, compact + stateless SPX | rejected | admitted | block 713 (620,382) |
| 3-of-4, 2 frames (committer = guardian 0) | rejected | admitted | block 725 (750,018) |
| 2-of-4, **3 frames** (control) | rejected (prefix gas budget) | rejected: `… = 200200 exceeds MAX_VERIFY_GAS 100000` | — |

Also in two frames through the stock sidecar: rotation (block 732), recovery (733), a transfer by the rotated and
recovered guardians (734), and the live stale-restore attack (baseline double inclusion at 737/738, equivocation
revocation at 739 — the watcher reconstructs the committer's `firstMessageFor` from the public transaction — and
PQ-Vault's VERIFY frame refusing the restored signer with `StaleLeaf(slotId, 10)`). With the [BUDGET-010] sidecar
the same code was included in both shapes (three frames block 742, 379,769 gas; two frames block 744, 378,782 gas).
The billed gas of a two-frame 2-of-n transfer, 378,782, equals the original public-devnet transfers: same bytes.

## 9. Limitations and unsuccessful experiments

**Limitations of the mitigation**
- **Clones are bounded, not prevented.** Two live copies can still sign one fresh leaf once (γ = 2, ≈ 96–98
  bits) before the report lands; the defence relies on someone watching the mempool and paying for the report.
- **In-flight window.** Leaves signed by transactions that are still pending (or dropped) are not yet
  anchored; W = 1 caps reuse at γ = 2, not 1.
- **Authenticated chain view.** The anchored signer trusts the host for the ledger mark. A host that *lies
  about the mark* degrades `anchored` to the baseline; `anchored_w1` refuses (denial of service) in that case.
- **Withhold-and-rollback (open; found after the experiments, not yet simulated).** A malicious host does not
  need to lie: it withholds the transaction carrying leaf q, rolls the device's storage back, and asks again.
  The chain truthfully still reports mark q−1, so even `anchored_w1` re-signs leaf q — unboundedly, and the
  signatures are never published, so no equivocation report fires. The host can then forge at leaf q (one
  guardian's approval; execution still needs a second guardian). Relevant to a secure element without reliable
  anti-rollback attached to a hostile host (a fully compromised software host can read the key anyway).
  No design can prevent reuse when storage, host and RPC are all untrusted and no trusted counter exists (the
  state-continuity problem: Memoir 2011, Ariadne 2016, ROTE 2017, Nimble 2023). Candidate fix, not implemented:
  per-boot instance IDs from the hardware RNG + leaf *leases* granted strictly above all previous leases on chain
  (authorised by the stateless key) + an on-device light client verifying the lease; residual: live RAM/VM
  snapshots (reuse bounded by lease size), and today's light-client signatures (BLS) are not post-quantum.
  Where nothing can be trusted, use the stateless path (PQ-Vault already supports it as the second approval).
- **Cross-protocol reuse.** The ledger only sees PQ-Vault usage. The same slot used in another account type
  (e.g. a JARDIN 4337 account) is not tracked.
- **Single guardian could spend fees (two-frame design only).** Resolved by the three-frame design (§8.1): every
  approval is verified in a VERIFY frame. The price is a validation prefix above EIP-8141's 100k, so the vault
  needs an ERC-8421 mempool with [BUDGET-010] and a stake; the deployed workshop gateway does not have it yet.
- **Model scope.** Simulator magnitudes depend on scenario parameters (backup age 10, rollback depth 3, …);
  the qualitative ordering is what we claim. SIGKILL tests process crashes, not power loss (unsynced page
  cache survives SIGKILL); power loss is modelled, not measured. No hardware secure element was tested.

**Unsuccessful or corrected experiments** (kept deliberately)
- The first real-process crash run *saturated*: the 128-leaf slot ran out after ~128 signatures, so most kills
  hit an idle process, and random kills almost never landed in the microsecond window between release and
  persistence — the naive signer showed **no** reuse. We added slot rotation and a targeted fault-injection
  mode (kill on release).
- The first W = 1 implementation **deadlocked** after any crash between burning and releasing a leaf; fixed by
  allowing a skip when nothing is in flight.
- Our first chain metric ("accepted on a reused leaf") conflated harmless acceptance of the device's own
  signature with replay; replaced by double-acceptance and an exposure-over-time metric.
- The first equivocation watcher also reported reuse on leaves the ledger had already retired, causing
  needless revocations (7 per run in one scenario); it now reports only exploitable reuse.
- **2-of-3 inside `VERIFY` does not fit the deployed sidecar**: two JARDIN FORS verifications plus overhead
  exceed `MAX_VERIFY_GAS = 100,000`, and the deployed sidecar (forshtat/mempool-workshop-sidecar @ 2e22ff0a)
  caps the whole prefix at 100k. The two-frame design split verification instead; §8.1 moves all approvals into
  VERIFY and implements ERC-8421 [BUDGET-010] in the sidecar (local devnet only).
- **Admitted but never included (§8.2, infrastructure).** Two two-frame transactions (3-of-4, and compact+SPX)
  plus one resubmission were admitted by the stock sidecar, relayed 41 times through ethrex's privileged path and
  cancelled. ethrex built a payload every slot in that window; its skip reason is only logged at debug level,
  which we then enabled at runtime (`admin_setLogLevel "info,ethrex_blockchain=debug"`). The same shapes,
  resubmitted, were included (blocks 713, 725); the only skip logged afterwards was a duplicate relay of an
  already-applied transaction (`Nonce mismatch`). Root cause of the earlier drops: not determined.
- **Per-vault slot governance (§8.2).** One guardian set can guard several vaults, but rotation/recovery is
  approved per vault: after rotating guardian 1 and recovering guardian 2 on the 2-of-4 vault, the 3-of-4 vault
  still registered their old slots and refused the new ones (`BadEntry(0, R_SLOT)`), as designed.
- **Mislabelled admission runs (§8.1).** Our first scripted batch of four admission cases passed each case's
  arguments as one zsh word (zsh does not split unquoted variables), so all four ran the default case (staked
  2-of-4, guardians 0 and 1) under the wrong tags. The four transactions are real and were included; their
  records were relabelled "budget010-2of4 repeat N" with a note, and the three intended cases were rerun.
- Infrastructure: the public devnet stalled at block 408,262 for several hours (head timestamp >6 h old, faucet
  empty) before being reset; meanwhile the published amd64 ethrex image segfaulted (exit 139) under emulation on
  Apple Silicon, so we built ethrex @ 9aa3645d natively for arm64 and ran a local Kurtosis devnet. After the reset,
  every devnet result was reproduced on the public devnet. Our first two crash-test
  harness revisions were also wrong (keys generated after "ready", so random kills hit key generation; and the
  fault-injection flag was dropped by an argv slice so children never self-killed) — both caught because the
  numbers were implausible (0 signatures; 267,904 signatures from 150 kills), fixed, and rerun.

## 10. Reproduce

```sh
git submodule update --init
(cd contracts && forge test)                                   # 29 tests (real JARDIN sigs + verifiers)
python3.12 -m unittest discover -s tests -t .                  # 25 tests: codec vs ethrex golden vector, JARDIN wrapper, stores, three-frame builder, sim invariants
python3.12 research/run_experiments.py --seeds 20              # ~10 min -> results/experiments.{json,md}
python3.12 research/sweeps.py --seeds 10                       # -> results/sweeps.{json,md}
python3.12 research/crash_test.py --kills 100                  # -> results/crash_test.json

# devnet (local; Apple Silicon needs the native ethrex build)
./infra/build-ethrex-arm64.sh                                  # or use the published amd64 image on x86
ETHREX_IMAGE=ethrex:eip8141-tracer-9aa3645d-arm64 ./infra/local-devnet.sh up
# write .devnet/local/network.json {"ethrex": "<infra/local-devnet.sh rpc>", "sidecar": "http://127.0.0.1:14337/rpc"},
# fund .devnet/deployer.json's address from the enclave's prefunded test account (its throwaway key is in the
# upstream sidecar repo's test/e2e/kurtosis/eip8141-single-node.yaml), then:
python3.12 -m pqv.devnet local deploy-infra
./infra/sidecar-local.sh <ethrex-port> <staking address from .devnet/local/deployment.json>
infra/sidecar-budget010/build.sh                               # ERC-8421 [BUDGET-010] sidecar image
SIDECAR_IMAGE=pqvault/mempool-sidecar:budget-010 ./infra/sidecar-local.sh <ethrex-port> <staking>
python3.12 -m pqv.devnet local new-guardians --n 4
python3.12 -m pqv.devnet local deploy-vault --threshold 2 --fund 2 --stake 0.02
python3.12 -m pqv.devnet local deploy-vault --vault vault34 --threshold 3 --fund 2 --stake 0.02
python3.12 -m pqv.devnet local transfer <to> 1000000000000000 --guardians 0,1          # after Hegota (epoch 2)
python3.12 -m pqv.devnet local transfer <to> 1000000000000000 --vault vault34 --guardians 0,2,3
python3.12 -m pqv.devnet local transfer <to> 2000000000000000 --guardians 1,3 --stateless 3
python3 -m research.mempool_admission local <tag> [--vault ...] [--guardians ...] [--frames 2|3]  # node responses
python3.12 -m pqv.devnet local transfer <to> 1000000000000000 --guardians 0,1 --frames 2   # fallback shape (stock sidecar)
python3.12 -m pqv.devnet local rotate 0 && python3.12 -m pqv.devnet local recover 2
python3.12 -m pqv.devnet local attack-stale-restore
python3.12 -m pqv.receipts local --out docs/RECEIPTS-three-frame.md
```

## Sources

- JARDIN: https://github.com/nconsigny/JARDIN · https://notes.ethereum.org/@niard/JARDIN
- SPHINCS-: https://github.com/nconsigny/SPHINCs- · https://ethresear.ch/t/sphincs-minus-efficient-stateless-post-quantum-signature-verification-on-the-evm/25165
- SHRINCS: https://delvingbitcoin.org/t/shrincs-324-byte-stateful-post-quantum-signatures-with-static-backups/2158
- SHRIMPS: https://delvingbitcoin.org/t/shrimps-2-5-kb-post-quantum-signatures-across-multiple-stateful-devices/2355
- McGrew, Kampanakis, Fluhrer, Gazdag, Butin, Buchmann, *State Management for Hash-Based Signatures*, SSR 2016: https://eprint.iacr.org/2016/357
- IETF draft-ietf-pquip-hbs-state-02 (Dec 2025): https://www.ietf.org/archive/id/draft-ietf-pquip-hbs-state-02.txt
- NIST SP 800-208, *Recommendation for Stateful Hash-Based Signature Schemes* (2020)
- EIP-8141: https://eips.ethereum.org/EIPS/eip-8141 · ERC-8421 draft: https://github.com/forshtat/ERCs (pr-clean branch)
