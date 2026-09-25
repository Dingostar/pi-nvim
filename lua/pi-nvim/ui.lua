local M = {}

-- Stable namespace for the source-buffer selection highlight, so a highlight
-- leaked by an earlier dialog can always be found and cleared again.
local SELECTION_NS = vim.api.nvim_create_namespace("pi_nvim_selection")

--- Drop any selection highlight this plugin left behind, in every loaded buffer.
local function clear_all_selection_highlights()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, SELECTION_NS, 0, -1)
    end
  end
end

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:."),
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

local function selection_line_count(selection)
  return select(2, selection.text:gsub("\n", "")) + 1
end

--- @param show_keys boolean  Include the toggle key hints. Only the float can
---   toggle, so the split's winbar renders the same state without them.
local function make_context_lines(state, show_keys)
  local sel_line
  if state.selection then
    sel_line = string.format(
      " Selection: %d lines (%d-%d)",
      selection_line_count(state.selection),
      state.selection.start_line,
      state.selection.end_line
    )
  else
    sel_line = string.format(
      " Send buffer: %s%s",
      state.send_buffer and "[x]" or "[ ]",
      show_keys and " (<Tab>)" or ""
    )
  end

  return {
    " " .. state.file_info,
    sel_line,
    string.format(
      " LSP diag: %s%s",
      state.include_lsp and "[x]" or "[ ]",
      show_keys and " (<S-Tab>)" or ""
    ),
  }
end

--- Collect LSP diagnostics for the dialog's source buffer (scoped to the selection, if any).
--- @return string|nil
local function lsp_section(state)
  if not state.include_lsp then return nil end
  local pi = require("pi-nvim")
  if not pi.lsp_diagnostics then return nil end

  local opts = { buf = state.source_buf }
  if state.selection then
    opts.start = state.selection.start_line
    opts["end"] = state.selection.end_line
  end
  local diag = pi.lsp_diagnostics(opts)
  if diag and diag ~= "" then return diag end
  return nil
end

--- Build the parts that wrap the typed prompt, so the full message is always
--- `prefix .. prompt .. suffix`. Returns nil when there is nothing to send.
--- @return {prefix: string, suffix: string}|nil
local function build_frame(state, has_prompt)
  local prefix, suffix = "", ""

  if state.selection then
    local sel = state.selection
    local header = string.format("%s lines %d-%d", sel.file, sel.start_line, sel.end_line)
    if has_prompt then
      suffix = string.format("\n\nFrom %s:\n```%s\n%s\n```", header, sel.ft, sel.text)
    else
      prefix = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, sel.ft, sel.text)
    end
  elseif state.send_buffer and state.rel_file ~= "" then
    local content = table.concat(state.buf_lines, "\n")
    if has_prompt then
      suffix = string.format("\n\nFile: %s\n```%s\n%s\n```", state.rel_file, state.ft, content)
    else
      prefix = string.format("Look at this file %s:\n\n```%s\n%s\n```", state.rel_file, state.ft, content)
    end
  elseif state.file ~= "" then
    if has_prompt then
      prefix = string.format("File: %s\n\n", state.file)
    else
      prefix = string.format("Look at this file: %s", state.file)
    end
  elseif not has_prompt then
    return nil
  end

  local diag = lsp_section(state)
  if diag then
    suffix = suffix .. "\n\n" .. diag
  end

  return { prefix = prefix, suffix = suffix }
end

--- @return string|nil message, {prefix: string, suffix: string}|nil frame
local function build_message(state, prompt_text)
  local frame = build_frame(state, prompt_text ~= "")
  if not frame then return nil, nil end
  return frame.prefix .. prompt_text .. frame.suffix, frame
end

local function create_prompt_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pi-nvim-prompt"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  return buf
end

