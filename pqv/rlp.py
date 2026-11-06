"""Minimal RLP (Ethereum Yellow Paper, Appendix B). Items are bytes or lists of items."""
from typing import List, Union

Item = Union[bytes, List["Item"]]


def uint(n: int) -> bytes:
    """RLP integer: zero is the empty string, otherwise minimal big-endian bytes."""
    if n < 0:
        raise ValueError("negative integer")
    return b"" if n == 0 else n.to_bytes((n.bit_length() + 7) // 8, "big")


def _prefix(length: int, offset: int) -> bytes:
    if length < 56:
        return bytes([offset + length])
    bl = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(bl)]) + bl


def encode(item: Item) -> bytes:
    if isinstance(item, (bytes, bytearray)):
        b = bytes(item)
        if len(b) == 1 and b[0] < 0x80:
            return b
        return _prefix(len(b), 0x80) + b
    if isinstance(item, list):
        payload = b"".join(encode(i) for i in item)
        return _prefix(len(payload), 0xC0) + payload
    raise TypeError(f"cannot RLP-encode {type(item)}")


def decode(data: bytes) -> Item:
    item, rest = _decode(data)
    if rest:
        raise ValueError("trailing bytes after RLP item")
    return item


def _decode(data: bytes):
    if not data:
        raise ValueError("empty input")
    b0 = data[0]
    if b0 < 0x80:
        return data[:1], data[1:]
    if b0 < 0xB8:
        n = b0 - 0x80
        return data[1 : 1 + n], data[1 + n :]
    if b0 < 0xC0:
        ll = b0 - 0xB7
        n = int.from_bytes(data[1 : 1 + ll], "big")
        return data[1 + ll : 1 + ll + n], data[1 + ll + n :]
    if b0 < 0xF8:
        n = b0 - 0xC0
        payload, rest = data[1 : 1 + n], data[1 + n :]
    else:
        ll = b0 - 0xF7
        n = int.from_bytes(data[1 : 1 + ll], "big")
        payload, rest = data[1 + ll : 1 + ll + n], data[1 + ll + n :]
    items = []
    while payload:
        it, payload = _decode(payload)
        items.append(it)
    return items, rest
