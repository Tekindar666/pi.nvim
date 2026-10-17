local M = {}
local quickfix_id

local function positive(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Read only loaded buffers. Never fall back to disk or change editor focus.
function M.read_buffer(params)
  if type(params.path) ~= "string" or params.path:sub(1, 1) ~= "/" then
    error("read_buffer requires an absolute file path")
  end
  local buffer
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(candidate)
      and canonical(vim.api.nvim_buf_get_name(candidate)) == canonical(params.path)
    then
      buffer = candidate
      break
    end
  end
  if not buffer then
    error("File is not loaded in Neovim: " .. params.path)
  end
  local offset, limit = params.offset or 1, params.limit or 2000
  if not positive(offset) or not positive(limit) then
    error("offset and limit must be positive integers")
  end
  local total = vim.api.nvim_buf_line_count(buffer)
  local lines, bytes = {}, 0
  for index = offset, math.min(total, offset + math.min(limit, 2000) - 1) do
    local line = vim.api.nvim_buf_get_lines(buffer, index - 1, index, false)[1]
    if bytes + #line + 1 > 50 * 1024 then
      if #lines == 0 then
        error("This buffer line exceeds the 50KB response limit")
      end
      break
    end
    lines[#lines + 1] = line
    bytes = bytes + #line + 1
  end
  return {
    file = vim.api.nvim_buf_get_name(buffer),
    bufnr = buffer,
    modified = vim.bo[buffer].modified,
    filetype = vim.bo[buffer].filetype,
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    totalLines = total,
    offset = offset,
    lines = lines,
  }
end

--- Keep one Pi-owned quickfix list across connections. Never open a window or jump to an item.
function M.publish_quickfix(params)
  if type(params.title) ~= "string" or params.title == "" or not vim.islist(params.items) then
    error("publish_quickfix requires a title and items")
  end
  if params.mode ~= "replace" and params.mode ~= "append" then
    error("publish_quickfix requires replace or append mode")
  end
  for _, item in ipairs(params.items) do
    if
      type(item) ~= "table"
      or type(item.filename) ~= "string"
      or item.filename:sub(1, 1) ~= "/"
      or not positive(item.lnum)
      or type(item.text) ~= "string"
    then
      error("Every quickfix item requires an absolute filename, positive line, and text")
    end
  end
  local existing = quickfix_id and vim.fn.getqflist({ id = quickfix_id, nr = 0 })
  local result
  if not existing or existing.id ~= quickfix_id then
    -- Appending at the stack's end preserves newer personal lists when an older list is selected.
    result = vim.fn.setqflist(
      {},
      " ",
      { nr = "$", title = params.title, items = params.items, context = { source = "pi" } }
    )
    if result == 0 then
      quickfix_id = vim.fn.getqflist({ nr = "$", id = 0 }).id
    end
  else
    local action = params.mode == "append" and "a" or "r"
    result = vim.fn.setqflist({}, action, { id = quickfix_id, title = params.title, items = params.items })
    if result == 0 then
      vim.cmd("silent " .. existing.nr .. "chistory")
    end
  end
  if result ~= 0 then
    error("Neovim could not update the Pi quickfix list")
  end
  return { id = quickfix_id, title = params.title, count = #vim.fn.getqflist({ id = quickfix_id, items = 0 }).items }
end

function M.publish_harpoon(params)
  return require("pi.harpoon").publish(params)
end

return M
