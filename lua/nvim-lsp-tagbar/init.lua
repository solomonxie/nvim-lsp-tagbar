-- Minimal LSP-based tagbar: bottom bar, nested by real hierarchy (or by
-- containerName when a server only returns a flat symbol list), filtered
-- to configured kinds. No ctags, no plugin dependency.

local config = require('nvim-lsp-tagbar.config')

local M = {}

M.win, M.buf, M.src_win, M.src_buf = nil, nil, nil, nil
M._keymap = nil
M._configured = false

local CURSOR_NS = vim.api.nvim_create_namespace('lsptagbar_cursor')

local function is_document_symbol(list)
    return list[1] and list[1].selectionRange ~= nil
end

-- SymbolInformation[] (flat, containerName-linked) -> tree via containerName
local function nest_by_container_name(list)
    local by_name, roots = {}, {}
    for _, s in ipairs(list) do
        s.children = {}
        by_name[s.name] = by_name[s.name] or s
    end
    for _, s in ipairs(list) do
        local parent = s.containerName and by_name[s.containerName]
        if parent and parent ~= s then
            table.insert(parent.children, s)
        else
            table.insert(roots, s)
        end
    end
    return roots
end

local function jump_pos(s)
    if s.selectionRange then
        return s.selectionRange.start
    end
    return s.location.range.start
end

-- A real definition's `range` spans its whole signature/body; a mere
-- reference (e.g. an import) has no body, so `range` collapses to just
-- the name, same as `selectionRange`.
local function is_bare_reference(s)
    local r, sel = s.range, s.selectionRange
    if not (r and sel) then
        return false
    end
    return r.start.line == sel.start.line and r.start.character == sel.start.character
        and r['end'].line == sel['end'].line and r['end'].character == sel['end'].character
end

-- Flat SymbolInformation servers (e.g. pylsp) have no range/selectionRange
-- gap to check, so ask treesitter whether the position sits inside an
-- import-like node instead.
local function is_import_node(pos)
    if not (M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf)) then
        return false
    end
    local ok, parser = pcall(vim.treesitter.get_parser, M.src_buf, vim.bo[M.src_buf].filetype)
    if not ok or not parser then
        return false
    end
    local root = parser:parse()[1]:root()
    local node = root:named_descendant_for_range(pos.line, pos.character, pos.line, pos.character)
    while node do
        if node:type():find('import', 1, true) then
            return true
        end
        node = node:parent()
    end
    return false
end

local function build_lines(list, depth, parent_idx, lines, jumps)
    for _, s in ipairs(list) do
        local label = config.options.kinds[s.kind]
        local kept = label and not is_bare_reference(s) and not is_import_node(jump_pos(s))
        local child_parent_idx = parent_idx
        if kept then
            table.insert(lines, string.rep('  ', depth) .. label .. ' ' .. s.name)
            table.insert(jumps, { pos = jump_pos(s), range = s.range or s.location.range, parent = parent_idx })
            child_parent_idx = #lines
        end
        if s.children and #s.children > 0 then
            -- kept nodes recurse one deeper only if this node itself was
            -- shown; filtered-out containers still walk their children at
            -- the same depth so a stray Function under an unlisted kind
            -- (e.g. Namespace) isn't lost. Either way children's parent
            -- link points at the nearest kept ancestor, not a filtered one.
            build_lines(s.children, kept and (depth + 1) or depth, child_parent_idx, lines, jumps)
        end
    end
end

function M.close()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        vim.api.nvim_win_close(M.win, true)
    end
    M.win, M.buf = nil, nil
end

local function goto_parent()
    local jumps = vim.b[M.buf].jumps
    local entry = jumps[vim.api.nvim_win_get_cursor(0)[1]]
    local parent = entry and entry.parent
    if not parent then
        return
    end
    vim.api.nvim_win_set_cursor(0, { parent, 0 })
end

local function goto_jump()
    local jumps = vim.b[M.buf].jumps
    local entry = jumps[vim.api.nvim_win_get_cursor(0)[1]]
    if not entry then
        return
    end
    local src_win = M.src_win
    M.close()
    if src_win and vim.api.nvim_win_is_valid(src_win) then
        vim.api.nvim_set_current_win(src_win)
    end
    vim.api.nvim_win_set_cursor(0, { entry.pos.line + 1, entry.pos.character })
    vim.cmd('normal! zz')
end

-- Deepest symbol whose range contains lnum0 (0-indexed): children are
-- listed right after their parent and their ranges nest inside it, so the
-- last containing match found by a plain left-to-right scan is the most
-- specific one.
local function line_for_cursor(jumps, lnum0)
    local best
    for i, entry in ipairs(jumps) do
        local r = entry.range
        if r and lnum0 >= r.start.line and lnum0 <= r['end'].line then
            best = i
        end
    end
    return best
