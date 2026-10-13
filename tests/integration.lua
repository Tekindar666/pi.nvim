-- Real socket exchange; only tmux discovery is substituted to isolate the user's window.
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.system = function()
  return {
    wait = function()
      return { code = 0, stdout = vim.env.PI_TEST_SOCKET }
    end,
  }
end
vim.notify = function() end
vim.api.nvim_buf_set_name(0, "/project/example.ts")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved integration text" })
local buffer = vim.api.nvim_get_current_buf()
local cursor = vim.api.nvim_win_get_cursor(0)
local pi = require("pi")
pi.add_context()
assert(
  vim.wait(6000, function()
    return pi.status() == "Pi ◐"
  end),
  "No working status received"
)
print("WORKING")
assert(
  vim.wait(6000, function()
    return pi.status() == "Pi ●"
  end),
  "No idle status received"
)
assert(vim.fn.getqflist()[1].text == "Read this first")
assert(vim.api.nvim_get_current_buf() == buffer)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor))
assert(vim.bo[buffer].modified)
assert(#vim.api.nvim_list_wins() == 1)
print("INTEGRATION PASSED")
