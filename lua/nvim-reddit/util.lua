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

    ---@type string|nil
    local subreddit = nil
    ---@type string|nil
    local user = nil
    ---@type NvimReddit.EndpointType
    local type = "listing"

    local r = path:match("^/r/([^/]+)")
    local u = path:match("^/user/([^/]+)") or path:match("^/u/([^/]+)")

    if r then
        subreddit = r
        path = path:gsub("^/r/[^/]+", "")
    elseif u then
        subreddit = "u_" .. u
        user = u
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
    }
end

---draw "rendered" (formatted) lines along with their marks to a buffer
---@param reddit_buf NvimReddit.Buffer
---@param ns integer
---@param tns integer
---@param lines string[]
---@param marks NvimReddit.Mark[]
---@param things NvimReddit.ThingMark[]
---@param foldlevels NvimReddit.FoldLevels
---@param start_line integer
---@param end_line? integer
function M.draw(reddit_buf, ns, tns, lines, marks, things, foldlevels, start_line, end_line)
    end_line = end_line or -1

    local buffer_foldlevels = require("nvim-reddit.state").folds[reddit_buf.buffer]
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
