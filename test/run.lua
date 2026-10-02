-- test/run.lua
--
-- Headless harness:
--
--   nvim --headless -u NONE -l test/run.lua
--
-- Sources each Vimscript suite below into this one editor and reports what it
-- left in v:errors. Exits non-zero on any failure so it can gate a commit.
--
-- `-u NONE` keeps the user's config out of the result; it also skips plugin/,
-- so plugin/tare.vim is sourced here by hand.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local test_dir = vim.fs.dirname(script)
local root = vim.fs.dirname(test_dir)

-- Neovim's own runtime and bundled parsers, and tare: the syntax goldens must
-- not follow parsers or queries the user has installed.
vim.opt.runtimepath = vim.tbl_filter(function(dir)
    return dir == vim.env.VIMRUNTIME or vim.endswith(dir, "/lib/nvim")
end, vim.opt.runtimepath:get())
vim.o.packpath = vim.env.VIMRUNTIME
vim.opt.runtimepath:append(root)
vim.cmd.runtime("plugin/tare.vim")

-- Suites build throwaway repositories: keep the user's git config and any
-- inherited repository out, and give tare a data directory of its own.
for _, name in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE" }) do
    vim.env[name] = nil
end
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME = "tare"
vim.env.GIT_AUTHOR_EMAIL = "tare@example.com"
vim.env.GIT_COMMITTER_NAME = "tare"
vim.env.GIT_COMMITTER_EMAIL = "tare@example.com"
local data_home = vim.fn.tempname()
vim.env.XDG_DATA_HOME = data_home

local SUITES = { "ops.vim", "invariant.vim", "view.vim", "highlight.vim", "git.vim", "popup.vim",
                 "syntax.vim" }

local failed = 0
for _, name in ipairs(SUITES) do
    vim.v.errors = {}
    local ok, err = pcall(vim.cmd.source, test_dir .. "/" .. name)
    local errors = vim.v.errors
    if not ok then
        errors[#errors + 1] = "aborted: " .. tostring(err)
    end
    if #errors == 0 then
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. " (" .. #errors .. ")")
        for _, e in ipairs(errors) do
            print("     " .. e)
        end
    end
end

vim.fn.delete(data_home, "rf")
print(string.format("\n%d suite(s), %d failed", #SUITES, failed))
os.exit(failed == 0 and 0 or 1)
