import type { AgentMessage } from "./server";

export type StreamEvt =
  | { t: "think"; c: string }
  | { t: "text"; c: string }
  | { t: "tools"; calls: NonNullable<AgentMessage["tool_calls"]> }
  | { t: "error"; e: string }
  | { t: "done" };