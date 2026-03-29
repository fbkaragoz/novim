-- lua/novim/core/diff.lua
local M = {}

function M.parse(response_text, current_file, buffer_lines)
  local explanation, code_blocks = M._extract_parts(response_text)

  if #code_blocks == 0 then
    return { type = "explain", explanation = explanation, changes = {} }
  end

  local hunks = {}
  for _, block in ipairs(code_blocks) do
    local hunk = M._block_to_hunk(block, current_file, buffer_lines)
    if hunk then
      table.insert(hunks, hunk)
    end
  end

  if #hunks == 0 then
    return { type = "explain", explanation = explanation, changes = {} }
  end

  return { type = "change", explanation = explanation, changes = hunks }
end

function M._extract_parts(text)
  local explanation_parts = {}
  local code_blocks = {}
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  local i = 1
  while i <= #lines do
    local marker_file, marker_line = lines[i]:match("^@@%s+(.+):(%d+)%s+@@")

    if marker_file and i + 1 <= #lines and lines[i + 1]:match("^%s*```") then
      i = i + 2
      local block_lines = {}
      while i <= #lines and not lines[i]:match("^%s*```") do
        table.insert(block_lines, lines[i])
        i = i + 1
      end
      table.insert(code_blocks, {
        file = marker_file,
        line = tonumber(marker_line),
        content = block_lines,
      })
      i = i + 1
    elseif lines[i]:match("^%s*```") then
      i = i + 1
      local block_lines = {}
      while i <= #lines and not lines[i]:match("^%s*```") do
        table.insert(block_lines, lines[i])
        i = i + 1
      end
      table.insert(code_blocks, {
        file = nil,
        line = nil,
        content = block_lines,
      })
      i = i + 1
    else
      table.insert(explanation_parts, lines[i])
      i = i + 1
    end
  end

  local explanation = table.concat(explanation_parts, "\n")
  explanation = explanation:match("^%s*(.-)%s*$") or ""
  return explanation, code_blocks
end

function M._block_to_hunk(block, current_file, buffer_lines)
  local file = block.file or current_file
  local start_line = block.line

  if not start_line and buffer_lines then
    start_line = M._fuzzy_match(block.content, buffer_lines)
  end

  if not start_line then
    return nil
  end

  local old_lines = {}
  if buffer_lines then
    for j = start_line, math.min(start_line + #block.content - 1, #buffer_lines) do
      table.insert(old_lines, buffer_lines[j])
    end
  end

  return {
    file = file,
    start_line = start_line,
    old_lines = old_lines,
    new_lines = block.content,
  }
end

function M._fuzzy_match(new_lines, buffer_lines)
  if #new_lines == 0 or #buffer_lines == 0 then
    return nil
  end

  local best_score = 0
  local best_line = nil
  local window = #new_lines

  for i = 1, math.max(1, #buffer_lines - window + 1) do
    local score = 0
    for j = 1, window do
      local buf_line = buffer_lines[i + j - 1] or ""
      local new_line = new_lines[j] or ""
      score = score + M._line_similarity(buf_line, new_line)
    end
    if score > best_score then
      best_score = score
      best_line = i
    end
  end

  if best_score < #new_lines * 0.3 then
    return nil
  end

  return best_line
end

function M._line_similarity(a, b)
  if a == b then return 1.0 end
  local at = a:match("^%s*(.-)%s*$") or ""
  local bt = b:match("^%s*(.-)%s*$") or ""
  if at == bt then return 0.9 end
  if #at == 0 and #bt == 0 then return 0.5 end
  if #at == 0 or #bt == 0 then return 0.0 end
  local shorter = #at < #bt and at or bt
  local longer = #at < #bt and bt or at
  local common = 0
  for i = 1, #shorter do
    if longer:find(shorter:sub(i, i), 1, true) then
      common = common + 1
    end
  end
  return common / #longer
end

function M.validate_hunks(hunks, buffer_lines)
  for _, hunk in ipairs(hunks) do
    for j, old_line in ipairs(hunk.old_lines) do
      local buf_idx = hunk.start_line + j - 1
      if buf_idx > #buffer_lines then
        return false, "Code has changed since this suggestion was made. Ask again for an updated fix."
      end
      if buffer_lines[buf_idx] ~= old_line then
        return false, "Code has changed since this suggestion was made. Ask again for an updated fix."
      end
    end
  end
  return true, nil
end

return M
