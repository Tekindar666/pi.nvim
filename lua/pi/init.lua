local M = {}

local tmux_option = "@pi_nvim_bridge"
local request_timeout_ms = 5000
local connection = nil
local next_id = 0
local agent_state = "idle"
local discovery_timer = nil

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level, { title = "Pi" })
  end)
end

local function redraw_statusline()
  vim.schedule(function()
    vim.cmd("redrawstatus")
  end)
end

local function get_socket_path()
  local pane = vim.env.TMUX_PANE
  if not pane or pane == "" then
    return nil, "Neovim is not running inside tmux"
  end

  local result = vim.system({ "tmux", "show-options", "-w", "-v", "-t", pane, tmux_option }, { text = true }):wait(1000)
  if result.code ~= 0 then
    return nil, "No Pi instance is registered in this tmux window"
  end

  local path = vim.trim(result.stdout or "")
  if path == "" then
    return nil, "No Pi instance is registered in this tmux window"
  end
  return path
end

local function project_root(file)
  if file ~= "" then
    local root = vim.fs.root(file, ".git")
    if root then
      return root
    end
  end
  return vim.uv.cwd()
end

local function current_context()
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local file = vim.api.nvim_buf_get_name(buffer)
  local mode = vim.fn.mode()
  local context = {
    projectRoot = project_root(file),
    file = file ~= "" and file or nil,
    cursor = { line = cursor[1], column = cursor[2] + 1 },
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    nvimServer = vim.v.servername ~= "" and vim.v.servername or nil,
    tmuxPane = vim.env.TMUX_PANE,
  }

  if mode == "v" or mode == "V" or mode == "\22" then
    local anchor = vim.fn.getpos("v")
    local active = vim.fn.getpos(".")
    local start = { line = anchor[2], column = anchor[3] }
    local finish = { line = active[2], column = active[3] }

    if start.line > finish.line or (start.line == finish.line and start.column > finish.column) then
      start, finish = finish, start
    end
    context.selection = { start = start, ["end"] = finish }
  end

  return context
end

local function find_buffer(path)
  local normalized = vim.fs.normalize(path)
  local realpath = vim.uv.fs_realpath(normalized) or normalized

  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" then
        local buffer_path = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
        if buffer_path == realpath then
          return buffer
        end
      end
    end
  end
end

local function read_buffer(params)
  if type(params) ~= "table" or type(params.path) ~= "string" or params.path == "" then
    error("read_buffer requires a file path")
  end

  local buffer = find_buffer(params.path)
  if not buffer then
    error("File is not loaded in Neovim: " .. params.path)
  end

  local total_lines = vim.api.nvim_buf_line_count(buffer)
  local offset = math.floor(tonumber(params.offset) or 1)
  local limit = math.floor(tonumber(params.limit) or 2000)
  if offset < 1 or limit < 1 then
    error("offset and limit must be positive")
  end

  local first = math.min(offset - 1, total_lines)
  local last = math.min(first + limit, total_lines)
  return {
    file = vim.api.nvim_buf_get_name(buffer),
    bufnr = buffer,
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    modified = vim.bo[buffer].modified,
    filetype = vim.bo[buffer].filetype,
    totalLines = total_lines,
    offset = first + 1,
    lines = vim.api.nvim_buf_get_lines(buffer, first, last, false),
  }
end

local function select_quickfix(id)
  local current = vim.fn.getqflist({ nr = 0 })
  local target = vim.fn.getqflist({ id = id, nr = 0 })
  if target.id ~= id or current.nr == target.nr then
    return
  end

  local difference = target.nr - current.nr
  if difference > 0 then
    vim.cmd("silent! cnewer " .. difference)
  else
    vim.cmd("silent! colder " .. -difference)
  end
end

