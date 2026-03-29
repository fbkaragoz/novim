-- lua/novim/adapters/neovim_editor.lua
local M = {}
M.__index = M

local ns_diff = vim.api.nvim_create_namespace("novim_diff")
local ns_badge = vim.api.nvim_create_namespace("novim_badge")

function M.new(config)
  local self = setmetatable({}, M)
  self.config = config
  self.badge_timer = nil
  return self
end

function M:get_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]
  local col = cursor[2]
  local file = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype or ""
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  local file_content
  local threshold = self.config.large_file_threshold or 500
  local context_lines = self.config.context_lines or 200

  if line_count <= threshold then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    file_content = table.concat(lines, "\n")
  else
    local win_start = math.max(0, row - 1 - context_lines)
    local win_end = math.min(line_count, row - 1 + context_lines + 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, win_start, win_end, false)
    file_content = string.format(
      "[Lines %d-%d of %d total]\n%s",
      win_start + 1, win_end, line_count,
      table.concat(lines, "\n")
    )
  end

  local selection = nil
  local mode = vim.fn.mode()
  if mode:find("[vV\22]") then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local s_row = math.min(start_pos[2], end_pos[2])
    local e_row = math.max(start_pos[2], end_pos[2])
    local sel_lines = vim.api.nvim_buf_get_lines(bufnr, s_row - 1, e_row, false)
    selection = table.concat(sel_lines, "\n")
  end

  local diagnostics = {}
  local raw_diags = vim.diagnostic.get(bufnr)
  for _, d in ipairs(raw_diags) do
    if math.abs(d.lnum + 1 - row) <= 5 then
      table.insert(diagnostics, {
        line = d.lnum + 1,
        message = d.message,
        severity = d.severity,
      })
    end
  end

  return {
    bufnr = bufnr,
    file = file ~= "" and file or "[No Name]",
    filetype = filetype,
    cursor_line = row,
    cursor_col = col,
    selection = selection,
    file_content = file_content,
    diagnostics = diagnostics,
  }
end

function M:get_buffer_lines(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M:read_file(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "File not found: " .. path
  end
  local lines = vim.fn.readfile(abs)
  local threshold = self.config.large_file_threshold or 500
  if #lines > threshold then
    local window = self.config.context_lines or 200
    local content = {}
    for i = 1, math.min(window, #lines) do
      table.insert(content, lines[i])
    end
    return string.format(
      "[First %d of %d lines]\n%s",
      math.min(window, #lines), #lines,
      table.concat(content, "\n")
    )
  end
  return table.concat(lines, "\n")
end

function M:find_symbol(name)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    return nil, "No language server attached to this buffer."
  end

  local results = {}
  local done = false

  vim.lsp.buf.workspace_symbol(name, function(err, symbols)
    if err or not symbols then
      done = true
      return
    end
    for i, sym in ipairs(symbols) do
      if i > 20 then break end
      local loc = sym.location or {}
      local uri = loc.uri or ""
      local range = loc.range or {}
      table.insert(results, {
        file = vim.uri_to_fname(uri),
        line = (range.start and range.start.line or 0) + 1,
        text = sym.name .. " (" .. (sym.kind or "?") .. ")",
      })
    end
    done = true
  end)

  vim.wait(5000, function() return done end, 50)

  if #results == 0 and not done then
    return nil, "Symbol lookup timed out."
  end
  return results
end

function M:search_project(pattern)
  local results = {}

  if vim.fn.executable("rg") == 1 then
    local cwd = vim.fn.getcwd()
    local handle = vim.system(
      { "rg", "--line-number", "--no-heading", "--max-count", "30", pattern, cwd },
      { text = true, timeout = 10000 }
    ):wait()
    if handle.code == 0 and handle.stdout then
      for line in handle.stdout:gmatch("[^\n]+") do
        local file, lnum, text = line:match("^(.+):(%d+):(.*)$")
        if file and lnum then
          table.insert(results, { file = file, line = tonumber(lnum), text = text })
          if #results >= 30 then break end
        end
      end
    end
    return results
  end

  local files = vim.fn.glob(vim.fn.getcwd() .. "/**/*", false, true)
  for _, file in ipairs(files) do
    if vim.fn.isdirectory(file) == 0 then
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok then
        for i, line in ipairs(lines) do
          if line:find(pattern, 1, true) then
            table.insert(results, { file = file, line = i, text = line })
            if #results >= 30 then return results end
          end
        end
      end
    end
  end
  return results
end

function M:apply_diff(hunks)
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local bufnr = vim.fn.bufnr(hunk.file)
    if bufnr == -1 then
      bufnr = vim.api.nvim_get_current_buf()
    end

    local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local diff_mod = require("novim.core.diff")
    local ok, err = diff_mod.validate_hunks({ hunk }, buffer_lines)
    if not ok then
      return false, err
    end

    local start = hunk.start_line - 1
    local finish = start + #hunk.old_lines
    vim.api.nvim_buf_set_lines(bufnr, start, finish, false, hunk.new_lines)
  end
  return true
end

function M:show_diff_preview(hunks)
  self:clear_diff_preview()
  for _, hunk in ipairs(hunks) do
    local bufnr = vim.fn.bufnr(hunk.file)
    if bufnr == -1 then
      bufnr = vim.api.nvim_get_current_buf()
    end

    for j = 0, #hunk.old_lines - 1 do
      local line = hunk.start_line - 1 + j
      if line < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, ns_diff, line, 0, {
          sign_text = self.config.diff_sign_remove or "-",
          sign_hl_group = "NovimDiffRemove",
          line_hl_group = "NovimDiffRemove",
        })
      end
    end

    local anchor = hunk.start_line - 1 + math.max(0, #hunk.old_lines - 1)
    local virt_lines = {}
    for _, new_line in ipairs(hunk.new_lines) do
      table.insert(virt_lines, {
        { (self.config.diff_sign_add or "+") .. " ", "NovimDiffAddSign" },
        { new_line, "NovimDiffAdd" },
      })
    end
    if #virt_lines > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_diff, anchor, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
    end
  end
end

function M:clear_diff_preview()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_diff, 0, -1)
    end
  end
end

function M:show_context_badge(bufnr, line)
  self:clear_context_badge()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_extmark(bufnr, ns_badge, line - 1, 0, {
      sign_text = ">>",
      sign_hl_group = "NovimContext",
    })
  end
end

function M:clear_context_badge()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_badge, 0, -1)
    end
  end
end

return M
