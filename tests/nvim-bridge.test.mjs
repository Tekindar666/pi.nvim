import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { access } from "node:fs/promises";
import { createRequire } from "node:module";
import { createConnection } from "node:net";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";

// Resolve the development runtime locally; consumers use Pi's bundled imports.
const piPackage = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
const requirePi = createRequire(piPackage);
const { createJiti } = requirePi("jiti");
const piModules = createJiti(piPackage);
const jiti = createJiti(import.meta.url, {
  alias: {
    "@earendil-works/pi-coding-agent": fileURLToPath(piModules.esmResolve("@earendil-works/pi-coding-agent")),
    "@earendil-works/pi-ai": fileURLToPath(piModules.esmResolve("@earendil-works/pi-ai/compat")),
    typebox: fileURLToPath(piModules.esmResolve("typebox")),
  },
});
const bridge = await jiti.import(
  fileURLToPath(new URL("../extensions/nvim-bridge.ts", import.meta.url)),
  { default: true },
);

async function connectBridge(t) {
  const previousPane = process.env.TMUX_PANE;
  process.env.TMUX_PANE = "%test";
  t.after(() => {
    if (previousPane === undefined) delete process.env.TMUX_PANE;
    else process.env.TMUX_PANE = previousPane;
  });

  const handlers = new Map();
  const tools = new Map();
  const state = { draft: "", sent: [], option: undefined, failSend: false };
  const ctx = {
    cwd: "/project",
    hasUI: true,
    ui: {
      getEditorText: () => state.draft,
      setEditorText: (text) => { state.draft = text; },
      setStatus: () => {},
    },
  };
  bridge({
    on: (name, handler) => handlers.set(name, handler),
    registerTool: (tool) => tools.set(tool.name, tool),
    sendUserMessage: (text, options) => {
      if (state.failSend) throw new Error("Submission rejected");
      state.sent.push({ text, options });
    },
    exec: async (command, args) => {
      assert.equal(command, "tmux");
      assert.ok(args.includes("%test"));
      if (args[0] === "show-options") return { code: 0, stdout: state.option ?? "" };
      if (args.includes("-u")) state.option = undefined;
      else state.option = args.at(-1);
      return { code: 0, stdout: "" };
    },
  });
  t.after(() => handlers.get("session_shutdown")({}, ctx));
  await handlers.get("session_start")({}, ctx);
  await access(state.option);

  const socket = createConnection(state.option);
  t.after(() => socket.destroy());
  await once(socket, "connect");
  const lines = createInterface({ input: socket })[Symbol.asyncIterator]();
  let id = 0;
  const request = async (message) => {
    socket.write(`${JSON.stringify({ version: 1, id: String(++id), ...message })}\n`);
    const line = await lines.next();
    return line.done ? undefined : JSON.parse(line.value);
  };
  return { state, request, tools, socket, lines, ctx, handlers };
}

const context = {
  file: "/project/example.ts",
  cursor: { line: 3, column: 1 },
  selection: { start: { line: 2, column: 1 }, end: { line: 3, column: 5 } },
  changedtick: 7,
};

test("real Neovim exchanges drafts, unsaved buffers, quickfix and status", { timeout: 15000 }, async (t) => {
  const { state, tools, ctx, handlers } = await connectBridge(t);
  const editor = spawn("nvim", ["--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/integration.lua"], {
    env: { ...process.env, PI_TEST_SOCKET: state.option },
  });
  t.after(() => editor.kill());
  let output = "";
  editor.stdout.on("data", (data) => { output += data; });
  editor.stderr.on("data", (data) => { output += data; });
  const exited = once(editor, "exit");
  const waitFor = async (predicate) => {
    for (let i = 0; i < 300; i++) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.fail(`Editor condition timed out: ${output}`);
  };
  await waitFor(() => state.draft.includes("Neovim context"));
  assert.deepEqual(state.sent, []);
  const read = await tools.get("nvim_read_buffer").execute("read", {}, undefined, undefined, ctx);
  assert.equal(read.details.modified, true);
  assert.deepEqual(read.details.lines, ["unsaved integration text"]);
  const quickfix = await tools.get("nvim_publish_quickfix").execute("qf", {
    title: "Integration", items: [{ path: "example.ts", line: 1, message: "Read this first" }],
  }, undefined, undefined, ctx);
  assert.equal(quickfix.details.count, 1);
  handlers.get("agent_start")();
  await waitFor(() => output.includes("WORKING"));
  handlers.get("agent_settled")();
  const [code] = await exited;
  assert.equal(code, 0, output);
  assert.match(output, /INTEGRATION PASSED/);
});

