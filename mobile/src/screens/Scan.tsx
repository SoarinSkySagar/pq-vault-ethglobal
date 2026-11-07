import React, { useRef, useState } from "react";
import { Linking, StyleSheet, View } from "react-native";
import { CameraView, useCameraPermissions } from "expo-camera";
import { Btn, C, Screen, T } from "../ui";

/** Full-screen QR scanner. onData returns null when the code is accepted, else an error to show. */
export default function Scan({ hint, onData, onCancel }: { hint: string; onData: (d: string) => string | null; onCancel: () => void }) {
  const [perm, ask] = useCameraPermissions();
  const [err, setErr] = useState("");
  const done = useRef(false);
  const last = useRef("");

  if (!perm) return <View style={{ flex: 1, backgroundColor: "#000" }} />;
  if (!perm.granted) {
    return (
      <Screen center>
        <T bold center style={{ fontSize: 18, marginBottom: 8 }}>Camera access</T>
        <T muted center style={{ marginBottom: 20 }}>The camera is only used to read QR codes.</T>
        {perm.canAskAgain
          ? <Btn title="Allow camera" onPress={ask} />
          : <Btn title="Open settings" onPress={() => Linking.openSettings()} />}
        <Btn ghost title="Cancel" onPress={onCancel} style={{ marginTop: 10 }} />
      </Screen>
    );
  }
  return (
    <View style={{ flex: 1, backgroundColor: "#000" }}>
      <CameraView style={StyleSheet.absoluteFill} facing="back" barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
        onBarcodeScanned={({ data }) => {
          if (done.current || data === last.current) return;
          last.current = data;
          const e = onData(data);
          if (e === null) done.current = true;
          else setErr(e);
        }} />
      <View style={st.frame} pointerEvents="none" />
      <View style={st.bottom}>
        <T center style={{ color: "#fff", marginBottom: 6 }}>{hint}</T>
        {err ? <T center small style={{ color: "#FFB4AE", marginBottom: 6 }}>{err}</T> : null}
        <Btn ghost title="Cancel" onPress={onCancel} style={{ marginTop: 8 }} />
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  frame: { position: "absolute", alignSelf: "center", top: "22%", width: 250, height: 250, borderWidth: 3, borderColor: "#fff", borderRadius: 18 },
  bottom: { position: "absolute", left: 0, right: 0, bottom: 0, padding: 24, paddingBottom: 40, backgroundColor: "rgba(23,33,49,0.82)", borderTopLeftRadius: 18, borderTopRightRadius: 18, borderColor: C.rule },
});
