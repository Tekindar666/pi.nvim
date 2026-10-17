local M = {}
local connection = nil
local CONNECT_TIMEOUT_MS = 5000
local next_id = 0

local function finish_request(target, id, ok, result)
  local pending = target.pending[id]
  if not pending then
    return
  end
  target.pending[id] = nil
  pending.timer:stop()
  pending.timer:close()
  vim.schedule(function()
    pending.callback(ok, result)
  end)
end

local function complete(target, ok, reason)
  local callback = target.callback
  target.callback = nil
  if target.timer then
    target.timer:stop()
    target.timer:close()
    target.timer = nil
  end
  if callback then
    vim.schedule(function()
      callback(ok, reason)
    end)
  end
end

local function close(target, reason)
  if target.closed then
    return
  end
  target.closed = true
  if connection == target then
    connection = nil
  end
  if not target.pipe:is_closing() then
    target.pipe:close()
  end
  complete(target, false, reason)
  for id in pairs(target.pending) do
    finish_request(target, id, false, reason .. ". Delivery may have occurred; check Pi before retrying.")
  end
end

local function send(target, message)
  if target.closed then
    return
  end
  local encoded, payload = pcall(vim.json.encode, message)
  if not encoded then
    close(target, "Could not encode bridge message: " .. tostring(payload))
    return
  end
  payload = payload .. "\n"
  if #payload > 1024 * 1024 then
    close(target, "Bridge message exceeds 1MB")
    return
  end
  local request, error = target.pipe:write(payload, function(write_error)
    if target.closed then
      return
    end
    if write_error then
      close(target, write_error)
    end
  end)
  if not request then
    close(target, error or "Failed to write to Pi")
  end
end

