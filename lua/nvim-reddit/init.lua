require("nvim-reddit.highlights")
local buffer = require("nvim-reddit.buffer")
local config = require("nvim-reddit.config")
local state = require("nvim-reddit.state")
local util = require("nvim-reddit.util")

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

    local last_folded_line_count = nil
    vim.api.nvim_set_decoration_provider(state.ns, {
        on_win = function(_, winid, bufnr, _, botline)
            if vim.api.nvim_get_mode().mode ~= "n" then return false end

            if not state.buffers[bufnr] then return false end

            local folded_lines = 0
            local i = 1
            while i < botline do
                local fold_start, fold_end = vim.fn.foldclosed(i), vim.fn.foldclosedend(i)
                if fold_start ~= -1 and fold_end ~= -1 then
                    folded_lines = folded_lines + (fold_end - fold_start)
                    i = fold_end + 1
                else
                    i = i + 1
                end
            end
            if last_folded_line_count ~= folded_lines then
                last_folded_line_count = folded_lines
                vim.schedule(function()
                    local reddit_buf = state.buffers[bufnr]
                    for _, float in ipairs(reddit_buf.floats) do
                        local visible, draw = float:is_visible(winid)
                        if visible then
                            if not float.window or draw then
                                float:draw(winid, draw)
                            end
                        else
                            if float.window then
                                float.close_override = true
                                float:hide()
                            end
                        end
                    end
                end)
            end
        end
    })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "reddit://*",
        callback = function(args)
            buffer.open(args.match:sub(10), args.buf)
        end,
    })

    vim.api.nvim_create_autocmd("WinScrolled", {
        callback = function(args)
            local reddit_buf = state.buffers[args.buf]
            if not reddit_buf then
                return
            end

            local window = tonumber(args.match, 10)
            for _, float in ipairs(reddit_buf.floats) do
                local visible, draw = float:is_visible(window)
                if visible then
                    if not float.window or draw then
                        float:draw(window, draw)
                    end
                else
                    if float.window then
                        float:hide()
                    end
                end
            end
        end
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function(args)
            local window = tonumber(args.match, 10)
            local float = state.win_float_map[window]
            if not float then
                return
            end

            local reddit_buf = float.reddit_buf
            if float.close_override then
                float.close_override = nil
                return
            end

            local row = vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, state.ns, float.mark, {})[1]
            util.array_remove_range(reddit_buf.foldlevels, row + 1, row + 2)

            vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
            vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, row + 2, true, {})
            vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

            vim.api.nvim_buf_del_extmark(reddit_buf.buffer, state.ns, float.mark)

            float.replying_to.reply_float = nil
            state.win_float_map[float.window] = nil

            for i, f in ipairs(reddit_buf.floats) do
                if f == float then
                    table.remove(reddit_buf.floats, i)
                    return
                end
            end
        end
    })

    vim.api.nvim_create_user_command("RedditFetch", function(args)
        coroutine.wrap(function()
            state.reddit_guard()

            local response, err = state.reddit:fetch(args.args)
            if err then
                vim.print(err)
                return
            end ---@cast response -?

            local formatted = vim.fn.systemlist("jq .", response.rawdata)
            if vim.v.shell_error ~= 0 then
                vim.notify("Failed to format JSON with jq", vim.log.levels.ERROR)
                return
            end

            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_set_option_value("filetype", "json", { buf = buf })
            vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
            vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

            vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted)

            vim.api.nvim_set_current_buf(buf)
        end)()
    end, { nargs = 1 })

    vim.api.nvim_create_user_command("Reddit", function(args)
        local path = args.args:gsub("%s+$", "")
        buffer.open(path)
    end, { nargs = "?" })
end

return M
