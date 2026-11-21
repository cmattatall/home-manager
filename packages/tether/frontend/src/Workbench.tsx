import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useLocation } from "react-router";
import type {
  Annotation,
  ChangedFile,
  Comparison,
  Machine,
  Scope,
  Session,
  Source,
  Worktree,
} from "./protocol";
import { api } from "./api";
import {
  deleteRecovery,
  expiresAfterThreeMonths,
  recoveryDrafts,
  saveRecovery,
  type RecoveryDraft,
} from "./recovery";
import { SourceViewer, type SourceSelection } from "./SourceViewer";
import { SignOut } from "./SignOut";
import { ConnectMachine, RegisterWorktree } from "./RegisterWorktree";
import styles from "./Workbench.module.css";

export function Workbench({
  loginError,
  registrationCandidate,
}: {
  loginError?: string;
  registrationCandidate: string;
}) {
  const client = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  const segments = location.pathname.split("/");
  const machineId =
    segments[1] === "machines"
      ? segments[2]
      : segments[1] === "worktrees"
        ? "local"
        : "";
  const selectedId =
    segments[1] === "machines" ? (segments[4] ?? "") : (segments[2] ?? "");
  const worktreeBase =
    machineId === "local" ? "/worktrees" : `/machines/${machineId}/worktrees`;
  const session = useQuery({
    queryKey: ["session"],
    queryFn: () => api<Session>("session"),
    refetchInterval: 30_000,
  });
  const inventory = useQuery({
    queryKey: ["worktrees", machineId],
    queryFn: ({ signal }) =>
      api<Worktree[]>(`machines/${machineId}/worktrees`, { signal }),
    enabled: !!session.data && !!machineId,
  });
  const machines = useQuery({
    queryKey: ["machines"],
    queryFn: () => api<Machine[]>("machines"),
    enabled: !!session.data,
  });
  const machine = machines.data?.find((entry) => entry.id === machineId);
  const [connectionOpen, setConnectionOpen] = useState(false);
  const worktree = inventory.data?.find((entry) => entry.id === selectedId);
  const [registrationOpen, setRegistrationOpen] = useState(false);

  if (session.isPending)
    return (
      <main className={styles.welcome}>
        <h1>Tether</h1>
        <p>Connecting to your gateway…</p>
      </main>
    );
  if (session.error || !session.data)
    return (
      <main className={styles.welcome}>
        <span className={styles.eyebrow}>YOUR LOCAL WORKBENCH</span>
        <h1>Tether</h1>
        <p>
          {loginError ??
            session.error?.message ??
            "Authorize this browser to continue."}
        </p>
        <p>
          Run <code>tether</code> on this machine to open a new login link.
        </p>
      </main>
    );

  return (
    <div className={styles.app}>
      <header className={styles.header}>
        <strong className={styles.brand}>
          tether<span> / </span>
        </strong>
        <span className={styles.breadcrumb}>
          {machine
            ? `${machine.account}@${machine.host} / ${worktree?.name ?? "Worktrees"}`
            : "Machines"}
        </span>
        <select
          className={styles.machineSelector}
          aria-label="Selected machine"
          value={machineId}
          onChange={(event) => {
            setRegistrationOpen(false);
            navigate(
              event.target.value ? `/machines/${event.target.value}/` : "/",
            );
          }}
        >
          <option value="">Choose a machine</option>
          {machines.data?.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {entry.ssh?.destination ?? "Local machine"}
            </option>
          ))}
        </select>
        <button
          disabled={!machines.data}
          onClick={() => setConnectionOpen(true)}
        >
          Connect machine
        </button>
        <select
          className={styles.compactWorktree}
          aria-label="Selected worktree"
          value={selectedId}
          disabled={!machine}
          onChange={(event) =>
            navigate(
              event.target.value
                ? `${worktreeBase}/${event.target.value}`
                : `/machines/${machineId}/`,
            )
          }
        >
          <option value="">Choose a worktree</option>
          {inventory.data?.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {entry.name}
            </option>
          ))}
        </select>
        <span className={styles.stage}>Preview · {session.data.version}</span>
        <SignOut owner={session.data.owner} />
      </header>
      <div className={styles.workspace}>
        <nav className={styles.rail} aria-label="Primary navigation">
          <button title="Machines" onClick={() => navigate("/")}>
            ▦
          </button>
          {machine && (
            <button
              title="Worktrees"
              onClick={() => navigate(`/machines/${machineId}/`)}
            >
              ⑂
            </button>
          )}
        </nav>
        {selectedId && (
          <aside className={styles.sidebar}>
            <div className={styles.sectionTitle}>
              <span>WORKTREES</span>
              <button
                aria-label="Register worktree"
                disabled={!machine}
                onClick={() => setRegistrationOpen(true)}
              >
                +
              </button>
            </div>
            <p className={styles.machine}>
              {machine?.ssh?.destination ?? "This machine"}
            </p>
            {inventory.data?.map((entry) => (
              <button
                key={entry.id}
                className={`${styles.worktree} ${entry.id === selectedId ? styles.active : ""}`}
                onClick={() => navigate(`${worktreeBase}/${entry.id}`)}
                title={entry.path}
              >
                <span>⑂ {entry.name}</span>
                <small>{entry.path}</small>
              </button>
            ))}
            {inventory.error && <p role="alert">{inventory.error.message}</p>}
            {machines.error && <p role="alert">{machines.error.message}</p>}
            {inventory.error && (
              <button onClick={() => void inventory.refetch()}>
                Retry connection
              </button>
            )}
            <div className={styles.sidebarFoot}>
              {machine?.account}@{machine?.host}
              <br />
              Source evidence stays on the owning machine
            </div>
          </aside>
        )}
        {worktree ? (
          <Review
            key={`${machineId}:${worktree.id}`}
            worktree={worktree}
            machineId={machineId}
            owner={session.data.owner}
          />
        ) : (
          <main className={styles.welcome}>
            <span className={styles.eyebrow}>
              {machineId ? "2 · WORKTREE" : "1 · MACHINE"}
            </span>
            <h1>{machineId ? "Choose a worktree" : "Choose a machine"}</h1>
            {machineId ? (
              <>
                <p>
                  {machine?.ssh?.destination ?? machine?.host} · Worktrees on
                  this machine
                </p>
                {inventory.isPending && <p role="status">Loading worktrees…</p>}
                {inventory.error && (
                  <p role="alert">{inventory.error.message}</p>
                )}
                {inventory.error && (
                  <button onClick={() => void inventory.refetch()}>
                    Retry connection
                  </button>
                )}
                <div className={styles.selectionList}>
                  {inventory.data?.map((entry) => (
                    <button
                      key={entry.id}
                      className={styles.selection}
                      onClick={() => navigate(`${worktreeBase}/${entry.id}`)}
                    >
                      <strong>{entry.name}</strong>
                      <small>{entry.path}</small>
                    </button>
                  ))}
                </div>
                {inventory.data?.length === 0 && (
                  <p>No worktrees registered on this machine.</p>
                )}
                <button
                  className={styles.primary}
                  disabled={!machine}
                  onClick={() => setRegistrationOpen(true)}
                >
                  Register a worktree
                </button>
              </>
            ) : (
              <>
                <p>
                  Select the machine running your agents to browse its
                  worktrees.
                </p>
                {machines.isPending && <p role="status">Loading machines…</p>}
                {machines.error && <p role="alert">{machines.error.message}</p>}
                {machines.error && (
                  <button onClick={() => void machines.refetch()}>
                    Retry machines
                  </button>
                )}
                <div className={styles.selectionList}>
                  {machines.data?.map((entry) => (
                    <button
                      key={entry.id}
                      className={styles.selection}
                      onClick={() => navigate(`/machines/${entry.id}/`)}
                    >
                      <strong>
                        {entry.ssh?.destination ?? "Local machine"}
                      </strong>
                      <small>
                        {entry.account}@{entry.host} ·{" "}
                        {entry.ssh ? "SSH" : "Local"}
                      </small>
                    </button>
                  ))}
                </div>
                <p className={styles.hint}>
                  Use Connect machine to add an SSH destination.
                </p>
              </>
            )}
          </main>
        )}
      </div>
      <footer className={styles.status}>
        <span>
          {machine
            ? `● Machine: ${machine.ssh?.destination ?? "local"}`
            : "Choose a machine to begin"}
        </span>
        <span>Authenticated gateway · {window.location.host}</span>
      </footer>
      {registrationOpen && machine && (
        <RegisterWorktree
          key={machine.id}
          machine={machine}
          initialPath={machineId === "local" ? registrationCandidate : ""}
          onClose={() => setRegistrationOpen(false)}
          onRegistered={async (worktree) => {
            await client.invalidateQueries({
              queryKey: ["worktrees", machineId],
            });
            setRegistrationOpen(false);
            navigate(`${worktreeBase}/${worktree.id}`);
          }}
        />
      )}
      {connectionOpen && machines.data && (
        <ConnectMachine
          machines={machines.data}
          onClose={() => setConnectionOpen(false)}
          onConnected={async (connected) => {
            await client.invalidateQueries({ queryKey: ["machines"] });
            setConnectionOpen(false);
            navigate(`/machines/${connected.id}/`);
          }}
        />
      )}
    </div>
  );
}

