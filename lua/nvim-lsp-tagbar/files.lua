-- File tree view, NERDTree style: folders first, opened in place, rooted at
-- the current file's git checkout. Paths are kept as reached, never
-- resolved, so a file under a symlinked folder shows under that folder.
-- Names are colored by git state against the same base as the hunks
-- (git_base / g:git_diff_base / HEAD), and git-ignored, symlinked,
-- hard-linked and executable entries get a `(ign)` / `(sym)` / `(hard)` /
-- `(exc)` tag after the name.

local config = require('nvim-lsp-tagbar.config')
local hunks = require('nvim-lsp-tagbar.hunks')

local uv = vim.uv

local M = {}

-- kept across opens of the bar for this nvim session, like NERDTree's tree
M.root = nil
M.open_dirs = {}
-- folders closed in the changed-files view, where every folder starts open
M.closed_changed = {}
-- nil until first used, then config files.show_hidden; `I` flips it
M.show_hidden = nil

local function opts()
    return config.options.files
end

local function join(dir, name)
    return dir == '/' and ('/' .. name) or (dir .. '/' .. name)
end

-- Absolute path with `.` and `..` dropped, symlinks left as they are.
function M.normalize(path)
    local parts = {}
    for p in path:gmatch('[^/]+') do
        if p == '..' then
            table.remove(parts)
        elseif p ~= '.' then
            parts[#parts + 1] = p
        end
    end
    return '/' .. table.concat(parts, '/')
end

-- Full path of a buffer's file as it was opened, symlinked folders kept.
-- The buffer's full name has links resolved; bufname() keeps the path as
-- typed (relative to the cwd), so that one is used when it's the same file.
function M.buf_path(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) or vim.bo[buf].buftype ~= '' then
        return nil
    end
    local name = vim.fn.bufname(buf)
    if name == '' then
        return nil
    end
    if name == '~' or name:sub(1, 2) == '~/' then
        name = vim.env.HOME .. name:sub(2)
    end
    local full = M.normalize(name:sub(1, 1) == '/' and name or (vim.fn.getcwd() .. '/' .. name))
    local real = vim.api.nvim_buf_get_name(buf)
    if vim.fn.resolve(full) ~= vim.fn.resolve(real) then
        full = real
    end
    local hook = opts().path
    if hook then
        full = hook(full) or full
    end
    return full
end

-- Git checkout of the buffer's file as reached through its path, else the
-- cwd: the nearest folder up the unresolved path holding a `.git` (a folder,
-- or a file in a worktree). Not `git rev-parse`, which resolves links.
function M.project_root(buf)
    local path = M.buf_path(buf)
    local dir = path and vim.fs.dirname(path) or vim.fn.getcwd()
    -- inside a git dir: the checkout it belongs to, found from a worktree's
    -- gitdir file (<checkout>/.git), else the folder holding .git
    local wt = dir:match('^(.*/%.git/worktrees/[^/]+)')
    if wt then
        local f = io.open(wt .. '/gitdir')
        if f then
            local line = f:read('*l')
            f:close()
            if line then
                return vim.fs.dirname(vim.trim(line))
            end
        end
    end
    local in_git = (dir .. '/'):match('^(.-)/%.git/')
    if in_git then
        return in_git
    end
    while dir ~= '/' and dir ~= '' do
        if uv.fs_stat(dir .. '/.git') then
            return dir
        end
        dir = vim.fs.dirname(dir)
    end
    return vim.fn.getcwd()
end

-- Git state under a root: dirty files and the folders holding them, and
-- ignored paths (an ignored folder is listed once and covers its contents).
-- Re-queried at most every few seconds.
local git = { key = nil, at = 0, dirty = {}, ignored = {}, stat = {} }
local GIT_TTL_MS = 3000
local NO_GIT = { dirty = {}, ignored = {}, stat = {} }

-- Lines in an untracked file, all of them added; nil for a big or unreadable one.
local function line_count(path)
    local st = uv.fs_stat(path)
    if not st or st.type ~= 'file' or st.size > 1024 * 1024 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and #lines or nil
end

function M.invalidate_git()
    git.key = nil
end

function M.git_status(root)
    if not opts().git then
        return NO_GIT
    end
    local base = hunks.base_ref()
    local key = root .. '@' .. base
    local now = uv.now()
    if git.key == key and now - git.at < GIT_TTL_MS then
        return git
    end
    -- stat: path -> { added, removed } lines, or { binary = true }
    local dirty, ignored, stat = {}, {}, {}
    local function run(args)
        return vim.system(vim.list_extend({ 'git', '-C', root }, args), { text = true })
    end
    if run({ 'rev-parse', '--git-dir' }):wait().code == 0 then
        -- paths relative to the root (not the git toplevel), so a symlinked root matches
        local diff = run({ 'diff', '--numstat', '--no-renames', '--relative', base })
        local untracked = run({ 'ls-files', '--others', '--exclude-standard' })
        local ign = run({ 'ls-files', '--others', '--ignored', '--exclude-standard', '--directory' })
        local function mark(path)
            dirty[path] = 'file'
            local dir = vim.fs.dirname(path)
            while #dir > #root and not dirty[dir] do
                dirty[dir] = 'dir'
                dir = vim.fs.dirname(dir)
            end
        end
        -- `added<TAB>removed<TAB>path`, `-` for both on a binary file
        for line in (diff:wait().stdout or ''):gmatch('[^\n]+') do
            local added, removed, rel = line:match('^(%S+)\t(%S+)\t(.+)$')
            if rel then
                local path = join(root, rel)
                mark(path)
                stat[path] = added == '-' and { binary = true } or { tonumber(added), tonumber(removed) }
            end
        end
        for rel in (untracked:wait().stdout or ''):gmatch('[^\n]+') do
            local path = join(root, rel)
            mark(path)
            local n = line_count(path)
            stat[path] = n and { n, 0 } or nil
        end
        for rel in (ign:wait().stdout or ''):gmatch('[^\n]+') do
            ignored[join(root, (rel:gsub('/$', '')))] = true
        end
    end
    git.key, git.at, git.dirty, git.ignored, git.stat = key, now, dirty, ignored, stat
    return git
end

local function visible(name)
    if M.show_hidden == nil then
        M.show_hidden = opts().show_hidden
    end
    if not M.show_hidden and name:sub(1, 1) == '.' then
        return false
    end
    for _, pattern in ipairs(opts().ignore or {}) do
        if name:find(pattern) then
            return false
        end
    end
    return true
end

-- Folder entries, folders first, then by name ignoring case.
function M.list_dir(dir)
    local handle = uv.fs_scandir(dir)
    if not handle then
        return {}
    end
    local out = {}
    while true do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if visible(name) then
            local path = join(dir, name)
            local is_dir = kind == 'directory'
            if kind == 'link' then
                local st = uv.fs_stat(path)
                is_dir = st ~= nil and st.type == 'directory'
            end
            out[#out + 1] = { name = name, path = path, dir = is_dir }
        end
    end
    table.sort(out, function(a, b)
        if a.dir ~= b.dir then
            return a.dir
        end
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then
            return la < lb
        end
        return a.name < b.name
    end)
    return out
end

-- 'sym' for a symlink, 'hard' for a file with other hard links to it,
-- 'exc' for an executable file, else nil.
function M.link_kind(path)
    local st = uv.fs_lstat(path)
    if not st then
        return nil
    end
    if st.type == 'link' then
        return 'sym'
    elseif st.type ~= 'file' then
        return nil
    elseif st.nlink > 1 then
        return 'hard'
    end
    -- 73 == 0o111, any execute bit
    return bit.band(st.mode, 73) ~= 0 and 'exc' or nil
end

local KIND_GROUP = { sym = 'lsptagbarFileLink', hard = 'lsptagbarFileLink', exc = 'lsptagbarFileExec' }

-- The tree under root, one line per shown entry: `lines`, `entries` (path,
-- dir, parent line, depth) and `marks` (byte columns of the arrow and name,
-- the name's highlight group, and the tags shown after it). With only_dirty,
-- just the entries git sees as changed, every folder holding one opened.
function M.build(root, only_dirty)
    local status = M.git_status(root)
    local arrows = opts().arrows
    local lines, entries, marks = {}, {}, {}
    local function walk(dir, depth, parent, ignored_parent)
        for _, item in ipairs(M.list_dir(dir)) do
            if only_dirty and not status.dirty[item.path] then
                goto continue
            end
            local is_open = item.dir and (only_dirty and not M.closed_changed[item.path] or not only_dirty and M.open_dirs[item.path]) or false
            local indent = string.rep('  ', depth)
            local prefix = indent .. (item.dir and ((is_open and arrows.open or arrows.closed) .. ' ') or '  ')
            local shown = item.name .. (item.dir and '/' or '')
            lines[#lines + 1] = prefix .. shown
            local kind = M.link_kind(item.path)
            local tags = {}
            -- `+n -n` lines changed vs the git base, a side left out when it's 0
            local st = status.stat[item.path]
            if st then
                if st.binary then
                    tags[#tags + 1] = { 'bin', 'lsptagbarGitStat' }
                else
                    if st[1] > 0 then
                        tags[#tags + 1] = { '+' .. st[1], 'lsptagbarGitAdded' }
                    end
                    if st[2] > 0 then
                        if #tags > 0 then
                            tags[#tags + 1] = { ' ', 'Normal' }
                        end
                        tags[#tags + 1] = { '-' .. st[2], 'lsptagbarGitRemoved' }
                    end
                end
            end
            if kind then
                if #tags > 0 then
                    tags[#tags + 1] = { ' ', 'Normal' }
                end
                tags[#tags + 1] = { '(' .. kind .. ')', KIND_GROUP[kind] }
            end
            -- only on the ignored entry itself, not repeated for what's inside an ignored folder
            if status.ignored[item.path] then
                if #tags > 0 then
                    tags[#tags + 1] = { ' ', 'Normal' }
                end
                tags[#tags + 1] = { '(ign)', 'lsptagbarGitIgnored' }
            end
            local ignored = ignored_parent or status.ignored[item.path] or false
            local dirty = status.dirty[item.path]
            -- git state wins the name's color; link/exec color only shows on clean entries
            local group = (dirty == 'file' and 'lsptagbarGitDirtyFile')
                or (dirty == 'dir' and 'lsptagbarGitDirtyDir')
                or (ignored and 'lsptagbarGitIgnored')
                or (kind and KIND_GROUP[kind])
                or (item.dir and 'Directory')
                or nil
            entries[#entries + 1] = { path = item.path, dir = item.dir, parent = parent, depth = depth }
            marks[#marks + 1] = {
                indent = #indent,
                name_start = #prefix,
                name_end = #prefix + #shown,
                group = group,
                tags = tags,
            }
            if is_open then
                walk(item.path, depth + 1, #lines, ignored)
            end
            ::continue::
        end
    end
    walk(root, 0, nil, false)
    return lines, entries, marks
end

-- Open every folder between the root and path, and show hidden files when
-- one of them (or the file) is a dotfile. False when path isn't under the root.
function M.reveal(path)
    if not (path and M.root) then
        return false
    end
    local prefix = M.root == '/' and '/' or (M.root .. '/')
    if path:sub(1, #prefix) ~= prefix then
        return false
    end
    local parts = vim.split(path:sub(#prefix + 1), '/', { plain = true })
    local dir = M.root
    for i = 1, #parts - 1 do
        dir = join(dir, parts[i])
        M.open_dirs[dir] = true
    end
    for _, p in ipairs(parts) do
        if p:sub(1, 1) == '.' then
            M.show_hidden = true
        end
    end
    return true
end

-- Changed files under the root in tree order (folders first, then names,
-- as listed), only the ones the tree would show.
function M.changed_files(root)
    local status = M.git_status(root)
    local out = {}
    local function walk(dir)
        for _, item in ipairs(M.list_dir(dir)) do
            local d = status.dirty[item.path]
            if d == 'dir' then
                walk(item.path)
            elseif d == 'file' then
                out[#out + 1] = item.path
            end
        end
    end
    walk(root)
    return out
end

-- Open a folder and every folder under it, skipping git-ignored ones and
-- symlinked ones (which could loop), with a cap for huge trees.
function M.open_recursive(dir)
    local status = M.git_status(M.root or dir)
    local count = 0
    local function walk(d, depth)
        M.open_dirs[d] = true
        count = count + 1
        if depth >= 20 or count >= 500 then
            return
        end
        for _, item in ipairs(M.list_dir(d)) do
            if item.dir and not status.ignored[item.path] and M.link_kind(item.path) ~= 'sym' then
                walk(item.path, depth + 1)
            end
        end
    end
    walk(dir, 0)
end

-- File operations for the `m` menu. Each returns nil on success, else an error message.

-- A trailing `/` makes a folder.
function M.add(path)
    if uv.fs_lstat((path:gsub('/$', ''))) then
        return path .. ' already exists'
    end
    if path:sub(-1) == '/' then
        if vim.fn.mkdir(path, 'p') == 1 then
            return nil
        end
        return 'could not create ' .. path
    end
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    if vim.fn.writefile({}, path) == 0 then
        return nil
    end
    return 'could not create ' .. path
end

-- Loaded buffers of `from` (or of files under it) take the new name; an
-- unchanged one is re-read from there so :w doesn't refuse it.
local function retarget_buffers(rfrom, to)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= '' and vim.bo[b].buftype == '' then
            local rest
            if name == rfrom then
                rest = ''
            elseif name:sub(1, #rfrom + 1) == rfrom .. '/' then
                rest = name:sub(#rfrom + 1)
            end
            if rest and pcall(vim.api.nvim_buf_set_name, b, to .. rest) and not vim.bo[b].modified then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd('silent! edit')
                end)
            end
        end
    end
end

function M.move(from, to)
    if uv.fs_lstat(to) then
        return to .. ' already exists'
    end
    local rfrom = vim.fn.resolve(from)
    vim.fn.mkdir(vim.fs.dirname(to), 'p')
    local ok, err = uv.fs_rename(from, to)
    if not ok then
        return err
    end
    retarget_buffers(rfrom, vim.fn.resolve(to))
    return nil
end

function M.copy(from, to)
    if uv.fs_lstat(to) then
        return to .. ' already exists'
    end
    vim.fn.mkdir(vim.fs.dirname(to), 'p')
    local res = vim.system({ 'cp', '-R', from, to }, { text = true }):wait()
    if res.code == 0 then
        return nil
    end
    return vim.trim(res.stderr or 'copy failed')
end

function M.delete(path)
    -- vim.fn.delete removes a symlink itself, not what it points to
    local flags = M.link_kind(path) ~= 'sym' and vim.fn.isdirectory(path) == 1 and 'rf' or ''
    if vim.fn.delete(path, flags) == 0 then
        return nil
    end
    return 'could not delete ' .. path
end

-- Show the entry selected in a Finder window (macOS); returns nil on success.
function M.reveal_in_finder(path)
    if vim.fn.has('mac') == 0 then
        return 'reveal in Finder is macOS only'
    end
    local res = vim.system({ 'open', '-R', path }, { text = true }):wait()
    if res.code == 0 then
        return nil
    end
    return vim.trim(res.stderr or 'open -R failed')
end

-- How `x` in the menu runs a file, by extension: an interpreter, or `open`
-- for what's meant to be viewed. A file with an execute bit and no rule
-- here is run as is.
M.runners = {
    sh = { 'bash' }, bash = { 'bash' }, zsh = { 'zsh' },
    py = { 'python3' }, lua = { 'lua' }, js = { 'node' }, mjs = { 'node' }, ts = { 'npx', 'tsx' },
    rb = { 'ruby' }, pl = { 'perl' }, php = { 'php' }, go = { 'go', 'run' },
    html = { 'open' }, htm = { 'open' }, pdf = { 'open' }, svg = { 'open' }, png = { 'open' },
    jpg = { 'open' }, jpeg = { 'open' }, gif = { 'open' }, webp = { 'open' }, mp3 = { 'open' },
    mp4 = { 'open' }, mov = { 'open' }, csv = { 'open' }, xlsx = { 'open' }, docx = { 'open' },
    pptx = { 'open' }, zip = { 'open' }, app = { 'open' },
}

-- The command `x` runs for a path, or nil when it doesn't know how. `open`
-- only exists on macOS; xdg-open stands in elsewhere.
function M.run_command(path)
    local ext = (path:match('%.([^./]+)/?$') or ''):lower()
    local runner = M.runners[ext]
    if runner then
        local cmd = vim.deepcopy(runner)
        if cmd[1] == 'open' and vim.fn.has('mac') == 0 then
            cmd[1] = 'xdg-open'
        end
        cmd[#cmd + 1] = path
        return cmd
    end
    if M.link_kind(path) == 'exc' then
        return { path }
    end
    return nil
end

-- Colors from the user's NERDTree setup; own colors rather than Diff* links,
-- since some colorschemes' DiffChange is a near-invisible background.
function M.set_colors()
    local hl = vim.api.nvim_set_hl
    hl(0, 'lsptagbarGitDirtyFile', { default = true, bold = true, fg = '#aeee00', ctermfg = 154, cterm = { bold = true } })
    hl(0, 'lsptagbarGitDirtyDir', { default = true, fg = '#aeee00', ctermfg = 154 })
    hl(0, 'lsptagbarGitIgnored', { default = true, fg = '#767676', ctermfg = 243 })
    hl(0, 'lsptagbarFileLink', { default = true, fg = '#5fd7ff', ctermfg = 81 })
    hl(0, 'lsptagbarFileExec', { default = true, fg = '#af87ff', ctermfg = 141 })
    hl(0, 'lsptagbarFileArrow', { default = true, link = 'Directory' })
    hl(0, 'lsptagbarGitAdded', { default = true, link = 'Added' })
    hl(0, 'lsptagbarGitRemoved', { default = true, link = 'Removed' })
    hl(0, 'lsptagbarGitStat', { default = true, link = 'Comment' })
    -- the bar header's folder / file row: a soft blue, apart from the grey labels
    hl(0, 'lsptagbarHeaderFolder', { default = true, bold = true, fg = '#87afd7', ctermfg = 110, cterm = { bold = true } })
end

return M
