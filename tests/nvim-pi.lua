-- Run from the repository root: nvim --headless -u NONE -l tests/nvim-pi.lua
vim.opt.runtimepath:append(vim.fn.getcwd())

local requests = {}
local responses = {}
local notifications = {}
local reader
local submitted = true
local reply_ok = true
local hold_reply = false
local connect_error
local socket_available = true

vim.notify = function(message)
  table.insert(notifications, message)
end
vim.system = function()
  return {
    wait = function()
      return { code = socket_available and 0 or 1, stdout = "/test/pi.sock" }
    end,
  }
end
vim.env.TMUX_PANE = "%test"
vim.uv.new_pipe = function()
  return {
    connect = function(_, _, callback)
      callback(connect_error)
    end,
    read_start = function(_, callback)
      reader = callback
    end,
    write = function(_, data)
      local message = vim.json.decode(data)
      if message.type == "register" then
        return
      end
      if message.type == "response" then
        table.insert(responses, message)
        return
      end
      table.insert(requests, message)
      if hold_reply then
        return
      end
      reader(nil, vim.json.encode({
        version = 1,
        type = "response",
        id = message.id,
        ok = reply_ok,
        error = not reply_ok and "Pi rejected the append" or nil,
        result = { submitted = submitted },
      }) .. "\n")
    end,
    is_closing = function()
      return false
    end,
    close = function() end,
  }
end

local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local function invoke(mode, keys)
  local mapping = vim.fn.maparg(keys, mode, false, true)
  assert(type(mapping.callback) == "function", "Missing mapping: " .. keys)
  mapping.callback()
  vim.wait(20, function()
    return false
  end)
end

local function select_lines()
  vim.api.nvim_feedkeys("ggVj", "xt", false)
  equal("V", vim.fn.mode())
end

vim.api.nvim_buf_set_name(0, "/test/example.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1", "print(value)" })
vim.g.mapleader = " "
dofile("examples/keymaps.lua")

