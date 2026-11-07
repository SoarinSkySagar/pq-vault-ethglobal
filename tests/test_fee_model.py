"""Wallet fee estimate (pqv/wallet.py): the gas model against measured receipts, and the send plan's decisions.

Expected gas values are receipts of frame txs on the local devnet (block numbers given); see the gas survey in
docs or re-measure with the explorer API (/api/tx/<hash>: gasUsed, per-frame stateGasUsed).
"""
import unittest

from pqv import wallet as w

C7, C2, S = ("compact", 7), ("compact", 2), ("stateless", None)


class GasModel(unittest.TestCase):
    def test_reproduces_measured_receipts(self):
        cases = [  # (block, signers, new storage slots, rotation, billed gasUsed)
            (116, [C7, C7], 0, False, 379_513),   # ordinary payment
            (78, [C7, C7], 1, False, 477_433),    # one key's first leaf
            (843, [C7, C7], 2, False, 575_353),   # a new wallet's first payment
            (75, [C7, S], 0, False, 621_113),     # stateless (SPX) approval
            (76, [C7, C7], 2, True, 597_881),     # rotation
            (488, [C2, C2], 0, False, 369_273),   # 4-leaf slots: shorter auth paths
            (495, [S, C2], 0, False, 615_993),
            (496, [S, S], 0, False, 862_713),
            (490, [C2, C2], 2, True, 587_641),
            (497, [S, C2], 1, True, 736_441),
            (498, [S, C2], 2, True, 834_361),
        ]
        for block, signers, new, rot, gas in cases:
            with self.subTest(block=block):
                self.assertEqual(w.frame_tx_gas(signers, new, rot), gas)


class _Slot:
    def __init__(self, i, h):
        self.h, self.q_max, self.slot_id = h, 1 << h, bytes([i]) * 32


class _Key:
    def __init__(self, i, remaining, h=7):
        self.i, self._rem, self._slot = i, remaining, _Slot(i, h)

    def remaining_leaves(self):
        return self._rem

    def slot(self):
        return self._slot


class _Net:
    def __init__(self, used):
        self.used = used

    def ledger_hwm(self, slot_id):
        return 5 if slot_id[0] in self.used else 0


class SendPlan(unittest.TestCase):
    def plan(self, keys, used=(0, 1, 2)):
        old, w.W = w.W, _Net(set(used))
        try:
            return w.send_plan(keys)
        finally:
            w.W = old

    def test_ordinary_payment_uses_the_two_fullest_keys(self):
        p = self.plan([_Key(0, 90), _Key(1, 120), _Key(2, 110)])
        self.assertEqual([(t["what"], t["guardians"], t["gas"]) for t in p], [("payment", [1, 2], 379_513)])

    def test_new_wallet_pays_for_two_ledger_entries(self):
        p = self.plan([_Key(i, 128) for i in range(3)], used=())
        self.assertEqual([(t["guardians"], t["newStorage"], t["gas"]) for t in p], [([0, 1], 2, 575_353)])

    def test_renewal_first_then_payment(self):
        # 4-leaf keys: key 0 has 1 leaf left (renewal due), key 2 none (signs stateless when approving the renewal);
        # blocks 497 and 499 are exactly this sequence: rotation (SPX + compact) then a payment with the fresh slot.
        p = self.plan([_Key(0, 1, 2), _Key(1, 3, 2), _Key(2, 0, 2)])
        self.assertEqual([(t["what"], t["guardians"], t["kinds"], t["gas"]) for t in p], [
            ("renew", [1, 2], ["compact", "stateless"], 736_441),
            ("payment", [0, 1], ["compact", "compact"], 467_193),
        ])


if __name__ == "__main__":
    unittest.main()
