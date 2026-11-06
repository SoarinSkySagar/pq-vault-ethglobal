"""PQ-Vault devnet driver: deploy infrastructure, create guardians and a vault, send 2-of-3 frame txs.

    python -m pqv.devnet <network> status
    python -m pqv.devnet <network> deploy-infra
    python -m pqv.devnet <network> new-guardians [--n 3]
    python -m pqv.devnet <network> deploy-vault [--threshold 2] [--fund ETH] [--stake ETH]
    python -m pqv.devnet <network> transfer <to> <wei> [--guardians 0,1] [--stateless 1]

Two transaction shapes (--frames, or "frames" in network.json; default 3):
  3 frames (ERC-8421 `[only_verify, pay]` prefix + body) — every approval verified before payment:
    frame 0 VERIFY (scope EXECUTION) validate() over approvals [0, k)
    frame 1 VERIFY (scope PAYMENT)   validate() over approvals [k, t)
    frame 2 SENDER execute(calls): consume every approval's leaf, run the batch
    Needs an ERC-8421 mempool with [BUDGET-010] (per-entity budgets, 1M for a staked entity): two or more
    PQ approvals exceed EIP-8141's combined 100k MAX_VERIFY_GAS.
  2 frames (`[self_verify]` prefix + body) — fallback for mempools with the combined 100k cap (stock workshop sidecar):
    frame 0 VERIFY (scope EXECUTION+PAYMENT) validateAndCommit(): the committer's compact approval, signed
                   last over first_message(sigHash, other entries)
    frame 1 SENDER execute(calls): verify the other t-1 approvals, consume leaves, run the batch

<network> is `public` (chain-1337 alt-mempool devnet) or `local` (infra/local-devnet.sh, Kurtosis).
ECDSA appears in exactly one place: the throwaway deployer EOA (.devnet/deployer.json) that publishes
contracts with ordinary transactions. The vault itself has no ECDSA code path.
State and keys live in .devnet/ (gitignored). Devnet only - never point this at a real network.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

from . import frametx as ft
from . import rpc
from .hashing import ROOT, keccak256
from .jardin import CompactSlot, GuardianKeys, compact_entry, first_message, stateless_entry, vault_message
from .state import AnchoredLeafStore, DurableLeafStore

DEVNET_DIR = os.path.join(ROOT, ".devnet")
OUT = os.path.join(ROOT, "contracts", "out")
SOLC_CANDIDATES = [os.environ.get("PQV_SOLC", ""), os.path.expanduser("~/Library/Application Support/svm/0.8.28/solc-0.8.28"),
                   os.path.expanduser("~/.svm/0.8.28/solc-0.8.28"),
                   os.path.expanduser("~/.local/share/svm/0.8.28/solc-0.8.28"), "solc"]
PUBLIC = {"ethrex": "https://altmempool.forshtat.com", "sidecar": "https://altmempoolgateway.forshtat.com/rpc",
          "staking": "0xd51c04d7a0b01124e84de152f4e56d9eecb22d2f", "explorer": "https://explorer.altmempool.wtf"}
# Declared VERIFY-frame execution limits. The sum over both frames + 100 per ARBITRARY entry is what an
# ERC-8421 node counts against the vault's validation budget ([BUDGET-010]). Measured (Foundry, gas-faithful
# FrameOps stand-in): 86,135 for a frame with one compact approval, +~68.5k per further compact approval,
# 295,410 for a frame with one stateless (SPX) approval. Limits below carry ~10-15% headroom.
# Two-frame shape: one compact approval + restHash, 89,647 (t=2) / 89,996 (t=3); limit 100,000 - 100 t.
VERIFY_BASE_GAS = 30_000
VERIFY_COMPACT_GAS = 70_000
VERIFY_STATELESS_GAS = 300_000
MAX_VERIFY_GAS_STAKED_ENTITY = 1_000_000  # ERC-8421
MAX_VERIFY_GAS = 100_000  # EIP-8141, combined over the prefix (+100 per ARBITRARY signature)
MAX_TX_COST_WEI = 5 * 10**16
SLOT_H = 7


# ----------------------------------------------------------------------------- small utils
def sel(sig: str) -> bytes:
    return keccak256(sig.encode())[:4]


def h(b: bytes) -> str:
    return "0x" + b.hex()


def unhex(s: str) -> bytes:
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def cast(*args) -> str:
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {re.sub(r'0x[0-9a-fA-F]{64}', '<hex64>', r.stderr.strip())[:1500]}")
    return r.stdout.strip()


class Net:
    def __init__(self, name: str):
        self.name = name
        self.dir = os.path.join(DEVNET_DIR, name)
        os.makedirs(self.dir, exist_ok=True)
        cfg_path = os.path.join(self.dir, "network.json")
        if os.path.exists(cfg_path):
            self.cfg = json.load(open(cfg_path))
        elif name == "public":
            self.cfg = dict(PUBLIC)
        else:
            raise SystemExit(f"write {cfg_path} with ethrex/sidecar URLs first (see infra/local-devnet.sh)")
        rpc.ETHREX_URL, rpc.SIDECAR_URL = self.cfg["ethrex"], self.cfg["sidecar"]

    # files
    def path(self, f):
        return os.path.join(self.dir, f)

    def load(self, f, default=None):
        p = self.path(f)
        return json.load(open(p)) if os.path.exists(p) else default

    def save(self, f, obj):
        p = self.path(f)
        with open(p, "w") as fh:
            json.dump(obj, fh, indent=1)
        os.chmod(p, 0o600)

    @property
    def deployment(self):
        return self.load("deployment.json", {})

    # chain helpers
    def deployer_key(self) -> str:
        d = json.load(open(os.path.join(DEVNET_DIR, "deployer.json")))
        d = d[0] if isinstance(d, list) else d
        return d["private_key"]

    def deployer(self) -> str:
        d = json.load(open(os.path.join(DEVNET_DIR, "deployer.json")))
        return (d[0] if isinstance(d, list) else d)["address"]

    def gas_price(self) -> int:
        base = int(rpc.eth("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
        return max(2 * base, 10**9)

    def send_legacy(self, to, data_hex, value_wei=0, gas=None) -> dict:
        args = ["send", "--private-key", self.deployer_key(), "--rpc-url", self.cfg["ethrex"], "--legacy",
                "--gas-price", str(self.gas_price()), "--json", "--value", str(value_wei)]
        if gas:
            args += ["--gas-limit", str(gas)]
        args += ["--create", data_hex] if to is None else [to, data_hex]
        r = json.loads(cast(*args))
        if r.get("status") not in ("0x1", 1, "1"):
            raise RuntimeError(f"tx {r.get('transactionHash')} reverted")
        return r

    def call(self, to: str, data: bytes) -> bytes:
        return unhex(rpc.eth("eth_call", [{"to": to, "data": h(data)}, "latest"]))

    def ledger_hwm(self, slot_id: bytes) -> int:
        led = self.deployment.get("ledger")
        if not led:
            return 0
        return int.from_bytes(self.call(led, sel("hwm(bytes32)") + slot_id), "big")


def artifact(name: str, sol: str = None) -> str:
    p = os.path.join(OUT, f"{sol or name}.sol", f"{name}.json")
    return json.load(open(p))["bytecode"]["object"]


def _solc() -> str:
    import shutil
    for c in SOLC_CANDIDATES:
        if c and (os.path.isfile(c) or shutil.which(c)):
            return c
    raise SystemExit("solc 0.8.28 not found (set PQV_SOLC)")


def frameops_initcode() -> str:
    """Compiled without the optimizer, like @forshtat/hegota-support's helpers: the bytecode maps 1:1
    onto the verbatim opcode sequence that was reviewed against ethrex's stack order."""
    src = os.path.join(ROOT, "contracts", "src", "PQVaultFrameOps.yul")
    out = subprocess.run([_solc(), "--strict-assembly", "--evm-version", "cancun", "--bin", src],
                         capture_output=True, text=True, check=True).stdout
    return "0x" + out.split("Binary representation:")[1].split()[0]


