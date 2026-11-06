#!/usr/bin/env python3
"""Real-process crash experiment (S1/S4: crashes and interrupted signing).

A child process signs messages in a loop with a real JARDIN compact slot and a file-backed leaf
counter, appending every *released* signature (leaf q, message) to a release log the moment it is
produced (what an attacker on the wire sees). The parent SIGKILLs the child at random moments and
restarts it, many times. Afterwards we count leaves that released two different messages.

    python3 research/crash_test.py [--kills 200]

Policies: `naive` (sign, release, then write the counter without fsync), `naive_fsync` (sign,
release, then write+fsync), `burn` (write+fsync q+1 BEFORE signing: JARDIN / NIST SP 800-208).
Modes: `random` (SIGKILL at a random moment while signing) and `targeted` (the process is killed the
instant a signature has been released - fault injection at the worst point).
Limitation: SIGKILL loses process state but not the OS page cache, so this measures process crashes
and interrupted signing, not power loss (where unsynced writes are also lost - modelled in sim.py).
"""
import argparse
import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def child(policy: str, state_path: str, log_path: str, announce: str = "0"):
    sys.path.insert(0, ROOT)
    from pqv.hashing import keccak256
    from pqv.jardin import CompactSlot
    from pqv.state import atomic_write_json

    slots = {}

    def slot_for(k):
        if k not in slots:
            slots[k] = CompactSlot(keccak256(b"crash-test-master"), keccak256(b"crash-test-slot-%d" % k), 7)
        return slots[k]

    def read_state():
        try:
            with open(state_path) as f:
                st = json.load(f)
            return st["slot"], st["next_q"]
        except (FileNotFoundError, ValueError, KeyError):
            return 0, 1  # missing/torn state: start over (what a naive implementation does)

    log = open(log_path, "a", buffering=1)
    slot_for(read_state()[0])  # key generation first, so kills land in the signing loop
    print("ready", flush=True)
    while True:
        k, q = read_state()
        slot = slot_for(k)
        if q > slot.q_max:  # exhausted: rotate to the next slot (fresh r)
            atomic_write_json(state_path, {"slot": k + 1, "next_q": 1})
            continue
        if policy == "burn":
            atomic_write_json(state_path, {"slot": k, "next_q": q + 1})
        msg = os.urandom(32)
        sig = slot.sign(msg, q)
        log.write(json.dumps({"k": k, "q": q, "m": msg.hex(), "len": len(sig)}) + "\n")  # released
        if announce == "1":
            # Fault injection at the worst moment: power is cut right after the signature has left the
            # device and before anything else runs (deterministic version of "kill on release").
            os.kill(os.getpid(), signal.SIGKILL)
        if policy == "naive":
            with open(state_path, "w") as f:  # non-atomic, no fsync
                f.write(json.dumps({"slot": k, "next_q": q + 1}))
        elif policy == "naive_fsync":
            atomic_write_json(state_path, {"slot": k, "next_q": q + 1})


def run(policy: str, kills: int, seed: int, targeted: bool):
    rng = random.Random(seed)
    raw = os.path.join(ROOT, "research", "results", "raw")  # gitignored
    os.makedirs(raw, exist_ok=True)
    d = tempfile.mkdtemp(prefix=f"crash-{policy}-{'targeted' if targeted else 'random'}-", dir=raw)
    state, log = os.path.join(d, "state.json"), os.path.join(d, "released.jsonl")
    t0 = time.time()
    for _ in range(kills):
        p = subprocess.Popen([sys.executable, __file__, "--child", policy, state, log, "1" if targeted else "0"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p.stdout.readline()  # wait for "ready" (slot keygen done)
        if targeted:
            try:
                p.wait(timeout=30)  # the child kills itself right after its first release
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        else:
            time.sleep(rng.uniform(0.0, 0.05))  # natural crash at a random moment while signing
            p.send_signal(signal.SIGKILL)
            p.wait()
    per_leaf = {}
    n = 0
    with open(log) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue  # torn last line
            n += 1
            per_leaf.setdefault((r["k"], r["q"]), set()).add(r["m"])
    gam = [len(v) for v in per_leaf.values()]
    return {"policy": policy, "mode": "targeted" if targeted else "random", "kills": kills, "released_signatures": n, "leaves_used": len(per_leaf),
            "reused_leaves": sum(1 for g in gam if g >= 2), "max_gamma": max(gam, default=0),
            "runtime_s": round(time.time() - t0, 1)}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        return child(*sys.argv[2:6])  # policy, state, log, announce
    ap = argparse.ArgumentParser()
    ap.add_argument("--kills", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    res = [run(p, a.kills, a.seed, t) for t in (False, True) for p in ("naive", "naive_fsync", "burn")]
    out = os.path.join(ROOT, "research", "results", "crash_test.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(res, open(out, "w"), indent=1)
    for r in res:
        print(r)


if __name__ == "__main__":
    main()
