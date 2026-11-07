// Shared look: the same palette and identicons as the web wallet (app/wallet/index.html).
import React, { createContext, useContext } from "react";
import {
  ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View,
  type RefreshControlProps, type StyleProp, type TextInputProps, type TextStyle, type ViewStyle,
} from "react-native";
import Svg, { Path } from "react-native-svg";
import qrcode from "qrcode-generator";
import { avatarCells } from "./format";

export const C = {
  page: "#E6EBF1", panel: "#FFFFFF", ink: "#172131", slate: "#5D6B7E", rule: "#D5DCE5", soft: "#F3F6F9",
  plus: "#2F6F5E", warn: "#A86A12", bad: "#B4372F", acc: "#3B5BA9",
};
export const mono = Platform.select({ ios: "Menlo", default: "monospace" });

/** The account's accent colour (from its address), like the web wallet's top border and buttons. */
export const Accent = createContext(C.acc);
export const useAccent = () => useContext(Accent);

export function T({ style, muted, small, bold, center, children, selectable }: {
  style?: StyleProp<TextStyle>; muted?: boolean; small?: boolean; bold?: boolean; center?: boolean; selectable?: boolean;
  children?: React.ReactNode;
}) {
  return (
    <Text selectable={selectable} style={[s.t, muted && { color: C.slate }, small && { fontSize: 13, lineHeight: 18 },
      bold && { fontWeight: "600" }, center && { textAlign: "center" }, style]}>{children}</Text>
  );
}

export const H1 = ({ children, style }: { children: React.ReactNode; style?: StyleProp<TextStyle> }) =>
  <Text style={[s.h1, style]}>{children}</Text>;
export const H2 = ({ children, style }: { children: React.ReactNode; style?: StyleProp<TextStyle> }) =>
  <Text style={[s.h2, style]}>{children}</Text>;

export function Btn({ title, onPress, ghost, disabled, busy, style, danger }: {
  title: string; onPress?: () => void; ghost?: boolean; disabled?: boolean; busy?: boolean; danger?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  const acc = useAccent();
  const off = disabled || busy;
  return (
    <Pressable accessibilityRole="button" accessibilityState={{ disabled: !!off }} disabled={off} onPress={onPress}
      style={({ pressed }) => [s.btn, ghost ? { backgroundColor: C.panel, borderColor: C.rule } : { backgroundColor: danger ? C.bad : acc, borderColor: danger ? C.bad : acc },
        off && { opacity: 0.45 }, pressed && { opacity: 0.8 }, style]}>
      {busy ? <ActivityIndicator color={ghost ? C.ink : "#fff"} /> :
        <Text style={[s.btnText, { color: ghost ? (danger ? C.bad : C.ink) : "#fff" }]}>{title}</Text>}
    </Pressable>
  );
}

export function Field({ label, error, hint, right, ...p }: TextInputProps & { label: string; error?: string; hint?: string; right?: React.ReactNode }) {
  return (
    <View style={{ marginBottom: 16 }}>
      <Text style={s.label}>{label}</Text>
      <View style={{ flexDirection: "row", gap: 8 }}>
        <TextInput placeholderTextColor="#98A3B3" autoCorrect={false} spellCheck={false}
          {...p} style={[s.input, { flex: 1 }, p.style]} />
        {right}
      </View>
      {hint ? <T small muted style={{ marginTop: 6 }}>{hint}</T> : null}
      {error ? <T small style={{ color: C.bad, marginTop: 6 }}>{error}</T> : null}
    </View>
  );
}

export function Avatar({ addr, size = 40 }: { addr?: string | null; size?: number }) {
  const acc = useAccent();
  const cells = avatarCells(addr);
  const cell = size / 5;
  return (
    <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
      style={{ width: size, height: size, borderRadius: size / 4, overflow: "hidden", backgroundColor: C.soft, flexDirection: "row", flexWrap: "wrap" }}>
      {cells.map((on, i) => <View key={i} style={{ width: cell, height: cell, backgroundColor: on ? acc : "transparent" }} />)}
    </View>
  );
}

export function Qr({ text, size = 220 }: { text: string; size?: number }) {
  const q = qrcode(0, "M");
  q.addData(text);
  q.make();
  const n = q.getModuleCount();
  const quiet = 2;
  let d = "";
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) d += `M${c + quiet} ${r + quiet}h1v1h-1z`;
  return (
    <View accessibilityLabel="QR code" style={{ backgroundColor: "#fff", padding: 4, borderRadius: 8 }}>
      <Svg width={size} height={size} viewBox={`0 0 ${n + 2 * quiet} ${n + 2 * quiet}`}><Path d={d} fill={C.ink} /></Svg>
    </View>
  );
}