# ----------------------------------------------------------------------------- commands
def deploy_infra(net: Net):
    dep = net.deployment
    def create(label, initcode, ctor_sig=None, *ctor_args):
        if dep.get(label):
            print(f"  {label}: {dep[label]} (exists)")
            return dep[label]
        code = initcode
        if ctor_sig:
            code += cast("abi-encode", ctor_sig, *ctor_args)[2:]
        r = net.send_legacy(None, code)
        dep[label] = r["contractAddress"]
        dep.setdefault("txs", {})[label] = r["transactionHash"]
        net.save("deployment.json", dep)
        print(f"  {label}: {dep[label]}  tx {r['transactionHash']}  gas {int(r['gasUsed'], 16)}")
        return dep[label]

    staking = net.cfg.get("staking") or create("staking", artifact("NaiveStakingRegistry"))
    dep["staking"] = staking
    fo = create("frameOps", frameops_initcode())
    fors = create("forsVerifier", artifact("JardinForsPlainVerifier"))
    spx = create("spxVerifier", artifact("JardinSpxVerifier"))
    fac = create("factory", artifact("PQVaultFactory"), "constructor(address,address,address,address)", fo, fors, spx, staking)
    dep["ledger"] = "0x" + net.call(fac, sel("ledger()"))[-20:].hex()
    net.save("deployment.json", dep)
    print(f"  ledger: {dep['ledger']}")


