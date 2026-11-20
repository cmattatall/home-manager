import { useEffect, useRef, useState } from "react";
import * as monaco from "monaco-editor/editor/editor.api";
import "monaco-editor/editor/browser/coreCommands";
import "monaco-editor/editor/contrib/semanticTokens/browser/documentSemanticTokens";
import type { Comparison, ReviewAnchor, Selection, Source } from "./protocol";
import { tokenTypes } from "./protocol";
import { GoExplorer } from "./GoExplorer";
import styles from "./Workbench.module.css";

export interface SourceSelection {
  source: Source;
  selection: Selection;
  review?: ReviewAnchor;
}

interface SourceViewerProps {
  worktree: string;
  source?: Source;
  comparison?: Comparison;
  onSelection: (selection: SourceSelection | null) => void;
  onExplorationChange?: (active: boolean) => void;
}

monaco.languages.register({ id: "tether-source-go" });

export function highlightSource(
  model: monaco.editor.ITextModel,
  source: Source,
) {
  const provider = monaco.languages.registerDocumentSemanticTokensProvider(
    model.getLanguageId(),
    {
      getLegend: () => ({ tokenTypes, tokenModifiers: [] }),
      provideDocumentSemanticTokens: (requested) =>
        requested === model
          ? {
              data: new Uint32Array(source.highlights ?? []),
              resultId: source.id,
            }
          : null,
      releaseDocumentSemanticTokens() {},
    },
  );
  model.onWillDispose(() => provider.dispose());
}

monaco.editor.defineTheme("tether", {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "keyword", foreground: "C7A5EF" },
    { token: "string", foreground: "A9D9BE" },
    { token: "comment", foreground: "8292A9" },
    { token: "number", foreground: "E4B98C" },
    { token: "function", foreground: "E6D397" },
    { token: "variable", foreground: "9BD1EA" },
    { token: "type", foreground: "80CFC4" },
  ],
  colors: {
    "editor.background": "#111418",
    "editor.foreground": "#dce2eb",
    "editorLineNumber.foreground": "#68778b",
    "editor.selectionBackground": "#354b73",
    "peekView.border": "#829de3",
    "peekViewTitle.background": "#263141",
    "peekViewEditor.background": "#171b21",
    "peekViewResult.background": "#1c222b",
  },
});

export const editorOptions: monaco.editor.IStandaloneEditorConstructionOptions =
  {
    theme: "tether",
    readOnly: true,
    "semanticHighlighting.enabled": true,
    automaticLayout: true,
    fontFamily: "Menlo, Consolas, monospace",
    fontSize: 13,
    lineHeight: 23,
    minimap: { enabled: false },
    wordWrap: "off",
    scrollBeyondLastLine: false,
    folding: false,
    links: false,
    occurrencesHighlight: "off",
    selectionHighlight: false,
    wordBasedSuggestions: "off",
    stickyScroll: { enabled: false },
    gotoLocation: {
      multipleDefinitions: "peek",
      multipleReferences: "peek",
      alternativeReferenceCommand: "",
    },
    unicodeHighlight: { nonBasicASCII: false, ambiguousCharacters: false },
    padding: { top: 16 },
  };

