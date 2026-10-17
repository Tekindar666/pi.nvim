local M = {}
local uv = vim.uv
local DIRECTORY_MODE = tonumber("700", 8)
local FILE_MODE = tonumber("600", 8)

local function private(stat, kind, uid, mode)
  return stat and stat.type == kind and stat.uid == uid and bit.band(stat.mode, 0xFFF) == mode
end

local function advertisement(directory, name, uid)
  local path = directory .. "/" .. name
  local stat = uv.fs_lstat(path)
  if not private(stat, "file", uid, FILE_MODE) or stat.size > 16384 then
    return
  end
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return
  end
  local text = uv.fs_read(fd, 16384, 0)
  uv.fs_close(fd)
  local ok, item = pcall(vim.json.decode, text or "")
  if not ok or type(item) ~= "table" then
    return
  end
  local id = name:match("^([%x%-]+)%.json$")
  if not id or item.instanceId ~= id or item.version ~= 1 or item.protocolVersion ~= 2 then
    return
  end
  if type(item.cwd) ~= "string" or type(item.pid) ~= "number" or item.pid < 1 or item.pid % 1 ~= 0 then
    return
  end
  -- Never follow an advertisement outside this user's private registry.
  if item.socketPath ~= directory .. "/" .. id .. ".sock" then
    return
  end
  if not private(uv.fs_lstat(item.socketPath), "socket", uid, FILE_MODE) then
    return
  end
  return item
end

local function candidates()
  local uid = uv.getuid()
  local directory = "/tmp/pi-nvim-" .. uid
  local stat, error, code = uv.fs_lstat(directory)
  if not stat then
    if code == "ENOENT" then
      return {}
    end
    return nil, error
  end
  if not private(stat, "directory", uid, DIRECTORY_MODE) then
    return nil, "Unsafe Pi registry: expected an owned, non-symlink directory with mode 0700"
  end
  local scan, scan_error = uv.fs_scandir(directory)
  if not scan then
    return nil, scan_error
  end
  local items = {}
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if name:match("%.json$") then
      local item = advertisement(directory, name, uid)
      if item then
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function probe(path, callback)
  local pipe = uv.new_pipe(false)
  local timer = uv.new_timer()
  if not pipe or not timer then
    if pipe then
      pipe:close()
    end
    if timer then
      timer:close()
    end
    vim.schedule(function()
      callback(false)
    end)
    return
  end
  local finished = false
  local function finish(alive)
    if finished then
      return
    end
    finished = true
    timer:stop()
    timer:close()
    pipe:close()
    vim.schedule(function()
      callback(alive)
    end)
  end
  timer:start(300, 0, function()
    finish(false)
  end)
  local ok, request = pcall(function()
    return pipe:connect(path, function(error)
      -- No registration: discovery must never acquire or displace ownership.
      finish(not error)
    end)
  end)
  if not ok or not request then
    finish(false)
  end
end

--- Discover reachable candidates, not guaranteed available pairings. Never deletes registry files.
--- Probes are bounded to eight sockets at a time; callback runs on Neovim's main loop.
function M.list(callback)
  local items, error = candidates()
  if not items or #items == 0 then
    vim.schedule(function()
      callback(items, error)
    end)
    return
  end
  local found, next_index, remaining = {}, 1, #items
  local function advance()
    local item = items[next_index]
    if not item then
      return
    end
    next_index = next_index + 1
    probe(item.socketPath, function(alive)
      if alive then
        found[#found + 1] = item
      end
      remaining = remaining - 1
      if remaining == 0 then
        table.sort(found, function(left, right)
          if left.cwd == right.cwd then
            return left.instanceId < right.instanceId
          end
          return left.cwd < right.cwd
        end)
        callback(found)
      else
        advance()
      end
    end)
  end
  for _ = 1, math.min(8, #items) do
    advance()
  end
end

return M
