local M = {}
local draft = nil

local function text(state)
  return table.concat(vim.api.nvim_buf_get_lines(state.buffer, 0, -1, false), "\n")
end

local function visible(state)
  return state.window
    and vim.api.nvim_win_is_valid(state.window)
    and vim.api.nvim_win_get_buf(state.window) == state.buffer
end

local function close(state)
  if visible(state) then
    state.cursor = vim.api.nvim_win_get_cursor(state.window)
    if vim.api.nvim_get_current_win() == state.window then
      vim.cmd("stopinsert")
    end
    vim.api.nvim_win_close(state.window, true)
  end
end

local function confirm(state)
  if state.pending then
    return
  end
  local content = text(state)
  if vim.trim(content) == "" then
    return
  end

  -- Freeze the submitted text until acknowledgement; a late reply must never erase new edits.
  state.pending = true
  vim.bo[state.buffer].modifiable = false
  local done = vim.schedule_wrap(function(ok)
    if not state.pending then
      return
    end
    state.pending = false
    if not vim.api.nvim_buf_is_valid(state.buffer) then
      return
    end
    vim.bo[state.buffer].modifiable = true
    if ok then
      close(state)
      vim.api.nvim_buf_delete(state.buffer, { force = true })
      if draft == state then
        draft = nil
      end
    end
  end)

  local ok, error = pcall(state.on_confirm, content, state.context, done)
  if not ok then
    done(false)
    vim.notify(tostring(error), vim.log.levels.ERROR, { title = "Pi" })
  end
end

local function create(context, on_confirm)
  local state = {
    buffer = vim.api.nvim_create_buf(false, true),
    context = context,
    on_confirm = on_confirm,
    pending = false,
  }
  vim.bo[state.buffer].bufhidden = "hide"
  vim.bo[state.buffer].swapfile = false
  vim.bo[state.buffer].undofile = false
  vim.bo[state.buffer].filetype = "markdown"
  vim.b[state.buffer].completion = false

  -- Keep confirmation local to the composer, independent of global save mappings.
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    confirm(state)
  end, { buffer = state.buffer, desc = "Add Prompt to Pi Draft" })
  vim.keymap.set("n", "q", function()
    close(state)
  end, { buffer = state.buffer, desc = "Close Pi Prompt (Keep Text)" })
  -- Keep these editing keys independent of global completion/escape mappings.
  vim.keymap.set("i", "<CR>", "<CR>", { buffer = state.buffer })
  vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = state.buffer })
  return state
end

--- Open or resume one in-memory prompt, retaining its original source context and undo history.
--- on_confirm(content, context, done) must call done(true) only after Pi acknowledges the append.
--- Closing never sends or discards text. Empty closed drafts acquire fresh context on the next open.
function M.open(context, on_confirm)
  if draft and vim.api.nvim_buf_is_valid(draft.buffer) then
    if visible(draft) then
      vim.api.nvim_set_current_win(draft.window)
      if not draft.pending then
        vim.cmd("startinsert")
      end
      return
    end
    if not draft.pending and vim.trim(text(draft)) == "" then
      vim.api.nvim_buf_delete(draft.buffer, { force = true })
      draft = nil
    end
  else
    draft = nil
  end
  draft = draft or create(context, on_confirm)

  local title = " Pi prompt (text only) "
  if draft.context.selection then
    local selection = draft.context.selection
    local name = draft.context.file and vim.fn.fnamemodify(draft.context.file, ":t") or "[unnamed]"
    title = string.format(" Pi: %s:%d-%d ", name, selection.start.line, selection["end"].line)
  end
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(8, vim.o.lines - 4))
  local options = vim.lsp.util.make_floating_popup_options(width, height, {
    border = "rounded",
    focusable = true,
    title = title,
  })
  -- A one-line source split can leave the LSP helper with zero available rows.
  options.height = math.max(1, options.height)
  options.footer = " C-s: add to draft | q: close "
  options.footer_pos = "center"
  draft.window = vim.api.nvim_open_win(draft.buffer, true, options)
  vim.wo[draft.window].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"
  vim.wo[draft.window].wrap = true
  vim.wo[draft.window].linebreak = true
  vim.wo[draft.window].conceallevel = 0
  vim.wo[draft.window].spell = false
  if draft.cursor then
    vim.api.nvim_win_set_cursor(draft.window, draft.cursor)
  end
  if not draft.pending then
    vim.cmd("startinsert")
  end
end

return M
