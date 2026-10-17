# pi.nvim

An explicit, local bridge between [Pi](https://pi.dev) and Neovim: choose a Pi
instance, compose a question with source context, and let Pi read unsaved buffers
or publish navigation locations without taking over your editor.

**Development branch:** the old automatic-discovery API has been replaced. There
is no `setup()`, automatic connection, or automatic reconnection. Update both the
Neovim client and Pi extension together; this branch uses bridge protocol v2.

## Requirements

- Neovim 0.11+ and Node.js 22.19+ on Linux or macOS.
- Pi and Neovim running on the same machine as the same user. No tmux required.
- Pi's interactive terminal UI for drafting and submission. Other modes can pair
  and use editor tools, but cannot supply the reviewable Pi draft editor.
- Optional: Harpoon 2 and plenary.nvim for Harpoon publishing only.

Linux with Neovim 0.12.6 and Pi 1.3.0 has been exercised. macOS is not verified.
Windows is not supported by this Unix-socket bridge.

## Install both sides

For local development, load this checkout with your Neovim plugin manager. For lazy.nvim:

```lua
{
  dir = "/absolute/path/to/pi.nvim",
  lazy = false,
}
```

No setup call is needed. Commands load with the plugin; loading it does not connect.
No global keymaps are installed.

Start Pi with the companion extension:

```sh
pi --extension /absolute/path/to/pi.nvim/extensions/nvim-bridge.ts
```

Load only one copy of the extension. If migrating from another bridge installation,
remove its configured extension and old Lua API calls first. Pi and Neovim may load
separate checkouts; editing one does not update the other.

## Use

| Command | Action |
|---|---|
| `:PiConnect` | Choose a reachable local Pi instance using `vim.ui.select()` |
| `:PiDisconnect` | Release the connection, cancel a pending connection, or invalidate a pending picker |
| `:PiPrompt` | Open or reopen a retained question buffer with source-file context |
| `:'<,'>PiPrompt` | Capture the selected **line range** as question context |
| `:PiDraft` | Append the question to Pi's draft for review; do not submit |
| `:PiSubmit` | Submit Pi's current draft explicitly |

1. Start Pi, open a named file in Neovim, and run `:PiConnect`.
2. Run `:PiPrompt`, optionally with a line range, and write a multiline question.
3. Press **Ctrl-S** in the question buffer to append and submit. The composer closes
   after Pi acknowledges submission, not after the model finishes answering.
4. For review-before-submit instead, use `:PiDraft`, review/edit in Pi, then `:PiSubmit`.
5. Pi can use `nvim_read_buffer` to inspect the live source, including unsaved edits.

The question buffer is an ordinary scratch split. Normal-mode **q** hides it without
losing text; `:PiPrompt` reopens it. A retained question keeps its original source,
not whatever buffer happens to be current later. A fresh question captures new context.
Unnamed and special buffers cannot be question sources.

`:PiDraft` clears unchanged local text after append acknowledgement and leaves the
composer open. Ctrl-S waits for both append and submission acknowledgement before
clearing text and closing its split. If you edited while waiting, the newer text and
composer remain. Closing the composer does not steal focus from another window;
if it is Neovim's last window, it shows the loaded source buffer instead.

Errors and uncertain delivery retain the question. There are no automatic retries:
**after a timeout or disconnect, inspect Pi before resending**, because it may have
received the request even though Neovim missed the reply. An append can succeed
while submission fails; do not append the same question again blindly. Drafts are
held in memory; closing Neovim does not persist the scratch question.

**Ctrl-S and `PiSubmit` send the whole Pi draft**, including any existing text. If Pi is busy, its existing follow-up queue is
used. An empty draft does nothing. The default buffer for `nvim_read_buffer` is the
source of the latest question submitted through Ctrl-S or `PiSubmit`; preparing another draft
or moving the cursor does not change it. If several questions were appended, the
last appended source is the default. An explicit file path always overrides it.
Submitting directly from Pi's terminal does not establish a new default source.

## Editor tools

- **`nvim_read_buffer`** reads only loaded buffers, never falls back to disk, and
  never saves or changes editor focus. Responses are limited to 2000 lines and
  50KB of text; use offset/limit to paginate. A single line over 50KB returns an
  explicit error rather than silently returning incomplete content.
- **`nvim_publish_quickfix`** replaces, appends to, or clears one Pi-owned list.
  It makes that list current without opening windows or jumping to an item. Other
  lists remain in Neovim's normal quickfix history, subject to its native capacity.
  Use `:copen` when you want to view the locations. Pi's list persists across reconnects.
- **`nvim_publish_harpoon`** replaces only Pi-tagged marks in Harpoon's default list.
  Personal marks keep their slots and context; shared paths remain personal. Pi
  and Neovim must have the same working directory, and the Harpoon menu must be
  closed. Files must exist or have a Neovim buffer. Missing Harpoon affects only
  this optional tool, not the connection or other editor features.

Quickfix is for agreed walkthroughs and requested findings. Harpoon publishing is
only for explicit requests; those guidelines are included in the tool descriptions.

## Pairing and discovery

One Neovim instance holds one live or pending connection. One Pi accepts one
registered editor. Another editor is rejected without replacing the owner. Disconnect
before switching instances. Process exit or socket closure releases ownership once
observed by the other endpoint; reconnection is always manual.

Pi publishes advertisements in `/tmp/pi-nvim-<uid>/`. The directory must be owned
by the current user, non-symlink, and mode `0700`; sockets and advertisements use
`0600`. Unsafe directories are rejected, never repaired automatically.

The picker validates advertisements and briefly probes sockets **without registering**.
It lists reachable candidates, not guaranteed available pairings: Pi can be busy
with another editor or exit while the picker is open. Selection requests pairing;
only Pi's explicit acceptance counts as success. Cancelling does nothing.

Publication uses an atomic rename after the socket is ready. Normal shutdown
withdraws the advertisement before closing connections. Crashes can leave stale
files; discovery ignores unreachable or invalid candidates and does not delete files.
No background service, polling, heartbeat, or tmux advertisement is used.

These permissions do not isolate the bridge from other processes running as your
user. Connect only to trusted Pi instances. Source metadata and submitted questions
become model context; buffer contents can be sent when Pi calls the read tool.
The plugin itself does not contact an AI provider.

## Manual connection API

For scripting or diagnostics, bypass discovery with an advertised `socketPath`:

```lua
require("pi").connect("/tmp/pi-nvim-1000/<instance-id>.sock", function(ok, err)
  print(ok and "Paired" or err)
end)
```

Later, disconnect with `require("pi").disconnect()`.

`connect(path, callback)` calls back once on Neovim's main loop. Success means Pi
accepted exclusive pairing, not merely that registration was written. Establishment
has a five-second deadline. Later disconnect silently releases the connection;
it does not invoke that callback again. The manual API itself emits no notifications.
`disconnect()` is safe to repeat and cancels an in-progress connection.

`connection_state()` returns `disconnected`, `connecting`, or `paired`.
`draft(content, capturedContext, callback)` and `submit(callback)` are asynchronous
request APIs used by the commands. `send_question(content, capturedContext, callback)`
chains both steps on the same pairing, failing if that connection changes in between.
They require an existing pairing and never retry.
See [architecture and protocol](docs/architecture.md) for the message contracts.

## Development and verification

```sh
npm ci --ignore-scripts
npm run typecheck
npm run lint                 # requires stylua on PATH
```

The previous automated test suite was intentionally removed; no replacement test
files are included. Validation currently uses inline runtime smoke checks and
manual integration. See [the smoke checklist](docs/smoke.md) for a repeatable demo
and failure checks.

The development dependency still pins Pi 0.84.2. Repository typecheck passes with
those dependencies installed; an additional isolated typecheck against locally
installed Pi 1.3.0 also passed. Runtime compatibility with the older development pin
remains unverified. Lua lint, syntax, and diff checks pass. `npm audit` reports two
affected packages through Pi's transitive `undici` dependency (one moderate, one high);
no dependency upgrades or forced audit fixes have been applied.
Dependency lifecycle scripts are disabled. There are no bundled Pi runtime
dependencies and no npm publication.

## Scope

No statusline component, completion notifications, automatic reconnection, automatic
submission, diagnostics/hover helpers, or mandatory picker dependencies. The old
feature API is not a compatibility target.

## Origin

Extracted from `Tekindar666/dotfiles` (Neovim client) and the author's Pi configuration
(companion extension), then refactored around explicit pairing and tmux-free discovery.
