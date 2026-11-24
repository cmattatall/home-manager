import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { after, before, test } from "node:test";
import { build } from "esbuild";
import { chromium } from "playwright";

let browser;
let bundle;
let css;

before(async () => {
  const built = await build({
    stdin: {
      contents: `export { Terminal } from '@xterm/xterm';
        export { TerminalDisplay } from '../../frontend/src/TerminalDisplay';`,
      resolveDir: process.cwd(),
    },
    bundle: true,
    format: "iife",
    globalName: "Library",
    write: false,
  });
  bundle = built.outputFiles[0].text;
  css = await readFile("node_modules/@xterm/xterm/css/xterm.css", "utf8");
  browser = await chromium.launch({ executablePath: process.env.CHROME_BIN });
});

after(async () => browser?.close());

async function viewer(t) {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 800 },
    deviceScaleFactor: 2,
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  t.after(async () => {
    await page.close();
    assert.deepEqual(errors, []);
  });
  await page.setContent(
    '<div id="terminal"></div><output id="state"></output>',
  );
  await page.addStyleTag({ content: css });
  await page.addScriptTag({ content: bundle });
  await page.evaluate(() => {
    const terminal = new Library.Terminal({
      allowProposedApi: true,
      cols: 40,
      rows: 6,
      scrollback: 10000,
    });
    terminal.open(document.querySelector("#terminal"));
    const displayedRevisions = [];
    const display = new Library.TerminalDisplay(terminal, "runtime", () => {
      terminal.options.disableStdin = display.paused || display.rendering;
      const revision = display.displayedStamp?.revision;
      if (revision !== undefined && revision !== displayedRevisions.at(-1)) {
        displayedRevisions.push(revision);
      }
      document.querySelector("#state").textContent = display.paused
        ? "Display paused for selection or scrollback"
        : display.rendering
          ? "Updating display"
          : "Live";
    });
    const input = [];
    terminal.onData((data) => input.push(data));
    Object.assign(window, {
      terminal,
      display,
      input,
      displayedRevisions,
      frame: (revision, text, columns = 40, rows = 6) => ({
        stamp: { runtime: "runtime", revision },
        dimensions: { columns, rows },
        painting: `\x1bc\x1b[?1047l\x1b[3J\x1b[?7l${text}`,
        history_rows: 0,
        history_bytes: 0,
        rejected_osc: 0,
        rejected_marks: 0,
      }),
      resume: () => {
        terminal.clearSelection();
        terminal.scrollToBottom();
      },
      snapshot: () => ({
        selection: terminal.getSelection(),
        viewport: terminal.buffer.active.viewportY,
        revision: display.displayedStamp?.revision,
        columns: terminal.cols,
        rows: terminal.rows,
        paused: display.paused,
        text: Array.from({ length: terminal.buffer.active.length }, (_, row) =>
          terminal.buffer.active.getLine(row).translateToString(true),
        ),
      }),
    });
  });
  return page;
}

test("selection pins copied bytes, viewport and dimensions across replacement frames", async (t) => {
  const page = await viewer(t);
  await page.evaluate(async () => {
    await display.apply(
      frame(1, "duplicate\r\nCOPY café 界 🔒\r\nduplicate\r\nOLD"),
    );
    terminal.select(0, 1, 15);
  });
  const pinned = await page.evaluate(() => snapshot());
  assert.equal(pinned.selection, "COPY café 界 🔒");
  assert.equal(pinned.paused, true);
  const results = await page.evaluate(async () => {
    const results = [];
    for (let revision = 2; revision <= 101; revision++) {
      results.push(
        await display.apply(frame(revision, `NEW ${revision}`, 31, 9)),
      );
    }
    return results;
  });
  assert.deepEqual(results, Array(100).fill("held"));
  assert.deepEqual(await page.evaluate(() => snapshot()), pinned);
  const copy = await page.evaluate(() => {
    const clipboard = new DataTransfer();
    terminal.element.dispatchEvent(
      new ClipboardEvent("copy", { bubbles: true, clipboardData: clipboard }),
    );
    return clipboard.getData("text/plain");
  });
  assert.equal(copy, "COPY café 界 🔒");
  await page.evaluate(() => terminal.focus());
  await page.keyboard.type("ignored");
  await page.evaluate(() => terminal.paste("PASTED WHILE PAUSED"));
  assert.deepEqual(await page.evaluate(() => input), []);
  assert.deepEqual(await page.evaluate(() => snapshot()), pinned);
  await page.evaluate(() => resume());
  await page.waitForFunction(() => display.displayedStamp.revision === 101);
  const resumed = await page.evaluate(() => snapshot());
  assert.equal(resumed.text[0], "NEW 101");
  assert.equal(resumed.columns, 31);
  assert.equal(resumed.rows, 9);
  assert.equal(resumed.selection, "");
  assert.equal(resumed.paused, false);
  assert.deepEqual(await page.evaluate(() => displayedRevisions), [1, 101]);
  await page.keyboard.type("accepted");
  assert.equal(await page.evaluate(() => input.join("")), "accepted");
});

