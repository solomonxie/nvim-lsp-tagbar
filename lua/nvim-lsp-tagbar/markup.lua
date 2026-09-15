-- Outline source for prose/markup documents (Markdown & friends), as
-- opposed to the documentSymbol source used for code buffers. These files
-- have no LSP symbols worth listing, so sections come from their '#'
-- headings, emitted in the same shape documentSymbol returns.

local config = require('nvim-lsp-tagbar.config')

local M = {}

local function pos(line, character)
    return { line = line, character = character }
end

local function close_range(node, end_line)
    node.range['end'] = pos(end_line, 0)
end

function M.outline(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local roots, stack, fenced = {}, {}, false

    for i, line in ipairs(lines) do
        local lnum = i - 1
        if line:match('^%s*```') or line:match('^%s*~~~') then
            fenced = not fenced
        elseif not fenced then
            local hashes, text = line:match('^(#+)%s+(.-)%s*#*%s*$')
            if hashes and #hashes <= 6 and text ~= '' then
                local level = #hashes
                while #stack > 0 and stack[#stack].level >= level do
                    close_range(table.remove(stack), lnum - 1)
                end
                local node = {
                    name = text,
                    level = level,
                    label = string.format(config.options.heading_label, level),
                    selectionRange = { start = pos(lnum, #hashes + 1), ['end'] = pos(lnum, #line) },
                    range = { start = pos(lnum, 0), ['end'] = pos(lnum, 0) },
                    children = {},
                }
                local parent = stack[#stack]
                table.insert(parent and parent.children or roots, node)
                table.insert(stack, node)
            end
        end
    end

    for _, node in ipairs(stack) do
        close_range(node, math.max(#lines - 1, 0))
    end
    return roots
end

function M.handles(buf)
    return vim.tbl_contains(config.options.heading_filetypes, vim.bo[buf].filetype)
end

return M
