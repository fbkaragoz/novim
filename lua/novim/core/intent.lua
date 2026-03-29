-- lua/novim/core/intent.lua
local M = {}

local patterns = {
  fix = {
    "fix", "repair", "solve", "resolve", "correct the",
  },
  diagnose = {
    "error", "wrong", "broken", "bug", "issue", "problem",
    "diagnose", "failing", "doesn't work", "not working",
  },
  refactor = {
    "refactor", "clean up", "simplify", "improve", "optimize",
    "restructure",
  },
  write = {
    "write", "create", "add", "implement", "generate", "build",
  },
  explain = {
    "what", "why", "how does", "how do", "explain", "describe",
    "tell me", "walk me through", "show me",
  },
}

local priority = { "fix", "write", "diagnose", "refactor", "explain" }

function M.classify(message)
  local lower = (message or ""):lower()
  for _, intent in ipairs(priority) do
    for _, pattern in ipairs(patterns[intent]) do
      if lower:find(pattern, 1, true) then
        return intent
      end
    end
  end
  return "explain"
end

return M
