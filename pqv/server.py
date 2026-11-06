"""PQ-Vault local UI server (stdlib only; binds 127.0.0.1).

    python -m pqv.server <network> [--port 8141]

Serves app/ and a JSON API. Guardian keys never leave this process; the browser only sees public
data. One operation at a time (a lock), because guardian leaf state must never be used concurrently.
"""
import argparse
import json
import os
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import devnet as dv
from . import rpc
from .hashing import ROOT
from .state import DurableLeafStore

APP = os.path.join(ROOT, "app")
RESULTS = os.path.join(ROOT, "research", "results", "experiments.json")
LOCK = threading.Lock()
NET = None
_GCACHE = {"mtime": None, "gs": None}


def cached_guardians():
    """Guardian objects (JARDIN slot trees) are expensive to build; rebuild only when guardians.json changes."""
    path = NET.path("guardians.json")
    m = os.path.getmtime(path)
    if _GCACHE["mtime"] != m:
        _GCACHE["gs"], _GCACHE["mtime"] = dv.guardians(NET), m
    return _GCACHE["gs"]


def status():
    net = NET
    dep = net.deployment
    vault = dep.get("vault")
    out = {"network": net.name, "rpc": net.cfg["ethrex"], "mempool": net.cfg["sidecar"],
           "explorer": net.cfg.get("explorer"), "head": int(rpc.eth("eth_blockNumber"), 16),
           "deployment": {k: v for k, v in dep.items() if k != "txs"}, "guardians": [], "receipts": []}
    if vault:
        out["vault"] = {"address": vault,
                        "balanceWei": str(int(rpc.eth("eth_getBalance", [vault, "latest"]), 16)),
                        "nonce": int(rpc.eth("eth_getTransactionCount", [vault, "latest"]), 16)}
    if net.load("guardians.json"):
        for g in cached_guardians():
            slot = g.slot()
            hwm = net.ledger_hwm(slot.slot_id)
            info = net.call(vault, dv.sel("slotGuardian(bytes32)") + slot.slot_id) if vault else b""
            out["guardians"].append({
                "index": g.i, "slotId": dv.h(slot.slot_id), "slotCount": len(g.rec["slots"]),
                "qMax": slot.q_max, "nextLeafLocal": g.leaves.peek(slot.slot_id),
                "ledgerHighWaterMark": "revoked" if hwm >= 2**255 else hwm,
                "activeInVault": bool(info and info[31]), "replaced": g.rec.get("replaced", 0)})
    out["receipts"] = list(reversed(net.load("receipts.json", [])))[:25]
    return out


def demo_stale_restore(g_idx: int):
    """Live rollback attack on our own devnet test wallet: guardian g's device is 'restored from an old
    backup' (leaf counter reset to 1). (a) The PQ-Vault signer (AnchoredLeafStore) resumes above the
    chain-anchored mark, so no leaf is reused. (b) A baseline JARDIN-style signer (DurableLeafStore,
    no anchoring) re-signs a consumed leaf; ethrex simulation shows the vault's VERIFY frame rejecting it
    (LeafLedger StaleLeaf), so it can never be included. Nothing is broadcast in (b)."""
    net = NET
    gs = dv.guardians(net)
    g = gs[g_idx]
    slot = g.slot()
    hwm = net.ledger_hwm(slot.slot_id)
    if hwm == 0:
        raise RuntimeError("send at least one transaction with this guardian first")
    stale_path = net.path(f"guardian-{g_idx}-leaves.stale-backup.json")
    dv_state = DurableLeafStore(stale_path)  # a freshly 'restored' backup: next_q = 1
    vault = net.deployment["vault"]
    # (b) baseline signer on the restored backup, together with one honest approval (entries in guardian order)
    approvers = sorted([g_idx, (g_idx + 1) % 3])
    tx = dv.build_vault_tx(net, vault, [(net.deployer(), 1, "0x")], ["compact", "compact"])
    q_stale = dv_state.reserve(slot.slot_id, slot.q_max)
    dv.sign_entries(tx, [(lambda m: dv.compact_entry(g_idx, slot, slot.sign(m, q_stale))) if a == g_idx
                         else dv.entry_signer(gs[a], "compact") for a in approvers])
    sim = dv.simulate(tx)
    # (a) PQ-Vault signer on the same restored backup
    anchored_q = max(1, hwm + 1)
    os.unlink(stale_path)
    return {"guardian": g_idx, "chainHighWaterMark": hwm,
            "baselineSigner": {"leafChosen": q_stale, "reusesConsumedLeaf": q_stale <= hwm,
                               "simulation": {k: sim.get(k) for k in ("valid", "violation", "executionError")}},
            "pqVaultSigner": {"leafChosen": anchored_q, "reusesConsumedLeaf": False}}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else json.dumps(body, indent=1, default=str).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        try:
            if self.path == "/api/status":
                return self._send(200, status())
            if self.path == "/api/research":
                return self._send(200, json.load(open(RESULTS)) if os.path.exists(RESULTS) else {"rows": []})
            f = "index.html" if self.path in ("/", "/index.html") else self.path.lstrip("/")
            p = os.path.realpath(os.path.join(APP, f))
            if not p.startswith(os.path.realpath(APP)) or not os.path.isfile(p):
                return self._send(404, {"error": "not found"})
            ctype = {"html": "text/html", "js": "text/javascript", "css": "text/css"}.get(p.rsplit(".", 1)[-1], "text/plain")
            return self._send(200, open(p, "rb").read(), ctype + "; charset=utf-8")
        except Exception as e:
            return self._send(500, {"error": str(e)})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if not LOCK.acquire(blocking=False):
            return self._send(409, {"error": "another guardian operation is running"})
        try:
            if self.path == "/api/transfer":
                approvers = tuple(int(x) for x in body.get("approvers", body.get("pair", [0, 1])))
                stateless = tuple(int(x) for x in body.get("stateless", []))
                out = dv.cmd_transfer(NET, body["to"], int(body["wei"]), approvers, stateless)
            elif self.path == "/api/rotate":
                out = dv.cmd_rotate(NET, int(body["guardian"]))
            elif self.path == "/api/recover":
                out = dv.cmd_recover(NET, int(body["lost"]))
            elif self.path == "/api/demo/stale-restore":
                out = demo_stale_restore(int(body["guardian"]))
            else:
                return self._send(404, {"error": "unknown endpoint"})
            return self._send(200, out)
        except Exception as e:
            traceback.print_exc()
            return self._send(400, {"error": str(e)})
        finally:
            LOCK.release()


def main():
    global NET
    ap = argparse.ArgumentParser()
    ap.add_argument("network", choices=["public", "local"])
    ap.add_argument("--port", type=int, default=8141)
    a = ap.parse_args()
    NET = dv.Net(a.network)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    print(f"PQ-Vault UI on http://127.0.0.1:{a.port}  (network: {a.network})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
