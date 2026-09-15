local M = {}

M.defaults = {
    -- normal-mode mapping to toggle the bar; set to false to disable
    keymap = 'ft',
    -- bottom split height
    height = 20,
    -- filetypes whose outline comes from '#' headings instead of LSP symbols
    heading_filetypes = { 'markdown', 'rmd', 'quarto', 'vimwiki' },
    -- heading label shown in the bar; %d is the heading level
    heading_label = '[H%d]',
    -- LSP SymbolKind -> label shown in the bar
    kinds = {
        [5] = '[C]',   -- Class
        [6] = '[M]',   -- Method
        [9] = '[M]',   -- Constructor
        [12] = '[F]',  -- Function
        [14] = '[K]',  -- Constant
        [23] = '[S]',  -- Struct
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
    -- deep_extend merges list-like tables by index, which would leave
    -- stale defaults past the end of a shorter user list.
    if opts and opts.heading_filetypes then
        M.options.heading_filetypes = opts.heading_filetypes
    end
end

return M
