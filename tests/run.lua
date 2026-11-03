-- Minimal test runner, no dependencies:
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/run.lua
-- Loads every tests/test_*.lua; each returns a table of test_* functions.

local dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
package.path = dir .. '/?.lua;' .. package.path

local passed, failed = 0, 0
for _, file in ipairs(vim.fn.sort(vim.fn.glob(dir .. '/test_*.lua', false, true))) do
    local mod = dofile(file)
    local names = vim.tbl_keys(mod)
    table.sort(names)
    for _, name in ipairs(names) do
        if name:match('^test_') then
            local ok, err = pcall(mod[name])
            local label = vim.fn.fnamemodify(file, ':t') .. '::' .. name
            if ok then
                passed = passed + 1
                io.write('PASS ' .. label .. '\n')
            else
                failed = failed + 1
                io.write('FAIL ' .. label .. '\n  ' .. tostring(err) .. '\n')
            end
        end
    end
end
io.write(('\n%d passed, %d failed\n'):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
