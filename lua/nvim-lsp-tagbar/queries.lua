-- User-defined outline entries, matched against the syntax tree, for
-- symbols no language server reports (anonymous callbacks, DSL-style
-- registrations). Emits the same node shape the documentSymbol source
-- does, so merged entries nest and jump like real symbols.
--
-- Each query needs a @name capture (the text shown) and may add a @scope
-- capture (the entry's range, defaulting to @name's own node).

local config = require('nvim-lsp-tagbar.config')

local M = {}

local function pos(line, character)
    return { line = line, character = character }
end

local function node_range(node)
    local sl, sc, el, ec = node:range()
    return { start = pos(sl, sc), ['end'] = pos(el, ec) }
end

local function match_node(match, id)
    local nodes = id and match[id]
    -- iter_matches yields a list per capture; a quantified capture can
    -- match several nodes, and the first is the one to anchor on.
    if type(nodes) == 'table' then
        return nodes[1]
    end
    return nodes
end

function M.outline(buf)
    local ft = vim.bo[buf].filetype
    local specs = config.options.queries[ft]
    if not specs or vim.tbl_isempty(specs) then
        return {}
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, ft)
    if not ok or not parser then
        return {}
    end
    local root = parser:parse()[1]:root()
    local lang = parser:lang()

    local out = {}
    for _, spec in ipairs(specs) do
        local ok_q, query = pcall(vim.treesitter.query.parse, lang, spec.query)
        if not ok_q then
            vim.notify('nvim-lsp-tagbar: bad query for ' .. ft .. ': ' .. tostring(query), vim.log.levels.WARN)
        else
            local ids = {}
            for i, name in ipairs(query.captures) do
                ids[name] = i
            end
            for _, match in query:iter_matches(root, buf, 0, -1) do
                local name_node = match_node(match, ids.name)
                if name_node then
                    local scope = match_node(match, ids.scope) or name_node
                    table.insert(out, {
                        name = vim.treesitter.get_node_text(name_node, buf),
                        label = spec.label or '[?]',
                        selectionRange = node_range(name_node),
                        range = node_range(scope),
                        children = {},
                    })
                end
            end
        end
    end
    return out
end

return M