export function SourceViewer({
  worktree,
  endpoint,
  source,
  comparison,
  onSelection,
  onExplorationChange,
}: SourceViewerProps & { endpoint: string }) {
  const [exploring, setExploring] = useState(false);
  const [hunk, setHunk] = useState(-1);
  const path =
    source?.path ?? comparison?.after?.path ?? comparison?.before?.path ?? "";
  const callback = useRef(onSelection);
  callback.current = onSelection;
  const reviewSelection = useRef<SourceSelection | null>(null);
  useEffect(() => {
    setExploring(false);
    setHunk(-1);
    reviewSelection.current = null;
    callback.current(null);
  }, [source?.id, comparison?.id, worktree]);
  useEffect(() => {
    callback.current(exploring ? null : reviewSelection.current);
  }, [exploring]);

  function selectReview(selection: SourceSelection | null) {
    reviewSelection.current = selection;
    callback.current(selection);
  }

  function moveHunk(direction: number) {
    const count = comparison?.hunks.length ?? 0;
    if (count) setHunk((current) => (current + direction + count) % count);
  }

  function explore(active: boolean) {
    setExploring(active);
    onExplorationChange?.(active);
  }

  return (
    <div className={styles.viewer}>
      <div className={styles.explorationBar}>
        <button aria-pressed={!exploring} onClick={() => explore(false)}>
          Return to review
        </button>
        <button
          disabled={!path.endsWith(".go")}
          aria-pressed={exploring}
          onClick={() => explore(true)}
        >
          Explore current version
        </button>
        {!exploring && comparison && (
          <>
            <button
              disabled={!comparison.hunks.length}
              onClick={() => moveHunk(-1)}
              aria-label="Previous hunk"
            >
              ↑
            </button>
            <button
              disabled={!comparison.hunks.length}
              onClick={() => moveHunk(1)}
              aria-label="Next hunk"
            >
              ↓
            </button>
            <span>
              {hunk < 0
                ? comparison.hunks.length
                : `${hunk + 1}/${comparison.hunks.length}`}{" "}
              hunks
            </span>
          </>
        )}
      </div>
      <div
        className={styles.diff}
        style={{ display: exploring ? "none" : undefined }}
      >
        {comparison
          ? (["before", "after"] as const).map((side) => (
              <section className={styles.diffSide} key={side}>
                <div className={styles.sideLabel}>
                  {side === "before"
                    ? comparison.beforeLabel
                    : comparison.afterLabel}
                </div>
                {comparison[side] ? (
                  <SourceEditor
                    worktree={worktree}
                    source={comparison[side]}
                    comparison={comparison}
                    side={side}
                    hunk={hunk}
                    onSelection={selectReview}
                  />
                ) : (
                  <div className={styles.empty}>File absent on this side</div>
                )}
              </section>
            ))
          : source && (
              <SourceEditor
                worktree={worktree}
                source={source}
                hunk={-1}
                onSelection={selectReview}
              />
            )}
      </div>
      {exploring && (
        <GoExplorer
          worktree={worktree}
          endpoint={endpoint}
          path={path}
          onSelection={onSelection}
        />
      )}
    </div>
  );
}

function SourceEditor({
  worktree,
  source,
  comparison,
  side,
  hunk,
  onSelection,
}: SourceViewerProps & {
  source: Source;
  side?: "before" | "after";
  hunk: number;
}) {
  const container = useRef<HTMLDivElement>(null);
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const callback = useRef(onSelection);
  callback.current = onSelection;

  useEffect(() => {
    const model = monaco.editor.createModel(
      source.text,
      source.path.endsWith(".go") ? "tether-source-go" : "plaintext",
      monaco.Uri.from({
        scheme: "tether",
        authority: worktree,
        path: `/${source.path}`,
        query: new URLSearchParams({
          review: comparison?.id ?? source.id,
          side: side ?? "source",
        }).toString(),
      }),
    );
    highlightSource(model, source);
    const editor = monaco.editor.create(container.current!, {
      ...editorOptions,
      model,
    });
    editorRef.current = editor;
    if (comparison && side) {
      editor.createDecorationsCollection(
        comparison.hunks.flatMap((change) => {
          const start =
            side === "before" ? change.beforeStart : change.afterStart;
          const end = side === "before" ? change.beforeEnd : change.afterEnd;
          if (start === end) return [];
          return [
            {
              range: new monaco.Range(
                start,
                1,
                end - 1,
                model.getLineMaxColumn(end - 1),
              ),
              options: {
                isWholeLine: true,
                className: side === "before" ? styles.removed : styles.added,
                linesDecorationsClassName:
                  side === "before" ? styles.removedGutter : styles.addedGutter,
              },
            },
          ];
        }),
      );
    }
    const subscription = editor.onDidChangeCursorSelection(({ selection }) => {
      callback.current(
        selection.isEmpty()
          ? null
          : {
              source,
              selection: {
                startLineNumber: selection.startLineNumber,
                startColumn: selection.startColumn,
                endLineNumber: selection.endLineNumber,
                endColumn: selection.endColumn,
              },
              review:
                comparison && side
                  ? { comparisonId: comparison.id, side }
                  : undefined,
            },
      );
    });
    return () => {
      subscription.dispose();
      editor.dispose();
      model.dispose();
    };
  }, [worktree, source, comparison, side]);

  useEffect(() => {
    const change = comparison?.hunks[hunk];
    if (!change || !side) return;
    const line = side === "before" ? change.beforeStart : change.afterStart;
    editorRef.current?.revealLineInCenter(line);
    editorRef.current?.setPosition({ lineNumber: line, column: 1 });
  }, [comparison, hunk, side]);

  return (
    <div
      ref={container}
      className={styles.editor}
      aria-label={`${side ?? "Source"}: ${source.path}`}
    />
  );
}
