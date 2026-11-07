import React, { useCallback, useEffect, useState } from "react";
import { AppState, RefreshControl, Text, View } from "react-native";
import { api, type Proposal, type VaultDetail } from "../api";
import { cap, describe, eth, ethToWei, hexOf, isAddress, num, sameAddr, short } from "../format";
import { HERE, useWallet } from "../store";
import { Avatar, Btn, C, Chip, Field, H1, H2, Msg, Note, Screen, T, s } from "../ui";

function friendlyErr(e: string) {
  if (/expired/i.test(e)) return "Another vault payment went first; propose it again.";
  if (/rejected|reverted|simulat/i.test(e)) return "The network rejected it; propose it again.";
  return e.slice(0, 120);
}

function Status({ p }: { p: Proposal }) {
  const [label, color] = p.status === "sent" ? ["Sent", C.plus] : p.status === "pending" ? ["Needs approval", C.warn]
    : p.status === "ready" ? ["Approved", C.warn] : p.status === "submitting" ? ["Sending…", C.warn] : [cap(p.status), C.bad];
  return <Text style={{ color, fontSize: 13, fontWeight: "600" }}>{label}</Text>;
}

export function Vault({ id, msg: initialMsg }: { id: string; msg?: { text: string; bad?: boolean } }) {
  const w = useWallet();
  const [V, setV] = useState<VaultDetail | null>(null);
  const [msg, setMsg] = useState(initialMsg);
  const [busy, setBusy] = useState("");
  const load = useCallback(async () => {
    try { setV(await api<VaultDetail>("/api/vaults/" + id)); } catch (e) { setMsg({ text: (e as Error).message, bad: true }); }
  }, [id]);
  useEffect(() => {
    load();
    const t = setInterval(() => { if (AppState.currentState === "active") load(); }, 4000);
    return () => clearInterval(t);
  }, [load]);

  if (!V) return <Screen>{msg ? <Msg {...msg} /> : <T muted>Loading…</T>}</Screen>;
  const me = V.members.find((m) => m.me);
  const joined = V.members.filter((m) => m.joined).length;

  async function join() {
    setBusy("join");
    try { await api(`/api/vaults/${id}/join`, {}); setMsg({ text: "You joined. Your key for this vault is ready." }); await w.refresh(); await load(); }
    catch (e) { setMsg({ text: (e as Error).message, bad: true }); }
    setBusy("");
  }
  async function approve(pid: string) {
    setBusy(pid);
    try {
      const r = await api<{ job?: string; approvals?: number }>(`/api/vaults/${id}/proposals/${pid}/approve`, {});
      if (r.job) {
        return w.replace({ name: "job", job: { title: "Sending the vault payment", jobId: r.job, first: "Approved with your vault key",
          doneText: "Paid from the vault.", back: "vault", vaultId: id } });
      }
      setMsg({ text: "Approved. It is sent when one more guardian approves." }); await load();
    } catch (e) { setMsg({ text: (e as Error).message, bad: true }); }
    setBusy("");
  }
  const submit = (pid: string) => w.replace({ name: "job", job: { title: "Sending the vault payment", path: `/api/vaults/${id}/proposals/${pid}/submit`,
    doneText: "Paid from the vault.", back: "vault", vaultId: id } });
  const deploy = () => w.replace({ name: "job", job: { title: "Creating the vault", path: `/api/vaults/${id}/deploy`,
    doneText: "The vault is ready.", back: "vault", vaultId: id } });

  let top: React.ReactNode = null;
  if (V.status === "active") {
    top = (
      <>
        <View style={{ alignItems: "center", marginVertical: 20 }}>
          <Text><Text style={{ fontSize: 36, fontWeight: "600", color: C.ink }}>{eth(V.balanceWei)}</Text><Text style={{ fontSize: 18, color: C.slate }}>  ETH</Text></Text>
        </View>
        <View style={{ flexDirection: "row", gap: 10 }}>
          <Btn title="Propose payment" onPress={() => w.push({ name: "propose", id })} style={{ flex: 1 }} />
          <Btn ghost title="Deposit" onPress={() => w.push({ name: "send", to: V.address! })} style={{ flex: 1 }} />
        </View>
      </>
    );
  } else if (V.invited) {
    top = (
      <>
        <Msg text={`${cap(V.creator)} invited you. Accepting creates your key for this vault ${HERE}.`} />
        <View style={{ flexDirection: "row", gap: 10 }}>
          <Btn ghost title="Not now" onPress={w.pop} style={{ flex: 1 }} />
          <Btn title="Accept" onPress={join} busy={busy === "join"} style={{ flex: 1 }} />
        </View>
      </>
    );
  } else if (joined === 3 && V.status === "inviting") {
    top = (
      <>
        <Msg text="Everyone accepted. Create the vault on chain (the devnet pays the 0.02 ETH mempool stake and adds 0.5 test ETH)." />
        <Btn title="Create vault" onPress={deploy} />
      </>
    );
  } else if (V.status !== "deploying") {
    top = <Msg text={`Waiting for ${V.members.filter((m) => !m.joined).map((m) => cap(m.wallet)).join(" and ")} to accept.`} />;
  } else {
    top = <Msg text="The vault is being created…" />;
  }

  return (
    <Screen refresh={<RefreshControl refreshing={false} onRefresh={load} />}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 12, marginBottom: 14 }}>
        <Avatar addr={V.address || hexOf(V.id)} />
        <View style={{ flex: 1 }}>
          <H1 style={{ textTransform: "none" }}>{V.name}</H1>
          <T small muted style={V.address ? s.mono : undefined}>{V.address ? short(V.address) : "2 of 3 multisig vault"}</T>
        </View>
      </View>
      {msg ? <Msg {...msg} /> : null}
      {top}
      <Text style={{ fontWeight: "600", color: C.ink, marginTop: 24, marginBottom: 6 }}>Guardians, any 2 of 3 approve</Text>
      {V.members.map((m) => (
        <View key={m.wallet} style={{ flexDirection: "row", justifyContent: "space-between", paddingVertical: 8 }}>
          <T style={{ textTransform: "capitalize" }}>{m.wallet}{m.me ? " (you)" : ""}</T>
          <T small style={{ color: m.joined ? C.plus : C.slate }}>{m.joined ? (V.status === "active" ? "guardian" : "accepted") : "invited"}</T>
        </View>
      ))}
      {V.myKey ? <Note>Your key for this vault: {V.myKey.remaining} of {V.myKey.leaves} approvals left.</Note> : null}
      {V.status === "active" ? (
        <>
          <Text style={{ fontWeight: "600", color: C.ink, marginTop: 24, marginBottom: 8 }}>Payments</Text>
          {!V.proposals.length ? <T muted>No payments yet.</T> : null}
          {V.proposals.slice(0, 12).map((p) => {
            const mine = !!me && p.approvals.some((a) => a.index === me.index);
            const toName = w.S.contacts.find((c) => sameAddr(c.address, p.to))?.name || (sameAddr(w.S.account?.address, p.to) ? "you" : short(p.to));
            return (
              <View key={p.id} style={s.card}>
                <View style={{ flexDirection: "row", justifyContent: "space-between", gap: 8 }}>
                  <T bold style={{ flex: 1 }}>Pay {eth(p.wei, 18)} ETH to {cap(toName)}</T><Status p={p} />
                </View>
                <T small muted style={{ marginTop: 4 }}>
                  Approved by {p.approvals.map((a) => (a.wallet === w.S.name ? "you" : cap(a.wallet)) + (a.kind === "stateless" ? " (stateless)" : "")).join(" and ")},{" "}
                  {p.approvals.length} of 2{p.block ? `, block ${num(p.block)}` : ""}
                  {p.status === "expired" ? ". Another vault payment went first; propose it again." : ""}
                  {p.status === "failed" && p.error ? `. ${friendlyErr(p.error)}` : ""}
                </T>
                {p.status === "pending" && !mine ? <Btn title="Approve" onPress={() => approve(p.id)} busy={busy === p.id} style={{ marginTop: 10 }} /> : null}
                {p.status === "ready" || (p.status === "failed" && p.approvals.length >= 2) ? <Btn title="Send now" onPress={() => submit(p.id)} style={{ marginTop: 10 }} /> : null}
              </View>
            );
          })}
          {V.activity.length ? <Text style={{ fontWeight: "600", color: C.ink, marginTop: 18, marginBottom: 4 }}>Activity</Text> : null}
          {V.activity.slice(0, 10).map((r) => (
            <View key={r.txHash + r.direction} style={{ flexDirection: "row", justifyContent: "space-between", paddingVertical: 10, borderBottomWidth: 0.5, borderBottomColor: C.rule }}>
              <View><T>{describe(r).replace("Account created", "Vault created")}</T><T small muted>block {num(r.block)}</T></View>
              <T bold style={{ color: r.direction === "in" ? C.plus : C.ink }}>{r.direction === "in" ? "+" : "−"}{eth(r.wei)} ETH</T>
            </View>
          ))}
        </>
      ) : null}
    </Screen>
  );
}

