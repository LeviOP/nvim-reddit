---@class (exact) NvimReddit.State
---@field reddit NvimReddit.RedditClient|nil
---@field ns integer
---@field tns integer
---@field config NvimReddit.Config
---@field buffers table<integer, NvimReddit.Buffer>
local M = {
    ns = vim.api.nvim_create_namespace("nvim_reddit"),
    tns = vim.api.nvim_create_namespace("nvim_reddit_things"),
    buffers = {}
}

return M