def new_guardians(net: Net, n: int = 3):
    if net.load("guardians.json"):
        raise SystemExit("guardians.json exists; refusing to overwrite keys")
    if not 2 <= n <= 16:
        raise SystemExit("n must be in [2, 16]")
    gs = [{"index": i, "master_sk": h(os.urandom(32)), "slots": [{"r": h(os.urandom(32)), "h": SLOT_H}]}
          for i in range(n)]
    net.save("guardians.json", gs)
    print(f"created {n} guardians (secret keys in .devnet/{net.name}/guardians.json)")


class Guardian:
    def __init__(self, net: Net, rec: dict, prefix: str = "guardian", anchored: bool = True):
        self.net, self.rec, self.i = net, rec, rec["index"]
        self.keys = GuardianKeys(self.i, unhex(rec["master_sk"]))
        self._spx = None
        self._slots = {}
        path = net.path(f"{prefix}-{self.i}-leaves.json")
        # PQ-Vault guardians use the anchored store; the baseline (attack demo) uses JARDIN-style burn-before-sign only.
        self.leaves = AnchoredLeafStore(path, net.ledger_hwm) if anchored else DurableLeafStore(path)

    @property
    def spx(self):
        if self._spx is None:
            self._spx = self.keys.spx()
        return self._spx

    def slot(self, k=-1) -> CompactSlot:
        s = self.rec["slots"][k]
        if s["r"] not in self._slots:
            self._slots[s["r"]] = CompactSlot(self.keys.master_sk, unhex(s["r"]), s["h"])
        return self._slots[s["r"]]

    def sign_compact(self, msg: bytes) -> bytes:
        slot = self.slot()
        q = self.leaves.reserve(slot.slot_id, slot.q_max)  # burned (fsync) before the signature exists
        return compact_entry(self.i, slot, slot.sign(msg, q))

    def sign_stateless(self, msg: bytes) -> bytes:
        return stateless_entry(self.i, self.spx.sign(msg))


def guardians(net: Net, file: str = "guardians.json", prefix: str = "guardian", anchored: bool = True):
    gs = net.load(file)
    if not gs:
        raise SystemExit(f"run new-guardians first ({file})")
    return [Guardian(net, g, prefix, anchored) for g in gs]


def deploy_vault(net: Net, fund_eth: float, stake_eth: float, use_ledger: bool = True, label: str = "vault",
                 gs=None, threshold: int = 2):
    dep = net.deployment
    if dep.get(label):
        print(f"{label} exists: {dep[label]}")
        return
    gs = gs or guardians(net)
    if not 2 <= threshold <= len(gs):
        raise SystemExit(f"threshold must be in [2, {len(gs)}]")
    g_tuple = ",".join(f"({h(g.spx.public[0])},{h(g.spx.public[1])})" for g in gs)
    seeds = ",".join(h(g.slot().seed16) for g in gs)
    roots = ",".join(h(g.slot().root16) for g in gs)
    init = f"([{g_tuple}],[{seeds}],[{roots}],{threshold},{MAX_TX_COST_WEI},0)"
    salt = h(os.urandom(32))
    stake = int(stake_eth * 10**18)
    data = cast("calldata", "deploy(bytes32,((bytes32,bytes32)[],bytes16[],bytes16[],uint8,uint256,uint32),bool,uint256)",
                salt, init, "true" if use_ledger else "false", str(stake))
    value = int(fund_eth * 10**18) + stake
    est = int(rpc.eth("eth_estimateGas", [{"from": net.deployer(), "to": dep["factory"], "data": data,
                                           "value": hex(value)}]), 16)
    r = net.send_legacy(dep["factory"], data, value, gas=int(est * 1.3))
    topic = "0x" + keccak256(b"VaultDeployed(address,bytes32,bool)").hex()
    addr = next("0x" + l["topics"][1][-40:] for l in r["logs"] if l["topics"][0] == topic)
    dep[label] = addr
    dep.setdefault("thresholds", {})[label] = threshold
    dep.setdefault("txs", {})[label] = r["transactionHash"]
    net.save("deployment.json", dep)
    print(f"{label}: {addr}  tx {r['transactionHash']}  {threshold}-of-{len(gs)} ledger={use_ledger} stake={stake_eth} ETH")


