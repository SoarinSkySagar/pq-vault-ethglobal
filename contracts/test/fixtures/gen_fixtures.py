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
from pqv.jardin import CompactSlot, SpxMaster, compact_entry, stateless_entry, vault_message  # noqa: E402

H = 7
N = 3
OUT = os.path.join(os.path.dirname(__file__), "vault_fixtures.json")


def label(s):
    return keccak256(s.encode())


def main():
    masters = [label(f"pq-vault-test/guardian-{i}") for i in range(N)]
    spx = [SpxMaster(m) for m in masters]
    slots = [CompactSlot(masters[i], label(f"pq-vault-test/slot-{i}-0"), H) for i in range(N)]
    new_master = label("pq-vault-test/guardian-2-replacement")
    new_spx = SpxMaster(new_master)
    new_slot = CompactSlot(new_master, label("pq-vault-test/slot-2-replacement"), H)

    fx = {"h": H}
    for i in range(N):
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

    # Every approving guardian signs vault_message(sigHash) (PQVault.messageFor); entry builders take it.
    def c(g, slot, q):
        return lambda msg: compact_entry(g, slot, slot.sign(msg, q))

    def st(g, master):
        return lambda msg: stateless_entry(g, master.sign(msg))

    def tx(h, *signers, signed_hash=None):
        m = vault_message(signed_hash or h)  # signed_hash: sign another tx's hash (wrong-message case)
        return h, [s(m) for s in signers]

    scen = {}
    TX = [label(f"pq-vault-test/tx{i}") for i in range(11)]
    scen["happy"] = tx(TX[1], c(0, slots[0], 1), c(1, slots[1], 1))
    scen["stateless"] = tx(TX[2], c(0, slots[0], 2), st(2, spx[2]))
    # Rolled-back signer: guardian 0 re-signs leaf 2 for a *different* transaction.
    scen["rollback"] = tx(TX[3], c(0, slots[0], 2), c(1, slots[1], 2))
    # Rolled-back guardian 1 checked in the *second* VERIFY frame (its leaf 1 was consumed by "happy").
    scen["rollbackSecond"] = tx(TX[4], c(0, slots[0], 3), c(1, slots[1], 1))
    scen["sameGuardian"] = tx(TX[5], c(0, slots[0], 3), c(0, slots[0], 4))
    # Second approval is a valid SPX signature, but over another transaction (H1).
    scen["wrongMsg"] = tx(TX[6], c(1, slots[1], 4))
    scen["wrongMsg"][1].append(st(2, spx[2])(vault_message(TX[1])))
    scen["recovery"] = tx(TX[7], c(0, slots[0], 5), c(1, slots[1], 5))
    scen["oldSlotAfterRecovery"] = tx(TX[8], c(0, slots[0], 6), c(2, slots[2], 1))
    scen["newSlotAfterRecovery"] = tx(TX[9], c(0, slots[0], 7), c(2, new_slot, 1))
    for k, (h, entries) in scen.items():
        fx[f"{k}_sigHash"] = "0x" + h.hex()
        fx[f"{k}_n"] = len(entries)
        for i, e in enumerate(entries):
            fx[f"{k}_e{i}"] = "0x" + e.hex()

    with open(OUT, "w") as f:
        json.dump(fx, f, indent=1)
    print(f"wrote {OUT}: {len(scen)} scenarios")


if __name__ == "__main__":
    main()
