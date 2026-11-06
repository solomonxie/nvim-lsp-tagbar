local h = require('helpers')
local T = {}

local function open_src()
    vim.cmd('silent! only')
    vim.cmd('edit ' .. h.fixtures .. '/linked/repo/README.md')
    return vim.api.nvim_get_current_win()
end

function T.test_back_returns_to_source_window()
    local bar = require('nvim-lsp-tagbar')
    local src = open_src()
    bar.find()
    assert(vim.api.nvim_get_current_win() == bar.win, 'find focuses the bar')
    bar.back()
    assert(vim.api.nvim_get_current_win() == src, 'back returns to the source window')
    assert(vim.api.nvim_win_is_valid(bar.win), 'the bar stays open')
    bar.close()
end

function T.test_back_finds_another_window_if_source_closed()
    local bar = require('nvim-lsp-tagbar')
    local src = open_src()
    vim.cmd('vsplit')
    local other = vim.api.nvim_get_current_win()
    bar.find()
    vim.api.nvim_win_close(other, true)
    vim.api.nvim_set_current_win(bar.win)
    bar.src_win = other
    bar.back()
    assert(vim.api.nvim_get_current_win() == src, 'falls back to a normal window')
    bar.close()
end

return T
