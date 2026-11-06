"""Three-frame 2-of-3 vault transactions built by pqv.devnet (no network: RPC answers are canned)."""
import unittest
from unittest import mock

from pqv import devnet as dv
from pqv import frametx as ft

VAULT = "0x" + "11" * 20


def _rpc(method, params=None):
    return {"eth_getTransactionCount": "0x5", "eth_chainId": hex(3151908),
            "eth_getBlockByNumber": {"baseFeePerGas": hex(7)}}[method]


class VaultTx(unittest.TestCase):
    def build(self, kinds, calls=((VAULT, 1, "0x"),)):
        with mock.patch.object(dv.rpc, "eth", _rpc), \
                mock.patch.object(dv, "execute_calldata", lambda c: b"\x3f\x70\x7e\x6b" + b"\x00" * 64):
            return dv.build_vault_tx(None, VAULT, list(calls), kinds)

    def test_three_frames_only_verify_then_pay_then_sender(self):
        tx = self.build(["compact", "compact"])
        f0, f1, f2 = tx.frames
        v = bytes.fromhex(VAULT[2:])
        self.assertEqual((f0.mode, f0.flags, f0.target), (ft.MODE_VERIFY, ft.SCOPE_EXECUTION, None))  # = tx.sender
        self.assertEqual((f1.mode, f1.flags, f1.target), (ft.MODE_VERIFY, ft.SCOPE_PAYMENT, v))
        self.assertEqual((f2.mode, f2.flags, f2.target), (ft.MODE_SENDER, 0, v))
        self.assertEqual(f0.data, dv.sel("validate()"))
        self.assertEqual(f1.data, dv.sel("validate()"))
        self.assertEqual(len(tx.signatures), 2)

    def test_declared_limits_cover_measured_validation_gas(self):
        # Foundry measurements (contracts/test/PQVault.t.sol gas tests): 87,756 (frame 0, compact),
        # 82,110 (frame 1, compact), 296,854 (frame 1, stateless).
        self.assertGreaterEqual(dv.approval_gas("compact"), 87_756)
        self.assertGreaterEqual(dv.approval_gas("stateless"), 296_854)
        tx = self.build(["compact", "stateless"])
        self.assertEqual([tx.frames[0].execution, tx.frames[1].execution],
                         [dv.approval_gas("compact"), dv.approval_gas("stateless")])

    def test_exactly_two_approvals(self):
        with self.assertRaises(ValueError):
            self.build(["compact"] * 3)

    def test_signatures_do_not_change_sig_hash(self):
        tx = self.build(["compact", "compact"])
        sh = tx.sig_hash()
        for s in tx.signatures:
            s.signature = b"\x01" * 2739
        self.assertEqual(tx.sig_hash(), sh)

    def test_both_guardians_sign_the_same_message(self):
        tx = self.build(["compact", "compact"])
        seen = []
        sh = dv.sign_entries(tx, [lambda m: seen.append(m) or b"\x00" * 40] * 2)
        self.assertEqual(seen, [dv.vault_message(sh)] * 2)

    def test_approver_plan_sorts_and_rejects_bad_pairs(self):
        gs = ["g0", "g1", "g2"]
        signers, kinds, idx = dv.approver_plan(gs, (2, 0), stateless=(2,))
        self.assertEqual((signers, kinds, idx), (["g0", "g2"], ["compact", "stateless"], [0, 2]))
        for bad in [(1, 1), (0,), (0, 1, 2)]:
            with self.assertRaises(ValueError):
                dv.approver_plan(gs, bad)


class SlotRefresh(unittest.TestCase):
    def test_rotation_due_thresholds(self):
        self.assertFalse(dv.rotation_due(9, 128))        # default: rotate at <= 8 left of 128
        self.assertTrue(dv.rotation_due(8, 128))
        self.assertTrue(dv.rotation_due(0, 128))
        self.assertFalse(dv.rotation_due(2, 4))          # tiny slot: capped at q_max // 4 = 1
        self.assertTrue(dv.rotation_due(1, 4))
        self.assertFalse(dv.rotation_due(0, 128, rotate_at=0))  # disabled

    def test_exhausted_compact_approver_falls_back_to_stateless(self):
        self.assertEqual(dv.effective_kinds(["compact", "compact"], [0, 5]), ["stateless", "compact"])
        self.assertEqual(dv.effective_kinds(["stateless", "compact"], [0, 0]), ["stateless", "stateless"])

    def test_remaining_leaves_uses_local_counter_and_chain_mark(self):
        import tempfile, os
        from pqv.hashing import keccak256

        class FakeNet:
            def __init__(self, d):
                self.d, self.mark = d, 0

            def path(self, f):
                return os.path.join(self.d, f)

            def ledger_hwm(self, slot_id):
                return self.mark

        net = FakeNet(tempfile.mkdtemp())
        rec = {"index": 0, "master_sk": "0x" + keccak256(b"m").hex(),
               "slots": [{"r": "0x" + keccak256(b"r").hex(), "h": 2}]}
        g = dv.Guardian(net, rec)
        self.assertEqual(g.remaining_leaves(), 4)
        g.sign_compact(keccak256(b"tx1"))
        self.assertEqual(g.remaining_leaves(), 3)  # local burn-before-sign counter
        net.mark = 3
        self.assertEqual(g.remaining_leaves(), 1)  # leaves 1..3 already on chain (e.g. another device)
        net.mark = 2**256 - 1
        self.assertEqual(g.remaining_leaves(), 0)  # revoked slot (equivocation report)


if __name__ == "__main__":
    unittest.main()
