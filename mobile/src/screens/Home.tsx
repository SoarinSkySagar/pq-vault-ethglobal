import React, { useState } from "react";
import { Pressable, RefreshControl, StyleSheet, Text, View } from "react-native";
import * as Clipboard from "expo-clipboard";
import { cap, describe, eth, hexOf, num, short } from "../format";
import { HERE, useWallet } from "../store";
import { Avatar, Bar, Btn, C, H1, H2, Note, Screen, T, s, useAccent } from "../ui";

export function WalletTab() {
  const w = useWallet();
  const acc = useAccent();
  const a = w.S.account!;
  const [copied, setCopied] = useState(false);
  const [pulling, setPulling] = useState(false);
  const pull = async () => { setPulling(true); await w.refresh(); setPulling(false); };
  const faucet = () => w.push({ name: "job", job: { title: "Adding test ETH", path: "/api/faucet", body: {}, doneBig: "+1 ETH", doneText: "Test ETH added.", back: "home" } });

  return (
    <Screen refresh={<RefreshControl refreshing={pulling} onRefresh={pull} />}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
        <Avatar addr={a.address} />
        <View style={{ flex: 1 }}>
          <H1>{w.S.name}</H1>
          <Pressable accessibilityRole="button" accessibilityLabel="Copy address"
            onPress={async () => { await Clipboard.setStringAsync(a.address); setCopied(true); setTimeout(() => setCopied(false), 1500); }}>
            <Text style={[s.mono, { color: C.slate }]}>{copied ? "Copied" : `${short(a.address)}, copy`}</Text>
          </Pressable>
        </View>
      </View>
      <View style={{ alignItems: "center", marginVertical: 30 }}>
        <Text style={{ color: C.ink }}>
          <Text style={{ fontSize: 42, fontWeight: "600", letterSpacing: -0.5 }}>{eth(a.balanceWei)}</Text>
          <Text style={{ fontSize: 20, color: C.slate, fontWeight: "500" }}>  ETH</Text>
        </Text>
      </View>
      <View style={{ flexDirection: "row", justifyContent: "space-around", marginBottom: 26 }}>
        {([["↑", "Send", () => w.push({ name: "send" })], ["↓", "Receive", () => w.push({ name: "receive" })], ["+", "Add test ETH", faucet]] as const)
          .map(([icon, label, fn]) => (
            <Pressable key={label} onPress={fn} accessibilityRole="button" accessibilityLabel={label} style={{ alignItems: "center", gap: 8, minWidth: 84 }}>
              <View style={[st.circle, { backgroundColor: acc }]}><Text style={{ color: "#fff", fontSize: 22, fontWeight: "600" }}>{icon}</Text></View>
              <T small>{label}</T>
            </Pressable>
          ))}
      </View>
      <Text style={st.section}>Activity</Text>
      {!w.A.length ? <T muted style={{ paddingVertical: 16 }}>No activity yet. Add test ETH to get started.</T> : null}
      {w.A.slice(0, 30).map((r) => (
        <View key={r.txHash + r.direction} style={st.item}>
          <View style={{ flex: 1 }}>
            <T>{describe(r)}</T>
            <T small muted>block {num(r.block)} · {short(r.txHash)}</T>
          </View>
          <T bold style={{ color: r.direction === "in" ? C.plus : C.ink }}>{r.direction === "in" ? "+" : "−"}{eth(r.wei)} ETH</T>
        </View>
      ))}
    </Screen>
  );
}

export function KeysTab() {
  const { S } = useWallet();
  return (
    <Screen>
      <H2>Keys</H2>
      {S.keys.map((k) => (
        <View key={k.index} style={s.card}>
          <T bold>Key {k.index + 1}{k.renewals ? <T small muted>, renewed {k.renewals}×</T> : null}</T>
          <Bar value={k.remaining / k.leaves} />
          <T small muted>{k.remaining} of {k.leaves} signatures left before it renews itself</T>
        </View>
      ))}
      <Note>Your account is a smart contract guarded by three post-quantum keys stored {HERE}. Every payment is signed by
        two of them. Each key can sign {S.keys[0]?.leaves ?? 128} times, then renews automatically. There is no seed
        phrase and no ECDSA key.</Note>
    </Screen>
  );
}

function vaultState(v: { status: string; balanceWei: string | null; members: { joined: boolean }[] }) {
  if (v.status === "active") return `${eth(v.balanceWei)} ETH`;
  if (v.status === "deploying") return "Being created…";
  const joined = v.members.filter((m) => m.joined).length;
  return joined < 3 ? `${joined} of 3 joined` : "Ready to create";
}

export function VaultsTab() {
  const w = useWallet();
  const vs = w.S.vaults || [];
  const others = (w.S.wallets || []).length;
  return (
    <Screen refresh={<RefreshControl refreshing={false} onRefresh={w.refresh} />}>
      <H2>Shared vaults</H2>
      {vs.filter((v) => v.invited).map((v) => (
        <View key={v.id} style={[s.card, { borderColor: "#E6D3AE", backgroundColor: "#FFFBF2" }]}>
          <T><T bold>{cap(v.creator)}</T> invited you to guard <T bold>{v.name}</T>, a vault where any 2 of{" "}
            {v.members.map((m) => cap(m.wallet)).join(", ")} must approve each payment.</T>
          <View style={{ flexDirection: "row", gap: 10, marginTop: 12 }}>
            <Btn ghost title="View" onPress={() => w.push({ name: "vault", id: v.id })} style={{ flex: 1 }} />
            <Btn title="Accept" onPress={() => w.push({ name: "vault", id: v.id })} style={{ flex: 1 }} />
          </View>
        </View>
      ))}
      {vs.filter((v) => !v.invited).map((v) => (
        <Pressable key={v.id} onPress={() => w.push({ name: "vault", id: v.id })} accessibilityRole="button"
          style={({ pressed }) => [s.card, { flexDirection: "row", alignItems: "center", gap: 12 }, pressed && { backgroundColor: C.soft }]}>
          <Avatar addr={v.address || hexOf(v.id)} />
          <View style={{ flex: 1 }}>
            <T bold>{v.name}{v.awaitingMe ? <T small style={{ color: C.warn }}>  {v.awaitingMe} to approve</T> : null}</T>
            <T small muted>2 of 3: {v.members.map((m) => (m.me ? "you" : m.wallet)).join(", ")}</T>
          </View>
          <T small>{vaultState(v)}</T>
        </Pressable>
      ))}
      {!vs.length ? <T muted style={{ marginBottom: 16 }}>No shared vaults yet. A vault holds funds that any two of three people must approve to move.</T> : null}
      <Btn ghost title="Create a multisig vault" disabled={others < 2} onPress={() => w.push({ name: "newvault" })} style={{ marginTop: 6 }} />
      {others < 2 ? <Note>Start at least two other wallets on the wallet computer to create a vault with them.</Note> : null}
    </Screen>
  );
}

const st = StyleSheet.create({
  circle: { width: 52, height: 52, borderRadius: 26, alignItems: "center", justifyContent: "center" },
  section: { fontSize: 13, fontWeight: "600", color: C.slate, textTransform: "uppercase", letterSpacing: 0.6, marginBottom: 4 },
  item: { flexDirection: "row", alignItems: "center", paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: C.rule, gap: 12 },
});
