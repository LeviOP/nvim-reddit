return function()
    local state = require("nvim-reddit.state")
    local buffer = vim.api.nvim_get_current_buf()
    return state.folds[buffer][vim.v.lnum] or 0
end