export function Screen({ children, refresh, pad = true, center }: {
  children: React.ReactNode; refresh?: React.ReactElement<RefreshControlProps>; pad?: boolean; center?: boolean;
}) {
  return (
    <ScrollView keyboardShouldPersistTaps="handled" refreshControl={refresh}
      contentContainerStyle={[pad && { padding: 20, paddingBottom: 32 }, center && { flexGrow: 1, justifyContent: "center" }]}>
      {children}
    </ScrollView>
  );
}

export const Note = ({ children, style }: { children: React.ReactNode; style?: StyleProp<ViewStyle> }) =>
  <View style={[s.note, style]}><T small muted>{children}</T></View>;

export const Msg = ({ text, bad }: { text: string; bad?: boolean }) =>
  <View style={[s.msg, bad && { borderColor: "#E9C4C1", backgroundColor: "#FBF0EF" }]}><T small style={bad ? { color: C.bad } : undefined}>{text}</T></View>;

export function Bar({ value }: { value: number }) {
  const acc = useAccent();
  return <View style={s.bar}><View style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%`, height: "100%", backgroundColor: acc }} /></View>;
}

export function Chip({ title, onPress, addr, selected }: { title: string; onPress: () => void; addr?: string; selected?: boolean }) {
  const acc = useAccent();
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityState={{ selected: !!selected }}
      style={[s.chip, selected && { borderColor: acc, backgroundColor: C.soft }]}>
      {addr ? <Avatar addr={addr} size={22} /> : null}
      <Text style={{ color: C.ink, fontSize: 14, textTransform: "capitalize" }}>{title}</Text>
    </Pressable>
  );
}

export const Row = ({ k, children }: { k: string; children: React.ReactNode }) => (
  <View style={s.row}><T muted style={{ width: 104 }}>{k}</T><View style={{ flex: 1, alignItems: "flex-end" }}>{children}</View></View>
);

export const s = StyleSheet.create({
  t: { color: C.ink, fontSize: 15, lineHeight: 21 },
  h1: { color: C.ink, fontSize: 18, fontWeight: "600", textTransform: "capitalize" },
  h2: { color: C.ink, fontSize: 20, fontWeight: "600", marginBottom: 14 },
  btn: { minHeight: 48, borderRadius: 12, borderWidth: 1, alignItems: "center", justifyContent: "center", paddingHorizontal: 16 },
  btnText: { fontSize: 16, fontWeight: "600" },
  label: { color: C.ink, fontWeight: "600", marginBottom: 8, fontSize: 15 },
  input: { minHeight: 48, borderWidth: 1, borderColor: C.rule, borderRadius: 10, paddingHorizontal: 12, fontSize: 16, color: C.ink, backgroundColor: C.panel },
  note: { marginTop: 18, padding: 12, backgroundColor: C.soft, borderRadius: 10 },
  msg: { padding: 12, borderRadius: 10, borderWidth: 1, borderColor: C.rule, backgroundColor: C.soft, marginBottom: 12 },
  bar: { height: 8, borderRadius: 4, backgroundColor: C.soft, overflow: "hidden", marginVertical: 8, borderWidth: 1, borderColor: C.rule },
  chip: { flexDirection: "row", alignItems: "center", gap: 8, paddingVertical: 8, paddingHorizontal: 12, borderRadius: 999, borderWidth: 1, borderColor: C.rule, backgroundColor: C.panel },
  row: { flexDirection: "row", paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: C.rule, gap: 12 },
  card: { backgroundColor: C.panel, borderRadius: 14, borderWidth: 1, borderColor: C.rule, padding: 16, marginBottom: 12 },
  mono: { fontFamily: mono, fontSize: 13 },
});
