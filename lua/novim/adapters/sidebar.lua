-- lua/novim/adapters/sidebar.lua
local M = {}
M.__index = M

local ns_conv = vim.api.nvim_create_namespace("novim_conv")
local ns_input = vim.api.nvim_create_namespace("novim_input")

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.new(config, callbacks)
  local self = setmetatable({}, M)
  self.config = config
  self.callbacks = callbacks
  self.conv_buf = nil
  self.conv_win = nil
  self.input_buf = nil
  self.input_win = nil
  self.state = "idle"
  self.spinner_timer = nil
  self.spinner_frame = 0
  self.auto_scroll = true
  self.autocmd_ids = {}
  return self
end

function M:open()
  if self:is_open() then
    self:focus_input()
    return
  end

  local pos = self.config.sidebar_position or "right"
  local cmd = pos == "left" and "topleft vsplit" or "botright vsplit"
  vim.cmd("noautocmd " .. cmd)

  self.conv_win = vim.api.nvim_get_current_win()

  local total = vim.o.columns
  local ratio = self.config.sidebar_width or 0.35
  local min_w = self.config.sidebar_min_width or 40
  local max_w = self.config.sidebar_max_width or 80
  local width = math.floor(total * ratio)
  width = math.max(min_w, math.min(max_w, width))
  vim.api.nvim_win_set_width(self.conv_win, width)

  self.conv_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(self.conv_win, self.conv_buf)
  vim.bo[self.conv_buf].buftype = "nofile"
  vim.bo[self.conv_buf].buflisted = false
  vim.bo[self.conv_buf].swapfile = false
  vim.bo[self.conv_buf].bufhidden = "wipe"
  vim.bo[self.conv_buf].filetype = "novim"
  vim.bo[self.conv_buf].modifiable = false

  vim.wo[self.conv_win].wrap = true
  vim.wo[self.conv_win].linebreak = true
  vim.wo[self.conv_win].number = false
  vim.wo[self.conv_win].relativenumber = false
  vim.wo[self.conv_win].signcolumn = "no"
  vim.wo[self.conv_win].winfixwidth = true
  vim.wo[self.conv_win].cursorline = false
  vim.wo[self.conv_win].list = false

  self:_update_winbar()

  self.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.input_buf].buftype = "nofile"
  vim.bo[self.input_buf].buflisted = false
  vim.bo[self.input_buf].swapfile = false
  vim.bo[self.input_buf].bufhidden = "wipe"
  vim.bo[self.input_buf].filetype = "novim-input"

  self:_create_input_float()
  self:_set_input_prefix()
  self:_setup_keybinds()
  self:_setup_autocmds()

  self:focus_input()
  vim.cmd("startinsert")
end

