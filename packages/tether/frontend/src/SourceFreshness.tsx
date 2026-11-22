import { useState, useSyncExternalStore } from "react";
import { onlineManager, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import type { AssessedSources, SourceAssessment } from "./protocol";
import { SourceDiff } from "./SourceDiff";
import styles from "./FeedbackPanel.module.css";

export function useAssessments(endpoint: string) {
  return useQuery({
    queryKey: [endpoint, "freshness", "annotations"],
    queryFn: ({ signal }) =>
      api<SourceAssessment[]>(`${endpoint}/assessments`, { signal }),
    refetchInterval: 5000,
    retry: false,
  });
}

const labels = {
  unchanged: "Source unchanged",
  moved: "Moved · source unchanged",
  changed: "Source changed",
  removed: "Source removed",
  uncertain: "Location uncertain",
  unknown: "Freshness unknown",
};

export function FreshnessLabel({
  assessment,
  checking,
  failed,
  response = false,
}: {
  assessment?: SourceAssessment;
  checking: boolean;
  failed: boolean;
  response?: boolean;
}) {
  const online = useSyncExternalStore(
    (notify) => onlineManager.subscribe(notify),
    () => onlineManager.isOnline(),
  );
  const unknown = failed || !online;
  const label = unknown
    ? "Freshness unknown"
    : checking
      ? "Checking source…"
      : assessment
        ? response && assessment.fileChanged
          ? "Changed since response"
          : labels[assessment.freshness]
        : "Freshness unknown";
  return (
    <div className={styles.freshness}>
      <strong>{label}</strong>
      {assessment && (
        <>
          <small>
            {unknown || checking ? "Last observation" : "Observed"} ·{" "}
            {new Date(assessment.observedAt).toLocaleTimeString()}
            {(unknown || checking) && ` · ${labels[assessment.freshness]}`}
          </small>
          {assessment.fileChanged && assessment.selection && (
            <small>File changed elsewhere</small>
          )}
          {assessment.freshness === "moved" && assessment.selection && (
            <small>
              Current location · L{assessment.selection.startLineNumber}:
              {assessment.selection.startColumn}
            </small>
          )}
          <small>{assessment.detail}</small>
        </>
      )}
    </div>
  );
}

export function SourceInspection({
  endpoint,
  annotationId,
  eventId,
  path,
  oldSide = false,
}: {
  endpoint: string;
  annotationId: string;
  eventId?: string;
  path: string;
  oldSide?: boolean;
}) {
  const client = useQueryClient();
  const [open, setOpen] = useState(false);
  const parameters = new URLSearchParams({ id: annotationId, path });
  if (eventId) parameters.set("eventId", eventId);
  const assessment = useQuery({
    queryKey: [endpoint, "freshness", annotationId, eventId, path],
    queryFn: ({ signal }) =>
      api<SourceAssessment>(`${endpoint}/assessSource?${parameters}`, {
        signal,
      }),
    refetchInterval: 5000,
    retry: false,
  });
  const sources = useQuery({
    queryKey: [
      endpoint,
      "freshness",
      annotationId,
      eventId,
      path,
      "sources",
      assessment.data?.currentId,
      assessment.data?.freshness,
    ],
    queryFn: ({ signal }) =>
      api<AssessedSources>(
        `${endpoint}/assessSource?${parameters}&sources=true&expectedCurrentId=${assessment.data?.currentId ?? "absent"}`,
        { signal },
      ),
    enabled: open && !!assessment.data && !assessment.isError,
    retry: false,
  });
  const snapshot = sources.data;
  const matchesObservation =
    snapshot &&
    snapshot.assessment.currentId === assessment.data?.currentId &&
    snapshot.assessment.baselineId === assessment.data?.baselineId;
  const baselineLabel = eventId
    ? "Captured response"
    : oldSide
      ? "Reviewed new-side state"
      : "Original annotation source";
  return (
    <section
      aria-label={
        eventId ? "Response source freshness" : "Annotation source freshness"
      }
    >
      <FreshnessLabel
        assessment={assessment.data}
        checking={assessment.isFetching}
        failed={assessment.isError || assessment.isPaused}
        response={!!eventId}
      />
      <button
        disabled={assessment.isFetching}
        onClick={() =>
          void client.invalidateQueries({
            queryKey: [endpoint, "freshness", annotationId, eventId, path],
          })
        }
      >
        Check source now
      </button>
      {assessment.error && <p role="alert">{assessment.error.message}</p>}
      <details onToggle={(event) => setOpen(event.currentTarget.open)}>
        <summary>
          {eventId
            ? "Inspect changes since response"
            : "Inspect changes since annotation"}
        </summary>
        {sources.error && <p role="alert">{sources.error.message}</p>}
        {open && sources.isPending && (
          <p role="status">Loading source comparison…</p>
        )}
        {open && snapshot && (
          <>
            {(!matchesObservation || assessment.isError) && (
              <p role="status">
                This comparison shows an earlier observation. Check source again
                for current freshness.
              </p>
            )}
            <p className={styles.hint}>
              Observed{" "}
              {new Date(snapshot.assessment.observedAt).toLocaleString()}
            </p>
            {snapshot.assessment.freshness === "unknown" ? (
              <p role="status">{snapshot.assessment.detail}</p>
            ) : (
              <>
                <div className={styles.sourceLabels}>
                  <span>
                    {baselineLabel} ·{" "}
                    {snapshot.baseline?.id.slice(0, 8) ?? "absent"}
                  </span>
                  <span>
                    Observed worktree ·{" "}
                    {snapshot.current?.id.slice(0, 8) ?? "absent"}
                  </span>
                </div>
                <SourceDiff
                  before={snapshot.baseline}
                  after={snapshot.current}
                  beforeLabel={baselineLabel}
                  afterLabel="Observed worktree source"
                />
                {oldSide && !eventId && (
                  <details>
                    <summary>Inspect original reviewed change</summary>
                    <div className={styles.sourceLabels}>
                      <span>
                        Original old-side source ·{" "}
                        {snapshot.original?.id.slice(0, 8)}
                      </span>
                      <span>
                        Reviewed new-side state ·{" "}
                        {snapshot.baseline?.id.slice(0, 8) ?? "absent"}
                      </span>
                    </div>
                    <SourceDiff
                      before={snapshot.original}
                      after={snapshot.baseline}
                      beforeLabel="Original old-side source"
                      afterLabel="Reviewed new-side state"
                    />
                  </details>
                )}
              </>
            )}
          </>
        )}
      </details>
    </section>
  );
}
