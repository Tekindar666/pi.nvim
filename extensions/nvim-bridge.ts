import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  formatSize,
  truncateHead,
} from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { chmod, unlink } from "node:fs/promises";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

const TMUX_OPTION = "@pi_nvim_bridge";
const MAX_REQUEST_BYTES = 1024 * 1024;
const REQUEST_TIMEOUT_MS = 5000;

type Position = {
  line: number;
  column: number;
};

type EditorContext = {
  projectRoot?: string;
  file?: string;
  cursor?: Position;
  selection?: {
    start: Position;
    end: Position;
  };
  changedtick?: number;
  nvimServer?: string;
  tmuxPane?: string;
};

type RegisterMessage = {
  version: 1;
  type: "register";
  projectRoot?: string;
  nvimServer?: string;
  tmuxPane?: string;
};

type SubmitMessage = {
  version: 1;
  type: "submit";
  id: string;
};

type DraftMessage = {
  version: 1;
  type: "draft";
  id: string;
  label: string;
  content?: string;
  context: EditorContext;
};

type ResponseMessage = {
  version: 1;
  type: "response";
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
};

type IncomingMessage = RegisterMessage | SubmitMessage | DraftMessage | ResponseMessage;

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  removeAbortListener?: () => void;
};

type Peer = {
  socket: Socket;
  buffer: string;
  projectRoot?: string;
  nvimServer?: string;
  tmuxPane?: string;
  lastContext?: EditorContext;
  pending: Map<string, PendingRequest>;
};

type ReadBufferResult = {
  file: string;
  bufnr: number;
  changedtick: number;
  modified: boolean;
  filetype: string;
  totalLines: number;
  offset: number;
  lines: string[];
};

type QuickfixResult = {
  id: number;
  count: number;
  title: string;
};

function isPosition(value: unknown): value is Position {
  if (!value || typeof value !== "object") return false;
  const position = value as Position;
  return Number.isInteger(position.line) && Number.isInteger(position.column);
}

function parseMessage(line: string): IncomingMessage {
  const value = JSON.parse(line) as Record<string, unknown>;
  if (value.version !== 1) throw new Error("Unsupported bridge protocol version");
  if (value.type === "register") return value as RegisterMessage;
  if (value.type === "response") {
    if (typeof value.id !== "string" || typeof value.ok !== "boolean") {
      throw new Error("Invalid response message");
    }
    return value as ResponseMessage;
  }
  if (typeof value.id !== "string") throw new Error("Bridge message requires an id");
  if (value.type === "submit") return value as SubmitMessage;
  if (value.type !== "draft") throw new Error("Unsupported bridge message type");
  if (typeof value.label !== "string" || value.label.trim() === "") {
    throw new Error("Draft message requires a label");
  }
  if (value.content !== undefined && typeof value.content !== "string") {
    throw new Error("Draft content must be a string");
  }

  const context = value.context as EditorContext | undefined;
  if (!context || typeof context !== "object") throw new Error("Draft context is required");
  if (context.cursor !== undefined && !isPosition(context.cursor)) {
    throw new Error("Invalid cursor position");
  }
  if (
    context.selection !== undefined &&
    (!isPosition(context.selection.start) || !isPosition(context.selection.end))
  ) {
    throw new Error("Invalid selection range");
  }
  return value as DraftMessage;
}

function formatDraft(label: string, content: string | undefined, context: EditorContext): string {
  const lines: string[] = [];
  if (context.file) lines.push(`File: ${context.file}`);
  if (context.selection) {
    const { start, end } = context.selection;
    lines.push(`Selection: ${start.line}:${start.column}-${end.line}:${end.column}`);
  } else if (context.cursor) {
    lines.push(`Cursor: ${context.cursor.line}:${context.cursor.column}`);
  }
  if (context.changedtick !== undefined) lines.push(`Neovim changedtick: ${context.changedtick}`);

  let draft = `${label.trim()}:`;
  if (lines.length > 0) draft += `\n${lines.map((line) => `- ${line}`).join("\n")}`;
  if (content?.trim()) draft += `\n${content.trim()}`;
  return draft;
}

