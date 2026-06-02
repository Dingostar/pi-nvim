local M = {}

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

local function make_context_lines(state)
  local sel_line
  if state.selection then
    sel_line = string.format(
      " Selection: %d lines (%d-%d)",
      selection_line_count(state.selection),
      state.selection.start_line,
      state.selection.end_line
    )
  else
    sel_line = string.format(" Send buffer: %s", state.send_buffer and "[x]" or "[ ]")
  end

  return {
    " " .. state.file_info,
    sel_line,
    string.format(" LSP diag: %s", state.include_lsp and "[x]" or "[ ]"),
  }
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

--- Open the Pi send dialog as a floating prompt, with <C-e> to expand into a split.
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
      vim.api.nvim_buf_set_lines(state.info_buf, 0, -1, false, make_context_lines(state))
      vim.bo[state.info_buf].modifiable = false
    end

    if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
      local ctx = make_context_lines(state)
      local hint = state.selection
          and " | <C-s> send | <leader>pl LSP"
          or " | <C-s> send | <leader>pb buffer | <leader>pl LSP"
      vim.wo[state.split_win].winbar = table.concat(ctx, " ") .. hint
    end
  end

  local function clear_selection_highlight()
    if state.sel_ns and vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.api.nvim_buf_clear_namespace(state.source_buf, state.sel_ns, 0, -1)
      state.sel_ns = nil
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

  local function send()
    local prompt_text = get_prompt_text()
    close_all()

    local message
    if state.selection then
      local header = string.format("%s lines %d-%d", state.selection.file, state.selection.start_line, state.selection.end_line)
      if prompt_text == "" then
        message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, state.selection.ft, state.selection.text)
      else
        message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", prompt_text, header, state.selection.ft, state.selection.text)
      end
    elseif state.send_buffer and state.rel_file ~= "" then
      local content = table.concat(state.buf_lines, "\n")
      if prompt_text == "" then
        message = string.format("Look at this file %s:\n\n```%s\n%s\n```", state.rel_file, state.ft, content)
      else
        message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", prompt_text, state.rel_file, state.ft, content)
      end
    elseif state.file ~= "" then
      if prompt_text == "" then
        message = string.format("Look at this file: %s", state.file)
      else
        message = string.format("File: %s\n\n%s", state.file, prompt_text)
      end
    else
      if prompt_text == "" then
        vim.notify("Nothing to send", vim.log.levels.WARN)
        return
      end
      message = prompt_text
    end

    if state.include_lsp then
      local lsp_opts = { buf = state.source_buf }
      if state.selection then
        lsp_opts.start = state.selection.start_line
        lsp_opts["end"] = state.selection.end_line
      end
      local diag = pi.lsp_diagnostics and pi.lsp_diagnostics(lsp_opts)
      if diag and diag ~= "" then
        message = message .. "\n\n" .. diag
      end
      local saved = pi.config.include_lsp
      pi.config.include_lsp = false
      pi.prompt(message)
      pi.config.include_lsp = saved
      return
    end

    pi.prompt(message)
  end

  local function toggle_buffer()
    if not state.selection then
      state.send_buffer = not state.send_buffer
      update_context()
      vim.notify("Pi send buffer: " .. (state.send_buffer and "on" or "off"), vim.log.levels.INFO)
    end
  end

  local function toggle_lsp()
    state.include_lsp = not state.include_lsp
    pi.config.include_lsp = state.include_lsp
    update_context()
    vim.notify("Pi LSP diagnostics: " .. (state.include_lsp and "on" or "off"), vim.log.levels.INFO)
  end

  local function attach_prompt_keymaps(buf, opts2)
    opts2 = opts2 or {}
    local kopts = { buffer = buf, noremap = true, silent = true }

    vim.keymap.set({ "i", "n" }, "<C-s>", send, kopts)
    vim.keymap.set({ "i", "n" }, "<leader>pb", toggle_buffer, kopts)
    vim.keymap.set({ "i", "n" }, "<leader>pl", toggle_lsp, kopts)

    if opts2.float then
      vim.keymap.set("i", "<CR>", send, kopts)
      vim.keymap.set({ "i", "n" }, "<Esc>", close_all, kopts)
      vim.keymap.set({ "i", "n" }, "<C-c>", close_all, kopts)
      vim.keymap.set({ "i", "n" }, "<Tab>", toggle_buffer, kopts)
      vim.keymap.set({ "i", "n" }, "<S-Tab>", toggle_lsp, kopts)
    end
  end

  local function open_split(initial_lines)
    state.mode = "split"
    close_float()

    vim.cmd("botright 10split")
    state.split_win = vim.api.nvim_get_current_win()
    state.input_buf = create_prompt_buf(initial_lines)
    vim.api.nvim_win_set_buf(state.split_win, state.input_buf)
    vim.wo[state.split_win].wrap = true
    vim.wo[state.split_win].number = false
    vim.wo[state.split_win].relativenumber = false
    vim.wo[state.split_win].signcolumn = "no"
    vim.wo[state.split_win].foldcolumn = "0"

    attach_prompt_keymaps(state.input_buf)
    update_context()
    vim.cmd("noautocmd startinsert!")
  end

  -- Highlight the visual selection in the source buffer while the dialog is open.
  if state.selection and vim.api.nvim_buf_is_valid(state.source_buf) then
    state.sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = state.selection.start_line, state.selection.end_line do
      vim.api.nvim_buf_add_highlight(state.source_buf, state.sel_ns, "Visual", lnum - 1, 0, -1)
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
  vim.api.nvim_buf_set_lines(state.info_buf, 0, -1, false, make_context_lines(state))
  vim.bo[state.info_buf].modifiable = false

  state.info_win = vim.api.nvim_open_win(state.info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi  (<C-e> expand) ",
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

  vim.keymap.set({ "i", "n" }, "<C-e>", function()
    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    open_split(lines)
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
