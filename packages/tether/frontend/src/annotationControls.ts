import * as monaco from "monaco-editor/editor/editor.api";
import styles from "./AnnotationControls.module.css";

export function lastSelectedLine(range: monaco.IRange) {
  if (range.endColumn === 1 && range.endLineNumber > range.startLineNumber) {
    return range.endLineNumber - 1;
  }
  return range.endLineNumber;
}

export function lineRange(
  model: monaco.editor.ITextModel,
  start: number,
  end: number,
) {
  const endColumn = model.getLineMaxColumn(end);
  if (endColumn === 1 && end < model.getLineCount()) {
    return new monaco.Range(start, 1, end + 1, 1);
  }
  return new monaco.Range(start, 1, end, endColumn);
}

export function addAnnotationControls(
  editor: monaco.editor.IStandaloneCodeEditor,
  annotate: (range: monaco.Range) => void,
) {
  let line = 1;
  let contextLine: number | undefined;
  const enabled = editor.createContextKey<boolean>("tetherCanAnnotate", true);
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "+";
  button.className = styles.add;
  button.setAttribute("aria-keyshortcuts", "Control+Enter Meta+Enter");
  editor.updateOptions({ glyphMargin: true });

  function selectedLines(at: number) {
    const model = editor.getModel()!;
    const selection = editor.getSelection()!;
    const last = lastSelectedLine(selection);
    if (!selection.isEmpty() && at >= selection.startLineNumber && at <= last) {
      return lineRange(model, selection.startLineNumber, last);
    }
    return lineRange(model, at, at);
  }

  // Overlay widgets keep the gutter button in the accessibility tree.
  const widget: monaco.editor.IOverlayWidget = {
    getId: () => "tether.annotate",
    getDomNode: () => button,
    getPosition: () => {
      const layout = editor.getLayoutInfo();
      const height = editor.getOption(monaco.editor.EditorOption.lineHeight);
      const top = editor.getTopForLineNumber(line) - editor.getScrollTop();
      button.style.width = `${layout.glyphMarginWidth - 4}px`;
      button.style.height = `${height - 4}px`;
      button.style.visibility =
        top < 0 || top + height > layout.height ? "hidden" : "visible";
      return { preference: { top: top + 2, left: layout.glyphMarginLeft + 2 } };
    },
  };

  function refresh(at: number) {
    line = at;
    const range = selectedLines(line);
    const last = lastSelectedLine(range);
    const label =
      last === range.startLineNumber
        ? `Annotate line ${range.startLineNumber}`
        : `Annotate lines ${range.startLineNumber}–${last}`;
    button.setAttribute("aria-label", label);
    button.title = `${label} (Ctrl/Cmd+Enter). Drag over line numbers to select a range.`;
    editor.layoutOverlayWidget(widget);
  }

  function submit(at: number) {
    if (button.disabled) return;
    const range = selectedLines(at);
    editor.setSelection(range);
    annotate(range);
  }

  button.onmousedown = (event) => {
    event.preventDefault();
    event.stopPropagation();
  };
  button.onclick = (event) => {
    event.stopPropagation();
    submit(line);
  };
  editor.addOverlayWidget(widget);
  refresh(1);
  const subscriptions = [
    editor.onDidScrollChange(() => editor.layoutOverlayWidget(widget)),
    editor.onDidLayoutChange(() => editor.layoutOverlayWidget(widget)),
    editor.onDidChangeViewZones(() => editor.layoutOverlayWidget(widget)),
    editor.onMouseMove(({ target }) => {
      if (target.position) refresh(target.position.lineNumber);
    }),
    editor.onContextMenu(({ target }) => {
      contextLine = target.position?.lineNumber;
    }),
    editor.onKeyDown(() => {
      contextLine = undefined;
    }),
    editor.onDidChangeCursorSelection(({ selection }) => {
      contextLine = undefined;
      refresh(
        Math.min(selection.positionLineNumber, lastSelectedLine(selection)),
      );
    }),
    editor.onDidChangeModel(() => refresh(1)),
    editor.addAction({
      id: "tether.annotateLine",
      label: "Annotate line or selection",
      precondition: "tetherCanAnnotate",
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter],
      contextMenuGroupId: "tether",
      run: () => {
        submit(contextLine ?? editor.getPosition()!.lineNumber);
        contextLine = undefined;
      },
    }),
  ];

  return {
    setEnabled(value: boolean) {
      enabled.set(value);
      button.disabled = !value;
    },
    dispose() {
      for (const subscription of subscriptions) subscription.dispose();
      editor.removeOverlayWidget(widget);
      enabled.reset();
    },
  };
}
