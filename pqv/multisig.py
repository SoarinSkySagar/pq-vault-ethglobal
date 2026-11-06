"""Shared 2-of-3 PQ multisig vaults between personal wallets (pqv.wallet).

A wallet can create a vault with two other wallets as co-guardians. Each guardian wallet holds its own dedicated
JARDIN guardian key for that vault (master SPX key + a 128-leaf compact slot) in its own directory; only the public
halves are shared. Payments are proposals: the proposer fixes the exact frame transaction and approves it; when a
second guardian approves (in their own wallet), that wallet assembles the two signature entries in guardian order and
submits the three-frame transaction (VERIFY guardian A, VERIFY guardian B, SENDER).

Coordination between wallet processes goes through a shared folder, .devnet/<net>/vaults/<id>/ (vault.json,
proposals/<id>.json), under a file lock: a local stand-in for the message relay a deployment would need. It only
ever holds public keys, unsigned transactions and signatures, never a secret key.

Both VERIFY frames are sized for a stateless (SPX) approval, so any guardian can approve with either kind and the
transaction (whose signature hash commits to the frame gas limits) can be fixed before anyone signs.
"""
import contextlib
import fcntl
import json
import os
import time
import uuid

from . import devnet as dv
from . import frametx as ft
from . import rpc
from .hashing import keccak256
from .jardin import CompactSlot, GuardianKeys, compact_entry, stateless_entry, vault_message

SLOT_H = 7
FUND_ETH, STAKE_ETH = 0.5, 0.02


# ----------------------------------------------------------------------------- shared store
def root(W):
    p = os.path.join(W.shared_dir, "vaults")
    os.makedirs(p, exist_ok=True)
    return p


def vdir(W, vid):
    if not vid.isalnum():
        raise ValueError("bad vault id")
    return os.path.join(root(W), vid)


