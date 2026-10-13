-- Run from the repository root: nvim --headless -u NONE -l tests/nvim-pi-prompt.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
local composer = require("pi.prompt")

local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local function settle()
  vim.wait(20, function()
    return false
  end)
end

local function keys(value)
  vim.api.nvim_feedkeys(vim.keycode(value), "xt", false)
end

local function invoke(key)
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(type(mapping.callback) == "function", "Missing mapping: " .. key)
  mapping.callback()
  settle()
end

vim.o.columns = 120
vim.o.lines = 40
local source = vim.api.nvim_get_current_buf()
local source_window = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(source, "/test/source.lua")
vim.api.nvim_buf_set_lines(source, 0, -1, false, vim.fn["repeat"]({ string.rep("x", 100) }, 200))
vim.wo.wrap = false
keys("ggzt0")
local context = {
  file = "/test/source.lua",
  selection = { start = { line = 1, column = 1 }, ["end"] = { line = 2, column = 10 } },
  changedtick = vim.api.nvim_buf_get_changedtick(source),
}
local source_lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
local source_cursor = vim.api.nvim_win_get_cursor(source_window)
local sends = {}
local acknowledge
local function append(content, captured, done)
  table.insert(sends, { content = content, context = captured })
  acknowledge = done
end

composer.open(context, append)
local buffer = vim.api.nvim_get_current_buf()
local window = vim.api.nvim_get_current_win()
local config = vim.api.nvim_win_get_config(window)
equal("NW", config.anchor)
equal(source_window, config.win)
equal("╭", config.border[1])
assert(config.height > 1)
equal(true, vim.bo[buffer].modifiable)
equal("nofile", vim.bo[buffer].buftype)
equal(false, vim.bo[buffer].buflisted)
equal(false, vim.bo[buffer].swapfile)
equal(false, vim.bo[buffer].undofile)
equal("markdown", vim.bo[buffer].filetype)
assert(config.title[1][1]:find("source.lua:1-2", 1, true))
equal("Normal:Normal,FloatBorder:FloatBorder", vim.wo[window].winhighlight)

