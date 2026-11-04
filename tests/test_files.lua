-- Tests for lua/nvim-lsp-tagbar/files.lua, against the fixture tree in tests/fixtures/tree:
--   .dotdir/secret.txt  .dotfile  Beta/inner.txt  Zeta.txt  __pycache__/cached.txt
--   alpha/.hidden_in_alpha  alpha/nested/deep.txt  apple.txt  junk.pyc
--   link_file -> apple.txt  link_to_alpha -> alpha  node_modules/mod.txt  run.sh (executable)

local h = require('helpers')

local T = {}

local TREE = h.fixtures .. '/tree'

local function names(list)
    return vim.tbl_map(function(item)
        return item.name .. (item.dir and '/' or '')
    end, list)
end

function T.test_normalize_drops_dot_and_dotdot()
    local files = h.files()
    h.eq('/a/c', files.normalize('/a/./b/../c'))
    h.eq('/a/b', files.normalize('/a//b/'))
    h.eq('/', files.normalize('/..'))
end

function T.test_list_dir_folders_first_case_insensitive_hidden_and_ignored_left_out()
    local files = h.files()
    h.eq({ 'alpha/', 'Beta/', 'link_to_alpha/', 'apple.txt', 'link_file', 'run.sh', 'Zeta.txt' },
        names(files.list_dir(TREE)))
end

function T.test_list_dir_show_hidden_lists_dotfiles()
    local files = h.files()
    files.show_hidden = true
    h.eq({ '.dotdir/', 'alpha/', 'Beta/', 'link_to_alpha/', '.dotfile', 'apple.txt', 'link_file', 'run.sh', 'Zeta.txt' },
        names(files.list_dir(TREE)))
end

function T.test_list_dir_custom_ignore_replaces_defaults()
    require('nvim-lsp-tagbar.config').setup({ files = { git = false, ignore = { '^Zeta' } } })
    local files = require('nvim-lsp-tagbar.files')
    files.show_hidden = nil
    h.eq({ '__pycache__/', 'alpha/', 'Beta/', 'link_to_alpha/', 'node_modules/', 'apple.txt', 'junk.pyc', 'link_file', 'run.sh' },
        names(files.list_dir(TREE)))
end

function T.test_list_dir_missing_folder_is_empty()
    local files = h.files()
    h.eq({}, files.list_dir(TREE .. '/does-not-exist'))
end

function T.test_link_kind_symlink_exec_plain_and_folder()
    local files = h.files()
    h.eq('sym', files.link_kind(TREE .. '/link_to_alpha'))
    h.eq('sym', files.link_kind(TREE .. '/link_file'))
    h.eq('exc', files.link_kind(TREE .. '/run.sh'))
    h.eq(nil, files.link_kind(TREE .. '/apple.txt'))
    h.eq(nil, files.link_kind(TREE .. '/alpha'))
    h.eq(nil, files.link_kind(TREE .. '/does-not-exist'))
end

function T.test_link_kind_hard_link()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    assert(vim.uv.fs_link(tmp .. '/apple.txt', tmp .. '/apple_hard.txt'))
    h.eq('hard', files.link_kind(tmp .. '/apple.txt'))
    h.eq('hard', files.link_kind(tmp .. '/apple_hard.txt'))
end

function T.test_build_closed_tree()
    local files = h.files()
    local lines, entries, marks = files.build(TREE)
    h.eq({ '▸ alpha/', '▸ Beta/', '▸ link_to_alpha/', '  apple.txt', '  link_file', '  run.sh', '  Zeta.txt' }, lines)
    h.eq({ path = TREE .. '/alpha', dir = true, depth = 0 }, entries[1])
    h.eq({ path = TREE .. '/apple.txt', dir = false, depth = 0 }, entries[4])
    -- the arrow is 3 bytes, then a space
    h.eq({ indent = 0, name_start = 4, name_end = 10, group = 'Directory', tags = {} }, marks[1])
    h.eq({ indent = 0, name_start = 2, name_end = 11, group = nil, tags = {} }, marks[4])
end

