local M = {}

M.defaults = {
    -- normal-mode mapping to toggle the bar; set to false to disable
    keymap = 'ft',
    -- bottom split height
    height = 20,
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
end

return M
