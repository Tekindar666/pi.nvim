-- Optional mappings; pi.nvim does not install global keymaps.
local pi = require("pi")
vim.keymap.set({ "n", "x" }, "<leader>pa", pi.add_context, { desc = "Add Context to Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>pp", pi.prompt, { desc = "Add Prompt to Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>ps", pi.submit, { desc = "Submit Pi Draft" })
vim.keymap.set({ "n", "x" }, "<leader>pd", pi.add_diagnostics, { desc = "Add Diagnostics to Pi" })
vim.keymap.set({ "n", "x" }, "<leader>ph", pi.add_hover, { desc = "Add LSP Hover to Pi" })
