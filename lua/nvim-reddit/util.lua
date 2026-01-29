local state = require("nvim-reddit.state")

local ns = state.ns
local sns = state.sns
local tns = state.tns

local uv = vim.uv

local M = {}

---@param created_utc integer
---@return string
function M.time_ago(created_utc)
    return M.time_since(created_utc) .. " ago"
end

---@param created_utc integer
---@return string
function M.time_since(created_utc)
    local now = os.time()
    local diff = now - created_utc

    local function fmt(n, unit)
        if n == 1 then
            return n .. " " .. unit
        else
            return n .. " " .. unit .. "s"
        end
    end

    local seconds = diff
    local minutes = math.floor(seconds / 60)
    local hours   = math.floor(minutes / 60)
    local days    = math.floor(hours / 24)
    local weeks   = math.floor(days / 7)
    local months  = math.floor(days / 30)
    local years   = math.floor(days / 365)

    if seconds < 60 then
        return fmt(seconds, "second")
    elseif minutes < 60 then
        return fmt(minutes, "minute")
    elseif hours < 24 then
        return fmt(hours, "hour")
    elseif days < 7 then
        return fmt(days, "day")
    elseif weeks < 5 then
        return fmt(weeks, "week")
    elseif months < 12 then
        return fmt(months, "month")
    else
        return fmt(years, "year")
    end
end

---@param win integer
function M.get_window_text_width(win)
    local width = vim.api.nvim_win_get_width(win)

    --FIXME: use getwininfo().textoff
    -- local foldcol = vim.wo[win].foldcolumn
    -- local signcol = vim.wo[win].signcolumn
    local number = vim.wo[win].number and 1 or 0

    local number_width = 0
    if number ~= 0 then
        local max_num = vim.fn.line('$')
        number_width = #tostring(max_num)
    end

    number_width = math.max(number_width, vim.wo.numberwidth)

    local offset = number_width + 2
    return width - offset
end

function M.closure(func, ...)
    local fixed = { ... }
    local nfixed = select("#", ...)

    return function(...)
        local args = {}
        for i = 1, nfixed do
            args[i] = fixed[i]
        end
        local n = nfixed
        local nvar = select("#", ...)
        for i = 1, nvar do
            args[n + i] = select(i, ...)
        end
        return func(unpack(args, 1, n + nvar))
    end
end

---@param path string
---@return string|nil, string?, string?
function M.read_file(path)
    local fd, err, err_code = uv.fs_open(path, "r", 438) -- 666
    if err or not fd then
        return nil, err, err_code
    end

    local stat, err, err_code = uv.fs_stat(path)
    if err or not stat then
        uv.fs_close(fd)
        return nil, err, err_code
    end

    local contents, err, err_code = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if err then
        return nil, err, err_code
    end

    return contents
end

---@param path string
function M.ensure_dir(path)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
end

---@alias NvimReddit.EndpointType
---| "listing"
---| "article"
---| "about"

---@class (exact) NvimReddit.ParsedEndpoint
---@field type NvimReddit.EndpointType
---@field subreddit string|nil
---@field user string|nil
---@field params table<string, string>

---@param path string
---@return NvimReddit.ParsedEndpoint
function M.parse_reddit_endpoint(path)
    if path == "" then
        return {
            type = "listing",
            subreddit = nil,
        }
    end

    if not path:match("^/") then
        path = "/" .. path
    end

    -- This only handles query parameters with keys and values
    ---@type table<string, string>
    local params = {}
    local query_string = path:match("%?(.*)$")
    if query_string then
        for key, value in query_string:gmatch("([^&=]+)=([^&=]+)") do
            params[key] = value
        end
    end

    path = path:gsub("%?.*$", "")

    ---@type string|nil
    local subreddit = nil
    ---@type string|nil
    local user = nil
    ---@type NvimReddit.EndpointType
    local type = "listing"

    local r = path:match("^/r/([^/]+)")
    local u = path:match("^/user/([^/]+)") or path:match("^/u/([^/]+)")

    if r then
        subreddit = r:lower()
        path = path:gsub("^/r/[^/]+", "")
    elseif u then
        subreddit = "u_" .. u:lower()
        user = u:lower()
        path = path:gsub("^/u/[^/]+", ""):gsub("^/user/[^/]+", "")
    end

    if path:match("^/comments/") then
        type = "article"
    elseif path:match("^/about$") then
        type = "about"
    end

    return {
        type = type,
        subreddit = subreddit,
        user = user,
        params = params,
    }
end

