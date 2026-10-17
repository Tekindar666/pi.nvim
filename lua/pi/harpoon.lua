local M = {}

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Replace only marks tagged by Pi. Personal items retain their original slots and context.
function M.publish(params)
  local root = vim.uv.cwd()
  if type(params.cwd) ~= "string" or canonical(params.cwd) ~= canonical(root) then
    error("Pi and Neovim must use the same working directory for Harpoon publishing")
  end
  if not vim.islist(params.paths) or #params.paths > 20 then
    error("publish_harpoon requires at most 20 paths")
  end
  local paths, seen = {}, {}
  for _, path in ipairs(params.paths) do
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[\r\n%z]") then
      error("Harpoon requires absolute file paths without line breaks")
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
      paths[#paths + 1] = path
    end
  end

  local ok, harpoon = pcall(require, "harpoon")
  if not ok or type(harpoon.list) ~= "function" then
    error("Harpoon publishing requires Harpoon 2 and plenary.nvim")
  end
  if harpoon.ui.win_id and vim.api.nvim_win_is_valid(harpoon.ui.win_id) then
    error("Close the Harpoon menu before publishing marks")
  end
  local Path = require("plenary.path")
  local list = harpoon:list()
  local personal, removed = {}, 0
  for index = list:length(), 1, -1 do
    local item = list:get(index)
    if item then
      if item.context and item.context.pi_working_set then
        -- Harpoon 2 removes without shifting later slots.
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
      list:add({ value = Path:new(path):make_relative(root), context = { row = 1, col = 0, pi_working_set = true } })
      added = added + 1
    end
  end
  harpoon:sync()
  return { added = added, removed = removed, shared = #paths - added }
end

return M