export function Propose({ id }: { id: string }) {
  const w = useWallet();
  const [V, setV] = useState<VaultDetail | null>(null);
  const [to, setTo] = useState("");
  const [amount, setAmount] = useState("");
  const [toErr, setToErr] = useState("");
  const [amtErr, setAmtErr] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => { api<VaultDetail>("/api/vaults/" + id).then(setV).catch(() => {}); }, [id]);
  const opts = [...(w.S.account ? [{ name: "you", address: w.S.account.address }] : []),
    ...w.S.contacts.filter((c) => !V || !sameAddr(c.address, V.address))];

  async function submit() {
    const t = to.trim(), wei = ethToWei(amount);
    const te = isAddress(t) ? "" : "Enter a 0x address with 40 hex characters.";
    const ae = wei === null || wei <= 0n ? "Enter an amount such as 0.05." : "";
    setToErr(te); setAmtErr(ae);
    if (te || ae) return;
    setBusy(true);
    try {
      await api(`/api/vaults/${id}/propose`, { to: t, wei: wei!.toString() });
      w.replace({ name: "vault", id, msg: { text: "Proposed and approved by you. One more guardian must approve." } });
    } catch (e) { setAmtErr((e as Error).message); setBusy(false); }
  }
  return (
    <Screen>
      <H2>Propose a payment from {V ? V.name : "the vault"}</H2>
      <Field label="To" value={to} onChangeText={setTo} placeholder="0x…" autoCapitalize="none" error={toErr} style={s.mono} />
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, marginTop: -6, marginBottom: 18 }}>
        {opts.map((c) => <Chip key={c.address} title={c.name} addr={c.address} selected={sameAddr(c.address, to)} onPress={() => setTo(c.address)} />)}
      </View>
      <Field label="Amount (ETH)" value={amount} onChangeText={setAmount} placeholder="0.0" keyboardType="decimal-pad" error={amtErr}
        hint={`Vault balance: ${V ? eth(V.balanceWei) : "…"} ETH`} />
      <T small muted style={{ marginBottom: 16 }}>Your key approves it now. It is sent as soon as one more guardian approves in their own wallet.</T>
      <Btn title="Propose and approve" onPress={submit} busy={busy} />
    </Screen>
  );
}

