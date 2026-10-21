-- Git change entries: each hunk between the buffer and a git base shows up
-- in the bar as `[+] first added line`, `[~] first changed line` or
-- `[-] 3 lines removed`. Diffed here with vim.diff against `git show`, so
-- no git-signs plugin is needed. The base is config `git_base`, else the
-- editor-wide g:git_diff_base when set, else HEAD.

local config = require('nvim-lsp-tagbar.config')

local M = {}

-- Same one-slot memo as markers.lua, plus a short expiry: a commit or
-- checkout changes the base without touching the buffer.
local cache = {}
local TTL_MS = 2000

local function pos(line, character)
    return { line = line, character = character }
end

local function base_ref()
    local opt = config.options.git_base
    if opt then
        return type(opt) == 'function' and opt() or opt
    end
    local shared = vim.g.git_diff_base
    return (shared and shared ~= '') and shared or 'HEAD'
end

function M.base_label()
    local ref = base_ref()
    return ref:match('^%x+$') and #ref >= 40 and ref:sub(1, 8) or ref
end

-- The file's text at `ref`: '' for a file git doesn't have there (new or
-- untracked, so the whole buffer counts as added), nil outside a repo.
local function base_text(path, ref)
    if not vim.fs.root(path, '.git') then
        return nil
    end
    local show = vim.system({ 'git', '-C', vim.fs.dirname(path), 'show', ref .. ':./' .. vim.fs.basename(path) },
        { text = true }):wait()
    return show.code == 0 and show.stdout or ''
end

function M.outline(buf)
    if not config.options.git_hunks or vim.bo[buf].buftype ~= '' then
        return {}
    end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == '' then
        return {}
    end
    local ref = base_ref()
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local now = vim.uv.now()
    if cache.buf == buf and cache.tick == tick and cache.ref == ref and now - cache.time < TTL_MS then
        return cache.out
    end
    local out = {}
    local old = base_text(path, ref)
    if old then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local new = table.concat(lines, '\n') .. '\n'
        local labels = config.options.git_hunk_labels
        for _, h in ipairs(vim.diff(old, new, { result_type = 'indices' })) do
            local old_count, new_start, new_count = h[2], h[3], h[4]
            local label, name, first, last
            if new_count == 0 then
                -- vim.diff gives the line the removal sits after; 0 is the top
                first = math.max(new_start - 1, 0)
                last = first
                label = labels.delete
                name = ('%d line%s removed'):format(old_count, old_count == 1 and '' or 's')
            else
                first = new_start - 1
                last = new_start + new_count - 2
                label = old_count == 0 and labels.add or labels.change
                for i = first + 1, last + 1 do
                    local text = vim.trim(lines[i] or '')
                    if text ~= '' then
                        name = text
                        break
                    end
                end
                name = name or '(blank lines)'
            end
            table.insert(out, {
                name = name,
                label = label,
                selectionRange = { start = pos(first, 0), ['end'] = pos(first, 0) },
                range = { start = pos(first, 0), ['end'] = pos(last, #(lines[last + 1] or '')) },
                children = {},
            })
        end
    end
    cache.buf, cache.tick, cache.ref, cache.time, cache.out = buf, tick, ref, now, out
    return out
end

return M
