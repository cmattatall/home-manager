import { useState } from "react";
import { useIsMutating, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import { MachineSetup } from "./RegisterWorktree";
import type { Machine, MachineStatus } from "./protocol";
import styles from "./Workbench.module.css";

export function MachineVersion({
  machine,
  inline = false,
}: {
  machine: Machine;
  inline?: boolean;
}) {
  const client = useQueryClient();
  const [open, setOpen] = useState(false);
  const pendingUpdates = useIsMutating({
    mutationKey: ["machine-setup", machine.id],
  });
  const status = useQuery({
    queryKey: ["machine-status", machine.id],
    queryFn: ({ signal }) =>
      api<MachineStatus>(`machines/${machine.id}/status`, { signal }),
    retry: false,
    staleTime: 30_000,
    refetchInterval: (query) => (query.state.data?.updating ? 2000 : 60_000),
  });
  const name = machine.ssh?.destination ?? "Local machine";
  const build = status.data;
  const updating = pendingUpdates > 0 || build?.updating;
  const current =
    !!build &&
    build.installed?.buildId === build.expected.buildId &&
    build.installed?.version === build.expected.version;
  let label = "Checking version…";
  if (status.error) label = "Unavailable";
  else if (updating) label = "Updating…";
  else if (build) label = current ? "Up to date" : "Update available";
  const detail =
    status.error?.message ??
    (build
      ? `Installed: ${build.installed?.version ?? "missing"} · ${build.installed?.buildId ?? "build unknown"}\nGateway: ${build.expected.version} · ${build.expected.buildId}`
      : "Checking the running Tether build");

  return (
    <>
      <div
        className={styles.machineVersion}
        aria-label={`Tether version on ${name}`}
      >
        <span
          title={detail}
          data-current={current && !status.error}
          role="status"
        >
          {label}
        </span>
        <button
          title={detail}
          aria-label={`Check version on ${name}`}
          disabled={status.isFetching}
          onClick={() => void status.refetch()}
        >
          ↻
        </button>
        {build &&
          !current &&
          !status.error &&
          (build.canUpdate ? (
            <button
              disabled={updating || open}
              onClick={() => setOpen(true)}
              aria-label={`Update Tether on ${name}`}
            >
              Update
            </button>
          ) : (
            <span title="Automatic updates require the Nix-packaged gateway">
              Installer required
            </span>
          ))}
      </div>
      {inline && updating && (
        <progress
          className={styles.machineUpdateProgress}
          aria-label={`Updating Tether on ${name}`}
        />
      )}
      {open && build && (
        <MachineSetup
          machines={[machine]}
          update={{ machine, status: build }}
          inline={inline}
          onClose={() => {
            setOpen(false);
            void status.refetch();
          }}
          onConnected={async () => {
            setOpen(false);
            await client.invalidateQueries();
          }}
        />
      )}
    </>
  );
}