local function publish_quickfix(params, target)
  if type(params) ~= "table" or type(params.title) ~= "string" or params.title == "" then
    error("publish_quickfix requires a title")
  end
  if params.mode ~= "replace" and params.mode ~= "append" then
    error("publish_quickfix mode must be replace or append")
  end
  if not vim.islist(params.items) then
    error("publish_quickfix requires an item list")
  end
  if params.mode == "append" and #params.items == 0 then
    error("publish_quickfix append requires at least one item; use replace to clear")
  end

  for _, item in ipairs(params.items) do
    if type(item.filename) ~= "string" or item.filename == "" then
      error("Every quickfix item requires a filename")
    end
    if type(item.lnum) ~= "number" or item.lnum < 1 then
      error("Every quickfix item requires a positive line number")
    end
    if type(item.text) ~= "string" then
      error("Every quickfix item requires text")
    end
  end

  local existing = target.quickfix_id and vim.fn.getqflist({ id = target.quickfix_id, nr = 0 }) or nil
  if not existing or existing.id ~= target.quickfix_id then
    local status = vim.fn.setqflist({}, " ", {
      nr = "$",
      title = params.title,
      items = params.items,
      context = { source = "pi" },
    })
    if status ~= 0 then
      error("Neovim failed to create the Pi quickfix list")
    end
    target.quickfix_id = vim.fn.getqflist({ nr = "$", id = 0 }).id
  else
    local action = params.mode == "append" and "a" or "r"
    local status = vim.fn.setqflist({}, action, {
      id = target.quickfix_id,
      title = params.title,
      items = params.items,
      context = { source = "pi" },
    })
    if status ~= 0 then
      error("Neovim failed to update the Pi quickfix list")
    end
    select_quickfix(target.quickfix_id)
  end

  return {
    id = target.quickfix_id,
    count = #vim.fn.getqflist({ id = target.quickfix_id, items = 0 }).items,
    title = params.title,
  }
end

local request_handlers = {
  read_buffer = read_buffer,
  publish_quickfix = publish_quickfix,
  publish_harpoon = function(params)
    return require("pi.harpoon").publish(params)
  end,
}

local function close_connection(target, reason)
  if not target or target.closed then
    return
  end
  target.closed = true
  target.connected = false

  for _, ready in ipairs(target.ready_callbacks) do
    if ready.on_error then
      ready.on_error(reason or "Pi disconnected")
    end
  end
  target.ready_callbacks = {}

  for id, pending in pairs(target.pending) do
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    if pending.callback then
      pending.callback(false, reason or "Pi disconnected")
    end
    target.pending[id] = nil
  end

  if not target.pipe:is_closing() then
    target.pipe:close()
  end
  if connection == target then
    connection = nil
  end
  redraw_statusline()
end

local function send(target, message)
  if target.closed then
    return false
  end
  target.pipe:write(vim.json.encode(message) .. "\n")
  return true
end

local function send_response(target, id, ok, result)
  local message = { version = 1, type = "response", id = id, ok = ok }
  if ok then
    message.result = result
  else
    message.error = result
  end
  send(target, message)
end

local function handle_message(target, message)
  if message.version ~= 1 or type(message.type) ~= "string" then
    close_connection(target, "Pi sent an unsupported bridge message")
    return
  end

  if message.type == "response" then
    local pending = target.pending[message.id]
    if not pending then
      return
    end
    target.pending[message.id] = nil
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    if pending.callback then
      pending.callback(message.ok, message.ok and message.result or message.error)
    end
    return
  end

  if message.type ~= "request" or type(message.id) ~= "string" then
    close_connection(target, "Pi sent an unsupported bridge request")
    return
  end

  vim.schedule(function()
    local handler = request_handlers[message.method]
    if not handler then
      send_response(target, message.id, false, "Unsupported Neovim method: " .. tostring(message.method))
      return
    end

    local ok, result = pcall(handler, message.params, target)
    if ok then
      send_response(target, message.id, true, result)
    else
      send_response(target, message.id, false, tostring(result))
    end
  end)
end

