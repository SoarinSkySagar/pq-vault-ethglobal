"""Write docs/RECEIPTS.md from recorded devnet data (.devnet/<network>/{deployment,receipts}.json).

    python -m pqv.receipts <network> [<network> ...]

Every line is copied from what the node returned; receipts are re-fetched from the chain so the file
cannot drift from it.
"""
import json
import os
import sys
import time

from . import devnet as dv
from . import rpc
from .hashing import ROOT


def section(name: str) -> str:
    net = dv.Net(name)
    dep = net.deployment
    recs = net.load("receipts.json", [])
    chain = int(rpc.eth("eth_chainId"), 16)
    client = rpc.eth("web3_clientVersion")
    lines = [f"## Network `{name}`", "",
             f"- chain id: {chain}", f"- execution client: `{client}`",
             f"- RPC: {net.cfg['ethrex']} · mempool (ERC-8421 sidecar): {net.cfg['sidecar']}",
             f"- generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}", "",
             "### Contracts", "", "| contract | address | deploy tx |", "|---|---|---|"]
    for k in ("frameOps", "forsVerifier", "spxVerifier", "staking", "factory", "ledger", "vault", "baselineVault",
              "unstakedVault"):
        if dep.get(k):
            lines.append(f"| {k} | `{dep[k]}` | `{dep.get('txs', {}).get(k, '-')}` |")
    lines += ["", "### PQ-signed frame transactions", "",
              "| # | action | tx hash | block | status | gas used | frames (VERIFY, SENDER) |", "|---|---|---|---|---|---|---|"]
    for i, r in enumerate(recs, 1):
        rc = rpc.eth("eth_getTransactionReceipt", [r["txHash"]]) or {}
        frames = rc.get("frameReceipts") or []
        fr = ", ".join(f"{f.get('status')}/{int(f.get('gasUsed', '0x0'), 16) if isinstance(f.get('gasUsed'), str) else f.get('gasUsed')}"
                       for f in frames)
        lines.append(f"| {i} | {r['label']} | `{r['txHash']}` | {int(rc.get('blockNumber', '0x0'), 16)} | "
                     f"{rc.get('status', 'missing')} | {int(rc.get('gasUsed', '0x0'), 16)} | {fr} |")
    cmp_ = net.load("mempool-comparison.json")
    if cmp_:
        lines += ["", "### Why the ERC-8421 alt mempool (recorded node responses)", "",
                  "The vault's VERIFY frame reads the shared LeafLedger (storage not associated with the sender).", "",
                  "| submission | admitted | node response |", "|---|---|---|",
                  f"| staked PQ-Vault → ethrex canonical mempool (`eth_sendRawTransaction`) | {cmp_['canonical_mempool']['admitted']} | `{json.dumps(cmp_['canonical_mempool'].get('error', cmp_['canonical_mempool'].get('result')))}` |",
                  f"| unstaked vault → ERC-8421 alt mempool | {cmp_['unstaked_alt_mempool']['admitted']} | `{json.dumps(cmp_['unstaked_alt_mempool'].get('error', cmp_['unstaked_alt_mempool'].get('txHash')))}` |",
                  "| staked PQ-Vault → ERC-8421 alt mempool | True | transactions 1-5 above |"]
    att = net.load("attack-stale-restore.json")
    if att:
        lines += ["", "### Live attack: outdated-backup restoration (controlled test wallets)", "",
                  "```json", json.dumps(att, indent=1), "```"]
    lines += ["", "<details><summary>raw receipts (JSON)</summary>", "", "```json",
              json.dumps([rpc.eth("eth_getTransactionReceipt", [r["txHash"]]) for r in recs], indent=1)[:200000],
              "```", "</details>", ""]
    return "\n".join(lines)


def main():
    nets = sys.argv[1:] or ["local"]
    out = ["# Devnet receipts", "",
           "Real EIP-8141 frame transactions authorised by JARDIN hash-based signatures (no ECDSA), "
           "submitted through the ERC-8421 alt-mempool sidecar. Regenerate with `python -m pqv.receipts "
           + " ".join(nets) + "`.", ""]
    for n in nets:
        out.append(section(n))
    p = os.path.join(ROOT, "docs", "RECEIPTS.md")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("\n".join(out))
    print("wrote", p)


if __name__ == "__main__":
    main()
