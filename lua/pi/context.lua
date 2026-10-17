local M = {}

--- Capture source identity and positions, not file contents. Positions are one-based byte columns.
function M.capture(range)
  local buffer = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buffer)
  if vim.bo[buffer].buftype ~= "" or file == "" then
    error("Open a named file buffer before composing a Pi question")
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local context = {
    projectRoot = vim.uv.cwd(),
    file = file,
    cursor = { line = cursor[1], column = cursor[2] + 1 },
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
  }
  if range and range.range > 0 then
    local last = vim.api.nvim_buf_get_lines(buffer, range.line2 - 1, range.line2, false)[1]
    context.selection = {
      start = { line = range.line1, column = 1 },
      ["end"] = { line = range.line2, column = math.max(1, #last) },
    }
  end
  return context
end

return M