local function start_reader(target)
  target.pipe:read_start(function(error, data)
    if error then
      close_connection(target, "Failed to read from Pi: " .. error)
      return
    end
    if not data then
      close_connection(target, "Pi disconnected")
      return
    end

    target.buffer = target.buffer .. data
    while true do
      local newline = target.buffer:find("\n", 1, true)
      if not newline then
        break
      end

      local line = target.buffer:sub(1, newline - 1):gsub("\r$", "")
      target.buffer = target.buffer:sub(newline + 1)
      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if not ok then
          close_connection(target, "Pi sent invalid JSON")
          return
        end
        handle_message(target, message)
      end
    end
  end)
end

local function register(target, context)
  send(target, {
    version = 1,
    type = "register",
    projectRoot = context.projectRoot,
    nvimServer = context.nvimServer,
    tmuxPane = context.tmuxPane,
  })
end

local function ensure_connection(path, context, callback, on_error)
  if connection and not connection.closed and connection.path == path then
    if connection.connected then
      register(connection, context)
      callback(connection)
    else
      table.insert(connection.ready_callbacks, { context = context, callback = callback, on_error = on_error })
    end
    return
  end

  if connection then
    close_connection(connection, "Connecting to a different Pi instance")
  end

  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    notify("Failed to create bridge pipe", vim.log.levels.ERROR)
    if on_error then
      on_error("Failed to create bridge pipe")
    end
    return
  end

  local target = {
    pipe = pipe,
    path = path,
    buffer = "",
    pending = {},
    closed = false,
    connected = false,
    ready_callbacks = { { context = context, callback = callback, on_error = on_error } },
  }
  connection = target

  pipe:connect(path, function(error)
    if error then
      close_connection(target, "Could not connect to Pi: " .. error)
      notify("Could not connect to Pi: " .. error, vim.log.levels.ERROR)
      return
    end

    target.connected = true
    start_reader(target)
    local ready_callbacks = target.ready_callbacks
    target.ready_callbacks = {}
    for _, ready in ipairs(ready_callbacks) do
      register(target, ready.context)
      ready.callback(target)
    end
    redraw_statusline()
  end)
end

local function request(target, message, callback)
  next_id = next_id + 1
  local id = string.format("nvim-%d-%d", vim.uv.getpid(), next_id)
  message.version = 1
  message.id = id

  local timer = vim.uv.new_timer()
  target.pending[id] = { callback = callback, timer = timer }
  if timer then
    timer:start(request_timeout_ms, 0, function()
      local pending = target.pending[id]
      if not pending then
        return
      end
      target.pending[id] = nil
      timer:stop()
      timer:close()
      vim.schedule(function()
        callback(false, "Timed out waiting for Pi")
      end)
    end)
  end
  send(target, message)
end

local function set_status(params)
  if type(params) ~= "table" or (params.state ~= "working" and params.state ~= "idle") then
    error("set_status requires working or idle state")
  end

  local previous = agent_state
  agent_state = params.state
  redraw_statusline()
  if previous == "working" and agent_state == "idle" then
    vim.notify("Pi finished", vim.log.levels.INFO, { title = "Pi" })
  end
  return { state = agent_state }
end

request_handlers.set_status = set_status

function M.setup()
  if discovery_timer then
    return
  end

  discovery_timer = vim.uv.new_timer()
  if not discovery_timer then
    return
  end

  discovery_timer:start(0, 2000, function()
    vim.schedule(function()
      if connection and connection.connected then
        return
      end

      local socket_path = get_socket_path()
      if not socket_path then
        return
      end

      local context = current_context()
      ensure_connection(socket_path, context, function() end)
    end)
  end)
end

function M.status()
  if not connection or not connection.connected then
    return "Pi ○"
  end
  return agent_state == "working" and "Pi ◐" or "Pi ●"
end

function M.submit()
  local socket_path, error = get_socket_path()
  if not socket_path then
    vim.notify(error, vim.log.levels.ERROR, { title = "Pi" })
    return
  end

  ensure_connection(socket_path, current_context(), function(target)
    request(target, { type = "submit" }, function(ok, result)
      vim.schedule(function()
        if not ok then
          notify(result or "Pi rejected the draft submission", vim.log.levels.ERROR)
          return
        end
        if not result.submitted then
          vim.notify("Pi draft is empty", vim.log.levels.INFO, { title = "Pi" })
          return
        end
        vim.notify("Pi draft submitted", vim.log.levels.INFO, { title = "Pi" })
      end)
    end)
  end)
