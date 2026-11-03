-- Minimal LSP-based tagbar: bottom or right bar, nested by real hierarchy (or by
-- containerName when a server only returns a flat symbol list), filtered
-- to configured kinds. No ctags, no plugin dependency.

local config = require('nvim-lsp-tagbar.config')
local markup = require('nvim-lsp-tagbar.markup')
local queries = require('nvim-lsp-tagbar.queries')
local markers = require('nvim-lsp-tagbar.markers')
local callers = require('nvim-lsp-tagbar.callers')
local hunks = require('nvim-lsp-tagbar.hunks')
local files = require('nvim-lsp-tagbar.files')

local M = {}

M.win, M.buf, M.src_win, M.src_buf = nil, nil, nil, nil
M._keymap = nil
M._configured = false
-- `@` in the bar cycles what's listed: the file tree, the file tree with
-- only changed files, the buffer's symbols, its markers (flat), its git
-- hunks (flat)
local VIEWS = { 'files', 'changed', 'symbols', 'markers', 'changes' }
local VIEW_TITLES = {
    files = 'Files',
    changed = 'Changed files',
    symbols = 'Symbols',
    markers = 'Markers',
    changes = 'Buffer changes',
}
-- kept across opens of the bar for this nvim session; setup() starts it at default_view
M.view = 'files'
-- `?` in the bar shows a quick help block above the tree, NERDTree style
M.help = false
M.help_len = 0

local CURSOR_NS = vim.api.nvim_create_namespace('lsptagbar_cursor')
local FILES_NS = vim.api.nvim_create_namespace('lsptagbar_files')
-- set while the bar itself swaps a buffer into the source window, so the
-- BufEnter that fires then isn't taken for the user switching buffers
M._previewing = false
M._timer = nil
M._last_move = 0
-- set by M.find(): true keeps the bar open when a file or symbol is opened from it and
-- when focus leaves it, false closes it then; nil follows auto_close / files.close_on_open
M.stay = nil
local start_timer

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
        M._previewing = true
        pcall(vim.api.nvim_win_set_buf, M.src_win, M.src_buf)
        M._previewing = false
    end
    if M._timer then
        M._timer:stop()
        M._timer:close()
        M._timer = nil
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
    if not (entry and entry.pos) then
        return
    end
    local src_win = M.src_win
    if M.stay then
        -- the bar stays; drop a caller preview so the source window shows its own buffer first
        if src_win and vim.api.nvim_win_is_valid(src_win) and M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf)
                and vim.api.nvim_win_get_buf(src_win) ~= M.src_buf then
            M._previewing = true
            pcall(vim.api.nvim_win_set_buf, src_win, M.src_buf)
            M._previewing = false
        end
    else
        M.close()
    end
    if src_win and vim.api.nvim_win_is_valid(src_win) then
        vim.api.nvim_set_current_win(src_win)
        -- nvim_win_set_cursor leaves no jumplist entry, so mark where the bar was opened from
        -- (auto_preview may have moved the cursor since) to make <C-o> come back here
        if M.src_pos and vim.api.nvim_get_current_buf() == M.src_buf then
            pcall(vim.api.nvim_win_set_cursor, 0, M.src_pos)
        end
        vim.cmd("normal! m'")
    end
    if entry.uri then
        vim.cmd('edit ' .. vim.fn.fnameescape(vim.uri_to_fname(entry.uri)))
    end
    vim.api.nvim_win_set_cursor(0, { entry.pos.line + 1, entry.pos.character })
    vim.cmd('normal! zz')
end

-- Whether opening something from the bar closes it, and whether leaving it does.
local function closes_on_open()
    if M.stay ~= nil then
        return not M.stay
    end
    return config.options.files.close_on_open
end

local function closes_on_leave()
    if M.stay ~= nil then
        return not M.stay
    end
    return config.options.auto_close
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
    if not (entry and entry.pos) then
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
        M._previewing = true
        pcall(vim.api.nvim_win_set_buf, M.src_win, buf)
        M._previewing = false
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

