import React, { useState } from "react";
import { Pressable, Share, Text, View } from "react-native";
import * as Clipboard from "expo-clipboard";
import { api, type Quote } from "../api";
import { addressFromQr, cap, eth, ethToWei, feeReasons, isAddress, num, sameAddr, short } from "../format";
import { useWallet } from "../store";
import { Avatar, Btn, C, Chip, Field, H2, Qr, Row, Screen, T, s } from "../ui";

export function Send({ to: initialTo }: { to?: string }) {
  const w = useWallet();
  const a = w.S.account!;
  const [to, setTo] = useState(initialTo ?? "");
  const [amount, setAmount] = useState("");
  const [toErr, setToErr] = useState("");
  const [amtErr, setAmtErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function max() {
    try { const q = await api<Quote>("/api/quote"); setAmount(eth(q.maxSendWei, 18).replace(/,/g, "")); } catch { /* ignore */ }
  }
  function scan() {
    w.push({ name: "scan", title: "Scan address", hint: "Scan a wallet address QR code", onData: (d) => {
      const addr = addressFromQr(d);
      if (!addr) return "No 0x address in that QR code.";
      setTo(addr); w.pop(); return null;
    } });
  }
  async function next() {
    const t = to.trim(), wei = ethToWei(amount);
    const te = !isAddress(t) ? "Enter a 0x address with 40 hex characters." : sameAddr(t, a.address) ? "That is your own address." : "";
    setToErr(te);
    setBusy(true);
    let q: Quote | null = null;
    try { q = await api<Quote>("/api/quote"); } catch { /* checked again by the wallet */ }
    setBusy(false);
    const ae = wei === null || wei <= 0n ? "Enter an amount such as 0.01."
      : q && wei > BigInt(q.maxSendWei) ? `You can send up to ${eth(q.maxSendWei, 6)} ETH (the rest covers the network fee).` : "";
    setAmtErr(ae);
    if (te || ae) return;
    w.push({ name: "review", to: t, amount: amount.trim(), quote: q });
  }

  return (
    <Screen>
      <H2>Send ETH</H2>
      <Field label="To" value={to} onChangeText={setTo} placeholder="0x…" autoCapitalize="none" error={toErr} style={s.mono}
        right={<Btn ghost title="Scan" onPress={scan} style={{ minHeight: 48, paddingHorizontal: 14 }} />} />
      {w.S.contacts.length ? (
        <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, marginTop: -6, marginBottom: 18 }}>
          {w.S.contacts.map((c) => <Chip key={c.address} title={c.name} addr={c.address} selected={sameAddr(c.address, to)} onPress={() => setTo(c.address)} />)}
        </View>
      ) : null}
      <Field label="Amount (ETH)" value={amount} onChangeText={setAmount} placeholder="0.0" keyboardType="decimal-pad" error={amtErr}
        hint={`Balance: ${eth(a.balanceWei)} ETH`} right={<Btn ghost title="Max" onPress={max} style={{ minHeight: 48, paddingHorizontal: 14 }} />} />
      <Btn title="Continue" onPress={next} busy={busy} />
    </Screen>
  );
}

export function Review({ to, amount, quote }: { to: string; amount: string; quote: Quote | null }) {
  const w = useWallet();
  const c = w.S.contacts.find((x) => sameAddr(x.address, to));
  const wei = ethToWei(amount)!;
  const why = feeReasons(quote);
  const confirm = () => w.replace({ name: "job", job: {
    title: "Sending", path: "/api/send", body: { to, wei: wei.toString() }, back: "home",
    doneBig: `−${eth(wei, 18)} ETH`, doneText: `Sent to ${c ? cap(c.name) : short(to)}.`,
  } });
  return (
    <Screen>
      <H2>Review</H2>
      <View style={[s.card, { paddingVertical: 4 }]}>
        <Row k="From"><T>{cap(w.S.name)}</T><T small muted style={s.mono}>{short(w.S.account!.address)}</T></Row>
        <Row k="To">{c ? <T>{cap(c.name)}</T> : null}<T small muted style={s.mono}>{short(to)}</T></Row>
        <Row k="Amount"><T bold>{eth(wei, 18)} ETH</T></Row>
        <View style={{ flexDirection: "row", paddingVertical: 12, gap: 12 }}>
          <T muted style={{ width: 104 }}>Network fee</T>
          <View style={{ flex: 1, alignItems: "flex-end" }}>
            <T>about {quote ? eth(quote.feeWei, 5) : "…"} ETH</T>
            {quote ? <T small muted style={{ textAlign: "right" }}>{num(quote.gas)} gas{why.length ? "; " + why.join("; ") : ""}</T> : null}
          </View>
        </View>
      </View>
      <T small muted style={{ marginVertical: 14 }}>Two of your three post-quantum keys will sign this payment on your wallet
        computer. The network checks both signatures before your account pays any fee.</T>
      <View style={{ flexDirection: "row", gap: 10 }}>
        <Btn ghost title="Cancel" onPress={() => w.reset()} style={{ flex: 1 }} />
        <Btn title="Confirm" onPress={confirm} style={{ flex: 1 }} />
      </View>
    </Screen>
  );
}

export function Receive() {
  const { S } = useWallet();
  const a = S.account!.address;
  const [copied, setCopied] = useState(false);
  return (
    <Screen>
      <View style={{ alignItems: "center" }}>
        <Avatar addr={a} size={56} />
        <H2 style={{ marginTop: 12, marginBottom: 4 }}>Receive ETH</H2>
        <T small muted center style={{ marginBottom: 18 }}>Share this address to receive ETH on chain {S.network.chainId}.</T>
        <Qr text={a} size={210} />
        <Pressable onLongPress={() => Clipboard.setStringAsync(a)} style={{ marginVertical: 18, paddingHorizontal: 8 }}>
          <Text selectable style={[s.mono, { fontSize: 15, textAlign: "center", color: C.ink, lineHeight: 22 }]}>
            {a.slice(2).match(/.{1,4}/g)!.map((g, i) => (i === 0 ? "0x" : "") + g).join(" ")}
          </Text>
        </Pressable>
      </View>
      <Btn title={copied ? "Copied" : "Copy address"} onPress={async () => { await Clipboard.setStringAsync(a); setCopied(true); setTimeout(() => setCopied(false), 1500); }} />
      <Btn ghost title="Share address" onPress={() => Share.share({ message: a, title: `${cap(S.name)}'s address` })} style={{ marginTop: 10 }} />
    </Screen>
  );
}