invoke("n", " pa")
equal("draft", requests[#requests].type)
equal("Neovim context", requests[#requests].label)
equal(nil, requests[#requests].context.selection)

select_lines()
invoke("x", " pa")
equal("draft", requests[#requests].type)
equal(1, requests[#requests].context.selection.start.line)
equal(2, requests[#requests].context.selection["end"].line)

local source_buffer = vim.api.nvim_get_current_buf()
local source_tick = vim.api.nvim_buf_get_changedtick(source_buffer)
local source_cursor = vim.api.nvim_win_get_cursor(0)
local before_prompt = #requests
invoke("x", " pp")
equal(before_prompt, #requests)
local prompt_buffer = vim.api.nvim_get_current_buf()
assert(prompt_buffer ~= source_buffer)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Explain the selection", "and its callers" })
invoke("n", "<C-s>")
equal("draft", requests[#requests].type)
equal("Explain the selection\nand its callers", requests[#requests].content)
equal("/test/example.lua", requests[#requests].context.file)
equal(source_tick, requests[#requests].context.changedtick)
equal(1, requests[#requests].context.selection.start.line)
equal(2, requests[#requests].context.selection["end"].line)
equal(source_buffer, vim.api.nvim_get_current_buf())
equal(source_cursor, vim.api.nvim_win_get_cursor(0))
equal(false, vim.api.nvim_buf_is_valid(prompt_buffer))

local before_cancel = #requests
invoke("n", " pp")
invoke("n", "q")
equal(before_cancel, #requests)
invoke("n", " pp")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "  " })
invoke("n", "<C-s>")
equal(before_cancel, #requests)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Explain the design" })
invoke("n", "<C-s>")
equal("draft", requests[#requests].type)
equal("Explain the design", requests[#requests].content)
equal("/test/example.lua", requests[#requests].context.file)
equal({ line = source_cursor[1], column = source_cursor[2] + 1 }, requests[#requests].context.cursor)
equal(source_tick, requests[#requests].context.changedtick)
equal(nil, requests[#requests].context.selection)
equal("%test", requests[#requests].context.tmuxPane)
assert(requests[#requests].context.projectRoot)

-- Rejected appends keep editable text for an explicit retry.
invoke("n", " pp")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Keep this prompt" })
prompt_buffer = vim.api.nvim_get_current_buf()
reply_ok = false
invoke("n", "<C-s>")
equal(true, vim.bo[prompt_buffer].modifiable)
equal({ "Keep this prompt" }, vim.api.nvim_buf_get_lines(prompt_buffer, 0, -1, false))
reply_ok = true

-- Pending sends freeze text and block duplicate confirmation, including after close/reopen.
hold_reply = true
local before_send = #requests
invoke("n", "<C-s>")
equal(false, vim.bo[prompt_buffer].modifiable)
invoke("n", "<C-s>")
invoke("n", "q")
invoke("n", " pp")
invoke("n", "<C-s>")
equal(before_send + 1, #requests)
local pending_request = requests[#requests]
reader(nil, vim.json.encode({ version = 1, type = "response", id = pending_request.id, ok = true }) .. "\n")
vim.wait(20, function()
  return false
end)
equal(false, vim.api.nvim_buf_is_valid(prompt_buffer))
hold_reply = false

-- Discovery/connection failures must unlock the composer without discarding its contents.
invoke("n", " pp")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Reconnect and keep me" })
prompt_buffer = vim.api.nvim_get_current_buf()
socket_available = false
invoke("n", "<C-s>")
equal(true, vim.bo[prompt_buffer].modifiable)
socket_available = true
reader(nil, nil)
connect_error = "connection refused"
invoke("n", "<C-s>")
equal(true, vim.bo[prompt_buffer].modifiable)
equal({ "Reconnect and keep me" }, vim.api.nvim_buf_get_lines(prompt_buffer, 0, -1, false))
connect_error = nil

-- Disconnecting an in-flight append retains text too; no automatic retry.
hold_reply = true
invoke("n", "<C-s>")
reader(nil, nil)
vim.wait(20, function()
  return false
end)
equal(true, vim.bo[prompt_buffer].modifiable)
equal({ "Reconnect and keep me" }, vim.api.nvim_buf_get_lines(prompt_buffer, 0, -1, false))
hold_reply = false
invoke("n", "<C-s>")
equal(false, vim.api.nvim_buf_is_valid(prompt_buffer))

-- A timeout retains the prompt and ignores a late acknowledgement; retry stays explicit.
invoke("n", " pp")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Slow acknowledgement" })
prompt_buffer = vim.api.nvim_get_current_buf()
hold_reply = true
invoke("n", "<C-s>")
local timed_out = requests[#requests]
local after_send = #requests
assert(vim.wait(5500, function()
  return vim.bo[prompt_buffer].modifiable
end))
equal(after_send, #requests)
reader(nil, vim.json.encode({ version = 1, type = "response", id = timed_out.id, ok = true }) .. "\n")
vim.wait(20, function()
  return false
end)
equal({ "Slow acknowledgement" }, vim.api.nvim_buf_get_lines(prompt_buffer, 0, -1, false))
assert(notifications[#notifications]:find("check Pi's draft before retrying", 1, true))
hold_reply = false
invoke("n", "<C-s>")
equal(false, vim.api.nvim_buf_is_valid(prompt_buffer))

local namespace = vim.api.nvim_create_namespace("pi-test")
vim.diagnostic.set(namespace, 0, {
  { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "Test diagnostic" },
})
invoke("n", " pd")
equal("draft", requests[#requests].type)
equal("Neovim diagnostics", requests[#requests].label)

local get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return {
    {
      name = "test",
      offset_encoding = "utf-16",
      request_sync = function()
        return { result = { contents = "Test hover" } }
      end,
    },
  }
end
invoke("n", " ph")
vim.lsp.get_clients = get_clients
equal("draft", requests[#requests].type)
equal("Neovim LSP hover", requests[#requests].label)

for _, request in ipairs(requests) do
  equal("draft", request.type)
end
equal("", vim.fn.maparg(" p<CR>", "n"))
equal("", vim.fn.maparg(" p<CR>", "x"))
invoke("n", " ps")
equal("submit", requests[#requests].type)
equal("Pi draft submitted", notifications[#notifications])
equal("Pi ●", require("pi").status())

submitted = false
invoke("x", " ps")
equal("submit", requests[#requests].type)
equal("Pi draft is empty", notifications[#notifications])
local published
package.loaded["pi.harpoon"] = {
  publish = function(params)
    published = params
    return { added = 1, removed = 0, shared = 0 }
  end,
}
reader(nil, vim.json.encode({
  version = 1,
  type = "request",
  id = "harpoon-test",
  method = "publish_harpoon",
  params = { cwd = "/test", paths = { "/test/example.lua" } },
}) .. "\n")
assert(vim.wait(1000, function()
  return #responses > 0
end))
equal({ cwd = "/test", paths = { "/test/example.lua" } }, published)
equal(true, responses[1].ok)
equal("harpoon-test", responses[1].id)
equal({ added = 1, removed = 0, shared = 0 }, responses[1].result)
print("Pi draft keymap and Harpoon routing checks passed")