function M:close()
  self:_stop_spinner()

  for _, id in ipairs(self.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  self.autocmd_ids = {}

  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    pcall(vim.api.nvim_win_close, self.input_win, true)
  end
  if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
    pcall(vim.api.nvim_buf_delete, self.input_buf, { force = true })
  end

  if self.conv_win and vim.api.nvim_win_is_valid(self.conv_win) then
    pcall(vim.api.nvim_win_close, self.conv_win, true)
  end
  if self.conv_buf and vim.api.nvim_buf_is_valid(self.conv_buf) then
    pcall(vim.api.nvim_buf_delete, self.conv_buf, { force = true })
  end

  self.conv_buf = nil
  self.conv_win = nil
  self.input_buf = nil
  self.input_win = nil
  self.state = "idle"
end

function M:is_open()
  return self.conv_win ~= nil and vim.api.nvim_win_is_valid(self.conv_win)
end

function M:set_state(new_state)
  self.state = new_state
  if new_state == "thinking" then
    self:_start_spinner()
  else
    self:_stop_spinner()
  end
  self:_update_winbar()
end

function M:add_message(role, text)
  if not self.conv_buf or not vim.api.nvim_buf_is_valid(self.conv_buf) then
    return
  end

  local hl_group = ({
    user = "NovimUser",
    ai = "NovimAI",
    system = "NovimSystem",
  })[role] or "NovimSystem"

  local label = ({
    user = "You",
    ai = "Novim",
    system = "",
  })[role] or ""

  vim.bo[self.conv_buf].modifiable = true

  local line_count = vim.api.nvim_buf_line_count(self.conv_buf)
  local lines = {}

  local existing = vim.api.nvim_buf_get_lines(self.conv_buf, 0, 1, false)
  if existing[1] and existing[1] ~= "" then
    table.insert(lines, "")
  end

  if label ~= "" then
    table.insert(lines, label)
  end

  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  local start_line = line_count
  if existing[1] == "" and line_count == 1 then
    vim.api.nvim_buf_set_lines(self.conv_buf, 0, 1, false, lines)
    start_line = 0
  else
    vim.api.nvim_buf_set_lines(self.conv_buf, line_count, line_count, false, lines)
  end

  local new_count = vim.api.nvim_buf_line_count(self.conv_buf)
  for i = start_line, new_count - 1 do
    vim.api.nvim_buf_set_extmark(self.conv_buf, ns_conv, i, 0, {
      line_hl_group = hl_group,
      end_row = i + 1,
    })
  end

  vim.bo[self.conv_buf].modifiable = false

  if self.auto_scroll and self.conv_win and vim.api.nvim_win_is_valid(self.conv_win) then
    vim.api.nvim_win_set_cursor(self.conv_win, { new_count, 0 })
  end
end

function M:focus_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_set_current_win(self.input_win)
  end
end

function M:_create_input_float()
  if not self.conv_win or not vim.api.nvim_win_is_valid(self.conv_win) then
    return
  end

  local win_height = vim.api.nvim_win_get_height(self.conv_win)
  local win_width = vim.api.nvim_win_get_width(self.conv_win)

  self.input_win = vim.api.nvim_open_win(self.input_buf, false, {
    relative = "win",
    win = self.conv_win,
    row = win_height - 1,
    col = 0,
    width = win_width,
    height = 1,
    style = "minimal",
    border = { "─", "─", "─", "", "", "", "", "" },
    focusable = true,
  })

  vim.wo[self.input_win].wrap = true
  vim.wo[self.input_win].linebreak = true
  vim.wo[self.input_win].cursorline = false
end

function M:_set_input_prefix()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.input_buf, ns_input, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  if #lines == 0 then
    vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
  end

  vim.api.nvim_buf_set_extmark(self.input_buf, ns_input, 0, 0, {
    virt_text = { { "> ", "NovimInputPrefix" } },
    virt_text_pos = "inline",
  })
end

function M:_get_input_text()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return vim.trim(text)
end

function M:_clear_input()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
  self:_set_input_prefix()

  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_win_set_height(self.input_win, 1)
    self:_reposition_input_float()
  end
end

function M:_reposition_input_float()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  if not self.conv_win or not vim.api.nvim_win_is_valid(self.conv_win) then
    return
  end

  local win_height = vim.api.nvim_win_get_height(self.conv_win)
  local win_width = vim.api.nvim_win_get_width(self.conv_win)
  local input_height = vim.api.nvim_win_get_height(self.input_win)

  vim.api.nvim_win_set_config(self.input_win, {
    relative = "win",
    win = self.conv_win,
    row = win_height - input_height,
    col = 0,
    width = win_width,
    height = input_height,
  })
end

function M:_update_winbar()
  if not self.conv_win or not vim.api.nvim_win_is_valid(self.conv_win) then
    return
  end

  local state_text = ({
    idle = "ASK",
    thinking = self.spinner_frame > 0
      and spinner_frames[((self.spinner_frame - 1) % #spinner_frames) + 1]
      or "...",
    diff_pending = "DIFF",
  })[self.state] or "ASK"

  vim.wo[self.conv_win].winbar = "%#NovimWinbarTitle# novim%=%#NovimWinbarState# " .. state_text .. " "
end

function M:_start_spinner()
  self:_stop_spinner()
  self.spinner_frame = 1
  self.spinner_timer = vim.uv.new_timer()
  self.spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if not self:is_open() then
      self:_stop_spinner()
      return
    end
    self.spinner_frame = self.spinner_frame + 1
    self:_update_winbar()
  end))
end

function M:_stop_spinner()
  if self.spinner_timer then
    if not self.spinner_timer:is_closing() then
      pcall(function()
        self.spinner_timer:stop()
        self.spinner_timer:close()
      end)
    end
    self.spinner_timer = nil
  end
  self.spinner_frame = 0
end

function M:_setup_keybinds()
  local buf = self.input_buf
  if not buf then return end

  local opts = { buffer = buf, noremap = true, nowait = true, silent = true }

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    self:_handle_cr()
  end, opts)

  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    self:_handle_esc()
  end, opts)
end

function M:_handle_cr()
  local text = self:_get_input_text()
  if text ~= "" then
    self:_clear_input()
    self.callbacks.on_submit(text)
  elseif self.state == "diff_pending" then
    self.callbacks.on_accept()
  end
end

function M:_handle_esc()
  if self.state == "thinking" then
    self.callbacks.on_cancel()
  elseif self.state == "diff_pending" then
    self.callbacks.on_dismiss()
  else
    self.callbacks.on_close()
  end
end

function M:_setup_autocmds()
  if self.conv_buf then
    local id = vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = self.conv_buf,
      once = true,
      callback = function()
        self.callbacks.on_close()
      end,
    })
    table.insert(self.autocmd_ids, id)
  end

  if self.conv_win then
    local id = vim.api.nvim_create_autocmd("WinScrolled", {
      callback = function()
        if not self:is_open() then return end
        local cur_win = vim.api.nvim_get_current_win()
        if cur_win == self.conv_win then
          local cursor_line = vim.api.nvim_win_get_cursor(self.conv_win)[1]
          local total = vim.api.nvim_buf_line_count(self.conv_buf)
          self.auto_scroll = (cursor_line >= total - 2)
        end
      end,
    })
    table.insert(self.autocmd_ids, id)
  end

  if self.input_buf then
    local id = vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
      buffer = self.input_buf,
      callback = function()
        self.auto_scroll = true
      end,
    })
    table.insert(self.autocmd_ids, id)
  end

  local id = vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      if self:is_open() then
        self:_reposition_input_float()
      end
    end,
  })
  table.insert(self.autocmd_ids, id)

  if self.input_buf then
    local grow_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = self.input_buf,
      callback = function()
        if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
          return
        end
        local lines = vim.api.nvim_buf_line_count(self.input_buf)
        local height = math.min(math.max(1, lines), 5)
        vim.api.nvim_win_set_height(self.input_win, height)
        self:_reposition_input_float()
      end,
    })
    table.insert(self.autocmd_ids, grow_id)
  end
end

return M