test("scrollback stays readable through history eviction and alternate-screen entry", async (t) => {
  const page = await viewer(t);
  await page.evaluate(async () => {
    const rows = Array.from({ length: 30 }, (_, row) => `record-${row}`);
    await display.apply(frame(1, rows.join("\r\n")));
    terminal.scrollToLine(3);
    terminal.select(0, 4, 8);
  });
  const pinned = await page.evaluate(() => snapshot());
  assert.equal(pinned.selection, "record-4");
  assert.equal(pinned.viewport, 3);
  await page.evaluate(() => display.apply(frame(2, "retained-newest-only")));
  await page.evaluate(() =>
    display.apply(frame(3, "\x1b[?1047hNEW ALTERNATE", 33, 7)),
  );
  assert.deepEqual(await page.evaluate(() => snapshot()), pinned);
  await page.evaluate(() => terminal.clearSelection());
  assert.equal(await page.evaluate(() => display.paused), true);
  assert.equal(await page.evaluate(() => display.displayedStamp.revision), 1);
  await page.evaluate(() => terminal.scrollToBottom());
  await page.waitForFunction(() => display.displayedStamp.revision === 3);
  assert.equal(
    await page.evaluate(() => terminal.buffer.active.type),
    "alternate",
  );
  assert.equal(await page.evaluate(() => snapshot().text[0]), "NEW ALTERNATE");
});

test("a pointer gesture pins output before its first selected character", async (t) => {
  const page = await viewer(t);
  await page.evaluate(() => display.apply(frame(1, "SELECT ME AND KEEP ME")));
  const screen = await page.locator(".xterm-screen").boundingBox();
  const cellWidth = screen.width / 40;
  await page.mouse.move(screen.x + cellWidth * 0.1, screen.y + 8);
  await page.mouse.down();
  assert.equal(await page.evaluate(() => terminal.hasSelection()), false);
  assert.equal(await page.evaluate(() => display.paused), true);
  assert.equal(
    await page.evaluate(() => display.apply(frame(2, "CHANGED DURING DRAG"))),
    "held",
  );
  await page.mouse.move(screen.x + cellWidth * 9.1, screen.y + 8, { steps: 5 });
  await page.mouse.up();
  assert.equal(await page.evaluate(() => terminal.getSelection()), "SELECT ME");
  assert.equal(
    await page.evaluate(() => snapshot().text[0]),
    "SELECT ME AND KEEP ME",
  );
  await page.evaluate(() => resume());
  await page.waitForFunction(() => display.displayedStamp.revision === 2);
  assert.equal(
    await page.evaluate(() => snapshot().text[0]),
    "CHANGED DURING DRAG",
  );

  await page.mouse.down();
  await page.evaluate(() => display.apply(frame(3, "CLICK RELEASED")));
  await page.mouse.up();
  await page.waitForFunction(() => display.displayedStamp.revision === 3);
});