export function NewVault() {
  const w = useWallet();
  const [name, setName] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const toggle = (x: string) => setPicked((p) => (p.includes(x) ? p.filter((y) => y !== x) : [...p, x].slice(-2)));
  async function create() {
    setBusy(true); setErr("");
    try {
      const v = await api<{ id: string }>("/api/vaults", { name: name.trim(), guardians: picked });
      await w.refresh();
      w.replace({ name: "vault", id: v.id, msg: { text: "Invitations sent. The vault is created once both accept." } });
    } catch (e) { setErr((e as Error).message); setBusy(false); }
  }
  const who = picked.length === 2 ? `You, ${cap(picked[0])} and ${cap(picked[1])}` : picked.length === 1 ? `You, ${cap(picked[0])} and one more person` : "You and the two people you choose";
  return (
    <Screen>
      <H2>Create a multisig vault</H2>
      <Field label="Vault name" value={name} onChangeText={setName} placeholder="Family savings" maxLength={40} />
      <T bold style={{ marginBottom: 8 }}>Choose two co-guardians</T>
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: 16 }}>
        {(w.S.wallets || []).map((x) => <Chip key={x} title={x} addr={hexOf(x)} selected={picked.includes(x)} onPress={() => toggle(x)} />)}
      </View>
      <T small muted style={{ marginBottom: 16 }}>{who} each hold one post-quantum key. Any two of the three must approve every payment from the vault. They are asked to accept first.</T>
      {err ? <T small style={{ color: C.bad, marginBottom: 12 }}>{err}</T> : null}
      <Btn title="Send invitations" onPress={create} disabled={picked.length !== 2} busy={busy} />
    </Screen>
  );
}
