local M = {}

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.publish(params)
  if type(params) ~= "table" or type(params.cwd) ~= "string" or params.cwd == "" then
    error("publish_harpoon requires Pi's working directory")
  end
  local root = vim.uv.cwd()
  if canonical(params.cwd) ~= canonical(root) then
    error("Pi and Neovim must use the same working directory before publishing Harpoon marks")
  end
  if not vim.islist(params.paths) or #params.paths > 20 then
    error("publish_harpoon requires a list of at most 20 paths; use an empty list to clear Pi marks")
  end

  local paths = {}
  local seen = {}
  for _, path in ipairs(params.paths) do
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[\r\n%z]") then
      error("Every Harpoon path must be an absolute file path without line breaks")
    end
    path = canonical(path)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type ~= "file" then
      error("Harpoon path is not a file: " .. path)
    end
    if not stat and vim.fn.bufnr(path) == -1 then
      error("Harpoon file does not exist and has no Neovim buffer: " .. path)
    end
    if not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end

  local harpoon = require("harpoon")
  if harpoon.ui.win_id and vim.api.nvim_win_is_valid(harpoon.ui.win_id) then
    error("Close the Harpoon menu before replacing the working set")
  end
  local list = harpoon:list()
  local Path = require("plenary.path")
  local personal = {}
  local removed = 0
  for index = list:length(), 1, -1 do
    local item = list:get(index)
    if item then
      if item.context and item.context.pi_working_set then
        list:remove_at(index)
        removed = removed + 1
      else
        personal[canonical(Path:new(item.value):absolute())] = true
      end
    end
  end

  local added = 0
  for _, path in ipairs(paths) do
    if not personal[path] then
      list:add({
        value = Path:new(path):make_relative(root),
        context = { row = 1, col = 0, pi_working_set = true },
      })
      added = added + 1
    end
  end
  -- Ownership survives reconnects/restarts; removal keeps personal shortcut slots intact.
  harpoon:sync()
  return { added = added, removed = removed, shared = #paths - added }
end

return M