---draw "rendered" (formatted) lines along with their marks to a buffer
---@param reddit_buf NvimReddit.Buffer
---@param lines string[]
---@param marks NvimReddit.Mark[]
---@param spoilers NvimReddit.Spoiler[]
---@param things NvimReddit.ThingMark[]
---@param foldlevels NvimReddit.FoldLevels
---@param start_line integer
---@param end_line? integer
function M.draw(reddit_buf, lines, marks, spoilers, things, foldlevels, start_line, end_line)
    end_line = end_line or -1

    local buffer_foldlevels = reddit_buf.foldlevels
    local old_line_count = end_line - start_line
    local new_line_count = #foldlevels
    -- sometimes the "more" comments are deleted or removed or something, meaning there is actually less to render.
    -- instead of handling that case directly (which could lead to other unforseen problems), we'll just check and render it correctly
    if new_line_count > old_line_count then
        for i, foldlevel in ipairs(foldlevels) do
            if i <= old_line_count then
                buffer_foldlevels[i + start_line] = foldlevel
            else
                table.insert(buffer_foldlevels, i + start_line, foldlevel)
            end
        end
    else -- this case also runs when they're equal. convenient optimization :-)
        for i, foldlevel in ipairs(foldlevels) do
            buffer_foldlevels[i + start_line] = foldlevel
        end
        M.array_remove_range(buffer_foldlevels, start_line + new_line_count + 1, end_line)
    end

    vim.api.nvim_buf_set_lines(reddit_buf.buffer, start_line, end_line, false, lines)

    for _, mark in ipairs(marks) do
        mark.line = mark.line + start_line
        mark.details.end_row = mark.line
        mark.details.end_col = mark.end_col
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, mark.line, mark.start_col, mark.details)
        -- local ok = pcall(vim.api.nvim_buf_set_extmark,reddit_buf.buffer, ns, mark.line, mark.start_col, mark.details)
        -- if not ok then
        --     vim.print(mark)
        -- end
    end

    for _, spoiler in ipairs(spoilers) do
        spoiler.line = spoiler.line + start_line
        spoiler.details.end_row = spoiler.line
        spoiler.details.end_col = spoiler.end_col
        local extmark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, sns, spoiler.line, spoiler.start_col, spoiler.details)
        local map = reddit_buf.spoiler_marks_map
        local spoiler_id = spoiler.spoiler
        if not map[spoiler_id] then
            map[spoiler_id] = {}
        end
        table.insert(map[spoiler_id], extmark)
    end

    for _, thing in ipairs(things) do
        thing.start_line = thing.start_line + start_line
        local mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, tns, thing.start_line, 0, {
            end_row = thing.start_line + thing.lines,
            end_col = 0,
            strict = false
        })
        reddit_buf.mark_thing_map[mark] = thing.thing
        thing.thing.mark = mark
    end
end

---@param top_parent NvimReddit.Comment|NvimReddit.Listing
---@param appended_things (NvimReddit.Comment|NvimReddit.More)[]
---@param remove_trailing boolean
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[], NvimReddit.ThingMark[], NvimReddit.FoldLevels
function M.render_appended_things(top_parent, appended_things, foldlevel, remove_trailing)
    ---@type table<string, NvimReddit.Comment|NvimReddit.Listing>
    local id_cache = {}
    if top_parent.kind == "t1" then
        id_cache["t1_" .. top_parent.data.id] = top_parent
    else
        id_cache[top_parent.data.children[1].data.link_id] = top_parent
    end
    ---@type (NvimReddit.Comment|NvimReddit.More)[]
    local base_things = {}

    for _, thing in ipairs(appended_things) do
        local parent = id_cache[thing.data.parent_id]
        if parent == nil then
            print("couldn't find parent?????")
            goto continue
        end

        if parent.kind == "t1" then
            if parent.data.replies == "" then
                parent.data.replies = {
                    kind = "Listing",
                    data = {
                        children = {},
                        after = vim.NIL,
                        before = vim.NIL,
                        dist = vim.NIL,
                    }
                }
            end
            table.insert(parent.data.replies.data.children, thing)
            if parent == top_parent then
                thing.padding = parent.padding + 2
                table.insert(base_things, thing)
            end
        else
            thing.padding = 0
            table.insert(parent.data.children, thing)
            table.insert(base_things, thing)
            if thing.kind == "more" then
                thing.link_id = thing.data.parent_id
                -- this should always be at the end of the array but why not calculate things to be sure? :-)
                thing.self_index = #parent.data.children
                thing.parent = parent
            end
        end
        -- we don't need to cache mores because they can't have children
        if thing.kind == "t1" then
            id_cache["t1_" .. thing.data.id] = thing
        end

        ::continue::
    end

    local render = require("nvim-reddit.render")

    ---@type string[]
    local lines = {}
    ---@type NvimReddit.Mark[]
    local marks = {}
    ---@type NvimReddit.Spoiler[]
    local spoilers = {}
    ---@type NvimReddit.ThingMark[]
    local things = {}
    ---@type NvimReddit.FoldLevels
    local foldlevels = {}
    local line = 0
    for _, thing in ipairs(base_things) do
        local thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels
        if thing.kind == "t1" then
            thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels = render.comment(thing, true)
        else
            thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels = render.more(thing)
        end
        for _, thing_line in ipairs(thing_lines) do
            table.insert(lines, thing_line)
        end
        for _, style_mark in ipairs(thing_style_marks) do
            style_mark.line = style_mark.line + line
            table.insert(marks, style_mark)
        end
        for _, spoiler in ipairs(thing_spoilers) do
            spoiler.line = spoiler.line + line
            table.insert(spoilers, spoiler)
        end
        for _, thing_mark in ipairs(thing_marks) do
            thing_mark.start_line = thing_mark.start_line + line
            table.insert(things, thing_mark)
        end
        for _, thing_foldlevel in ipairs(thing_foldlevels) do
            table.insert(foldlevels, thing_foldlevel)
        end
        line = line + #thing_lines
        table.insert(lines, "")
        table.insert(foldlevels, foldlevel)
        line = line + 1
    end

    if remove_trailing then
        -- remove trailing empty line. maybe this should be done some other way but.....
        lines[#lines] = nil
        foldlevels[#foldlevels] = nil
    end

    return lines, marks, spoilers, things, foldlevels
end

---@param array any[]
---@param lower integer
---@param upper integer
function M.array_remove_range(array, lower, upper)
    local n = #array
    local write = lower
    for read = upper + 1, n do
        array[write] = array[read]
        write = write + 1
    end
    for i = write, n do
        array[i] = nil
    end
end

return M
