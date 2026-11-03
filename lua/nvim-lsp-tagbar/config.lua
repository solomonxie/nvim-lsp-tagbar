local M = {}

M.defaults = {
    -- normal-mode mapping to toggle the bar; set to false to disable
    keymap = 'ft',
    -- where the bar opens: 'bottom' (a split of `height` lines), 'left' or 'right' (`width` columns)
    position = 'bottom',
    -- bottom split height
    height = 20,
    -- left / right split width
    width = 40,
    -- moving the cursor in the bar shows that symbol in the source window, keeping focus in the bar
    auto_preview = false,
    -- close the bar as soon as focus moves to another window
    auto_close = true,
    -- the view the bar starts in: 'files', 'changed', 'symbols', 'markers' or 'changes'; `]]` / `[[` step through them
    default_view = 'files',
    -- with auto_close off, the bar follows the buffer you switch to (and the file tree reveals it)
    follow = true,
    -- file tree view
    files = {
        -- dotfiles; `I` in the bar toggles
        show_hidden = false,
        -- Lua patterns on the name of entries never listed
        ignore = { '%.pyc$', '%.sw[po]$', '^__pycache__$', '^node_modules$' },
        -- opening a file from the tree closes the bar (`go` previews it and keeps the bar)
        close_on_open = true,
        -- re-read the tree this often while it's shown (skipped while you move in it); 0 disables
        refresh_ms = 10000,
        -- color names by git state vs git_base, grey out git-ignored entries
        git = true,
        arrows = { closed = '▸', open = '▾' },
        -- function(path) -> path, to map a buffer's path before it's revealed in the tree
        path = nil,
    },
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
    -- list git hunks (buffer vs git_base) as entries, and in the changes-only view
    git_hunks = true,
    -- ref or function returning one; nil follows g:git_diff_base, else HEAD
    git_base = nil,
    git_hunk_labels = { add = '[+]', change = '[~]', delete = '[-]' },
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
    if opts and opts.files and opts.files.ignore then
        M.options.files.ignore = opts.files.ignore
    end
end

return M
