import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  formatSize,
  truncateHead,
} from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { createServer, type Server, type Socket } from "node:net";
import { isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

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
  version: 2;
  type: "register";
  projectRoot?: string;
  nvimServer?: string;
  tmuxPane?: string;
};

type SubmitMessage = {
  version: 2;
  type: "submit";
  id: string;
};

type DraftMessage = {
  version: 2;
  type: "draft";
  id: string;
  label: string;
  content?: string;
  context: EditorContext;
};

type ResponseMessage = {
  version: 2;
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
  draftContext?: EditorContext;
  pending: Map<string, PendingRequest>;
  closing: boolean;
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
  if (!value || typeof value !== "object" || value.version !== 2) {
    throw new Error("Incompatible bridge protocol; update both Pi and Neovim to version 2");
  }
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
  if (typeof context.file !== "string" || !isAbsolute(context.file)) {
    throw new Error("Draft context requires an absolute source file path");
  }
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

/** Refuse unsafe shared locations rather than changing permissions on someone else's directory. */
async function registryDirectory(): Promise<string> {
  if (!process.getuid) throw new Error("The Neovim bridge requires a Unix user ID");
  const uid = process.getuid();
  const directory = `/tmp/pi-nvim-${uid}`;
  try {
    await mkdir(directory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.uid !== uid || (stat.mode & 0o7777) !== 0o700) {
    throw new Error(`Unsafe Neovim bridge registry: ${directory}; expected an owned directory with mode 0700`);
  }
  return directory;
}

/** A complete advertisement becomes visible only after the socket is ready. */
async function advertise(directory: string, instanceId: string, socketPath: string, cwd: string): Promise<string> {
  const path = join(directory, `${instanceId}.json`);
  const temporaryPath = `${path}.tmp`;
  const file = await open(temporaryPath, "wx", 0o600);
  try {
    try {
      await file.writeFile(`${JSON.stringify({
        version: 1,
        protocolVersion: 2,
        instanceId,
        pid: process.pid,
        cwd,
        socketPath,
      })}\n`);
    } finally {
      await file.close();
    }
    await rename(temporaryPath, path);
    return path;
  } finally {
    await removeFile(temporaryPath);
  }
}

async function removeFile(path: string): Promise<void> {
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
  let advertisementPath: string | undefined;
  // Only a successful registration owns routing; advertisements never confer ownership.
  let pairedPeer: Peer | undefined;
  let activeContext: ExtensionContext | undefined;
  const peers = new Set<Peer>();

  const requestPeer = (
    peer: Peer,
    method: string,
    params: object,
    signal?: AbortSignal,
  ): Promise<unknown> => {
    if (peer.closing || peer.socket.destroyed) throw new Error("The Neovim connection is closed");
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
      send(peer.socket, { version: 2, type: "request", id, method, params });
    });
  };

  const requireDraftEditor = () => {
    if (!activeContext?.hasUI || ("mode" in activeContext && activeContext.mode !== "tui")) {
      throw new Error("Drafting and submission require Pi's interactive terminal editor");
    }
    return activeContext;
  };

  const setDraftText = (text: string) => {
    const context = requireDraftEditor();
    context.ui.setEditorText(text);
    // setEditorText currently mutates state without requesting a TUI render.
    context.ui.setStatus("nvim-bridge", "nvim bridge");
  };

  const handleMessage = (peer: Peer, message: IncomingMessage) => {
    if (message.type === "register") {
      if (pairedPeer) throw new Error("Pi is already paired; disconnect the current editor first");
      peer.projectRoot = message.projectRoot;
      peer.nvimServer = message.nvimServer;
      peer.tmuxPane = message.tmuxPane;
      pairedPeer = peer;
      send(peer.socket, { version: 2, type: "registered", ok: true });
      return;
    }

    if (pairedPeer !== peer) throw new Error("Register before sending bridge messages");

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

    try {
      if (message.type === "draft") {
        const block = formatDraft(message.label, message.content, message.context);
        const current = requireDraftEditor().ui.getEditorText();
        const draft = current.trim() === "" ? block : `${current}\n\n${block}`;
        setDraftText(draft);
        peer.draftContext = message.context;
        send(peer.socket, { version: 2, type: "response", id: message.id, ok: true, result: { appended: true } });
        return;
      }

      const draft = requireDraftEditor().ui.getEditorText();
      const submitted = draft.trim() !== "";
      if (submitted) {
        pi.sendUserMessage(draft, { deliverAs: "followUp" });
        // Preparing the next question must not change the source of the last submitted one.
        peer.lastContext = peer.draftContext;
        peer.draftContext = undefined;
        setDraftText("");
      }
      send(peer.socket, { version: 2, type: "response", id: message.id, ok: true, result: { submitted } });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      send(peer.socket, {
        version: 2,
        type: "response",
        id: message.id,
        ok: false,
        error: detail,
      });
    }
  };

  const handleConnection = (socket: Socket) => {
    socket.setEncoding("utf8");
    const peer: Peer = { socket, buffer: "", pending: new Map(), closing: false };
    peers.add(peer);
    const registrationTimer = setTimeout(() => {
      if (pairedPeer !== peer) socket.destroy();
    }, REQUEST_TIMEOUT_MS);

    socket.on("data", (chunk: string) => {
      if (peer.closing) return;
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
          if (pairedPeer === peer) clearTimeout(registrationTimer);
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          peer.closing = true;
          // Flush the rejection before closing; ignore any further pipelined messages.
          socket.end(
            `${JSON.stringify({ version: 2, type: "registered", ok: false, error: detail })}\n`,
            () => socket.destroy(),
          );
          return;
        }
      }
    });

    socket.on("close", () => {
      clearTimeout(registrationTimer);
      peers.delete(peer);
      if (pairedPeer === peer) pairedPeer = undefined;
      rejectPending(peer, "Neovim disconnected");
    });
    socket.on("error", () => {});
  };

  pi.registerTool({
    name: "nvim_read_buffer",
    label: "Read Neovim Buffer",
    description:
      "Read live contents from a named Neovim buffer. Without a path, use the source of the latest question submitted through PiSubmit, not the current cursor buffer. Use this instead of read when the buffer may contain unsaved changes. Output is limited to 2000 lines or 50KB; use offset and limit to paginate.",
    promptSnippet: "Read live, potentially unsaved contents from the connected Neovim buffer",
    promptGuidelines: [
      "Use nvim_read_buffer instead of read when Neovim context includes a changedtick and unsaved editor content may matter.",
    ],
    parameters: Type.Object({
      path: Type.Optional(Type.String({ description: "File path; defaults to the source of the latest PiSubmit question" })),
      offset: Type.Optional(Type.Integer({ minimum: 1, description: "First line to read (1-based)" })),
      limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum number of lines" })),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const peer = pairedPeer;
      if (!peer) throw new Error("No Neovim instance is paired with this Pi session");

      let path = params.path?.replace(/^@/, "") || peer.lastContext?.file;
      if (!path) throw new Error("Specify a file path or submit a Neovim question with PiSubmit first");
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
      let text = result.file;
      if (result.lines.length > 0) text += `:${result.offset}-${lastLine}`;
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
      const peer = pairedPeer;
      if (!peer) throw new Error("No Neovim instance is paired with this Pi session");

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
      const peer = pairedPeer;
      if (!peer) throw new Error("No Neovim instance is paired with this Pi session");

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

  const stopBridge = async () => {
    const errors: unknown[] = [];
    // Withdraw discovery first, but a failed unlink must not prevent socket cleanup.
    if (advertisementPath) {
      try {
        await removeFile(advertisementPath);
        advertisementPath = undefined;
      } catch (error) {
        errors.push(error);
      }
    }
    for (const peer of peers) {
      rejectPending(peer, "Pi session shut down");
      peer.socket.destroy();
    }
    peers.clear();
    pairedPeer = undefined;
    activeContext = undefined;

    if (server?.listening) await closeServer(server);
    server = undefined;
    if (socketPath) {
      try {
        await removeFile(socketPath);
        socketPath = undefined;
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length) throw new AggregateError(errors, "Failed to clean up Neovim bridge files");
  };

  pi.on("session_start", async (_event, ctx) => {
    // Repeated lifecycle events must not leave an older listener or advertisement behind.
    ctx.ui.setStatus("nvim-bridge", undefined);
    await stopBridge();
    activeContext = ctx;
    try {
      const directory = await registryDirectory();
      const instanceId = randomUUID();
      const path = join(directory, `${instanceId}.sock`);
      server = createServer(handleConnection);
      await listen(server, path);
      socketPath = path;
      await chmod(path, 0o600);
      advertisementPath = await advertise(directory, instanceId, path, ctx.cwd);
      ctx.ui.setStatus("nvim-bridge", "nvim bridge");
    } catch (error) {
      try {
        await stopBridge();
      } catch (cleanupError) {
        throw new AggregateError([error, cleanupError], "Neovim bridge startup and cleanup failed");
      }
      throw error;
    }
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    ctx.ui.setStatus("nvim-bridge", undefined);
    await stopBridge();
  });
}
