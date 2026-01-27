---@alias NvimReddit.Mode "normal" | "post"

---@class NvimReddit.State
---@field reddit NvimReddit.RedditClient|nil
---@field ns integer
---@field tns integer
---@field sns integer
---@field buffers table<integer, NvimReddit.Buffer>
---@field mode NvimReddit.Mode
---@field rolling_spoiler_id integer
local M = {
    ns = vim.api.nvim_create_namespace("nvim_reddit"),
    tns = vim.api.nvim_create_namespace("nvim_reddit_things"),
    sns = vim.api.nvim_create_namespace("nvim_reddit_spoilers"),
    buffers = {},
    mode = "normal",
    rolling_spoiler_id = 0,
}

local config = require("nvim-reddit.config")
local expand

---@param buffer integer
---@param dir -1|1
function M.jump(buffer, dir)
    local cur_pos = vim.api.nvim_win_get_cursor(0)
    local cur_row = cur_pos[1] - 1
    local thing_marks = vim.api.nvim_buf_get_extmarks(buffer, M.tns, {0, 0}, {-1, -1}, {})

    local closest_thing_mark
    local closest_row
    if dir == 1 then
        for _, thing_mark in ipairs(thing_marks) do
            local row = thing_mark[2]
            if row < cur_row and (not closest_row or row > closest_row) and vim.fn.foldclosed(row) == -1 then
                closest_thing_mark = thing_mark[1]
                closest_row = row
            end
        end
    else
        for _, thing_mark in ipairs(thing_marks) do
            local row = thing_mark[2]
            if row > cur_row and (not closest_row or row < closest_row) and vim.fn.foldclosed(row) == -1 then
                closest_thing_mark = thing_mark[1]
                closest_row = row
            end
        end
    end

    if not closest_row then
        return
    end


    if config.post_mode_auto_open then
        local reddit_buf = M.buffers[buffer]
        local selected_mark = reddit_buf.selected_mark_id
        if not selected_mark then
            goto bail
        end

        local thing = reddit_buf.mark_thing_map[selected_mark]
        if thing.kind ~= "t3" or not thing.open then
            goto bail
        end

        local new_thing = reddit_buf.mark_thing_map[closest_thing_mark]
        if new_thing.kind ~= "t3" then
            goto bail
        end

        if not expand then
            expand = require("nvim-reddit.expand")
        end

        -- the start and end points aren't needed when closing
        expand.link(thing, reddit_buf, 0, 0)

        local thing_mark_start, _, thing_details = unpack(vim.api.nvim_buf_get_extmark_by_id(buffer, M.tns, closest_thing_mark, { details = true }))
        local thing_end_row = thing_details.end_row
        -- if we close the last thing, the offset of the new thing is going to be different, so we update it
        closest_row = thing_mark_start


        if not new_thing.open then
            expand.link(new_thing, reddit_buf, thing_mark_start, thing_end_row)
        end

        ::bail::
    end

    local _, _, thing_details = unpack(vim.api.nvim_buf_get_extmark_by_id(buffer, M.tns, closest_thing_mark, { details = true }))
    local thing_end_row = thing_details.end_row

    -- it's simpler to move the cursor to the bottom of the thing we're jumping
    -- to than to calculate what the bottom of the window is and what we should
    -- set the topline to to make it fit on screen accounting for folds
    vim.api.nvim_win_set_cursor(0, { thing_end_row, cur_pos[2] })
    vim.api.nvim_win_set_cursor(0, { closest_row + 1, cur_pos[2] })
end

local lualine

---@param mode NvimReddit.Mode
function M.set_mode(mode)
    if mode == M.mode then
        return
    end

    if mode == "post" then
        for buffer, _ in pairs(M.buffers) do
            M.mode = "post"
            vim.keymap.set("n", "j", function()
                M.jump(buffer, -1)
            end, { buffer = buffer })
            vim.keymap.set("n", "k", function()
                M.jump(buffer, 1)
            end, { buffer = buffer })
        end
    else
        for buffer, _ in pairs(M.buffers) do
            vim.keymap.del("n", "j", { buffer = buffer })
            vim.keymap.del("n", "k", { buffer = buffer })
            M.mode = "normal"
        end
    end

    if config.refresh_lualine then
        if not lualine then
            lualine = require("lualine")
        end
        lualine.refresh()
    end
end

function M.lualine()
    return {
        function()
            return M.mode == "post" and "POST" or ""
        end,
        cond = function()
            return vim.bo.filetype == "reddit"
        end,
        separator = {
            left = "",
            right = ""
        },
        color = "RedditModeStatus",
    }
end

return M
