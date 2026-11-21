import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import { Command } from "cmdk";
import type {
  DirectoryPage,
  Machine,
  MachineStatus,
  Worktree,
} from "./protocol";
import { api, setupMachine } from "./api";
import styles from "./Workbench.module.css";

export function RegisterWorktree({
  machine,
  initialPath,
  onClose,
  onRegistered,
}: {
  machine: Machine;
  initialPath: string;
  onClose: () => void;
  onRegistered: (worktree: Worktree) => void;
}) {
  const [path, setPath] = useState(initialPath);
  const [browsing, setBrowsing] = useState(!!machine.ssh);
  const [location, setLocation] = useState({ path: initialPath, offset: 0 });
  const [hidden, setHidden] = useState(false);
  const directories = useQuery({
    queryKey: ["directories", machine.id, location, hidden],
    queryFn: ({ signal }) =>
      api<DirectoryPage>(
        `machines/${machine.id}/directories?${new URLSearchParams({
          path: location.path,
          offset: String(location.offset),
          hidden: String(hidden),
        })}`,
        { signal },
      ),
    enabled: browsing,
    staleTime: 0,
  });
  const registration = useMutation({
    mutationFn: () =>
      api<Worktree>(`machines/${machine.id}/worktrees`, {
        method: "POST",
        body: JSON.stringify({ path }),
      }),
  });
  const nativePicker = useMutation({
    mutationFn: () =>
      api<string | null>("worktree-directory", { method: "POST" }),
    onSuccess: (chosen) => {
      if (chosen !== null) setPath(chosen);
    },
  });
  const busy = nativePicker.isPending || registration.isPending;
  const listing = directories.data;
  const machineName = machine.ssh?.destination ?? machine.host;

  function browseDirectory(directory: string) {
    if (browsing && location.path === directory && location.offset === 0)
      void directories.refetch();
    else setLocation({ path: directory, offset: 0 });
    setBrowsing(true);
  }

  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className={styles.overlay} />
        <Dialog.Content
          className={`${styles.dialog} ${styles.directoryDialog}`}
        >
          <Dialog.Title>Register a worktree on {machineName}</Dialog.Title>
          <Dialog.Description>
            Select a folder on{" "}
            <strong>
              {machine.account}@{machine.host}
            </strong>
            {machine.ssh && <> via {machine.ssh.destination}</>}. Registration
            enables source reads and annotation storage.
          </Dialog.Description>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              if (!busy)
                registration.mutate(undefined, { onSuccess: onRegistered });
            }}
          >
            <label htmlFor="worktree-path">Worktree directory</label>
            <div className={styles.directoryField}>
              <input
                id="worktree-path"
                value={path}
                onChange={(event) => setPath(event.target.value)}
                placeholder="/path/to/project"
                disabled={busy}
                required
              />
              <button
                type="button"
                disabled={busy || (!!machine.ssh && directories.isFetching)}
                onClick={() => {
                  registration.reset();
                  if (machine.ssh) browseDirectory(path);
                  else nativePicker.mutate();
                }}
              >
                {nativePicker.isPending
                  ? "Choosing…"
                  : machine.ssh && directories.isFetching
                    ? "Loading…"
                    : "Browse…"}
              </button>
            </div>
            {!machine.ssh && (
              <button
                type="button"
                className={styles.folderBrowserToggle}
                disabled={busy}
                onClick={() => browseDirectory(path)}
              >
                Browse folders in Tether
              </button>
            )}
            {nativePicker.isPending && (
              <p role="status">
                Choose or cancel in the native folder chooser.
              </p>
            )}
            {nativePicker.error && (
              <p role="alert">{nativePicker.error.message}</p>
            )}
            {browsing && (
              <section
                className={styles.folderBrowser}
                aria-label="Folders on selected machine"
                aria-busy={directories.isFetching}
              >
                <div className={styles.folderToolbar}>
                  <button type="button" onClick={() => browseDirectory("")}>
                    Home
                  </button>
                  <button
                    type="button"
                    disabled={!listing?.parent || directories.isFetching}
                    onClick={() => browseDirectory(listing!.parent!)}
                  >
                    Up
                  </button>
                  <button type="button" onClick={() => browseDirectory(path)}>
                    Go to path
                  </button>
                  <label>
                    <input
                      type="checkbox"
                      checked={hidden}
                      onChange={(event) => {
                        setHidden(event.target.checked);
                        setLocation({ ...location, offset: 0 });
                      }}
                    />{" "}
                    Hidden
                  </label>
                </div>
                <p className={styles.folderPath}>
                  {machine.account}@{machine.host}:{" "}
                  {listing?.path ?? (location.path || "Home")}
                </p>
                {directories.isFetching && (
                  <p className={styles.loading} role="status">
                    <span className={styles.spinner} aria-hidden="true" />
                    Loading folders on {machineName}…
                  </p>
                )}
                {directories.error && (
                  <p role="alert">
                    {directories.error.message}{" "}
                    <button
                      type="button"
                      onClick={() => void directories.refetch()}
                    >
                      Retry
                    </button>
                  </p>
                )}
                {listing && !directories.isFetching && !directories.error && (
                  <>
                    <div className={styles.folderList}>
                      {listing.entries.map((name) => (
                        <button
                          key={name}
                          type="button"
                          onClick={() =>
                            browseDirectory(`${listing.path}/${name}`)
                          }
                        >
                          ▸ {name}
                        </button>
                      ))}
                      {!listing.entries.length && (
                        <p>No folders in this view.</p>
                      )}
                    </div>
                    {listing.skipped > 0 && (
                      <p>{listing.skipped} unreadable entries skipped.</p>
                    )}
                    <div className={styles.folderToolbar}>
                      <button
                        type="button"
                        disabled={location.offset === 0}
                        onClick={() =>
                          setLocation({
                            ...location,
                            offset: Math.max(0, location.offset - 200),
                          })
                        }
                      >
                        Previous
                      </button>
                      <button
                        type="button"
                        disabled={listing.nextOffset === null}
                        onClick={() =>
                          setLocation({
                            ...location,
                            offset: listing.nextOffset!,
                          })
                        }
                      >
                        Next
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          setPath(listing.path);
                          setBrowsing(false);
                        }}
                      >
                        Use this folder
                      </button>
                    </div>
                  </>
                )}
              </section>
            )}
            {registration.error && (
              <p role="alert">{registration.error.message}</p>
            )}
            <div className={styles.actions}>
              <button type="button" disabled={busy} onClick={onClose}>
                Cancel
              </button>
              <button
                className={styles.primary}
                disabled={busy || !path.trim()}
              >
                {registration.isPending ? "Registering…" : "Register worktree"}
              </button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function MachineSetup({
  machines,
  update,
  inline = false,
  onClose,
  onConnected,
}: {
  machines: Machine[];
  update?: { machine: Machine; status: MachineStatus };
  inline?: boolean;
  onClose: () => void;
  onConnected: (machine: Machine) => void;
}) {
  const [hostChoice, setHostChoice] = useState(
    update?.machine.ssh?.destination ?? "",
  );
  const [hostSearch, setHostSearch] = useState("");
  const [hostInputFocused, setHostInputFocused] = useState(false);
  const [connectionProgress, setConnectionProgress] = useState("");
  const [connectionOutput, setConnectionOutput] = useState("");
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const outputPanel = useRef<HTMLPreElement>(null);
  const followOutput = useRef(true);
  const connectButton = useRef<HTMLButtonElement>(null);
  const destination = (hostChoice || hostSearch).trim();
  const alreadyRegistered =
    !update &&
    machines.some((machine) => machine.ssh?.destination === destination);
  const hosts = useQuery({
    queryKey: ["ssh-hosts"],
    queryFn: ({ signal }) => api<string[]>("ssh-hosts", { signal }),
    enabled: !update,
  });
  const connection = useMutation({
    mutationKey: ["machine-setup", update?.machine.id ?? destination],
    mutationFn: () => {
      setConnectionProgress("Connecting over SSH…");
      setConnectionOutput("");
      setElapsedSeconds(0);
      followOutput.current = true;
      return setupMachine(
        update ? `machines/${update.machine.id}/update` : "machines",
        update ? undefined : { destination },
        (event) => {
          if (event.type === "progress") setConnectionProgress(event.message);
          else
            setConnectionOutput((previous) =>
              (previous + event.text).slice(-32_768),
            );
        },
      );
    },
  });
  useEffect(() => {
    if (!connection.isPending) return;
    const startedAt = Date.now();
    const timer = window.setInterval(() => {
      setElapsedSeconds(Math.floor((Date.now() - startedAt) / 1000));
    }, 1000);
    return () => window.clearInterval(timer);
  }, [connection.isPending]);
  useEffect(() => {
    const panel = outputPanel.current;
    if (panel && followOutput.current) panel.scrollTop = panel.scrollHeight;
  }, [connectionOutput]);
  useEffect(() => {
    if (hostChoice) connectButton.current?.focus();
  }, [hostChoice]);

  const Title = inline ? "h3" : Dialog.Title;
  const Description = inline ? "p" : Dialog.Description;
  const content = (
    <>
      <Title>
        {update ? `Update Tether on ${destination}` : "Connect an SSH machine"}
      </Title>
      <Description>
        {update
          ? "Install this gateway's pinned Tether build on the selected machine. Worktrees and saved annotations are preserved."
          : "Uses your SSH configuration and trusted host keys. Connect installs missing Tether through Nix in your remote account's Tether directory."}
      </Description>
      {update && (
        <p className={styles.hint}>
          Installed: {update.status.installed?.version ?? "Missing"} ·{" "}
          {update.status.installed?.buildId?.slice(0, 12) ?? "build unknown"}
          <br />
          Target: {update.status.expected.version} ·{" "}
          {update.status.expected.buildId?.slice(0, 12)}
        </p>
      )}
      <form
        className={styles.connectionForm}
        onSubmit={(event) => {
          event.preventDefault();
          if (!destination || connection.isPending || alreadyRegistered) return;
          connection.mutate(undefined, { onSuccess: onConnected });
        }}
      >
        <div className={styles.connectionFields}>
          {!hostChoice ? (
            <>
              <p>SSH destination</p>
              <Command label="SSH destination" className={styles.hostPicker}>
                <Command.Input
                  asChild
                  autoFocus
                  onFocus={() => setHostInputFocused(true)}
                  onBlur={() => setHostInputFocused(false)}
                  value={hostSearch}
                  onValueChange={(value) => {
                    connection.reset();
                    setHostSearch(value);
                  }}
                  disabled={connection.isPending}
                  placeholder="SSH alias, hostname, IP or user@host"
                  aria-invalid={alreadyRegistered}
                  aria-describedby={
                    alreadyRegistered
                      ? "ssh-search-help ssh-registration-error"
                      : "ssh-search-help"
                  }
                >
                  <input aria-expanded={hostInputFocused} />
                </Command.Input>
                <Command.List
                  className={styles.hostList}
                  label="Configured SSH hosts"
                  hidden={!hostInputFocused}
                  onMouseDown={(event) => event.preventDefault()}
                >
                  {!!hosts.data?.length && (
                    <Command.Empty className={styles.hint}>
                      No configured hosts match this destination.
                    </Command.Empty>
                  )}
                  {hosts.data?.map((host) => {
                    const registered = machines.some(
                      (machine) => machine.ssh?.destination === host,
                    );
                    return (
                      <Command.Item
                        key={host}
                        value={host}
                        disabled={registered || connection.isPending}
                        className={styles.hostOption}
                        onSelect={() => {
                          connection.reset();
                          setHostChoice(host);
                        }}
                      >
                        {host}
                        {registered && <small>Already registered</small>}
                      </Command.Item>
                    );
                  })}
                </Command.List>
              </Command>
            </>
          ) : (
            <div className={styles.hostSelection}>
              <strong>{hostChoice}</strong>
              {!update && (
                <button
                  type="button"
                  disabled={connection.isPending}
                  onClick={() => {
                    connection.reset();
                    setHostSearch("");
                    setHostChoice("");
                  }}
                >
                  Change host
                </button>
              )}
            </div>
          )}
          <div className={hostChoice ? undefined : styles.hostDetails}>
            {!hostChoice && (
              <p
                id="ssh-search-help"
                className={styles.hint}
                hidden={connection.isPending || connection.isError}
              >
                Type a destination and choose Connect machine. Suggestions from
                ~/.ssh/config support fuzzy search. ↑/↓ and Enter select a
                suggested host.
              </p>
            )}
            {!update && hosts.isPending && (
              <p role="status">Loading configured hosts…</p>
            )}
            {!update && hosts.data?.length === 0 && (
              <p>No concrete Host aliases found in ~/.ssh/config.</p>
            )}
            {hosts.error && <p role="alert">{hosts.error.message}</p>}
            {hosts.error && (
              <button type="button" onClick={() => void hosts.refetch()}>
                Retry hosts
              </button>
            )}
            <p
              className={styles.hint}
              hidden={connection.isPending || connection.isError}
            >
              Automatic setup requires Nix on the remote machine and uses this
              gateway's pinned sources. First builds can take several minutes.
              Home Manager profiles stay unchanged.
            </p>
            {connection.isPending && (
              <>
                <p className={styles.loading} role="status">
                  <span className={styles.spinner} aria-hidden="true" />
                  {connectionProgress}
                </p>
                <p className={styles.hint}>
                  Elapsed {Math.floor(elapsedSeconds / 60)}m{" "}
                  {elapsedSeconds % 60}s. Nix can be quiet between output
                  messages.
                </p>
              </>
            )}
            {connection.error && (
              <p className={styles.error} role="alert">
                {connection.error.message}
              </p>
            )}
            {(connection.isPending || connection.isError) &&
              connectionOutput && (
                <>
                  <p className={styles.hint}>Latest installation output</p>
                  <pre
                    ref={outputPanel}
                    className={styles.installationOutput}
                    aria-label="Installation output"
                    tabIndex={0}
                    onScroll={(event) => {
                      const panel = event.currentTarget;
                      followOutput.current =
                        panel.scrollHeight -
                          panel.scrollTop -
                          panel.clientHeight <
                        24;
                    }}
                  >
                    {connectionOutput}
                  </pre>
                </>
              )}
            {alreadyRegistered && (
              <p
                id="ssh-registration-error"
                role="alert"
                className={styles.error}
              >
                This machine is already registered. Select it from Machines.
              </p>
            )}
          </div>
        </div>
        <div className={`${styles.actions} ${styles.connectionActions}`}>
          <button
            type="button"
            disabled={connection.isPending}
            onClick={onClose}
          >
            Cancel
          </button>
          <button
            ref={connectButton}
            className={styles.primary}
            disabled={connection.isPending || !destination || alreadyRegistered}
          >
            {connection.isPending
              ? update
                ? "Updating…"
                : "Connecting…"
              : update
                ? "Update machine"
                : "Connect machine"}
          </button>
        </div>
      </form>
    </>
  );

  if (inline) return <div className={styles.machineUpdate}>{content}</div>;

  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open && !connection.isPending) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className={styles.overlay} />
        <Dialog.Content
          className={`${styles.dialog} ${styles.directoryDialog} ${styles.connectionDialog}`}
        >
          {content}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
