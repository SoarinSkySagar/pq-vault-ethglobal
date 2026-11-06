"""pqv.jardin (wrapper over the upstream JARDIN signers) and pqv.state (leaf-state stores)."""
import os
import tempfile
import unittest

from pqv.hashing import keccak256
from pqv.jardin import (CompactSlot, SpxMaster, compact_entry, parse_compact_entry, stateless_entry,
                        vault_message)
from pqv.state import AnchoredLeafStore, DurableLeafStore, LeafExhausted

MASTER = keccak256(b"pqv-unit-test-master")


class Jardin(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.slot = CompactSlot(MASTER, keccak256(b"unit-slot"), 4)

    def test_compact_sign_verify_and_entry_layout(self):
        m = vault_message(keccak256(b"tx"))
        sig = self.slot.sign(m, 3)
        self.assertEqual(len(sig), 2593 + 16 * 4)
        self.assertTrue(self.slot.verify(m, sig))
        self.assertFalse(self.slot.verify(keccak256(b"other"), sig))
        g, slot_id, q, fors = parse_compact_entry(compact_entry(2, self.slot, sig))
        self.assertEqual((g, slot_id, q, fors), (2, self.slot.slot_id, 3, sig))

    def test_same_leaf_same_message_is_deterministic(self):
        m = keccak256(b"m")
        self.assertEqual(self.slot.sign(m, 5), self.slot.sign(m, 5))  # re-signing reveals nothing new

    def test_leaf_bounds(self):
        with self.assertRaises(ValueError):
            self.slot.sign(keccak256(b"m"), self.slot.q_max + 1)

    def test_slot_randomness_separates_devices(self):
        other = CompactSlot(MASTER, keccak256(b"unit-slot-2"), 4)
        self.assertNotEqual(other.slot_id, self.slot.slot_id)

    def test_stateless_master(self):
        spx = SpxMaster(MASTER)
        m = vault_message(keccak256(b"tx2"))
        sig = spx.sign(m)
        self.assertEqual(len(stateless_entry(1, sig)), 2 + 6512)
        self.assertTrue(spx.verify(m, sig))

    def test_vault_message_matches_solidity_definition(self):
        # keccak256(abi.encode(keccak256("PQ-Vault/v1"), sigHash))
        sh = bytes(range(32))
        self.assertEqual(vault_message(sh), keccak256(keccak256(b"PQ-Vault/v1") + sh))


class Stores(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.sid = keccak256(b"slot")

    def test_burn_before_sign_monotonic_and_persistent(self):
        p = os.path.join(self.dir, "s.json")
        st = DurableLeafStore(p)
        self.assertEqual([st.reserve(self.sid, 4) for _ in range(3)], [1, 2, 3])
        self.assertEqual(DurableLeafStore(p).reserve(self.sid, 4), 4)  # survives a restart
        with self.assertRaises(LeafExhausted):
            st.reserve(self.sid, 4)

    def test_stale_backup_reuses_without_anchor(self):
        p = os.path.join(self.dir, "s.json")
        st = DurableLeafStore(p)
        st.reserve(self.sid, 128)
        backup = open(p).read()
        st.reserve(self.sid, 128)
        open(p, "w").write(backup)  # restore an outdated backup
        self.assertEqual(DurableLeafStore(p).reserve(self.sid, 128), 2)  # leaf 2 handed out twice

    def test_anchored_store_resumes_above_chain_mark(self):
        p = os.path.join(self.dir, "s.json")
        hwm = {"v": 0}
        st = AnchoredLeafStore(p, lambda sid: hwm["v"])
        self.assertEqual(st.reserve(self.sid, 128), 1)
        backup = open(p).read()
        self.assertEqual(st.reserve(self.sid, 128), 2)
        hwm["v"] = 2  # both landed on chain
        open(p, "w").write(backup)  # stale restore
        self.assertEqual(AnchoredLeafStore(p, lambda sid: hwm["v"]).reserve(self.sid, 128), 3)


if __name__ == "__main__":
    unittest.main()
