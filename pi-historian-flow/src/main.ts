/**
 * pi-historian-flow/src/main.ts
 *
 * Pure message router for the tedge-flows JS runtime.
 * All PI Web API logic lives in scripts/poll-pi.sh; that script outputs lines
 * in the format:   TOPIC<TAB>JSON_PAYLOAD
 * onMessage splits each line on the tab and re-emits it on the correct topic.
 */

export interface Message {
  time: Date;
  topic: string;
  payload: string | Uint8Array;
}

interface FlowStore {
  get<T = unknown>(key: string): T | undefined;
  set<T = unknown>(key: string, value: T): void;
}

interface FlowContext {
  config: Record<string, unknown>;
  flow: FlowStore;
}

const decoder = new TextDecoder();

export function onMessage(message: Message, _context: FlowContext): Message[] {
  const line =
    typeof message.payload === "string"
      ? message.payload
      : decoder.decode(message.payload);

  const tab = line.indexOf("\t");
  if (tab < 0) return [];

  return [{
    time:    message.time,
    topic:   line.slice(0, tab),
    payload: line.slice(tab + 1),
  }];
}

// No-ops — scheduling is handled by [input.process] interval in flows.toml
export function onStartup(): Message[] { return []; }
export function onInterval(): Message[] { return []; }
