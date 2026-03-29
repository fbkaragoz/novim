-- plugin/novim.lua
if vim.g.loaded_novim then
  return
end
vim.g.loaded_novim = 1

-- Highlight groups (defaults, user can override)
local function set_hl(name, opts)
  if vim.fn.hlexists(name) == 0 or vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    vim.api.nvim_set_hl(0, name, opts)
  end
end

set_hl("NovimUser", { fg = "#7a7a7a", italic = true })
set_hl("NovimAI", { fg = "#d4d4d4" })
set_hl("NovimSystem", { fg = "#555555", italic = true })
set_hl("NovimInputPrefix", { fg = "#888888", bold = true })
set_hl("NovimContext", { fg = "#5599dd" })
set_hl("NovimWinbarTitle", { fg = "#aaaaaa", bold = true })
set_hl("NovimWinbarState", { fg = "#88bb88", bold = true })
set_hl("NovimDiffRemove", { fg = "#ff6b6b", strikethrough = true })
set_hl("NovimDiffAdd", { fg = "#69db7c" })
set_hl("NovimDiffAddSign", { fg = "#69db7c", bold = true })

-- User commands
vim.api.nvim_create_user_command("NovimToggle", function()
  require("novim").toggle()
end, { desc = "Novim: toggle sidebar" })

vim.api.nvim_create_user_command("NovimSetup", function(opts)
  require("novim").setup()
end, { desc = "Novim: run setup with defaults" })
