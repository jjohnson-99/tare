-- lua/tare/syntax.lua
--
-- Treesitter -> highlight spans for the base side of a file. This half of the
-- plugin reads a syntax tree and returns data; it never places an extmark, sets
-- an option or touches a buffer. autoload/tare/syntax.vim caches the result and
-- autoload/tare.vim cuts removed lines into chunks with it.
--
-- Columns are BYTE offsets into a line, as treesitter gives them; display width
-- is the caller's concern.

local M = {}

-- Captures that steer spell checking, which a virtual line never gets.
local SPELL = { spell = true, nospell = true }


--=================================================

-- Every highlight capture of every tree, injected ones included, as
-- per-row lists of { start_col, end_col, priority, order, group }. `order` is
-- the order Neovim's highlighter places its marks in: trees parent first, then
-- captures as the query yields them.
local function captures(parser, text, lines)
    local rows = {}
    for row = 1, #lines do
        rows[row] = {}
    end
    local order = 0
    parser:for_each_tree(function(tstree, ltree)
        local lang = ltree:lang()
        local query = vim.treesitter.query.get(lang, "highlights")
        if not query then
            return
        end
        for id, node, metadata in query:iter_captures(tstree:root(), text) do
            local name = query.captures[id]
            if name:sub(1, 1) ~= "_" and not SPELL[name] then
                local range = vim.treesitter.get_range(node, text, metadata[id])
                local priority = tonumber(metadata.priority
                    or metadata[id] and metadata[id].priority)
                    or vim.hl.priorities.treesitter
                local group = "@" .. name .. "." .. lang
                order = order + 1
                -- A capture over several lines covers each to its end.
                for row = range[1], math.min(range[4], #lines - 1) do
                    local s = row == range[1] and range[2] or 0
                    local e = row == range[4] and range[5] or #lines[row + 1]
                    if e > s then
                        table.insert(rows[row + 1], { s, e, priority, order, group })
                    end
                end
            end
        end
    end)
    return rows
end

-- One row's captures cut into non-overlapping { start_col, end_col, groups }.
-- `groups` lists every capture over the span, lowest priority first and, at
-- one priority, in placement order: later groups win where both set a colour,
-- as overlapping extmarks combine.
local function spans(caps)
    table.sort(caps, function(a, b)
        if a[3] ~= b[3] then return a[3] < b[3] end
        return a[4] < b[4]
    end)
    local cuts, seen = {}, {}
    for _, c in ipairs(caps) do
        for i = 1, 2 do
            if not seen[c[i]] then
                seen[c[i]] = true
                cuts[#cuts + 1] = c[i]
            end
        end
    end
    table.sort(cuts)

    local out = {}
    for i = 1, #cuts - 1 do
        local s, e = cuts[i], cuts[i + 1]
        local groups = {}
        for _, c in ipairs(caps) do
            if c[1] <= s and c[2] >= e then
                -- A group repeated adds nothing but where it last applies.
                for j = #groups, 1, -1 do
                    if groups[j] == c[5] then
                        table.remove(groups, j)
                    end
                end
                groups[#groups + 1] = c[5]
            end
        end
        local last = out[#out]
        if #groups == 0 then
            -- Left to the caller's own group.
        elseif last and last[2] == s
            and table.concat(last[3], ",") == table.concat(groups, ",") then
            last[2] = e
        else
            out[#out + 1] = { s, e, groups }
        end
    end
    return out
end


--=================================================

-- `lines` is a whole file, parsed as one text so a construct spanning lines
-- (a block comment, a raw string) colours each of them. Returns one list of
-- spans per line, or nil when `filetype` has no parser or no highlights
-- query, or the parse fails.
function M.spans(lines, filetype)
    local lang = filetype ~= "" and vim.treesitter.language.get_lang(filetype)
    if not lang then
        return nil
    end
    local ok, result = pcall(function()
        if not vim.treesitter.query.get(lang, "highlights") then
            return nil
        end
        local text = table.concat(lines, "\n") .. "\n"
        local parser = vim.treesitter.get_string_parser(text, lang)
        parser:parse(true)
        local rows = captures(parser, text, lines)
        for row = 1, #rows do
            rows[row] = spans(rows[row])
        end
        return rows
    end)
    return ok and result or nil
end


return M
