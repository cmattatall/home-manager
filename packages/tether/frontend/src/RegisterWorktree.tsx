import { useState } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import type { DirectoryPage, Machine, Worktree } from "./protocol";
import { api } from "./api";
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
          <Dialog.Title>Register a worktree</Dialog.Title>
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
                disabled={busy}
                onClick={() => {
                  registration.reset();
                  if (machine.ssh) {
                    setLocation({ path, offset: 0 });
                    setBrowsing(true);
                  } else nativePicker.mutate();
                }}
              >
                {nativePicker.isPending ? "Choosing…" : "Browse…"}
              </button>
            </div>
            {!machine.ssh && (
              <button
                type="button"
                className={styles.folderBrowserToggle}
                disabled={busy}
                onClick={() => {
                  setLocation({ path, offset: 0 });
                  setBrowsing(true);
                }}
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
              >
                <div className={styles.folderToolbar}>
                  <button
                    type="button"
                    onClick={() => setLocation({ path: "", offset: 0 })}
                  >
                    Home
                  </button>
                  <button
                    type="button"
                    disabled={!listing?.parent || directories.isFetching}
                    onClick={() =>
                      setLocation({ path: listing!.parent!, offset: 0 })
                    }
                  >
                    Up
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      if (location.path === path && location.offset === 0)
                        void directories.refetch();
                      else setLocation({ path, offset: 0 });
                    }}
                  >
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
                  <p role="status">Loading folders…</p>
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
                            setLocation({
                              path: `${listing.path}/${name}`,
                              offset: 0,
                            })
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

export function ConnectMachine({
  onClose,
  onConnected,
}: {
  onClose: () => void;
  onConnected: (machine: Machine) => void;
}) {
  const [hostChoice, setHostChoice] = useState("");
  const [customDestination, setCustomDestination] = useState("");
  const destination = hostChoice === "manual:" ? customDestination : hostChoice;
  const hosts = useQuery({
    queryKey: ["ssh-hosts"],
    queryFn: ({ signal }) => api<string[]>("ssh-hosts", { signal }),
  });
  const connection = useMutation({
    mutationFn: () =>
      api<Machine>("machines", {
        method: "POST",
        body: JSON.stringify({ destination }),
      }),
  });
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
          className={`${styles.dialog} ${styles.directoryDialog}`}
        >
          <Dialog.Title>Connect an SSH machine</Dialog.Title>
          <Dialog.Description>
            Uses your system SSH configuration and trusted host keys. Install
            this Tether release on the remote machine first.
          </Dialog.Description>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              connection.mutate(undefined, { onSuccess: onConnected });
            }}
          >
            <label htmlFor="ssh-host">Host from ~/.ssh/config</label>
            <select
              id="ssh-host"
              value={hostChoice}
              onChange={(event) => setHostChoice(event.target.value)}
              required
              disabled={connection.isPending}
            >
              <option value="">Choose an SSH host</option>
              {hosts.data?.map((host) => (
                <option key={host} value={host}>
                  {host}
                </option>
              ))}
              <option value="manual:">Enter another destination…</option>
            </select>
            {hosts.isPending && <p role="status">Loading configured hosts…</p>}
            {hosts.data?.length === 0 && (
              <p>No concrete Host aliases found in ~/.ssh/config.</p>
            )}
            {hosts.error && <p role="alert">{hosts.error.message}</p>}
            {hosts.error && (
              <button type="button" onClick={() => void hosts.refetch()}>
                Retry hosts
              </button>
            )}
            {hostChoice === "manual:" && (
              <>
                <label htmlFor="ssh-destination">SSH destination</label>
                <input
                  id="ssh-destination"
                  placeholder="user@host or SSH alias"
                  value={customDestination}
                  onChange={(event) => setCustomDestination(event.target.value)}
                  required
                  disabled={connection.isPending}
                />
              </>
            )}
            <p className={styles.hint}>
              Tether finds its installed executable on the remote host. Complete
              interactive SSH authentication in your terminal first.
            </p>
            {connection.error && <p role="alert">{connection.error.message}</p>}
            <div className={styles.actions}>
              <button
                type="button"
                disabled={connection.isPending}
                onClick={onClose}
              >
                Cancel
              </button>
              <button
                className={styles.primary}
                disabled={connection.isPending || !destination.trim()}
              >
                {connection.isPending ? "Connecting…" : "Connect machine"}
              </button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
