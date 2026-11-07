import React, { useEffect, useRef, useState } from "react";
import { ActivityIndicator, Text, View } from "react-native";
import { api, sleep, type Job as JobT, type JobEvent } from "../api";
import { num } from "../format";
import { useWallet, type JobSpec } from "../store";
import { Btn, C, H2, Screen, T, useAccent } from "../ui";

// Job events from the wallet server (pqv/server.py jobs, pqv/devnet.py), in words. Same wording as the web wallet.
const STEP: Record<string, (e: JobEvent) => string | null> = {
  log: (e) => /^keys:/.test(e.text || "") ? "Generating your three post-quantum keys"
    : /^account:/.test(e.text || "") ? "Creating your smart account on chain"
    : /^done:/.test(e.text || "") ? "Added 1 test ETH"
    : /^faucet:/.test(e.text || "") ? "Requesting test ETH from the devnet faucet"
    : /^vault: deploying/.test(e.text || "") ? "Creating the vault on chain" : null,
  renew: () => "Renewing a key that is almost used up",
  fallback: () => "A key is used up: signing with its backup key instead",
  signing: () => "Signing with two of your keys",
  simulated: (e) => (e.ok ? "Checked: the network will accept it" : "The network would reject this payment"),
  submitting: () => "Sent to the mempool, waiting for a block",
  included: (e) => `Confirmed in block ${num(e.block || 0)}`,
};

type Step = { text: string; err?: boolean };

export default function Job({ job }: { job: JobSpec }) {
  const w = useWallet();
  const acc = useAccent();
  const [steps, setSteps] = useState<Step[]>([{ text: job.first || "Starting…" }]);
  const [state, setState] = useState<"running" | "done" | "error">("running");
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    let alive = true;
    w.setBusy(true);
    (async () => {
      let id = job.jobId;
      if (!id) {
        try { id = (await api<{ job: string }>(job.path!, job.body || {})).job; } catch (e) {
          if (alive) { setSteps([{ text: (e as Error).message, err: true }]); setState("error"); }
          w.setBusy(false); return;
        }
      }
      for (let misses = 0; alive;) {
        await sleep(900);
        let j: JobT;
        try { j = await api<JobT>("/api/jobs/" + id); misses = 0; } catch (e) {
          if (++misses > 30) { setSteps((p) => [...p, { text: "Lost the connection to the wallet. Check Activity once it is back.", err: true }]); setState("error"); break; }
          continue;
        }
        const out: Step[] = job.first && job.jobId ? [{ text: job.first }] : [];
        for (const e of j.events) {
          const f = STEP[e.type]; const t = f && f(e);
          if (t && (!out.length || out[out.length - 1].text !== t)) out.push({ text: t });
        }
        if (j.state === "error") out.push({ text: j.error || "Failed.", err: true });
        if (!alive) break;
        setSteps(out.length ? out : [{ text: "Working…" }]);
        setState(j.state);
        if (j.state !== "running") break;
      }
      w.setBusy(false);
      w.refresh();
    })();
    return () => { alive = false; };
  }, []);

  const back = () => job.back === "vault" && job.vaultId ? w.reset({ name: "vault", id: job.vaultId }) : w.reset();
  return (
    <Screen>
      <H2>{job.title}</H2>
      <View accessibilityLiveRegion="polite" style={{ gap: 12, marginVertical: 8 }}>
        {steps.map((st, i) => {
          const now = i === steps.length - 1 && state === "running" && !st.err;
          return (
            <View key={i} style={{ flexDirection: "row", gap: 12, alignItems: "flex-start" }}>
              <View style={{ width: 22, alignItems: "center", paddingTop: 1 }}>
                {now ? <ActivityIndicator size="small" color={acc} />
                  : <Text style={{ color: st.err ? C.bad : C.plus, fontWeight: "700", fontSize: 16 }}>{st.err ? "✕" : "✓"}</Text>}
              </View>
              <T style={[{ flex: 1 }, st.err && { color: C.bad }, !now && !st.err && { color: C.slate }]}>{st.text}</T>
            </View>
          );
        })}
      </View>
      {state === "done" ? (
        <View style={{ alignItems: "center", marginVertical: 26 }}>
          {job.doneBig ? <Text style={{ fontSize: 34, fontWeight: "600", color: C.ink }}>{job.doneBig}</Text> : null}
          <T muted style={{ marginTop: 6 }}>{job.doneText}</T>
        </View>
      ) : null}
      {state !== "running" ? <Btn title={job.back === "vault" ? "Back to the vault" : "Back to wallet"} ghost={state === "error"} onPress={back} style={{ marginTop: 12 }} /> : null}
    </Screen>
  );
}
