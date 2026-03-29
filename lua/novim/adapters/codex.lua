-- lua/novim/adapters/codex.lua
local M = {}
M.__index = M

function M.new(config, editor)
  local self = setmetatable({}, M)
  self.config = config
  self.editor = editor
  self.handle = nil
  return self
end

function M:send(history, context, callbacks)
  local conversation = require("novim.core.conversation")
  local intent_mod = require("novim.core.intent")

  local conv = conversation.new()
  for _, msg in ipairs(history) do
    conv:add(msg.role, msg.text, msg.context)
  end

  local last_user_msg = ""
  for i = #history, 1, -1 do
    if history[i].role == "user" then
      last_user_msg = history[i].text
      break
    end
  end
  local intent = intent_mod.classify(last_user_msg)
  local prompt = conv:build_prompt(context, intent)

  local round = 0
  local max_rounds = self.config.max_tool_rounds or 5
  local tool_context = {}
  local cancelled = false

  local function cancel()
    cancelled = true
    if self.handle then
      pcall(function() self.handle:kill("sigterm") end)
      self.handle = nil
    end
    callbacks.on_error("cancelled")
  end

  local function serialize_prompt(p, extra_context)
    local parts = { p.system }
    if p.context ~= "" then
      table.insert(parts, "\n--- Current Context ---\n" .. p.context)
    end
    if #extra_context > 0 then
      table.insert(parts, "\n--- Tool Results ---")
      for _, tc in ipairs(extra_context) do
        table.insert(parts, tc)
      end
    end
    if p.history ~= "" then
      table.insert(parts, "\n--- Conversation ---\n" .. p.history)
    end
    return table.concat(parts, "\n")
  end

  local function parse_tool_requests(text)
    local requests = {}
    local visible_parts = {}
    local i = 1
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      table.insert(lines, line)
    end

    while i <= #lines do
      if lines[i]:match("^%[TOOL_REQUEST%]") then
        local req = {}
        i = i + 1
        while i <= #lines and not lines[i]:match("^%[/TOOL_REQUEST%]") do
          local key, val = lines[i]:match("^(%w+):%s*(.+)$")
          if key and val then
            req[key] = val
          end
          i = i + 1
        end
        if req.action then
          table.insert(requests, req)
        end
        i = i + 1
      else
        table.insert(visible_parts, lines[i])
        i = i + 1
      end
    end

    local visible = table.concat(visible_parts, "\n")
    visible = visible:match("^%s*(.-)%s*$") or ""
    return requests, visible
  end

  local function execute_tool(req)
    if req.action == "read_file" and req.path then
      local content, err = self.editor:read_file(req.path)
      if err then return "Error: " .. err end
      return "Contents of " .. req.path .. ":\n" .. (content or "")
    elseif req.action == "find_symbol" and req.name then
      local results, err = self.editor:find_symbol(req.name)
      if err then return "Error: " .. err end
      if not results or #results == 0 then
        return "No results found for symbol: " .. req.name
      end
      local parts = {}
      for _, r in ipairs(results) do
        table.insert(parts, string.format("%s:%d: %s", r.file, r.line, r.text))
      end
      return table.concat(parts, "\n")
    elseif req.action == "search_project" and req.pattern then
      local results = self.editor:search_project(req.pattern)
      if #results == 0 then
        return "No results found for: " .. req.pattern
      end
      local parts = {}
      for _, r in ipairs(results) do
        table.insert(parts, string.format("%s:%d: %s", r.file, r.line, r.text))
      end
      return table.concat(parts, "\n")
    end
    return "Unknown tool action: " .. (req.action or "nil")
  end

  local function do_round(prompt_str)
    if cancelled then return end
    round = round + 1
    if round > max_rounds then
      callbacks.on_error("Max tool rounds exceeded (" .. max_rounds .. ")")
      return
    end

    local cmd = vim.deepcopy(self.config.codex_cmd or { "codex", "exec" })
    table.insert(cmd, prompt_str)

    self.handle = vim.system(
      cmd,
      { timeout = self.config.timeout_ms or 90000, text = true },
      vim.schedule_wrap(function(result)
        self.handle = nil
        if cancelled then return end

        if result.code ~= 0 then
          -- Detect timeout: vim.system sends SIGTERM (signal 15) on timeout
          if result.signal == 15 or (result.stderr and result.stderr:find("timed? ?out")) then
            local timeout_s = math.floor((self.config.timeout_ms or 90000) / 1000)
            callbacks.on_error("Request timed out after " .. timeout_s .. "s")
            return
          end
          local err = result.stderr or result.stdout or "unknown error"
          if err == "" then err = "codex exited with code " .. result.code end
          callbacks.on_error("AI request failed: " .. vim.trim(err))
          return
        end

        local response = vim.trim(result.stdout or "")
        if response == "" then
          callbacks.on_error("AI returned empty response")
          return
        end

        local requests, visible = parse_tool_requests(response)

        if #requests > 0 then
          for _, req in ipairs(requests) do
            local status_msg = string.format("-- %s %s --",
              req.action == "read_file" and "reading" or
              req.action == "find_symbol" and "looking up" or "searching",
              req.path or req.name or req.pattern or "")
            callbacks.on_status(status_msg)

            local tool_result = execute_tool(req)
            table.insert(tool_context, tool_result)
          end

          local extended = prompt_str
            .. "\n\nAssistant: " .. visible
            .. "\n\nSystem: " .. table.concat(tool_context, "\n\n")
            .. "\n\nContinue your response."
          do_round(extended)
        else
          callbacks.on_chunk(response)
          callbacks.on_done({ text = response })
        end
      end)
    )
  end

  local initial_prompt = serialize_prompt(prompt, tool_context)
  do_round(initial_prompt)

  return cancel
end

return M
