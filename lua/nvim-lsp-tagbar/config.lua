local M = {}

M.defaults = {
    -- normal-mode mapping to toggle the bar; set to false to disable
    keymap = 'ft',
    -- where the bar opens: 'bottom' (a split of `height` lines) or 'right' (`width` columns)
    position = 'bottom',
    -- bottom split height
    height = 20,
    -- right split width
    width = 40,
    -- moving the cursor in the bar shows that symbol in the source window, keeping focus in the bar
    auto_preview = false,
    -- `o` on a tag lists its callers under it (LSP call hierarchy); callers in files matching these
    -- Lua patterns are left out unless callers_include_tests is set
    callers_include_tests = false,
    callers_test_patterns = { '/tests?/', '/test_[^/]*$', '_test%.[^/]*$', '/conftest%.py$', '%.spec%.', '%.test%.' },
    -- filetypes whose outline comes from '#' headings instead of LSP symbols
    heading_filetypes = { 'markdown', 'rmd', 'quarto', 'vimwiki' },
    -- heading label shown in the bar; %d is the heading level
    heading_label = '[H%d]',
    -- filetype -> treesitter queries adding entries the LSP misses;
    -- each { label = '[U]', query = [[ ... @name ... @scope ]] }
    queries = {},
    -- filetype -> Lua patterns for hand-written entries, '*' for every other filetype;
    -- the first capture is the text shown, e.g. `# @@ setup db` -> `[@] setup db`
    markers = { ['*'] = { '@@%s*(.-)%s*$' } },
    marker_label = '[@]',
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
    -- stale defaults past the end of a shorter user list, and would splice
    -- a user's queries together with any shipped later.
    for _, key in ipairs({ 'heading_filetypes', 'queries', 'markers', 'callers_test_patterns' }) do
        if opts and opts[key] then
            M.options[key] = opts[key]
        end
    end
end

return M
