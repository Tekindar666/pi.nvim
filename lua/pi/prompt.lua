local M = {}
local buffer, context
local pending = false

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Pi" })
end

local function text()
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

--- Reopen an existing question without replacing its source. Only a fresh question captures new context.
function M.open(range)
  local source = vim.api.nvim_get_current_buf()
  if text():match("^%s*$") and not pending and source ~= buffer then
    local ok, captured = pcall(require("pi.context").capture, range)
    if not ok then
      notify(tostring(captured), vim.log.levels.ERROR)
      return
    end
    context = captured
  end
  if not context then
    notify("Open a named file buffer before composing a Pi question", vim.log.levels.WARN)
    return
  end
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, "pi://question")
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].filetype = "markdown"
    vim.bo[buffer].swapfile = false
    vim.keymap.set("n", "q", "<cmd>hide<CR>", { buffer = buffer, desc = "Hide Pi question (retain text)" })
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      M.send()
    end, { buffer = buffer, desc = "Send question to Pi and close on acceptance" })
  end
  local window = vim.fn.bufwinid(buffer)
  if window ~= -1 then
    vim.api.nvim_set_current_win(window)
  else
    vim.cmd("botright 10split")
    vim.api.nvim_win_set_buf(0, buffer)
  end
  notify("Question source: " .. vim.fn.strtrans(context.file) .. ". Ctrl-S sends; :PiDraft appends for review.")
end

function M.busy()
  return pending
end

local function deliver(submit)
  if pending or require("pi.commands").busy() then
    notify("Wait for the pending draft or submission to complete", vim.log.levels.WARN)
    return
  end
  local content = text()
  if not context or content:match("^%s*$") then
    notify("Write a question with :PiPrompt first", vim.log.levels.WARN)
    return
  end
  local source_buffer = buffer
  local window = vim.fn.bufwinid(buffer)
  local origin = vim.fn.bufnr(context.file)
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  pending = true
  local send = require("pi").draft
  if submit then
    send = require("pi").send_question
  end
  send(content, context, function(ok, result)
    pending = false
    if not ok then
      notify(tostring(result) .. " Question kept locally.", vim.log.levels.ERROR)
      return
    end
    if not submit and (type(result) ~= "table" or result.appended ~= true) then
      notify("Invalid draft reply. Question kept locally; check Pi before retrying.", vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_buf_is_valid(source_buffer) and vim.api.nvim_buf_get_changedtick(source_buffer) == tick then
      vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "" })
      vim.bo[source_buffer].modified = false
      if submit then
        -- Close only the original composer window, never a window the user repurposed.
        if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_buf(window) == source_buffer then
          if vim.api.nvim_get_current_win() == window then
            vim.cmd.stopinsert()
          end
          local closed = pcall(vim.api.nvim_win_close, window, false)
          if not closed and vim.api.nvim_buf_is_loaded(origin) then
            -- Neovim cannot close its last window; show the existing source buffer instead.
            vim.api.nvim_win_set_buf(window, origin)
          end
        end
        notify("Question submitted to Pi")
      else
        notify("Appended to Pi draft. Review it in Pi, then :PiSubmit.")
      end
    else
      local action = submit and "Submitted" or "Appended"
      notify(action .. " snapshot to Pi; newer local edits kept. Review before sending again.", vim.log.levels.WARN)
    end
  end)
end

function M.append()
  deliver(false)
end

function M.send()
  deliver(true)
end

return M
