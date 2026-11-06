"""Phone access gate (pqv/lan.py): pairing codes, normalisation, lockout after repeated wrong codes."""
import os
import stat
import tempfile
import unittest
from unittest import mock

from pqv import lan


class PairingCode(unittest.TestCase):
    def test_made_once_private_and_well_formed(self):
        with tempfile.TemporaryDirectory() as d:
            c = lan.pairing_code(d)
            self.assertEqual(c, lan.pairing_code(d))  # stable across restarts
            self.assertRegex(c, r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")
            self.assertTrue(set(c.replace("-", "")) <= set(lan.CODE_ALPHABET))
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, "pair-code")).st_mode), 0o600)


class Gate(unittest.TestCase):
    CODE = "K7QM-P3XA-WN9D"

    def test_accepts_the_code_in_any_case_and_spacing(self):
        g = lan.Gate(self.CODE)
        for h in ("Bearer K7QM-P3XA-WN9D", "bearer k7qmp3xawn9d", "Bearer k7qm p3xa wn9d"):
            self.assertEqual(g.check(h), "ok", h)

    def test_rejects_missing_wrong_and_non_bearer(self):
        g = lan.Gate(self.CODE)
        self.assertEqual(g.check(""), "missing")
        self.assertEqual(g.check("Basic K7QM-P3XA-WN9D"), "missing")
        self.assertEqual(g.check("Bearer K7QM-P3XA-WN9E"), "wrong")
        self.assertEqual(g.check("Bearer K7QM-P3XA"), "wrong")  # a prefix is not the code

    def test_locks_after_too_many_wrong_codes_then_recovers(self):
        g = lan.Gate(self.CODE)
        t = [1000.0]
        with mock.patch.object(lan.time, "monotonic", lambda: t[0]):
            for _ in range(lan.FAIL_LIMIT):
                self.assertEqual(g.check("Bearer AAAA-AAAA-AAAA"), "wrong")
            self.assertEqual(g.check("Bearer " + self.CODE), "locked")  # even the right code waits
            self.assertEqual(g.check(""), "locked")
            t[0] += lan.FAIL_WINDOW + 1
            self.assertEqual(g.check("Bearer " + self.CODE), "ok")

    def test_missing_codes_do_not_count_towards_the_lockout(self):
        g = lan.Gate(self.CODE)
        for _ in range(lan.FAIL_LIMIT * 2):
            g.check("")
        self.assertEqual(g.check("Bearer " + self.CODE), "ok")


if __name__ == "__main__":
    unittest.main()
