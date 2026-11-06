"""A personal PQ-Vault wallet (MetaMask-style), one per process, for demos with several users.

    python -m pqv.wallet <name> [--port 8201] [--network local]
    infra/wallets.sh start alice bob carol      # several wallets, one port each

Each wallet is its own account: a 2-of-3 PQ-Vault smart account whose three JARDIN keys live on this computer
(.devnet/<network>/wallets/<name>/). It shares the network's contracts (factory, LeafLedger, verifiers) with every
other wallet. The browser page only sees public data; signing happens in this process. Test ETH comes from the
throwaway devnet deployer (the only ECDSA key in the project), which also pays for deploying the account.

    GET  /api/state               account, balance, network connection, keys, contacts
    GET  /api/activity            received and sent ETH (EIP-7708 transfer logs), newest first
    GET  /api/quote               fee estimate and the most that can be sent
    POST /api/create              create this wallet's account (keys + smart account + test ETH)  -> {job}
    POST /api/faucet              1 test ETH from the devnet faucet                                 -> {job}
    POST /api/send {to, wei}      pay, signed by the two keys with the most leaves left             -> {job}
    POST /api/network {ethrex, sidecar}   connect to another node / mempool
    GET  /api/jobs/<id>

Shared 2-of-3 multisig vaults with other wallets (pqv/multisig.py):
    POST /api/vaults {name, guardians: [two other wallet names]}       create; invites the other two
    GET  /api/vaults/<id>                                             detail, proposals, activity
    POST /api/vaults/<id>/join                                        accept an invitation (makes this wallet's key)
    POST /api/vaults/<id>/deploy                                      once all three joined          -> {job}
    POST /api/vaults/<id>/propose {to, wei}                           propose + approve a payment
    POST /api/vaults/<id>/proposals/<pid>/approve                     second approval submits it     -> {job}
"""
import argparse
import contextlib
import fcntl
import glob
import json
import os
import re
import shutil
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import devnet as dv
from . import multisig as ms
from . import rpc
from . import server as srv
from .hashing import ROOT, keccak256

APP = os.path.join(ROOT, "app", "wallet")
ADDR = re.compile(r"^0x[0-9a-fA-F]{40}$")
EIP7708 = "0xfffffffffffffffffffffffffffffffffffffffe"  # ethrex emits a Transfer log here for every ETH move
TRANSFER = "0x" + keccak256(b"Transfer(address,address,uint256)").hex()
INFRA = ("staking", "frameOps", "forsVerifier", "spxVerifier", "factory", "ledger")
FAUCET_WEI = 10**18
CREATE_FUND_ETH, CREATE_STAKE_ETH = 1.0, 0.02
EST_GAS = 380_000              # billed gas of a compact+compact transfer (docs/RECEIPTS-local.md)
MAX_COST_RESERVE = 5 * 10**15  # the account must hold value + the tx's maximum cost when payment is approved
W = None


class WalletNet(dv.Net):
    """dv.Net whose files live in wallets/<name>/, on top of the network's shared contracts."""

    def __init__(self, network: str, name: str):
        super().__init__(network)
        self.shared_dir, self.wallet = self.dir, name
        self.dir = os.path.join(self.shared_dir, "wallets", name)
        os.makedirs(self.dir, exist_ok=True)
        own = self.load("network.json")
        if own:
            self.cfg.update(own)
        rpc.ETHREX_URL, rpc.SIDECAR_URL = self.cfg["ethrex"], self.cfg["sidecar"]

    @property
    def deployment(self):
        p = os.path.join(self.shared_dir, "deployment.json")
        shared = json.load(open(p)) if os.path.exists(p) else {}
        return {**self.load("deployment.json", {}), **{k: shared[k] for k in INFRA if k in shared}}


