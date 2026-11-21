import type { ConnectionEvent, Machine, SshDestination } from "./protocol";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(`/api/${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...options?.headers },
  });
  const body = await response.json();
  if (!response.ok)
    throw new ApiError(response.status, body.error ?? response.statusText);
  return body as T;
}

export async function setupMachine(
  endpoint: string,
  input: SshDestination | undefined,
  onProgress: (
    event: Extract<ConnectionEvent, { type: "progress" | "output" }>,
  ) => void,
): Promise<Machine> {
  const response = await fetch(`/api/${endpoint}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/x-ndjson",
    },
    body: input ? JSON.stringify(input) : undefined,
  });
  if (!response.ok) {
    const body = await response.json();
    throw new ApiError(response.status, body.error ?? response.statusText);
  }
  if (!response.body) throw new Error("Connection progress is unavailable");
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let pending = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      pending += value;
      let newline = pending.indexOf("\n");
      while (newline !== -1) {
        const event: ConnectionEvent = JSON.parse(pending.slice(0, newline));
        pending = pending.slice(newline + 1);
        if (event.type === "connected") return event.machine;
        if (event.type === "error") throw new Error(event.message);
        onProgress(event);
        newline = pending.indexOf("\n");
      }
    }
    throw new Error(
      "Progress connection interrupted. Check the machine status before retrying setup.",
    );
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
