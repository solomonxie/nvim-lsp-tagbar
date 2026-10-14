-- Minimal LSP-based tagbar: bottom or right bar, nested by real hierarchy (or by
-- containerName when a server only returns a flat symbol list), filtered
-- to configured kinds. No ctags, no plugin dependency.

local config = require('nvim-lsp-tagbar.config')
local markup = require('nvim-lsp-tagbar.markup')
local queries = require('nvim-lsp-tagbar.queries')
local callers = require('nvim-lsp-tagbar.callers')

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
        -- markup heading nodes carry their own label; the reference/import
        -- filters only make sense for LSP symbols.
        local label = s.label or config.options.kinds[s.kind]
        local kept = label and (s.label ~= nil
            or (not is_bare_reference(s) and not is_import_node(jump_pos(s))))
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
    -- undo a caller preview left in the source window
    if M.src_win and vim.api.nvim_win_is_valid(M.src_win) and M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf)
            and vim.api.nvim_win_get_buf(M.src_win) ~= M.src_buf then
        vim.api.nvim_win_set_buf(M.src_win, M.src_buf)
    end
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
    if entry.uri then
        vim.cmd('edit ' .. vim.fn.fnameescape(vim.uri_to_fname(entry.uri)))
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

-- Show the symbol under the bar's cursor in the source window without leaving the bar.
-- Setting another window's cursor fires no CursorMoved there, so this doesn't feed back into sync_cursor.
local function preview()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf) and M.src_win and vim.api.nvim_win_is_valid(M.src_win)) then
        return
    end
    local entry = (vim.b[M.buf].jumps or {})[vim.api.nvim_win_get_cursor(0)[1]]
    if not entry then
        return
    end
    -- a caller in another file is shown in the source window too; the bar stays on M.src_buf, and the
    -- window goes back to it on the next line from this file or when the bar closes
    local buf = M.src_buf
    if entry.uri and entry.uri ~= vim.uri_from_bufnr(M.src_buf) then
        buf = vim.uri_to_bufnr(entry.uri)
        vim.fn.bufload(buf)
        vim.bo[buf].buflisted = true
    end
    if vim.api.nvim_win_get_buf(M.src_win) ~= buf then
        vim.api.nvim_win_set_buf(M.src_win, buf)
    end
    vim.api.nvim_win_call(M.src_win, function()
        vim.api.nvim_win_set_cursor(0, { entry.pos.line + 1, entry.pos.character })
        vim.cmd('normal! zvzz')
    end)
end

-- Caller lines (from `o`) sit right under their tag or caller line, one level deeper each.
local function caller_depth(entry)
    return entry and entry.cdepth or 0
end

-- Lines were inserted (n > 0) or removed (n < 0) after line `at`: keep `p`'s parent links pointing at the same tags.
local function shift_parents(jumps, at, n)
    for _, e in ipairs(jumps) do
        if e.parent and e.parent > at then
            e.parent = e.parent + n
        end
    end
end

local function collapse(jumps, lnum)
    local d, last = caller_depth(jumps[lnum]), lnum
    while jumps[last + 1] and jumps[last + 1].cdepth and jumps[last + 1].cdepth > d do
        last = last + 1
    end
    if last == lnum then
        return false
    end
    for _ = lnum + 1, last do
        table.remove(jumps, lnum + 1)
    end
    shift_parents(jumps, lnum, lnum - last)
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, lnum, last, false, {})
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
    return true
end

-- Call hierarchy item for a bar line: a caller line carries it; a tag is looked up at its name.
local function item_for(client, lnum, entry)
    if entry.item then
        return entry.item
    end
    local name = vim.api.nvim_buf_get_lines(M.buf, lnum - 1, lnum, false)[1]:match('%] (.+)$')
    local src_line = vim.api.nvim_buf_get_lines(M.src_buf, entry.pos.line, entry.pos.line + 1, false)[1] or ''
    -- flat-list servers (pylsp) point at the `def`, not the name
    local col = name and src_line:find(name, entry.pos.character + 1, true)
    return callers.prepare(client, M.src_buf, { line = entry.pos.line, character = col and (col - 1) or entry.pos.character })
end

