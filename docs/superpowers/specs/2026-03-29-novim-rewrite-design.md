# Novim v2 — Design Spec

## What is Novim

A neovim plugin that puts an AI tutor beside your code. Not a code-generation tool — a "show me, explain, then I decide" companion for learning and working with code.

The user is learning to program. They want to understand what code does, why errors happen, and how to fix things — with the AI meeting them where their cursor is. No copy-pasting filenames, no switching tabs, no explaining context manually.

## Core Principles

1. **Explain first, change second** — the AI always explains before showing a diff. No silent replacements.
2. **One keybind to rule them all** — `<A-x>` toggles the sidebar. `<CR>` and `<Esc>` do the obvious thing. Three keys total.
3. **No modes** — the AI infers intent from natural language. "what does this do" = explain. "fix this" = diff. No ask/work toggle.
4. **Context-aware, not context-aggressive** — the AI sees your cursor, selection, and diagnostics automatically. It can reach into the project when needed. It never proactively fires requests.
5. **Visible reasoning** — when the AI reads files or searches the project, you see it happen in the chat. No black box.
6. **Hexagonal architecture** — core logic knows nothing about neovim. UI knows nothing about AI. Clean separation.

## Architecture

```
lua/novim/
  init.lua                  -- Entry: setup(), keybind wiring

  core/
    conversation.lua        -- Message history, prompt building
    intent.lua              -- Classify user input -> explain/fix/refactor/write
    diff.lua                -- Parse AI response -> structured changes + explanation

  ports/
    ai.lua                  -- Port: send prompt, get structured response
    editor.lua              -- Port: read cursor/selection/diagnostics/files
    presenter.lua           -- Port: render conversation, show diffs, accept/reject

  adapters/
    codex.lua               -- Implements ai port via `codex exec` CLI
    neovim_editor.lua       -- Implements editor port via vim.api + LSP
    sidebar.lua             -- Implements presenter port (the sidebar UI)

plugin/
  novim.lua                 -- Keymaps and user commands (thin shell)
```

### The Rule

- Nothing in `core/` calls `vim.*`
- Nothing in `adapters/` contains business logic
- `ports/` are contracts only — tables describing function signatures
- Each file has one job

### Module Responsibilities

**core/conversation.lua**
- Holds structured message history: `{ role, text, context, timestamp }`
- Builds the full prompt for each AI request (conversation history + current context)
- Sends full history to the AI — no artificial trimming
- Resets when sidebar closes

**core/intent.lua**
- Takes a user message string, returns an intent classification
- Intent types: `explain`, `diagnose`, `fix`, `refactor`, `write`
- The classified intent is included in the system prompt as a hint to the AI: `explain` → "respond with an explanation, no code changes", `fix`/`refactor`/`write` → "include a code block with the proposed change". This is a soft hint — the AI may override it (e.g., user says "fix this" but nothing is broken → AI responds with explanation only). The response `type` field reflects what the AI actually did, not what the intent predicted.
- Simple keyword/pattern matching, not AI-powered — runs instantly

**core/diff.lua**
- Parses structured AI responses into a normalized format
- Extracts fenced code blocks from the AI response. The AI is instructed (via system prompt) to include `@@ file:line @@` markers before code blocks to indicate where changes apply. Example:

```
@@ src/orders.lua:42 @@
```lua
function processOrder(_opts, callback)
```

- If markers are missing, falls back to fuzzy matching: takes the code block content and searches the current file buffer for the closest matching region using a line-by-line similarity score. This handles cases where the AI doesn't follow the format exactly.
- Produces a list of hunks:
```lua
{
  file = "src/orders.lua",       -- file path
  start_line = 42,               -- 1-indexed line in buffer
  old_lines = { "opts" },        -- actual line content being replaced
  new_lines = { "_opts" },       -- actual line content to insert
}
```
- `old_lines` and `new_lines` are arrays of strings (line content), not counts
- Before applying, validates that `old_lines` still matches the buffer content at `start_line`. If the buffer has been edited since context was captured, the diff is rejected with a message: "Code has changed since this suggestion was made. Ask again for an updated fix."
- Handles edge cases: no code blocks in response (type=explain), malformed markers, empty blocks

## AI Communication Protocol

### Single-turn with tool-use loop

The AI port uses a request-response loop. Each call to `send()` may result in multiple round-trips if the AI requests project context:

```
conversation.lua calls ai.send(history, context)
    |
    v
codex adapter builds prompt, executes CLI
    |
    v
Parse response -> does it contain tool_requests?
    |--- NO --> return structured response to conversation
    |--- YES --> for each request:
                   execute via editor port (read_file, find_symbol, etc.)
                   append result to conversation as system context
                   re-send to AI with updated context
                   (max 5 iterations to prevent infinite loops)
