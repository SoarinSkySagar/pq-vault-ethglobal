#!/usr/bin/env python3
"""Draw the wallet app's home-screen icons (app/wallet/icons/*.png). Standard library only.

    python3 infra/make_app_icons.py

The glyph is a small hash tree: a root, two inner nodes and four one-time leaves, one of them already used (an
outline). It sits inside the central 60% so the same files work as Android maskable icons.
"""
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "app", "wallet", "icons")
BG, FG = (0x3B, 0x5B, 0xA9), (0xFF, 0xFF, 0xFF)

ROOT_N, MIDS = (0.50, 0.32), [(0.3665, 0.50), (0.6335, 0.50)]
LEAVES = [(0.30, 0.68), (0.4333, 0.68), (0.5667, 0.68), (0.70, 0.68)]
EDGES = [(ROOT_N, m) for m in MIDS] + [(MIDS[i // 2], leaf) for i, leaf in enumerate(LEAVES)]
STROKE, NODE_R, LEAF_H, LEAF_R, RING = 0.022, 0.05, 0.043, 0.014, 0.022
USED = 1  # index of the outlined (spent) leaf


def seg(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy) - STROKE / 2


def rbox(px, py, c, h, r):
    qx, qy = abs(px - c[0]) - h + r, abs(py - c[1]) - h + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def sdf(px, py):
    d = min(seg(px, py, a, b) for a, b in EDGES)
    d = min(d, math.hypot(px - ROOT_N[0], py - ROOT_N[1]) - NODE_R)
    for m in MIDS:
        d = min(d, math.hypot(px - m[0], py - m[1]) - NODE_R * 0.8)
    for i, leaf in enumerate(LEAVES):
        b = rbox(px, py, leaf, LEAF_H, LEAF_R)
        if i == USED:
            # an outlined leaf: the edge from its parent stops at the outline instead of filling it
            d = max(d, -(b + RING / 2))
            b = abs(b + RING / 2) - RING / 2
        d = min(d, b)
    return d


def png(n):
    rows = []
    for y in range(n):
        row = bytearray(b"\x00")
        py = (y + 0.5) / n
        for x in range(n):
            px = (x + 0.5) / n
            a = 0.0
            if 0.22 < px < 0.78 and 0.22 < py < 0.78:
                a = max(0.0, min(1.0, 0.5 - sdf(px, py) * n))
            row += bytes(round(BG[k] + (FG[k] - BG[k]) * a) for k in range(3))
        rows.append(bytes(row))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, n in (("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180), ("favicon-32.png", 32)):
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(png(n))
        print(os.path.join("app", "wallet", "icons", name))


if __name__ == "__main__":
    main()
