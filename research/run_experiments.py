#!/usr/bin/env python3
"""Run every scenario x policy x {no ledger, LeafLedger} over many seeds; write results/.

    python3 research/run_experiments.py [--seeds 20] [--h 7]
Outputs research/results/experiments.json and research/results/experiments.md (worst case and mean
over seeds). Deterministic for a given seed count.
"""
import argparse
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from pqv.hashing import keccak256  # noqa: E402
from pqv.jardin import CompactSlot  # noqa: E402
from research.policies import POLICIES  # noqa: E402
from research.sim import SCENARIOS  # noqa: E402

RES = os.path.join(os.path.dirname(__file__), "results")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--h", type=int, default=7)
    a = ap.parse_args()
    os.makedirs(RES, exist_ok=True)
    t0 = time.time()
    slots = [CompactSlot(keccak256(b"sim-master"), keccak256(b"sim-seed-%d" % s), a.h) for s in range(a.seeds)]
    rows = []
    for scen, fn in SCENARIOS.items():
        for pname, P in POLICIES.items():
            for ledger in (False, True, "revoke"):
                runs = [fn(slots[s], P, ledger, s) for s in range(a.seeds)]
                agg = {"scenario": scen, "policy": pname, "ledger": ledger, "seeds": a.seeds,
                       "worst_gamma": max(r["max_gamma"] for r in runs),
                       "mean_gamma": round(statistics.mean(r["max_gamma"] for r in runs), 2),
                       "worst_exploitable_bits": min(r["exploitable_bits"] for r in runs),
                       "mean_exploitable_bits": round(statistics.mean(r["exploitable_bits"] for r in runs), 1),
                       "worst_min_bits": min(r["min_bits"] for r in runs),
                       "mean_reused_leaves": round(statistics.mean(r["reused_leaves"] for r in runs), 2),
                       "total_double_accepted": sum(r["double_accepted"] for r in runs),
                       "mean_exposure_steps": round(statistics.mean(r["exposure_steps"] for r in runs), 2),
                       "worst_exposure_bits": min(r["exposure_min_bits"] for r in runs),
                       "mean_retires": round(statistics.mean(r["retires"] for r in runs), 2),
                       "mean_revocations": round(statistics.mean(r["revocations"] for r in runs), 2),
                       "mean_refused": round(statistics.mean(r["refused"] for r in runs), 2),
                       "mean_stateless": round(statistics.mean(r["stateless"] for r in runs), 2),
                       "mean_reslots": round(statistics.mean(r["reslots"] for r in runs), 2),
                       "mean_signatures": round(statistics.mean(r["signatures"] for r in runs), 1)}
                rows.append(agg)
        print(f"  {scen} done ({time.time() - t0:.0f}s)", flush=True)
    meta = {"seeds": a.seeds, "h": a.h, "q_max": 1 << a.h, "fors": "JARDIN plain FORS k=32 a=4",
            "runtime_s": round(time.time() - t0, 1)}
    json.dump({"meta": meta, "rows": rows}, open(os.path.join(RES, "experiments.json"), "w"), indent=1)

    cols = ["policy", "ledger", "worst_gamma", "worst_min_bits", "total_double_accepted", "mean_exposure_steps",
            "worst_exposure_bits", "mean_refused", "mean_retires", "mean_revocations", "mean_stateless", "mean_reslots"]
    with open(os.path.join(RES, "experiments.md"), "w") as f:
        f.write(f"# Experiment results\n\n{meta}\n\n")
        for scen in SCENARIOS:
            f.write(f"## {scen}\n\n| " + " | ".join(cols) + " |\n|" + "---|" * len(cols) + "\n")
            for r in rows:
                if r["scenario"] == scen:
                    f.write("| " + " | ".join(str(r[c]) for c in cols) + " |\n")
            f.write("\n")
    print(f"wrote {RES}/experiments.json and .md in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
