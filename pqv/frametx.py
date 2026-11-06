"""EIP-8141 frame transactions, laid out as the chain-1337 alt-mempool devnet expects.

Payload (profile `ethrex-eip8141-tracer` of @forshtat/hegota-support, and ethrex 9aa3645d
`FrameTransaction` RLP):
    [chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
     [max_priority_fee, max_fee, max_fee_per_blob_gas], blob_versioned_hashes,
     recent_root_references]
    frame     = [mode, flags, target | "", [limit_execution, limit_state], value, data]
    signature = [scheme, signer, msg, signature]
Wire bytes: 0x06 || rlp(payload).
sig_hash:   keccak256(0x06 || rlp(payload with the `signature` bytes of every empty-`msg`
            entry elided)); frame data is committed verbatim (ethrex compute_sig_hash).
"""
from dataclasses import dataclass, field, replace
from typing import List, Optional

from . import rlp
from .hashing import keccak256

TX_TYPE = 0x06
CHAIN_ID = 1337

MODE_DEFAULT, MODE_VERIFY, MODE_SENDER = 0, 1, 2
SCOPE_NONE, SCOPE_PAYMENT, SCOPE_EXECUTION, SCOPE_EXECUTION_AND_PAYMENT = 0, 1, 2, 3
SCHEME_ARBITRARY, SCHEME_SECP256K1, SCHEME_P256 = 0, 1, 2


def _b(h) -> bytes:
    if isinstance(h, (bytes, bytearray)):
        return bytes(h)
    h = h[2:] if h.startswith("0x") else h
    return bytes.fromhex(h)


@dataclass
class Frame:
    mode: int
    flags: int
    target: Optional[bytes]  # None = tx.sender
    execution: int
    state: int = 0
    value: int = 0
    data: bytes = b""

    def rlp_item(self):
        return [rlp.uint(self.mode), rlp.uint(self.flags), self.target or b"",
                [rlp.uint(self.execution), rlp.uint(self.state)], rlp.uint(self.value), self.data]


@dataclass
class Signature:
    scheme: int
    signer: bytes = b""
    msg: bytes = b""
    signature: bytes = b""

    def rlp_item(self):
        return [rlp.uint(self.scheme), self.signer, self.msg, self.signature]


@dataclass
class FrameTx:
    sender: bytes
    nonce_seq: int
    frames: List[Frame]
    signatures: List[Signature] = field(default_factory=list)
    max_priority_fee: int = 1_000_000_000
    max_fee: int = 2_000_000_000
    max_fee_per_blob: int = 0
    chain_id: int = CHAIN_ID
    nonce_keys: List[int] = field(default_factory=lambda: [0])

    def payload_item(self):
        return [rlp.uint(self.chain_id), [rlp.uint(k) for k in self.nonce_keys], rlp.uint(self.nonce_seq),
                self.sender, [f.rlp_item() for f in self.frames], [s.rlp_item() for s in self.signatures],
                [rlp.uint(self.max_priority_fee), rlp.uint(self.max_fee), rlp.uint(self.max_fee_per_blob)],
                [], []]

    def payload_rlp(self) -> bytes:
        return rlp.encode(self.payload_item())

    def raw(self) -> bytes:
        return bytes([TX_TYPE]) + self.payload_rlp()

    def tx_hash(self) -> bytes:
        return keccak256(self.raw())

    def sig_hash(self) -> bytes:
        elided = replace(self, signatures=[
            replace(s, signature=b"") if len(s.msg) == 0 else s for s in self.signatures])
        return keccak256(elided.raw())

    def to_wire(self) -> dict:
        hx = lambda n: hex(n)
        h = lambda b: "0x" + b.hex()
        return {
            "chainId": hx(self.chain_id),
            "nonceKeys": [hx(k) for k in self.nonce_keys],
            "nonceSeq": hx(self.nonce_seq),
            "sender": h(self.sender),
            "frames": [{
                "mode": f.mode, "flags": f.flags,
                "target": None if f.target is None else h(f.target),
                "limits": {"execution": hx(f.execution), "state": hx(f.state)},
                "value": hx(f.value), "data": h(f.data),
            } for f in self.frames],
            "signatures": [{"scheme": s.scheme, "signer": h(s.signer), "msg": h(s.msg),
                            "signature": h(s.signature)} for s in self.signatures],
            "fees": {"maxPriorityFeePerGas": hx(self.max_priority_fee), "maxFeePerGas": hx(self.max_fee),
                     "maxFeePerBlobGas": hx(self.max_fee_per_blob)},
            "blobVersionedHashes": [],
            "recentRootReferences": [],
        }


def decode_raw(raw: bytes) -> FrameTx:
    if raw[0] != TX_TYPE:
        raise ValueError("not a type-0x06 frame transaction")
    it = rlp.decode(raw[1:])
    if len(it) != 9:
        raise ValueError(f"expected 9 payload items, got {len(it)}")
    i = lambda b: int.from_bytes(b, "big")
    frames = [Frame(i(f[0]), i(f[1]), f[2] or None, i(f[3][0]), i(f[3][1]), i(f[4]), f[5]) for f in it[4]]
    sigs = [Signature(i(s[0]), s[1], s[2], s[3]) for s in it[5]]
    return FrameTx(sender=it[3], nonce_seq=i(it[2]), frames=frames, signatures=sigs,
                   max_priority_fee=i(it[6][0]), max_fee=i(it[6][1]), max_fee_per_blob=i(it[6][2]),
                   chain_id=i(it[0]), nonce_keys=[i(k) for k in it[1]])