function T.test_build_link_and_exec_tags_and_colors()
    local files = h.files()
    local _, _, marks = files.build(TREE)
    h.eq('lsptagbarFileLink', marks[3].group)
    h.eq({ { '(sym)', 'lsptagbarFileLink' } }, marks[3].tags)
    h.eq({ { '(sym)', 'lsptagbarFileLink' } }, marks[5].tags)
    h.eq('lsptagbarFileExec', marks[6].group)
    h.eq({ { '(exc)', 'lsptagbarFileExec' } }, marks[6].tags)
end

function T.test_build_open_folders_nest_with_parent_lines()
    local files = h.files()
    files.open_dirs[TREE .. '/alpha'] = true
    files.open_dirs[TREE .. '/alpha/nested'] = true
    local lines, entries, marks = files.build(TREE)
    h.eq({ '▾ alpha/', '  ▾ nested/', '      deep.txt', '▸ Beta/', '▸ link_to_alpha/',
        '  apple.txt', '  link_file', '  run.sh', '  Zeta.txt' }, lines)
    h.eq(nil, entries[1].parent)
    h.eq(1, entries[2].parent)
    h.eq({ path = TREE .. '/alpha/nested/deep.txt', dir = false, parent = 2, depth = 2 }, entries[3])
    h.eq(nil, entries[4].parent)
    h.eq({ indent = 4, name_start = 6, name_end = 14, group = nil, tags = {} }, marks[3])
end

function T.test_reveal_opens_parent_folders()
    local files = h.files()
    files.root = TREE
    h.truthy(files.reveal(TREE .. '/alpha/nested/deep.txt'))
    h.eq({ [TREE .. '/alpha'] = true, [TREE .. '/alpha/nested'] = true }, files.open_dirs)
    h.eq(nil, files.show_hidden)
end

function T.test_reveal_dotfile_shows_hidden()
    local files = h.files()
    files.root = TREE
    h.truthy(files.reveal(TREE .. '/.dotdir/secret.txt'))
    h.eq(true, files.show_hidden)
    h.eq({ [TREE .. '/.dotdir'] = true }, files.open_dirs)
end

function T.test_reveal_outside_root_is_refused()
    local files = h.files()
    files.root = TREE .. '/alpha'
    h.eq(false, files.reveal(TREE .. '/alphabet/x.txt'))
    h.eq(false, files.reveal(TREE .. '/Beta/inner.txt'))
    h.eq({}, files.open_dirs)
    files.root = nil
    h.eq(false, files.reveal(TREE .. '/apple.txt'))
end

function T.test_open_recursive_skips_symlinked_folders()
    local files = h.files()
    files.root = TREE
    files.open_recursive(TREE)
    h.eq({
        [TREE] = true,
        [TREE .. '/alpha'] = true,
        [TREE .. '/alpha/nested'] = true,
        [TREE .. '/Beta'] = true,
    }, files.open_dirs)
end

function T.test_add_file_and_folder()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(nil, files.add(tmp .. '/new/dir/file.txt'))
    h.eq(1, vim.fn.filereadable(tmp .. '/new/dir/file.txt'))
    h.eq(nil, files.add(tmp .. '/newfolder/'))
    h.eq(1, vim.fn.isdirectory(tmp .. '/newfolder'))
end

function T.test_add_refuses_existing()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(tmp .. '/apple.txt already exists', files.add(tmp .. '/apple.txt'))
    h.eq(tmp .. '/alpha/ already exists', files.add(tmp .. '/alpha/'))
    h.eq({ 'a' }, vim.fn.readfile(tmp .. '/apple.txt'))
end

function T.test_move_file_into_new_folder()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(nil, files.move(tmp .. '/apple.txt', tmp .. '/fruit/apple.txt'))
    h.eq(0, vim.fn.filereadable(tmp .. '/apple.txt'))
    h.eq({ 'a' }, vim.fn.readfile(tmp .. '/fruit/apple.txt'))
end

function T.test_move_refuses_existing_target()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(tmp .. '/Zeta.txt already exists', files.move(tmp .. '/apple.txt', tmp .. '/Zeta.txt'))
    h.eq({ 'a' }, vim.fn.readfile(tmp .. '/apple.txt'))
end

