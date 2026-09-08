if vim.g.loaded_nvim_lsp_tagbar then
  return
end
vim.g.loaded_nvim_lsp_tagbar = true

-- Neovim auto-sources every plugin/ file on runtimepath once, right after
-- the user's whole config finishes -- later than any explicit setup() call
-- the user's own config already made (e.g. via luafile). Skip the default
-- setup() here if that already happened, so it doesn't clobber it back.
local tagbar = require('nvim-lsp-tagbar')
if not tagbar._configured then
  tagbar.setup()
end

vim.api.nvim_create_user_command('LspTagbarToggle', function()
  require('nvim-lsp-tagbar').toggle()
end, { desc = 'Toggle the LSP symbol tagbar' })

vim.api.nvim_create_user_command('LspTagbarDebug', function()
  require('nvim-lsp-tagbar').debug()
end, { desc = 'Print tagbar internal state for debugging' })