-- Where the tree's entries come from, for the help block: which LSP servers
-- answer documentSymbol, plus the markers and treesitter queries merged in.
local function source_lines(ft)
    if markup.handles(M.src_buf) then
        return { '"   # headings (line scan, no LSP)' }
    end
    local names = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = M.src_buf, method = 'textDocument/documentSymbol' })) do
        names[#names + 1] = client.name
    end
    local out = { '"   LSP documentSymbol: ' .. (#names > 0 and table.concat(names, ', ') or 'none attached') }
    if #names > 1 then
        out[#out + 1] = '"     (each server re-renders the bar; the last to answer wins)'
    end
    local specs = config.options.queries[ft] or {}
    if #specs > 0 then
        out[#out + 1] = ('"   + treesitter queries: %d for %s'):format(#specs, ft)
    end
    out[#out + 1] = '"   + @@ markers (line scan); no ctags'
    if config.options.git_hunks then
        out[#out + 1] = '"   + git hunks vs ' .. hunks.base_label()
    end
    return out
end

local function is_tree_view()
    return M.view == 'files' or M.view == 'changed'
end

local function files_help_lines()
    return {
        '" File tree keys (? to close)',
        '"   <CR>/o  open file, or open / close folder',
        '"   go      preview file, keep the bar',
        '"   O       open folder and all under it',
        '"   x       close parent folder',
        '"   s/i/t   open in vsplit / split / tab',
        '"   p       go to parent folder',
        '"   C       make this folder the root',
        '"   u       root up one level',
        '"   R       refresh',
        '"   I       show / hide dotfiles  [now: ' .. (files.show_hidden and 'shown' or 'hidden') .. ']',
        '"   m       menu: add / move / copy / delete',
        '"   Y       copy full path',
        '"   @       cycle view: ' .. table.concat(VIEWS, ' > ') .. '  [now: ' .. M.view .. ']',
        '"   q       close',
        '" Colors vs ' .. hunks.base_label(),
        '"   green: changed   grey: git-ignored (ign)',
        '"   (sym) symlink  (hard) hard link  (exc) executable',
        '',
    }
end

local function help_lines()
    if is_tree_view() then
        return files_help_lines()
    end
    local ft = vim.bo[M.src_buf].filetype
    local markers_cfg = config.options.markers or {}
    local patterns = markers_cfg[ft] or markers_cfg['*'] or {}
    local lines = {
        '" Keys (? to close)',
        '"   <CR>  jump to symbol, close bar',
        '"   j/k   move' .. (config.options.auto_preview and ', previewing in source' or ''),
        '"   p     go to parent symbol',
        '"   o     show / hide callers',
        '"   @     cycle view: ' .. table.concat(VIEWS, ' > ') .. '  [now: ' .. M.view .. ']',
        '"   q     close',
        '" Custom tags',
        '"   write `@@ some text` in a comment or docstring',
        '"   ' .. ft .. ' patterns: ' .. (#patterns > 0 and table.concat(patterns, '  ') or 'none (off)'),
        '"   change via setup({ markers = { [ft] = { pattern } } })',
        '"   label: ' .. config.options.marker_label,
        '" Source',
    }
    vim.list_extend(lines, source_lines(ft))
    lines[#lines + 1] = ''
    return lines
end

-- Help lines sit above the tree with placeholder jumps (no pos, leaf), so
-- every tree line keeps its index into `jumps` shifted by the help length.
local function insert_help()
    local lines = help_lines()
    local jumps = vim.b[M.buf].jumps or {}
    shift_parents(jumps, 0, #lines)
    for n = 1, #lines do
        table.insert(jumps, n, { leaf = true })
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, 0, false, lines)
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
    M.help_len = #lines
end

local function remove_help()
    local jumps = vim.b[M.buf].jumps or {}
    for _ = 1, M.help_len do
        table.remove(jumps, 1)
    end
    shift_parents(jumps, 0, -M.help_len)
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, M.help_len, false, {})
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
    M.help_len = 0
end

-- ?: done in place rather than by re-rendering, so expanded callers stay open.
local function toggle_help()
    M.help = not M.help
    if M.help then
        insert_help()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
    else
        remove_help()
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

-- Title of the current `@` view, shown in the bar's winbar.
local function set_title()
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        return
    end
    local title = VIEW_TITLES[M.view]
    if (M.view == 'files' or M.view == 'changed') and files.root then
        title = title .. ': ' .. vim.fn.fnamemodify(files.root, ':~')
    end
    if (M.view == 'changes' and config.options.git_hunks) or (M.view == 'changed' and config.options.files.git) then
        title = title .. ' vs ' .. hunks.base_label()
    end
    local idx = 1
    for i, view in ipairs(VIEWS) do
        if view == M.view then
            idx = i
        end
    end
    title = (' %s  (%d/%d, @ next)'):format(title, idx, #VIEWS)
    vim.wo[M.win].winbar = '%#lsptagbarTitle#' .. title:gsub('%%', '%%%%')
end

-- The file tree entry under the bar's cursor, if any.
local function tree_entry()
    if not (M.win and vim.api.nvim_win_is_valid(M.win) and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return nil
    end
    local e = (vim.b[M.buf].jumps or {})[vim.api.nvim_win_get_cursor(M.win)[1]]
    return e and e.path and e or nil
end

-- Draw the file tree and put the cursor on `focus` (a path), else keep it on
-- the entry it was on. A timer refresh (`idle`) skips drawing an unchanged tree.
local function render_tree(focus, idle)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
    end
    if not files.root then
        files.root = files.project_root(M.src_buf)
    end
    local only_dirty = M.view == 'changed'
    local lines, entries, marks = files.build(files.root, only_dirty)
    local sig = M.view .. '\n' .. table.concat(lines, '\n') .. vim.inspect(marks)
    if idle and sig == M._tree_sig then
        return
    end
    M._tree_sig = sig
    local before = tree_entry()
    focus = focus or (before and before.path)
    local old_lnum = M.win and vim.api.nvim_win_is_valid(M.win) and vim.api.nvim_win_get_cursor(M.win)[1] or 1
    set_title()
    local jumps = {}
    for i, e in ipairs(entries) do
        jumps[i] = { path = e.path, dir = e.dir, parent = e.parent, leaf = true }
    end
    if #lines == 0 then
        if not only_dirty then
            lines = { '(empty folder)' }
        elseif config.options.files.git then
            lines = { 'No changed files' }
        else
            lines = { 'Git is off (files.git = false)' }
        end
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
    vim.b[M.buf].jumps = jumps
    vim.api.nvim_buf_clear_namespace(M.buf, CURSOR_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(M.buf, FILES_NS, 0, -1)
    for i, m in ipairs(marks) do
        if entries[i].dir then
            vim.api.nvim_buf_set_extmark(M.buf, FILES_NS, i - 1, m.indent,
                { end_col = m.name_start, hl_group = 'lsptagbarFileArrow' })
        end
        if m.group then
            vim.api.nvim_buf_set_extmark(M.buf, FILES_NS, i - 1, m.name_start,
                { end_col = m.name_end, hl_group = m.group })
        end
        if #m.tags > 0 then
            vim.api.nvim_buf_set_extmark(M.buf, FILES_NS, i - 1, 0, { virt_text = m.tags, virt_text_pos = 'eol' })
        end
    end
    M.help_len = 0
    if M.help then
        insert_help()
    end
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        return
    end
    jumps = vim.b[M.buf].jumps
    local lnum
    for i, e in ipairs(jumps) do
        if focus and e.path == focus then
            lnum = i
            break
        end
    end
    lnum = lnum or math.min(old_lnum, vim.api.nvim_buf_line_count(M.buf))
    vim.api.nvim_win_set_cursor(M.win, { lnum, 0 })
end

-- Window a file from the tree opens in: the one the bar was opened from,
-- else another normal window in this tab, else a new one beside the bar.
local function target_window()
    if M.src_win and vim.api.nvim_win_is_valid(M.src_win) and M.src_win ~= M.win then
        return M.src_win
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= M.win and vim.api.nvim_win_get_config(w).relative == ''
                and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == '' then
            return w
        end
    end
    local empty = vim.api.nvim_create_buf(true, false)
    vim.bo[empty].bufhidden = 'wipe'
    return vim.api.nvim_open_win(empty, false,
        { split = ({ left = 'right', right = 'left' })[config.options.position] or 'above', win = -1 })
end

-- how: nil (in the source window), 'vsplit', 'split', 'tab', or 'preview'
-- (in the source window, focus and bar kept).
local function open_file(path, how)
    local win = target_window()
    local fname = vim.fn.fnameescape(path)
    local ok, err
    if how == 'preview' then
        M._previewing = true
        ok, err = pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('edit ' .. fname)
        end)
        M._previewing = false
        if ok then
            -- a real open, not a peek: closing the bar keeps it
            M.src_win, M.src_buf = win, vim.api.nvim_win_get_buf(win)
        end
    else
        if closes_on_open() then
            M.close()
        end
        vim.api.nvim_set_current_win(win)
        vim.cmd("normal! m'")
        local cmd = ({ vsplit = 'vsplit', split = 'split', tab = 'tabedit' })[how] or 'edit'
        ok, err = pcall(vim.cmd, cmd .. ' ' .. fname)
    end
    if not ok then
        vim.notify('nvim-lsp-tagbar: ' .. tostring(err), vim.log.levels.ERROR)
    end
end

-- <CR> / o: open a file, or open / close a folder.
local function tree_activate(how)
    local e = tree_entry()
    if not e then
        return
    end
    if not e.dir then
        open_file(e.path, how)
    elseif not how then
        files.open_dirs[e.path] = not files.open_dirs[e.path] or nil
        render_tree(e.path)
    end
end

-- O: open a folder and everything under it; on a file, like o.
local function tree_open_recursive()
    local e = tree_entry()
    if not e then
        return
    end
    if not e.dir then
        open_file(e.path)
        return
    end
    files.open_recursive(e.path)
    render_tree(e.path)
end

-- x: close the folder holding this entry.
local function tree_close_parent()
    local jumps = vim.b[M.buf].jumps or {}
    local e = jumps[vim.api.nvim_win_get_cursor(0)[1]]
    local parent = e and e.parent and jumps[e.parent]
    if not (parent and parent.path) then
        return
    end
    files.open_dirs[parent.path] = nil
    render_tree(parent.path)
end

-- C: this folder (or this file's folder) becomes the root.
local function tree_set_root()
    local e = tree_entry()
    if not e then
        return
    end
    files.root = e.dir and e.path or vim.fs.dirname(e.path)
    render_tree()
    vim.api.nvim_win_set_cursor(M.win, { math.min(M.help_len + 1, vim.api.nvim_buf_line_count(M.buf)), 0 })
end

-- u: root up one level, the old root opened in it.
local function tree_root_up()
    local old = files.root
    if not old or old == '/' then
        return
    end
    files.root = vim.fs.dirname(old)
    files.open_dirs[old] = true
    render_tree(old)
end

local function tree_reload()
    files.invalidate_git()
    render_tree()
end

-- I: show / hide dotfiles.
local function tree_toggle_hidden()
    files.show_hidden = not files.show_hidden
    render_tree()
end

-- Y: full path into the unnamed register and the clipboard.
local function tree_yank_path()
    local e = tree_entry()
    if not e then
        return
    end
    vim.fn.setreg('"', e.path)
    pcall(vim.fn.setreg, '+', e.path)
    vim.api.nvim_echo({ { 'Copied ' .. e.path } }, false, {})
end

-- Unmodified buffers of path (or of files under it): shown windows get an
-- empty buffer instead, then they are deleted. Paths resolved before the
-- file is gone.
local function buffers_under(path)
    local real = vim.fn.resolve(path)
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= '' and b ~= M.buf and not vim.bo[b].modified
                and (name == real or name:sub(1, #real + 1) == real .. '/') then
            out[#out + 1] = b
        end
    end
    return out
end

local function wipe_buffers(list)
    for _, b in ipairs(list) do
        if vim.api.nvim_buf_is_valid(b) then
            for _, w in ipairs(vim.fn.win_findbuf(b)) do
                local empty = vim.api.nvim_create_buf(true, false)
                vim.bo[empty].bufhidden = 'wipe'
                M._previewing = true
                pcall(vim.api.nvim_win_set_buf, w, empty)
                M._previewing = false
            end
            pcall(vim.api.nvim_buf_delete, b, {})
        end
    end
    if M.src_buf and not vim.api.nvim_buf_is_valid(M.src_buf) and M.src_win and vim.api.nvim_win_is_valid(M.src_win) then
        M.src_buf = vim.api.nvim_win_get_buf(M.src_win)
    end
end

-- m: add / move / copy / delete, NERDTree's menu boiled down.
local function tree_menu()
    local e = tree_entry()
    local dir = e and (e.dir and e.path or vim.fs.dirname(e.path)) or files.root
    vim.api.nvim_echo({ { '(a)dd  (m)ove  (c)opy  (d)elete: ', 'Question' } }, false, {})
    local ok, ch = pcall(vim.fn.getcharstr)
    vim.api.nvim_echo({ { '' } }, false, {})
    if not ok then
        return
    end
    local function done(err, focus)
        if err then
            vim.notify('nvim-lsp-tagbar: ' .. err, vim.log.levels.ERROR)
            return
        end
        files.invalidate_git()
        if focus then
            files.reveal(focus)
        end
        render_tree(focus)
    end
    local function absolute(input)
        local trailing = input:sub(-1) == '/' and '/' or ''
        local full = input:sub(1, 1) == '/' and input or (dir .. '/' .. input)
        return files.normalize(vim.fn.expand(full)) .. trailing
    end
    if ch == 'a' then
        vim.ui.input({ prompt = 'Add (end with / for a folder): ', default = dir .. '/', completion = 'file' },
            function(input)
                if not input or input == '' or input == dir .. '/' then
                    return
                end
                local path = absolute(input)
                done(files.add(path), (path:gsub('/$', '')))
            end)
    elseif (ch == 'm' or ch == 'c') and e then
        vim.ui.input({ prompt = (ch == 'm' and 'Move to: ' or 'Copy to: '), default = e.path, completion = 'file' },
            function(input)
                if not input or input == '' or input == e.path then
                    return
                end
                local to = (absolute(input):gsub('/$', ''))
                done(ch == 'm' and files.move(e.path, to) or files.copy(e.path, to), to)
            end)
    elseif ch == 'd' and e then
        if vim.fn.confirm('Delete ' .. e.path .. (e.dir and ' and everything in it' or '') .. '?', '&Yes\n&No', 2) ~= 1 then
            return
        end
        local bufs = buffers_under(e.path)
        local err = files.delete(e.path)
        if not err then
            wipe_buffers(bufs)
        end
        done(err, vim.fs.dirname(e.path))
    end
end

local function render(result, empty_msg)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
    end
    set_title()
    vim.api.nvim_buf_clear_namespace(M.buf, FILES_NS, 0, -1)
    local lines, jumps, tree = {}, {}, {}
    if M.view == 'markers' then
        tree = vim.deepcopy(markers.outline(M.src_buf))
    elseif M.view == 'changes' then
        tree = vim.deepcopy(hunks.outline(M.src_buf))
    elseif result and not vim.tbl_isempty(result) then
        tree = is_document_symbol(result) and result or nest_by_container_name(result)
    end
    -- Merge after nesting, so a flat SymbolInformation tree is already
    -- built and query entries can find their containing symbol.
    local extra = {}
    if M.view == 'symbols' and M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf) then
        vim.list_extend(extra, queries.outline(M.src_buf))
    end
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
    M.help_len = 0
    if M.help then
        insert_help()
    end
end

local function cycle_view()
    local next_idx = 1
    for idx, view in ipairs(VIEWS) do
        if view == M.view then
            next_idx = idx % #VIEWS + 1
        end
    end
    M.view = VIEWS[next_idx]
    M.refresh()
end

function M.refresh()
    if not (M.buf and M.src_buf and vim.api.nvim_buf_is_valid(M.src_buf)) then
        return
    end
    if is_tree_view() then
        local e = tree_entry()
        render_tree(e and e.path or files.buf_path(M.src_buf))
        return
    end
    if M.view == 'markers' or M.view == 'changes' then
        render(nil, M.view == 'markers' and 'No markers' or 'No git changes')
        M.sync_cursor()
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

-- Re-read the file tree every files.refresh_ms while it's shown: only in
-- normal mode and not while the cursor is moving in it, since a big tree
-- takes a moment to read.
start_timer = function()
    local ms = config.options.files.refresh_ms
    if not ms or ms <= 0 or M._timer then
        return
    end
    M._timer = vim.uv.new_timer()
    M._timer:start(ms, ms, vim.schedule_wrap(function()
        if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
            if M._timer then
                M._timer:stop()
                M._timer:close()
                M._timer = nil
            end
            return
        end
        if not is_tree_view() or vim.api.nvim_get_mode().mode ~= 'n' or vim.uv.now() - M._last_move < 2000 then
            return
        end
        render_tree(nil, true)
    end))
end

function M.open()
    M.src_win = vim.api.nvim_get_current_win()
    M.src_buf = vim.api.nvim_get_current_buf()
    M.src_pos = vim.api.nvim_win_get_cursor(M.src_win)
    M.help = false
    M._tree_sig = nil
    -- like NERDTree find: always at the current file's project root, the file revealed
    files.root = files.project_root(M.src_buf)
    files.reveal(files.buf_path(M.src_buf))

    if config.options.position == 'left' then
        vim.cmd('topleft ' .. config.options.width .. ' vsplit')
    elseif config.options.position == 'right' then
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
    local side = config.options.position == 'left' or config.options.position == 'right'
    vim.wo[M.win].winfixheight = not side
    vim.wo[M.win].winfixwidth = side
    -- :bn, :bp, :e and the like would otherwise load another buffer into the bar
    vim.wo[M.win].winfixbuf = true

    local opts = { buffer = M.buf, silent = true, nowait = true }
    -- file tree keys; in the symbol views the first ones keep their old meaning, the rest do nothing
    local function tree(fn, fallback)
        return function()
            if is_tree_view() then
                fn()
            elseif fallback then
                fallback()
            end
        end
    end
    vim.keymap.set('n', '<CR>', tree(function() tree_activate() end, goto_jump), opts)
    vim.keymap.set('n', 'o', tree(function() tree_activate() end, toggle_callers), opts)
    vim.keymap.set('n', 'p', goto_parent, opts)
    vim.keymap.set('n', 'R', tree(tree_reload, M.refresh), opts)
    local tree_keys = {
        go = function() tree_activate('preview') end,
        s = function() tree_activate('vsplit') end,
        i = function() tree_activate('split') end,
        t = function() tree_activate('tab') end,
        O = tree_open_recursive,
        x = tree_close_parent,
        C = tree_set_root,
        u = tree_root_up,
        I = tree_toggle_hidden,
        m = tree_menu,
        Y = tree_yank_path,
    }
    for lhs, fn in pairs(tree_keys) do
        vim.keymap.set('n', lhs, tree(fn), opts)
    end
    vim.keymap.set('n', '@', cycle_view, opts)
    vim.keymap.set('n', '?', toggle_help, opts)
    vim.keymap.set('n', 'q', M.close, opts)
    vim.keymap.set('n', '<Esc>', M.close, opts)
    if config.options.auto_preview then
        vim.api.nvim_create_autocmd('CursorMoved', { buffer = M.buf, callback = preview })
    end
    -- the tree's timer refresh holds off while the cursor moves in it
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function()
            M._last_move = vim.uv.now()
        end,
    })
    start_timer()
    -- scheduled: a window can't be closed from inside its own WinLeave;
    -- the check skips a bar that was already closed, reopened or re-entered by then.
    -- Checked on each leave, since M.find() can switch the mode while the bar is open.
    local win = M.win
    vim.api.nvim_create_autocmd('WinLeave', {
        buffer = M.buf,
        callback = function()
            if not closes_on_leave() then
                return
            end
            vim.schedule(function()
                if M.win == win and vim.api.nvim_get_current_win() ~= win then
                    M.close()
                end
            end)
        end,
    })

    M.refresh()
end

-- Open the bar, or focus it if it's open, with the current file revealed:
-- NERDTree's find, for a mapping in your own config. opts.stay = true keeps
-- the bar open after opening a file and when focus leaves it (NERDTree with
-- NERDTreeQuitOnOpen = 0); false closes it then. Called from inside the bar,
-- it only switches that mode. The last call decides, for this nvim session.
function M.find(opts)
    opts = opts or {}
    if opts.stay ~= nil then
        M.stay = opts.stay
    end
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        M.open()
    elseif vim.api.nvim_get_current_win() ~= M.win then
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].buftype == '' and vim.api.nvim_win_get_config(win).relative == '' then
            M.src_win, M.src_buf = win, buf
            M.src_pos = vim.api.nvim_win_get_cursor(win)
        end
        vim.api.nvim_set_current_win(M.win)
        if is_tree_view() then
            local path = files.buf_path(M.src_buf)
            files.reveal(path)
            render_tree(path)
        else
            M.refresh()
        end
    end
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        vim.api.nvim_win_call(M.win, function()
            vim.cmd('normal! zz')
        end)
    end
    vim.api.nvim_echo({ { M.stay and 'Bar stays open' or 'Bar closes after opening a file' } }, false, {})
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

-- Whoever owns g:git_diff_base fires this after changing it.
vim.api.nvim_create_autocmd('User', {
    pattern = 'GitDiffBaseChanged',
    callback = function()
        files.invalidate_git()
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            M.refresh()
        end
    end,
})

-- follow: a bar left open (auto_close off, or stay) moves along to the buffer you
-- switch to; the file tree reveals it if it's under the root.
vim.api.nvim_create_autocmd('BufEnter', {
    callback = function(ev)
        if not config.options.follow or M._previewing or not (M.win and vim.api.nvim_win_is_valid(M.win)) then
            return
        end
        local win = vim.api.nvim_get_current_win()
        if win == M.win or ev.buf == M.buf or vim.bo[ev.buf].buftype ~= ''
                or vim.api.nvim_win_get_config(win).relative ~= ''
                or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_win_get_tabpage(M.win)
                or (win == M.src_win and ev.buf == M.src_buf) then
            return
        end
        M.src_win, M.src_buf = win, ev.buf
        M.src_pos = vim.api.nvim_win_get_cursor(win)
        if is_tree_view() then
            local path = files.buf_path(ev.buf)
            if files.reveal(path) then
                render_tree(path)
            end
        else
            M.refresh()
        end
    end,
})

files.set_colors()
vim.api.nvim_create_autocmd('ColorScheme', { callback = files.set_colors })

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
    if vim.tbl_contains(VIEWS, config.options.default_view) then
        M.view = config.options.default_view
    end
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