```

### Tool request format

The AI is instructed (via system prompt) to request tools using a structured format in its response:

```
[TOOL_REQUEST]
action: read_file
path: src/types.ts
[/TOOL_REQUEST]
```

The codex adapter parses these from the raw response text. Everything outside `[TOOL_REQUEST]` blocks is treated as the AI's visible message (shown in chat). Tool requests are:
- Displayed in the sidebar as system status messages: `-- reading src/types.ts --`
- Executed via the editor port
- Results appended to context for the next AI call
- The AI's next response continues the conversation naturally

Supported tool actions:
- `read_file { path }` — read a file from the project
- `find_symbol { name }` — LSP symbol lookup
- `search_project { pattern }` — ripgrep text search

### Port contract (revised)

**ports/ai.lua**
```lua
{
  -- Sends a message and handles the tool-use loop internally.
  -- Calls on_chunk for each piece of visible AI text as it arrives.
  -- Calls on_status for tool-use status messages.
  -- Calls on_done with the final structured response.
  -- Returns a cancel() function.
  send = function(history, context, callbacks) -> cancel_fn
  -- callbacks: {
  --   on_chunk = function(text)        -- partial AI text (for streaming display)
  --   on_status = function(text)       -- "reading src/types.ts"
  --   on_done = function(response)     -- { type, explanation, changes? }
  --   on_error = function(err_msg)     -- error string
  -- }
}
```

### Streaming

The `codex exec` CLI returns output all at once (not streamed). The initial implementation will:
1. Show a spinner in the winbar while waiting
2. Display the full response at once when it arrives via `on_done`
3. `on_chunk` is called once with the full text (for forward-compatibility)

If a future adapter supports true streaming (e.g., direct API calls), the `on_chunk` callback receives incremental text and the sidebar adapter appends it in real time. The contract supports both patterns without changes.

### Cancellation

`send()` returns a `cancel_fn`. Calling it:
- Kills the underlying `vim.system()` process
- Fires `on_error("cancelled")`
- The sidebar shows "Cancelled" and returns to idle state

Currently, `<Esc>` with a spinner showing (AI thinking) cancels the request. This is handled by the sidebar checking if a request is in flight before deciding what `<Esc>` does.

## UI Design

### Sidebar Layout

Right-side vertical split, ~35% of screen width. Uses **two buffers in one window**, not a single buffer:

1. **Conversation buffer** (read-only) — fills most of the window. Contains all messages. User cannot edit this.
2. **Input buffer** — a small floating window anchored to the bottom of the sidebar split. Always editable. Always starts with `> ` as a virtual text prefix (using extmarks, not real text — so backspace can't delete it).

The two-buffer approach solves the "partially editable buffer" problem cleanly. The conversation buffer is fully `nomodifiable`. The input buffer is fully editable. They appear as one continuous UI via positioning.

```
+-----------------------------+
| novim                   ASK |  <- winbar (on sidebar split)
|- - - - - - - - - - - - - - -|
|                             |
| You                         |  <- conversation buffer (read-only)
| what does this function do  |
|                             |
| Novim                       |
| This function takes a       |
| callback and registers it   |
| for the next event loop...  |
|                             |
| ~ changes ready             |  <- change indicator
|                             |
+-----------------------------+
| > _                         |  <- input buffer (floating, editable)
+-----------------------------+
```

### Visual Elements (all native neovim)

**Winbar** — top of sidebar, always visible. Left: `novim`. Right: state indicator.
- Idle: `ASK`
- Waiting for AI: spinner animation
- Diff pending: `DIFF`
- AI thinking + diff pending: spinner (request takes priority in display)

**Message roles** — distinct highlight groups:
- `NovimUser` — your messages, dimmed
- `NovimAI` — AI messages, normal weight
- `NovimSystem` — file reads, searches, muted/italic

**Input buffer** — floating window anchored at sidebar bottom. The `> ` prefix is a virtual text extmark (not real text), so the user can't accidentally delete it. Multi-line input: just keep typing, the float grows up to 5 lines tall, then scrolls. `<CR>` sends.

**Auto-scroll** — conversation buffer auto-scrolls to bottom when new messages arrive. If the user scrolls up (detected via `WinScrolled` autocmd checking if cursor is above the last line), auto-scroll pauses. It resumes when the user presses any key in the input buffer (detected via `BufEnter` or `InsertEnter` on the input buffer).

### Inline Diff Preview (in code buffer)

When the AI suggests changes, the code buffer shows a preview using extmarks and virtual text. No actual buffer modification until accepted.

- **Removed lines**: red sign in gutter (`-`), dimmed text with strikethrough highlight (`NovimDiffRemove`)
- **Added lines**: green sign in gutter (`+`), shown as virtual lines below the removal point with green highlight (`NovimDiffAdd`). Uses `nvim_buf_set_extmark` with `virt_lines`.
- **Original code is untouched** underneath the extmarks
- Preview persists until accepted or dismissed
- If the user keeps chatting and the AI suggests an updated change, the old preview extmarks are cleared and replaced with the new ones

**Stale diff protection**: Before applying a diff, `diff.lua` validates that `old_lines` in each hunk still matches the actual buffer content. If the buffer was edited, the diff is rejected with a chat message explaining why.

### Context Badge

When the sidebar is open, a `>>` sign column marker appears next to the line the AI is looking at. Updated via `CursorMoved` autocmd with a 150ms debounce (using `vim.defer_fn`) to avoid flicker. Uses a dedicated extmark namespace so it doesn't conflict with other sign column plugins.

## Keybinds

| Key | Where | State | What |
|-----|-------|-------|------|
| `<A-x>` | Anywhere | Any | Toggle sidebar open/close |
| `<CR>` | Input buffer | No pending diff | Send message |
| `<CR>` | Input buffer | Diff pending + input empty | Apply diff |
| `<CR>` | Input buffer | Diff pending + input has text | Send message (follow-up, diff stays) |
| `<Esc>` | Input buffer | AI thinking | Cancel request |
| `<Esc>` | Input buffer | Diff pending | Dismiss diff |
| `<Esc>` | Input buffer | Idle, no diff | Close sidebar |

The ambiguity is resolved: **if you're typing something, `<CR>` always sends.** Only when the input is empty AND a diff is pending does `<CR>` apply the diff. `<Esc>` priority: cancel > dismiss diff > close. The winbar reflects the current state so the user always knows what will happen.

## Interaction Flow

### Basic question

```
1. Cursor on line 42 of orders.lua, inside processOrder()
2. Press <A-x> — sidebar opens, input buffer focused
3. Type: "what does this function do"
4. Press <CR> — message sent, winbar shows spinner
5. AI response appears in conversation buffer
6. Winbar returns to ASK
7. You read, learn, continue coding or ask a follow-up
```

### Fix with diff

```
1. Cursor on a line with LSP error "Parameter 'opts' is declared but never used"
2. Press <A-x> — sidebar opens
3. Type: "why is this erroring"
4. Press <CR> — AI explains the error in conversation buffer
5. Type: "fix it"
6. Press <CR> — AI explains the fix + diff preview appears in code buffer
   (opts -> _opts, green/red highlights)
