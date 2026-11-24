local h = require('helpers')
local T = {}

-- m > m in the tree, answering the prompt with `to`; returns the bar's lines afterwards
local function menu_move(dir, from, to)
    local bar = require('nvim-lsp-tagbar')
    vim.cmd('silent! only')
    vim.cmd('cd ' .. dir)
    vim.cmd('edit ' .. dir .. '/' .. from)
    bar.find()
    local e = (vim.b[bar.buf].jumps or {})[vim.fn.line('.')]
    -- never press m on anything but the fixture copy's file
    assert(e and e.path == dir .. '/' .. from, 'cursor on ' .. from .. ', got ' .. vim.inspect(e))
    local input = vim.ui.input
    vim.ui.input = function(_, cb) cb(dir .. '/' .. to) end
    vim.api.nvim_feedkeys('mm', 'x', false)
    vim.ui.input = input
    local lines = vim.api.nvim_buf_get_lines(bar.buf, 0, -1, false)
    bar.close()
    return lines
end

function T.test_menu_move_renames_file_and_redraws_tree()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.system({ 'cp', h.fixtures .. '/tree/apple.txt', h.fixtures .. '/tree/Zeta.txt', dir })
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    local text = table.concat(menu_move(dir, 'apple.txt', 'pear.txt'), '\n')
    h.truthy(text:find('pear.txt', 1, true), 'tree shows the new name:\n' .. text)
    h.truthy(not text:find('apple.txt', 1, true), 'tree drops the old name:\n' .. text)
    h.eq({ '.git', 'Zeta.txt', 'pear.txt' }, vim.fn.sort(vim.fn.readdir(dir)), 'moved, not copied')
end

return T
