-- this file contains no error checking for speed. you'd have to do something
-- pretty messed up (setting foldexpr for non-reddit buffer) for this to error

local M = {}

function M.expr()
    return require("nvim-reddit.state").buffers[vim.api.nvim_get_current_buf()].foldlevels[vim.v.lnum] or 0
end

function M.text()
    local state = require("nvim-reddit.state")
    local reddit_buf = state.buffers[vim.api.nvim_get_current_buf()]
    local pos = { vim.v.foldstart - 1, 0 }
    local buf_marks = vim.api.nvim_buf_get_extmarks(reddit_buf.buffer, state.tns, pos, pos, { details = true, overlap = true })
    local mark = buf_marks[1] -- assume for speed ;)
    -- comments are the only thing that can be properly folded right now
    local thing = reddit_buf.mark_thing_map[mark[1]] ---@cast thing NvimReddit.Comment

    local line = (" "):rep(thing.padding + 2) .. thing.data.author .. " "
    if thing.data.score_hidden then
        line = line .. "[score hidden]"
    else
        line = line .. thing.data.score .. " point"
        if thing.data.score ~= 1 then
            line = line .. "s"
        end
    end

    line = line .. " "

    if thing.time_ago then
        line = line .. thing.time_ago
        if thing.time_ago_edited then
            line = line .. " " .. thing.time_ago_edited
        end
        line = line .. " "
    end

    if thing.data.replies == "" then
        line = line .. "(0 children)"
    else
        local children = #thing.data.replies.data.children
        line = line .. "(" .. children .. " " .. (children == 1 and "child" or "children") .. ")"
    end

    return line
end

return M
