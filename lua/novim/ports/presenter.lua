-- lua/novim/ports/presenter.lua
-- Port contract: UI presentation
--
-- open(callbacks)     -> void
--   callbacks: {
--     on_submit  = function(text)   -- user sent a message
--     on_accept  = function()       -- user accepted pending diff
--     on_dismiss = function()       -- user dismissed pending diff
--     on_cancel  = function()       -- user cancelled in-flight request
--     on_close   = function()       -- user closed the sidebar
--   }
-- close()             -> void
-- is_open()           -> boolean
-- add_message(role, text) -> void   (role: "user"|"ai"|"system")
-- set_state(state)    -> void       (state: "idle"|"thinking"|"diff_pending")
-- focus_input()       -> void

return {
  open = function(callbacks) error("presenter.open: not implemented") end,
  close = function() error("presenter.close: not implemented") end,
  is_open = function() error("presenter.is_open: not implemented") end,
  add_message = function(role, text) error("presenter.add_message: not implemented") end,
  set_state = function(state) error("presenter.set_state: not implemented") end,
  focus_input = function() error("presenter.focus_input: not implemented") end,
}