local function handle_message(target, line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    close(target, "Pi sent an invalid bridge message")
    return
  end
  if message.version ~= 2 then
    close(target, "Incompatible bridge protocol; update both Pi and Neovim to version 2")
    return
  end

  if not target.paired then
    if message.type ~= "registered" or type(message.ok) ~= "boolean" then
      close(target, "Expected Pi pairing response")
    elseif not message.ok then
      close(target, type(message.error) == "string" and message.error or "Pi rejected pairing")
    else
      target.paired = true
      complete(target, true)
    end
    return
  end

  if message.type == "response" and type(message.id) == "string" and type(message.ok) == "boolean" then
    local result = message.result
    if not message.ok then
      result = type(message.error) == "string" and message.error or "Pi rejected the request"
    end
    finish_request(target, message.id, message.ok, result)
  elseif message.type == "request" and type(message.id) == "string" then
    vim.schedule(function()
      if target.closed then
        return
      end
      local success, result = pcall(function()
        local handler = require("pi.editor")[message.method]
        if not handler then
          error("Unsupported Neovim method: " .. tostring(message.method))
        end
        if type(message.params) ~= "table" then
          error("Editor request requires params")
        end
        return handler(message.params)
      end)
      local response = { version = 2, type = "response", id = message.id, ok = success }
      if success then
        response.result = result
      else
        response.error = tostring(result)
      end
      send(target, response)
    end)
  else
    close(target, "Pi sent an unsupported bridge message")
  end
end

local function start_reader(target)
  local started, error = target.pipe:read_start(function(read_error, data)
    if target.closed then
      return
    end
    if read_error or not data then
      local reason = "Pi disconnected"
      if not target.paired then
        reason = "Pi disconnected before accepting pairing (protocol v2 required)"
      end
      close(target, read_error or reason)
      return
    end

    -- Socket chunks can contain partial messages or several newline-delimited messages.
    target.buffer = target.buffer .. data
    if #target.buffer > 1024 * 1024 then
      close(target, "Bridge message exceeds 1MB")
      return
    end
    while not target.closed do
      local newline = target.buffer:find("\n", 1, true)
      if not newline then
        break
      end
      local line = target.buffer:sub(1, newline - 1):gsub("\r$", "")
      target.buffer = target.buffer:sub(newline + 1)
      if line ~= "" then
        handle_message(target, line)
      end
    end
  end)
  if not started then
    close(target, error or "Failed to read from Pi")
  end
end

--- Connect to a supplied Pi Unix socket; never discover or reconnect automatically.
--- callback(ok, error) runs once on Neovim's main loop. Success means Pi accepted
--- exclusive pairing using protocol v2. Connection and pairing have a five-second deadline.
--- Disconnect before choosing another socket. Later disconnection silently releases it.
---@param path string
---@param callback fun(ok: boolean, error: string|nil)
function M.connect(path, callback)
  assert(type(callback) == "function", "connect requires a callback")
  if type(path) ~= "string" or path == "" then
    vim.schedule(function()
      callback(false, "connect requires a socket path")
    end)
    return
  end
  if connection then
    vim.schedule(function()
      callback(false, "Already connected or connecting; disconnect first")
    end)
    return
  end

  local pipe, error = vim.uv.new_pipe(false)
  if not pipe then
    vim.schedule(function()
      callback(false, error or "Failed to create a socket")
    end)
    return
  end

  local timer, timer_error = vim.uv.new_timer()
  if not timer then
    pipe:close()
    vim.schedule(function()
      callback(false, timer_error or "Failed to create connection timer")
    end)
    return
  end
  local target = {
    pipe = pipe,
    buffer = "",
    callback = callback,
    closed = false,
    paired = false,
    pending = {},
    timer = timer,
  }
  connection = target
  timer:start(CONNECT_TIMEOUT_MS, 0, function()
    close(target, "Pi pairing timed out (protocol v2 required)")
  end)
  local registration = { version = 2, type = "register", projectRoot = vim.uv.cwd() }
  local ok, connect_error = pcall(function()
    local request, error = pipe:connect(path, function(error)
      if target.closed then
        return
      end
      if error then
        close(target, error)
        return
      end
      start_reader(target)
      if not target.closed then
        send(target, registration)
      end
    end)
    if not request then
      close(target, error or "Failed to connect to Pi")
    end
  end)
  if not ok then
    close(target, tostring(connect_error))
  end
end

local function request(message, callback)
  assert(type(callback) == "function", "request requires a callback")
  local target = connection
  if not target or not target.paired then
    vim.schedule(function()
      callback(false, "Connect to Pi first with :PiConnect")
    end)
    return
  end
  local timer, error = vim.uv.new_timer()
  if not timer then
    vim.schedule(function()
      callback(false, error or "Could not create request timer")
    end)
    return
  end
  next_id = next_id + 1
  local id = "nvim-" .. next_id
  message.version = 2
  message.id = id
  target.pending[id] = { callback = callback, timer = timer }
  timer:start(CONNECT_TIMEOUT_MS, 0, function()
    finish_request(target, id, false, "Pi request timed out. Delivery may have occurred; check Pi before retrying.")
  end)
  send(target, message)
end

--- Append a question and captured source context to Pi's draft, without submitting.
--- A failed callback can mean uncertain delivery; never retry automatically.
function M.draft(content, context, callback)
  request({ type = "draft", label = "Neovim question", content = content, context = context }, callback)
end

--- Submit Pi's current draft explicitly. Never reconnect or retry automatically.
function M.submit(callback)
  request({ type = "submit" }, callback)
end

--- Append and submit on the same pairing. Acknowledgement of both steps is required.
--- Partial or uncertain delivery is reported without automatically retrying either step.
function M.send_question(content, context, callback)
  assert(type(callback) == "function", "send_question requires a callback")
  local target = connection
  M.draft(content, context, function(ok, result)
    if not ok then
      callback(false, result)
      return
    end
    if type(result) ~= "table" or result.appended ~= true then
      callback(false, "Invalid draft reply; check Pi before retrying")
      return
    end
    if connection ~= target then
      callback(false, "Question appended, but connection changed; check the original Pi before retrying")
      return
    end
    M.submit(function(submitted, response)
      if not submitted then
        callback(
          false,
          "Question appended, but submission failed: " .. tostring(response) .. ". Check Pi before retrying"
        )
      elseif type(response) ~= "table" or response.submitted ~= true then
        callback(false, "Question appended, but submission was not confirmed; check Pi before retrying")
      else
        callback(true, response)
      end
    end)
  end)
end

--- Current local lifecycle state; discovery and picker state belong to the command layer.
function M.connection_state()
  if not connection then
    return "disconnected"
  end
  if connection.paired then
    return "paired"
  end
  return "connecting"
end

--- Close the current socket, including an in-progress connection. Safe to call repeatedly.
function M.disconnect()
  if connection then
    close(connection, "Disconnected by caller")
  end
end

return M
