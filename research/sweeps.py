#!/usr/bin/env python3
"""Sensitivity sweeps (real JARDIN signatures; same simulator as run_experiments.py).

  repeated_restore  restore the *same* old backup r times (VM snapshot revert, re-imaged disk)
  rollback_depth    rewind the counter by d leaves every 5 signatures
  clones            n live copies of one device signing concurrently

    python3 research/sweeps.py [--seeds 10]  -> research/results/sweeps.json / sweeps.md
"""
import argparse
import json
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from pqv.hashing import keccak256  # noqa: E402
from pqv.jardin import CompactSlot  # noqa: E402
from research.policies import POLICIES, Storage  # noqa: E402
from research.sim import Device, World, expected_bits, metrics, sign  # noqa: E402

RES = os.path.join(os.path.dirname(__file__), "results")
CASES = [("durable", False), ("durable", True), ("anchored_w1", True), ("anchored_w1", "revoke")]


def world(slot, ledger, seed):
    return World({0: slot}, bool(ledger), random.Random(seed), revoke=(ledger == "revoke"))


def repeated_restore(slot, P, ledger, seed, r):
    w = world(slot, ledger, seed)
    d = Device("A", P(slot.q_max), Storage())
    for _ in range(5):
        sign(w, d)
        w.mine()
    backup = d.st.copy()
    for _ in range(r):
        for _ in range(5):
            sign(w, d)
            w.mine()
        d.st = backup.copy()  # silent restore of the same old snapshot
    for _ in range(5):
        sign(w, d)
        w.mine()
    return metrics(w)


def rollback_depth(slot, P, ledger, seed, depth):
    w = world(slot, ledger, seed)
    d = Device("A", P(slot.q_max), Storage())
    for i in range(40):
        if i and i % 5 == 0:
            d.st.committed["next_q"] = max(1, d.st.read("next_q", 1) - depth)
            d.st.volatile.clear()
        sign(w, d)
        w.mine()
    return metrics(w)


def clones(slot, P, ledger, seed, n):
    w = world(slot, ledger, seed)
    devs = [Device("A", P(slot.q_max), Storage())]
    for i in range(30):
        if i == 5:
            devs += [Device(f"C{j}", P(slot.q_max), devs[0].st.copy()) for j in range(n - 1)]
        for d in devs:
            sign(w, d, delay=1)
        w.mine()
    return metrics(w)


SWEEPS = {"repeated_restore": (repeated_restore, [1, 2, 4, 8]),
          "rollback_depth": (rollback_depth, [1, 2, 3, 5]),
          "clones": (clones, [2, 3, 4])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=10)
    a = ap.parse_args()
    slots = [CompactSlot(keccak256(b"sim-master"), keccak256(b"sweep-seed-%d" % s), 7) for s in range(a.seeds)]
    rows = []
    for name, (fn, values) in SWEEPS.items():
        for v in values:
            for pol, ledger in CASES:
                runs = [fn(slots[s], POLICIES[pol], ledger, s, v) for s in range(a.seeds)]
                rows.append({"sweep": name, "value": v, "policy": pol, "ledger": ledger,
                             "worst_gamma": max(r["max_gamma"] for r in runs),
                             "worst_min_bits": min(r["min_bits"] for r in runs),
                             "expected_bits_at_worst_gamma": round(expected_bits(max(r["max_gamma"] for r in runs)), 1),
                             "total_double_accepted": sum(r["double_accepted"] for r in runs),
                             "mean_exposure_steps": round(statistics.mean(r["exposure_steps"] for r in runs), 2),
                             "mean_refused": round(statistics.mean(r["refused"] for r in runs), 2),
                             "mean_reslots": round(statistics.mean(r["reslots"] for r in runs), 2)})
        print("  ", name, "done", flush=True)
    os.makedirs(RES, exist_ok=True)
    json.dump({"seeds": a.seeds, "rows": rows}, open(os.path.join(RES, "sweeps.json"), "w"), indent=1)
    cols = ["value", "policy", "ledger", "worst_gamma", "worst_min_bits", "expected_bits_at_worst_gamma",
            "total_double_accepted", "mean_exposure_steps", "mean_refused", "mean_reslots"]
    with open(os.path.join(RES, "sweeps.md"), "w") as f:
        f.write(f"# Sensitivity sweeps ({a.seeds} seeds)\n\n")
        for name in SWEEPS:
            f.write(f"## {name}\n\n| " + " | ".join(cols) + " |\n|" + "---|" * len(cols) + "\n")
            for r in rows:
                if r["sweep"] == name:
                    f.write("| " + " | ".join(str(r[c]) for c in cols) + " |\n")
            f.write("\n")
    print("wrote", os.path.join(RES, "sweeps.md"))


if __name__ == "__main__":
    main()