function T.test_move_renames_loaded_buffer()
    local files = h.files()
    local tmp = vim.fn.resolve(h.copy_fixture('tree'))
    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/Beta/inner.txt'))
    local buf = vim.api.nvim_get_current_buf()
    h.eq(nil, files.move(tmp .. '/Beta', tmp .. '/Gamma'))
    h.eq(tmp .. '/Gamma/inner.txt', vim.api.nvim_buf_get_name(buf))
    vim.cmd('bwipeout! ' .. buf)
end

function T.test_copy_folder()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(nil, files.copy(tmp .. '/alpha', tmp .. '/alpha2'))
    h.eq({ 'deep' }, vim.fn.readfile(tmp .. '/alpha2/nested/deep.txt'))
    h.eq({ 'deep' }, vim.fn.readfile(tmp .. '/alpha/nested/deep.txt'))
    h.eq(tmp .. '/Zeta.txt already exists', files.copy(tmp .. '/apple.txt', tmp .. '/Zeta.txt'))
end

function T.test_delete_file_and_folder()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(nil, files.delete(tmp .. '/apple.txt'))
    h.eq(nil, vim.uv.fs_lstat(tmp .. '/apple.txt'))
    h.eq(nil, files.delete(tmp .. '/alpha'))
    h.eq(nil, vim.uv.fs_lstat(tmp .. '/alpha'))
end

function T.test_delete_symlink_keeps_its_target()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    h.eq(nil, files.delete(tmp .. '/link_to_alpha'))
    h.eq(nil, vim.uv.fs_lstat(tmp .. '/link_to_alpha'))
    h.eq({ 'deep' }, vim.fn.readfile(tmp .. '/alpha/nested/deep.txt'))
end

-- git won't commit a file named .git, so the fixture keeps it as `gitfile`
-- and it's renamed in the temp copy, like a worktree's .git file.
function T.test_project_root_finds_dot_git_file()
    local files = h.files()
    local tmp = vim.fn.resolve(h.copy_fixture('project'))
    assert(vim.uv.fs_rename(tmp .. '/gitfile', tmp .. '/.git'))
    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/sub/file.txt'))
    local buf = vim.api.nvim_get_current_buf()
    h.eq(tmp, files.project_root(buf))
    h.eq(tmp .. '/sub/file.txt', files.buf_path(buf))
    vim.cmd('bwipeout! ' .. buf)
end

function T.test_project_root_without_git_is_cwd()
    local files = h.files()
    local tmp = vim.fn.resolve(h.copy_fixture('project'))
    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/sub/file.txt'))
    local buf = vim.api.nvim_get_current_buf()
    h.eq(vim.fn.getcwd(), files.project_root(buf))
    vim.cmd('bwipeout! ' .. buf)
end

function T.test_buf_path_keeps_symlinked_folder()
    local files = h.files()
    vim.cmd('edit ' .. vim.fn.fnameescape(TREE .. '/link_to_alpha/nested/deep.txt'))
    local buf = vim.api.nvim_get_current_buf()
    h.eq(TREE .. '/link_to_alpha/nested/deep.txt', files.buf_path(buf))
    vim.cmd('bwipeout! ' .. buf)
end

function T.test_run_command_by_extension()
    local files = h.files()
    h.eq({ 'bash', TREE .. '/run.sh' }, files.run_command(TREE .. '/run.sh'))
    h.eq({ 'python3', '/x/tool.PY' }, files.run_command('/x/tool.PY'))
end

function T.test_run_command_opens_documents()
    local files = h.files()
    local opener = vim.fn.has('mac') == 1 and 'open' or 'xdg-open'
    h.eq({ opener, '/x/page.html' }, files.run_command('/x/page.html'))
end

function T.test_run_command_unknown_plain_file_is_nil()
    local files = h.files()
    h.eq(nil, files.run_command(TREE .. '/apple.txt'))
end

function T.test_run_command_executable_without_rule_runs_as_is()
    local files = h.files()
    local tmp = h.copy_fixture('tree')
    assert(vim.uv.fs_rename(tmp .. '/run.sh', tmp .. '/runme'))
    h.eq({ tmp .. '/runme' }, files.run_command(tmp .. '/runme'))
end

return T