test("context, prompt, diagnostics and hover append to the draft without sending", async (t) => {
  const { state, request } = await connectBridge(t);
  state.draft = "Existing user text";
  for (const [label, content] of [
    ["Neovim context", undefined],
    ["Neovim prompt", "Explain this selection"],
    ["Neovim diagnostics", "Type mismatch"],
    ["Neovim LSP hover", "interface Example"],
  ]) {
    const result = await request({ type: "draft", label, content, context });
    assert.equal(result.ok, true);
    assert.equal(result.result.draft, state.draft);
    assert.ok(state.draft.includes(label));
    if (content) assert.ok(state.draft.includes(content));
    assert.deepEqual(state.sent, []);
  }
  assert.ok(state.draft.startsWith("Existing user text\n\n"));
  assert.ok(state.draft.includes("Selection: 2:1-3:5"));
  assert.ok(state.draft.includes("Neovim changedtick: 7"));
});

test("text-only prompts omit buffer metadata and clear the implicit buffer without disconnecting tools", async (t) => {
  const { state, request, tools, socket, lines, ctx } = await connectBridge(t);
  await request({ type: "draft", label: "Neovim context", context });
  state.draft = "Existing draft";
  const result = await request({
    type: "draft",
    label: "Neovim prompt",
    content: "Explain the design\nincluding the trade-offs",
    context: { projectRoot: "/project", tmuxPane: "%test" },
  });
  assert.equal(result.ok, true);
  assert.equal(state.draft, "Existing draft\n\nNeovim prompt:\nExplain the design\nincluding the trade-offs");
  assert.deepEqual(state.sent, []);

  const readBuffer = tools.get("nvim_read_buffer");
  await assert.rejects(readBuffer.execute("test", {}, undefined, undefined, ctx), /No Neovim buffer path/);
  const reading = readBuffer.execute("test", { path: "example.ts" }, undefined, undefined, ctx);
  const message = JSON.parse((await lines.next()).value);
  assert.equal(message.method, "read_buffer");
  assert.equal(message.params.path, "/project/example.ts");
  socket.write(`${JSON.stringify({
    version: 1, type: "response", id: message.id, ok: true,
    result: {
      file: "/project/example.ts", bufnr: 1, changedtick: 8, modified: true,
      filetype: "typescript", totalLines: 1, offset: 1, lines: ["unsaved buffer text"],
    },
  })}\n`);
  assert.match((await reading).content[0].text, /unsaved buffer text/);
});

test("explicit submit sends the whole draft once and clears it", async (t) => {
  const { state, request } = await connectBridge(t);
  await request({ type: "draft", label: "Neovim context", context });
  state.draft = `Explain this code\n\n${state.draft}`;
  const draft = state.draft;
  const result = await request({ type: "submit" });
  assert.equal(result.result.submitted, true);
  assert.deepEqual(state.sent, [{ text: draft, options: { deliverAs: "followUp" } }]);
  assert.equal(state.draft, "");
  assert.equal((await request({ type: "submit" })).result.submitted, false);
  assert.equal(state.sent.length, 1);
});

test("whitespace-only drafts do not start work", async (t) => {
  const { state, request } = await connectBridge(t);
  state.draft = "  \n ";
  assert.equal((await request({ type: "submit" })).result.submitted, false);
  assert.deepEqual(state.sent, []);
});