def execute_calldata(calls) -> bytes:
    arr = "[" + ",".join(f"({to},{val},{data})" for to, val, data in calls) + "]"
    return unhex(cast("calldata", "execute((address,uint256,bytes)[])", arr))


def validate_data(frm: int, to: int) -> bytes:
    """VERIFY frame data: validate() selector || from u8 || to u8 (PQVault.validate reads the range packed)."""
    return sel("validate()") + bytes([frm, to])


def approval_gas(kinds) -> int:
    return VERIFY_BASE_GAS + sum(VERIFY_STATELESS_GAS if k == "stateless" else VERIFY_COMPACT_GAS for k in kinds)


def split_point(kinds) -> int:
    """k in [1, t) that balances the two VERIFY frames' declared gas (entries stay in guardian order)."""
    t = len(kinds)
    return min(range(1, t), key=lambda k: max(approval_gas(kinds[:k]), approval_gas(kinds[k:])))


def build_vault_tx(net: Net, vault: str, calls, kinds, exec_gas=900_000, state_gas=400_000, frames=3) -> ft.FrameTx:
    """Unsigned vault transaction for approvals of the given kinds ("compact"/"stateless"), in entry order
    (three frames: increasing guardian order; two frames: committer first, then increasing guardian order)."""
    t = len(kinds)
    if t < 2:
        raise ValueError("a vault transaction needs at least 2 approvals")
    nonce = int(rpc.eth("eth_getTransactionCount", [vault, "latest"]), 16)
    chain_id = int(rpc.eth("eth_chainId"), 16)
    base = int(rpc.eth("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
    max_fee = max(4 * base, 2 * 10**9)
    v = unhex(vault)
    if frames == 2:
        if kinds[0] != "compact":
            raise ValueError("two-frame shape: the committer (entry 0) must sign compact (SPX does not fit 100k)")
        fs = [ft.Frame(ft.MODE_VERIFY, ft.SCOPE_EXECUTION_AND_PAYMENT, None, MAX_VERIFY_GAS - 100 * t, 0, 0,
                       sel("validateAndCommit()")),
              ft.Frame(ft.MODE_SENDER, 0, v, exec_gas, state_gas, 0, execute_calldata(calls))]
    elif frames == 3:
        k = split_point(kinds)
        g0, g1 = approval_gas(kinds[:k]), approval_gas(kinds[k:])
        if g0 + g1 + 100 * t > MAX_VERIFY_GAS_STAKED_ENTITY:
            raise ValueError(f"validation prefix {g0 + g1 + 100 * t} gas exceeds ERC-8421 MAX_VERIFY_GAS_STAKED_ENTITY")
        # frame 0 target None = tx.sender (only_verify must target the sender); frame 1 names the payer (the vault)
        fs = [ft.Frame(ft.MODE_VERIFY, ft.SCOPE_EXECUTION, None, g0, 0, 0, validate_data(0, k)),
              ft.Frame(ft.MODE_VERIFY, ft.SCOPE_PAYMENT, v, g1, 0, 0, validate_data(k, t)),
              ft.Frame(ft.MODE_SENDER, 0, v, exec_gas, state_gas, 0, execute_calldata(calls))]
    else:
        raise ValueError("frames must be 2 or 3")
    return ft.FrameTx(sender=v, nonce_seq=nonce, frames=fs,
                      signatures=[ft.Signature(ft.SCHEME_ARBITRARY) for _ in range(t)],
                      max_priority_fee=10**9, max_fee=max_fee, chain_id=chain_id)


def entry_signer(g, kind):
    return (lambda m: g.sign_stateless(m)) if kind == "stateless" else (lambda m: g.sign_compact(m))


def sign_entries(tx: ft.FrameTx, entry_fns):
    """Fill the signature entries. entry_fns[i](message) -> entry bytes, in entry order.
    Three frames: every entry signs vault_message(sigHash), independently.
    Two frames: entries 1..t-1 sign vault_message(sigHash) first; entry 0 signs last, over
    first_message(sigHash, entries 1..t-1), so it commits to their exact bytes."""
    sh = tx.sig_hash()  # empty-msg ARBITRARY bytes are elided, so adding them does not change the hash
    m = vault_message(sh)
    if len(tx.frames) == 2:
        for i in range(1, len(entry_fns)):
            tx.signatures[i].signature = entry_fns[i](m)
        tx.signatures[0].signature = entry_fns[0](first_message(sh, [s.signature for s in tx.signatures[1:]]))
    else:
        for i, fn in enumerate(entry_fns):
            tx.signatures[i].signature = fn(m)
    assert tx.sig_hash() == sh
    return sh


def sign_vault_tx(tx: ft.FrameTx, approvers, kinds):
    return sign_entries(tx, [entry_signer(g, k) for g, k in zip(approvers, kinds)])


def simulate(tx: ft.FrameTx, trace=False) -> dict:
    return rpc.eth("ethrex_simulateFrameTransaction", [h(tx.raw()), "latest", {"trace": trace}])


def submit(net: Net, tx: ft.FrameTx, wait=True) -> dict:
    tx_hash = rpc.sidecar("eth_sendFrameTransaction", [tx.to_wire()])
    out = {"txHash": tx_hash, "submittedVia": net.cfg["sidecar"]}
    if not wait:
        return out
    end = time.time() + 180
    while time.time() < end:
        try:
            st = rpc.sidecar("skandha_frameTransactionStatus", [tx_hash])
            out["sidecarStatus"] = st.get("status")
        except rpc.RpcError:
            pass
        rc = rpc.eth("eth_getTransactionReceipt", [tx_hash])
        if rc:
            out["receipt"] = rc
            return out
        time.sleep(2)
    raise TimeoutError(f"{tx_hash} not mined: {out}")


def record_receipt(net: Net, label: str, out: dict, extra=None):
    recs = net.load("receipts.json", [])
    rc = out.get("receipt", {})
    recs.append({"label": label, "txHash": out["txHash"], "block": int(rc.get("blockNumber", "0x0"), 16),
                 "status": rc.get("status"), "gasUsed": int(rc.get("gasUsed", "0x0"), 16),
                 "frameReceipts": rc.get("frameReceipts"), "submittedVia": out.get("submittedVia"),
                 "sidecarStatus": out.get("sidecarStatus"), "network": net.name, "time": int(time.time()),
                 **(extra or {})})
    net.save("receipts.json", recs)


def approver_plan(gs, approvers, stateless=(), frames=3, committer=None):
    """Approver guardians in entry order and their signature kinds.
    Three frames: increasing guardian order. Two frames: the committer (default: the lowest-index compact
    approver) first, then the others in increasing order."""
    idx = sorted(set(approvers))
    if len(idx) != len(approvers):
        raise ValueError("an approver may appear only once")
    if frames == 2:
        if committer is None:
            committer = next((i for i in idx if i not in stateless), None)
        if committer is None or committer not in idx or committer in stateless:
            raise ValueError("two-frame shape needs a compact committer among the approvers")
        idx = [committer] + [i for i in idx if i != committer]
    return [gs[i] for i in idx], ["stateless" if i in stateless else "compact" for i in idx], idx


def net_frames(net) -> int:
    """Transaction shape for this network: "frames" in network.json, else 3 (needs an ERC-8421 mempool
    with [BUDGET-010], e.g. infra/local-net.sh). Use 2 for a mempool that caps the prefix at 100k."""
    return int(net.cfg.get("frames", 3))


def vault_call(net: Net, calls, approvers=(0, 1), stateless=(), label="vault call", gs=None, vault_label="vault",
               frames=None, committer=None):
    """Build, t-of-n sign, simulate, submit and record one vault frame transaction."""
    gs = gs or guardians(net)
    vault = net.deployment[vault_label]
    t = net.deployment.get("thresholds", {}).get(vault_label, 2)
    if len(approvers) != t:
        raise SystemExit(f"{vault_label} is {t}-of-{len(gs)}: give exactly {t} approvers")
    frames = frames or net_frames(net)
    signers, kinds, idx = approver_plan(gs, approvers, stateless, frames, committer)
    tx = build_vault_tx(net, vault, calls, kinds, frames=frames)
    sh = sign_vault_tx(tx, signers, kinds)
    sim = simulate(tx)
    # `valid`/`violation` are ethrex's *canonical* (EIP-8141 public mempool) verdict. PQ-Vault's VERIFY frame
    # reads the shared LeafLedger, so it is expected to be canonically invalid and admitted by the ERC-8421
    # alt mempool (staked sender); what must hold is that full execution succeeds.
    brief = {k: sim.get(k) for k in ("valid", "prefixShape", "violation", "canonicalMempoolViolation", "executionStatus",
                                     "gasUsed", "frames", "executionError", "failedFrameIndex", "haltReason", "revertData")}
    print("simulate:", json.dumps(brief))
    if sim.get("executionStatus") not in (None, "success"):
        raise RuntimeError(f"simulated execution failed: {brief}")
    out = submit(net, tx)
    rc = out["receipt"]
    print(f"{label}: tx {out['txHash']} status {rc['status']} block {int(rc['blockNumber'], 16)} "
          f"gasUsed {int(rc['gasUsed'], 16)}")
    record_receipt(net, label, out, {"sigHash": h(sh), "guardians": idx, "kinds": kinds, "frames": frames,
                                     "simulation": brief, "vault": vault})
    return out


def _others(net: Net, n: int, exclude: int):
    t = net.deployment.get("thresholds", {}).get("vault", 2)
    pick = [x for x in range(n) if x != exclude][:t]
    if len(pick) < t:
        raise SystemExit("not enough remaining guardians to reach the threshold")
    return tuple(pick)


def _plus(idx, stateless):
    return "+".join(f"g{i}" + ("(spx)" if i in stateless else "") for i in sorted(idx))


def cmd_transfer(net: Net, to: str, wei: int, approvers=(0, 1), stateless=(), label=None, vault_label="vault",
                 frames=None, committer=None):
    t = net.deployment.get("thresholds", {}).get(vault_label, 2)
    n = len(net.load("guardians.json", []))
    frames = frames or net_frames(net)
    return vault_call(net, [(to, wei, "0x")], approvers, stateless,
                      label or f"transfer {t}-of-{n} {_plus(approvers, stateless)} ({frames} frames)",
                      vault_label=vault_label, frames=frames, committer=committer)


def cmd_rotate(net: Net, g: int, pair=None):
    """Key rotation: guardian g gets a fresh compact slot (new random r); the old slot is revoked."""
    gs = guardians(net)
    pair = pair or _others(net, len(gs), g)
    old = gs[g].slot()
    rec = net.load("guardians.json")
    new_r = h(os.urandom(32))
    new_slot = CompactSlot(gs[g].keys.master_sk, unhex(new_r), SLOT_H)
    vault = net.deployment["vault"]
    calls = [(vault, 0, cast("calldata", "registerSlot(uint8,bytes16,bytes16)", str(g), h(new_slot.seed16), h(new_slot.root16))),
             (vault, 0, cast("calldata", "revokeSlot(bytes32)", h(old.slot_id)))]
    out = vault_call(net, calls, pair, label=f"rotate guardian {g} slot (approved by {_plus(pair, ())})", gs=gs)
    rec[g]["slots"].append({"r": new_r, "h": SLOT_H})
    net.save("guardians.json", rec)
    return out


def cmd_recover(net: Net, lost: int):
    """Key-loss recovery: the two other guardians install new master + slot keys for `lost`."""
    gs = guardians(net)
    pair = _others(net, len(gs), lost)
    new_master = os.urandom(32)
    nk = GuardianKeys(lost, new_master)
    spx = nk.spx()
    new_r = os.urandom(32)
    slot = CompactSlot(new_master, new_r, SLOT_H)
    vault = net.deployment["vault"]
    data = cast("calldata", "replaceGuardian(uint8,(bytes32,bytes32),bytes16,bytes16)", str(lost),
                f"({h(spx.public[0])},{h(spx.public[1])})", h(slot.seed16), h(slot.root16))
    out = vault_call(net, [(vault, 0, data)], pair, label=f"recover lost guardian {lost} (approved by {_plus(pair, ())})", gs=gs)
    rec = net.load("guardians.json")
    rec[lost] = {"index": lost, "master_sk": h(new_master), "slots": [{"r": h(new_r), "h": SLOT_H}],
                 "replaced": rec[lost].get("replaced", 0) + 1}
    net.save("guardians.json", rec)
    for f in (f"guardian-{lost}-leaves.json",):
        if os.path.exists(net.path(f)):
            os.replace(net.path(f), net.path(f + ".lost-device"))
    return out


# ----------------------------------------------------------------------------- research: live attack on controlled test wallets
def cmd_attack_stale_restore(net: Net):
    """Outdated-backup restoration against our own devnet test wallets.

    Baseline: a vault without leaf tracking (JARDIN behaviour) and guardians using burn-before-sign only.
    Guardian 0 signs tx1 at leaf q; its device is then restored from a backup taken before that signature;
    it signs tx2 at the *same* leaf q. We show (1) the baseline vault includes both, (2) a watcher turns the
    two public signatures into an equivocation proof that revokes the slot in the LeafLedger, and (3) the
    same restored signer cannot get a reused leaf past PQ-Vault's VERIFY frame.
    """
    import shutil
    report = {}
    if not net.load("baseline-guardians.json"):
        net.save("baseline-guardians.json", [{"index": i, "master_sk": h(os.urandom(32)),
                                               "slots": [{"r": h(os.urandom(32)), "h": SLOT_H}]} for i in range(3)])
    bgs = guardians(net, "baseline-guardians.json", "baseline-guardian", anchored=False)
    deploy_vault(net, 0.05, 0.02, use_ledger=False, label="baselineVault", gs=bgs)
    g0 = bgs[0]
    leaf_file = g0.leaves.path
    backup = leaf_file + ".backup"
    shutil.copyfile(leaf_file, backup)  # the backup the device will later be restored from
    to = net.deployer()
    out1 = vault_call(net, [(to, 1, "0x")], (0, 1), label="baseline vault: tx1 (guardian 0, leaf q)", gs=bgs,
                      vault_label="baselineVault")
    q1 = out1["receipt"] and parse_q(net, out1["txHash"])
    shutil.copyfile(backup, leaf_file)  # silent restore of the outdated backup
    out2 = vault_call(net, [(to, 2, "0x")], (0, 2), label="baseline vault: tx2 after stale restore (guardian 0, SAME leaf)",
                      gs=bgs, vault_label="baselineVault")
    q2 = parse_q(net, out2["txHash"])
    report["baseline"] = {"tx1": out1["txHash"], "tx2": out2["txHash"], "leaf_tx1": q1, "leaf_tx2": q2,
                          "both_included": out1["receipt"]["status"] == "0x1" and out2["receipt"]["status"] == "0x1"}
    # (2) permissionless equivocation report from the two public transactions
    e_a, m_a = entry0_and_message(net, out1["txHash"])
    e_b, m_b = entry0_and_message(net, out2["txHash"])
    slot = g0.slot()
    data = cast("calldata", "reportEquivocation(bytes16,bytes16,bytes32,bytes,bytes32,bytes)", h(slot.seed16), h(slot.root16),
                h(m_a), h(e_a[34:]), h(m_b), h(e_b[34:]))
    r = net.send_legacy(net.deployment["ledger"], data, gas=1_000_000)
    report["equivocationReport"] = {"tx": r["transactionHash"], "status": r["status"],
                                    "slotRevoked": net.ledger_hwm(slot.slot_id) >= 2**255}
    recs = net.load("receipts.json", [])
    recs.append({"label": "watcher: equivocation proof revokes the reused slot (LeafLedger.reportEquivocation)",
                 "txHash": r["transactionHash"], "block": int(r["blockNumber"], 16), "status": r["status"],
                 "gasUsed": int(r["gasUsed"], 16), "network": net.name, "time": int(time.time()), "legacyTx": True})
    net.save("receipts.json", recs)
    # (3) the same stale signer against PQ-Vault
    gs = guardians(net)
    pg = gs[0]
    pslot = pg.slot()
    hwm = net.ledger_hwm(pslot.slot_id)
    if hwm >= 1:
        t = net.deployment.get("thresholds", {}).get("vault", 2)
        tx = build_vault_tx(net, net.deployment["vault"], [(to, 3, "0x")], ["compact"] * t, frames=net_frames(net))
        # guardian 0 (restored signer, reused leaf) is entry 0 in both shapes: lowest index / the committer
        sign_entries(tx, [lambda m: compact_entry(0, pslot, pslot.sign(m, hwm))]
                     + [entry_signer(gs[i], "compact") for i in range(1, t)])
        sim = simulate(tx)
        try:
            rpc.sidecar("eth_sendFrameTransaction", [tx.to_wire()])
            admitted = "ADMITTED (unexpected)"
        except rpc.RpcError as e:
            admitted = f"rejected: {json.dumps(e.error)[:300]}"
        report["pqVault"] = {"reusedLeaf": hwm, "simulation": {k: sim.get(k) for k in ("valid", "violation", "executionError")},
                             "altMempool": admitted}
    net.save("attack-stale-restore.json", report)
    print(json.dumps(report, indent=1))
    return report


def raw_tx(net: Net, tx_hash: str) -> ft.FrameTx:
    raw = rpc.eth("debug_getRawTransaction", [tx_hash])
    return ft.decode_raw(unhex(raw))


def entry0_and_message(net: Net, tx_hash: str):
    """From an included vault transaction (public data): the first approval's entry and the message it signed."""
    tx = raw_tx(net, tx_hash)
    sh = tx.sig_hash()
    if len(tx.frames) == 2:
        return tx.signatures[0].signature, first_message(sh, [s.signature for s in tx.signatures[1:]])
    return tx.signatures[0].signature, vault_message(sh)


def parse_q(net: Net, tx_hash: str) -> int:
    e0, _ = entry0_and_message(net, tx_hash)
    return e0[34 + 2592]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("network", choices=["public", "local"])
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--fund", type=float, default=0.3)
    ap.add_argument("--stake", type=float, default=0.02)
    ap.add_argument("--guardians", default="0,1", help="approving guardian indices (exactly t of them)")
    ap.add_argument("--stateless", default="", help="approvers that sign with their stateless SPX key")
    ap.add_argument("--n", type=int, default=3, help="new-guardians: number of guardians")
    ap.add_argument("--threshold", type=int, default=2, help="deploy-vault: approvals required (t)")
    ap.add_argument("--vault", default="vault", help="deployment label of the vault to use / deploy")
    ap.add_argument("--frames", type=int, choices=[2, 3], default=None,
                    help="transaction shape (default: network.json 'frames', else 3)")
    ap.add_argument("--committer", type=int, default=None, help="two-frame shape: guardian whose approval is in VERIFY")
    a = ap.parse_args(argv)
    net = Net(a.network)
    if a.cmd == "status":
        print(json.dumps({"head": int(rpc.eth("eth_blockNumber"), 16), "deployment": net.deployment}, indent=1))
    elif a.cmd == "deploy-infra":
        deploy_infra(net)
    elif a.cmd == "new-guardians":
        new_guardians(net, a.n)
    elif a.cmd == "deploy-vault":
        deploy_vault(net, a.fund, a.stake, label=a.vault, threshold=a.threshold)
    elif a.cmd == "transfer":
        cmd_transfer(net, a.args[0], int(a.args[1]), tuple(int(x) for x in a.guardians.split(",")),
                     tuple(int(x) for x in a.stateless.split(",") if x), vault_label=a.vault,
                     frames=a.frames, committer=a.committer)
    elif a.cmd == "rotate":
        cmd_rotate(net, int(a.args[0]))
    elif a.cmd == "recover":
        cmd_recover(net, int(a.args[0]))
    elif a.cmd == "attack-stale-restore":
        cmd_attack_stale_restore(net)
    else:
        sys.exit(f"unknown command {a.cmd}")


if __name__ == "__main__":
    main()
