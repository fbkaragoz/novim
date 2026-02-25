local M = {}

M.opts = {
    codex_cmd = { "codex", "exec" },
    timeout_ms = 90000,
    context_lines = 20,
    pass_context_as_prompt = true,
    replace_selection = true,
    show_errors = true,
    prompt_blend = 22,
    prompt_border = "none",
    prompt_min_width = 54,
    prompt_max_width = 86,
    prompt_row_offset = 3,
    output_split = "noautocmd rightbelow vsplit",
    output_ratio = 0.52,
    output_min_width = 64,
    output_max_width = 130,
}

M.mode = "work"
M._last = {}
M._panel = { buf = nil, win = nil, last_lines = nil, prev_win = nil }
M._prompt = { buf = nil, win = nil, selected = nil, range = nil }
M._spinner = { timer = nil, frame = 0, running = false, icon = "" }
local open_output
local spinner_frames = { "-", "\\", "|", "/" }

local function log(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = "novim" })
end

local function clamp(value, min_value, max_value)
    if max_value < min_value then
        max_value = min_value
    end
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function sanitize_lines(text)
    return vim.split(vim.trim(text or ""), "\n", { plain = true })
end

local function sanitize_for_replacement(text)
    local raw = vim.trim(text or "")
    if raw == "" then
        return {}
    end

    local lines = vim.split(raw, "\n", { plain = true })
    local blocks = {}
    local capturing = false
    local current_block = {}

    for _, line in ipairs(lines) do
        if line:match("^%s*```") then
            if not capturing then
                capturing = true
                current_block = {}
            else
                table.insert(blocks, vim.trim(table.concat(current_block, "\n")))
                capturing = false
                break
            end
        elseif capturing then
            table.insert(current_block, line)
        end
    end

    if capturing and #current_block > 0 then
        table.insert(blocks, vim.trim(table.concat(current_block, "\n")))
    end

    if #blocks > 0 and blocks[1] ~= "" then
        return sanitize_lines(blocks[1])
    end

    return sanitize_lines(raw)
end

local function normalize_mode(mode)
    local m = (mode or "work"):lower()
    if m == "ask" or m == "work" then
        return m
    end
    return "work"
end

function M.setup(opts)
    M.opts = vim.tbl_deep_extend("force", {}, M.opts, opts or {})
    M.mode = normalize_mode(M.opts.mode or M.mode)
end

function M.toggle_mode()
    if M.mode == "ask" then
        M.set_mode("work")
        return
    end
    M.set_mode("ask")
end

function M.get_mode()
    return M.mode
end

