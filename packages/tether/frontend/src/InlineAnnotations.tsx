import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import * as monaco from "monaco-editor/editor/editor.api";
import type {
  Annotation,
  AnnotationInput,
  ReviewAnchor,
  Selection,
} from "./protocol";
import { lastSelectedLine } from "./annotationControls";
import { FreshnessLabel, useAssessments } from "./SourceFreshness";
import styles from "./Workbench.module.css";

export interface InlineDraft {
  input: AnnotationInput;
  content: ReactNode;
}

export function InlineAnnotations({
  endpoint,
  path,
  editor,
  sourceId,
  review,
  annotations,
  draft,
}: {
  endpoint: string;
  path: string;
  editor: monaco.editor.IStandaloneCodeEditor;
  sourceId: string;
  review?: ReviewAnchor;
  annotations: Annotation[];
  draft?: InlineDraft;
}) {
  const assessments = useAssessments(endpoint);
  function matches(input: AnnotationInput) {
    return (
      input.path === path &&
      input.sourceId === sourceId &&
      input.review?.comparisonId === review?.comparisonId &&
      input.review?.side === review?.side
    );
  }

  return (
    <>
      {annotations.map((note) => {
        if (note.input.path !== path) return null;
        const assessment = assessments.data?.find(
          (item) => item.annotationId === note.input.id,
        );
        const mapped =
          assessment?.currentId === sourceId && review?.side !== "before"
            ? assessment.selection
            : null;
        const selection = matches(note.input) ? note.input.selection : mapped;
        if (!selection) return null;
        const endLine = lastSelectedLine(selection);
        return (
          <InlineZone key={note.input.id} editor={editor} selection={selection}>
            <article
              className={styles.inlineNote}
              tabIndex={0}
              aria-label={`Annotation on line ${selection.startLineNumber}`}
            >
              <strong>
                Annotation · L{selection.startLineNumber}
                {endLine > selection.startLineNumber && `–L${endLine}`}
              </strong>
              <p>{note.input.text}</p>
              <FreshnessLabel
                assessment={assessment}
                checking={assessments.isFetching}
                failed={assessments.isError || assessments.isPaused}
              />
            </article>
          </InlineZone>
        );
      })}
      {draft && matches(draft.input) && (
        <InlineZone
          key={draft.input.id}
          editor={editor}
          selection={draft.input.selection}
          editing
        >
          {draft.content}
        </InlineZone>
      )}
    </>
  );
}

function InlineZone({
  editor,
  selection,
  editing = false,
  children,
}: {
  editor: monaco.editor.IStandaloneCodeEditor;
  selection: Selection;
  editing?: boolean;
  children: ReactNode;
}) {
  const [host] = useState(() => document.createElement("div"));
  const endLine = lastSelectedLine(selection);
  useEffect(() => {
    let top = 0;
    host.className = styles.inlineAnnotation;
    const widgetId = `tether.annotation.${crypto.randomUUID()}`;
    const widget: monaco.editor.IOverlayWidget = {
      getId: () => widgetId,
      getDomNode: () => host,
      getPosition: () => {
        const layout = editor.getLayoutInfo();
        host.style.width = `${Math.max(0, layout.contentWidth - 24)}px`;
        const clippedTop = Math.max(0, -top - 8);
        const clippedBottom = Math.max(
          0,
          top + 8 + host.offsetHeight - layout.height,
        );
        host.style.clipPath = `inset(${clippedTop}px 0 ${clippedBottom}px 0)`;
        return { preference: { top: top + 8, left: layout.contentLeft + 8 } };
      },
    };
    // The view zone reserves source space. The overlay keeps comments accessible.
    const zone: monaco.editor.IViewZone = {
      afterLineNumber: endLine,
      heightInPx: host.offsetHeight + 16,
      domNode: document.createElement("div"),
      onDomNodeTop: (value) => {
        top = value;
        editor.layoutOverlayWidget(widget);
      },
    };
    editor.addOverlayWidget(widget);
    let zoneId = "";
    editor.changeViewZones((accessor) => {
      zoneId = accessor.addZone(zone);
    });
    const resize = new ResizeObserver(() => {
      zone.heightInPx = host.offsetHeight + 16;
      editor.changeViewZones((accessor) => accessor.layoutZone(zoneId));
      editor.layoutOverlayWidget(widget);
    });
    resize.observe(host);
    const layout = editor.onDidLayoutChange(() =>
      editor.layoutOverlayWidget(widget),
    );
    const highlight = editor.createDecorationsCollection([
      {
        range: new monaco.Range(selection.startLineNumber, 1, endLine, 1),
        options: { isWholeLine: true, className: styles.annotationAnchor },
      },
    ]);
    function reveal() {
      editor.revealLineNearTop(endLine, monaco.editor.ScrollType.Immediate);
    }
    host.addEventListener("focusin", reveal);
    if (editing) {
      reveal();
      host.querySelector("textarea")?.focus();
    }
    return () => {
      host.removeEventListener("focusin", reveal);
      resize.disconnect();
      layout.dispose();
      highlight.clear();
      editor.changeViewZones((accessor) => accessor.removeZone(zoneId));
      editor.removeOverlayWidget(widget);
    };
  }, [editor, host, selection, endLine, editing]);
  return createPortal(children, host);
}
