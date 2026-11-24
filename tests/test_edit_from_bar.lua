local h = require('helpers')
local T = {}

function T.test_edit_in_bar_opens_in_source_window()
    local bar = require('nvim-lsp-tagbar')
    vim.cmd('silent! only')
    vim.cmd('edit ' .. h.fixtures .. '/linked/repo/README.md')
    local src = vim.api.nvim_get_current_win()
    bar.find()
    local bar_win, bar_buf = bar.win, bar.buf
    assert(vim.api.nvim_get_current_win() == bar_win, 'find focuses the bar')

    local target = h.fixtures .. '/linked/repo/to_target.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(target))
    vim.wait(50)

    h.eq(vim.fn.resolve(target), vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(src))),
        'the file lands in the source window')
    h.eq(src, vim.api.nvim_get_current_win(), 'focus moves to the source window')
    if vim.api.nvim_win_is_valid(bar_win) then
        h.eq(bar_buf, vim.api.nvim_win_get_buf(bar_win), 'the bar keeps its own buffer')
    end
    bar.close()
    assert(not vim.api.nvim_buf_is_valid(bar_buf), 'closing the bar deletes its buffer')
end

return T
