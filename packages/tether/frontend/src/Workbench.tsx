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
import { FileTree } from "./FileTree";
import { Explorer } from "./Explorer";
import { SignOut } from "./SignOut";
import { MachineSetup, RegisterWorktree } from "./RegisterWorktree";
import { MachineVersion } from "./MachineVersion";
import { FeedbackPanel } from "./FeedbackPanel";
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
        {!selectedId && (
          <button
            disabled={!machines.data || connectionOpen}
            onClick={() => {
              navigate("/");
              setConnectionOpen(true);
            }}
          >
            Connect machine
          </button>
        )}
        <select
          className={styles.worktreeSelector}
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
        {machine && <MachineVersion key={machine.id} machine={machine} />}
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
        {worktree && (
          <Review
            key={`${machineId}:${worktree.id}`}
            worktree={worktree}
            machineId={machineId}
            owner={session.data.owner}
          />
        )}
        <main className={styles.welcome} hidden={!!worktree}>
          <span className={styles.eyebrow}>
            {machineId ? "2 · WORKTREE" : "1 · MACHINE"}
          </span>
          <h1>{machineId ? "Choose a worktree" : "Choose a machine"}</h1>
          <div hidden={!machineId}>
            <p>
              {machine?.ssh?.destination ?? machine?.host} · Worktrees on this
              machine
            </p>
            {inventory.isPending && <p role="status">Loading worktrees…</p>}
            {inventory.error && <p role="alert">{inventory.error.message}</p>}
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
          </div>
          <div hidden={!!machineId}>
            <p>
              Select the machine running your agents to browse its worktrees.
            </p>
            {machines.isPending && <p role="status">Loading machines…</p>}
            {machines.error && <p role="alert">{machines.error.message}</p>}
            {machines.error && (
              <button onClick={() => void machines.refetch()}>
                Retry machines
              </button>
            )}
            <div className={styles.selectionList}>
              {connectionOpen && machines.data && (
                <section
                  className={styles.machineCard}
                  aria-label="New SSH machine"
                >
                  <MachineSetup
                    machines={machines.data}
                    inline
                    onClose={() => setConnectionOpen(false)}
                    onConnected={async (connected) => {
                      await client.invalidateQueries({
                        queryKey: ["machines"],
                      });
                      setConnectionOpen(false);
                      navigate(`/machines/${connected.id}/`);
                    }}
                  />
                </section>
              )}
              {!machineId &&
                machines.data?.map((entry) => (
                  <section
                    key={entry.id}
                    className={styles.machineCard}
                    aria-label={`Machine ${entry.ssh?.destination ?? "Local machine"}`}
                  >
                    <button
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
                    <MachineVersion machine={entry} inline />
                  </section>
                ))}
            </div>
            <p className={styles.hint}>
              Use Connect machine to add an SSH destination.
            </p>
          </div>
        </main>
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
  const [scope, setScope] = useState<Scope | "source">("source");
  const changes = useQuery({
    queryKey: [worktreeKey, "changes", scope],
    queryFn: ({ signal }) =>
      api<ChangedFile[]>(`${endpoint}/changes?scope=${scope}`, { signal }),
    enabled: scope !== "source",
    refetchInterval: 5000,
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
  const [filesOpen, setFilesOpen] = useState(true);
  const [feedbackOpen, setFeedbackOpen] = useState(false);
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
    (scope === "source" ? source.error : (changes.error ?? comparison.error)) ??
    annotations.error ??
    save.error;
  const feedbackVisible = feedbackOpen || !!draft;

  function selectPath(path: string) {
    setPath(path);
    setExplorationComparison(undefined);
    setSelection(null);
  }

  function changeScope(scope: Scope | "source") {
    setScope(scope);
    selectPath("");
  }

  return (
    <main className={styles.review}>
      <aside id="review-files" className={styles.files} hidden={!filesOpen}>
        <div className={styles.fileViews} aria-label="File views">
          <button
            aria-pressed={scope === "source"}
            disabled={!!draft}
            onClick={() => changeScope("source")}
          >
            Explorer
          </button>
          <button
            aria-pressed={scope !== "source"}
            disabled={!!draft}
            onClick={() => changeScope("uncommitted")}
          >
            Changes
          </button>
        </div>
        <div className={styles.sectionTitle}>
          {scope === "source" ? worktree.name : "CHANGES"}
          {scope !== "source" && <span>{changes.data?.length ?? "…"}</span>}
        </div>
        <div className={styles.fileList} hidden={scope !== "source"}>
          <Explorer
            endpoint={endpoint}
            selected={path}
            disabled={!!draft}
            onSelect={selectPath}
          />
        </div>
        {scope !== "source" && (
          <>
            <select
              aria-label="Comparison scope"
              value={scope}
              disabled={!!draft}
              onChange={(event) => changeScope(event.target.value as Scope)}
            >
              <option value="uncommitted">Uncommitted</option>
              <option value="staged">Staged</option>
              <option value="unstaged">Unstaged</option>
            </select>
            <input
              aria-label="Filter files"
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder="Filter paths…"
            />
            <div className={styles.loading} role="status">
              {changes.isFetching && (
                <>
                  <span className={styles.spinner} aria-hidden="true" />
                  {changes.isPending ? "Loading files…" : "Refreshing files…"}
                </>
              )}
            </div>
            <div className={styles.fileList} aria-busy={changes.isFetching}>
              <FileTree
                key={`${scope}:${filter}`}
                files={(changes.data ?? []).filter((file) =>
                  file.path.toLowerCase().includes(filter.toLowerCase()),
                )}
                selected={path}
                disabled={!!draft}
                onSelect={selectPath}
              />
            </div>
          </>
        )}
      </aside>
      <section className={styles.sourcePane}>
        <div className={styles.toolbar}>
          <button
            aria-expanded={filesOpen}
            aria-controls="review-files"
            onClick={() => setFilesOpen(!filesOpen)}
          >
            Files
          </button>
          <span className={styles.sourcePath} title={displayed?.path}>
            {displayed?.path ?? "Choose a source file"}
          </span>
          <button
            onClick={() => {
              setSelection(null);
              if (scope === "source") {
                void client.invalidateQueries({
                  queryKey: [endpoint, "sourceDirectory"],
                });
                if (path) void source.refetch();
              } else {
                void changes.refetch();
                if (path) void comparison.refetch();
              }
            }}
            disabled={!!draft}
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
          <button
            aria-expanded={feedbackVisible}
            aria-controls="review-annotations"
            disabled={!!draft}
            onClick={() => setFeedbackOpen(!feedbackOpen)}
          >
            Annotations ({annotations.data?.length ?? 0})
            {recovery.length > 0 && ` · ${recovery.length} drafts`}
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
              {scope === "source"
                ? "Choose a file in Explorer."
                : changes.isPending
                  ? "Loading worktree…"
                  : changes.data?.length === 0
                    ? "No changes in this comparison."
                    : "Choose a file to review."}
            </h2>
            <p>
              Explorer browses the worktree's files and folders. Changes shows
              diffs for Uncommitted, Staged, and Unstaged content.
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
      </section>
      <aside
        id="review-annotations"
        className={styles.feedback}
        hidden={!feedbackVisible}
      >
        <div className={styles.sectionTitle}>
          ANNOTATIONS <span>{annotations.data?.length ?? 0}</span>
          <button
            aria-label="Close annotations"
            disabled={!!draft}
            onClick={() => setFeedbackOpen(false)}
          >
            ×
          </button>
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
        {feedbackVisible && !draft && (
          <FeedbackPanel
            key={endpoint}
            endpoint={endpoint}
            annotations={annotations.data ?? []}
          />
        )}
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
