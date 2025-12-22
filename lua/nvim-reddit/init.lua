require("nvim-reddit.highlights")
local buffer = require("nvim-reddit.buffer")
local config = require("nvim-reddit.config")

vim.async = require("async")

local M = {}

---@param options NvimReddit.Config|nil
function M.setup(options)
    config.setup(options)

    vim.api.nvim_create_user_command("Reddit", function(opts)
        vim.async.run(function()
            buffer.open(opts.args:gsub("%s+$", ""))
        end)
    end, { nargs = "?" })
end

return M