7. Winbar shows: DIFF
8. Input is empty, press <CR> — diff applied, code modified, preview disappears
9. Winbar returns to ASK
```

### Cross-file investigation

```
1. You: "why is this import failing" <CR>
2. AI: "The import references OrderType from src/types.ts.
        Let me check that file."
   Chat shows: -- reading src/types.ts --  (system status, muted)
   (codex adapter executes read_file, re-sends to AI)
3. AI: "Found it - OrderType was renamed to OrderStatus
        in that file. Here's the fix:"
4. Diff preview appears in code buffer
5. <CR> to apply
```

### Conversation continuity

```
1. You ask about function on line 42
2. AI explains
3. You move cursor to line 80, different function
4. You: "and what about this one?"
5. AI sees new cursor position (gathered fresh on send),
   uses conversation history,
   understands "this one" = the function at line 80
6. Context badge (>>) moves to line 80
```

### Cancellation

```
1. You send a message, winbar shows spinner
2. You realize you asked the wrong thing
3. Press <Esc> — request cancelled, sidebar shows "Cancelled"
4. Type a new message and <CR>
```

## Context Awareness

### Layer 1 — Attention (automatic, every message)

Gathered by `neovim_editor` adapter on each message send:
- Current file path and filetype
- File content: files under 500 lines are sent in full. Files over 500 lines send a window of 200 lines above and 200 lines below the cursor, plus the full function/block scope containing the cursor (detected via treesitter or simple brace matching). The truncation boundaries and total line count are noted in the context so the AI knows it's seeing a partial file.
- Cursor line and column
- Visual selection text and range (if any)
- LSP diagnostics on and near the cursor line (within 5 lines)

### Layer 2 — Project (on demand)

Available to the AI when it requests tools:
- `read_file(path)` — read any file in the project. Same 500-line truncation rule applies; if the AI needs a specific section it can request with a line range.
- `find_symbol(name)` — LSP-powered symbol lookup. Returns up to 20 results: `{ file, line, text }`. Requires an attached LSP client; if none is attached, returns an error message the AI can relay to the user.
- `search_project(pattern)` — ripgrep text search. Returns up to 30 matches: `{ file, line, text }`. Falls back to `vim.fn.glob` + lua pattern matching if ripgrep is not installed.

The AI decides when to use layer 2. Each tool use is visible in chat.

## Configuration

`require("novim").setup(opts)` with these defaults:

```lua
{
  -- AI backend
  codex_cmd = { "codex", "exec" },  -- command to invoke AI
  timeout_ms = 90000,               -- max wait per AI call
  max_tool_rounds = 5,              -- max tool-use loop iterations

  -- Sidebar
  sidebar_width = 0.35,             -- fraction of screen width
  sidebar_min_width = 40,           -- minimum columns
  sidebar_max_width = 80,           -- maximum columns
  sidebar_position = "right",       -- "right" or "left"

  -- Context
  context_lines = 200,              -- lines above/below cursor for large files
  large_file_threshold = 500,       -- lines; above this, truncate context

  -- Diff
  diff_sign_add = "+",              -- gutter sign for added lines
  diff_sign_remove = "-",           -- gutter sign for removed lines

  -- Keybind
  toggle_key = "<A-x>",            -- sidebar toggle; set to false to disable
}
```

All options are optional. `setup()` validates: `codex_cmd` must be a table, numeric values must be positive, `sidebar_position` must be "right" or "left". Invalid values log a warning and fall back to defaults.

## Error Handling

Errors are surfaced in the sidebar chat as system messages (muted highlight), not as `vim.notify` popups. The user sees them in context alongside the conversation.

| Scenario | Behavior |
|----------|----------|
| `codex` CLI not found | On first `send()`: system message "codex not found — install it and make sure it's in PATH". Sidebar stays open for the user to read. |
| `codex` CLI exits non-zero | System message with stderr content: "AI request failed: <error>". User can retry by sending another message. |
| Request timeout | System message: "Request timed out after 90s". Request is cancelled. User can retry. |
| LSP not attached | `get_diagnostics` returns empty list (no error). `find_symbol` returns error string; the AI relays it: "I can't look up symbols — no language server is running for this file." |
| ripgrep not installed | `search_project` falls back to lua glob+match. No error shown. |
| Buffer edited during AI request | Diff validation catches stale hunks. System message: "Code changed since this suggestion — ask again for an updated fix." |
| AI response has no parseable structure | Entire response treated as explanation (type=explain). No diff attempted. |
| User closes sidebar with `:q` | `BufWipeout` autocmd on conversation buffer triggers cleanup: cancels any in-flight request, clears diff preview, resets state. Same as pressing `<A-x>` to close. |
| `:qa` / quit neovim | Sidebar buffer is `buftype=nofile` and `buflisted=false` — does not block quit, does not trigger save prompts. |

## Session Lifecycle

- **Open**: `<A-x>` opens sidebar. Fresh conversation. Context gathered from current cursor position.
- **Active**: conversation accumulates. Context refreshed on each message send (current cursor, not original).
- **Close**: `<Esc>` (when idle) or `<A-x>` closes sidebar. Conversation is discarded. Diff preview is cleared.
- **Reopen**: `<A-x>` again starts a completely fresh session.

This is a deliberate choice: no persistence. The sidebar is ephemeral like a conversation with someone standing next to you. The learning happens in your head and in the code you accept, not in chat history.

## Window Management

- The sidebar is scoped to the current tab. Each tab can have its own sidebar (or not).
- Opening a sidebar in a tab where one is already open focuses the existing one.
- Splits, tab switches, and other window operations do not affect the sidebar — it's a normal neovim split with `winfixwidth=true`.
- The input floating window follows the sidebar split. If the sidebar is resized, the float repositions on `WinResized`.

## What This Replaces

The current novim plugin (v1) is an 829-line monolith with:
- ask/work mode switching (6+ keybinds just for modes)
- A 2-line floating prompt that can't fit real questions
- A 52%-width output split that disrupts layout
- No conversation continuity
- No diff preview
- No context awareness beyond a fixed 20-line window
- Tightly coupled UI + logic + API calls in one file

All of this is replaced by the design above. The v1 code will be removed entirely — clean rewrite.

## Out of Scope

- Persistent chat history across sessions
- Multi-file diff preview (v2 shows diffs in the currently focused buffer only; cross-file changes are explained in chat)
- Proactive AI suggestions (no ambient/automatic requests)
- Voice input, image/screenshot support
- Plugin marketplace or extension system
- True streaming (initial version receives full response; streaming support is forward-compatible via the callback contract but not implemented in the codex adapter)
