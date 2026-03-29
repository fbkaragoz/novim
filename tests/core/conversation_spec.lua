-- tests/core/conversation_spec.lua
describe("conversation", function()
  local conversation = require("novim.core.conversation")

  describe("new", function()
    it("creates a conversation with empty history", function()
      local conv = conversation.new()
      assert.is_table(conv)
      assert.same({}, conv:get_history())
    end)
  end)

  describe("add", function()
    it("appends a user message", function()
      local conv = conversation.new()
      conv:add("user", "what does this do")
      local history = conv:get_history()
      assert.equals(1, #history)
      assert.equals("user", history[1].role)
      assert.equals("what does this do", history[1].text)
      assert.is_number(history[1].timestamp)
    end)

    it("appends messages in order", function()
      local conv = conversation.new()
      conv:add("user", "hello")
      conv:add("ai", "hi there")
      conv:add("user", "fix this")
      local history = conv:get_history()
      assert.equals(3, #history)
      assert.equals("user", history[1].role)
      assert.equals("ai", history[2].role)
      assert.equals("user", history[3].role)
    end)

    it("stores optional context", function()
      local ctx = { file = "test.lua", cursor_line = 10 }
      local conv = conversation.new()
      conv:add("user", "hello", ctx)
      assert.same(ctx, conv:get_history()[1].context)
    end)
  end)

  describe("reset", function()
    it("clears all history", function()
      local conv = conversation.new()
      conv:add("user", "hello")
      conv:add("ai", "hi")
      conv:reset()
      assert.same({}, conv:get_history())
    end)
  end)

  describe("build_prompt", function()
    it("includes system prompt with intent hint", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "explain")
      assert.is_string(prompt.system)
      assert.truthy(prompt.system:find("explanation"))
    end)

    it("includes fix hint for fix intent", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "fix")
      assert.truthy(prompt.system:find("fix"))
    end)

    it("includes context section with file info", function()
      local conv = conversation.new()
      local context = { file = "src/main.lua", filetype = "lua", cursor_line = 42 }
      local prompt = conv:build_prompt(context, "explain")
      assert.truthy(prompt.context:find("src/main.lua"))
      assert.truthy(prompt.context:find("lua"))
      assert.truthy(prompt.context:find("42"))
    end)

    it("includes diagnostics in context", function()
      local conv = conversation.new()
      local context = {
        diagnostics = {
          { line = 10, message = "unused variable 'x'" },
        },
      }
      local prompt = conv:build_prompt(context, "diagnose")
      assert.truthy(prompt.context:find("unused variable"))
    end)

    it("includes selection in context", function()
      local conv = conversation.new()
      local context = { selection = "local x = 42" }
      local prompt = conv:build_prompt(context, "explain")
      assert.truthy(prompt.context:find("local x = 42"))
    end)

    it("includes conversation history (user and ai only)", function()
      local conv = conversation.new()
      conv:add("user", "what is this")
      conv:add("ai", "it is a function")
      conv:add("system", "-- reading file --")
      conv:add("user", "fix it")
      local prompt = conv:build_prompt({}, "fix")
      assert.truthy(prompt.history:find("what is this"))
      assert.truthy(prompt.history:find("it is a function"))
      assert.truthy(prompt.history:find("fix it"))
      assert.falsy(prompt.history:find("reading file"))
    end)

    it("returns empty history for fresh conversation", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "explain")
      assert.equals("", prompt.history)
    end)

    it("includes tool request format in system prompt", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "explain")
      assert.truthy(prompt.system:find("TOOL_REQUEST"))
    end)

    it("includes @@ marker instructions in system prompt", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "fix")
      assert.truthy(prompt.system:find("@@"))
    end)

    it("includes all five intent hints", function()
      local conv = conversation.new()
      for _, intent in ipairs({ "explain", "diagnose", "fix", "refactor", "write" }) do
        local prompt = conv:build_prompt({}, intent)
        assert.is_string(prompt.system)
        assert.truthy(#prompt.system > 100, "system prompt should be substantial for " .. intent)
      end
    end)

    it("falls back to explain hint for unknown intent", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "unknown_intent")
      assert.truthy(prompt.system:find("explanation"))
    end)

    it("handles nil context gracefully", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt(nil, "explain")
      assert.equals("", prompt.context)
    end)

    it("handles empty context table", function()
      local conv = conversation.new()
      local prompt = conv:build_prompt({}, "explain")
      assert.equals("", prompt.context)
    end)

    it("includes file_content in context", function()
      local conv = conversation.new()
      local context = { file_content = "local x = 1\nreturn x" }
      local prompt = conv:build_prompt(context, "explain")
      assert.truthy(prompt.context:find("local x = 1"))
    end)

    it("handles multiple diagnostics", function()
      local conv = conversation.new()
      local context = {
        diagnostics = {
          { line = 5, message = "unused variable" },
          { line = 10, message = "type mismatch" },
        },
      }
      local prompt = conv:build_prompt(context, "diagnose")
      assert.truthy(prompt.context:find("unused variable"))
      assert.truthy(prompt.context:find("type mismatch"))
    end)

    it("separates history entries with double newlines", function()
      local conv = conversation.new()
      conv:add("user", "first")
      conv:add("ai", "second")
      local prompt = conv:build_prompt({}, "explain")
      assert.truthy(prompt.history:find("first\n\n"))
    end)

    it("labels user messages as User and ai as Assistant", function()
      local conv = conversation.new()
      conv:add("user", "hello")
      conv:add("ai", "world")
      local prompt = conv:build_prompt({}, "explain")
      assert.truthy(prompt.history:find("User: hello"))
      assert.truthy(prompt.history:find("Assistant: world"))
    end)
  end)

  describe("isolation", function()
    it("conversations are independent instances", function()
      local conv1 = conversation.new()
      local conv2 = conversation.new()
      conv1:add("user", "only in conv1")
      assert.equals(1, #conv1:get_history())
      assert.equals(0, #conv2:get_history())
    end)

    it("reset does not affect other instances", function()
      local conv1 = conversation.new()
      local conv2 = conversation.new()
      conv1:add("user", "msg1")
      conv2:add("user", "msg2")
      conv1:reset()
      assert.equals(0, #conv1:get_history())
      assert.equals(1, #conv2:get_history())
    end)
  end)
end)
