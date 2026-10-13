-- Run from the repository root: nvim --headless -u NONE -l tests/nvim-pi-harpoon.lua
-- Uses installed Harpoon/plenary but isolates their persistent data from personal marks.
local repo = vim.fn.getcwd()
local plugins = vim.env.NVIM_PLUGIN_DIR or (vim.fn.stdpath("data") .. "/lazy")
vim.opt.runtimepath:append(repo)
vim.opt.runtimepath:append(plugins .. "/plenary.nvim")
vim.opt.runtimepath:append(plugins .. "/harpoon")

local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/data/nvim", "p")
vim.fn.mkdir(temp .. "/one", "p")
vim.fn.mkdir(temp .. "/two", "p")
vim.env.XDG_DATA_HOME = temp .. "/data"

local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local ok, err = xpcall(function()
  vim.api.nvim_set_current_dir(temp .. "/one")
  local root = vim.uv.cwd()
  for _, name in ipairs({ "personal.ts", "first.ts", "second.ts", "design.md" }) do
    vim.fn.writefile({ "// example" }, root .. "/" .. name)
  end
  local harpoon = require("harpoon")
  local publish = require("pi.harpoon").publish
  local list = harpoon:list()
  local personal = { value = "personal.ts", context = { row = 1, col = 0 } }
  list:add(personal)
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  equal(
    { added = 2, removed = 0, shared = 1 },
    publish({
      cwd = root,
      paths = { root .. "/first.ts", root .. "/personal.ts", root .. "/second.ts", root .. "/first.ts" },
    })
  )
  equal(personal, list:get(1))
  equal("first.ts", list:get(2).value)
  equal("second.ts", list:get(3).value)
  equal(true, list:get(2).context.pi_working_set)
  equal(buffer, vim.api.nvim_get_current_buf())
  equal(cursor, vim.api.nvim_win_get_cursor(0))
  equal({ "personal.ts", "first.ts", "second.ts" }, list:display())

  -- A personal mark added during the learning loop keeps its shortcut slot.
  list:add({ value = "design.md", context = { row = 1, col = 0 } })
  equal({ added = 1, removed = 2, shared = 0 }, publish({ cwd = root, paths = { root .. "/second.ts" } }))
  equal("second.ts", list:get(2).value)
  equal(nil, list:get(3))
  equal("design.md", list:get(4).value)

  local function rejected(params, pattern)
    local before = vim.deepcopy(list.items)
    local success, message = pcall(publish, params)
    assert(not success and tostring(message):match(pattern), tostring(message))
    equal(before, list.items)
  end
  rejected({ cwd = temp .. "/two", paths = {} }, "same working directory")
  rejected({ cwd = root, paths = { root .. "/first.ts", root .. "/missing.ts" } }, "does not exist")
  rejected({ cwd = root, paths = { root } }, "not a file")
  rejected({ cwd = root, paths = { "relative.ts" } }, "absolute file path")
  rejected({ cwd = root, paths = { root .. "/bad\nfile" } }, "without line breaks")
  rejected({ cwd = root, paths = "invalid" }, "list of at most")
  rejected({ cwd = root, paths = vim.fn["repeat"]({ root .. "/first.ts" }, 21) }, "list of at most")

  harpoon.ui.win_id = vim.api.nvim_get_current_win()
  rejected({ cwd = root, paths = {} }, "Close the Harpoon menu")
  harpoon.ui.win_id = nil

  -- Path aliases must not turn an existing personal mark into a managed mark.
  assert(vim.uv.fs_symlink(root .. "/personal.ts", root .. "/alias.ts"))
  equal({ added = 0, removed = 1, shared = 1 }, publish({ cwd = root, paths = { root .. "/alias.ts" } }))
  equal(personal, list:get(1))

  local unsaved = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(unsaved, root .. "/new.ts")
  vim.api.nvim_buf_set_lines(unsaved, 0, -1, false, { "const value = 1" })
  equal({ added = 1, removed = 0, shared = 0 }, publish({ cwd = root, paths = { root .. "/new.ts" } }))
  equal(true, vim.bo[unsaved].modified)

  -- Persisted ownership still allows safe clear after reconnect/reload.
  harpoon.lists = {}
  harpoon.data = require("harpoon.data").Data:new(harpoon.config)
  list = harpoon:list()
  equal(true, list:get(2).context.pi_working_set)
  equal({ added = 0, removed = 1, shared = 0 }, publish({ cwd = root, paths = {} }))
  equal(personal, list:get(1))
  equal("design.md", list:get(4).value)
  equal(nil, list:get(2))
  equal({ added = 0, removed = 0, shared = 0 }, publish({ cwd = root, paths = {} }))

  -- Another worktree's list is not cleared or populated by this one.
  vim.api.nvim_set_current_dir(temp .. "/two")
  equal(0, harpoon:list():length())
  equal({ added = 1, removed = 0, shared = 0 }, publish({ cwd = vim.uv.cwd(), paths = { root .. "/first.ts" } }))
  vim.api.nvim_set_current_dir(root)
  equal(personal, harpoon:list():get(1))
  equal({ added = 0, removed = 0, shared = 0 }, publish({ cwd = root, paths = {} }))
  vim.api.nvim_set_current_dir(temp .. "/two")
  equal(1, harpoon:list():length())
end, debug.traceback)

vim.api.nvim_set_current_dir(repo)
vim.fn.delete(temp, "rf")
assert(ok, err)
print("Pi Harpoon working-set checks passed")
