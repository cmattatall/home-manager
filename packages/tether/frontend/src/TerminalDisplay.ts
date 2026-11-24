import { Unicode11Addon } from "@xterm/addon-unicode11";
import type { IDisposable, Terminal } from "@xterm/xterm";
import type { Frame, FrameStamp } from "./protocol";

type Painting = {
  resolve: () => void;
  reject: (error: Error) => void;
};

export class TerminalDisplay implements IDisposable {
  private readonly element: HTMLElement;
  private readonly events = new AbortController();
  private readonly listeners: IDisposable[];
  private readonly unicode = new Unicode11Addon();
  private dragging = false;
  private disposed = false;
  private receivedRevision = -1;
  private held: Frame | undefined;
  private painting: Painting | undefined;
  private displayed: FrameStamp | undefined;

  constructor(
    private readonly terminal: Terminal,
    private readonly runtime: string,
    private readonly changed: () => void,
  ) {
    if (!terminal.element)
      throw new Error("Open the terminal before attaching");
    this.element = terminal.element;
    terminal.loadAddon(this.unicode);
    terminal.unicode.activeVersion = "11";
    this.listeners = [
      terminal.onSelectionChange(() => this.selectionChanged()),
      terminal.onScroll(() => this.selectionChanged()),
    ];

    const options = { capture: true, signal: this.events.signal };
    for (const event of ["mousedown", "keydown", "contextmenu"]) {
      this.element.addEventListener(event, this.blockDuringPaint, options);
    }
    this.element.addEventListener("mousedown", this.mouseDown, options);
    this.element.ownerDocument.addEventListener(
      "mouseup",
      this.mouseUp,
      options,
    );
    this.element.ownerDocument.defaultView?.addEventListener(
      "blur",
      this.mouseUp,
      options,
    );
  }

  get paused(): boolean {
    const buffer = this.terminal.buffer.active;
    return (
      this.dragging ||
      this.terminal.hasSelection() ||
      buffer.viewportY < buffer.baseY
    );
  }

  get rendering(): boolean {
    return this.painting !== undefined;
  }

  get displayedStamp(): FrameStamp | undefined {
    return this.displayed;
  }

  async apply(frame: Frame): Promise<"displayed" | "held"> {
    if (this.disposed) throw new Error("Terminal display disposed");
    if (this.rendering) throw new Error("Terminal display is painting");
    if (frame.stamp.runtime !== this.runtime) {
      throw new Error("Terminal runtime changed");
    }
    if (
      !Number.isSafeInteger(frame.stamp.revision) ||
      frame.stamp.revision <= this.receivedRevision
    ) {
      throw new Error("Stale or invalid terminal revision");
    }
    const { columns, rows } = frame.dimensions;
    if (
      !Number.isInteger(columns) ||
      columns < 2 ||
      columns > 512 ||
      !Number.isInteger(rows) ||
      rows < 1 ||
      rows > 200
    ) {
      throw new Error("Invalid terminal dimensions");
    }
    this.receivedRevision = frame.stamp.revision;
    if (this.paused) {
      this.held = frame;
      this.changed();
      return "held";
    }
    this.held = undefined;
    await this.paint(frame);
    return "displayed";
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.events.abort();
    for (const listener of this.listeners) listener.dispose();
    this.unicode.dispose();
    this.held = undefined;
    this.painting?.reject(new Error("Terminal display disposed"));
    this.painting = undefined;
  }

  private blockDuringPaint = (event: Event): void => {
    if (!this.rendering) return;
    // A queued terminal reset can erase a selection begun during painting.
    event.preventDefault();
    event.stopImmediatePropagation();
  };

  private mouseDown = (event: MouseEvent): void => {
    if (event.button !== 0) return;
    const forceSelection = navigator.platform.startsWith("Mac")
      ? event.altKey && this.terminal.options.macOptionClickForcesSelection
      : event.shiftKey;
    if (this.terminal.modes.mouseTrackingMode !== "none" && !forceSelection) {
      return;
    }
    this.dragging = true;
    this.changed();
  };

  private mouseUp = (): void => {
    this.dragging = false;
    // xterm finalizes its selection in the same mouseup event.
    queueMicrotask(() => this.selectionChanged());
  };

  private selectionChanged(): void {
    if (this.disposed || this.rendering) return;
    if (!this.paused && this.held) {
      const frame = this.held;
      this.held = undefined;
      void this.paint(frame).catch((error: unknown) => {
        if (!this.disposed) throw error;
      });
    }
    this.changed();
  }

  private paint(frame: Frame): Promise<void> {
    return new Promise((resolve, reject) => {
      this.painting = { resolve, reject };
      this.changed();
      this.terminal.resize(frame.dimensions.columns, frame.dimensions.rows);
      this.terminal.write(frame.painting, () => {
        if (this.disposed) return;
        this.displayed = frame.stamp;
        const painting = this.painting!;
        this.painting = undefined;
        painting.resolve();
        this.changed();
      });
    });
  }
}
