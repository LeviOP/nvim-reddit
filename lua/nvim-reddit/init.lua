require("nvim-reddit.highlights")
local buffer = require("nvim-reddit.buffer")
local config = require("nvim-reddit.config")

vim.async = require("async")

local M = {}

local function setup_dev_icons()
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok then
        return
    end

    devicons.set_icon({
        reddit = {
            icon = "󰑍",
            color = "#FF4500",
            cterm_color = "202",
            name = "Reddit"
        }
    })
    devicons.set_icon_by_filetype({
        reddit = "reddit"
    })
end

---@param options NvimReddit.Config|nil
function M.setup(options)
    config.setup(options)

    if config.icons then
        setup_dev_icons()
    end

    vim.api.nvim_create_user_command("Reddit", function(opts)
        vim.async.run(function()
            buffer.open(opts.args:gsub("%s+$", ""))
        end)
    end, { nargs = "?" })
end

return M
