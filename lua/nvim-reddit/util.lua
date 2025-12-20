local uv = vim.uv

local M = {}

---@param created_utc integer
---@return string
function M.time_ago(created_utc)
    local now = os.time()
    local diff = now - created_utc

    local seconds = diff
    local minutes = math.floor(seconds / 60)
    local hours   = math.floor(minutes / 60)
    local days    = math.floor(hours / 24)
    local weeks   = math.floor(days / 7)
    local months  = math.floor(days / 30)
    local years   = math.floor(days / 365)

    if seconds < 60 then
        return seconds .. " seconds ago"
    elseif minutes < 60 then
        return minutes .. " minutes ago"
    elseif hours < 24 then
        return hours .. " hours ago"
    elseif days < 7 then
        return days .. " days ago"
    elseif weeks < 5 then
        return weeks .. " weeks ago"
    elseif months < 12 then
        return months .. " months ago"
    else
        return years .. " years ago"
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

---@class (exact) NvimReddit.ParsedEndpoint
---@field type NvimReddit.EndpointType
---@field subreddit string|nil

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
    ---@type NvimReddit.EndpointType
    local type = "listing"

    local sub = path:match("^/r/([^/]+)")
    local user = path:match("^/user/([^/]+)")

    if sub then
        subreddit = sub
        path = path:gsub("^/r/[^/]+", "")
    elseif user then
        subreddit = "u_" .. user
        path = path:gsub("^/user/[^/]+", "")
    end

    if path:match("^/comments/") then
        type = "article"
    end

    return {
        type = type,
        subreddit = subreddit,
    }
end

---draw "rendered" (formatted) lines along with their marks to a buffer
---@param reddit_buf NvimReddit.Buffer
---@param ns integer
---@param tns integer
---@param lines string[]
---@param marks NvimReddit.Mark[]
---@param things NvimReddit.ThingMark[]
---@param line integer
function M.draw(reddit_buf, ns, tns, lines, marks, things, line)
    vim.api.nvim_buf_set_lines(reddit_buf.buffer, line, -1, false, lines)
    for _, mark in ipairs(marks) do
        mark.details.end_row = mark.line
        mark.details.end_col = mark.end_col
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, mark.line, mark.start_col, mark.details)
    end
    for _, thing in ipairs(things) do
        local mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, tns, thing.start_line, 0, {
            end_row = thing.start_line + thing.lines,
            end_col = 0,
            strict = false
        })
        reddit_buf.mark_thing_map[mark] = thing.thing
    end
end

return M