@contextlib.contextmanager
def locked(W, vid):
    d = vdir(W, vid)
    os.makedirs(os.path.join(d, "proposals"), exist_ok=True)
    with open(os.path.join(d, ".lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield d
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _read(p, default=None):
    return json.load(open(p)) if os.path.exists(p) else default


def _write(p, obj):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, p)


def load_vault(W, vid):
    v = _read(os.path.join(vdir(W, vid), "vault.json"))
    if not v:
        raise ValueError("unknown vault")
    return v


def all_vaults(W):
    out = []
    for vid in sorted(os.listdir(root(W))):
        v = _read(os.path.join(root(W), vid, "vault.json"))
        if v:
            out.append(v)
    return out


# ----------------------------------------------------------------------------- this wallet's guardian keys
def _keyfile(W, vid):
    return f"vault-keys/{vid}.json"


def my_guardian(W, v):
    """dv.Guardian for this wallet's key in vault v (index = its position in the vault), or None."""
    me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
    rec = W.load(_keyfile(W, v["id"])) if me else None
    if not rec:
        return None
    rec = dict(rec, index=me["index"])
    return dv.Guardian(W, rec, prefix=f"vault-{v['id']}", anchored=True, file=_keyfile(W, v["id"]))


def _new_key(W, vid, index):
    os.makedirs(os.path.join(W.dir, "vault-keys"), exist_ok=True)
    master, r = os.urandom(32), os.urandom(32)
    rec = {"index": index, "master_sk": dv.h(master), "slots": [{"r": dv.h(r), "h": SLOT_H}]}
    W.save(_keyfile(W, vid), rec)
    spx = GuardianKeys(index, master).spx()
    slot = CompactSlot(master, r, SLOT_H)
    return {"spxSeed": dv.h(spx.public[0]), "spxRoot": dv.h(spx.public[1]),
            "slotSeed": dv.h(slot.seed16), "slotRoot": dv.h(slot.root16)}


# ----------------------------------------------------------------------------- lifecycle
def create(W, name, co_guardians):
    name = " ".join(str(name).split())[:40]
    co = [str(c) for c in co_guardians]
    if not name:
        raise ValueError("Give the vault a name.")
    if len(set(co)) != 2 or W.wallet in co:
        raise ValueError("Choose two other wallets as co-guardians.")
    for c in co:
        if not os.path.isdir(os.path.join(W.shared_dir, "wallets", c)):
            raise ValueError(f"There is no wallet called {c} on this computer.")
    vid = uuid.uuid4().hex[:10]
    with locked(W, vid) as d:
        members = [{"wallet": W.wallet, "index": 0, "pub": None}] + [{"wallet": c, "index": i + 1, "pub": None}
                                                                    for i, c in enumerate(co)]
        v = {"id": vid, "name": name, "creator": W.wallet, "threshold": 2, "members": members,
             "address": None, "status": "inviting", "created": int(time.time())}
        v["members"][0]["pub"] = _new_key(W, vid, 0)
        _write(os.path.join(d, "vault.json"), v)
    return v


def join(W, vid):
    with locked(W, vid) as d:
        v = load_vault(W, vid)
        me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
        if not me:
            raise ValueError("This wallet is not invited to that vault.")
        if v["status"] != "inviting":
            raise ValueError("That vault is already set up.")
        if not me["pub"]:
            me["pub"] = _new_key(W, vid, me["index"])
            _write(os.path.join(d, "vault.json"), v)
    return v


def deploy(W, vid, deployer_lock):
    """Deploy the vault (the devnet deployer pays the 0.02 ETH mempool stake and seeds 0.5 test ETH)."""
    with locked(W, vid) as d:
        v = load_vault(W, vid)
        if v["status"] != "inviting":
            raise ValueError("That vault is already deployed or being deployed.")
        if not all(m["pub"] for m in v["members"]):
            raise ValueError("Wait until all three guardians have accepted.")
        v["status"] = "deploying"
        _write(os.path.join(d, "vault.json"), v)
    try:
        ms = sorted(v["members"], key=lambda m: m["index"])
        g_tuple = ",".join(f"({m['pub']['spxSeed']},{m['pub']['spxRoot']})" for m in ms)
        seeds = ",".join(m["pub"]["slotSeed"] for m in ms)
        roots = ",".join(m["pub"]["slotRoot"] for m in ms)
        init = f"([{g_tuple}],[{seeds}],[{roots}],{dv.MAX_TX_COST_WEI},0)"
        stake = int(STAKE_ETH * 10**18)
        value = int(FUND_ETH * 10**18) + stake
        data = dv.cast("calldata", "deploy(bytes32,((bytes32,bytes32)[3],bytes16[3],bytes16[3],uint256,uint32),bool,uint256)",
                       dv.h(os.urandom(32)), init, "true", str(stake))
        dep = W.deployment
        print(f"vault: deploying '{v['name']}' (2 of 3: {', '.join(m['wallet'] for m in ms)})")
        with deployer_lock():
            est = int(rpc.eth("eth_estimateGas", [{"from": W.deployer(), "to": dep["factory"], "data": data,
                                                   "value": hex(value)}]), 16)
            r = W.send_legacy(dep["factory"], data, value, gas=int(est * 1.3))
        topic = "0x" + keccak256(b"VaultDeployed(address,bytes32,bool)").hex()
        addr = next("0x" + l["topics"][1][-40:] for l in r["logs"] if l["topics"][0] == topic)
    except Exception:
        with locked(W, vid) as d:
            v = load_vault(W, vid)
            v["status"] = "inviting"
            _write(os.path.join(d, "vault.json"), v)
        raise
    with locked(W, vid) as d:
        v = load_vault(W, vid)
        v.update(address=addr, status="active", createdBlock=int(r["blockNumber"], 16), deployTx=r["transactionHash"])
        _write(os.path.join(d, "vault.json"), v)
    print(f"vault: tx {r['transactionHash']} status 0x1 block {int(r['blockNumber'], 16)} gasUsed {int(r['gasUsed'], 16)}")
    return {"txHash": r["transactionHash"], "receipt": r}


# ----------------------------------------------------------------------------- proposals
def proposals(W, vid):
    d = os.path.join(vdir(W, vid), "proposals")
    if not os.path.isdir(d):
        return []
    out = [_read(os.path.join(d, f)) for f in os.listdir(d) if f.endswith(".json")]
    return sorted([p for p in out if p], key=lambda p: -p["created"])


def _sign(W, v, tx):
    """This wallet's approval entry for tx: compact if a leaf is left, else stateless."""
    g = my_guardian(W, v)
    if not g:
        raise ValueError("This wallet has no key for that vault.")
    m = vault_message(tx.sig_hash())
    if g.remaining_leaves() > 0:
        return g.sign_compact(m), "compact"
    print(f"stateless fallback: guardian {g.i} has no compact leaf left; it signs with its SPX key")
    return g.sign_stateless(m), "stateless"


def propose(W, vid, to, wei):
    v = load_vault(W, vid)
    if v["status"] != "active":
        raise ValueError("That vault is not deployed yet.")
    me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
    if not me:
        raise ValueError("Only the vault's guardians can propose payments.")
    calls = [(to, int(wei), "0x")]
    tx = dv.build_vault_tx(W, v["address"], calls, ["stateless", "stateless"])  # frames fit either signature kind
    entry, kind = _sign(W, v, tx)
    pid = uuid.uuid4().hex[:10]
    p = {"id": pid, "vault": vid, "proposer": W.wallet, "to": to, "wei": str(int(wei)), "nonce": tx.nonce_seq,
         "unsigned": dv.h(tx.raw()), "sigHash": dv.h(tx.sig_hash()), "created": int(time.time()), "status": "pending",
         "approvals": {str(me["index"]): {"wallet": W.wallet, "kind": kind, "entry": dv.h(entry)}}}
    with locked(W, vid) as d:
        _write(os.path.join(d, "proposals", pid + ".json"), p)
    return p


def _vault_nonce(v):
    return int(rpc.eth("eth_getTransactionCount", [v["address"], "latest"]), 16)


def approve(W, vid, pid):
    """Add this wallet's approval. Returns (proposal, ready) where ready means this wallet must now submit."""
    v = load_vault(W, vid)
    me = next((m for m in v["members"] if m["wallet"] == W.wallet), None)
    if not me:
        raise ValueError("Only the vault's guardians can approve.")
    path = os.path.join(vdir(W, vid), "proposals", pid + ".json")
    p = _read(path)
    if not p:
        raise ValueError("unknown proposal")
    if p["status"] != "pending":
        raise ValueError(f"That payment is already {p['status']}.")
    if str(me["index"]) in p["approvals"]:
        raise ValueError("You already approved this payment.")
    if _vault_nonce(v) != p["nonce"]:
        with locked(W, vid):
            p = _read(path); p["status"] = "expired"; _write(path, p)
        raise ValueError("Another vault transaction went first, so this payment expired. Propose it again.")
    tx = ft.decode_raw(dv.unhex(p["unsigned"]))
    if dv.h(tx.sig_hash()) != p["sigHash"]:
        raise ValueError("The proposal's transaction does not match its hash.")
    entry, kind = _sign(W, v, tx)  # signing happens outside the lock (it burns a leaf first)
    with locked(W, vid):
        p = _read(path)
        if p["status"] != "pending":
            raise ValueError(f"That payment is already {p['status']}.")
        p["approvals"][str(me["index"])] = {"wallet": W.wallet, "kind": kind, "entry": dv.h(entry)}
        ready = len(p["approvals"]) >= v["threshold"]
        if ready:
            p["status"] = "ready"
        _write(path, p)
    return p, ready


def submit(W, vid, pid):
    """Assemble the two approvals in guardian order and submit the three-frame transaction."""
    v = load_vault(W, vid)
    path = os.path.join(vdir(W, vid), "proposals", pid + ".json")
    with locked(W, vid):  # claim it: exactly one wallet submits
        p = _read(path)
        if not p or p["status"] not in ("ready", "failed") or len(p["approvals"]) < v["threshold"]:
            raise ValueError("That payment is not waiting to be sent.")
        p["status"], p["submitter"] = "submitting", W.wallet
        _write(path, p)
    if _vault_nonce(v) != p["nonce"]:
        with locked(W, vid):
            q = _read(path); q["status"] = "expired"; _write(path, q)
        raise ValueError("Another vault transaction went first, so this payment expired. Propose it again.")
    tx = ft.decode_raw(dv.unhex(p["unsigned"]))
    sh = tx.sig_hash()
    idx = sorted(p["approvals"], key=int)[:2]
    for i, k in enumerate(idx):
        tx.signatures[i].signature = dv.unhex(p["approvals"][k]["entry"])
    assert tx.sig_hash() == sh
    kinds = [p["approvals"][k]["kind"] for k in idx]
    print("signing: " + ", ".join(f"guardian {k} ({p['approvals'][k]['wallet']}, {kd})" for k, kd in zip(idx, kinds)))
    try:
        sim = dv.simulate(tx)
        brief = {k: sim.get(k) for k in ("executionStatus", "frames", "executionError")}
        print("simulate: " + json.dumps(brief))
        if sim.get("executionStatus") != "success":
            raise RuntimeError(f"simulated execution failed: {brief}")
        print(f"submitting: to {W.cfg['sidecar']}")
        out = dv.submit(W, tx)
        rc = out["receipt"]
        status = "sent" if rc["status"] == "0x1" else "reverted"
        print(f"vault payment: tx {out['txHash']} status {rc['status']} block {int(rc['blockNumber'], 16)} "
              f"gasUsed {int(rc['gasUsed'], 16)}")
        upd = {"status": status, "txHash": out["txHash"], "block": int(rc["blockNumber"], 16), "kinds": kinds}
        return_val = {"txHash": out["txHash"], "receipt": rc, "kinds": kinds, "guardians": [int(k) for k in idx]}
    except Exception as e:
        upd, return_val = {"status": "failed", "error": str(e)[:300]}, None
        with locked(W, vid):
            q = _read(path); q.update(upd); _write(path, q)
        raise
    with locked(W, vid):
        q = _read(path); q.update(upd); _write(path, q)
    return return_val


def expire_stale(W, v):
    """Mark pending proposals whose nonce was used by another transaction."""
    if v["status"] != "active":
        return
    n = _vault_nonce(v)
    with locked(W, v["id"]):
        for p in proposals(W, v["id"]):
            if p["status"] in ("pending", "ready", "failed") and p["nonce"] != n:
                p["status"] = "expired"
                _write(os.path.join(vdir(W, v["id"]), "proposals", p["id"] + ".json"), p)
