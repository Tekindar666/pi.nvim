# Smoke checks and demonstration

These are manual checks, not an automated test suite. Use disposable Pi sessions,
Neovim instances, and project files. A real Ctrl-S or `PiSubmit` may invoke a model and incur
provider usage; lifecycle and append-only checks do not require model calls.

## Two-minute demonstration

1. Start interactive Pi with this checkout's extension. Start Neovim with the plugin.
2. Open a named file and make an unsaved edit.
3. Run `:PiConnect`. Choose the Pi project by directory, PID, and short instance ID.
4. Select a few lines and run `:'<,'>PiPrompt`. Write a question about those lines.
5. For the review path, run `:PiDraft`. Show the question and file/range metadata in
   Pi's draft before anything is submitted, then use `:PiSubmit` after reviewing.
   Alternatively, press Ctrl-S in the question buffer to append and submit together;
   its split should close only after submission is acknowledged.
6. Ask Pi to read the source using `nvim_read_buffer`. The output should contain the
   unsaved edit, without saving or moving Neovim.
7. Ask Pi explicitly to publish a short quickfix reading set. Open it yourself with
   `:copen`; show that the locations have explanations.
8. Run `:PiDisconnect`. Another editor can now pair with the same Pi.

## Failure and ownership checks

| Check | Expected result |
|---|---|
| Two Pi processes, one Neovim | Picker distinguishes instances; selection pairs only the chosen one |
| Two editors choose one Pi | Second is rejected; first keeps ownership and receives tool requests |
| Repeat `PiConnect` while choosing | No second picker |
| Cancel selection or disconnect while picker is open | No connection from a later stale selection callback |
| Kill a Pi process | Neovim releases its connection; no automatic reconnect; stale advertisement is ignored |
| Reload the extension with `/reload` | Old advertisement/socket removed; fresh instance can be chosen manually |
| Connect to an incompatible endpoint | Failure, not a false successful pairing |
| Disconnect while connecting | Callback completes once; another attempt can start |
| Stop the peer during a draft append | Local text stays; warning says delivery may have occurred |
| Edit the question before its append/submission reply arrives | Sent snapshot is acknowledged; newer local text and composer stay |
| Ctrl-S succeeds | Append then submit; composer closes only after submission acknowledgement |
| Append succeeds but submission fails | Composer and text stay; warning explains the partial delivery |
| Switch windows while Ctrl-S is pending | Only the original composer closes; current focus stays put |
| Repeat Ctrl-S or PiSubmit while sending | No duplicate request |
| Change pairing between append and submission | No submission on the new pairing |
| Move to another buffer after submission | Default read still targets the submitted question's source |
| Prepare another draft without submitting | Default read source does not change yet |
| Read a missing/unloaded buffer | Clear error; no disk fallback or buffer opening |
| Publish quickfix while a personal list exists | Pi owns a separate list; no cursor or window jump |
| Publish Harpoon without Harpoon installed | Only that tool fails with a dependency message |
| Share a path with a personal Harpoon mark | Personal slot, position, and other context remain unchanged |
| Clear Pi Harpoon marks | Personal marks remain; no file opened |

Malformed, incompatible, wrongly permissioned, or outside-registry advertisements
must not appear as candidates. An unsafe registry directory must produce an error,
not a permissions repair or deletion. Never alter a real user's registry permissions
for testing; use an isolated user/environment or fixtures you created yourself.

## Evidence for the current implementation

Executed inline without adding test files:

- Real Unix sockets and headless Neovim: discovery, non-claiming probes, picker
  cancellation, duplicate-picker suppression, explicit pairing, competing-editor
  rejection, ownership release, fragmented replies, deadlines, and callback-once behavior.
- Registry fixtures: stale/malformed/incompatible/outside-path entries ignored;
  private directory/file permissions, symlink refusal, atomic publication cleanup,
  startup failure cleanup, repeated startup, and independent instance shutdown.
- Real Neovim with a simulated Pi lifecycle: unsaved paginated reads, missing default
  source errors, draft append separate from submission, captured selection metadata,
  source retention while preparing the next question, and quickfix replace/append/clear.
- Real Harpoon 2 with isolated data storage: personal slot/context preservation,
  shared paths, Pi-only clearing, and unchanged editor focus.
- Delayed/silent/disconnecting socket peers: local edits survive acknowledgement,
  timeouts retain questions, and submission failures do not retry automatically.
- Ctrl-S with real sockets and headless Neovim: append then submit, delayed final
  acknowledgement, duplicate-send suppression, unchanged text cleared and split
  closed, focus preservation, in-flight edits retained, append/submission rejection,
  disconnect, timeout, append-only PiDraft regression, and sole-window source fallback.
  An inline pairing-change check verified that a different connection cannot receive
  the second step. No model was called for these checks.
- Actual Pi 1.3.0: RPC startup/pairing and orderly shutdown; explicit rejection of
  drafting outside the TUI; TUI draft append; `/reload` with fresh advertisement;
  abrupt process exit leaving a stale, unreachable advertisement. No model was called.

Static checks:

- `luac -p lua/pi/*.lua plugin/pi.lua` — passed.
- `PATH=/home/ed/.local/share/nvim/mason/bin:$PATH npm run lint` — passed using the
  locally installed StyLua, which is not otherwise on this machine's PATH.
- `git diff --check` and package JSON parsing — passed.
- Isolated TypeScript check against installed Pi 1.3.0 declarations — passed.
- `npm ci --ignore-scripts` — completed without changing the lockfile.
- `npm run typecheck` against the repository's pinned dependencies — passed.
- `npm audit` — reports two affected packages through Pi's transitive `undici`
  dependency (one moderate, one high). Dependency remediation is not included in
  these changes; no forced fixes or upgrades were applied.

Still unverified: runtime compatibility with the pinned Pi 0.84.2 development dependency,
macOS, a full model-driven conversation using these tools, and interactive visual
polish across third-party `vim.ui.select` adapters. These checks do not constitute
exhaustive regression coverage. All implementation changes are currently uncommitted.
