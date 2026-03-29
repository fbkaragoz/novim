-- lua/novim/ports/ai.lua
-- Port contract: AI communication
--
-- send(history, context, callbacks) -> cancel_fn
--   history:   array of { role, text, context, timestamp }
--   context:   table from editor port's get_context()
--   callbacks: {
--     on_chunk  = function(text)      -- partial AI text (streaming)
--     on_status = function(text)      -- tool-use status ("reading src/types.ts")
--     on_done   = function(response)  -- { text = string }
--     on_error  = function(err_msg)   -- error string
--   }
--   Returns: cancel_fn() that kills the request and fires on_error("cancelled")

return {
  send = function(history, context, callbacks)
    error("ai.send: not implemented — wire an adapter")
  end,
}
