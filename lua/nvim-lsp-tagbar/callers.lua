-- Callers of a symbol, from LSP call hierarchy (callHierarchy/incomingCalls).
--
-- Calls made through an interface (e.g. `service.validate_token()` where `service` is typed as a
-- Protocol or base class) are linked by the server to the interface's method, not to the
-- implementation. So for a method, the callers of every other same-named `def` in the repo are
-- added too, each marked with the def it came through (`via`).

local config = require('nvim-lsp-tagbar.config')

local M = {}

local function sync(client, method, params, buf)
    local r = client:request_sync(method, params, 20000, buf)
    if not r or r.err then
        vim.notify('nvim-lsp-tagbar: ' .. method .. ' failed: ' .. vim.inspect(r and r.err or 'timeout'),
            vim.log.levels.WARN)
        return nil
    end
    return r.result
end

function M.client(buf)
    return vim.lsp.get_clients({ bufnr = buf, method = 'callHierarchy/prepareCallHierarchy' })[1]
end

function M.short(uri)
    return vim.fn.fnamemodify(vim.uri_to_fname(uri), ':~:.')
end

local function key(item)
    return item.uri .. ':' .. item.selectionRange.start.line
end

function M.is_test(uri)
    local f = vim.uri_to_fname(uri)
    for _, pat in ipairs(config.options.callers_test_patterns) do
        if f:find(pat) then
            return true
        end
    end
    return false
end

-- The call hierarchy item at pos in buf, or nil.
function M.prepare(client, buf, pos)
    local items = sync(client, 'textDocument/prepareCallHierarchy',
        { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = pos }, buf)
    return items and items[1]
end

local function line_of(uri, lnum0)
    local buf = vim.uri_to_bufnr(uri)
    vim.fn.bufload(buf)
    return vim.api.nvim_buf_get_lines(buf, lnum0, lnum0 + 1, false)[1] or '', buf
end

-- A method's `def` is indented under its class; servers don't agree on reporting it as a Method.
local function is_method(item)
    return item.kind == vim.lsp.protocol.SymbolKind.Method
        or (line_of(item.uri, item.selectionRange.start.line)):match('^%s+') ~= nil
end

-- Other `def <name>(` in the repo outside tests: { uri, line, character }.
local function same_named_defs(item)
    local root = vim.fs.root(vim.uri_to_fname(item.uri), '.git')
    if not root then
        return {}
    end
    local out = vim.fn.systemlist({ 'git', '-C', root, 'grep', '-n', '-E',
        '^[[:space:]]+(async[[:space:]]+)?def[[:space:]]+' .. vim.pesc(item.name) .. '[[:space:]]*\\(', '--', '*.py' })
    local defs = {}
    for _, l in ipairs(out) do
        local file, lnum, text = l:match('^([^:]+):(%d+):(.*)$')
        local uri = file and vim.uri_from_fname(root .. '/' .. file)
        if uri and not M.is_test(uri) then
            defs[#defs + 1] = { uri = uri, line = tonumber(lnum) - 1, character = text:find(item.name, 1, true) - 1 }
        end
    end
    return defs
end

-- Callers of item: list of { item, site (call position in the caller), count, via }, plus how many
-- callers in tests were left out.
function M.of(client, buf, item)
    local list, seen, hidden = {}, { [key(item)] = true }, 0
    local function add(calls, via)
        for _, c in ipairs(calls or {}) do
            local k = key(c.from)
            if not seen[k] then
                seen[k] = true
                if config.options.callers_include_tests or not M.is_test(c.from.uri) then
                    list[#list + 1] = { item = c.from, site = c.fromRanges[1] and c.fromRanges[1].start,
                        count = #c.fromRanges, via = via }
                else
                    hidden = hidden + 1
                end
            end
        end
    end
    add(sync(client, 'callHierarchy/incomingCalls', { item = item }, buf))
    if vim.uri_to_fname(item.uri):match('%.py$') and is_method(item) and not item.name:match('^__') then
        for _, d in ipairs(same_named_defs(item)) do
            if not (d.uri == item.uri and d.line == item.selectionRange.start.line) then
                local _, dbuf = line_of(d.uri, d.line)
                local other = M.prepare(client, dbuf, { line = d.line, character = d.character })
                if other then
                    add(sync(client, 'callHierarchy/incomingCalls', { item = other }, buf),
                        M.short(d.uri) .. ':' .. (d.line + 1))
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if (a.via == nil) ~= (b.via == nil) then
            return a.via == nil
        end
        return M.short(a.item.uri) .. a.item.name < M.short(b.item.uri) .. b.item.name
    end)
    return list, hidden
end

return M