async function removeSocket(path: string): Promise<void> {
  try {
    await unlink(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function listen(server: Server, path: string): Promise<void> {
  return new Promise((resolveListen, reject) => {
    const onError = (error: Error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolveListen();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(path);
  });
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolveClose) => server.close(() => resolveClose()));
}

function send(socket: Socket, message: object): void {
  socket.write(`${JSON.stringify(message)}\n`);
}

function rejectPending(peer: Peer, reason: string): void {
  for (const pending of peer.pending.values()) {
    clearTimeout(pending.timer);
    pending.removeAbortListener?.();
    pending.reject(new Error(reason));
  }
  peer.pending.clear();
}

export default function (pi: ExtensionAPI) {
  let server: Server | undefined;
  let socketPath: string | undefined;
  let tmuxPane: string | undefined;
  let lastPeer: Peer | undefined;
  let activePromptPeer: Peer | undefined;
  let activeContext: ExtensionContext | undefined;
  const peers = new Set<Peer>();

  const requestPeer = (
    peer: Peer,
    method: string,
    params: object,
    signal?: AbortSignal,
  ): Promise<unknown> => {
    if (peer.socket.destroyed) throw new Error("The Neovim connection is closed");
    if (signal?.aborted) throw new Error(`Neovim ${method} request aborted`);

    const id = randomUUID();
    return new Promise((resolveRequest, reject) => {
      const timer = setTimeout(() => {
        const pending = peer.pending.get(id);
        peer.pending.delete(id);
        pending?.removeAbortListener?.();
        reject(new Error(`Neovim ${method} request timed out`));
      }, REQUEST_TIMEOUT_MS);

      let removeAbortListener: (() => void) | undefined;
      if (signal) {
        const onAbort = () => {
          clearTimeout(timer);
          peer.pending.delete(id);
          reject(new Error(`Neovim ${method} request aborted`));
        };
        signal.addEventListener("abort", onAbort, { once: true });
        removeAbortListener = () => signal.removeEventListener("abort", onAbort);
      }

      peer.pending.set(id, { resolve: resolveRequest, reject, timer, removeAbortListener });
      send(peer.socket, { version: 1, type: "request", id, method, params });
    });
  };

  const setDraftText = (text: string) => {
    if (!activeContext?.hasUI) throw new Error("Pi editor is unavailable");
    activeContext.ui.setEditorText(text);
    // setEditorText currently mutates state without requesting a TUI render.
    activeContext.ui.setStatus("nvim-bridge", "nvim bridge");
  };

  const handleMessage = (peer: Peer, message: IncomingMessage) => {
    if (message.type === "register") {
      peer.projectRoot = message.projectRoot;
      peer.nvimServer = message.nvimServer;
      peer.tmuxPane = message.tmuxPane;
      lastPeer = peer;
      return;
    }

    if (message.type === "response") {
      const pending = peer.pending.get(message.id);
      if (!pending) return;
      peer.pending.delete(message.id);
      clearTimeout(pending.timer);
      pending.removeAbortListener?.();
      if (message.ok) pending.resolve(message.result);
      else pending.reject(new Error(message.error || "Neovim request failed"));
      return;
    }

    lastPeer = peer;
    try {
      if (message.type === "draft") {
        peer.lastContext = message.context;
        const block = formatDraft(message.label, message.content, message.context);
        const current = activeContext?.ui.getEditorText() ?? "";
        const draft = current.trim() === "" ? block : `${current}\n\n${block}`;
        setDraftText(draft);
        send(peer.socket, { version: 1, type: "response", id: message.id, ok: true, result: { draft } });
        return;
      }

      if (!activeContext?.hasUI) throw new Error("Pi editor is unavailable");
      const draft = activeContext.ui.getEditorText();
      const submitted = draft.trim() !== "";
      if (submitted) {
        activePromptPeer = peer;
        pi.sendUserMessage(draft, { deliverAs: "followUp" });
        setDraftText("");
      }
      send(peer.socket, { version: 1, type: "response", id: message.id, ok: true, result: { submitted } });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      send(peer.socket, {
        version: 1,
        type: "response",
        id: message.id,
        ok: false,
        error: detail,
      });
    }
  };

  const handleConnection = (socket: Socket) => {
    socket.setEncoding("utf8");
    const peer: Peer = { socket, buffer: "", pending: new Map() };
    peers.add(peer);

    socket.on("data", (chunk: string) => {
      peer.buffer += chunk;
      if (Buffer.byteLength(peer.buffer) > MAX_REQUEST_BYTES) {
        socket.destroy(new Error("Bridge message exceeds 1MB"));
        return;
      }

      while (true) {
        const newline = peer.buffer.indexOf("\n");
        if (newline === -1) break;
        const line = peer.buffer.slice(0, newline).replace(/\r$/, "");
        peer.buffer = peer.buffer.slice(newline + 1);
        if (line === "") continue;

        try {
          handleMessage(peer, parseMessage(line));
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          socket.destroy(new Error(detail));
          return;
        }
      }
    });

    socket.on("close", () => {
      peers.delete(peer);
      if (lastPeer === peer) lastPeer = undefined;
      if (activePromptPeer === peer) activePromptPeer = undefined;
      rejectPending(peer, "Neovim disconnected");
    });
    socket.on("error", () => {});
  };

  pi.registerTool({
    name: "nvim_read_buffer",
    label: "Read Neovim Buffer",
    description:
      "Read live contents from the Neovim buffer that initiated the latest prompt. Use this instead of read when the buffer may contain unsaved changes. Output is limited to 2000 lines or 50KB; use offset and limit to paginate.",
    promptSnippet: "Read live, potentially unsaved contents from the connected Neovim buffer",
    promptGuidelines: [
      "Use nvim_read_buffer instead of read when Neovim context includes a changedtick and unsaved editor content may matter.",
    ],
    parameters: Type.Object({
      path: Type.Optional(Type.String({ description: "File path; defaults to the prompt's Neovim buffer" })),
      offset: Type.Optional(Type.Integer({ minimum: 1, description: "First line to read (1-based)" })),
      limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum number of lines" })),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const peer = lastPeer;
      if (!peer) throw new Error("No Neovim instance has sent a prompt to this Pi session");

      let path = params.path?.replace(/^@/, "") || peer.lastContext?.file;
      if (!path) throw new Error("No Neovim buffer path is available");
      if (!isAbsolute(path)) path = resolve(ctx.cwd, path);

      const result = (await requestPeer(
        peer,
        "read_buffer",
        { path, offset: params.offset, limit: params.limit },
        signal,
      )) as ReadBufferResult;

      const body = result.lines.join("\n");
      const truncation = truncateHead(body, {
        maxLines: DEFAULT_MAX_LINES,
        maxBytes: DEFAULT_MAX_BYTES,
      });
      const lastLine = result.offset + result.lines.length - 1;
      let text = `${result.file}:${result.offset}-${lastLine}`;
      text += ` (${result.totalLines} lines, changedtick ${result.changedtick}`;
      if (result.modified) text += ", modified";
      text += `)\n${truncation.content}`;

      if (truncation.truncated) {
        text += `\n\n[Output truncated to ${formatSize(truncation.outputBytes)}. `;
        text += `Use offset and limit to read a smaller range.]`;
      } else if (lastLine < result.totalLines) {
        text += `\n\n[More lines available. Continue with offset=${lastLine + 1}.]`;
      }

      return { content: [{ type: "text", text }], details: result };
    },
  });

  pi.registerTool({
    name: "nvim_publish_quickfix",
    label: "Publish Neovim Quickfix",
    description:
      "Publish an ordered set of exact code locations and explanations to a Pi-managed Neovim quickfix list. Replaces or appends without overwriting unrelated lists, opening a window, or moving the cursor. With replace, an empty items array clears the Pi list.",
    promptSnippet: "Publish small ordered reading sets or requested findings to Neovim quickfix",
    promptGuidelines: [
      "Use nvim_publish_quickfix for small ordered reading sets during an agreed code walkthrough, or for requested review findings and code locations. Explain each location in plain language. Replace the current set as the focus changes; publish no unsolicited lists outside that scope.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Descriptive quickfix list title" }),
      mode: Type.Optional(StringEnum(["replace", "append"] as const)),
      items: Type.Array(
        Type.Object({
          path: Type.String({ description: "Absolute path or path relative to Pi's working directory" }),
          line: Type.Integer({ minimum: 1 }),
          column: Type.Optional(Type.Integer({ minimum: 1 })),
          endLine: Type.Optional(Type.Integer({ minimum: 1 })),
          endColumn: Type.Optional(Type.Integer({ minimum: 1 })),
          severity: Type.Optional(StringEnum(["error", "warning", "info", "note"] as const)),
          message: Type.String(),
        }),
        { minItems: 0 },
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const peer = lastPeer;
      if (!peer) throw new Error("No Neovim instance has sent a prompt to this Pi session");

      const severityTypes = { error: "E", warning: "W", info: "I", note: "N" } as const;
      const items = params.items.map((item) => {
        const rawPath = item.path.replace(/^@/, "");
        return {
          filename: isAbsolute(rawPath) ? rawPath : resolve(ctx.cwd, rawPath),
          lnum: item.line,
          col: item.column ?? 1,
          end_lnum: item.endLine,
          end_col: item.endColumn,
          type: item.severity ? severityTypes[item.severity] : "",
          text: item.message,
          user_data: { source: "pi", severity: item.severity },
        };
      });

      const result = (await requestPeer(
        peer,
        "publish_quickfix",
        { title: params.title, mode: params.mode ?? "replace", items },
        signal,
      )) as QuickfixResult;

      return {
        content: [
          {
            type: "text",
            text: `Published ${result.count} location(s) to Neovim quickfix list "${result.title}".`,
          },
        ],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_publish_harpoon",
    label: "Publish Neovim Harpoon",
    description:
      "Replace Pi-managed marks in Neovim's default Harpoon list with an ordered file working set. An empty paths array clears only Pi marks. Preserves personal marks and their shortcut slots; shared files keep their existing personal mark. Does not open files, move the cursor, or change comments. Pi and Neovim must have the same working directory. Files must exist or have a Neovim buffer.",
    promptSnippet: "Publish or clear Harpoon files only when explicitly requested, preserving personal marks",
    promptGuidelines: [
      "Use nvim_publish_harpoon only when explicitly requested. Use nvim_publish_quickfix, not Harpoon, for agreed guided reading sets.",
    ],
    parameters: Type.Object({
      paths: Type.Array(
        Type.String({ minLength: 1, description: "Absolute file path or path relative to Pi's working directory" }),
        { maxItems: 20, description: "Files in reading order; [] clears the completed Pi working set" },
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const peer = lastPeer;
      if (!peer) throw new Error("No Neovim instance is connected to this Pi session");

      const paths = params.paths.map((path) => resolve(ctx.cwd, path.replace(/^@/, "")));
      const result = (await requestPeer(
        peer,
        "publish_harpoon",
        { cwd: ctx.cwd, paths },
        signal,
      )) as { added: number; removed: number; shared: number };

      return {
        content: [
          {
            type: "text",
            text: `Harpoon: added ${result.added} Pi mark(s), removed ${result.removed}; ${result.shared} requested file(s) already bookmarked personally.`,
          },
        ],
        details: result,
      };
    },
  });

  const sendAgentState = (state: "working" | "idle") => {
    const peer = activePromptPeer ?? lastPeer;
    if (!peer) return;
    void requestPeer(peer, "set_status", { state }).catch(() => {});
  };

  pi.on("agent_start", () => {
    sendAgentState("working");
  });

  pi.on("agent_settled", () => {
    sendAgentState("idle");
    activePromptPeer = undefined;
  });

  pi.on("session_start", async (_event, ctx) => {
    activeContext = ctx;
    tmuxPane = process.env.TMUX_PANE;
    if (!tmuxPane) {
      ctx.ui.notify("Neovim bridge requires Pi to run inside tmux", "warning");
      return;
    }

    socketPath = join(tmpdir(), `pi-nvim-${process.pid}-${randomUUID().slice(0, 8)}.sock`);
    await removeSocket(socketPath);

    server = createServer(handleConnection);
    await listen(server, socketPath);
    await chmod(socketPath, 0o600);

    const result = await pi.exec("tmux", [
      "set-option",
      "-w",
      "-t",
      tmuxPane,
      TMUX_OPTION,
      socketPath,
    ]);
    if (result.code !== 0) {
      await closeServer(server);
      await removeSocket(socketPath);
      server = undefined;
      throw new Error(`Failed to register Neovim bridge with tmux: ${result.stderr.trim()}`);
    }

    ctx.ui.setStatus("nvim-bridge", "nvim bridge");
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    ctx.ui.setStatus("nvim-bridge", undefined);

    if (tmuxPane && socketPath) {
      const current = await pi.exec("tmux", [
        "show-options",
        "-w",
        "-v",
        "-t",
        tmuxPane,
        TMUX_OPTION,
      ]);
      if (current.code === 0 && current.stdout.trim() === socketPath) {
        await pi.exec("tmux", ["set-option", "-w", "-u", "-t", tmuxPane, TMUX_OPTION]);
      }
    }

    for (const peer of peers) {
      rejectPending(peer, "Pi session shut down");
      peer.socket.destroy();
    }
    peers.clear();
    lastPeer = undefined;
    activePromptPeer = undefined;
    activeContext = undefined;

    if (server) await closeServer(server);
    if (socketPath) await removeSocket(socketPath);
    server = undefined;
    socketPath = undefined;
  });
}