end

local function add_to_draft(label, content, context, callback)
  context = context or current_context()
  local socket_path, error = get_socket_path()
  if not socket_path then
    vim.notify(error, vim.log.levels.ERROR, { title = "Pi" })
    if callback then
      callback(false)
    end
    return
  end

  ensure_connection(socket_path, context, function(target)
    request(target, {
      type = "draft",
      label = label,
      content = content,
      context = context,
    }, function(ok, result)
      vim.schedule(function()
        if callback then
          callback(ok)
        end
        if not ok then
          local message = result or "Pi rejected the editor context"
          if callback then
            message = message .. ". Prompt kept; check Pi's draft before retrying."
          end
          notify(message, vim.log.levels.ERROR)
          return
        end
        vim.notify("Added " .. label:lower() .. " to Pi draft", vim.log.levels.INFO, { title = "Pi" })
      end)
    end)
  end, function()
    if callback then
      callback(false)
    end
  end)
end

function M.prompt()
  local context = current_context()
  require("pi.prompt").open(context, function(content, source, done)
    add_to_draft("Neovim prompt", content, source, done)
  end)
end

function M.add_context()
  add_to_draft("Neovim context")
end

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

function M.add_diagnostics()
  local context = current_context()
  local first_line = context.cursor.line
  local last_line = first_line
  if context.selection then
    first_line = context.selection.start.line
    last_line = context.selection["end"].line
  end

  local diagnostics = vim.tbl_filter(function(diagnostic)
    local diagnostic_start = diagnostic.lnum + 1
    local diagnostic_end = (diagnostic.end_lnum or diagnostic.lnum) + 1
    return diagnostic_start <= last_line and diagnostic_end >= first_line
  end, vim.diagnostic.get(0))

  if #diagnostics == 0 then
    vim.notify("No diagnostics at the selected location", vim.log.levels.INFO, { title = "Pi" })
    return
  end

  table.sort(diagnostics, function(left, right)
    if left.lnum == right.lnum then
      return left.col < right.col
    end
    return left.lnum < right.lnum
  end)

  local lines = {}
  for _, diagnostic in ipairs(diagnostics) do
    local provider = diagnostic.source or "diagnostic"
    if diagnostic.code then
      provider = provider .. "(" .. tostring(diagnostic.code) .. ")"
    end
    local location = string.format("%d:%d", diagnostic.lnum + 1, diagnostic.col + 1)
    local message = diagnostic.message:gsub("\n", " ")
    table.insert(
      lines,
      string.format("- %s [%s] %s: %s", location, severity_names[diagnostic.severity] or "UNKNOWN", provider, message)
    )
  end

  add_to_draft("Neovim diagnostics", table.concat(lines, "\n"), context)
end

function M.add_hover()
  local context = current_context()
  local buffer = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = buffer, method = "textDocument/hover" })
  if #clients == 0 then
    vim.notify("No LSP hover provider is attached", vim.log.levels.INFO, { title = "Pi" })
    return
  end

  local sections = {}
  for _, client in ipairs(clients) do
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local response = client:request_sync("textDocument/hover", params, request_timeout_ms, buffer)
    if response and response.result and response.result.contents then
      local lines = vim.lsp.util.convert_input_to_markdown_lines(response.result.contents)
      lines = vim.lsp.util.trim_empty_lines(lines)
      if #lines > 0 then
        if #clients > 1 then
          table.insert(sections, "LSP: " .. client.name)
        end
        table.insert(sections, table.concat(lines, "\n"))
      end
    end
  end

  if #sections == 0 then
    vim.notify("No LSP hover information at the cursor", vim.log.levels.INFO, { title = "Pi" })
    return
  end

  add_to_draft("Neovim LSP hover", table.concat(sections, "\n\n"), context)
end

return M
