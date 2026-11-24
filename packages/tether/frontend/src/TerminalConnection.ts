import type { Terminal } from "@xterm/xterm";
import { api } from "./api";
import type { Dimensions, Frame, FrameStamp } from "./protocol";
import { TerminalDisplay } from "./TerminalDisplay";

type Attachment = {
  attachment: string;
  runtime: string;
  generation: number;
  control: boolean;
};

export class TerminalConnection {
  readonly display: TerminalDisplay;
  error = "";
  control = false;
  connected = false;
  exited = false;
  private lifetime = new AbortController();
  private cycle: Promise<void> | undefined;
  private attachment: Attachment | undefined;
  private fresh = false;
  private input = "";
  private writing = false;
  private disposed = false;
  private claim = false;
  private stop = false;
  private size: Dimensions | undefined;

  constructor(
    private readonly terminal: Terminal,
    private readonly endpoint: string,
    private readonly session: string,
    private readonly runtime: string,
    private readonly changed: () => void,
  ) {
    this.display = new TerminalDisplay(terminal, runtime, () => {
      if (this.display.paused) this.fresh = false;
      this.update();
    });
    terminal.options.disableStdin = true;
  }

  get ready(): boolean {
    return (
      this.connected &&
      this.control &&
      this.fresh &&
      !this.exited &&
      !this.display.paused &&
      !this.display.rendering
    );
  }

  private update(): void {
    if (this.disposed) return;
    this.terminal.options.disableStdin = !this.ready;
    this.changed();
  }

  private request<T>(method: string, input: object = {}): Promise<T> {
    return api<T>(`${this.endpoint}/${method}`, {
      method: "POST",
      signal: AbortSignal.any([
        this.lifetime.signal,
        AbortSignal.timeout(10_000),
      ]),
      body: JSON.stringify({
        session: this.session,
        attachment: this.attachment?.attachment,
        generation: this.attachment?.generation,
        ...input,
      }),
    });
  }

  get canReconnect(): boolean {
    return !this.disposed && !this.cycle && !this.writing;
  }

  connect(): void {
    if (!this.canReconnect) return;
    this.lifetime = new AbortController();
    this.error = "";
    this.attachment = undefined;
    this.claim = false;
    this.stop = false;
    this.cycle = this.run().finally(() => {
      this.cycle = undefined;
      this.update();
    });
  }

  private async run(): Promise<void> {
    try {
      this.attachment = await this.request<Attachment>("attachTerminal");
      if (this.attachment.runtime !== this.runtime)
        throw new Error("Terminal runtime changed");
      this.connected = true;
      while (!this.lifetime.signal.aborted) {
        const state = await this.request<{
          generation: number;
          control: boolean;
          status: string;
        }>("terminalHeartbeat", { paused: this.display.paused });
        if (this.attachment.generation !== state.generation) {
          this.fresh = false;
          this.stop = false;
        }
        this.attachment.generation = state.generation;
        this.control = state.control;
        this.exited = state.status === "exited";
        this.update();
        if (this.claim) {
          this.claim = false;
          const claimed = await this.request<{ generation: number }>(
            "claimTerminal",
          );
          this.attachment.generation = claimed.generation;
          this.control = true;
          this.fresh = false;
        }
        if (this.stop && this.ready) {
          this.stop = false;
          this.fresh = false;
          this.update();
          await this.request("stopSession");
        }
        if (this.size && this.ready) {
          const dimensions = this.size;
          this.size = undefined;
          this.fresh = false;
          this.update();
          await this.request("resizeTerminal", { dimensions });
        }
        if (!this.display.paused && !this.display.rendering)
          await this.receive();
        await new Promise<void>((resolve) => setTimeout(resolve, 500));
      }
    } catch (error) {
      if (!this.lifetime.signal.aborted) this.fail(error);
    } finally {
      this.connected = false;
      this.fresh = false;
      this.update();
      if (this.attachment) {
        void api(`${this.endpoint}/detachTerminal`, {
          method: "POST",
          signal: AbortSignal.timeout(5000),
          body: JSON.stringify({
            session: this.session,
            attachment: this.attachment.attachment,
          }),
        }).catch(() => {});
      }
    }
  }

  private async receive(): Promise<void> {
    const header = await this.request<{ stamp: FrameStamp; length: number }>(
      "terminalFrame",
    );
    if (
      !Number.isSafeInteger(header.length) ||
      header.length < 1 ||
      header.length > 32 * 1024 * 1024 ||
      header.stamp.runtime !== this.runtime
    )
      throw new Error("Invalid terminal frame header");
    const bytes = new Uint8Array(header.length);
    let offset = 0;
    while (offset < bytes.length) {
      const chunk = await this.request<{ bytes: number[] }>("terminalChunk", {
        offset,
      });
      if (
        !Array.isArray(chunk.bytes) ||
        chunk.bytes.length === 0 ||
        chunk.bytes.length > 65536 ||
        chunk.bytes.length > bytes.length - offset ||
        chunk.bytes.some(
          (byte) => !Number.isInteger(byte) || byte < 0 || byte > 255,
        )
      ) {
        throw new Error("Invalid terminal frame chunk");
      }
      bytes.set(chunk.bytes, offset);
      offset += chunk.bytes.length;
    }
    const frame: Frame = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
    if (
      frame.stamp.runtime !== header.stamp.runtime ||
      frame.stamp.revision !== header.stamp.revision
    ) {
      throw new Error("Terminal frame identity mismatch");
    }
    const alreadyDisplayed =
      this.display.displayedStamp?.revision === frame.stamp.revision;
    const result = alreadyDisplayed
      ? "displayed"
      : await this.display.apply(frame);
    const displayed = result === "displayed" && !this.display.paused;
    await this.request("terminalAck", { stamp: frame.stamp, displayed });
    this.fresh = displayed && !this.display.paused;
    this.update();
  }

  send(text: string): void {
    if (!this.ready) return;
    if (new TextEncoder().encode(this.input + text).length > 4096) {
      this.fail(
        new Error("Terminal input exceeds the 4 KiB pending-input limit"),
      );
      return;
    }
    this.input += text;
    if (this.writing) return;
    void this.flushInput();
  }

  private async flushInput(): Promise<void> {
    this.writing = true;
    try {
      while (this.input) {
        if (
          !this.connected ||
          !this.control ||
          !this.fresh ||
          this.display.paused
        ) {
          throw new Error(
            "Pending input cancelled after terminal state changed",
          );
        }
        const text = this.input;
        this.input = "";
        await this.request("terminalInput", { text });
      }
    } catch (error) {
      this.fail(
        new Error(
          `Input delivery is uncertain. Inspect the terminal before typing again. ${String(error)}`,
        ),
      );
    } finally {
      this.input = "";
      this.writing = false;
      this.update();
    }
  }

  takeControl(): void {
    this.claim = true;
  }
  terminate(): void {
    this.stop = true;
  }
  resize(dimensions: Dimensions): void {
    if (
      dimensions.columns !== this.terminal.cols ||
      dimensions.rows !== this.terminal.rows
    )
      this.size = dimensions;
  }
  resume(): void {
    this.fresh = false;
    this.terminal.clearSelection();
    this.terminal.scrollToBottom();
    this.update();
  }

  private fail(error: unknown): void {
    this.error = error instanceof Error ? error.message : String(error);
    this.connected = false;
    this.fresh = false;
    this.lifetime.abort();
    this.update();
  }

  dispose(): void {
    this.disposed = true;
    this.lifetime.abort();
    this.connected = false;
    this.input = "";
    this.display.dispose();
  }
}
