import { useEffect, useRef } from "react";
import {
  useIsMutating,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { api } from "./api";
import type { Machine, MachineStatus, MachineUpdate } from "./protocol";
import styles from "./Workbench.module.css";

export function MachineVersion({
  machine,
  inline = false,
}: {
  machine: Machine;
  inline?: boolean;
}) {
  const client = useQueryClient();
  const outputPanel = useRef<HTMLPreElement>(null);
  const followOutput = useRef(true);
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
  const update = useQuery({
    queryKey: ["machine-update", machine.id],
    queryFn: ({ signal }) =>
      api<MachineUpdate | null>(`machines/${machine.id}/update`, { signal }),
    enabled: !!machine.ssh,
    refetchInterval: (query) => {
      const state = query.state.data?.state;
      return pendingUpdates > 0 ||
        state === "running" ||
        state === "cancelling" ||
        status.data?.updating
        ? 1000
        : 60_000;
    },
  });
  const progress = update.data;
  const updateState = progress?.state;
  const startUpdate = useMutation({
    mutationKey: ["machine-setup", machine.id],
    mutationFn: () =>
      api<Machine>(`machines/${machine.id}/update`, { method: "POST" }),
    onSettled: () => client.invalidateQueries(),
  });
  const cancel = useMutation({
    mutationFn: () =>
      api(`machines/${machine.id}/update/cancel`, { method: "POST" }),
    onSettled: () =>
      client.invalidateQueries({ queryKey: ["machine-update", machine.id] }),
  });
  useEffect(() => {
    if (
      updateState &&
      updateState !== "running" &&
      updateState !== "cancelling"
    ) {
      void client.invalidateQueries({
        queryKey: ["machine-status", machine.id],
      });
    }
  }, [client, machine.id, updateState]);
  useEffect(() => {
    const panel = outputPanel.current;
    if (panel && followOutput.current) panel.scrollTop = panel.scrollHeight;
  }, [progress?.output]);
  const name = machine.ssh?.destination ?? "Local machine";
  const build = status.data;
  const updating =
    pendingUpdates > 0 ||
    (progress
      ? progress.state === "running" || progress.state === "cancelling"
      : build?.updating);
  const current =
    !!build &&
    build.installed?.buildId === build.expected.buildId &&
    build.installed?.version === build.expected.version;
  let label = "Checking version…";
  if (progress?.state === "cancelling") label = "Cancelling…";
  else if (updating) label = "Updating…";
  else if (status.error) label = "Unavailable";
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
          onClick={() => {
            void status.refetch();
            if (machine.ssh) void update.refetch();
          }}
        >
          ↻
        </button>
        {updating && machine.ssh && (
          <button
            title="Cancel update"
            aria-label={`Cancel update on ${name}`}
            disabled={
              cancel.isPending || !progress || progress.state === "cancelling"
            }
            onClick={() => cancel.mutate()}
          >
            <span aria-hidden="true">■</span>
          </button>
        )}
        {startUpdate.error && (
          <span role="alert">{startUpdate.error.message}</span>
        )}
        {cancel.error && <span role="alert">{cancel.error.message}</span>}
        {build &&
          !current &&
          !status.error &&
          (build.canUpdate ? (
            <button
              disabled={updating}
              onClick={() => startUpdate.mutate()}
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
      {inline && (progress || updating) && (
        <details
          className={styles.machineUpdateLog}
          onToggle={(event) => {
            const panel = outputPanel.current;
            if (event.currentTarget.open && panel && followOutput.current) {
              panel.scrollTop = panel.scrollHeight;
            }
          }}
        >
          <summary>Update log</summary>
          {update.error ? (
            <p role="alert">
              Could not load update log: {update.error.message}
            </p>
          ) : (
            <>
              <p role="status">{progress?.message ?? "Loading update log…"}</p>
              <div className={styles.installationOutput}>
                <pre
                  ref={outputPanel}
                  aria-label={`Update output on ${name}`}
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
                  {progress?.output || "Waiting for installation output…"}
                </pre>
              </div>
            </>
          )}
        </details>
      )}
    </>
  );
}
