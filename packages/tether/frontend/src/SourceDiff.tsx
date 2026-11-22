import { useEffect, useRef } from "react";
import * as monaco from "monaco-editor/editor/editor.api";
import type { Source } from "./protocol";
import styles from "./FeedbackPanel.module.css";

export function SourceDiff({
  before,
  after,
  beforeLabel,
  afterLabel,
}: {
  before: Source | null;
  after: Source | null;
  beforeLabel: string;
  afterLabel: string;
}) {
  const container = useRef<HTMLDivElement>(null);
  const beforeLines = before?.text.split(/\r\n|\r|\n/).length ?? 0;
  const afterLines = after?.text.split(/\r\n|\r|\n/).length ?? 0;
  const height = Math.min(
    280,
    Math.max(100, (beforeLines + afterLines) * 18 + 24),
  );
  useEffect(() => {
    const original = monaco.editor.createModel(before?.text ?? "", "plaintext");
    const modified = monaco.editor.createModel(after?.text ?? "", "plaintext");
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
      lineHeight: 18,
      wordWrap: "on",
      originalAriaLabel: beforeLabel,
      modifiedAriaLabel: afterLabel,
    });
    editor.setModel({ original, modified });
    return () => {
      editor.dispose();
      original.dispose();
      modified.dispose();
    };
  }, [before, after, beforeLabel, afterLabel]);
  return (
    <div ref={container} className={styles.sourceDiff} style={{ height }} />
  );
}