end

function M.sync_cursor()
    if not (M.win and vim.api.nvim_win_is_valid(M.win) and M.buf and vim.api.nvim_buf_is_valid(M.buf)
            and M.src_win and vim.api.nvim_win_is_valid(M.src_win)) then
        return
    end
    local jumps = vim.b[M.buf].jumps
    if not jumps or vim.tbl_isempty(jumps) then
        return
    end
    local idx = line_for_cursor(jumps, vim.api.nvim_win_get_cursor(M.src_win)[1] - 1)
    if not idx then
        return
    end
    vim.api.nvim_buf_clear_namespace(M.buf, CURSOR_NS, 0, -1)
    vim.api.nvim_buf_add_highlight(M.buf, CURSOR_NS, 'CursorLine', idx - 1, 0, -1)
    vim.api.nvim_win_set_cursor(M.win, { idx, 0 })
end

local function render(result, empty_msg)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
    end
    local lines, jumps = {}, {}
    if not result or vim.tbl_isempty(result) then
        lines = { empty_msg or 'No symbols' }
    else
        local tree = is_document_symbol(result) and result or nest_by_container_name(result)
        build_lines(tree, 0, nil, lines, jumps)
        if vim.tbl_isempty(lines) then
            lines = { 'No matching symbols' }
        end
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
end

function M.refresh()
    if not (M.buf and M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf)) then
        return
    end
    if not next(vim.lsp.get_clients({ bufnr = M.src_buf, method = 'textDocument/documentSymbol' })) then
        render(nil, 'No LSP attached yet')
        return
    end
    render(nil, 'Loading symbols...')
    local params = { textDocument = vim.lsp.util.make_text_document_params(M.src_buf) }
    vim.lsp.buf_request(M.src_buf, 'textDocument/documentSymbol', params, function(err, result)
        render(err and nil or result)
        M.sync_cursor()
    end)
end

function M.open()
    M.src_win = vim.api.nvim_get_current_win()
    M.src_buf = vim.api.nvim_get_current_buf()

    vim.cmd('botright ' .. config.options.height .. ' split')
    M.win = vim.api.nvim_get_current_win()
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(M.win, M.buf)

    vim.bo[M.buf].buftype = 'nofile'
    vim.bo[M.buf].bufhidden = 'wipe'
    vim.bo[M.buf].filetype = 'lsptagbar'
    vim.wo[M.win].number = false
    vim.wo[M.win].wrap = false
    -- Without this, any later window-layout change ('<C-w>=', a new split,
    -- closing a window) re-equalizes every window and the bar loses its
    -- configured height.
    vim.wo[M.win].winfixheight = true

    local opts = { buffer = M.buf, silent = true }
    vim.keymap.set('n', '<CR>', goto_jump, opts)
    vim.keymap.set('n', 'p', goto_parent, opts)
    vim.keymap.set('n', 'q', M.close, opts)
    vim.keymap.set('n', '<Esc>', M.close, opts)

    M.refresh()
end

function M.toggle()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        M.close()
    else
        M.open()
    end
end

-- Run with the bar open, cursor inside a function, to see which assumption
-- (win/buf validity, src_buf match, jumps populated, range present) is
-- failing.
function M.debug()
    print('win valid:', M.win and vim.api.nvim_win_is_valid(M.win))
    print('buf valid:', M.buf and vim.api.nvim_buf_is_valid(M.buf))
    print('src_buf:', M.src_buf, 'current buf:', vim.api.nvim_get_current_buf())
    local jumps = M.buf and vim.b[M.buf] and vim.b[M.buf].jumps
    print('jumps count:', jumps and #jumps or 'nil')
    if jumps and jumps[1] then
        print('first entry:', vim.inspect(jumps[1]))
    end
end

-- Slow LSP servers may still be attaching when the bar first opens.
vim.api.nvim_create_autocmd('LspAttach', {
    callback = function()
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            M.refresh()
        end
    end,
})

vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    callback = function(ev)
        if ev.buf == M.src_buf then
            M.sync_cursor()
        end
    end,
})

function M.setup(opts)
    M._configured = true
    config.setup(opts)
    if M._keymap then
        pcall(vim.keymap.del, 'n', M._keymap)
        M._keymap = nil
    end
    if config.options.keymap then
        vim.keymap.set('n', config.options.keymap, M.toggle, { silent = true, desc = 'Toggle LSP symbol tagbar' })
        M._keymap = config.options.keymap
    end
end

return M