test("a rejected submission keeps the draft", async (t) => {
  const { state, request } = await connectBridge(t);
  state.draft = "Keep this draft";
  state.failSend = true;
  const result = await request({ type: "submit" });
  assert.equal(result.ok, false);
  assert.equal(result.error, "Submission rejected");
  assert.equal(state.draft, "Keep this draft");
});

test("legacy direct-prompt requests cannot accidentally start work", async (t) => {
  const { state, request } = await connectBridge(t);
  assert.equal(await request({ type: "prompt", prompt: "Do not send", context }), undefined);
  assert.deepEqual(state.sent, []);
});

test("quickfix keeps ordered explanations and supports replacement, append, and clear", async (t) => {
  const { tools, socket, lines, ctx, request, state } = await connectBridge(t);
  await request({ type: "draft", label: "Context", context });
  const tool = tools.get("nvim_publish_quickfix");
  assert.equal(tool.parameters.properties.items.minItems ?? 0, 0);
  const items = [
    { path: "@z.ts", line: 20, severity: "note", message: "First: entry point" },
    { path: "/project/a.ts", line: 3, column: 4, severity: "error", message: "Second: dependency" },
    { path: "z.ts", line: 5, message: "Third: return to the helper" },
  ];
  for (const [mode, input] of [[undefined, items], ["append", items.slice(0, 1)], ["replace", []]]) {
    const execution = tool.execute("test", { title: "Reading set", mode, items: input }, undefined, undefined, ctx);
    const message = JSON.parse((await lines.next()).value);
    assert.equal(message.method, "publish_quickfix");
    assert.equal(message.params.mode, mode ?? "replace");
    assert.deepEqual(message.params.items.map((item) => [item.filename, item.lnum, item.col, item.text]),
      input.map((item) => [resolve(ctx.cwd, item.path.replace(/^@/, "")), item.line, item.column ?? 1, item.message]));
    const result = { id: 7, count: input.length, title: "Reading set" };
    socket.write(`${JSON.stringify({ version: 1, type: "response", id: message.id, ok: true, result })}\n`);
    assert.deepEqual((await execution).details, result);
    assert.deepEqual(state.sent, []);
  }
});

test("Harpoon publishes normalized paths and supports clear without starting work", async (t) => {
  const { tools, socket, lines, ctx, request, state } = await connectBridge(t);
  await request({ type: "draft", label: "Context", context });
  const tool = tools.get("nvim_publish_harpoon");
  assert.ok(tool);
  assert.equal(tool.parameters.properties.paths.maxItems, 20);
  for (const [paths, expected] of [
    [["@src/service.ts", "/elsewhere/design.md"], ["/project/src/service.ts", "/elsewhere/design.md"]],
    [[], []],
  ]) {
    const execution = tool.execute("test", { paths }, undefined, undefined, ctx);
    const message = JSON.parse((await lines.next()).value);
    assert.equal(message.method, "publish_harpoon");
    assert.deepEqual(message.params, { cwd: "/project", paths: expected });
    const result = { added: paths.length, removed: 1, shared: 0 };
    socket.write(`${JSON.stringify({ version: 1, type: "response", id: message.id, ok: true, result })}\n`);
    assert.deepEqual((await execution).details, result);
    assert.deepEqual(state.sent, []);
  }
});

test("Harpoon reports missing editor and editor-side failures", async (t) => {
  const { tools, socket, lines, ctx, request } = await connectBridge(t);
  const tool = tools.get("nvim_publish_harpoon");
  await assert.rejects(tool.execute("test", { paths: [] }, undefined, undefined, ctx), /No Neovim/);
  await request({ type: "draft", label: "Context", context });
  const execution = tool.execute("test", { paths: [] }, undefined, undefined, ctx);
  const rejection = assert.rejects(execution, /different working directory/);
  const message = JSON.parse((await lines.next()).value);
  socket.write(`${JSON.stringify({ version: 1, type: "response", id: message.id, ok: false, error: "different working directory" })}\n`);
  await rejection;
});
