// App-wide state: the wallet's /api/state + activity, the connection, and a small navigation stack.
import { createContext, useContext } from "react";
import type { Activity, Conn, Quote, State } from "./api";

export type JobSpec = {
  title: string;
  path?: string;          // POST that starts the job ...
  body?: object;
  jobId?: string;         // ... or an already started job (vault approval that completed the 2 of 3)
  first?: string;         // first step shown while it starts
  doneBig?: string;       // e.g. "−0.01 ETH"
  doneText: string;
  back: "home" | "vault";
  vaultId?: string;
};

export type Route =
  | { name: "home" }
  | { name: "send"; to?: string }
  | { name: "review"; to: string; amount: string; quote: Quote | null }
  | { name: "receive" }
  | { name: "job"; job: JobSpec }
  | { name: "vault"; id: string; msg?: { text: string; bad?: boolean } }
  | { name: "propose"; id: string }
  | { name: "newvault" }
  | { name: "settings" }
  | { name: "scan"; title: string; hint: string; onData: (data: string) => string | null }; // null = accepted, else an error

export type Tab = "wallet" | "vaults" | "keys";

export type Ctx = {
  S: State;
  A: Activity[];
  conn: Conn;
  refresh: () => Promise<void>;
  push: (r: Route) => void;
  pop: () => void;
  replace: (r: Route) => void;
  reset: (r?: Route) => void;
  tab: Tab;
  setTab: (t: Tab) => void;
  setBusy: (b: boolean) => void;
  disconnect: () => Promise<void>;
  /** Point the app at a new URL for the same wallet (a restarted ngrok tunnel gets a new one); checks it first. */
  moveTo: (url: string) => Promise<void>;
};

export const WalletCtx = createContext<Ctx | null>(null);
export function useWallet(): Ctx {
  const c = useContext(WalletCtx);
  if (!c) throw new Error("useWallet outside the wallet");
  return c;
}

/** Where the keys are, in words: always the wallet computer for this app. */
export const HERE = "on your wallet computer, not on this phone";
