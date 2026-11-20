import { useEffect, useRef, useState } from "react";
import * as monaco from "monaco-editor/editor/editor.api";
import "monaco-editor/editor/contrib/contextmenu/browser/contextmenu";
import "monaco-editor/editor/contrib/hover/browser/hoverContribution";
import "monaco-editor/editor/contrib/gotoSymbol/browser/goToCommands";
import "monaco-editor/editor/contrib/gotoSymbol/browser/link/goToDefinitionAtPosition";
import "monaco-editor/editor/standalone/browser/referenceSearch/standaloneReferenceSearch";
import "monaco-editor/editor/standalone/browser/quickAccess/standaloneGotoSymbolQuickAccess";
import "../node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css";
import type { AnalysisSource, Inspection, Source, Symbol } from "./protocol";
import { api } from "./api";
import {
  editorOptions,
  highlightSource,
  type SourceSelection,
} from "./SourceViewer";
import styles from "./Workbench.module.css";

interface Visit {
  model: monaco.editor.ITextModel;
  view: monaco.editor.ICodeEditorViewState | null;
}

const language = "tether-go";
monaco.languages.register({ id: language });

export function GoExplorer({
  worktree,
  endpoint,
  path,
  onSelection,
}: {
  worktree: string;
  endpoint: string;
  path: string;
  onSelection: (selection: SourceSelection | null) => void;
}) {
  const [source, setSource] = useState<AnalysisSource>();
  const [status, setStatus] = useState("Loading current Go analysis…");
  const [retry, setRetry] = useState(0);
  const [activePath, setActivePath] = useState(path);
  const [history, setHistory] = useState({ back: false, forward: false });
  const container = useRef<HTMLDivElement>(null);
  const navigate = useRef<(direction: number) => void>(() => {});
  const symbols = useRef<() => void>(() => {});
  const callback = useRef(onSelection);
  callback.current = onSelection;

  useEffect(() => {
    const controller = new AbortController();
    setSource(undefined);
    setStatus("Loading current Go analysis…");
    api<AnalysisSource>(
      `${endpoint}/analysisSource?${new URLSearchParams({ path })}`,
      { signal: controller.signal },
    )
      .then((result) => {
        setSource(result);
        setStatus("Go · current checkout · gopls ready");
      })
      .catch((error) => {
        if (!controller.signal.aborted) setStatus(error.message);
      });
    return () => controller.abort();
  }, [endpoint, path, retry]);

  useEffect(() => {
    if (!source) return;
    let disposed = false;
    let generation = 0;
    const models = new Map<monaco.editor.ITextModel, Source>();
    const controllers = new Set<AbortController>();
    const back: Visit[] = [];
    const forward: Visit[] = [];
    function modelFor(document: Source) {
      const uri = monaco.Uri.from({
        scheme: "tether",
        authority: worktree,
        path: `/${document.path}`,
        query: new URLSearchParams({
          context: source!.context,
          source: document.id,
        }).toString(),
      });
      const existing = monaco.editor.getModel(uri);
      if (existing && models.has(existing)) return existing;
      const model = monaco.editor.createModel(document.text, language, uri);
      models.set(model, document);
      highlightSource(model, document);
      return model;
    }
    const initial = modelFor(source.source);
    const editor = monaco.editor.create(container.current!, {
      ...editorOptions,
      model: initial,
    });
    editor.addCommand(monaco.KeyMod.Shift | monaco.KeyCode.F12, () => {
      editor.trigger("tether", "editor.action.referenceSearch.trigger", {});
    });
    setActivePath(source.source.path);
    setHistory({ back: false, forward: false });
    const updateHistory = () =>
      setHistory({ back: back.length > 0, forward: forward.length > 0 });

    async function inspect(
      model: monaco.editor.ITextModel,
      position: monaco.IPosition,
      kind: string,
      token: monaco.CancellationToken,
      includeDeclaration = true,
    ) {
      const document = models.get(model);
      if (!document || token.isCancellationRequested) return null;
      const requestedGeneration = generation;
      const controller = new AbortController();
      controllers.add(controller);
      const cancellation = token.onCancellationRequested(() =>
        controller.abort(),
      );
      try {
        const result = await api<Inspection>(
          `${endpoint}/inspect?${new URLSearchParams({
            path: document.path,
            sourceId: document.id,
            context: source!.context,
            kind,
            line: String(position.lineNumber),
            column: String(position.column),
            includeDeclaration: String(includeDeclaration),
          })}`,
          { signal: controller.signal },
        );
        if (
          disposed ||
          requestedGeneration !== generation ||
          model.isDisposed() ||
          token.isCancellationRequested ||
          result.context !== source!.context
        )
          return null;
        return result;
      } catch (error) {
        if (!disposed && !controller.signal.aborted)
          setStatus((error as Error).message);
        return null;
      } finally {
        cancellation.dispose();
        controllers.delete(controller);
      }
    }

    async function locations(
      model: monaco.editor.ITextModel,
      position: monaco.IPosition,
      kind: string,
      token: monaco.CancellationToken,
      includeDeclaration = true,
    ) {
      const result = await inspect(
        model,
        position,
        kind,
        token,
        includeDeclaration,
      );
      return (
        result?.locations.map((location) => ({
          uri: modelFor(location.source).uri,
          range: location.selection,
        })) ?? []
      );
    }
    function symbolTree(symbol: Symbol): monaco.languages.DocumentSymbol {
      return {
        name: symbol.name,
        detail: "",
        kind: symbol.kind - 1,
        tags: [],
        range: symbol.range,
        selectionRange: symbol.selectionRange,
        children: symbol.children.map(symbolTree),
      };
    }

    const subscriptions = [
      editor.onDidChangeModel(() => {
        generation += 1;
      }),
      monaco.languages.registerHoverProvider(language, {
        provideHover: async (model, position, token) => {
          const result = await inspect(model, position, "hover", token);
          return result
            ? {
                contents: result.hover.map((value) => ({
                  value,
                  isTrusted: false,
                  supportHtml: false,
                })),
              }
            : null;
        },
      }),
      monaco.languages.registerDefinitionProvider(language, {
        provideDefinition: (model, position, token) =>
          locations(model, position, "definition", token),
      }),
      monaco.languages.registerTypeDefinitionProvider(language, {
        provideTypeDefinition: (model, position, token) =>
          locations(model, position, "typeDefinition", token),
      }),
      monaco.languages.registerImplementationProvider(language, {
        provideImplementation: (model, position, token) =>
          locations(model, position, "implementation", token),
      }),
      monaco.languages.registerReferenceProvider(language, {
        provideReferences: (model, position, context, token) =>
          locations(
            model,
            position,
            "references",
            token,
            context.includeDeclaration,
          ),
      }),
      monaco.languages.registerDocumentSymbolProvider(language, {
        provideDocumentSymbols: async (model, token) => {
          const result = await inspect(
            model,
            { lineNumber: 1, column: 1 },
            "symbols",
            token,
          );
          return result?.symbols.map(symbolTree) ?? [];
        },
      }),
      monaco.editor.registerEditorOpener({
        openCodeEditor(_origin, uri, selection) {
          const model = monaco.editor.getModel(uri);
          if (!model || !models.has(model)) return false;
          back.push({
            model: editor.getModel()!,
            view: editor.saveViewState(),
          });
          forward.length = 0;
          editor.setModel(model);
          if (selection && "startLineNumber" in selection) {
            editor.setSelection(selection);
            editor.revealRangeInCenter(selection);
          } else if (selection) {
            editor.setPosition(selection);
            editor.revealPositionInCenter(selection);
          }
          setActivePath(models.get(model)!.path);
          updateHistory();
          editor.focus();
          return true;
        },
      }),
      editor.onDidChangeCursorSelection(({ selection }) => {
        const document = models.get(editor.getModel()!);
        callback.current(
          document && !selection.isEmpty()
            ? {
                source: document,
                selection: {
                  startLineNumber: selection.startLineNumber,
                  startColumn: selection.startColumn,
                  endLineNumber: selection.endLineNumber,
                  endColumn: selection.endColumn,
                },
              }
            : null,
        );
      }),
    ];
    symbols.current = () => {
      editor.focus();
      editor.trigger("tether", "editor.action.quickOutline", {});
    };
    navigate.current = (direction) => {
      const origin = direction < 0 ? back : forward;
      const destination = direction < 0 ? forward : back;
      const visit = origin.pop();
      if (!visit) return;
      destination.push({
        model: editor.getModel()!,
        view: editor.saveViewState(),
      });
      editor.setModel(visit.model);
      editor.restoreViewState(visit.view);
      setActivePath(models.get(visit.model)!.path);
      updateHistory();
      editor.focus();
    };
    return () => {
      disposed = true;
      controllers.forEach((controller) => controller.abort());
      subscriptions.forEach((subscription) => subscription.dispose());
      editor.dispose();
      models.forEach((_, model) => model.dispose());
      callback.current(null);
    };
  }, [source, worktree, endpoint]);

  return (
    <div className={styles.viewer}>
      <div className={styles.explorationBar}>
        <button
          disabled={!source || !history.back}
          onClick={() => navigate.current(-1)}
        >
          Back
        </button>
        <button
          disabled={!source || !history.forward}
          onClick={() => navigate.current(1)}
        >
          Forward
        </button>
        <button disabled={!source} onClick={() => symbols.current()}>
          Symbols
        </button>
        <button onClick={() => setRetry((value) => value + 1)}>
          Reload current
        </button>
        <span>{activePath}</span>
      </div>
      <p className={styles.analysisStatus} role="status">
        {status}
      </p>
      {!source && (
        <div className={styles.analysisConsent}>
          <p>
            Go analysis runs gopls and the Go toolchain on this machine. Enable
            it for a worktree you trust. Dependencies must already be available
            locally.
          </p>
          <button
            onClick={async () => {
              try {
                await api(`${endpoint}/enableAnalysis`, {
                  method: "POST",
                });
                setRetry((value) => value + 1);
              } catch (error) {
                setStatus((error as Error).message);
              }
            }}
          >
            Enable Go analysis for this worktree
          </button>
        </div>
      )}
      <div
        className={styles.editor}
        ref={container}
        aria-label={`Current Go source: ${activePath}`}
      />
    </div>
  );
}
