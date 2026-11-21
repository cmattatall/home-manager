import { useEffect, useRef, useState } from "react";
import * as monaco from "monaco-editor/editor/editor.api";
import EditorWorker from "monaco-editor/editor/editor.worker?worker";
import "monaco-editor/editor/browser/coreCommands";
import "monaco-editor/editor/contrib/contextmenu/browser/contextmenu";
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
  onAnnotate?: (selection: SourceSelection) => void;
  onExplorationChange?: (active: boolean) => void;
}

interface ReviewEditor {
  editor: monaco.editor.IStandaloneCodeEditor;
  canAnnotate: monaco.editor.IContextKey<boolean>;
}

self.MonacoEnvironment = { getWorker: () => new EditorWorker() };

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
    "diffEditor.removedLineBackground": "#682c354d",
    "diffEditor.insertedLineBackground": "#21523c66",
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
  onAnnotate,
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
        {(comparison || source) && (
          <SourceEditor
            worktree={worktree}
            source={source}
            comparison={comparison}
            hunk={hunk}
            onSelection={selectReview}
            onAnnotate={onAnnotate}
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
  hunk,
  onSelection,
  onAnnotate,
}: SourceViewerProps & {
  hunk: number;
}) {
  const container = useRef<HTMLDivElement>(null);
  const editors = useRef<ReviewEditor[]>([]);
  const callbacks = useRef({ onSelection, onAnnotate });
  callbacks.current = { onSelection, onAnnotate };
  const annotationEnabled = !!onAnnotate;

  useEffect(() => {
    const sources = comparison
      ? [comparison.before, comparison.after]
      : [source];
    const models = sources.map((captured, index) => {
      const model = monaco.editor.createModel(
        captured?.text ?? "",
        captured?.path.endsWith(".go") ? "tether-source-go" : "plaintext",
        monaco.Uri.from({
          scheme: "tether",
          authority: worktree,
          path: `/${captured?.path ?? "absent"}`,
          query: new URLSearchParams({
            review: comparison?.id ?? source!.id,
            side: comparison ? (index === 0 ? "before" : "after") : "source",
          }).toString(),
        }),
      );
      if (captured) highlightSource(model, captured);
      return model;
    });
    let widget:
      monaco.editor.IStandaloneCodeEditor | monaco.editor.IStandaloneDiffEditor;
    let codeEditors: monaco.editor.IStandaloneCodeEditor[];
    if (comparison) {
      const diff = monaco.editor.createDiffEditor(container.current!, {
        ...editorOptions,
        renderSideBySide: true,
        useInlineViewWhenSpaceIsLimited: false,
        enableSplitViewResizing: false,
        originalEditable: false,
        ignoreTrimWhitespace: false,
        renderMarginRevertIcon: false,
        renderGutterMenu: false,
        renderOverviewRuler: false,
        scrollbar: { vertical: "visible" },
        originalAriaLabel: `before: ${comparison.before?.path ?? "File absent"}`,
        modifiedAriaLabel: `after: ${comparison.after?.path ?? "File absent"}`,
      });
      diff.setModel({ original: models[0], modified: models[1] });
      diff.getOriginalEditor().updateOptions({
        scrollbar: { vertical: "hidden", horizontal: "hidden" },
      });
      widget = diff;
      codeEditors = [diff.getOriginalEditor(), diff.getModifiedEditor()];
    } else {
      const editor = monaco.editor.create(container.current!, {
        ...editorOptions,
        model: models[0],
        ariaLabel: `Source: ${source!.path}`,
      });
      widget = editor;
      codeEditors = [editor];
    }
    const subscriptions: monaco.IDisposable[] = [];
    editors.current = codeEditors.map((editor, index) => {
      const canAnnotate = editor.createContextKey(
        "tetherCanAnnotate",
        !!callbacks.current.onAnnotate,
      );
      const captured = sources[index];
      if (captured) {
        let contextLine: number | undefined;
        const captureSelection = (
          selection: monaco.IRange,
        ): SourceSelection => {
          return {
            source: captured,
            selection: {
              startLineNumber: selection.startLineNumber,
              startColumn: selection.startColumn,
              endLineNumber: selection.endLineNumber,
              endColumn: selection.endColumn,
            },
            review: comparison
              ? {
                  comparisonId: comparison.id,
                  side: index === 0 ? "before" : "after",
                }
              : undefined,
          };
        };
        subscriptions.push(
          editor.onContextMenu(({ target }) => {
            contextLine = target.position?.lineNumber;
          }),
          editor.onKeyDown(() => {
            contextLine = undefined;
          }),
          editor.onDidChangeCursorSelection(({ selection }) => {
            contextLine = undefined;
            callbacks.current.onSelection(
              selection.isEmpty() ? null : captureSelection(selection),
            );
          }),
        );
        subscriptions.push(
          editor.addAction({
            id: "tether.annotateLine",
            label: "Annotate line",
            precondition: "tetherCanAnnotate",
            contextMenuGroupId: "tether",
            run: () => {
              const line = contextLine ?? editor.getPosition()!.lineNumber;
              contextLine = undefined;
              const model = models[index];
              const selection =
                line < model.getLineCount()
                  ? new monaco.Range(line, 1, line + 1, 1)
                  : new monaco.Range(
                      line,
                      1,
                      line,
                      model.getLineMaxColumn(line),
                    );
              if (selection.isEmpty()) return;
              editor.setSelection(selection);
              callbacks.current.onAnnotate?.(captureSelection(selection));
            },
          }),
        );
      }
      return { editor, canAnnotate };
    });
    return () => {
      editors.current = [];
      for (const subscription of subscriptions) subscription.dispose();
      widget.dispose();
      for (const model of models) model.dispose();
    };
  }, [worktree, source, comparison]);

  useEffect(() => {
    for (const { canAnnotate } of editors.current)
      canAnnotate.set(annotationEnabled);
  }, [annotationEnabled]);

  useEffect(() => {
    const change = comparison?.hunks[hunk];
    if (!change) return;
    const useAfter = !!comparison?.after && change.afterStart < change.afterEnd;
    const line = useAfter ? change.afterStart : change.beforeStart;
    const editor = editors.current[useAfter ? 1 : 0].editor;
    editor.revealLineInCenter(line);
    editor.setPosition({ lineNumber: line, column: 1 });
  }, [comparison, hunk]);

  return (
    <>
      {comparison && (
        <div className={styles.diffLabels}>
          <div className={styles.sideLabel}>
            {comparison.beforeLabel}
            {!comparison.before && " · File absent on this side"}
          </div>
          <div className={styles.sideLabel}>
            {comparison.afterLabel}
            {!comparison.after && " · File absent on this side"}
          </div>
        </div>
      )}
      <div ref={container} className={styles.editor} />
    </>
  );
}
