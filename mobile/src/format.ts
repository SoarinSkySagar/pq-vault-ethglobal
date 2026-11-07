// Exact ETH amounts (BigInt wei), short addresses, and the identity helpers shared with app/wallet/index.html.
import type { Activity, Quote } from "./api";

export const ACCENTS = ["#2F6F5E", "#3B5BA9", "#7C4A9E", "#2C7DA0", "#6A7B2E", "#A04E68"]; // same as pqv/wallet.py

export function ethToWei(s: string): bigint | null {
  s = String(s).trim();
  if (!/^\d+(\.\d{1,18})?$/.test(s)) return null;
  const [i, f = ""] = s.split(".");
  return BigInt(i) * 10n ** 18n + BigInt((f + "0".repeat(18)).slice(0, 18));
}

export function eth(w: string | bigint | null | undefined, dp = 4): string {
  const v = BigInt(w ?? 0);
  const i = v / 10n ** 18n;
  const f = (v % 10n ** 18n).toString().padStart(18, "0").slice(0, dp).replace(/0+$/, "");
  return group(i.toString()) + (f ? "." + f : "");
}

export const group = (digits: string) => digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
export const num = (n: number) => group(String(n));
export const short = (a: string | null | undefined) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "");
export const cap = (s: string | null | undefined) => (s ? s[0].toUpperCase() + s.slice(1) : "");
export const isAddress = (s: string) => /^0x[0-9a-fA-F]{40}$/.test(s);
export const sameAddr = (a?: string | null, b?: string | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

export const accentFor = (addr?: string | null) => ACCENTS[parseInt((addr || "0x00").slice(2, 4), 16) % ACCENTS.length];

/** A stable 40-hex-digit fingerprint for a name (FNV-1a, repeated), for avatars of things without an address. */
export function hexOf(str: string): string {
  let out = "";
  let h = 0x811c9dc5;
  for (let k = 0; out.length < 40; k++) {
    for (const ch of str + k) { h ^= ch.charCodeAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
    out += h.toString(16).padStart(8, "0");
  }
  return "0x" + out.slice(0, 40);
}

/** 5x5 mirrored identicon cells from an address (same pattern as the web wallet). */
export function avatarCells(addr?: string | null): boolean[] {
  const hex = (addr || "0x").slice(2).toLowerCase().padEnd(40, "0");
  const cells: boolean[] = [];
  for (let r = 0; r < 5; r++) for (let c = 0; c < 5; c++) {
    const col = c < 3 ? c : 4 - c;
    cells.push(parseInt(hex[r * 3 + col], 16) % 2 === 1);
  }
  return cells;
}

/** "ethereum:0xabc…@1337?value=…" or a bare address from a scanned QR code. */
export function addressFromQr(s: string): string | null {
  const m = s.trim().match(/(0x[0-9a-fA-F]{40})/);
  return m ? m[1] : null;
}

const SYSTEM = /^(Account setup|Mempool stake|Test ETH faucet)$/;
export function describe(r: Activity): string {
  const who = r.name && !SYSTEM.test(r.name) ? cap(r.name) : short(r.counterparty);
  if (r.direction === "in") return r.name === "Account setup" ? "Account created" : r.name === "Test ETH faucet" ? "Test ETH added" : `Received from ${who}`;
  return r.name === "Mempool stake" ? "Mempool stake" : `Sent to ${who}`;
}

/** Why this payment costs more than the usual ~380k gas, from the wallet's send plan (pqv/wallet.py send_plan). */
export function feeReasons(q: Quote | null): string[] {
  if (!q || !q.plan) return [];
  const why: string[] = [];
  if (q.plan.some((t) => t.what === "renew")) why.push("renews a nearly used-up key first (an extra transaction)");
  if (q.plan.some((t) => t.kinds.includes("stateless"))) why.push("a used-up key signs with its larger backup signature");
  if (q.plan.some((t) => t.newStorage)) why.push("first use of a key records it on chain once");
  return why;
}
