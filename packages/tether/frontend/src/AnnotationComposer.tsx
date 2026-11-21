import { useEffect, useRef, type RefObject } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import type { RecoveryDraft } from "./recovery";
import { lastSelectedLine } from "./annotationControls";
import styles from "./Workbench.module.css";

export function AnnotationComposer({
  draft,
  textarea,
  locked,
  busy,
  message,
  confirmingDiscard,
  discardError,
  onText,
  onSave,
  onClose,
  onDiscard,
  onKeepEditing,
}: {
  draft: RecoveryDraft;
  textarea: RefObject<HTMLTextAreaElement | null>;
  locked: boolean;
  busy: boolean;
  message: string;
  confirmingDiscard: boolean;
  discardError?: string;
  onText: (text: string) => void;
  onSave: () => void;
  onClose: () => void;
  onDiscard: () => void;
  onKeepEditing: () => void;
}) {
  const container = useRef<HTMLFormElement>(null);
  const endLine = lastSelectedLine(draft.input.selection);
  useEffect(() => {
    if (!locked) textarea.current?.focus();
  }, [draft.input.id, locked, textarea]);

  return (
    <form
      ref={container}
      aria-label="Inline annotation"
      className={styles.composer}
      onSubmit={(event) => {
        event.preventDefault();
        if (draft.input.text.trim() && !busy && !confirmingDiscard) onSave();
      }}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing || confirmingDiscard) return;
        if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
          event.preventDefault();
          event.currentTarget.requestSubmit();
        }
      }}
    >
      <div className={styles.composerHeader}>
        <strong>
          Comment · {draft.input.review?.side ?? "source"} · L
          {draft.input.selection.startLineNumber}
          {endLine > draft.input.selection.startLineNumber && `–L${endLine}`}
        </strong>
        <button
          type="button"
          aria-label="Close annotation"
          title="Close and keep draft (Escape)"
          aria-keyshortcuts="Escape"
          disabled={busy}
          onClick={onClose}
        >
          ×
        </button>
      </div>
      <label htmlFor="annotation">What should change?</label>
      <textarea
        id="annotation"
        ref={textarea}
        value={draft.input.text}
        disabled={locked}
        onChange={(event) => onText(event.target.value)}
        placeholder="Explain the desired behavior…"
        maxLength={4000}
      />
      <p className={styles.hint} role="status">
        {message}
      </p>
      <div className={styles.composerActions}>
        <button
          className={styles.primary}
          aria-keyshortcuts="Control+Enter Meta+Enter"
          disabled={!draft.input.text.trim() || busy}
        >
          {draft.submission === "pending"
            ? "Retry save annotation"
            : "Save annotation"}
        </button>
        <button type="button" disabled={busy} onClick={onClose}>
          Keep draft for later
        </button>
      </div>
      <p className={styles.hint}>
        Ctrl/Cmd+Enter saves · Escape closes and keeps draft · F6 switches
        between source and comment.
      </p>
      <Dialog.Root
        open={confirmingDiscard}
        onOpenChange={(open) => {
          if (!open && !busy) onKeepEditing();
        }}
      >
        <Dialog.Portal container={container.current}>
          <Dialog.Overlay className={styles.draftOverlay} />
          <Dialog.Content
            className={styles.discardDraft}
            onCloseAutoFocus={(event) => {
              event.preventDefault();
              textarea.current?.focus();
            }}
            onInteractOutside={(event) => event.preventDefault()}
          >
            <Dialog.Title>Discard draft?</Dialog.Title>
            <Dialog.Description>
              Your unsaved text will be removed. Start a new annotation for the
              selected source?
            </Dialog.Description>
            <button type="button" disabled={busy} onClick={onKeepEditing}>
              Keep editing
            </button>
            <button
              type="button"
              className={styles.primary}
              disabled={busy}
              onClick={onDiscard}
            >
              {busy ? "Discarding…" : "Discard draft"}
            </button>
            {discardError && <p role="alert">{discardError}</p>}
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </form>
  );
}
