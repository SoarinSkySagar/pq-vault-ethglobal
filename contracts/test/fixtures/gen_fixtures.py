#!/usr/bin/env python3
"""Generate deterministic JARDIN signatures for the PQVault Foundry tests.

All keys are fixed test keys derived from public labels: NEVER use them for anything else.
Run from the repo root:  python3 contracts/test/fixtures/gen_fixtures.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
from pqv.hashing import keccak256  # noqa: E402
from pqv.jardin import (CompactSlot, SpxMaster, compact_entry, first_message,  # noqa: E402
                        stateless_entry, vault_message)

H = 7
OUT = os.path.join(os.path.dirname(__file__), "vault_fixtures.json")


def label(s):
    return keccak256(s.encode())


def main():
    masters = [label(f"pq-vault-test/guardian-{i}") for i in range(3)]
    spx = [SpxMaster(m) for m in masters]
    slots = [CompactSlot(masters[i], label(f"pq-vault-test/slot-{i}-0"), H) for i in range(3)]
    new_master = label("pq-vault-test/guardian-2-replacement")
    new_spx = SpxMaster(new_master)
    new_slot = CompactSlot(new_master, label("pq-vault-test/slot-2-replacement"), H)

    fx = {"h": H}
    for i in range(3):
        seed, root = spx[i].public
        fx[f"g{i}_spxSeed"] = "0x" + seed.hex()
        fx[f"g{i}_spxRoot"] = "0x" + root.hex()
        fx[f"g{i}_slotSeed"] = "0x" + slots[i].seed16.hex()
        fx[f"g{i}_slotRoot"] = "0x" + slots[i].root16.hex()
        fx[f"g{i}_slotId"] = "0x" + slots[i].slot_id.hex()
    s, r = new_spx.public
    fx.update({"g2new_spxSeed": "0x" + s.hex(), "g2new_spxRoot": "0x" + r.hex(),
               "g2new_slotSeed": "0x" + new_slot.seed16.hex(), "g2new_slotRoot": "0x" + new_slot.root16.hex(),
               "g2new_slotId": "0x" + new_slot.slot_id.hex()})

    # Entry builders take the message to sign. Entry 1 (guardian B) signs vault_message(sigHash); entry 0
    # (guardian A) signs first_message(sigHash, entry1) - PQVault binds A's approval to B's exact bytes.
    def c(slot_owner, slot, q):
        return lambda msg: compact_entry(slot_owner, slot, slot.sign(msg, q))

    def st(g, master):
        return lambda msg: stateless_entry(g, master.sign(msg))

    def tx(h, a, b, b_hash=None):
        e1 = b(vault_message(b_hash or h))  # b_hash: sign another tx's hash (wrong-message case)
        return h, a(first_message(h, e1)), e1

    scen = {}
    H1, H2, H3, H4, H5, H6, H7, H8, H9 = (label(f"pq-vault-test/tx{i}") for i in range(1, 10))
    scen["happy"] = tx(H1, c(0, slots[0], 1), c(1, slots[1], 1))
    scen["stateless"] = tx(H2, c(0, slots[0], 2), st(2, spx[2]))
    # Rolled-back signer: guardian 0 re-signs leaf 2 for a *different* transaction.
    scen["rollback"] = tx(H3, c(0, slots[0], 2), c(1, slots[1], 2))
    # Second approval from a rolled-back guardian 0 (leaf 1 already consumed by "happy").
    scen["rollbackSecond"] = tx(H4, c(1, slots[1], 3), c(0, slots[0], 1))
    scen["sameGuardian"] = tx(H5, c(0, slots[0], 3), c(0, slots[0], 4))
    # Second approval is a valid SPX signature, but over another transaction (H1).
    scen["wrongMsg"] = tx(H6, c(1, slots[1], 4), st(2, spx[2]), b_hash=H1)
    scen["recovery"] = tx(H7, c(0, slots[0], 5), c(1, slots[1], 5))
    scen["oldSlotAfterRecovery"] = tx(H8, c(2, slots[2], 1), c(0, slots[0], 6))
    scen["newSlotAfterRecovery"] = tx(H9, c(2, new_slot, 1), c(0, slots[0], 7))
    for k, (h, e0, e1) in scen.items():
        fx[f"{k}_sigHash"] = "0x" + h.hex()
        fx[f"{k}_e0"] = "0x" + e0.hex()
        fx[f"{k}_e1"] = "0x" + e1.hex()

    with open(OUT, "w") as f:
        json.dump(fx, f, indent=1)
    print(f"wrote {OUT}: {len(scen)} scenarios")


if __name__ == "__main__":
    main()
