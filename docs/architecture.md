# Architecture and protocol

## Responsibilities

- `plugin/pi.lua` installs user commands, with no connection side effects.
- `lua/pi/commands.lua` owns picker state and command feedback. Cancelling increments
  a generation counter so a delayed selection cannot connect afterwards.
- `lua/pi/discovery.lua` validates advertisements and probes reachability. It never
  registers an editor, acquires ownership, or deletes another process's files.
- `lua/pi/init.lua` owns one socket, pairing, JSON framing, deadlines, and pending
  requests. Editor work is scheduled onto Neovim's main loop.
- `lua/pi/context.lua` captures the source identity and positions before composition.
- `lua/pi/prompt.lua` owns one retained scratch question and its captured context.
- `lua/pi/editor.lua` handles live reads and Pi-owned quickfix updates.
- `lua/pi/harpoon.lua` handles the optional, separately tagged Harpoon working set.
- `extensions/nvim-bridge.ts` owns Pi's listener, advertisement, authoritative pairing,
  draft/submission handling, and model-facing editor tools.

Transport, discovery, and editor behavior have separate ownership. A picker adapter
can change presentation without changing pairing. Adding an editor method does not
require another transport or background process.

## Lifecycle and ownership

The Neovim connection moves through **disconnected → connecting → paired**. The
connecting state reserves the local slot while opening the socket and awaiting Pi's
acceptance. Rejection, timeout, cancellation, or socket failure releases it. Pairing
has no automatic retry or reconnection transition.

Pi tracks accepted but unregistered sockets separately from its single registered
owner. The first valid registration claims ownership synchronously. Another
registration cannot replace it. Unregistered clients may not submit requests or
change editor routing. Closing the owner's socket clears ownership and rejects
outstanding editor requests; an unrelated socket closing cannot clear the owner.

The owner is a live socket, not a PID, registry file, project directory, or conversation
identifier. Reloading the extension closes its old sockets and publishes a new instance.
A Neovim restart does not silently reclaim the previous connection.

## Advertisements

`/tmp/pi-nvim-<uid>/<instance-id>.json`:

```json
{
  "version": 1,
  "protocolVersion": 2,
  "instanceId": "<random UUID>",
  "pid": 12345,
  "cwd": "/project",
  "socketPath": "/tmp/pi-nvim-1000/<instance-id>.sock"
}
```

The advertisement schema and wire protocol have separate versions. Pi first validates
or creates the private registry, starts the socket, and sets its permissions. It writes
a temporary file exclusively and renames it to `.json` only when complete. Failed
startup and normal shutdown clean up only that instance's resources. The shared
directory stays in place.

Discovery checks file ownership, type, permissions, schema, and socket location.
Advertisements are limited to 16KB and cannot redirect discovery outside the registry.
Socket probes run at most eight at a time with a 300ms deadline. They send no messages;
a successful probe indicates reachability, not protocol authenticity or availability.
The selected connection still performs the full pairing handshake.

The registry is local and private, not an authentication boundary against the same
Unix user. Registry checks do not defend against a malicious process with that user's
permissions replacing files between checks. Stale advertisements are tolerated, not
used as ownership locks. A stale PID is never treated as evidence that the advertised
instance is alive.

## Wire protocol v2

Transport is UTF-8, newline-delimited JSON over a Unix socket. Chunks may split one
message or contain several. Receive buffers and outgoing Neovim messages are limited
to 1MB. All messages carry `version: 2`; incompatible versions fail explicitly.

### Pairing

```json
{"version":2,"type":"register","projectRoot":"/project"}
{"version":2,"type":"registered","ok":true}
```

Rejection uses `type: "registered", ok: false, error: "..."`, then closes the socket.
Neovim's five-second establishment deadline covers both connecting and acceptance.
Pi also closes sockets that never register within five seconds.

### Neovim → Pi

Draft append:

```json
{
  "version": 2,
  "type": "draft",
  "id": "nvim-1",
  "label": "Neovim question",
  "content": "Explain this function",
  "context": {
    "projectRoot": "/project",
    "file": "/project/main.lua",
    "cursor": {"line": 12, "column": 3},
    "changedtick": 42
  }
}
```

Optional `selection` contains `start` and `end` positions. Positions use one-based
lines and byte columns. `PiPrompt` ranges capture whole lines. Context is metadata,
not a saved or copied source file; later buffer reads return current live contents.

Successful append replies with `result: { "appended": true }`. It updates Pi's visible
draft and its pending source context, but does not start a model request.

Submission sends `{ "version": 2, "type": "submit", "id": "nvim-2" }` and receives
`result: { "submitted": true }` or `false` for an empty draft. The latest appended
context becomes the default read source only on submission. It is the latest
**submitted** source, including queued follow-ups, not a per-model-turn association.
If exact turn-specific provenance is needed, the model should supply the explicit
file path included in that question's context.

### Pi → Neovim

```json
{"version":2,"type":"request","id":"<uuid>","method":"read_buffer","params":{"path":"/project/main.lua"}}
```

Supported methods are `read_buffer`, `publish_quickfix`, and `publish_harpoon`.
The TypeScript tools define their input schemas and translate user-facing fields into
editor-specific parameters. Unknown methods return explicit errors.

### Responses and uncertain delivery

Both request directions use:

```json
{"version":2,"type":"response","id":"<matching id>","ok":true,"result":{}}
{"version":2,"type":"response","id":"<matching id>","ok":false,"error":"reason"}
```

Request deadlines are five seconds. Responses resolve only the matching request;
late responses after timeout are ignored. Closing a socket resolves pending client
callbacks as failures and rejects pending Pi-side requests.

A timeout is not proof that a mutation did not happen. There is no replay cache or
exactly-once delivery across reconnects. Drafting and submission therefore never
retry automatically. `PiDraft` clears unchanged local text after a valid append
acknowledgement, without closing the composer. Ctrl-S chains append and submission
on the same pairing and waits for both acknowledgements before clearing unchanged
text and closing the original composer split. A connection change between steps
prevents submission on a different Pi instance. If submission fails after append,
local text stays and the error warns that the question is already in Pi's draft.
Newer local edits survive; their composer remains open. Repeated sends and separate
`PiSubmit` commands are blocked while a composer operation is pending.

## Deliberate limits

- No heartbeat, process supervisor, automatic cleanup of stale registry files, or reconnect loop.
- No editor focus changes from model-facing tools; opening the composer is an explicit user action.
- Quickfix history uses Neovim's native finite stack; Pi keeps one managed list while it exists.
- Harpoon support depends on Harpoon 2's non-shifting removal and persistent context tags.
- Draft review requires Pi's interactive terminal editor; RPC cannot read editor text back.
- The previous test suite remains deleted. Runtime evidence and outstanding checks are
  documented in the smoke checklist, not represented as automated regression coverage.
