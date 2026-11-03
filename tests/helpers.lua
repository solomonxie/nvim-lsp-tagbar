-- Shared helpers for the tests: fixture paths and assertions.

local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
M.fixtures = M.root .. '/fixtures'

function M.eq(expected, actual, msg)
    if not vim.deep_equal(expected, actual) then
        error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

function M.truthy(value, msg)
    if not value then
        error(msg or 'expected a truthy value', 2)
    end
end

-- A fresh copy of a fixture folder, for tests that change files. cp -R keeps symlinks as links.
function M.copy_fixture(name)
    local dest = vim.fn.tempname()
    local res = vim.system({ 'cp', '-R', M.fixtures .. '/' .. name, dest }):wait()
    assert(res.code == 0, 'copy of fixture ' .. name .. ' failed')
    return dest
end

-- files.lua with git off, hidden files off and the default ignore list, and no tree state.
function M.files()
    require('nvim-lsp-tagbar.config').setup({ files = { git = false } })
    local files = require('nvim-lsp-tagbar.files')
    files.root = nil
    files.open_dirs = {}
    files.show_hidden = nil
    return files
end

return M