test("recovery frames preserve selection and reject stale or foreign identities", async (t) => {
  const page = await viewer(t);
  await page.evaluate(async () => {
    await display.apply(frame(10, "ORIGINAL"));
    terminal.select(0, 0, 8);
  });
  const pinned = await page.evaluate(() => snapshot());
  await page.evaluate(() => display.apply(frame(20, "RECOVERED")));
  for (const [revision, runtime] of [
    [10, "runtime"],
    [20, "runtime"],
    [21, "foreign"],
  ]) {
    await assert.rejects(
      page.evaluate(
        ([revision, runtime]) => {
          const candidate = frame(revision, "WRONG");
          candidate.stamp.runtime = runtime;
          return display.apply(candidate);
        },
        [revision, runtime],
      ),
      /Stale|runtime changed/,
    );
  }
  assert.deepEqual(await page.evaluate(() => snapshot()), pinned);
  await page.evaluate(() => resume());
  await page.waitForFunction(() => display.displayedStamp.revision === 20);
  assert.equal(await page.evaluate(() => snapshot().text[0]), "RECOVERED");
  await page.evaluate(async () => {
    terminal.select(0, 0, 9);
    await display.apply(frame(21, "DISCARDED"));
    display.dispose();
    terminal.clearSelection();
  });
  await assert.rejects(
    page.evaluate(() => display.apply(frame(22, "DISPOSED"))),
    /disposed/,
  );
  assert.equal(await page.evaluate(() => snapshot().text[0]), "RECOVERED");
});

test("painting excludes overlapping writes and gestures, and disposal settles callers", async (t) => {
  const page = await viewer(t);
  const result = await page.evaluate(async () => {
    await display.apply(frame(1, "READY"));
    const painting = display.apply(frame(2, "PAINTED"));
    const mouse = new MouseEvent("mousedown", {
      button: 0,
      bubbles: true,
      cancelable: true,
    });
    terminal.element.dispatchEvent(mouse);
    const blocked = mouse.defaultPrevented;
    const key = new KeyboardEvent("keydown", {
      key: "a",
      metaKey: true,
      bubbles: true,
      cancelable: true,
    });
    terminal.textarea.dispatchEvent(key);
    const keyBlocked = key.defaultPrevented;
    let overlap;
    try {
      await display.apply(frame(3, "OVERLAP"));
    } catch (error) {
      overlap = error.message;
    }
    await painting;
    const pending = display.apply(frame(4, "CANCELLED"));
    display.dispose();
    terminal.dispose();
    let disposed;
    try {
      await pending;
    } catch (error) {
      disposed = error.message;
    }
    return { blocked, keyBlocked, overlap, disposed };
  });
  assert.deepEqual(result, {
    blocked: true,
    keyBlocked: true,
    overlap: "Terminal display is painting",
    disposed: "Terminal display disposed",
  });
});

test("harness mouse reports remain available and modified drags select text", async (t) => {
  const page = await viewer(t);
  await page.evaluate(() => {
    terminal.options.macOptionClickForcesSelection = true;
    return display.apply(frame(1, "SELECT ME\x1b[?1000h\x1b[?1006h"));
  });
  const screen = await page.locator(".xterm-screen").boundingBox();
  const cellWidth = screen.width / 40;
  await page.mouse.click(screen.x + cellWidth * 0.1, screen.y + 8);
  assert.deepEqual(await page.evaluate(() => input), [
    "\x1b[<0;1;1M",
    "\x1b[<0;1;1m",
  ]);
  assert.equal(await page.evaluate(() => display.paused), false);
  const modifier = await page.evaluate(() =>
    navigator.platform.startsWith("Mac") ? "Alt" : "Shift",
  );
  await page.keyboard.down(modifier);
  await page.mouse.move(screen.x + cellWidth * 0.1, screen.y + 8);
  await page.mouse.down();
  assert.equal(await page.evaluate(() => display.paused), true);
  await page.evaluate(() => display.apply(frame(2, "UPDATED")));
  await page.mouse.move(screen.x + cellWidth * 9.1, screen.y + 8, { steps: 5 });
  await page.mouse.up();
  await page.keyboard.up(modifier);
  assert.equal(await page.evaluate(() => terminal.getSelection()), "SELECT ME");
  assert.equal(await page.evaluate(() => input.length), 2);
});