@contextlib.contextmanager
def deployer_lock():
    """Several wallet processes share the devnet deployer key: serialise its transactions (nonces)."""
    with open(os.path.join(dv.DEVNET_DIR, "deployer.lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


# ----------------------------------------------------------------------------- state
def account():
    """The account address if it exists on the connected chain, else None."""
    a = W.deployment.get("vault")
    if not a:
        return None
    try:
        return a if rpc.eth("eth_getCode", [a, "latest"]) not in ("0x", "0x0", None) else None
    except Exception:
        return None


def _guardians():
    return dv.guardians(W) if W.load("guardians.json") else []


def contacts():
    out = [{"name": v["name"], "address": v["address"], "vault": True} for v in ms.all_vaults(W) if v.get("address")]
    for p in sorted(glob.glob(os.path.join(W.shared_dir, "wallets", "*", "deployment.json"))):
        name = os.path.basename(os.path.dirname(p))
        if name == W.wallet:
            continue
        v = json.load(open(p)).get("vault")
        if v:
            out.append({"name": name, "address": v})
    return out


def vault_summary(v):
    me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
    out = {"id": v["id"], "name": v["name"], "status": v["status"], "address": v.get("address"), "creator": v["creator"],
           "members": [{"wallet": m["wallet"], "index": m["index"], "joined": bool(m["pub"]), "me": m["wallet"] == W.wallet}
                       for m in v["members"]],
           "invited": bool(me and not me["pub"]), "balanceWei": None, "pending": 0, "awaitingMe": 0}
    if v.get("address"):
        out["balanceWei"] = str(int(rpc.eth("eth_getBalance", [v["address"], "latest"]), 16))
        ms.expire_stale(W, v)
        for p in ms.proposals(W, v["id"]):
            if p["status"] in ("pending", "ready"):
                out["pending"] += 1
                if me and str(me["index"]) not in p["approvals"]:
                    out["awaitingMe"] += 1
    return out


def my_vaults():
    return [vault_summary(v) for v in ms.all_vaults(W) if any(m["wallet"] == W.wallet for m in v["members"])]


def vault_detail(vid):
    v = ms.load_vault(W, vid)
    out = vault_summary(v)
    me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
    out["myIndex"] = me["index"] if me else None
    out["proposals"] = [{k: p.get(k) for k in ("id", "proposer", "to", "wei", "status", "txHash", "block", "error",
                                                 "created", "submitter", "kinds")}
                        | {"approvals": [{"index": int(i), "wallet": a["wallet"], "kind": a["kind"]}
                                         for i, a in sorted(p["approvals"].items())]}
                        for p in ms.proposals(W, vid)]
    out["activity"] = activity(v["address"], v.get("createdBlock", 0)) if v.get("address") else []
    g = ms.my_guardian(W, v) if v.get("address") else None
    out["myKey"] = {"remaining": g.remaining_leaves(), "leaves": g.slot().q_max} if g else None
    return out


def state():
    out = {"name": W.wallet, "network": {"rpc": W.cfg["ethrex"], "mempool": W.cfg["sidecar"], "connected": False},
           "account": None, "keys": [], "contacts": contacts(), "rotateAt": dv.ROTATE_AT}
    try:
        out["network"].update({"chainId": int(rpc.eth("eth_chainId"), 16), "block": int(rpc.eth("eth_blockNumber"), 16),
                               "connected": True, "infra": bool(W.deployment.get("factory"))})
    except Exception as e:
        out["network"]["error"] = str(e)[:200]
        return out
    out["vaults"] = my_vaults()
    out["wallets"] = sorted(os.path.basename(d) for d in glob.glob(os.path.join(W.shared_dir, "wallets", "*"))
                            if os.path.isdir(d) and os.path.basename(d) != W.wallet)
    a = account()
    if a:
        out["account"] = {"address": a, "balanceWei": str(int(rpc.eth("eth_getBalance", [a, "latest"]), 16))}
        for g in _guardians():
            s = g.slot()
            out["keys"].append({"index": g.i, "leaves": s.q_max, "remaining": g.remaining_leaves(),
                                "renewals": len(g.rec["slots"]) - 1})
    elif W.deployment.get("vault"):
        out["staleAccount"] = W.deployment["vault"]  # created on a network that is gone (fresh chain)
    return out


def _names():
    n = {c["address"].lower(): c["name"] for c in contacts()}
    try:
        n[W.deployer().lower()] = "Test ETH faucet"
    except Exception:
        pass
    d = W.deployment
    for k, label in (("factory", "Account setup"), ("staking", "Mempool stake")):
        if d.get(k):
            n[d[k].lower()] = label
    if account():
        n[account().lower()] = W.wallet
    return n


def activity(a=None, created=None):
    a = a or account()
    if not a:
        return []
    pad = "0x" + "0" * 24 + a[2:].lower()
    start = hex(W.deployment.get("createdBlock", 0) if created is None else created)
    names, rows = _names(), []
    for direction, topics in (("in", [TRANSFER, None, pad]), ("out", [TRANSFER, pad])):
        for l in rpc.eth("eth_getLogs", [{"fromBlock": start, "toBlock": "latest", "address": EIP7708, "topics": topics}]):
            other = "0x" + l["topics"][2 if direction == "out" else 1][-40:]
            rows.append({"direction": direction, "counterparty": other, "name": names.get(other.lower()),
                         "wei": str(int(l["data"], 16)), "block": int(l["blockNumber"], 16), "txHash": l["transactionHash"]})
    rows.sort(key=lambda r: (-r["block"], r["direction"]))
    return rows


def quote():
    a = account()
    base = int(rpc.eth("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
    fee = EST_GAS * (base + 10**9)
    bal = int(rpc.eth("eth_getBalance", [a, "latest"]), 16) if a else 0
    return {"feeWei": str(fee), "maxSendWei": str(max(0, bal - MAX_COST_RESERVE))}


# ----------------------------------------------------------------------------- operations (background jobs)
def op_create():
    if account():
        raise RuntimeError("this wallet already has an account")
    if not W.deployment.get("factory"):
        raise RuntimeError("the network has no PQ-Vault contracts yet: run infra/local-net.sh up first")
    if W.load("guardians.json"):  # keys of an account on a network that no longer exists
        old = os.path.join(W.dir, f"archive-{int(time.time())}")
        os.makedirs(old)
        for f in os.listdir(W.dir):
            if f.endswith(".json") and f != "network.json":
                shutil.move(os.path.join(W.dir, f), old)
    print("keys: generating three post-quantum keys on this computer")
    dv.new_guardians(W)
    print("account: deploying your smart account (2 of 3 keys sign)")
    with deployer_lock():
        dv.deploy_vault(W, CREATE_FUND_ETH, CREATE_STAKE_ETH)
    dep = W.load("deployment.json")
    rc = rpc.eth("eth_getTransactionReceipt", [dep["txs"]["vault"]])
    dep["createdBlock"] = int(rc["blockNumber"], 16)
    W.save("deployment.json", dep)
    print(f"done: account {dep['vault']} with {CREATE_FUND_ETH} test ETH")
    return {"txHash": dep["txs"]["vault"], "receipt": rc}


def op_faucet():
    a = account()
    if not a:
        raise RuntimeError("create the account first")
    print("faucet: requesting 1 test ETH")
    with deployer_lock():
        r = json.loads(dv.cast("send", "--private-key", W.deployer_key(), "--rpc-url", W.cfg["ethrex"], "--legacy",
                               "--gas-price", str(W.gas_price()), "--json", "--value", str(FAUCET_WEI), a))
    if r.get("status") not in ("0x1", 1, "1"):
        raise RuntimeError(f"faucet transaction {r.get('transactionHash')} failed")
    print(f"faucet: tx {r['transactionHash']} status 0x1 block {int(r['blockNumber'], 16)} gasUsed {int(r['gasUsed'], 16)}")
    return {"txHash": r["transactionHash"], "receipt": r}


def op_send(to, wei):
    gs = _guardians()
    # the two keys with the most leaves left sign (ties: lower index); renewal/fallback are handled by the driver
    pick = sorted(sorted(gs, key=lambda g: (-g.remaining_leaves(), g.i))[:2], key=lambda g: g.i)
    return dv.cmd_transfer(W, to, wei, tuple(g.i for g in pick), gs=gs, label=f"send to {to}")


# ----------------------------------------------------------------------------- HTTP
class H(srv.H):
    def do_GET(self):
        try:
            if self.path == "/api/state":
                return self._send(200, state())
            if self.path == "/api/activity":
                return self._send(200, activity())
            if self.path == "/api/quote":
                return self._send(200, quote())
            m = re.match(r"^/api/vaults/([0-9a-f]{10})$", self.path)
            if m:
                return self._send(200, vault_detail(m[1]))
            if self.path.startswith("/api/jobs/"):
                job = srv.JOBS.get(self.path.rsplit("/", 1)[-1])
                return self._send(200, job) if job else self._send(404, {"error": "unknown job"})
            f = "index.html" if self.path in ("/", "/index.html") else self.path.split("?")[0].lstrip("/")
            p = os.path.realpath(os.path.join(APP, f))
            if not p.startswith(os.path.realpath(APP)) or not os.path.isfile(p):
                return self._send(404, {"error": "not found"})
            ctype = {"html": "text/html", "js": "text/javascript", "css": "text/css", "svg": "image/svg+xml"}.get(
                p.rsplit(".", 1)[-1], "text/plain")
            return self._send(200, open(p, "rb").read(), ctype + "; charset=utf-8")
        except Exception as e:
            return self._send(500, {"error": srv._friendly(e)})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/api/create":
                job = srv.start_job("create", op_create)
            elif self.path == "/api/faucet":
                job = srv.start_job("faucet", op_faucet)
            elif self.path == "/api/send":
                to, wei = str(body.get("to", "")).strip(), int(body.get("wei", 0))
                if not ADDR.match(to):
                    return self._send(400, {"error": "Enter a 0x address with 40 hex characters."})
                if to.lower() == (account() or "").lower():
                    return self._send(400, {"error": "That is this wallet's own address."})
                if wei <= 0:
                    return self._send(400, {"error": "Enter an amount above zero."})
                if wei > int(quote()["maxSendWei"]):
                    return self._send(400, {"error": "Not enough ETH for this amount plus the network fee."})
                job = srv.start_job("send", lambda: op_send(to, wei))
            elif self.path == "/api/vaults":
                return self._send(200, ms.create(W, body.get("name", ""), body.get("guardians", [])))
            elif re.match(r"^/api/vaults/[0-9a-f]{10}/", self.path):
                parts = self.path.split("/")
                vid, action = parts[3], parts[4]
                if action == "join":
                    return self._send(200, ms.join(W, vid))
                if action == "deploy":
                    job = srv.start_job("vault-deploy", lambda: ms.deploy(W, vid, deployer_lock))
                elif action == "propose":
                    to, wei = str(body.get("to", "")).strip(), int(body.get("wei", 0))
                    v = ms.load_vault(W, vid)
                    if not ADDR.match(to):
                        return self._send(400, {"error": "Enter a 0x address with 40 hex characters."})
                    if to.lower() == (v.get("address") or "").lower():
                        return self._send(400, {"error": "That is the vault's own address."})
                    bal = int(rpc.eth("eth_getBalance", [v["address"], "latest"]), 16) if v.get("address") else 0
                    if wei <= 0 or wei > bal - MAX_COST_RESERVE:
                        return self._send(400, {"error": "Enter an amount the vault can cover, leaving 0.005 ETH for the fee."})
                    p = ms.propose(W, vid, to, wei)
                    return self._send(200, {"proposal": p["id"]})
                elif action == "proposals" and len(parts) == 7 and parts[6] == "approve":
                    pid = parts[5]
                    if not pid.isalnum():
                        return self._send(400, {"error": "bad proposal id"})
                    p, ready = ms.approve(W, vid, pid)
                    if not ready:
                        return self._send(200, {"approvals": len(p["approvals"])})
                    job = srv.start_job("vault-payment", lambda: ms.submit(W, vid, pid))
                elif action == "proposals" and len(parts) == 7 and parts[6] == "submit":
                    pid = parts[5]
                    if not pid.isalnum():
                        return self._send(400, {"error": "bad proposal id"})
                    job = srv.start_job("vault-payment", lambda: ms.submit(W, vid, pid))
                else:
                    return self._send(404, {"error": "unknown endpoint"})
            elif self.path == "/api/network":
                ethrex, sidecar = str(body.get("ethrex", "")).strip(), str(body.get("sidecar", "")).strip()
                if not ethrex.startswith("http") or not sidecar.startswith("http"):
                    return self._send(400, {"error": "Enter both URLs, starting with http:// or https://."})
                old = (rpc.ETHREX_URL, rpc.SIDECAR_URL)
                rpc.ETHREX_URL, rpc.SIDECAR_URL = ethrex, sidecar
                try:
                    chain = int(rpc.eth("eth_chainId"), 16)
                except Exception as e:
                    rpc.ETHREX_URL, rpc.SIDECAR_URL = old
                    return self._send(400, {"error": f"No node answered at {ethrex}: {str(e)[:120]}"})
                W.cfg.update({"ethrex": ethrex, "sidecar": sidecar})
                W.save("network.json", {"ethrex": ethrex, "sidecar": sidecar})
                return self._send(200, {"chainId": chain})
            else:
                return self._send(404, {"error": "unknown endpoint"})
            return self._send(202, {"job": job["id"]})
        except BlockingIOError:
            return self._send(409, {"error": "The wallet is busy with another action; wait for it to finish."})
        except Exception as e:
            return self._send(400, {"error": srv._friendly(e)})


def main():
    global W
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="wallet name (lowercase letters, digits, dashes)")
    ap.add_argument("--port", type=int, default=8201)
    ap.add_argument("--network", default="local", choices=["local", "public"])
    a = ap.parse_args()
    if not re.match(r"^[a-z0-9][a-z0-9-]{0,23}$", a.name):
        raise SystemExit("wallet name: lowercase letters, digits and dashes, up to 24 characters")
    W = WalletNet(a.network, a.name)
    httpd = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    print(f"{a.name}'s PQ-Vault wallet on http://127.0.0.1:{a.port}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
