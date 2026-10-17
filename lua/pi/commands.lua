local M = {}
local choosing = false
local generation = 0
local submitting = false

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Pi" })
end

function M.connect()
  local pi = require("pi")
  if choosing then
    notify("Pi selection is already pending")
    return
  end
  if pi.connection_state() ~= "disconnected" then
    notify("Already connected or connecting; use :PiDisconnect first", vim.log.levels.WARN)
    return
  end
  choosing = true
  generation = generation + 1
  local current = generation
  require("pi.discovery").list(function(items, error)
    if current ~= generation then
      return
    end
    if not items or #items == 0 then
      choosing = false
      notify(error or "No running Pi instances found", error and vim.log.levels.ERROR or vim.log.levels.INFO)
      return
    end
    local ok, selection_error = pcall(vim.ui.select, items, {
      prompt = "Connect to Pi (availability checked when selected):",
      format_item = function(item)
        return string.format("%s · PID %d · %s", vim.fn.strtrans(item.cwd), item.pid, item.instanceId:sub(1, 8))
      end,
    }, function(item)
      if current ~= generation then
        return
      end
      choosing = false
      if not item then
        return
      end
      pi.connect(item.socketPath, function(accepted, reason)
        if accepted then
          notify("Paired with Pi: " .. vim.fn.strtrans(item.cwd))
        else
          notify(reason, vim.log.levels.ERROR)
        end
      end)
    end)
    if not ok then
      choosing = false
      notify(tostring(selection_error), vim.log.levels.ERROR)
    end
  end)
end

function M.disconnect()
  generation = generation + 1
  choosing = false
  require("pi").disconnect()
  notify("Disconnected from Pi")
end

function M.busy()
  return submitting
end

function M.submit()
  if submitting or require("pi.prompt").busy() then
    notify("Wait for the pending draft or submission to complete", vim.log.levels.WARN)
    return
  end
  submitting = true
  require("pi").submit(function(ok, result)
    submitting = false
    if not ok then
      notify(tostring(result), vim.log.levels.ERROR)
    elseif type(result) ~= "table" or type(result.submitted) ~= "boolean" then
      notify("Invalid submission reply; check Pi before retrying", vim.log.levels.ERROR)
    elseif result.submitted then
      notify("Pi draft submitted")
    else
      notify("Pi draft is empty")
    end
  end)
end

return M
