import React, { useState } from "react";
import { View } from "react-native";
import { ApiError, api, normalizeCode, normalizeUrl, parsePairLink, saveConn, type Conn, type State } from "../api";
import { hexOf } from "../format";
import { Avatar, Btn, Field, H2, Note, Screen, T } from "../ui";
import Scan from "./Scan";

/** Pair this phone with a wallet: the wallet computer's URL (an ngrok tunnel to it) and its pairing code. */
export default function Connect({ initial, message, onConnected }: {
  initial?: Partial<Conn>; message?: string; onConnected: (c: Conn, s: State) => void;
}) {
  const [url, setUrl] = useState(initial?.url ?? "");
  const [code, setCode] = useState(initial?.code ?? "");
  const [err, setErr] = useState(message ?? "");
  const [busy, setBusy] = useState(false);
  const [scanning, setScanning] = useState(false);

  async function connect(c: Conn) {
    setBusy(true); setErr("");
    try {
      const s = await api<State>("/api/state", undefined, c);
      await saveConn(c);
      onConnected(c, s);
    } catch (e) {
      const x = e as ApiError;
      setErr(x.pair ? (x.status === 429 ? x.message : "That pairing code is not right for this wallet.")
        : x.offline ? `${x.message} Check the URL, that the tunnel (ngrok) is running, and that the wallet is started.`
        : x.message);
    } finally {
      setBusy(false);
    }
  }

  function submit() {
    const u = normalizeUrl(url), k = normalizeCode(code);
    if (!u) return setErr("Enter the wallet's URL, e.g. https://abcd-1234.ngrok-free.app");
    if (k.length !== 12) return setErr("Enter the 12-character pairing code, e.g. K7QM-P3XA-WN9D.");
    connect({ url: u, code: k });
  }

  if (scanning) {
    return <Scan hint="Scan the QR code from ./demo.sh tunnel or the wallet's Phone screen" onCancel={() => setScanning(false)}
      onData={(d) => {
        const c = parsePairLink(d);
        if (!c) return "That QR code is not a wallet pairing link.";
        setScanning(false); setUrl(c.url); setCode(c.code); connect(c);
        return null;
      }} />;
  }
  return (
    <Screen center>
      <View style={{ alignItems: "center", marginBottom: 18 }}>
        <Avatar addr={hexOf(url || "pq")} size={72} />
        <H2 style={{ marginTop: 14, marginBottom: 6 }}>Connect your wallet</H2>
        <T muted center>Scan the wallet's pairing QR code, or enter its URL and pairing code.</T>
      </View>
      <Btn title="Scan QR code" onPress={() => setScanning(true)} disabled={busy} style={{ marginBottom: 20 }} />
      <Field label="Wallet URL" value={url} onChangeText={setUrl} placeholder="https://abcd-1234.ngrok-free.app"
        autoCapitalize="none" keyboardType="url" textContentType="URL" />
      <Field label="Pairing code" value={code} onChangeText={setCode} placeholder="XXXX-XXXX-XXXX" autoCapitalize="characters"
        maxLength={20} onSubmitEditing={submit} returnKeyType="go" />
      {err ? <T small style={{ color: "#B4372F", marginBottom: 12 }}>{err}</T> : null}
      <Btn ghost title="Connect" onPress={submit} busy={busy} />
      <Note>This phone is only a screen. The wallet's three post-quantum keys and all signing stay on the wallet
        computer. Anyone with the URL and the pairing code can use the wallet, so keep the code to yourself.</Note>
    </Screen>
  );
}