local function visual_range()
    local bufnr = vim.api.nvim_get_current_buf()
    local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
    local in_visual_mode = vim.fn.mode():find("[vV\22]") ~= nil

    if not in_visual_mode then
        return nil, "No visual selection"
    end

    local use_fallback = false
    if not start_mark or not end_mark then
        use_fallback = true
    elseif start_mark[1] <= 0 or end_mark[1] <= 0 then
        use_fallback = true
    end

    if use_fallback then
        local v_start = vim.fn.getpos("v")
        local v_end = vim.fn.getpos(".")
        if v_start and v_end and v_start[2] > 0 and v_end[2] > 0 then
            start_mark = { v_start[2], v_start[3] - 1 }
            end_mark = { v_end[2], v_end[3] - 1 }
            use_fallback = false
        end
    end

    if use_fallback then
        return nil, "No visual selection"
    end

    local start_row = start_mark[1] - 1
    local start_col = math.max(0, start_mark[2])
    local end_row = end_mark[1] - 1
    local end_col = math.max(0, end_mark[2])

    if start_row > end_row or (start_row == end_row and start_col > end_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local linewise = start_row ~= end_row and start_col == 0 and end_col == 0
    local linecount = vim.api.nvim_buf_line_count(bufnr)
    if start_row >= linecount or end_row >= linecount then
        return nil, "Selection outside buffer bounds"
    end

    local same_row = start_row == end_row
    if same_row and end_col < start_col then
        return nil, "Selection is empty"
    end

    return {
        bufnr = bufnr,
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        same_row = same_row,
        linewise = linewise,
    }
end

local function read_selection(range)
    local lines = vim.api.nvim_buf_get_lines(range.bufnr, range.start_row, range.end_row + 1, false)
    if #lines == 0 then
        return nil
    end

    if range.linewise then
        return table.concat(lines, "\n"), range
    end

    if range.same_row then
        local line = lines[1] or ""
        if range.start_col >= #line then
            return ""
        end
        local e = math.min(range.end_col + 1, #line)
        if e < range.start_col then
            return ""
        end
        return line:sub(range.start_col + 1, e), range
    end

    local first_line = (lines[1] or ""):sub(range.start_col + 1)
    local last_line = lines[#lines] or ""
    local last_end = math.min(range.end_col + 1, #last_line)
    lines[1] = first_line
    lines[#lines] = (range.end_col == 0) and last_line or last_line:sub(1, last_end)
    return table.concat(lines, "\n"), range
end

local function cursor_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local before_start = math.max(0, row - M.opts.context_lines)
    local after_end = math.min(vim.api.nvim_buf_line_count(bufnr), row + M.opts.context_lines + 1)
    local before = vim.api.nvim_buf_get_lines(bufnr, before_start, row, false)
    local after = vim.api.nvim_buf_get_lines(bufnr, row, after_end, false)
    return table.concat(before, "\n"), table.concat(after, "\n")
end

local function range_context(range)
    if not range then
        return "", ""
    end
    local before_start = math.max(0, range.start_row - M.opts.context_lines)
    local after_end = math.min(vim.api.nvim_buf_line_count(range.bufnr), range.end_row + M.opts.context_lines + 1)
    local before = vim.api.nvim_buf_get_lines(range.bufnr, before_start, range.start_row, false)
    local after = vim.api.nvim_buf_get_lines(range.bufnr, range.end_row + 1, after_end, false)
    return table.concat(before, "\n"), table.concat(after, "\n")
end

function M.get_visual_selection()
    local range, err = visual_range()
    if not range then
        return nil, nil, err
    end
    local selected = read_selection(range)
    if not selected then
        return nil, nil, "Selection is empty"
    end
    return selected, range, nil
end

function M.debug_selection()
    local selected, range, err = M.get_visual_selection()
    if not selected then
        log(err or "No selection", vim.log.levels.WARN)
        return
    end
    local file = vim.api.nvim_buf_get_name(range.bufnr)
    log("Selected in " .. (file == "" and "[No Name]" or file) .. "\n" .. selected, vim.log.levels.INFO)
end

local function make_prompt(user_prompt, selected, range)
    local bufnr = range and range.bufnr or vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(bufnr)
    local file_label = file == "" and "[No Name]" or file
    local before, after
    local has_selection = selected ~= nil and selected ~= ""
    if has_selection then
        before, after = range_context(range)
    else
        before, after = cursor_context()
    end
    local mode_hint = M.mode == "ask" and "Provide a direct, clear explanation." or "Return only the rewritten text for replacement."
    local selected_header = has_selection and "Selected text:" or "No selection found; using current context only."
    local selected_block = has_selection and table.concat({ "Selected text:\n```", selected, "```" }, "\n") or "Selected text: [none]"
    local context_prefix = has_selection and "Cursor context around selection:\n```" or "Cursor context:\n```"
    local project_hint = "If needed, infer related files from this project path and keep suggestions grounded to this workspace."
    return table.concat({
        "Novim request:",
        "Mode: " .. M.mode,
        "Instruction: " .. user_prompt,
        "File: " .. file_label,
        "Filetype: " .. (vim.bo[bufnr].filetype or "unknown"),
        "Mode hint: " .. mode_hint,
        selected_header,
        selected_block,
        context_prefix,
        before,
        "```",
        "Context after:\n```",
        after,
        "```",
        "Project note: " .. project_hint,
    }, "\n")
end

local function close_panel()
    if M._panel.win and vim.api.nvim_win_is_valid(M._panel.win) then
        pcall(vim.api.nvim_win_close, M._panel.win, true)
    end
    if M._panel.buf and vim.api.nvim_buf_is_valid(M._panel.buf) then
        pcall(vim.api.nvim_buf_delete, M._panel.buf, { force = true })
    end
    M._panel.win = nil
    M._panel.buf = nil
    M._panel.prev_win = nil
    M._panel.anchor_win = nil
end

local function panel_is_open()
    return M._panel.win ~= nil and vim.api.nvim_win_is_valid(M._panel.win)
end

local function focus_output_window()
    if not panel_is_open() then
        return false
    end
    local current = vim.api.nvim_get_current_win()
    if current ~= M._panel.win then
        M._panel.prev_win = current
        vim.api.nvim_set_current_win(M._panel.win)
    end
    return true
end

local function return_to_previous_window()
    if M._panel.prev_win and vim.api.nvim_win_is_valid(M._panel.prev_win) then
        vim.api.nvim_set_current_win(M._panel.prev_win)
        return true
    end

    if M._prompt.win and vim.api.nvim_win_is_valid(M._prompt.win) then
        vim.api.nvim_set_current_win(M._prompt.win)
        return true
    end

    return false
end

local function prompt_title()
    return string.format(
        "Novim • %s %s",
        M.mode:upper(),
        M._spinner.icon
    )
end

local function close_prompt()
    close_panel()
    if M._spinner.timer and not M._spinner.timer:is_closing() then
        pcall(function()
            M._spinner.timer:stop()
            M._spinner.timer:close()
        end)
    end
    M._spinner.timer = nil
    M._spinner.running = false
    M._spinner.icon = ""
    if M._prompt.win and vim.api.nvim_win_is_valid(M._prompt.win) then
        pcall(vim.api.nvim_win_close, M._prompt.win, true)
    end
    if M._prompt.buf and vim.api.nvim_buf_is_valid(M._prompt.buf) then
        pcall(vim.api.nvim_buf_delete, M._prompt.buf, { force = true })
    end
    M._prompt.win = nil
    M._prompt.buf = nil
    M._prompt.selected = nil
    M._prompt.range = nil
    M._prompt.anchor_win = nil
end

local function refresh_prompt_title()
    if M._prompt.buf and vim.api.nvim_buf_is_valid(M._prompt.buf) then
        local lines = vim.api.nvim_buf_get_lines(M._prompt.buf, 0, 2, false)
        if #lines == 0 then
            pcall(vim.api.nvim_buf_set_lines, M._prompt.buf, 0, -1, false, { prompt_title(), "> " })
            return
        end
        pcall(vim.api.nvim_buf_set_lines, M._prompt.buf, 0, 1, false, { prompt_title() })
    end
end

local function stop_spinner()
    if M._spinner.timer then
        if not M._spinner.timer:is_closing() then
            pcall(function()
                M._spinner.timer:stop()
                M._spinner.timer:close()
            end)
        end
        M._spinner.timer = nil
    end
    M._spinner.running = false
    M._spinner.icon = ""
    refresh_prompt_title()
end

local function start_spinner()
    stop_spinner()
    M._spinner.running = true
    M._spinner.timer = vim.uv.new_timer()
    M._spinner.timer:start(0, 130, vim.schedule_wrap(function()
        if not (M._prompt.buf and vim.api.nvim_buf_is_valid(M._prompt.buf)) then
            stop_spinner()
            return
        end
        M._spinner.frame = (M._spinner.frame % #spinner_frames) + 1
        M._spinner.icon = "[" .. spinner_frames[M._spinner.frame] .. "]"
        refresh_prompt_title()
    end))
end

local function send_codex_request(user_prompt, selected, range, request_mode, keep_prompt)
    request_mode = normalize_mode(request_mode or M.mode)
    local prompt = make_prompt(vim.trim(user_prompt), selected, range)
    local cmd = vim.deepcopy(M.opts.codex_cmd)
    table.insert(cmd, prompt)

    if M.opts.show_errors then
        log("Novim: sending to codex...")
    end
    start_spinner()

    vim.system(
        cmd,
        {
            timeout = M.opts.timeout_ms,
            text = true,
        },
        vim.schedule_wrap(function(result)
            stop_spinner()
            if result.code ~= 0 then
                log("codex failed: " .. (result.stderr ~= "" and result.stderr or result.stdout or "unknown error"), vim.log.levels.ERROR)
                return
            end

            local response = vim.trim(result.stdout or "")
            if response == "" then
                log("codex returned empty output", vim.log.levels.WARN)
                return
            end

            if range then
                M._last = {
                    response = response,
                    range = range,
                    bufnr = range.bufnr,
                }
            else
                M._last = nil
            end

            if request_mode == "ask" then
                open_output(response, M._prompt.win, request_mode)
                return
            end
            if not range then
                close_prompt()
                open_output(response, M._prompt.win, request_mode)
                return
            end

            if not keep_prompt then
                close_prompt()
            end
            apply_response(response)
            log("Novim: replaced selection")
        end)
    )
end

local function open_inline_prompt(selected, range)
    close_prompt()

    local anchor_win = vim.api.nvim_get_current_win()
    local ui = vim.api.nvim_list_uis()[1]
    local prompt_max = math.max(20, math.min(ui.width - 4, M.opts.prompt_max_width))
    local prompt_min = math.min(M.opts.prompt_min_width, prompt_max)
    local width = clamp(math.floor(ui.width * 0.55), prompt_min, prompt_max)
    local win = nil
    local buf = vim.api.nvim_create_buf(false, true)
    M._prompt = {
        buf = buf,
        win = nil,
        selected = selected,
        range = range,
        anchor_win = anchor_win,
    }

    vim.api.nvim_buf_set_name(buf, "novim-inline")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = "novim-inline"
    vim.bo[buf].complete = ""
    vim.bo[buf].omnifunc = ""
    vim.bo[buf].completefunc = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prompt_title(), "> " })

    local function submit_query()
        local raw = vim.api.nvim_buf_get_lines(buf, 1, 2, false)
        local query = vim.trim((raw[1] or ""):gsub("^>%s*", "", 1))
        if query == "" then
            log("Novim canceled", vim.log.levels.INFO)
            vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "> " })
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { 2, 2 })
                vim.cmd("startinsert")
            end
            return
        end

        local request_mode = M.mode
        local keep_prompt = request_mode == "ask"
        if not keep_prompt then
            close_prompt()
        end

        send_codex_request(query, selected, range, request_mode, keep_prompt)

        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "> " })
        end
        if keep_prompt then
            if M._prompt.win and vim.api.nvim_win_is_valid(M._prompt.win) then
                vim.api.nvim_set_current_win(M._prompt.win)
                vim.api.nvim_win_set_cursor(M._prompt.win, { 2, 2 })
                vim.cmd("startinsert")
            end
        end
    end

    win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = M.opts.prompt_border,
        row = math.max(1, ui.height - M.opts.prompt_row_offset),
        col = math.max(0, math.floor((ui.width - width) / 2)),
        width = width,
        height = 2,
        focusable = true,
        noautocmd = true,
    })
    M._prompt.win = win

    vim.api.nvim_win_set_option(win, "winblend", M.opts.prompt_blend)
    vim.api.nvim_win_set_option(win, "winhighlight", "Normal:NormalFloat,FloatBorder:NormalFloat")
    vim.api.nvim_win_set_option(win, "wrap", false)
    vim.api.nvim_win_set_option(win, "cursorline", false)
    vim.api.nvim_win_set_option(win, "number", false)
    vim.api.nvim_win_set_option(win, "relativenumber", false)
    vim.api.nvim_win_set_option(win, "signcolumn", "no")
    vim.api.nvim_win_set_option(win, "list", false)
    vim.api.nvim_win_set_option(win, "cursorcolumn", false)
    vim.api.nvim_win_set_option(win, "winfixwidth", true)

    vim.api.nvim_win_set_cursor(win, { 2, 2 })

    vim.keymap.set("i", "<F2>", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<F2>", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<A-m>", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<A-m>", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<leader>nm", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<leader>nm", function()
        M.toggle_mode()
        refresh_prompt_title()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<F3>", function()
        M.toggle_output_panel()
        return
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<F3>", function()
        M.toggle_output_panel()
        return
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<A-o>", function()
        M.toggle_output_panel()
        return
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<A-o>", function()
        M.toggle_output_panel()
        return
    end, { buffer = buf, noremap = true, nowait = true, silent = true })

    vim.keymap.set("i", "<Esc>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<C-[>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<C-[>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<C-c>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<C-c>", function()
        close_prompt()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("i", "<CR>", function()
        submit_query()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<CR>", function()
        submit_query()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })

    vim.cmd("startinsert")