-- Synchronous feedkeys in a Lua script needs an explicit mode transition.
-- Startup Insert mode is checked separately in an embedded editor's real input loop below.
vim.cmd("stopinsert")
keys("iFirst paragraph<CR>Second paragraph<Esc>")
equal({ "First paragraph", "Second paragraph" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
equal("n", vim.fn.mode())
equal(0, #sends)
equal(true, vim.api.nvim_win_is_valid(window))
keys("A!<Esc>")
keys("u")
equal({ "First paragraph", "Second paragraph" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
keys("<C-r>")
equal({ "First paragraph", "Second paragraph!" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))

-- Repeated opens focus the same composer, not a second window or a new source context.
composer.open({}, append)
equal(window, vim.api.nvim_get_current_win())
keys("<Esc>")
invoke("q")
equal(source_window, vim.api.nvim_get_current_win())
equal(source_cursor, vim.api.nvim_win_get_cursor(source_window))
equal(true, vim.api.nvim_buf_is_loaded(buffer))
keys("Gzb$")
composer.open({}, append)
equal(buffer, vim.api.nvim_get_current_buf())
config = vim.api.nvim_win_get_config(0)
equal("SE", config.anchor)
keys("<Esc>")
invoke("<C-s>")
equal(1, #sends)
equal("First paragraph\nSecond paragraph!", sends[1].content)
equal(context, sends[1].context)
equal(false, vim.bo[buffer].modifiable)
invoke("<C-s>")
equal(1, #sends)
acknowledge(false)
settle()
equal(true, vim.bo[buffer].modifiable)
equal(true, vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()))
invoke("<C-s>")
equal(2, #sends)

-- A late successful acknowledgement doesn't change focus/cursor in another window.
invoke("q")
local cursor = vim.api.nvim_win_get_cursor(0)
acknowledge(true)
settle()
equal(source_window, vim.api.nvim_get_current_win())
equal(cursor, vim.api.nvim_win_get_cursor(0))
equal(false, vim.api.nvim_buf_is_valid(buffer))
equal(source_lines, vim.api.nvim_buf_get_lines(source, 0, -1, false))
equal(context.changedtick, vim.api.nvim_buf_get_changedtick(source))

-- An empty closed draft is discarded so a new prompt acquires fresh context.
composer.open(context, append)
keys("<Esc>")
invoke("q")
composer.open({}, append)
vim.cmd("stopinsert")
keys("iFresh prompt<Esc>")
invoke("<C-s>")
equal({}, sends[#sends].context)
acknowledge(true)
settle()

-- Source splits with barely any height and small terminals still produce usable floats.
vim.o.columns = 30
vim.o.lines = 10
vim.cmd("belowright 1split")
composer.open({}, append)
config = vim.api.nvim_win_get_config(0)
assert(config.width >= 1 and config.width + 2 <= vim.o.columns)
assert(config.height >= 1 and config.height + 2 <= vim.o.lines)
keys("<Esc>")
invoke("q")
-- Exercise startup mode and screen placement through a real, separate editor event loop.
-- No user server, config, shada, or persistent files are touched.
local socket = vim.fn.tempname()
local child = vim.fn.jobstart({ vim.v.progpath, "-u", "NONE", "-i", "NONE", "--listen", socket }, {
  pty = true,
  width = 120,
  height = 40,
})
assert(child > 0)
local channel
local function rpc(method, ...)
  return vim.rpcrequest(channel, method, ...)
end
local ok, error = xpcall(function()
  assert(
    vim.wait(3000, function()
      return vim.uv.fs_stat(socket) ~= nil
    end),
    "Test editor did not start"
  )
  channel = vim.fn.sockconnect("pipe", socket, { rpc = true })
  assert(channel > 0)
  -- The listen socket exists before startup finishes; opening a float earlier can
  -- let the child's initial window setup steal focus before the first keystroke.
  assert(
    vim.wait(3000, function()
      return rpc("nvim_eval", "v:vim_did_enter") == 1
    end),
    "Test editor did not finish startup"
  )
  rpc(
    "nvim_exec_lua",
    [[
    vim.opt.runtimepath:append(...)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn['repeat']({ string.rep('x', 100) }, 200))
    vim.wo.wrap = false
    vim.cmd('normal! ggzt0')
    require('pi.prompt').open({}, function(content, _, done)
      _G.confirmed = content
      done(true)
    end)
  ]],
    { vim.fn.getcwd() }
  )
  assert(
    vim.wait(1000, function()
      return rpc("nvim_get_mode").mode == "i"
    end),
    "Composer did not start in Insert mode"
  )
  local float = rpc("nvim_get_current_win")
  local position = rpc("nvim_win_get_position", float)
  assert(position[1] <= 2, "Float should open just below the top-left cursor")
  rpc("nvim_input", "First line<CR>Second line<Esc>")
  assert(vim.wait(1000, function()
    return rpc("nvim_get_mode").mode == "n"
  end))
  equal({ "First line", "Second line" }, rpc("nvim_buf_get_lines", 0, 0, -1, false))
  equal(vim.NIL, rpc("nvim_exec_lua", "return _G.confirmed", {}))
  equal(true, rpc("nvim_win_is_valid", float))
  rpc("nvim_input", "q")
  assert(vim.wait(1000, function()
    return not rpc("nvim_win_is_valid", float)
  end))

  rpc(
    "nvim_exec_lua",
    [[
    vim.cmd('normal! Gzb$')
    require('pi.prompt').open({}, function() end)
  ]],
    {}
  )
  assert(vim.wait(1000, function()
    return rpc("nvim_get_mode").mode == "i"
  end))
  float = rpc("nvim_get_current_win")
  position = rpc("nvim_win_get_position", float)
  local dimensions = rpc("nvim_win_get_config", float)
  equal("SE", dimensions.anchor)
  assert(position[1] >= 0 and position[1] + dimensions.height + 2 <= 40)
  assert(position[2] >= 0 and position[2] + dimensions.width + 2 <= 120)
  equal({ "First line", "Second line" }, rpc("nvim_buf_get_lines", 0, 0, -1, false))

  rpc("nvim_input", "<Esc>q")
  assert(vim.wait(1000, function()
    return not rpc("nvim_win_is_valid", float)
  end))
  vim.fn.jobresize(child, 30, 10)
  assert(vim.wait(1000, function()
    return rpc("nvim_get_option_value", "columns", {}) == 30
  end))
  rpc("nvim_exec_lua", [[require('pi.prompt').open({}, function() end)]], {})
  assert(vim.wait(1000, function()
    return rpc("nvim_get_mode").mode == "i"
  end))
  float = rpc("nvim_get_current_win")
  position = rpc("nvim_win_get_position", float)
  dimensions = rpc("nvim_win_get_config", float)
  assert(position[1] >= 0 and position[1] + dimensions.height + 2 <= 10, vim.inspect({ position, dimensions }))
  assert(position[2] >= 0 and position[2] + dimensions.width + 2 <= 30, vim.inspect({ position, dimensions }))
  rpc("nvim_input", "<C-s>")
  assert(vim.wait(1000, function()
    return not rpc("nvim_win_is_valid", float)
  end))
  equal("First line\nSecond line", rpc("nvim_exec_lua", "return _G.confirmed", {}))
end, debug.traceback)
if channel then
  vim.fn.chanclose(channel)
end
vim.fn.jobstop(child)
vim.fn.jobwait({ child }, 1000)
vim.fn.delete(socket)
assert(ok, error)
print("Pi multiline composer checks passed")