function Review({
  worktree,
  owner,
  machineId,
}: {
  worktree: Worktree;
  owner: string;
  machineId: string;
}) {
  const client = useQueryClient();
  const endpoint =
    machineId === "local"
      ? `worktrees/${worktree.id}`
      : `machines/${machineId}/worktrees/${worktree.id}`;
  const worktreeKey =
    machineId === "local" ? worktree.id : `${machineId}:${worktree.id}`;
  const [scope, setScope] = useState<Scope | "source">("uncommitted");
  const changes = useQuery({
    queryKey: [worktreeKey, "changes", scope],
    queryFn: ({ signal }) =>
      api<ChangedFile[]>(`${endpoint}/changes?scope=${scope}`, { signal }),
    enabled: scope !== "source",
    refetchInterval: 5000,
  });
  const files = useQuery({
    queryKey: [worktreeKey, "files"],
    queryFn: () => api<string[]>(`${endpoint}/files`),
  });
  const annotations = useQuery({
    queryKey: [worktreeKey, "annotations"],
    queryFn: () => api<Annotation[]>(`${endpoint}/annotations`),
  });
  const sourcePreference = `tether:${owner}:${worktreeKey}:source`;
  const [path, setPath] = useState(
    () => sessionStorage.getItem(sourcePreference) ?? "",
  );
  useEffect(() => {
    sessionStorage.setItem(sourcePreference, path);
  }, [sourcePreference, path]);
  const [selection, setSelection] = useState<SourceSelection | null>(null);
  const [draft, setDraft] = useState<RecoveryDraft | null>(null);
  const [explorationComparison, setExplorationComparison] =
    useState<Comparison>();
  const [recovery, setRecovery] = useState<RecoveryDraft[]>([]);
  const [message, setMessage] = useState("");
  const [filter, setFilter] = useState("");
  const mounted = useRef(true);
  const source = useQuery({
    queryKey: [worktreeKey, "source", path],
    queryFn: ({ signal }) =>
      api<Source>(`${endpoint}/source?${new URLSearchParams({ path })}`, {
        signal,
      }),
    enabled: !!path && scope === "source",
    staleTime: Infinity,
  });
  const comparison = useQuery({
    queryKey: [worktreeKey, "comparison", scope, path],
    queryFn: ({ signal }) =>
      api<Comparison>(
        `${endpoint}/comparison?${new URLSearchParams({ path, scope })}`,
        { signal },
      ),
    enabled:
      !!path &&
      scope !== "source" &&
      !!changes.data?.some((file) => file.path === path),
    refetchInterval: draft || explorationComparison ? false : 5000,
    refetchOnWindowFocus: !draft && !explorationComparison,
  });
  const activeComparison =
    scope !== "source" && changes.data?.some((file) => file.path === path)
      ? comparison.data
      : undefined;
  const visibleComparison =
    draft?.comparison ?? explorationComparison ?? activeComparison;

  useEffect(() => {
    mounted.current = true;
    void recoveryDrafts(owner, worktree.id, machineId)
      .then((drafts) => {
        if (mounted.current) setRecovery(drafts);
      })
      .catch((error) =>
        setMessage(`Browser recovery unavailable: ${error.message}`),
      );
    return () => {
      mounted.current = false;
    };
  }, [owner, worktree.id, machineId]);

  const save = useMutation({
    mutationFn: async (submitted: RecoveryDraft) => {
      const pending: RecoveryDraft = { ...submitted, submission: "pending" };
      setDraft(pending);
      await saveRecovery(pending);
      return api<Annotation>(`${endpoint}/annotations`, {
        method: "POST",
        body: JSON.stringify(submitted.input),
      });
    },
    onSuccess: async (_, submitted) => {
      await deleteRecovery(submitted.input.id);
      await client.invalidateQueries({
        queryKey: [worktreeKey, "annotations"],
      });
      if (mounted.current) {
        setDraft(null);
        setMessage("Annotation saved to the worktree service");
      }
    },
  });

  function updateDraft(next: RecoveryDraft) {
    setDraft(next);
    setMessage("Saving recovery copy…");
    void saveRecovery(next)
      .then(() => {
        if (mounted.current)
          setMessage(
            "Saved in this browser · awaiting explicit Save annotation",
          );
      })
      .catch((error) => {
        if (mounted.current) setMessage(`Recovery failed: ${error.message}`);
      });
  }

  function beginAnnotation(selection: SourceSelection | null) {
    if (draft || !selection) return;
    updateDraft({
      owner,
      worktree: worktree.id,
      machine: machineId,
      source: selection.source,
      comparison: selection.review ? activeComparison : undefined,
      submission: "editing",
      expiresAt: expiresAfterThreeMonths(),
      input: {
        id: crypto.randomUUID(),
        sourceId: selection.source.id,
        path: selection.source.path,
        selection: selection.selection,
        review: selection.review,
        text: "",
      },
    });
  }

  const displayed =
    draft?.source ??
    (scope === "source"
      ? source.data
      : (visibleComparison?.after ?? visibleComparison?.before));
  const error =
    files.error ??
    changes.error ??
    (scope === "source" ? source.error : comparison.error) ??
    annotations.error ??
    save.error;
  const listed =
    scope === "source"
      ? files.data?.map((path) => ({ path, status: "" }))
      : changes.data;
  const fileListing = scope === "source" ? files : changes;
  return (
    <main className={styles.review}>
      <aside className={styles.files}>
        <div className={styles.sectionTitle}>
          {scope === "source" ? "SOURCE FILES" : "CHANGES"}{" "}
          <span>{listed?.length ?? "…"}</span>
        </div>
        <select
          aria-label="Comparison scope"
          value={scope}
          disabled={!!draft}
          onChange={(event) => {
            setScope(event.target.value as Scope | "source");
            setPath("");
            setExplorationComparison(undefined);
            setSelection(null);
          }}
        >
          <option value="uncommitted">Uncommitted</option>
          <option value="staged">Staged</option>
          <option value="unstaged">Unstaged</option>
          <option value="source">All source</option>
        </select>
        <input
          aria-label="Filter files"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
          placeholder="Filter paths…"
        />
        <div className={styles.loading} role="status">
          {fileListing.isFetching && (
            <>
              <span className={styles.spinner} aria-hidden="true" />
              {fileListing.isPending ? "Loading files…" : "Refreshing files…"}
            </>
          )}
        </div>
        <div className={styles.fileList} aria-busy={fileListing.isFetching}>
          {listed
            ?.filter((file) =>
              file.path.toLowerCase().includes(filter.toLowerCase()),
            )
            .map((file) => (
              <button
                key={file.path}
                disabled={!!draft}
                className={path === file.path ? styles.active : ""}
                onClick={() => {
                  setPath(file.path);
                  setExplorationComparison(undefined);
                  setSelection(null);
                }}
              >
                {file.status && (
                  <span className={styles.fileStatus}>{file.status}</span>
                )}{" "}
                {file.path}
              </button>
            ))}
        </div>
      </aside>
      <section className={styles.sourcePane}>
        <div className={styles.toolbar}>
          <span className={styles.sourcePath}>
            {displayed?.path ?? "Choose a source file"}
          </span>
          <button
            onClick={() => {
              setSelection(null);
              if (scope === "source") void source.refetch();
              else {
                void changes.refetch();
                void comparison.refetch();
              }
            }}
            disabled={!path || !!draft}
          >
            Refresh
          </button>
          <button
            className={styles.primary}
            disabled={!selection || !!draft}
            onClick={() => beginAnnotation(selection)}
          >
            Annotate selection
          </button>
        </div>
        {error && (
          <p className={styles.error} role="alert">
            {error.message}
          </p>
        )}
        {displayed ? (
          <SourceViewer
            worktree={worktreeKey}
            endpoint={endpoint}
            source={
              draft
                ? draft.comparison
                  ? undefined
                  : draft.source
                : scope === "source"
                  ? displayed
                  : undefined
            }
            comparison={draft ? draft.comparison : visibleComparison}
            onSelection={setSelection}
            onAnnotate={draft ? undefined : beginAnnotation}
            onExplorationChange={(active) =>
              setExplorationComparison(active ? visibleComparison : undefined)
            }
          />
        ) : (
          <div className={styles.empty}>
            <h2>
              {fileListing.isPending
                ? "Loading worktree…"
                : listed?.length === 0
                  ? "No changes in this comparison."
                  : "Choose a file to review."}
            </h2>
            <p>
              Inspect both sides, select source, and add an annotation. Staged
              and Unstaged remain available for index-only changes.
            </p>
          </div>
        )}
        <div className={styles.sourceFoot}>
          {displayed
            ? `Captured source · ${displayed.id.slice(0, 12)}`
            : "Read-only source"}
          <span>
            {selection
              ? `${selection.review?.side ?? "source"} · L${selection.selection.startLineNumber}:${selection.selection.startColumn}–L${selection.selection.endLineNumber}:${selection.selection.endColumn}`
              : "Select text to annotate"}
          </span>
        </div>
        <section className={styles.terminal}>
          <div className={styles.sectionTitle}>
            AGENT TERMINAL <span>Upcoming</span>
          </div>
          <p>Managed Amp sessions will appear here.</p>
          <small>
            This foundation keeps source capture and annotation persistence
            available independently.
          </small>
        </section>
      </section>
      <aside className={styles.feedback}>
        <div className={styles.sectionTitle}>
          ANNOTATIONS <span>{annotations.data?.length ?? 0}</span>
        </div>
        {draft ? (
          <form
            onSubmit={(event) => {
              event.preventDefault();
              save.mutate(draft);
            }}
            className={styles.composer}
          >
            <span className={styles.eyebrow}>
              CAPTURED {draft.input.review?.side.toUpperCase() ?? "SOURCE"} · L
              {draft.input.selection.startLineNumber}
            </span>
            <label htmlFor="annotation">What should change?</label>
            <textarea
              id="annotation"
              autoFocus
              value={draft.input.text}
              disabled={draft.submission === "pending"}
              onChange={(event) =>
                updateDraft({
                  ...draft,
                  expiresAt: expiresAfterThreeMonths(),
                  input: { ...draft.input, text: event.target.value },
                })
              }
              placeholder="Explain the desired behavior…"
              maxLength={4000}
            />
            <p className={styles.hint} role="status">
              {message}
            </p>
            <button
              className={styles.primary}
              disabled={!draft.input.text.trim() || save.isPending}
            >
              {draft.submission === "pending"
                ? "Retry save annotation"
                : "Save annotation"}
            </button>
            <button
              type="button"
              disabled={save.isPending}
              onClick={() => {
                setDraft(null);
                setRecovery((current) => [
                  ...current.filter((item) => item.input.id !== draft.input.id),
                  draft,
                ]);
              }}
            >
              Keep draft for later
            </button>
          </form>
        ) : (
          <>
            {recovery.map((item) => (
              <button
                className={styles.recovery}
                key={item.input.id}
                onClick={() => {
                  setDraft(item);
                  setRecovery((current) =>
                    current.filter((entry) => entry.input.id !== item.input.id),
                  );
                }}
              >
                Resume draft · {item.input.path}
              </button>
            ))}
            {message && (
              <p className={styles.hint} role="status">
                {message}
              </p>
            )}
          </>
        )}
        {annotations.data?.map((annotation) => (
          <article key={annotation.input.id} className={styles.note}>
            <div>
              <span className={styles.badge}>Saved</span>
              <small>
                {annotation.input.path}:
                {annotation.input.selection.startLineNumber}
              </small>
            </div>
            <p>{annotation.input.text}</p>
            <pre>{annotation.excerpt}</pre>
            <small>
              Original source retained · {annotation.input.sourceId.slice(0, 8)}
            </small>
          </article>
        ))}
        {!draft && annotations.data?.length === 0 && (
          <p className={styles.hint}>
            Saved annotations retain the source you inspected, even as the
            worktree changes.
          </p>
        )}
      </aside>
    </main>
  );
}
