local h = require('helpers')
local T = {}

function T.test_view_keys_switch_views()
    local bar = require('nvim-lsp-tagbar')
    vim.cmd('silent! only')
    vim.cmd('edit ' .. h.fixtures .. '/linked/repo/README.md')
    bar.find()
    local expect = { S = 'symbols', M = 'markers', D = 'changes', C = 'changed', F = 'files' }
    for _, key in ipairs({ 'S', 'M', 'D', 'C', 'F' }) do
        vim.api.nvim_feedkeys(key, 'x', false)
        assert(bar.view == expect[key], key .. ' shows ' .. expect[key] .. ', got ' .. bar.view)
    end
    bar.close()
end

function T.test_bar_closed_as_last_window_gets_line_numbers_back()
    local bar = require('nvim-lsp-tagbar')
    vim.o.number = true
    vim.cmd('silent! only')
    vim.cmd('edit ' .. h.fixtures .. '/linked/repo/README.md')
    local src = vim.api.nvim_get_current_win()
    bar.find()
    local win = bar.win
    vim.api.nvim_win_close(src, true)  -- the bar is the last window
    bar.close()
    assert(vim.api.nvim_win_is_valid(win), 'the last window stays, emptied')
    assert(vim.wo[win].number, 'the emptied window has line numbers again')
end

return T
