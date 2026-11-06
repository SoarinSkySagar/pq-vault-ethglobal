"""Adapter: exposes pycryptodome's `Crypto.Hash.keccak.new(digest_bits=256)` API
on top of OpenSSL's native KECCAK-256 (Ethereum keccak256, *not* SHA3-256),
available through hashlib on Python builds linked against OpenSSL >= 3.2.

No cryptography is implemented here; this only lets the upstream JARDIN and
SPHINCS- reference signers run without installing pycryptodome.
"""
import hashlib

try:
    hashlib.new("KECCAK-256")
except ValueError as e:  # pragma: no cover
    raise ImportError("this Python's OpenSSL lacks KECCAK-256 (need OpenSSL >= 3.2)") from e

# Known-answer check: keccak256("") (the Ethereum empty-code hash).
assert hashlib.new("KECCAK-256", b"").hexdigest() == (
    "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
), "KECCAK-256 KAT failed"


def new(data=None, digest_bits=256, **_ignored):
    if digest_bits != 256:
        raise ValueError("only keccak-256 is provided by this adapter")
    h = hashlib.new("KECCAK-256")
    if data is not None:
        h.update(data)
    return h
