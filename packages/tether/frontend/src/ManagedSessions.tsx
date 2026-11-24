import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { api } from "./api";
import type { ManagedLaunch, ManagedSession } from "./protocol";
import { TerminalConnection } from "./TerminalConnection";
import styles from "./ManagedSessions.module.css";

export function ManagedSessions({ endpoint }: { endpoint: string }) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const recoveryKey = `tether:managed-launch:${endpoint}`;
  const [pending, setPending] = useState<ManagedLaunch | null>(() => {
    const saved = localStorage.getItem(recoveryKey);
    return saved ? JSON.parse(saved) : null;
  });
  const inventory = useQuery({
    queryKey: [endpoint, "managedSessions"],
    queryFn: ({ signal }) =>
      api<ManagedSession[]>(`${endpoint}/managedSessions`, { signal }),
    enabled: open,
    refetchInterval: open ? 5000 : false,
  });
  const session = inventory.data?.find((entry) => entry.launch.id === selected);

  async function launch() {
    if (
      !pending &&
      !window.confirm(
        "Start Amp in this worktree? It will keep running when you close this view.",
      )
    )
      return;
    setBusy(true);
    setError("");
    try {
      const input = pending ?? {
        id: crypto.randomUUID(),
        dimensions: { columns: 100, rows: 18 },
      };
      localStorage.setItem(recoveryKey, JSON.stringify(input));
      setPending(input);
      const created = await api<ManagedSession>(`${endpoint}/launchSession`, {
        method: "POST",
        body: JSON.stringify(input),
        signal: AbortSignal.timeout(15_000),
      });
      localStorage.removeItem(recoveryKey);
      setPending(null);
      setSelected(created.launch.id);
      await inventory.refetch();
    } catch (error) {
      setError(String(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={styles.panel} aria-label="Managed Amp sessions">
      <div className={styles.bar}>
        <button aria-expanded={open} onClick={() => setOpen(!open)}>
          Amp terminals {open ? "▾" : "▸"}
        </button>
        {open && (
          <>
            <select
              aria-label="Managed Amp session"
              value={selected}
              onChange={(event) => setSelected(event.target.value)}
            >
              <option value="">Choose a session</option>
              {inventory.data?.map((entry) => (
                <option key={entry.launch.id} value={entry.launch.id}>
                  Amp · {entry.launch.id.slice(0, 8)} · {entry.status}
                </option>
              ))}
            </select>
            <button disabled={busy} onClick={() => void launch()}>
              {pending ? "Check pending launch" : "Start Amp"}
            </button>
            <span>Execution-machine owned</span>
          </>
        )}
      </div>
      {open && (
        <>
          {(error || inventory.error) && (
            <p role="alert">{error || inventory.error?.message}</p>
          )}
          {pending && (
            <p>
              Launch outcome pending. Check the saved operation before starting
              another session.
            </p>
          )}
          {session?.detail && <p>{session.detail}</p>}
          {session?.runtime &&
            ["running", "exited"].includes(session.status) && (
              <ManagedTerminal
                key={session.launch.id}
                endpoint={endpoint}
                session={session}
              />
            )}
          {!session && (
            <p>
              Select a managed session or start Amp. Closing this view leaves
              agents running.
            </p>
          )}
        </>
      )}
    </section>
  );
}

function ManagedTerminal({
  endpoint,
  session,
}: {
  endpoint: string;
  session: ManagedSession;
}) {
  const element = useRef<HTMLDivElement>(null);
  const connection = useRef<TerminalConnection | null>(null);
  const [, redraw] = useState(0);
  const id = session.launch.id;
  const runtime = session.runtime!;

  useEffect(() => {
    const container = element.current!;
    const terminal = new Terminal({
      allowProposedApi: true,
      cols: 100,
      rows: 18,
      scrollback: 10000,
      fontSize: 13,
      fontFamily: "Menlo, Consolas, monospace",
      macOptionClickForcesSelection: true,
      disableStdin: true,
      theme: {
        background: "#111418",
        foreground: "#e0e5ed",
        selectionBackground: "#455782",
      },
    });
    terminal.open(container);
    const transport = new TerminalConnection(
      terminal,
      endpoint,
      id,
      runtime,
      () => redraw((value) => value + 1),
    );
    connection.current = transport;
    const input = terminal.onData((text) => transport.send(text));
    const canvas = document.createElement("canvas").getContext("2d")!;
    canvas.font = "13px Menlo, Consolas, monospace";
    const observer = new ResizeObserver(() => {
      const columns = Math.max(
        2,
        Math.min(
          512,
          Math.floor(
            (container.clientWidth - 20) / canvas.measureText("W").width,
          ),
        ),
      );
      transport.resize({ columns, rows: 18 });
    });
    observer.observe(container);
    transport.connect();
    return () => {
      observer.disconnect();
      input.dispose();
      transport.dispose();
      terminal.dispose();
      connection.current = null;
    };
  }, [endpoint, id, runtime]);

  const current = connection.current;
  const paused = current?.display.paused;
  const status = current?.error
    ? "Disconnected"
    : current?.exited
      ? "Exited"
      : paused
        ? "Paused for selection or scrollback"
        : current?.ready
          ? "Live · input enabled"
          : current?.connected && !current.control
            ? "Viewing · another client controls input"
            : "Recovering current state…";

  return (
    <>
      <div className={styles.bar}>
        <span role="status">{status}</span>
        {paused && (
          <button onClick={() => current?.resume()}>Resume live output</button>
        )}
        {current?.error && (
          <button
            disabled={!current.canReconnect}
            onClick={() => current.connect()}
          >
            Reconnect terminal
          </button>
        )}
        {current?.connected && !current.control && !current.exited && (
          <button
            onClick={() => {
              if (
                window.confirm(
                  "Take terminal input control from the other client?",
                )
              )
                current.takeControl();
            }}
          >
            Take control
          </button>
        )}
        <button
          disabled={!current?.ready}
          onClick={() => {
            if (window.confirm("Terminate this managed Amp process?"))
              current?.terminate();
          }}
        >
          Terminate Amp
        </button>
      </div>
      {current?.error && <p role="alert">{current.error}</p>}
      <div
        ref={element}
        className={styles.terminal}
        onKeyDown={(event) => event.stopPropagation()}
      />
    </>
  );
}
