-- lua/novim/init.lua
local M = {}

local conversation_mod = require("novim.core.conversation")
local intent_mod = require("novim.core.intent")
local diff_mod = require("novim.core.diff")

local defaults = {
  codex_cmd = { "codex", "exec" },
  timeout_ms = 90000,
  max_tool_rounds = 5,
  sidebar_width = 0.35,
  sidebar_min_width = 40,
  sidebar_max_width = 80,
  sidebar_position = "right",
  context_lines = 200,
  large_file_threshold = 500,
  diff_sign_add = "+",
  diff_sign_remove = "-",
  toggle_key = "<A-x>",
}

local state = {
  config = nil,
  editor = nil,
  ai = nil,
  sidebar = nil,
  conversation = nil,
  cancel_fn = nil,
  pending_diff = nil,
}

local function validate_config(opts)
  local config = vim.tbl_deep_extend("force", {}, defaults, opts or {})

  if type(config.codex_cmd) ~= "table" then
    vim.notify("novim: codex_cmd must be a table, using default", vim.log.levels.WARN)
    config.codex_cmd = defaults.codex_cmd
  end
  if config.sidebar_position ~= "right" and config.sidebar_position ~= "left" then
    vim.notify("novim: sidebar_position must be 'right' or 'left', using default", vim.log.levels.WARN)
    config.sidebar_position = defaults.sidebar_position
  end

  local numerics = {
    "timeout_ms", "max_tool_rounds", "sidebar_width",
    "sidebar_min_width", "sidebar_max_width",
    "context_lines", "large_file_threshold",
  }
  for _, key in ipairs(numerics) do
    if type(config[key]) ~= "number" or config[key] <= 0 then
      vim.notify("novim: " .. key .. " must be a positive number, using default", vim.log.levels.WARN)
      config[key] = defaults[key]
    end
  end

  return config
end

function M.setup(opts)
  state.config = validate_config(opts)

  local neovim_editor = require("novim.adapters.neovim_editor")
  state.editor = neovim_editor.new(state.config)

  if state.config.toggle_key then
    vim.keymap.set({ "n", "v", "i" }, state.config.toggle_key, function()
      M.toggle()
    end, { noremap = true, silent = true, desc = "Novim: toggle sidebar" })
  end
end

function M.toggle()
  if state.sidebar and state.sidebar:is_open() then
    M._close()
  else
    M._open()
  end
end

function M._open()
  state.conversation = conversation_mod.new()
  state.pending_diff = nil
  state.cancel_fn = nil

  local codex = require("novim.adapters.codex")
  state.ai = codex.new(state.config, state.editor)

  local sidebar_mod = require("novim.adapters.sidebar")
  state.sidebar = sidebar_mod.new(state.config, {
    on_submit = function(text) M._on_submit(text) end,
    on_accept = function() M._on_accept() end,
    on_dismiss = function() M._on_dismiss() end,
    on_cancel = function() M._on_cancel() end,
    on_close = function() M._close() end,
  })
  state.sidebar:open()

  M._start_badge_tracking()
end

function M._close()
  M._stop_badge_tracking()

  if state.cancel_fn then
    state.cancel_fn()
    state.cancel_fn = nil
  end
  if state.editor then
    state.editor:clear_diff_preview()
    state.editor:clear_context_badge()
  end
  if state.sidebar then
    state.sidebar:close()
    state.sidebar = nil
  end
  state.conversation = nil
  state.pending_diff = nil
  state.ai = nil
end

function M._on_submit(text)
  if not state.conversation or not state.sidebar then return end

  -- Check codex availability on first send (sidebar stays open for user to read error)
  local cmd = state.config.codex_cmd[1]
  if vim.fn.executable(cmd) ~= 1 then
    state.sidebar:add_message("system", cmd .. " not found — install it and make sure it's in PATH")
    return
  end

  local context = state.editor:get_context()
  state.conversation:add("user", text, context)
  state.sidebar:add_message("user", text)
  state.sidebar:set_state("thinking")

  if state.pending_diff then
    state.editor:clear_diff_preview()
    state.pending_diff = nil
  end

  local history = state.conversation:get_history()
  state.cancel_fn = state.ai:send(history, context, {
    on_chunk = function(_chunk)
    end,
    on_status = function(status_text)
      if state.sidebar and state.sidebar:is_open() then
        state.sidebar:add_message("system", status_text)
      end
    end,
    on_done = function(response)
      state.cancel_fn = nil
      if not state.sidebar or not state.sidebar:is_open() then return end

      local buffer_lines = state.editor:get_buffer_lines(context.bufnr)
      local result = diff_mod.parse(response.text, context.file, buffer_lines)

      state.conversation:add("ai", result.explanation)
      state.sidebar:add_message("ai", result.explanation)

      if result.type == "change" and #result.changes > 0 then
        state.pending_diff = { hunks = result.changes, bufnr = context.bufnr }
        state.editor:show_diff_preview(result.changes)
        state.sidebar:set_state("diff_pending")
        state.sidebar:add_message("system", "~ changes ready")
      else
        state.sidebar:set_state("idle")
      end
    end,
    on_error = function(err)
      state.cancel_fn = nil
      if not state.sidebar or not state.sidebar:is_open() then return end

      if err == "cancelled" then
        state.sidebar:add_message("system", "Cancelled")
      else
        state.sidebar:add_message("system", err)
      end
      state.sidebar:set_state("idle")
    end,
  })
end

function M._on_accept()
  if not state.pending_diff then return end

  local hunks = state.pending_diff.hunks
  state.editor:clear_diff_preview()

  local ok, err = state.editor:apply_diff(hunks)
  if ok then
    state.sidebar:add_message("system", "Changes applied")
  else
    state.sidebar:add_message("system", err or "Failed to apply changes")
  end

  state.pending_diff = nil
  state.sidebar:set_state("idle")
end

function M._on_dismiss()
  if state.pending_diff then
    state.editor:clear_diff_preview()
    state.pending_diff = nil
  end
  state.sidebar:set_state("idle")
end

function M._on_cancel()
  if state.cancel_fn then
    state.cancel_fn()
    state.cancel_fn = nil
  end
end

function M._show_error(msg)
  if state.sidebar and state.sidebar:is_open() then
    state.sidebar:add_message("system", msg)
  else
    vim.notify("novim: " .. msg, vim.log.levels.ERROR)
  end
end

local badge_autocmd_id = nil
local badge_timer = nil

function M._start_badge_tracking()
  M._stop_badge_tracking()
  badge_autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      if not state.sidebar or not state.sidebar:is_open() then return end
      local cur_buf = vim.api.nvim_get_current_buf()
      if state.sidebar and (cur_buf == state.sidebar.conv_buf or cur_buf == state.sidebar.input_buf) then
        return
      end

      if badge_timer then
        pcall(function() badge_timer:stop() end)
      end
      badge_timer = vim.defer_fn(function()
        if not state.editor then return end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        state.editor:show_context_badge(cur_buf, line)
      end, 150)
    end,
  })
end

function M._stop_badge_tracking()
  if badge_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, badge_autocmd_id)
    badge_autocmd_id = nil
  end
  if badge_timer then
    pcall(function() badge_timer:stop() end)
    badge_timer = nil
  end
end

return M
