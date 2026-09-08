if vim.g.loaded_nvim_lsp_tagbar then
  return
end
vim.g.loaded_nvim_lsp_tagbar = true

require('nvim-lsp-tagbar').setup()

vim.api.nvim_create_user_command('LspTagbarToggle', function()
  require('nvim-lsp-tagbar').toggle()
end, { desc = 'Toggle the LSP symbol tagbar' })

vim.api.nvim_create_user_command('LspTagbarDebug', function()
  require('nvim-lsp-tagbar').debug()
end, { desc = 'Print tagbar internal state for debugging' })
