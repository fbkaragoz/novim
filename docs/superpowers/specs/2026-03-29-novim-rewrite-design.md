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
- Used by the conversation module to set expectations for the AI response format
- Simple keyword/pattern matching, not AI-powered — runs instantly

**core/diff.lua**
- Parses structured AI responses into a normalized format
- Extracts code blocks, maps them to file locations
- Produces a list of hunks: `{ file, start_line, removed_lines, added_lines }`
- Handles edge cases: multi-file changes, no changes, malformed responses

**ports/ai.lua**
Contract:
```lua
{
  send = function(conversation_history, context) -> response
  -- response: { type, explanation, changes?, file_requests? }
}
```

**ports/editor.lua**
Contract:
```lua
{
  -- Layer 1: Attention (automatic, every message)
  get_cursor_context = function() -> { file, line, col, filetype, content }
  get_selection = function() -> { text, range } | nil
  get_diagnostics = function(line) -> { { message, severity, source } }
  get_file_content = function(bufnr) -> string

  -- Layer 2: Project (on demand, AI requests it)
  read_file = function(path) -> string | nil
  find_symbol = function(name) -> { { file, line, text } }
  search_project = function(pattern) -> { { file, line, text } }
}
```

**ports/presenter.lua**
Contract:
```lua
{
  open = function()                          -- open sidebar
  close = function()                         -- close sidebar
  is_open = function() -> bool

  append_message = function(role, text)      -- "you", "novim", "system"
  append_status = function(text)             -- dim system note ("reading file.ts")
  clear = function()                         -- reset conversation display

  show_diff = function(hunks)               -- render inline diff in code buffer
  clear_diff = function()                   -- remove inline diff preview
  apply_diff = function()                   -- make diff real (modify buffer)
  has_pending_diff = function() -> bool

  set_winbar = function(left, right)        -- update status bar
  scroll_to_bottom = function()
}
```

## UI Design

### Sidebar Layout

Right-side vertical split, ~35% of screen width. Single buffer, visually divided:

```
+-----------------------------+
| novim                   ASK |  <- winbar: plugin name + current state
|- - - - - - - - - - - - - - -|
|                             |
| You                         |  <- dim highlight
| what does this function do  |
|                             |
| Novim                       |  <- slightly brighter highlight
| This function takes a       |
| callback and registers it   |
| for the next event loop...  |
|                             |
| You                         |
| why is the import failing   |
|                             |
| Novim                       |
| The import references       |
| OrderType from src/types.ts |
| Let me check that file.     |
|                             |
| -- reading src/types.ts --  |  <- system note, muted highlight
|                             |
| Novim                       |
| Found it - OrderType was    |
| renamed to OrderStatus.     |
| Here's the fix:             |
|                             |
| ~ changes ready (CR apply)  |  <- change indicator
|                             |
|- - - - - - - - - - - - - - -|
| > _                         |  <- input area, always at bottom
+-----------------------------+
```

### Visual Elements (all native neovim)

**Winbar** — top of sidebar, always visible. Left: `novim`. Right: state indicator.
- Idle: `ASK`
- Waiting for AI: spinner animation
- Diff pending: `DIFF (CR)`

**Message roles** — distinct highlight groups:
- `NovimUser` — your messages, dimmed
- `NovimAI` — AI messages, normal weight
- `NovimSystem` — file reads, searches, muted/italic

**Input separator** — virtual text `- - - -` line between conversation and input area.

**Input area** — last line(s) of the buffer. Always starts with `> `. Free-form text input, multi-line supported (shift-enter or just keep typing, it wraps).

**Auto-scroll** — conversation scrolls to latest message. Scrolling up to read freezes auto-scroll. Returning cursor to input area re-enables it.

### Inline Diff Preview (in code buffer)

When the AI suggests changes, the code buffer shows a preview:

- **Removed lines**: red sign in gutter (`-`), dimmed text with strikethrough highlight
- **Added lines**: green sign in gutter (`+`), shown as virtual lines below the removal point with green highlight
- **Original code is untouched** — all visual, using extmarks and virtual text
- Preview persists until accepted or dismissed
- If you keep chatting, the AI can update the preview (old preview is replaced)

### Context Badge

When the sidebar is open, a subtle `>>` marker appears in the code buffer's sign column next to the line the AI is looking at. Moves as you move your cursor. Visual confirmation of "the AI is looking at this."

## Keybinds

| Key | Where | What |
|-----|-------|------|
| `<A-x>` | Anywhere | Toggle sidebar open/close |
| `<CR>` | Sidebar input | Send message if typing; apply diff if pending |
| `<Esc>` | Sidebar | Dismiss diff if pending; close sidebar if nothing pending |

Three keys. All contextual. The winbar tells you what `<CR>` and `<Esc>` will do.

## Interaction Flow

### Basic question

```
1. Cursor on line 42 of orders.lua, inside processOrder()
2. Press <A-x> — sidebar opens
3. Type: "what does this function do"
4. Press <CR>
5. Winbar shows spinner
6. AI response streams into sidebar with explanation
7. Winbar returns to ASK
8. You read, learn, continue coding or ask a follow-up
```

### Fix with diff

```
1. Cursor on a line with LSP error "Parameter 'opts' is declared but never used"
2. Press <A-x> — sidebar opens
3. Type: "why is this erroring"
4. AI explains the error in sidebar
5. Type: "fix it"
6. AI explains the fix in sidebar + diff preview appears in code buffer
   (opts -> _opts, green/red highlights)
7. Winbar shows: DIFF (CR)
8. Press <CR> — diff applied, code modified, preview disappears
9. Winbar returns to ASK
```

### Cross-file investigation

```
1. You: "why is this import failing"
2. AI: "The import references OrderType from src/types.ts.
        Let me check that file."
   Chat shows: -- reading src/types.ts --
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
5. AI sees new cursor position, uses conversation history,
   understands "this one" = the function at line 80
6. Context badge (>>) moves from line 42 to line 80
```

## Context Awareness

### Layer 1 — Attention (automatic, every message)

Gathered by `neovim_editor` adapter on each message send:
- Current file path and full content (or smart excerpt for very large files)
- Cursor line and column
- Visual selection text and range (if any)
- LSP diagnostics on and near the cursor line
- Filetype

### Layer 2 — Project (on demand)

Available to the AI when it determines it needs more context:
- `read_file(path)` — read any file in the project
- `find_symbol(name)` — LSP-powered symbol lookup
- `search_project(pattern)` — ripgrep-powered text search

The AI decides when to use layer 2. The user sees it happen in chat via system status messages (`-- reading src/types.ts --`).

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
- Multi-file diff preview (v2 shows diffs in the currently focused buffer only)
- Proactive AI suggestions (no ambient/automatic requests)
- Voice input
- Image/screenshot support
- Plugin marketplace or extension system
