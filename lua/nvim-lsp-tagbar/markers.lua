-- Hand-written outline entries: a comment or docstring line carrying a
-- marker (default `@@ some text`) shows up in the bar as `[@] some text`.
-- A plain line scan, so it works the same in any filetype, with or without
-- an LSP or a treesitter parser.

local config = require('nvim-lsp-tagbar.config')

local M = {}

-- Same one-slot memo as queries.lua: a bar open renders two or three times.
local cache = {}

local function pos(line, character)
    return { line = line, character = character }
end

local function patterns_for(ft)
    local markers = config.options.markers or {}
    return markers[ft] or markers['*'] or {}
end

function M.outline(buf)
    local patterns = patterns_for(vim.bo[buf].filetype)
    if vim.tbl_isempty(patterns) then
        return {}
    end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if cache.buf == buf and cache.tick == tick then
        return cache.out
    end
    local out = {}
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        for _, pattern in ipairs(patterns) do
            local s, e, text = line:find(pattern)
            if s and text and text ~= '' then
                local lnum = i - 1
                table.insert(out, {
                    name = text,
                    label = config.options.marker_label,
                    selectionRange = { start = pos(lnum, s - 1), ['end'] = pos(lnum, e) },
                    range = { start = pos(lnum, 0), ['end'] = pos(lnum, #line) },
                    children = {},
                })
                break
            end
        end
    end
    cache.buf, cache.tick, cache.out = buf, tick, out
    return out
end

return M
