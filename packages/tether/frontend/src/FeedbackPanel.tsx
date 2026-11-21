import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import type {
  AmpSession,
  Annotation,
  Feedback,
  FeedbackInput,
  FeedbackPreview,
} from "./protocol";
import styles from "./Workbench.module.css";
import feedbackStyles from "./FeedbackPanel.module.css";

export function FeedbackPanel({
  endpoint,
  annotations,
}: {
  endpoint: string;
  annotations: Annotation[];
}) {
  const client = useQueryClient();
  const [sessionId, setSessionId] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [previewId, setPreviewId] = useState("");
  const sessions = useQuery({
    queryKey: [endpoint, "ampSessions"],
    queryFn: () => api<AmpSession[]>(`${endpoint}/ampSessions`),
  });
  const history = useQuery({
    queryKey: [endpoint, "feedback"],
    queryFn: () => api<Feedback[]>(`${endpoint}/feedback`),
    refetchInterval: 5000,
  });
  const preview = useQuery({
    queryKey: [endpoint, "feedbackPreview", previewId],
    queryFn: () =>
      api<FeedbackPreview>(
        `${endpoint}/feedbackPreview?id=${encodeURIComponent(previewId)}`,
      ),
    enabled: !!previewId,
  });
  const prepare = useMutation({
    mutationFn: (input: FeedbackInput) =>
      api<FeedbackPreview>(`${endpoint}/prepareFeedback`, {
        method: "POST",
        body: JSON.stringify(input),
      }),
    onSuccess: (result) => {
      client.setQueryData(
        [endpoint, "feedbackPreview", result.feedback.input.id],
        result,
      );
      setPreviewId(result.feedback.input.id);
      void client.invalidateQueries({ queryKey: [endpoint, "feedback"] });
    },
  });
  const send = useMutation({
    mutationFn: (id: string) =>
      api<Feedback>(`${endpoint}/sendFeedback`, {
        method: "POST",
        body: JSON.stringify({ id }),
      }),
    onSettled: () => {
      void client.invalidateQueries({ queryKey: [endpoint, "feedback"] });
      void client.invalidateQueries({
        queryKey: [endpoint, "feedbackPreview"],
      });
    },
  });
  const error =
    prepare.error ??
    send.error ??
    preview.error ??
    history.error ??
    sessions.error;
  const active =
    history.data?.find((item) => item.input.id === previewId) ??
    preview.data?.feedback;
  const busy = prepare.isPending || send.isPending;

  return (
    <section className={feedbackStyles.panel} aria-label="Amp feedback">
      <h3>Send feedback to Amp</h3>
      <label htmlFor="amp-session">Session in this worktree</label>
      <select
        id="amp-session"
        value={sessionId}
        disabled={busy || !!previewId}
        onChange={(event) => setSessionId(event.target.value)}
      >
        <option value="">Choose an Amp session</option>
        {sessions.data?.map((session) => (
          <option key={session.id} value={session.id}>
            {session.title || session.thread} · {session.thread}
          </option>
        ))}
      </select>
      <button
        disabled={sessions.isFetching || busy}
        onClick={() => void sessions.refetch()}
      >
        {sessions.isFetching ? "Finding sessions…" : "Refresh sessions"}
      </button>
      {sessions.data?.length === 0 && (
        <p className={styles.hint}>
          Open Amp in this worktree with the readiff plugin enabled. Use its
          readiff connect command, then refresh sessions.
        </p>
      )}
      <p className={styles.hint}>
        Select up to 20 annotations. Sending queues a steering message and can
        start agent work.
      </p>
      {annotations.map((annotation) => (
        <article key={annotation.input.id} className={styles.note}>
          <label className={feedbackStyles.selection}>
            <input
              type="checkbox"
              checked={selected.includes(annotation.input.id)}
              disabled={busy || !!previewId}
              onChange={(event) =>
                setSelected((current) =>
                  event.target.checked
                    ? [...current, annotation.input.id]
                    : current.filter((id) => id !== annotation.input.id),
                )
              }
            />
            {annotation.input.path}:{annotation.input.selection.startLineNumber}
          </label>
          <p>{annotation.input.text}</p>
          <pre>{annotation.excerpt}</pre>
          <small>
            Original source retained · {annotation.input.sourceId.slice(0, 8)}
          </small>
        </article>
      ))}
      {!previewId && (
        <button
          className={styles.primary}
          disabled={
            busy ||
            !sessions.data?.some((session) => session.id === sessionId) ||
            selected.length === 0 ||
            selected.length > 20
          }
          onClick={() =>
            prepare.mutate({
              id: crypto.randomUUID(),
              sessionId,
              annotationIds: selected,
            })
          }
        >
          Preview {selected.length || "selected"} annotations
        </button>
      )}
      {prepare.isError && prepare.variables && (
        <button
          disabled={busy}
          onClick={() => prepare.mutate(prepare.variables!)}
        >
          Retry preview
        </button>
      )}
      {previewId && (
        <div className={feedbackStyles.preview}>
          <h4>Feedback preview</h4>
          {preview.isPending && <p>Loading saved preview…</p>}
          {preview.data && (
            <>
              <p>{preview.data.feedback.session.title || "Amp session"}</p>
              <code>{preview.data.feedback.session.thread}</code>
              <details>
                <summary>Exact message and captured source</summary>
                <pre>{preview.data.content}</pre>
              </details>
              <p role="status">{active?.detail}</p>
              {active?.status !== "accepted" && (
                <button
                  className={styles.primary}
                  disabled={busy}
                  onClick={() => send.mutate(previewId)}
                >
                  {send.isPending
                    ? "Checking delivery…"
                    : active?.status === "uncertain"
                      ? "Check delivery"
                      : "Send to Amp"}
                </button>
              )}
            </>
          )}
          <button
            disabled={busy}
            onClick={() => {
              setPreviewId("");
              setSelected([]);
              send.reset();
              prepare.reset();
            }}
          >
            Close preview
          </button>
        </div>
      )}
      {error && (
        <p className={styles.error} role="alert">
          {error.message}
        </p>
      )}
      {!!history.data?.length && (
        <div className={feedbackStyles.history}>
          <h4>Delivery history</h4>
          <p className={styles.hint}>
            Confirmation records transcript visibility. Agent responses remain
            in Amp.
          </p>
          {history.data.map((item) => (
            <article key={item.input.id}>
              <span
                className={`${styles.badge} ${feedbackStyles.status}`}
                data-status={item.status}
              >
                {item.status === "accepted"
                  ? "Confirmed"
                  : item.status === "prepared"
                    ? "Prepared"
                    : "Unconfirmed"}
              </span>
              <p>{item.session.title || item.session.thread}</p>
              <small>
                {item.input.annotationIds.length} annotations ·{" "}
                {new Date(item.createdAt).toLocaleString()}
              </small>
              <p>{item.detail}</p>
              <button
                disabled={busy}
                onClick={() => {
                  setPreviewId(item.input.id);
                  send.reset();
                  prepare.reset();
                }}
              >
                View submission
              </button>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
