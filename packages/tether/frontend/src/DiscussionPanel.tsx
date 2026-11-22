import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import * as monaco from "monaco-editor/editor/editor.api";
import { api } from "./api";
import type {
  Annotation,
  Discussion,
  DiscussionEvent,
  Disposition,
  ResolutionInput,
  ResponseSources,
} from "./protocol";
import styles from "./FeedbackPanel.module.css";
import workbenchStyles from "./Workbench.module.css";

export function DiscussionPanel({
  endpoint,
  annotation,
  latestRevision,
  onClose,
}: {
  endpoint: string;
  annotation: Annotation;
  latestRevision?: number;
  onClose: () => void;
}) {
  const client = useQueryClient();
  const [offset, setOffset] = useState(0);
  const [note, setNote] = useState("");
  const [discardRequested, setDiscardRequested] = useState(false);
  const id = annotation.input.id;
  const discussion = useQuery({
    queryKey: [endpoint, "discussion", id, offset],
    queryFn: () =>
      api<Discussion>(
        `${endpoint}/discussion?${new URLSearchParams({ id, offset: String(offset) })}`,
      ),
    refetchOnReconnect: false,
  });
  const resolve = useMutation({
    mutationFn: (input: ResolutionInput) =>
      api<DiscussionEvent>(`${endpoint}/resolveDiscussion`, {
        method: "POST",
        body: JSON.stringify(input),
      }),
    onSuccess: async () => {
      setNote("");
      setOffset(0);
      await Promise.all([
        client.invalidateQueries({ queryKey: [endpoint, "discussion", id] }),
        client.invalidateQueries({ queryKey: [endpoint, "discussions"] }),
      ]);
    },
  });
  const current = discussion.data?.status;
  const busy = resolve.isPending || resolve.isError || offset > 0;
  function changeDisposition(disposition: Disposition) {
    if (!current) return;
    resolve.mutate({
      id: crypto.randomUUID(),
      annotationId: id,
      expectedRevision: current.revision,
      disposition,
      text: note,
    });
  }
  function close() {
    if (resolve.isPending) return;
    if (note) setDiscardRequested(true);
    else onClose();
  }

  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) close();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay
          className={`${workbenchStyles.overlay} ${styles.discussionOverlay}`}
        />
        <Dialog.Content className={styles.discussionDialog}>
          <div className={styles.actions}>
            <Dialog.Title>Review annotation</Dialog.Title>
            <button disabled={resolve.isPending} onClick={close}>
              Close review
            </button>
          </div>
          <div className={styles.reviewContent}>
            <Dialog.Description>
              {annotation.input.path}:
              {annotation.input.selection.startLineNumber} · Original feedback
            </Dialog.Description>
            <p className={styles.message}>{annotation.input.text}</p>
            <pre className={styles.excerpt}>{annotation.excerpt}</pre>
            <section
              className={styles.discussion}
              aria-label="Annotation discussion"
            >
              <div className={styles.actions}>
                <h4>Responses and review</h4>
                <button
                  disabled={discussion.isFetching || resolve.isPending}
                  onClick={() => {
                    resolve.reset();
                    void discussion.refetch();
                  }}
                >
                  Refresh discussion
                </button>
              </div>
              {discussion.isPending && <p role="status">Loading discussion…</p>}
              {discussion.error && (
                <p role="alert">{discussion.error.message}</p>
              )}
              {current &&
                latestRevision !== undefined &&
                latestRevision > current.revision && (
                  <p role="status" className={styles.warning}>
                    New review activity is available. Refresh the discussion to
                    inspect it.
                  </p>
                )}
              {discussion.data && (
                <>
                  <p>
                    Review revision {current!.revision} · {current!.disposition}
                  </p>
                  {discussion.data.events.length === 0 && (
                    <p>No responses yet.</p>
                  )}
                  {discussion.data.events.map((event) => (
                    <article key={event.id} className={styles.event}>
                      <div className={styles.actions}>
                        <strong>
                          {event.actor.kind === "agent"
                            ? "Amp response"
                            : "Your review"}
                        </strong>
                        <span
                          className={styles.disposition}
                          data-state={event.disposition}
                        >
                          {event.disposition}
                        </span>
                      </div>
                      <small>
                        {new Date(event.createdAt).toLocaleString()} · Review
                        revision {event.basedOnRevision}
                      </small>
                      {event.actor.kind === "agent" && (
                        <code>{event.actor.thread}</code>
                      )}
                      {!event.applied && (
                        <p className={styles.warning}>
                          Earlier review revision · retained in history. Current
                          disposition is unchanged.
                        </p>
                      )}
                      {event.text && (
                        <p className={styles.message}>{event.text}</p>
                      )}
                      {event.evidence.length > 0 && (
                        <ResponseInspection
                          endpoint={endpoint}
                          annotation={annotation}
                          event={event}
                        />
                      )}
                    </article>
                  ))}
                  <div className={styles.actions}>
                    {offset > 0 && (
                      <button onClick={() => setOffset(0)}>
                        Latest activity
                      </button>
                    )}
                    {discussion.data.nextOffset !== null && (
                      <button
                        onClick={() => setOffset(discussion.data!.nextOffset!)}
                      >
                        Older activity
                      </button>
                    )}
                  </div>
                </>
              )}
            </section>
          </div>
          <div className={styles.reviewActions}>
            {discardRequested && (
              <div role="alert" className={styles.event}>
                <p>Discard the unsaved review note?</p>
                <div className={styles.actions}>
                  <button onClick={() => setDiscardRequested(false)}>
                    Keep editing
                  </button>
                  <button onClick={onClose}>Discard note and close</button>
                </div>
              </div>
            )}
            {offset > 0 && (
              <p role="status">Return to Latest activity before reviewing.</p>
            )}
            {current && (
              <>
                <label htmlFor={`review-note-${id}`}>
                  Review note (optional)
                </label>
                <textarea
                  id={`review-note-${id}`}
                  value={note}
                  disabled={busy}
                  onChange={(event) => setNote(event.target.value)}
                  rows={2}
                />
                <div className={styles.actions}>
                  {current!.disposition !== "resolved" && (
                    <button
                      disabled={busy}
                      onClick={() => changeDisposition("resolved")}
                    >
                      Resolve
                    </button>
                  )}
                  {current!.disposition !== "dismissed" && (
                    <button
                      disabled={busy}
                      onClick={() => changeDisposition("dismissed")}
                    >
                      Dismiss
                    </button>
                  )}
                  {current!.disposition !== "open" && (
                    <button
                      disabled={busy}
                      onClick={() => changeDisposition("open")}
                    >
                      Reopen
                    </button>
                  )}
                </div>
                <p className={styles.hint}>
                  Reopening keeps the response history. Select the annotation
                  and prepare a new submission to request another revision.
                </p>
              </>
            )}
            {resolve.isPending && <p role="status">Saving review…</p>}
            {resolve.error && (
              <>
                <p role="alert">{resolve.error.message}</p>
                <button onClick={() => resolve.mutate(resolve.variables!)}>
                  Retry same review action
                </button>
              </>
            )}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function ResponseInspection({
  endpoint,
  annotation,
  event,
}: {
  endpoint: string;
  annotation: Annotation;
  event: DiscussionEvent;
}) {
  const [open, setOpen] = useState(false);
  const [path, setPath] = useState(event.evidence[0].path);
  const sources = useQuery({
    queryKey: [endpoint, "responseSources", event.id, path],
    queryFn: () =>
      api<ResponseSources>(
        `${endpoint}/responseSources?${new URLSearchParams({ id: annotation.input.id, eventId: event.id, path })}`,
      ),
    enabled: open,
    staleTime: Infinity,
  });
  return (
    <details onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>Inspect captured changes</summary>
      <label>
        Source evidence
        <select value={path} onChange={(event) => setPath(event.target.value)}>
          {event.evidence.map((evidence) => (
            <option key={evidence.path} value={evidence.path}>
              {evidence.path}
            </option>
          ))}
        </select>
      </label>
      <p className={styles.hint}>
        Snapshots captured with this response. Later edits remain outside this
        evidence.
      </p>
      {annotation.input.review?.side === "before" &&
        path === annotation.input.path && (
          <p className={styles.hint}>
            Original annotation targets the old side of its reviewed diff.
          </p>
        )}
      {sources.isPending && <p role="status">Loading captured source…</p>}
      {sources.error && <p role="alert">{sources.error.message}</p>}
      {open && sources.data && (
        <>
          <div className={styles.sourceLabels}>
            <span>
              {sources.data.before
                ? `Annotated source · ${sources.data.before.id.slice(0, 8)}`
                : "Original snapshot unavailable for this path"}
            </span>
            <span>
              {sources.data.after
                ? `Response source · ${sources.data.after.id.slice(0, 8)}`
                : "Absent when the agent responded"}
            </span>
          </div>
          <ResponseDiff sources={sources.data} />
        </>
      )}
    </details>
  );
}

function ResponseDiff({ sources }: { sources: ResponseSources }) {
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const original = monaco.editor.createModel(
      sources.before?.text ?? "",
      "plaintext",
    );
    const modified = monaco.editor.createModel(
      sources.after?.text ?? "",
      "plaintext",
    );
    const editor = monaco.editor.createDiffEditor(container.current!, {
      theme: "tether",
      readOnly: true,
      domReadOnly: true,
      originalEditable: false,
      automaticLayout: true,
      renderSideBySide: false,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontSize: 12,
      wordWrap: "on",
      originalAriaLabel: "Original annotated source",
      modifiedAriaLabel: "Source captured with response",
    });
    editor.setModel({ original, modified });
    return () => {
      editor.dispose();
      original.dispose();
      modified.dispose();
    };
  }, [sources]);
  return <div ref={container} className={styles.sourceDiff} />;
}