--- Open the Pi send dialog as a floating prompt.
--- <C-e> expands it into a split containing the complete message that will be
--- sent to pi — prompt, selection/buffer code block and LSP diagnostics — which
--- is then sent verbatim, exactly as shown.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local pi = require("pi-nvim")

  local state = {
    selection = opts.selection,
    file = vim.fn.expand("%:p"),
    rel_file = vim.fn.expand("%:."),
    ft = vim.bo.filetype,
    send_buffer = false,
    include_lsp = pi.config.include_lsp or false,
    source_buf = vim.api.nvim_get_current_buf(),
    closed = false,
    mode = "float",
  }
  state.buf_lines = vim.api.nvim_buf_get_lines(state.source_buf, 0, -1, false)
  state.file_info = "File: " .. (state.rel_file ~= "" and state.rel_file or "(no file)")

  local function update_context()
    if state.info_buf and vim.api.nvim_buf_is_valid(state.info_buf) then
      vim.bo[state.info_buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.info_buf, 0, -1, false, make_context_lines(state, true))
      vim.bo[state.info_buf].modifiable = false
    end

    if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
      local ctx = make_context_lines(state, false)
      vim.wo[state.split_win].winbar = table.concat(ctx, " ") .. " | <C-s> send as shown"
    end
  end

  local function clear_selection_highlight()
    if state.highlighted and vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.api.nvim_buf_clear_namespace(state.source_buf, SELECTION_NS, 0, -1)
      state.highlighted = false
    end
  end

  local function close_float()
    pcall(vim.api.nvim_win_close, state.input_win, true)
    pcall(vim.api.nvim_win_close, state.info_win, true)
    pcall(vim.api.nvim_buf_delete, state.input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, state.info_buf, { force = true })
    state.input_win = nil
    state.info_win = nil
    state.input_buf = nil
    state.info_buf = nil
  end

  local function close_split()
    if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
      pcall(vim.api.nvim_win_close, state.split_win, true)
    elseif state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
      pcall(vim.api.nvim_buf_delete, state.input_buf, { force = true })
    end
    state.split_win = nil
    state.input_buf = nil
  end

  local function close_all()
    if state.closed then return end
    state.closed = true
    pcall(vim.cmd, "noautocmd stopinsert")
    clear_selection_highlight()
    close_float()
    close_split()
  end

  local function get_prompt_text()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
      return ""
    end
    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    return vim.fn.trim(table.concat(lines, "\n"))
  end

  -- This dialog already embeds diagnostics itself, so suppress pi.prompt()'s
  -- auto-injection to avoid sending them twice.
  local function deliver(message)
    local saved = pi.config.include_lsp
    pi.config.include_lsp = false
    pi.prompt(message)
    pi.config.include_lsp = saved
  end

  local function send()
    local message
    if state.expanded then
      -- The expanded buffer *is* the message: send it exactly as shown.
      message = get_prompt_text()
    else
      message = build_message(state, get_prompt_text())
    end

    if not message or message == "" then
      close_all()
      vim.notify("Nothing to send", vim.log.levels.WARN)
      return
    end

    close_all()
    deliver(message)
  end

  --- Put the cursor at the end of the prompt portion of the expanded buffer.
  local function place_cursor(win, head)
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    local head_lines = vim.split(head, "\n", { plain = true })
    local lnum = #head_lines
    vim.api.nvim_win_set_cursor(win, { lnum, #head_lines[lnum] })
  end

  --- Redraw the expanded buffer after a context toggle, keeping whatever the
  --- user typed. Returns false if the generated context was hand-edited, in
  --- which case the buffer is left untouched.
  local function rerender_expanded()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then return false end

    local text = table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n")
    local old = state.frame or { prefix = "", suffix = "" }
    if not (vim.startswith(text, old.prefix) and vim.endswith(text, old.suffix)) then
      return false
    end
    if #text < #old.prefix + #old.suffix then
      return false
    end

    local prompt_text = text:sub(#old.prefix + 1, #text - #old.suffix)
    local frame = build_frame(state, true)
    state.frame = frame

    local head = frame.prefix .. prompt_text
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false,
      vim.split(head .. frame.suffix, "\n", { plain = true }))
    place_cursor(state.split_win, head)
    return true
  end

  local function refresh_after_toggle(what, enabled)
    update_context()
    local edited = state.expanded and not rerender_expanded()
    vim.notify(
      string.format("Pi %s: %s", what, enabled and "on" or "off")
        .. (edited and " (message was edited by hand — sending as shown)" or ""),
      edited and vim.log.levels.WARN or vim.log.levels.INFO
    )
  end

  local function toggle_buffer()
    if not state.selection then
      state.send_buffer = not state.send_buffer
      refresh_after_toggle("send buffer", state.send_buffer)
    end
  end

  local function toggle_lsp()
    state.include_lsp = not state.include_lsp
    pi.config.include_lsp = state.include_lsp
    refresh_after_toggle("LSP diagnostics", state.include_lsp)
  end

  local function attach_prompt_keymaps(buf, opts2)
    opts2 = opts2 or {}
    local kopts = { buffer = buf, noremap = true, silent = true }

    vim.keymap.set({ "i", "n" }, "<C-s>", send, kopts)

    if opts2.float then
      vim.keymap.set("i", "<CR>", send, kopts)
      vim.keymap.set({ "i", "n" }, "<Esc>", close_all, kopts)
      vim.keymap.set({ "i", "n" }, "<C-c>", close_all, kopts)
      -- The context toggles exist only in the float. Once <C-e> expands the
      -- dialog the split buffer *is* the message and is sent verbatim, so a
      -- toggle there would have to re-derive text the user may have edited.
      vim.keymap.set({ "i", "n" }, "<Tab>", toggle_buffer, kopts)
      vim.keymap.set({ "i", "n" }, "<S-Tab>", toggle_lsp, kopts)
    end
  end

  local function open_split(initial_lines, cursor_head)
    state.mode = "split"
    close_float()

    -- The split shows the selected code verbatim, so the source-buffer
    -- highlight is redundant here — and the split is a window you can navigate
    -- away from while the dialog stays open, which would leave it stranded.
    clear_selection_highlight()

    vim.cmd("botright 15split")
    state.split_win = vim.api.nvim_get_current_win()
    state.input_buf = create_prompt_buf(initial_lines)
    vim.api.nvim_win_set_buf(state.split_win, state.input_buf)
    vim.wo[state.split_win].wrap = true
    vim.wo[state.split_win].number = false
    vim.wo[state.split_win].relativenumber = false
    vim.wo[state.split_win].signcolumn = "no"
    vim.wo[state.split_win].foldcolumn = "0"

    attach_prompt_keymaps(state.input_buf)

    -- The split can be dismissed without ever going through send()/close_all()
    -- (:q, <C-w>c, or navigating away — the buffer is bufhidden=wipe), so tear
    -- the dialog down here too. Otherwise the selection highlight is orphaned
    -- in the source buffer. close_all() is re-entrant via state.closed.
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
      buffer = state.input_buf,
      once = true,
      callback = function()
        vim.schedule(close_all)
      end,
    })

    update_context()
    if cursor_head then
      place_cursor(state.split_win, cursor_head)
    end
    vim.cmd("noautocmd startinsert!")
  end

  -- Highlight the visual selection in the source buffer while the dialog is open.
  -- Sweep first: if an earlier dialog leaked a highlight, drop it now.
  clear_all_selection_highlights()
  if state.selection and vim.api.nvim_buf_is_valid(state.source_buf) then
    state.highlighted = true
    for lnum = state.selection.start_line, state.selection.end_line do
      vim.api.nvim_buf_add_highlight(state.source_buf, SELECTION_NS, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Floating-window layout.
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = 3
  local max_input_height = 6
  local top_row = math.floor((vim.o.lines - (info_height + 2 + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_hl.fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_hl.fg, bg = normal_hl.bg })

  state.info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.info_buf].buftype = "nofile"
  vim.bo[state.info_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(state.info_buf, 0, -1, false, make_context_lines(state, true))
  vim.bo[state.info_buf].modifiable = false

  state.info_win = vim.api.nvim_open_win(state.info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi  (<C-e> edit full message) ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[state.info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[state.info_win].cursorline = false

  state.input_buf = create_prompt_buf({ "" })
  state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = top_row + info_height + 2,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[state.input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[state.input_win].wrap = true

  local function resize_input()
    if not state.input_win or not vim.api.nvim_win_is_valid(state.input_win) then return end
    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      visual_rows = visual_rows + math.max(1, math.ceil((#line == 0 and 1 or #line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(state.input_win, new_height)
    local cursor_line = vim.api.nvim_win_get_cursor(state.input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(state.input_win, function()
      vim.fn.winrestview({ topline = top_line })
    end)
  end

  attach_prompt_keymaps(state.input_buf, { float = true })

  -- <C-e>: expand into a split holding the *entire* message that will be sent —
  -- the prompt plus the selection/buffer code block and the LSP diagnostics.
  vim.keymap.set({ "i", "n" }, "<C-e>", function()
    local prompt_text = get_prompt_text()
    -- Always use the "has prompt" framing so the prompt stays at the top,
    -- editable, with the context below it.
    local frame = build_frame(state, true)
    state.frame = frame
    state.expanded = true

    local head = frame.prefix .. prompt_text
    open_split(vim.split(head .. frame.suffix, "\n", { plain = true }), head)
  end, { buffer = state.input_buf, noremap = true, silent = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = state.input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = state.input_buf,
    once = true,
    callback = function()
      if state.mode == "float" then
        vim.schedule(close_all)
      end
    end,
  })

  vim.cmd("noautocmd startinsert!")
end

return M
