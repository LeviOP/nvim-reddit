---@alias NvimReddit.Mode "normal" | "post"

---@class NvimReddit.State
---@field reddit NvimReddit.RedditClient|nil
---@field ns integer
---@field tns integer
---@field config NvimReddit.Config
---@field buffers table<integer, NvimReddit.Buffer>
---@field mode NvimReddit.Mode
local M = {
    ns = vim.api.nvim_create_namespace("nvim_reddit"),
    tns = vim.api.nvim_create_namespace("nvim_reddit_things"),
    buffers = {},
    mode = "normal",
}

---@param buffer integer
---@param dir -1|1
function M.jump(buffer, dir)
    local cur_pos = vim.api.nvim_win_get_cursor(0)
    local cur_row = cur_pos[1] - 1
    local thing_marks = vim.api.nvim_buf_get_extmarks(buffer, M.tns, {0, 0}, {-1, -1}, {})

    local closest_row
    if dir == 1 then
        for _, thing_mark in ipairs(thing_marks) do
            local row = thing_mark[2]
            if row < cur_row and (not closest_row or row > closest_row) and vim.fn.foldclosed(row) == -1 then
                closest_row = row
            end
        end
    else
        for _, thing_mark in ipairs(thing_marks) do
            local row = thing_mark[2]
            if row > cur_row and (not closest_row or row < closest_row) and vim.fn.foldclosed(row) == -1 then
                closest_row = row
            end
        end
    end
    if closest_row then
        vim.api.nvim_win_set_cursor(0, { closest_row + 1, cur_pos[2] })
    end
end

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
end

return M
