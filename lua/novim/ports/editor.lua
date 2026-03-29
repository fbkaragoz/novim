-- lua/novim/ports/editor.lua
-- Port contract: editor integration
--
-- get_context()                -> { file, filetype, cursor_line, cursor_col,
--                                   selection, file_content, diagnostics }
-- get_buffer_lines(bufnr)     -> array of strings (1-indexed)
-- read_file(path)             -> string (file content, truncated per config)
-- find_symbol(name)           -> array of { file, line, text } or error string
-- search_project(pattern)     -> array of { file, line, text }
-- apply_diff(hunks)           -> boolean (success)
-- show_diff_preview(hunks)    -> void (extmarks in code buffer)
-- clear_diff_preview()        -> void
-- show_context_badge(bufnr, line) -> void
-- clear_context_badge()       -> void

return {
  get_context = function() error("editor.get_context: not implemented") end,
  get_buffer_lines = function(bufnr) error("editor.get_buffer_lines: not implemented") end,
  read_file = function(path) error("editor.read_file: not implemented") end,
  find_symbol = function(name) error("editor.find_symbol: not implemented") end,
  search_project = function(pattern) error("editor.search_project: not implemented") end,
  apply_diff = function(hunks) error("editor.apply_diff: not implemented") end,
  show_diff_preview = function(hunks) error("editor.show_diff_preview: not implemented") end,
  clear_diff_preview = function() error("editor.clear_diff_preview: not implemented") end,
  show_context_badge = function(bufnr, line) error("editor.show_context_badge: not implemented") end,
  clear_context_badge = function() error("editor.clear_context_badge: not implemented") end,
}
