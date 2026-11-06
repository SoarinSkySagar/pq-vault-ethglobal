"""Invariants of the research simulator that the report's claims rest on (small, fast runs)."""
import unittest

from pqv.hashing import keccak256
from pqv.jardin import CompactSlot
from research.policies import POLICIES
from research.sim import SCENARIOS, expected_bits, forgery_bits


class Sim(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.slot = CompactSlot(keccak256(b"sim-master"), keccak256(b"sim-test"), 7)

    def test_fors_reuse_formula_matches_jardin_table(self):
        # JARDIN README, k=32 a=4: 128.0 / 97.5 / 80.2 / 59.4 / 34.3 / 14.9
        for g, want in [(1, 128.0), (2, 97.5), (3, 80.2), (10, 34.3), (20, 14.9)]:
            self.assertAlmostEqual(expected_bits(g), want, delta=0.1)
        self.assertEqual(forgery_bits([]), 128.0)

    def run_s(self, scen, pol, ledger):
        return SCENARIOS[scen](self.slot, POLICIES[pol], ledger, 0)

    def test_stale_backup_breaks_baseline_but_not_anchored(self):
        self.assertGreaterEqual(self.run_s("stale_backup_silent", "durable", False)["max_gamma"], 2)
        self.assertEqual(self.run_s("stale_backup_silent", "anchored", True)["max_gamma"], 1)

    def test_ledger_prevents_on_chain_double_acceptance(self):
        for scen in ("stale_backup_silent", "rollback", "clone"):
            self.assertGreater(self.run_s(scen, "durable", False)["double_accepted"], 0, scen)
            self.assertEqual(self.run_s(scen, "durable", True)["double_accepted"], 0, scen)

    def test_clone_is_not_solved_by_anchoring_alone_but_revocation_bounds_it(self):
        a = self.run_s("clone", "anchored_w1", True)
        r = self.run_s("clone", "anchored_w1", "revoke")
        self.assertEqual(a["max_gamma"], 2)
        self.assertLess(r["exposure_steps"], a["exposure_steps"])
        self.assertGreaterEqual(r["revocations"], 1)

    def test_burn_before_sign_survives_crashes(self):
        self.assertEqual(self.run_s("crash", "durable", False)["max_gamma"], 1)
        self.assertGreaterEqual(self.run_s("crash", "naive", False)["max_gamma"], 2)


if __name__ == "__main__":
    unittest.main()
