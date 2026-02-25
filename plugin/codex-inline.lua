if vim.g.loaded_novim then
    return
end
vim.g.loaded_novim = 1

vim.keymap.set({ "n", "x", "i" }, "<leader>nm", function()
    require("novim").toggle_mode()
end, { desc = "Novim: toggle ask/work mode" })
vim.keymap.set({ "n", "x", "i" }, "<A-m>", function()
    require("novim").toggle_mode()
end, { desc = "Novim: toggle ask/work mode" })

vim.keymap.set({ "n", "x" }, "<leader>na", function()
    require("novim").set_mode("ask")
end, { desc = "Novim: set ask mode" })
vim.keymap.set({ "n", "x" }, "<leader>nw", function()
    require("novim").set_mode("work")
end, { desc = "Novim: set work mode" })

vim.keymap.set("x", "<leader>ni", function()
    require("novim").prompt_and_send()
end, { desc = "Novim: prompt for selected text" })

vim.keymap.set({ "n", "x", "i" }, "<A-x>", function()
    require("novim").toggle_inline_prompt()
end, { desc = "Novim: toggle inline prompt" })

vim.keymap.set({ "n", "i" }, "<leader>no", function()
    require("novim").toggle_output_panel()
end, { desc = "Novim: toggle answer output panel" })
vim.keymap.set({ "n", "i" }, "<A-o>", function()
    require("novim").toggle_output_panel()
end, { desc = "Novim: toggle answer output panel" })

vim.keymap.set({ "n", "i" }, "<leader>nf", function()
    require("novim").focus_output_window()
end, { desc = "Novim: focus answer output panel" })

vim.api.nvim_create_user_command("NovimDebug", function()
    require("novim").debug_selection()
end, {})

vim.api.nvim_create_user_command("NovimInline", function()
    require("novim").prompt_and_send()
end, { range = true })

vim.api.nvim_create_user_command("NovimModeAsk", function()
    require("novim").set_mode("ask")
end, {})

vim.api.nvim_create_user_command("NovimModeWork", function()
    require("novim").set_mode("work")
end, {})

vim.api.nvim_create_user_command("NovimModeToggle", function()
    local m = require("novim").get_mode()
    if m == "ask" then
        require("novim").set_mode("work")
    else
        require("novim").set_mode("ask")
    end
end, {})

vim.api.nvim_create_user_command("NovimApply", function()
    require("novim").apply_last_response()
end, {})

vim.api.nvim_create_user_command("NovimClose", function()
    require("novim").close_output_panel()
end, {})

vim.api.nvim_create_user_command("NovimOutputToggle", function()
    require("novim").toggle_output_panel()
end, {})

vim.api.nvim_create_user_command("NovimOutputFocus", function()
    require("novim").focus_output_window()
end, {})

vim.api.nvim_create_user_command("NovimToggle", function()
    require("novim").toggle_inline_prompt()
end, {})

vim.api.nvim_create_user_command("CodexInlineDebug", function()
    require("novim").debug_selection()
end, {})
