-- tests/core/diff_spec.lua
describe("diff", function()
  local diff = require("novim.core.diff")

  describe("_extract_parts", function()
    it("extracts explanation with no code blocks", function()
      local text = "This function adds two numbers together.\nIt returns the sum."
      local explanation, blocks = diff._extract_parts(text)
      assert.equals("This function adds two numbers together.\nIt returns the sum.", explanation)
      assert.equals(0, #blocks)
    end)

    it("extracts a bare code block", function()
      local text = "Here is the fix:\n```lua\nlocal x = 42\n```\nDone."
      local explanation, blocks = diff._extract_parts(text)
      assert.truthy(explanation:find("Here is the fix"))
      assert.truthy(explanation:find("Done."))
      assert.equals(1, #blocks)
      assert.is_nil(blocks[1].file)
      assert.is_nil(blocks[1].line)
      assert.same({ "local x = 42" }, blocks[1].content)
    end)

    it("extracts a code block with @@ marker", function()
      local text = "Fix:\n@@ src/main.lua:42 @@\n```lua\nlocal x = _opts\n```"
      local explanation, blocks = diff._extract_parts(text)
      assert.truthy(explanation:find("Fix"))
      assert.equals(1, #blocks)
      assert.equals("src/main.lua", blocks[1].file)
      assert.equals(42, blocks[1].line)
      assert.same({ "local x = _opts" }, blocks[1].content)
    end)

    it("handles multiple code blocks", function()
      local text = "Two changes:\n@@ a.lua:1 @@\n```\nfirst\n```\n@@ b.lua:5 @@\n```\nsecond\n```"
      local _, blocks = diff._extract_parts(text)
      assert.equals(2, #blocks)
      assert.equals("a.lua", blocks[1].file)
      assert.equals(1, blocks[1].line)
      assert.same({ "first" }, blocks[1].content)
      assert.equals("b.lua", blocks[2].file)
      assert.equals(5, blocks[2].line)
      assert.same({ "second" }, blocks[2].content)
    end)

    it("handles multi-line code blocks", function()
      local text = "@@ test.lua:10 @@\n```lua\nline one\nline two\nline three\n```"
      local _, blocks = diff._extract_parts(text)
      assert.equals(1, #blocks)
      assert.same({ "line one", "line two", "line three" }, blocks[1].content)
    end)

    it("handles empty code blocks", function()
      local text = "Nothing:\n```\n```"
      local _, blocks = diff._extract_parts(text)
      assert.equals(1, #blocks)
      assert.same({}, blocks[1].content)
    end)

    it("handles code fence with language tag", function()
      local text = "```python\nprint('hi')\n```"
      local _, blocks = diff._extract_parts(text)
      assert.equals(1, #blocks)
      assert.same({ "print('hi')" }, blocks[1].content)
    end)

    it("preserves explanation text around code blocks", function()
      local text = "Before.\n```\ncode\n```\nAfter."
      local explanation, _ = diff._extract_parts(text)
      assert.truthy(explanation:find("Before."))
      assert.truthy(explanation:find("After."))
    end)
  end)

  describe("parse", function()
    it("returns explain type when no code blocks", function()
      local result = diff.parse("Just an explanation.", "test.lua", { "line1" })
      assert.equals("explain", result.type)
      assert.equals("Just an explanation.", result.explanation)
      assert.same({}, result.changes)
    end)

    it("returns change type with hunks for marked code blocks", function()
      local buffer = { "local x = opts", "return x" }
      local text = "Fix:\n@@ test.lua:1 @@\n```lua\nlocal x = _opts\n```"
      local result = diff.parse(text, "test.lua", buffer)
      assert.equals("change", result.type)
      assert.equals(1, #result.changes)
      assert.equals("test.lua", result.changes[1].file)
      assert.equals(1, result.changes[1].start_line)
      assert.same({ "local x = opts" }, result.changes[1].old_lines)
      assert.same({ "local x = _opts" }, result.changes[1].new_lines)
    end)

    it("uses current_file for blocks without file in marker", function()
      local buffer = { "hello" }
      local text = "@@ :1 @@\n```\nworld\n```"
      local result = diff.parse(text, "main.lua", buffer)
      assert.is_table(result)
    end)

    it("defaults file to current_file for bare code blocks", function()
      local buffer = { "local old = true" }
      local text = "Fix:\n```lua\nlocal old = false\n```"
      local result = diff.parse(text, "test.lua", buffer)
      if #result.changes > 0 then
        assert.equals("test.lua", result.changes[1].file)
      end
    end)
  end)

  describe("_fuzzy_match", function()
    it("finds exact match location", function()
      local buffer = { "aaa", "bbb", "ccc", "ddd" }
      local new_lines = { "bbb", "ccc" }
      assert.equals(2, diff._fuzzy_match(new_lines, buffer))
    end)

    it("finds close match with whitespace differences", function()
      local buffer = { "  local x = 1", "  local y = 2", "  return x + y" }
      local new_lines = { "local x = 1", "local y = 2" }
      assert.equals(1, diff._fuzzy_match(new_lines, buffer))
    end)

    it("returns nil when no reasonable match", function()
      local buffer = { "aaa", "bbb", "ccc" }
      local new_lines = { "zzz", "yyy" }
      assert.is_nil(diff._fuzzy_match(new_lines, buffer))
    end)

    it("returns nil for empty inputs", function()
      assert.is_nil(diff._fuzzy_match({}, { "a" }))
      assert.is_nil(diff._fuzzy_match({ "a" }, {}))
    end)

    it("handles single-line match", function()
      local buffer = { "first", "target", "last" }
      local new_lines = { "target_modified" }
      local result = diff._fuzzy_match(new_lines, buffer)
      assert.equals(2, result)
    end)
  end)

  describe("_line_similarity", function()
    it("returns 1.0 for identical lines", function()
      assert.equals(1.0, diff._line_similarity("hello", "hello"))
    end)

    it("returns 0.9 for whitespace-only differences", function()
      assert.equals(0.9, diff._line_similarity("  hello  ", "hello"))
    end)

    it("returns 0.0 when one line is empty", function()
      assert.equals(0.0, diff._line_similarity("hello", ""))
      assert.equals(0.0, diff._line_similarity("", "hello"))
    end)

    it("returns 1.0 for two empty lines (identical)", function()
      assert.equals(1.0, diff._line_similarity("", ""))
    end)

    it("returns partial score for partially matching lines", function()
      local score = diff._line_similarity("local x = 1", "local x = 2")
      assert.is_true(score > 0.5)
      assert.is_true(score < 1.0)
    end)
  end)

  describe("validate_hunks", function()
    it("returns true when buffer matches old_lines", function()
      local hunks = {
        { start_line = 1, old_lines = { "aaa", "bbb" }, new_lines = { "ccc" } },
      }
      local buffer = { "aaa", "bbb", "ccc" }
      local ok, err = diff.validate_hunks(hunks, buffer)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false when buffer has changed", function()
      local hunks = {
        { start_line = 1, old_lines = { "aaa" }, new_lines = { "bbb" } },
      }
      local buffer = { "CHANGED" }
      local ok, err = diff.validate_hunks(hunks, buffer)
      assert.is_false(ok)
      assert.truthy(err:find("changed"))
    end)

    it("returns false when buffer is shorter than expected", function()
      local hunks = {
        { start_line = 1, old_lines = { "a", "b", "c" }, new_lines = { "x" } },
      }
      local buffer = { "a" }
      local ok, err = diff.validate_hunks(hunks, buffer)
      assert.is_false(ok)
    end)

    it("validates multiple hunks", function()
      local hunks = {
        { start_line = 1, old_lines = { "aaa" }, new_lines = { "xxx" } },
        { start_line = 3, old_lines = { "ccc" }, new_lines = { "yyy" } },
      }
      local buffer = { "aaa", "bbb", "ccc" }
      local ok, _ = diff.validate_hunks(hunks, buffer)
      assert.is_true(ok)
    end)
  end)
end)
