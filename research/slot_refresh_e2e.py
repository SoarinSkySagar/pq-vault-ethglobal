#!/usr/bin/env python3
"""End-to-end slot refresh on a devnet, with 4-leaf compact slots (h = 2) so slots run out within a few txs.

    python -m research.slot_refresh_e2e local        (after infra/local-net.sh up)

Uses its own guardian set (.devnet/<net>/small-guardians.json) and vault (`smallVault`, staked), so the main
vault is untouched. Phases:
  A  5 transfers g0+g1 with automatic refresh on: nearly used-up slots are rotated first (approved 2-of-3).
  B  transfers g0+g2 with refresh off, until both approvers are out of compact leaves: stateless fallback.
  C  rotate guardian 2 while guardian 0 (an approver) has no compact leaf left: it approves with its SPX key.
  D  transfer g1+g2 with guardian 2's fresh slot.
Writes research/results/slot_refresh_e2e.json (every tx: label, hash, block, status, signature kinds, gas, and
each guardian's slot number / remaining leaves after the step).
"""
import argparse
import json
import os
import time

from pqv import devnet as dv
from pqv import rpc
from pqv.hashing import ROOT

FILE, PREFIX, LABEL = "small-guardians.json", "small-guardian", "smallVault"
OUT = os.path.join(ROOT, "research", "results", "slot_refresh_e2e.json")


def snapshot(gs):
    return [{"guardian": g.i, "slotNumber": len(g.rec["slots"]), "slotId": dv.h(g.slot().slot_id)[:12],
             "qMax": g.slot().q_max, "remaining": g.remaining_leaves()} for g in gs]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("network", choices=["local", "public"])
    a = ap.parse_args(argv)
    net = dv.Net(a.network)
    if not net.load(FILE):
        dv.new_guardians(net, slot_h=2, file=FILE)
    gs = dv.guardians(net, FILE, PREFIX)
    if not net.deployment.get(LABEL):
        dv.deploy_vault(net, 1.0, 0.02, label=LABEL, gs=gs)
    to = net.deployer()
    log = []

    def step(phase, fn):
        before = len(net.load("receipts.json", []))
        fn()
        new = net.load("receipts.json", [])[before:]
        entry = {"phase": phase,
                 "txs": [{"label": r["label"], "txHash": r["txHash"], "block": r["block"], "status": r["status"],
                          "guardians": r.get("guardians"), "kinds": r.get("kinds"), "gasUsed": r["gasUsed"]}
                         for r in new],
                 "after": snapshot(gs)}
        log.append(entry)
        print(json.dumps(entry))
        return entry

    print("start:", json.dumps(snapshot(gs)))
    for k in range(1, 6):
        step(f"A{k}: transfer g0+g1, refresh on",
             lambda k=k: dv.cmd_transfer(net, to, 1, (0, 1), (), label=f"slot-refresh A{k}: transfer",
                                         vault_label=LABEL, gs=gs))
    for k in range(1, 7):
        e = step(f"B{k}: transfer g0+g2, refresh off",
                 lambda k=k: dv.cmd_transfer(net, to, 1, (0, 2), (), label=f"slot-refresh B{k}: transfer",
                                             vault_label=LABEL, rotate_at=0, gs=gs))
        if e["txs"][-1]["kinds"] == ["stateless", "stateless"]:
            break
    step("C: rotate guardian 2 (approver g0 has no compact leaf)",
         lambda: dv.cmd_rotate(net, 2, gs=gs, vault_label=LABEL))
    step("D: transfer g1+g2 with g2's fresh slot",
         lambda: dv.cmd_transfer(net, to, 1, (1, 2), (), label="slot-refresh D: transfer", vault_label=LABEL, gs=gs))

    txs = [t for e in log for t in e["txs"]]
    result = {"network": net.name, "chainId": int(rpc.eth("eth_chainId"), 16), "client": rpc.eth("web3_clientVersion"),
              "vault": net.deployment[LABEL], "slotLeaves": 4, "generated": int(time.time()),
              "summary": {"transactions": len(txs), "allSucceeded": all(t["status"] == "0x1" for t in txs),
                          "rotations": sum("rotate guardian" in t["label"] for t in txs),
                          "statelessApprovals": sum(k == "stateless" for t in txs for k in (t["kinds"] or []))},
              "steps": log}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(result, open(OUT, "w"), indent=1)
    print("wrote", OUT, json.dumps(result["summary"]))


if __name__ == "__main__":
    main()