end

function M.set_mode(mode)
    M.mode = normalize_mode(mode)
    log("Novim mode: " .. M.mode)
    refresh_prompt_title()
end

local function apply_response(response)
    if not M._last or not M._last.range or not M._last.bufnr or not vim.api.nvim_buf_is_valid(M._last.bufnr) then
        log("No valid target to apply response", vim.log.levels.WARN)
        return
    end
    local range = M._last.range
    local response_lines = sanitize_for_replacement(response)
    if #response_lines == 0 then
        log("No text to apply", vim.log.levels.WARN)
        return
    end

    if range.linewise then
        vim.api.nvim_buf_set_lines(M._last.bufnr, range.start_row, range.end_row + 1, false, response_lines)
        return
    end

    local start_row, start_col = range.start_row, range.start_col
    local end_row = range.end_row
    local end_col = range.end_col
    local endline = vim.api.nvim_buf_get_lines(M._last.bufnr, end_row, end_row + 1, false)[1] or ""
    local line_end = math.min(#endline, math.max(0, end_col + 1))
    local actual_end_col = end_col == 0 and #endline or line_end
    vim.api.nvim_buf_set_text(M._last.bufnr, start_row, start_col, end_row, actual_end_col, response_lines)
end

local function decorate_output_lines(response, request_mode)
    local mode = normalize_mode(request_mode or M.mode):upper()
    local body = sanitize_lines(response)
    if #body == 0 then
        return {
            "Novim " .. mode .. " answer",
            string.rep("-", 30),
            "No output.",
            "",
        }
    end

    local output_lines = {
        "Novim " .. mode .. " answer",
        string.rep("-", 30),
        "",
    }
    vim.list_extend(output_lines, body)
    return output_lines
end

open_output = function(response, anchor_win, request_mode)
    close_panel()

    local lines = sanitize_lines(response)
    M._panel.last_lines = lines
    local output_lines = sanitize_lines(response)
    if #output_lines == 0 then
        output_lines = { "No output." }
    end
    output_lines = decorate_output_lines(response, request_mode)
    if #output_lines == 0 then
        output_lines = { "Novim answer (empty)", "No output." }
    end

    local previous_win = vim.api.nvim_get_current_win()
    local split_anchor = (M._prompt.anchor_win and vim.api.nvim_win_is_valid(M._prompt.anchor_win))
        and M._prompt.anchor_win
        or (M._panel.anchor_win and vim.api.nvim_win_is_valid(M._panel.anchor_win))
        and M._panel.anchor_win
        or (anchor_win and vim.api.nvim_win_is_valid(anchor_win))
        or previous_win

    if vim.api.nvim_win_is_valid(split_anchor) then
        pcall(vim.api.nvim_set_current_win, split_anchor)
    end

    vim.cmd(M.opts.output_split)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, false)
    local output_max = math.max(20, math.min(vim.o.columns - 1, M.opts.output_max_width))
    local output_min = math.min(M.opts.output_min_width, output_max)
    local requested_width = math.floor(vim.o.columns * M.opts.output_ratio)
    requested_width = clamp(requested_width, output_min, output_max)
    M._panel = {
        win = win,
        buf = buf,
        last_lines = M._panel.last_lines,
        prev_win = previous_win,
        anchor_win = split_anchor,
    }
    M._panel.last_lines = lines

    vim.api.nvim_buf_set_name(buf, "novim-output")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local ok, err = pcall(function()
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        vim.api.nvim_set_option_value("readonly", false, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, output_lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        vim.api.nvim_set_option_value("readonly", true, { buf = buf })
    end)
    if not ok then
        log("Novim output write failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        close_panel()
        return
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, requested_width)
    vim.api.nvim_win_set_option(win, "wrap", true)
    vim.api.nvim_win_set_option(win, "winblend", 10)
    vim.api.nvim_win_set_option(win, "linebreak", true)
    vim.api.nvim_win_set_option(win, "breakindent", true)
    vim.api.nvim_win_set_option(win, "showbreak", "↳ ")
    vim.api.nvim_win_set_option(win, "scrollbind", false)
    vim.api.nvim_win_set_option(win, "number", false)
    vim.api.nvim_win_set_option(win, "relativenumber", false)
    vim.api.nvim_win_set_option(win, "signcolumn", "no")
    vim.api.nvim_win_set_option(win, "list", false)
    vim.api.nvim_win_set_option(win, "cursorcolumn", false)

    vim.keymap.set("n", "q", function()
        close_panel()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        close_panel()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<C-[>", function()
        close_panel()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<F3>", function()
        close_panel()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })
    vim.keymap.set("n", "<A-o>", function()
        close_panel()
    end, { buffer = buf, noremap = true, nowait = true, silent = true })

    if previous_win and vim.api.nvim_win_is_valid(previous_win) then
        pcall(vim.api.nvim_set_current_win, previous_win)
    end
end

function M.focus_output_window()
    if not focus_output_window() then
        log("No Novim output panel is open", vim.log.levels.WARN)
    end
end

function M.toggle_output_panel()
    if panel_is_open() then
        close_panel()
        return
    end
    if not M._panel.last_lines then
        log("No Novim output to toggle", vim.log.levels.WARN)
        return
    end
    open_output(table.concat(M._panel.last_lines, "\n"), nil, M.mode)
end

function M.toggle_inline_prompt()
    if (M._prompt.win and vim.api.nvim_win_is_valid(M._prompt.win)) or panel_is_open() then
        close_prompt()
        return
    end

    local selected, range, err = M.get_visual_selection()
    if not selected then
        selected = nil
        range = nil
    end

    if vim.fn.executable(M.opts.codex_cmd[1]) ~= 1 then
        log("`codex` not found. Make sure it is installed and in PATH.", vim.log.levels.ERROR)
        return
    end
    open_inline_prompt(selected, range)
end

function M.apply_last_response()
    if not M._last or not M._last.response then
        log("No response saved", vim.log.levels.WARN)
        return
    end
    apply_response(M._last.response)
end

function M.close_output_panel()
    close_prompt()
    close_panel()
end

function M.prompt_and_send()
    M.toggle_inline_prompt()
end

function M.visual_or_context()
    local selected, range, err = M.get_visual_selection()
    return {
        selected = selected,
        range = range,
        has_selection = selected ~= nil,
        error = err,
    }
end

return M
