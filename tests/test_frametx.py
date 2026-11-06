"""Frame-tx codec vs. ethrex 9aa3645d `golden_frame_tx_rlp_and_sig_hash` (transaction.rs),
which upstream cross-checked against an independent implementation (frametx.py)."""
import unittest

from pqv import frametx as ft

GOLDEN_RLP = (
    "f8b301c1800794000000000000000000000000000000000000abcdeccc010380c48252088080821122de028094000000"
    "0000000000000000000000000000001234c4829c40808080f85cf85a0194000000000000000000000000000000000000"
    "abcd80b84101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
    "01010101010101010101010101010101010101010101cc843b9aca008506fc23ac0080c0c0"
)
GOLDEN_SIGHASH = "d4df51143828c0338882dbd10c3308f3569972fe1928a7b5040ee18057920510"


def golden_tx():
    addr = lambda n: n.to_bytes(20, "big")
    return ft.FrameTx(
        chain_id=1, nonce_keys=[0], nonce_seq=7, sender=addr(0xABCD),
        frames=[ft.Frame(1, 3, None, 0x5208, 0, 0, bytes([0x11, 0x22])),
                ft.Frame(2, 0, addr(0x1234), 0x9C40, 0, 0, b"")],
        signatures=[ft.Signature(ft.SCHEME_SECP256K1, addr(0xABCD), b"", b"\x01" * 65)],
        max_priority_fee=0x3B9ACA00, max_fee=0x6FC23AC00, max_fee_per_blob=0)


class FrameTxCodec(unittest.TestCase):
    def test_golden_rlp(self):
        self.assertEqual(golden_tx().payload_rlp().hex(), GOLDEN_RLP)

    def test_golden_sig_hash(self):
        self.assertEqual(golden_tx().sig_hash().hex(), GOLDEN_SIGHASH)

    def test_sig_hash_elides_empty_msg_signature_bytes(self):
        a, b = golden_tx(), golden_tx()
        b.signatures[0].signature = b"\x02" * 65
        self.assertEqual(a.sig_hash(), b.sig_hash())
        self.assertNotEqual(a.tx_hash(), b.tx_hash())

    def test_sig_hash_covers_frame_data(self):
        a, b = golden_tx(), golden_tx()
        b.frames[1].data = b"\x01"
        self.assertNotEqual(a.sig_hash(), b.sig_hash())

    def test_roundtrip(self):
        tx = golden_tx()
        self.assertEqual(ft.decode_raw(tx.raw()).raw(), tx.raw())


if __name__ == "__main__":
    unittest.main()
