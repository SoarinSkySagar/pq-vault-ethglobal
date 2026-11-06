"""keccak256 from the Python stdlib (OpenSSL >= 3.2 KECCAK-256) and import plumbing for
the upstream JARDIN reference signers."""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JARDIN_SCRIPT_DIR = os.path.join(ROOT, "third_party", "JARDIN", "script")
SHIM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shim")


def keccak256(data: bytes) -> bytes:
    return hashlib.new("KECCAK-256", data).digest()


assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"


def enable_jardin_imports() -> None:
    """Make `import jardin_fors_plain_signer` etc. resolve to the pinned upstream files,
    with `Crypto.Hash.keccak` served by the stdlib adapter in pqv/_shim."""
    if not os.path.isdir(JARDIN_SCRIPT_DIR):
        raise RuntimeError("third_party/JARDIN missing: run `git submodule update --init`")
    for p in (SHIM_DIR, JARDIN_SCRIPT_DIR):
        if p not in sys.path:
            sys.path.insert(0, p)
