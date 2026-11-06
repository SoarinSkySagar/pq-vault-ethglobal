from pathlib import Path

content = r"""# PQ-Vault — Claude Code Context

> Purpose: Give Claude Code the architectural and project context needed to continue implementing PQ-Vault.
>
> **Important:** This document records the conversation's intended design and reported project status. It is not proof that every claim matches the current repository or the exact EIP-8141 / JARDIN implementation. Inspect the source code, pinned dependencies, client version, and protocol specifications before changing code. Do not silently assume that an architectural idea is already implemented or protocol-valid.

## 1. Project overview

**PQ-Vault** is a research smart wallet using post-quantum, hash-based JARDIN signatures for guardian authorization. It is being developed for ETHGlobal Mumbai 2026.

The intended wallet policy is **2-of-3 guardians**. Two valid guardian approvals are required to authorize a wallet operation. The wallet should not use an ECDSA authorization fallback.

The project combines:
- JARDIN hash-based signatures and upstream verification/signing code.
- EIP-8141 frame transactions.
- ERC-8421 alternative-mempool concepts / implementation.
- An on-chain LeafLedger to prevent reuse of stateful compact-signature leaves.
- Guardian rotation and recovery.
- A web UI and a demonstrable end-to-end devnet deployment.

Do not invent new cryptography. Prefer upstream JARDIN code and documented APIs. Treat this as a research prototype, not an audited production wallet.

## 2. Reported project status (verify against repository)

The project owner previously reported the following as implemented and tested. These are **reported facts**, not independently verified in this document:

### Phase 1 — wallet
- 2-of-3 guardian wallet.
- Guardian approvals use JARDIN hash-based signatures; no ECDSA authorization/fallback in the wallet.
- Upstream JARDIN verifier contracts and Python signers were reportedly used without modification.
- EIP-8141 transaction reportedly uses two frames:
  - `VERIFY`: verifies Guardian A's signature, checks leaf replay state, fee cap, and binding to the exact transaction/body data.
  - `SENDER`: verifies Guardian B's signature, records both leaves, and executes the batch.
- Key rotation and lost-device recovery (two guardians replace the third).
- Replay protection and local web UI.
- Alternative mempool integration.
- Public devnet chain ID 1337 and local ethrex EIP-8141 devnet tests reportedly succeeded.
- A relayer-corruption issue was reportedly fixed by binding Guardian A's approval to the exact bytes of Guardian B's signature.

### Phase 2 — stateful-signature backup / rollback research
The project owner reported experiments involving 128-leaf compact signing keys and leaf reuse:
- Restoring an old backup reportedly caused repeated use of a leaf.
- A simulated crash after signature release but before state persistence reportedly caused repeated leaf use.
- A LeafLedger was implemented to enforce monotonic leaf usage on-chain.
- An anchored signer reportedly reads the chain's mark before selecting a leaf.
- An in-flight signing window was introduced.
- Equivocation proofs were reportedly implemented to revoke a key if two signatures from one leaf are presented.
- Controlled tests reportedly covered stale backups, rollback, lost state, and clones.
- These are experimental results under test assumptions, not a mathematical proof that all rollback/reuse scenarios are impossible.

### Reported receipts / tests
The owner previously reported:
- `docs/RECEIPTS.md`
- `research/REPORT.md`
- `demo/pq-vault-demo.mp4`
- 20 Foundry tests and 19 Python tests.
- Frame transaction encoder matches an ethrex golden vector.
- A public devnet transaction hash was reported: `0x1a38358af26665a862b8a1b27eb9817565f08119d1aea3678d9c5bddaf6c9cc1` (block 366).
- Repo had not yet been committed/pushed at the time of the status report.

**Before relying on any item above, inspect the current repository, git history, test output, deployment receipts, and explorer data.**

## 3. Current intended authorization flow: three frames

The most recent design discussion settled on this proposed three-frame structure:

| Frame | Type | Intended responsibility |
|---|---|---|
| 1 | `VERIFY` | Verify Guardian A's JARDIN signature and check its leaf against the LeafLedger. |
| 2 | `VERIFY` | Verify Guardian B's JARDIN signature and check its leaf against the LeafLedger. |
| 3 | `SENDER` | Recheck both leaves, mark both as consumed, and execute the requested operation (for example, transfer 1 ETH). |

The high-level flow is:

```text
Guardian A signs the transaction authorization (off-chain)
                 |
Guardian B signs the same transaction authorization (off-chain)
                 |
        Collect both signatures
                 |
        Construct one EIP-8141 transaction
                 |
        Frame 1: VERIFY Guardian A
                 |
        Frame 2: VERIFY Guardian B
                 |
        Frame 3: SENDER
          - recheck both leaves
          - consume both leaves
          - execute transfer / batch
                 |
               Done
```

### Crucial timing distinction
The guardians do **not** have to sign simultaneously. Guardian A may sign at 10:00 AM and Guardian B at 3:00 PM. Their signatures are collected off-chain and submitted together later in one EIP-8141 transaction.

The signatures must authorize the **same transaction intent / digest**. Bind the authorization to all relevant fields, as appropriate to the transaction format:
- chain ID / domain
- vault/account address
- recipient(s)
- value(s)
- calldata / operation(s)
- nonce
- expiry/deadline, if used
- fee/payer constraints, if relevant
- any other fields that affect execution

Do not assume a timestamp makes signatures simultaneous. It does not. An expiry policy can limit how long an approval remains usable.

### Frame roles are an implementation choice
Guardian A is not more trusted than Guardian B. The different frame types in the earlier two-frame implementation were an architectural arrangement, not a rule that one guardian must always use `VERIFY` and another must always use `SENDER`.

The proposed three-frame arrangement is a design to investigate, **not yet confirmed as valid for the exact EIP-8141 version/client/mempool in use**.

## 4. LeafLedger: required semantics

The LeafLedger is persistent on-chain state used to stop a JARDIN compact-signature leaf from being accepted more than once.

Distinguish:
- **Checking a leaf:** read-only validation that the leaf has not already been consumed.
- **Consuming a leaf:** persistent state update recording that the leaf has been used.

The intended model:
1. Each `VERIFY` frame checks its guardian's signature and leaf against the current ledger.
2. The `SENDER` frame rechecks both leaves immediately before committing them.
3. The `SENDER` frame consumes both leaves and executes the operation in one atomic state transition, if protocol execution semantics permit.
4. If execution fails and the entire relevant EVM state transition reverts, the leaf updates should revert too. Confirm actual EIP-8141 transaction/frame rollback semantics; do not assume cross-frame rollback without checking the specification and client implementation.

### Why recheck in SENDER?
A leaf may be unused when validation occurs but become consumed by another transaction before this transaction's execution. Therefore, the SENDER frame must perform the authoritative check-and-update, not rely solely on earlier VERIFY checks.

### Storage identity
The ledger key must identify the **specific signing key or compact subtree**, not merely a human guardian label/address. A guardian may have multiple keys or rotate/renew subtrees.

Potential conceptual structure (not approved production code):

```solidity
mapping(bytes32 signingKeyOrSubtreeId => uint256 highestUsedLeaf)
    public highestUsedLeaf;
```

This monotonic-counter representation is valid only if the signer consumes leaves strictly in order and out-of-order leaf use is impossible. If leaves can be consumed out of order, use individual nullifiers or a bitmap / equivalent set representation.

For a leaf index `i`, a monotonic ledger should reject `i <= highestUsedLeaf` and update the high-water mark only according to the exact sequential-use invariant. Define the initial value carefully (e.g. sentinel / separate initialized flag) so leaf 0 is handled correctly.

### Important implementation questions
- Is the leaf index encoded in the signature or otherwise reliably available to the verifier/account?
- How is the subtree/key identity derived and authenticated?
- Can Guardian A and Guardian B use the same underlying key? If not intended, enforce the relevant separation.
- Can the same leaf be submitted concurrently in two transactions? The SENDER check-and-update must prevent both from succeeding.
- What is the behavior if the transfer fails?
- Are ledger updates in the same state-revert scope as the transfer?
- Does the mempool validate against state that may change before inclusion?
- Does the VERIFY frame have static-call semantics in the exact EIP-8141/client version? Confirm before relying on it. Earlier discussion assumed VERIFY cannot write persistent state; verify this against the actual spec and client.

## 5. Important signature-binding issue to resolve

The earlier implementation reportedly had Guardian A sign the exact bytes of Guardian B's signature to prevent a relayer from corrupting Guardian B's signature after Guardian A approved.

That design creates a signing-order dependency:
- Guardian B's signature must exist before Guardian A can sign bytes that include it.
- This conflicts with the desired example where Guardian A signs first and Guardian B signs hours later.

Do **not** preserve both claims as if they are simultaneously true.

Investigate a safer binding scheme in which both guardians sign a common canonical transaction digest, without one signature needing to exist before the other. The transaction digest should commit to the complete operation and relevant domain/nonce/expiry fields. The relayer must not be able to substitute either signature or alter the operation.

If the protocol's frame transaction hash or signature hash already binds the exact complete body, verify precisely what is covered. Do not assume it covers signatures, frame payloads, or execution calldata unless the spec/code proves it.

Document the selected scheme and add tests for:
- Guardian A signature paired with a different Guardian B signature.
- Guardian B signature paired with a different Guardian A signature.
- Any mutation to recipient, amount, calldata, nonce, chain ID, vault, fee, or expiry.
- Signature/frame reordering or substitution.
- Relayer mutation of signature bytes.

## 6. JARDIN 128-leaf compact-signature capacity

The conversation discussed a JARDIN compact signing key/subtree with **128 leaves**. Treat the exact limit and renewal behavior as something to verify in the pinned JARDIN source/specification.

Expected conceptual behavior:
- Each compact leaf is one-time-use.
- Once all 128 leaves of a particular compact subtree have been consumed, that subtree must not be reset or reused.
- Exhaustion of one subtree does not necessarily mean the guardian identity is permanently unusable.
- A fresh subtree/key may be registered or activated through the JARDIN-supported mechanism, reportedly involving a stateless signing path.

**Do not assume the re-registration flow exists in the current code or that the earlier description is complete. Inspect upstream JARDIN contracts, signer library, documentation, and examples.**

### Separate feature to investigate / implement
Subtree renewal may need integration in PQ-Vault if the upstream components do not already provide the complete flow:
1. Signer detects exhaustion / low remaining capacity.
2. Generate or derive a fresh subtree according to JARDIN's prescribed procedure.
3. Produce the correct stateless authorization/registration proof.
4. Smart contract validates and registers/activates the new subtree.
5. LeafLedger uses a distinct identity for the new subtree.
6. Old subtree remains exhausted/retired and cannot become active again.
7. Guardian rotation/recovery handles subtree state correctly.

Do not invent a registration protocol. Reuse the exact upstream JARDIN flow. Determine whether the subtree root, key ID, epoch, or another identifier is the correct ledger namespace.

### Example lifecycle (conceptual only)

```text
Subtree 1 registered
    |
128 compact leaves consumed
    |
Subtree 1 exhausted (never reset)
    |
JARDIN-authorized fresh subtree registration
    |
Subtree 2 registered/activated
    |
Use its fresh 128 leaves
```

## 7. EIP-8141 / mempool constraints to verify

EIP-8141 is experimental/draft protocol work, and the project reportedly uses an ethrex implementation/devnet. Do not assume current Ethereum mainnet support.

Before implementing the three-frame design, inspect the exact version of:
- EIP-8141 specification.
- ethrex implementation and frame execution code.
- Transaction encoder and golden vectors.
- Public mempool validation rules.
- ERC-8421 / alternative-mempool implementation and stake requirements.

Questions to answer with source references:
1. Is a transaction with two custom VERIFY frames followed by a SENDER frame permitted?
2. What are the exact VERIFY / `APPROVE` semantics?
3. Which frame(s) establish sender and payer authorization?
4. What does the public mempool accept as a validation prefix?
5. Can the alternative mempool accept the custom sequence?
6. What is the validation gas accounting across the two VERIFY frames?
7. Is there a per-frame or total validation gas limit? What exactly does the reported 100,000 gas cap apply to?
8. What are the state rollback / atomicity semantics across frames?
9. Can the final SENDER frame both update LeafLedger state and execute the transfer?
10. Is a separate execution SENDER frame allowed or required by the client?

Do not repeat the earlier assumption that any arbitrary number or order of VERIFY frames is automatically accepted. Verify it.

### Gas caution
The earlier project report said Guardian A's VERIFY frame used about 82,049 gas and mentioned a 100,000 validation cap. That is a reported measurement for one frame, not the total transaction gas. Two guardian verification frames may exceed the applicable validation budget. Measure with the actual client and mempool rules.

## 8. Security and correctness requirements

At minimum, add or preserve tests for:

### Authorization
- Both signatures valid for the same canonical transaction digest.
- Missing Guardian A or B approval fails.
- Invalid signature fails.
- Wrong guardian key fails.
- Wrong chain, vault, nonce, recipient, value, calldata, or fee fails.
- Expired approval fails, if expiry is implemented.

### Leaf replay / concurrency
- First use of each leaf succeeds.
- Reuse of either leaf fails.
- Same leaf submitted in two competing transactions cannot be consumed twice.
- Recheck in SENDER catches a leaf consumed after earlier validation.
- Different subtree IDs do not collide.
- Old exhausted subtree cannot be reactivated.
- Leaf 0 and final leaf index are handled correctly.
- Out-of-order leaves are either explicitly rejected or safely supported.

### Atomicity
- If leaf A is invalid, neither leaf is consumed.
- If leaf B is invalid, neither leaf is consumed.
- If the transfer reverts, both leaf updates revert if that is the intended protocol guarantee.
- If leaf update fails, the transfer does not execute.
- If batch item N fails, verify the intended all-or-nothing behavior.
- Confirm actual frame rollback behavior on ethrex, not just local mocks.

### Signing-state resilience
- Stale backup restoration.
- Process crash around signature generation and state persistence.
- Device clone / concurrent signer.
- Rollback of local state.
- RPC returning stale or malicious chain state.
- Network reorg / pending transaction behavior.
- Unpublished signatures and signatures generated but never submitted.
- Cross-chain or cross-vault reuse, according to the intended key scope.

Do not claim the on-chain ledger prevents all leaf reuse. It prevents acceptance/consumption of an already-consumed leaf in the relevant ledger domain. It cannot, by itself, prevent a compromised or rolled-back signer from generating duplicate unpublished signatures before any one of them is recorded on-chain.

## 9. Known limitations / research framing

Previously identified limitations:
- Signer trusts host/RPC for chain view.
- An unconfirmed transaction creates a window where the signer may need an in-flight policy.
- Alternative mempool validation limits may constrain signature checks.
- Clones cannot necessarily be prevented; mitigation may reduce the window.
- Power-loss tests were simulated, not measured on hardware.
- No hardware-backed JARDIN signing.
- Research prototype has not been independently audited.

Research claims must be conservative:
- Do not claim a new cryptographic primitive.
- Distinguish on-chain duplicate rejection from prevention of duplicate signature generation.
- Distinguish measured results from estimated attack complexity.
- Do not describe controlled simulations as proof of universal safety.
- Compare against existing JARDIN documentation, stateful-signature backup/rollback work, and public signature-log approaches before claiming novelty.

## 10. Implementation workflow for Claude Code

Before editing:
1. Inspect repository structure and git status.
2. Read README, architecture docs, `docs/RECEIPTS.md`, `research/REPORT.md`, contracts, signer code, tests, deployment scripts, and pinned dependencies if present.
3. Identify exact JARDIN and EIP-8141 versions/commits.
4. Trace the current two-frame flow end to end: signing digest, transaction encoding, VERIFY frame, SENDER frame, leaf checks, leaf writes, execution, mempool admission.
5. Compare actual code with the proposed three-frame design.
6. Identify which requirements are already implemented and which are only proposed.
7. Do not rewrite working components unnecessarily.

When implementing:
- Prefer minimal, reviewable changes.
- Reuse upstream JARDIN code.
- Add tests before or alongside changes.
- Preserve the existing working demo path until the new path passes tests.
- Do not weaken replay protection to make mempool admission easier.
- Do not claim EIP-8141 compatibility based only on a local mock.
- Record exact commands, test results, gas measurements, transaction hashes, and deployment addresses.
- If a spec or implementation detail cannot be verified, explicitly report that uncertainty rather than guessing.

## 11. Immediate next tasks

Recommended order:

1. **Audit current code against this context.** Confirm what is actually implemented.
2. **Resolve signature binding.** The earlier “Guardian A signs Guardian B's exact signature bytes” approach conflicts with independent signing where A signs first. Design and test a common canonical digest.
3. **Verify EIP-8141 frame semantics.** Confirm whether two VERIFY frames plus one SENDER frame are legal and mempool-admissible in the exact client version.
4. **Prototype the three-frame flow.** Keep leaf checks in VERIFY frames, then recheck and consume both leaves in the SENDER frame.
5. **Prove atomicity.** Verify that both leaf writes and the ETH transfer revert together on execution failure under actual frame semantics.
6. **Measure gas and mempool behavior.** Include both VERIFY frames and full transaction costs; do not confuse one frame's gas with total gas.
7. **Inspect JARDIN subtree renewal.** Determine whether upstream signer/contracts already implement registration/re-registration. Integrate the upstream lifecycle if needed.
8. **Update tests, docs, demo, and receipts.** State limitations precisely.

## 12. Useful official / primary references to inspect

Use the exact pinned source and version as the authority for implementation:
- EIP-8141: https://eips.ethereum.org/EIPS/eip-8141
- ERC-8421: locate and verify the exact current specification / repository used by this project.
- JARDIN design note previously referenced: https://notes.ethereum.org/@niard/JARDIN

The links above are starting points, not a substitute for checking the actual dependency versions and code in this repository.

---

## Instruction to Claude Code

Treat this file as project context, not as permission to make assumptions. First inspect the repository and report:
- what is already implemented,
- what differs from this document,
- which parts of the proposed three-frame architecture are supported by the exact EIP-8141 client,
- what the actual JARDIN subtree renewal mechanism is,
- and any security or correctness blockers.

Do not start a large refactor until those findings are clear.
"""
path = Path("/mnt/data/context.md")
path.write_text(content, encoding="utf-8")
print(f"Created {path} ({len(content.splitlines())} lines, {path.stat().st_size} bytes)")
