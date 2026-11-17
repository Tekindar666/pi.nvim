# pi.nvim

Connect [Pi](https://pi.dev) to Neovim for contextual prompts, unsaved buffer reads,
and code navigation. No tmux, background service, or mandatory picker dependency.

## Requirements

- Neovim 0.11+ and Node.js 22.19+ on Linux or macOS.
- Pi and Neovim running on the same machine as the same user.
- Pi's interactive terminal UI for sending questions.
- Optional: Harpoon 2 and plenary.nvim for bookmark publishing.

Tested on Linux with Neovim 0.12.6 and Pi 1.3.0. macOS remains unverified.

## Setup

Load your checkout in Neovim. For lazy.nvim:

```lua
{
  dir = "/absolute/path/to/pi.nvim",
  lazy = false,
}
```

Start Pi with the companion extension:

```sh
pi --extension /absolute/path/to/pi.nvim/extensions/nvim-bridge.ts
```

If the extension is already configured to auto-load, just run `pi`—don't load it
again with `--extension`. No npm publication or `setup()` call is needed. Update
both sides together; older protocol-v1 clients are incompatible.

## Use

1. Open a named file and run `:PiConnect` to choose a Pi instance.
2. Run `:PiPrompt`, write your question, and press **Ctrl-S** to send it with source
   context. The composer closes after Pi acknowledges submission.
3. Ask Pi to read your unsaved buffer or publish explained code locations.

| Command | Action |
|---|---|
| `:PiConnect` | Choose a local Pi instance through `vim.ui.select()` |
| `:PiDisconnect` | Disconnect or cancel a pending connection/selection |
| `:PiPrompt` | Open or reopen the question composer |
| `:'<,'>PiPrompt` | Include the selected line range as context |
| `:PiDraft` | Append the question to Pi's draft for review, without submitting |
| `:PiSubmit` | Submit Pi's current draft |

Normal-mode **q** hides the composer and retains its text. Failed sends and edits
made while sending are preserved. **Ctrl-S and `:PiSubmit` send the whole Pi draft**,
including existing text. After a timeout, check Pi before resending to avoid duplicates.

## Editor tools

- **Live buffers:** read unsaved content without saving or changing focus.
- **Quickfix:** publish a Pi-owned reading list without opening windows or jumping
  to locations. Use `:copen` when ready.
- **Harpoon:** optionally publish bookmarks while preserving personal marks and slots.

Pairing is one-to-one: another editor cannot steal your connection. Reconnection is
manual. Connect only to trusted local instances; the bridge is not an isolation
boundary against other processes running as your user.

## Development

```sh
npm ci --ignore-scripts
npm run typecheck
npm run lint                 # requires stylua on PATH
```

[Architecture and protocol](docs/architecture.md) · [Smoke checks and validation](docs/smoke.md)

Originally extracted from `Tekindar666/dotfiles` and the author's Pi configuration.
