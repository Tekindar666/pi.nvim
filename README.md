# pi.nvim

A two-way bridge between [Pi](https://pi.dev) and Neovim. Build a Pi draft from editor context without leaving Neovim; let Pi read unsaved buffers and publish explained code locations back to your editor.

## Requirements

- Neovim 0.11+ (tested with 0.12.5).
- Pi coding agent (tested with `@earendil-works/pi-coding-agent` 0.84.2).
- tmux on Linux or macOS, with Pi and Neovim in the **same tmux window**.
- Node.js 22.19+ for Pi. Windows is not supported by this Unix-socket bridge.

No LazyVim, Noice, Lualine, or Harpoon dependency is required for core features. Linux is tested; macOS is not yet verified.

## Install both sides

### Neovim (lazy.nvim)

```lua
{
  "Tekindar666/pi.nvim",
  lazy = false,
  config = function()
    require("pi").setup()
  end,
}
```

For another plugin manager, add this repository to Neovim's runtime path and call `require("pi").setup()`. Setup starts automatic connection discovery; it does not install global keymaps or change your statusline.

### Pi

```sh
pi install git:github.com/Tekindar666/pi.nvim
```

Restart Pi and Neovim after saving your work. If migrating from a local copy of the bridge, remove its extension and Lua modules first so only the package is loaded. Installing only the Neovim plugin is not sufficient.

Pi and lazy.nvim manage separate clones of this repository. Update both sides together. Pi supports pinning a Git tag or commit with `@ref`; lazy.nvim supports `commit` or `tag`.

## Use

Add your preferred mappings; these are examples, not automatically installed defaults:

```lua
local pi = require("pi")
vim.keymap.set({ "n", "x" }, "<leader>pa", pi.add_context, { desc = "Add Context to Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>pp", pi.prompt, { desc = "Add Prompt to Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>ps", pi.submit, { desc = "Submit Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>pd", pi.add_diagnostics, { desc = "Add Diagnostics to Pi" })
vim.keymap.set({ "n", "x" }, "<leader>ph", pi.add_hover, { desc = "Add LSP Hover to Pi" })
```

- `add_context()` appends the current file, cursor/selection and buffer change counter to Pi's draft. It does not copy the whole buffer or start a turn.
- `prompt()` opens a multiline floating composer with the current source context. **Ctrl-S** appends to Pi's draft; **Esc**, then **q** closes while retaining text. Acknowledged appends clear the composer. Failures retain it; after a timeout, inspect Pi's draft before retrying because the append may already have arrived.
- `add_diagnostics()` appends diagnostics overlapping the cursor line or selected lines.
- `add_hover()` appends LSP hover information at the cursor.
- `submit()` explicitly sends the whole Pi draft. If Pi is working, it queues a follow-up. Empty drafts do nothing.
- `status()` returns `Pi ○` (disconnected), `Pi ●` (connected/idle), or `Pi ◐` (working). Neovim notifies when work settles.

Optional Lualine component:

```lua
{ function() return require("pi").status() end }
```

### Tools available to Pi

- **`nvim_read_buffer`** reads live, potentially unsaved buffer contents, with pagination and output truncation. It never saves the buffer.
- **`nvim_publish_quickfix`** publishes an ordered reading set or requested findings. It owns a separate quickfix list, preserves unrelated lists, and does not open windows or move the cursor. Use `:copen` to view it. Replacing with an empty list clears only the managed list.
- **`nvim_publish_harpoon`** optionally replaces Pi-owned Harpoon marks while preserving personal marks and shortcut slots. Requires Harpoon's `harpoon2` branch and `plenary.nvim`, matching working directories, and a closed Harpoon menu. Without those plugins, only this tool is unavailable; the rest of the bridge works.

Quickfix is intended for agreed walkthroughs and requested findings. Harpoon publishing is intended only for explicit requests; these guidelines ship with the tools.

## Connection and privacy

Pi publishes a Unix socket path in the tmux window option `@pi_nvim_bridge`; Neovim discovers it every two seconds while disconnected. Messages use the existing version-1 newline-delimited JSON protocol. Requests time out after five seconds and are not automatically retried.

Use **one Pi session per tmux window**: the last session to register owns discovery. Editor tools route to the most recently registered/active editor connection; a single editor per window avoids ambiguity. Reconnection can create a new managed quickfix list; old lists remain in quickfix history. Prompt composer text is in memory only and does not survive exiting Neovim.

The socket is local and owner-readable/writable (`0600`). It is not an isolation boundary against other processes running as your user. The extension has Pi's normal system permissions. Context and text you append become part of the Pi prompt when submitted, so avoid sending secrets. The plugin does not independently contact an AI provider.

## Development

```sh
npm ci --ignore-scripts
npm test
npm run typecheck
npm run lint                 # requires stylua on PATH
npm run test:harpoon         # requires Harpoon 2 and plenary
```

Set `NVIM_PLUGIN_DIR` for the Harpoon test if plugins are not in Neovim's `data/lazy` directory. Tests isolate editor processes and Harpoon data; they do not overwrite personal marks or contact a model. The integration test uses real Neovim and real sockets with a simulated Pi editor/API and substituted tmux discovery.

The development dependency pins the tested Pi runtime. Consumers use their host Pi's bundled imports; there are no bundled Pi runtime dependencies and no npm publication.

## Origin

Extracted from `Tekindar666/dotfiles` (Neovim client) and the author's Pi configuration (companion extension). Keybindings and personal statusline styling remain outside the plugin.
