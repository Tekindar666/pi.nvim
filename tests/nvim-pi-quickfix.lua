-- Run from the repository root: nvim --headless -u NONE -l tests/nvim-pi-quickfix.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
local responses = {}
local reader
vim.env.TMUX_PANE = "%test"
vim.system = function()
  return {
    wait = function()
      return { code = 0, stdout = "/test/pi.sock" }
    end,
  }
end
vim.uv.new_pipe = function()
  return {
    connect = function(_, _, callback)
      callback()
    end,
    read_start = function(_, callback)
      reader = callback
    end,
    write = function(_, data)
      local message = vim.json.decode(data)
      if message.type == "response" then
        table.insert(responses, message)
      elseif message.type == "draft" then
        reader(nil, vim.json.encode({ version = 1, type = "response", id = message.id, ok = true }) .. "\n")
      end
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
vim.api.nvim_buf_set_name(0, "/test/example.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved = true", "print(unsaved)" })
require("pi").add_context()
assert(reader, "The bridge must connect before publishing")

-- Reading sets own a separate quickfix list and must not touch user lists or source buffers.
local function publish_quickfix(mode, items)
  local before = #responses
  reader(nil, vim.json.encode({
    version = 1,
    type = "request",
    id = "quickfix-test",
    method = "publish_quickfix",
    params = { title = "Pi reading set", mode = mode, items = items },
  }) .. "\n")
  assert(vim.wait(1000, function()
    return #responses > before
  end))
  local response = responses[#responses]
  assert(response.ok, response.error)
  return response.result
end

vim.fn.setqflist(
  {},
  " ",
  { title = "User list", items = {
    { filename = "/test/personal.lua", lnum = 1, text = "Keep this finding" },
  } }
)
local personal_list = vim.fn.getqflist({ id = 0, items = 0, title = 0 })
local current_buffer = vim.api.nvim_get_current_buf()
local current_cursor = vim.api.nvim_win_get_cursor(0)
local current_tick = vim.api.nvim_buf_get_changedtick(current_buffer)
local windows = vim.api.nvim_list_wins()
local function qf_item(line, text)
  return { filename = "/test/example.lua", lnum = line, col = 1, text = text, type = "N" }
end
local result = publish_quickfix("replace", { qf_item(2, "Read second line first"), qf_item(1, "Then the first") })
local reading_id = result.id
equal(
  { "Read second line first", "Then the first" },
  vim.tbl_map(function(item)
    return item.text
  end, vim.fn.getqflist())
)

vim.fn.setqflist({}, " ", { title = "Another user list", items = { qf_item(1, "Unrelated search") } })
local other_list = vim.fn.getqflist({ id = 0, items = 0, title = 0 })
equal(reading_id, publish_quickfix("append", { qf_item(2, "Finally revisit") }).id)
equal(3, #vim.fn.getqflist())
equal(reading_id, publish_quickfix("replace", { qf_item(1, "Next slice") }).id)
equal(1, #vim.fn.getqflist())
equal(0, publish_quickfix("replace", {}).count)
equal({}, vim.fn.getqflist())
for _, snapshot in ipairs({ personal_list, other_list }) do
  equal(snapshot, vim.fn.getqflist({ id = snapshot.id, items = 0, title = 0 }))
end
equal(current_buffer, vim.api.nvim_get_current_buf())
equal(current_cursor, vim.api.nvim_win_get_cursor(0))
equal(current_tick, vim.api.nvim_buf_get_changedtick(current_buffer))
equal(windows, vim.api.nvim_list_wins())
equal(true, vim.bo[current_buffer].modified)
print("Pi quickfix ownership/order/clear checks passed")