-- Insert lnum's callers under it; follow a chain of single callers down without asking.
local function expand(client, jumps, lnum, guard)
    local entry = jumps[lnum]
    local item = item_for(client, lnum, entry)
    if not item then
        vim.notify('nvim-lsp-tagbar: no call hierarchy for this symbol', vim.log.levels.WARN)
        return
    end
    local indent = vim.api.nvim_buf_get_lines(M.buf, lnum - 1, lnum, false)[1]:match('^%s*') .. '  '
    local found, hidden = callers.of(client, M.src_buf, item)
    -- the requests above let other events run; give up if the bar was closed or re-rendered meanwhile
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) or vim.b[M.buf].jumps[lnum] == nil
            or not vim.deep_equal(vim.b[M.buf].jumps[lnum].pos, entry.pos) then
        return
    end
    jumps = vim.b[M.buf].jumps
    local lines, new = {}, {}
    for _, c in ipairs(found) do
        local site = c.site or c.item.selectionRange.start
        lines[#lines + 1] = ('%s↑ %s  %s:%d%s%s'):format(indent, c.item.name, callers.short(c.item.uri), site.line + 1,
            c.count > 1 and (' (%d calls)'):format(c.count) or '', c.via and (' (via ' .. c.via .. ')') or '')
        new[#new + 1] = { pos = site, uri = c.item.uri, item = c.item, cdepth = caller_depth(entry) + 1 }
    end
    if #found == 0 then
        lines[1] = indent .. (hidden > 0 and ('(only called from tests: %d)'):format(hidden) or '(no callers)')
        new[1] = { pos = entry.pos, uri = entry.uri, cdepth = caller_depth(entry) + 1, leaf = true }
    elseif hidden > 0 then
        lines[#lines + 1] = indent .. ('(+%d in tests)'):format(hidden)
        new[#new + 1] = { pos = entry.pos, uri = entry.uri, cdepth = caller_depth(entry) + 1, leaf = true }
    end
    shift_parents(jumps, lnum, #new)
    for i, e in ipairs(new) do
        e.parent = lnum
        table.insert(jumps, lnum + i, e)
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, lnum, lnum, false, lines)
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
    if #found == 1 and (guard or 0) < 20 then
        expand(client, jumps, lnum + 1, (guard or 0) + 1)
    end
end

-- o: show / hide the callers of the tag (or caller) under the cursor, inline.
local function toggle_callers()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local jumps = vim.b[M.buf].jumps or {}
    local entry = jumps[lnum]
    if not entry or entry.leaf or collapse(jumps, lnum) then
        return
    end
    local client = callers.client(M.src_buf)
    if not client then
        vim.notify('nvim-lsp-tagbar: no LSP for this buffer supports call hierarchy', vim.log.levels.WARN)
        return
    end
    vim.api.nvim_echo({ { 'Finding callers...' } }, false, {})
    expand(client, jumps, lnum)
    vim.api.nvim_echo({ { '' } }, false, {})
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

local function symbol_range(s)
    return s.range or (s.location and s.location.range)
end

local function contains(outer, inner)
    return outer and (inner.start.line >= outer.start.line and inner['end'].line <= outer['end'].line)
end

-- Query-matched entries carry a range but no place in the server's tree.
-- Recursing before falling back lands each one under the deepest symbol
-- that contains it, which is where a server would have put it.
local function insert_by_range(tree, node)
    for _, s in ipairs(tree) do
        if contains(symbol_range(s), node.range) then
            s.children = s.children or {}
            insert_by_range(s.children, node)
            return
        end
    end
    table.insert(tree, node)
end

local function sort_by_line(tree)
    table.sort(tree, function(a, b)
        return symbol_range(a).start.line < symbol_range(b).start.line
    end)
    for _, s in ipairs(tree) do
        if s.children and #s.children > 0 then
            sort_by_line(s.children)
        end
    end
end

local function render(result, empty_msg)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
    end
    local lines, jumps, tree = {}, {}, {}
    if result and not vim.tbl_isempty(result) then
        tree = is_document_symbol(result) and result or nest_by_container_name(result)
    end
    -- Merge after nesting, so a flat SymbolInformation tree is already
    -- built and query entries can find their containing symbol.
    local extra = M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf) and queries.outline(M.src_buf) or {}
    if #extra > 0 then
        for _, node in ipairs(extra) do
            insert_by_range(tree, node)
        end
        sort_by_line(tree)
    end
    if vim.tbl_isempty(tree) then
        lines = { empty_msg or 'No symbols' }
    else
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
    if markup.handles(M.src_buf) then
        render(markup.outline(M.src_buf), 'No headings')
        M.sync_cursor()
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

    if config.options.position == 'right' then
        vim.cmd('botright ' .. config.options.width .. ' vsplit')
    else
        vim.cmd('botright ' .. config.options.height .. ' split')
    end
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
    -- configured size.
    vim.wo[M.win].winfixheight = config.options.position ~= 'right'
    vim.wo[M.win].winfixwidth = config.options.position == 'right'

    local opts = { buffer = M.buf, silent = true }
    vim.keymap.set('n', '<CR>', goto_jump, opts)
    vim.keymap.set('n', 'p', goto_parent, opts)
    vim.keymap.set('n', 'o', toggle_callers, opts)
    vim.keymap.set('n', 'q', M.close, opts)
    vim.keymap.set('n', '<Esc>', M.close, opts)
    if config.options.auto_preview then
        vim.api.nvim_create_autocmd('CursorMoved', { buffer = M.buf, callback = preview })
    end

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
    callback = function(ev)
        -- only for the bar's own buffer: files loaded for callers attach too, and a refresh would drop them
        if ev.buf == M.src_buf and M.win and vim.api.nvim_win_is_valid(M.win) then
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
