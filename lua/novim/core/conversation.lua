-- lua/novim/core/conversation.lua
local M = {}
M.__index = M

function M.new()
  local self = setmetatable({}, M)
  self.history = {}
  return self
end

function M:add(role, text, context)
  table.insert(self.history, {
    role = role,
    text = text,
    context = context or nil,
    timestamp = os.time(),
  })
end

function M:reset()
  self.history = {}
end

function M:get_history()
  return self.history
end

function M:build_prompt(context, intent_hint)
  return {
    system = M._build_system_prompt(intent_hint),
    context = M._build_context_section(context),
    history = self:_build_history_section(),
  }
end

function M._build_system_prompt(intent_hint)
  local base = [==[You are Novim, an AI coding tutor embedded in a code editor. You explain code, diagnose errors, and suggest fixes.

Rules:
- Always explain before showing code changes.
- When suggesting code changes, use fenced code blocks with @@ file:line @@ markers on the line before the opening fence.
- Format: @@ filepath:line_number @@
- If you need to read files or search the project, use tool requests.

Tool request format:
[TOOL_REQUEST]
action: read_file
path: <file path>
[/TOOL_REQUEST]

[TOOL_REQUEST]
action: find_symbol
name: <symbol name>
[/TOOL_REQUEST]

[TOOL_REQUEST]
action: search_project
pattern: <search pattern>
[/TOOL_REQUEST]]==]

  local hints = {
    explain = "\n\nThe user is asking for an explanation. Respond with a clear explanation, no code changes.",
    diagnose = "\n\nThe user is asking about an error or problem. Diagnose the issue and explain what's wrong.",
    fix = "\n\nThe user wants a fix. Explain what's wrong, then include a code block with the proposed change using @@ markers.",
    refactor = "\n\nThe user wants a refactor. Explain the improvement, then include a code block with the change using @@ markers.",
    write = "\n\nThe user wants new code written. Explain what you'll write, then include a code block using @@ markers.",
  }

  return base .. (hints[intent_hint] or hints.explain)
end

function M._build_context_section(context)
  if not context then return "" end
  local parts = {}
  if context.file then
    table.insert(parts, "File: " .. context.file)
  end
  if context.filetype then
    table.insert(parts, "Filetype: " .. context.filetype)
  end
  if context.cursor_line then
    table.insert(parts, "Cursor: line " .. context.cursor_line)
  end
  if context.selection then
    table.insert(parts, "Selection:\n```\n" .. context.selection .. "\n```")
  end
  if context.file_content then
    table.insert(parts, "File content:\n```\n" .. context.file_content .. "\n```")
  end
  if context.diagnostics and #context.diagnostics > 0 then
    table.insert(parts, "Diagnostics:")
    for _, d in ipairs(context.diagnostics) do
      table.insert(parts, string.format("  Line %d: %s", d.line, d.message))
    end
  end
  return table.concat(parts, "\n")
end

function M:_build_history_section()
  local parts = {}
  for _, msg in ipairs(self.history) do
    if msg.role == "user" or msg.role == "ai" then
      local prefix = msg.role == "user" and "User" or "Assistant"
      table.insert(parts, prefix .. ": " .. msg.text)
    end
  end
  return table.concat(parts, "\n\n")
end

return M
