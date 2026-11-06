"""Three-frame t-of-n vault transactions built by pqv.devnet (no network: RPC answers are canned)."""
import unittest
from unittest import mock

from pqv import devnet as dv
from pqv import frametx as ft

VAULT = "0x" + "11" * 20


def _rpc(method, params=None):
    return {"eth_getTransactionCount": "0x5", "eth_chainId": hex(3151908),
            "eth_getBlockByNumber": {"baseFeePerGas": hex(7)}}[method]


class VaultTx(unittest.TestCase):
    def build(self, kinds, calls=((VAULT, 1, "0x"),), frames=3):
        with mock.patch.object(dv.rpc, "eth", _rpc), \
                mock.patch.object(dv, "execute_calldata", lambda c: b"\x3f\x70\x7e\x6b" + b"\x00" * 64):
            return dv.build_vault_tx(None, VAULT, list(calls), kinds, frames=frames)

    def test_three_frames_only_verify_then_pay_then_sender(self):
        tx = self.build(["compact", "compact"])
        f0, f1, f2 = tx.frames
        v = bytes.fromhex(VAULT[2:])
        self.assertEqual((f0.mode, f0.flags, f0.target), (ft.MODE_VERIFY, ft.SCOPE_EXECUTION, None))  # = tx.sender
        self.assertEqual((f1.mode, f1.flags, f1.target), (ft.MODE_VERIFY, ft.SCOPE_PAYMENT, v))
        self.assertEqual((f2.mode, f2.flags, f2.target), (ft.MODE_SENDER, 0, v))
        self.assertEqual(f0.data, dv.sel("validate()") + bytes([0, 1]))
        self.assertEqual(f1.data, dv.sel("validate()") + bytes([1, 2]))
        self.assertEqual(len(tx.signatures), 2)

    def test_split_balances_validation_gas(self):
        self.assertEqual(dv.split_point(["compact"] * 2), 1)
        self.assertEqual(dv.split_point(["compact"] * 5), 2)  # 2 | 3 or 3 | 2 both balance; first minimum
        self.assertEqual(dv.split_point(["stateless", "compact", "compact", "compact"]), 1)
        tx = self.build(["compact", "compact", "stateless"])
        k = tx.frames[0].data[5]
        self.assertEqual(k, 2)
        self.assertEqual(tx.frames[1].data[4:], bytes([2, 3]))

    def test_declared_limits_cover_measured_validation_gas(self):
        # Foundry measurements (contracts/test/PQVault.t.sol gas tests): 86,135 (1 compact),
        # 154,630 (2 compact), 295,410 (1 stateless) per VERIFY frame.
        self.assertGreaterEqual(dv.approval_gas(["compact"]), 86_135)
        self.assertGreaterEqual(dv.approval_gas(["compact", "compact"]), 154_630)
        self.assertGreaterEqual(dv.approval_gas(["stateless"]), 295_410)

    def test_prefix_over_staked_budget_is_refused(self):
        with self.assertRaises(ValueError):
            self.build(["stateless"] * 4)

    def test_signatures_do_not_change_sig_hash(self):
        tx = self.build(["compact", "compact", "compact"])
        sh = tx.sig_hash()
        for s in tx.signatures:
            s.signature = b"\x01" * 2739
        self.assertEqual(tx.sig_hash(), sh)

    def test_approver_plan_sorts_and_rejects_duplicates(self):
        gs = ["g0", "g1", "g2", "g3"]
        signers, kinds, idx = dv.approver_plan(gs, (3, 0, 2), stateless=(2,))
        self.assertEqual((signers, kinds, idx), (["g0", "g2", "g3"], ["compact", "stateless", "compact"], [0, 2, 3]))
        with self.assertRaises(ValueError):
            dv.approver_plan(gs, (1, 1))


class TwoFrameFallback(unittest.TestCase):
    build = VaultTx.build

    def test_shape_self_verify_then_sender(self):
        tx = self.build(["compact", "compact"], frames=2)
        f0, f1 = tx.frames
        self.assertEqual((f0.mode, f0.flags, f0.target), (ft.MODE_VERIFY, ft.SCOPE_EXECUTION_AND_PAYMENT, None))
        self.assertEqual(f0.data, dv.sel("validateAndCommit()"))
        self.assertEqual(f0.execution + 100 * 2, dv.MAX_VERIFY_GAS)  # prefix + signature cost = 100k exactly
        self.assertEqual((f1.mode, f1.flags), (ft.MODE_SENDER, 0))
        tx3 = self.build(["compact"] * 3, frames=2)
        self.assertEqual(tx3.frames[0].execution + 100 * 3, dv.MAX_VERIFY_GAS)

    def test_stateless_committer_refused(self):
        with self.assertRaises(ValueError):
            self.build(["stateless", "compact"], frames=2)

    def test_committer_first_then_increasing(self):
        gs = ["g0", "g1", "g2", "g3"]
        _, kinds, idx = dv.approver_plan(gs, (2, 0, 3), stateless=(0,), frames=2)
        self.assertEqual((idx, kinds), ([2, 0, 3], ["compact", "stateless", "compact"]))  # g0 is SPX -> g2 commits
        _, _, idx = dv.approver_plan(gs, (2, 0, 3), frames=2, committer=3)
        self.assertEqual(idx, [3, 0, 2])
        with self.assertRaises(ValueError):
            dv.approver_plan(gs, (0, 1), stateless=(0, 1), frames=2)

    def test_committer_signs_last_over_the_other_entries(self):
        tx = self.build(["compact", "compact", "compact"], frames=2)
        order, seen = [], {}

        def fn(i):
            def sign(m):
                order.append(i)
                seen[i] = m
                return bytes([i]) * 40
            return sign

        sh = dv.sign_entries(tx, [fn(0), fn(1), fn(2)])
        self.assertEqual(order[-1], 0)
        self.assertEqual(seen[1], dv.vault_message(sh))
        self.assertEqual(seen[2], dv.vault_message(sh))
        self.assertEqual(seen[0], dv.first_message(sh, [bytes([1]) * 40, bytes([2]) * 40]))


if __name__ == "__main__":
    unittest.main()
