local util = require("nvim-reddit.util")
local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local config = require("nvim-reddit.config")

local ns = state.ns
local tns = state.tns
local sns = state.sns

---@module "reddit-image"

local M = {}

---@class (exact) NvimReddit.Buffer
---@field buffer integer
---@field mark_thing_map table<integer, NvimReddit.Selectable>
---@field selected_mark_id integer|nil
---@field images table<string, Image>
---@field floats NvimReddit.Float[]
--- 1-indexed
---@field foldlevels NvimReddit.FoldLevels
---@field spoiler_marks_map table<integer, integer[]>
---@field endpoint_type NvimReddit.EndpointType|nil

---@param path string
---@param buffer integer|nil
function M.open(path, buffer)
    coroutine.wrap(function()
        if not buffer then
            buffer = vim.api.nvim_get_current_buf()
            if vim.bo[buffer].modified or vim.api.nvim_buf_get_name(buffer) ~= "" then
                buffer = vim.api.nvim_create_buf(true, true)
            end
            vim.api.nvim_buf_set_name(buffer, "reddit://" .. path)
        end
        vim.api.nvim_set_option_value("filetype", "reddit", { buf = buffer })
        vim.api.nvim_set_option_value("buftype", "nofile", { buf = buffer })
        vim.api.nvim_set_option_value("swapfile", false, { buf = buffer })

        -- FIXME: window stuff should maybe be separate in the future (sidebar)
        vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
        vim.api.nvim_set_option_value("foldexpr", "v:lua.require'nvim-reddit.fold'.expr()", { win = 0 })
        vim.api.nvim_set_option_value("foldtext", "v:lua.require'nvim-reddit.fold'.text()", { win = 0 })

        vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
            "Loading..."
        })
        vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
        vim.api.nvim_set_current_buf(buffer)

        ---@type NvimReddit.Buffer
        local reddit_buf = {
            buffer = buffer,
            mark_thing_map = {},
            selected_mark_id = nil,
            images = {},
            floats = {},
            closing = false,
            foldlevels = {},
            spoiler_marks_map = {},
        }

        local needs_setup = true
        if state.buffers[buffer] then
            needs_setup = false
        end

        state.buffers[buffer] = reddit_buf

        if needs_setup then
            vim.api.nvim_create_autocmd("BufDelete", {
                buffer = buffer,
                callback = function()
                    state.buffers[buffer] = nil
                end,
            })
            vim.api.nvim_create_autocmd("BufUnload", {
                buffer = buffer,
                callback = function(args)
                    -- this might be a little extra work because image.nvim already does this,
                    -- but it probably isn't really any difference
                    local reddit_buf = state.buffers[args.buf]
                    for _, image in pairs(reddit_buf.images) do
                        image:clear()
                    end
                end
            })
        end

        state.reddit_guard()

        if not state.me then
            local response, err = state.reddit:fetch("api/v1/me?raw_json=1")
            if err then
                vim.print(err)
                return
            end ---@cast response -?
            state.me = response.data
        end

        -- Maybe this isn't the best way to do things, but there's no reason
        -- to parse all of the params correctly or anything if this works fine
        if path:find("?") then
            path = path .. "&raw_json=1"
        else
            path = path .. "?raw_json=1"
        end

        local response, err = state.reddit:fetch(path)
        if err then
            vim.print(err)
            return
        end ---@cast response -?

        ---@type string|nil
        local newpath = response.location:match("^https://oauth%.reddit%.com/(.*)$")
        if not newpath then
            print("Couldn't get path from response location???", response.location)
        elseif newpath ~= path then
            path = newpath
            vim.schedule(function ()
                vim.api.nvim_buf_set_name(buffer, "reddit://" .. path)
            end)
        end

        local endpoint = util.parse_reddit_endpoint(path)
        -- it's nicer if we don't make the code (or user) deal with this
        endpoint.params["raw_json"] = nil

        reddit_buf.endpoint_type = endpoint.type

        vim.schedule(function()
            vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
            if endpoint.type == "listing" then
                ---@type NvimReddit.Listing
                local listing = response.data

                local lines, marks, spoilers, things, foldlevels = render.listing(listing, endpoint)
                util.draw(reddit_buf, lines, marks, spoilers, things, foldlevels, 0)
            elseif endpoint.type == "article" then
                ---@type NvimReddit.Listing
                local link_listing = response.data[1]
                ---@type NvimReddit.Listing
                local comments = response.data[2]

                link_listing.data.children[1].comments_listing = comments
                comments.comments_for_link = link_listing.data.children[1] --[[@as NvimReddit.Link]]

                local lines, marks, spoilers, things, foldlevels = render.listing(link_listing, endpoint)
                util.draw(reddit_buf, lines, marks, spoilers, things, foldlevels, 0)

                local c_lines, c_marks, c_spoilers, c_things, c_foldlevels = render.listing(comments, endpoint)
                util.draw(reddit_buf, c_lines, c_marks, c_spoilers, c_things, c_foldlevels, #lines)
            elseif endpoint.type == "about" then
                if endpoint.user then
                    --- TODO: user endpoints (not user subreddit, maybe should be normalized)
                    vim.print("user info not supported")
                else
                    ---@type NvimReddit.Subreddit
                    local subreddit = response.data
                    local lines, marks = render.sidebar(subreddit)
                    util.draw(reddit_buf, lines, marks, {}, {}, {}, 0)
                end
            end

            vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
            vim.api.nvim_win_set_cursor(0, {1, 0})

            if needs_setup then
                vim.api.nvim_create_autocmd("CursorMoved", {
                    buffer = buffer,
                    callback = M.cursor_moved,
                })

                vim.api.nvim_create_autocmd("BufWinEnter", {
                    buffer = buffer,
                    callback = function(args)
                        local reddit_buf = state.buffers[args.buf]

                        local window = vim.api.nvim_get_current_win()
                        for _, float in ipairs(reddit_buf.floats) do
                            local visible, draw = float:is_visible(window)
                            if visible then
                                float:draw(window, draw)
                            end
                        end
                        vim.schedule(function()
                            for _, image in pairs(reddit_buf.images) do
                                image:render()
                            end
                        end)
                    end,
                })

                vim.api.nvim_create_autocmd("BufWinLeave", {
                    buffer = buffer,
                    callback = function(args)
                        local reddit_buf = state.buffers[args.buf]

                        for _, float in ipairs(reddit_buf.floats) do
                            if float.window then
                                float:hide()
                            end
                        end
                    end
                })

                vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI", "InsertEnter" }, {
                    buffer = buffer,
                    callback = function(args)
                        local reddit_buf = state.buffers[args.buf]
                        local window = vim.api.nvim_get_current_win()
                        for _, float in ipairs(reddit_buf.floats) do
                            local moved = false
                            ---@type integer, integer
                            local row, col = unpack(vim.api.nvim_buf_get_extmark_by_id(args.buf, ns, float.mark, {}))
                            if float.row ~= row or float.col ~= col then
                                moved = true
                                float.row = row
                                float.col = col
                            end
                            local visible, draw = float:is_visible(window)
                            if visible then
                                -- this might be stupid
                                if not float.window or draw or moved then
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

                for _, keymap in ipairs(config.keymaps) do
                    vim.keymap.set(keymap[1], keymap[2], function()
                        local reddit_buf = state.buffers[vim.api.nvim_get_current_buf()]
                        if reddit_buf.selected_mark_id == nil then
                            return
                        end

                        local thing = reddit_buf.mark_thing_map[reddit_buf.selected_mark_id]
                        if thing == nil then
                            print("didn't find thing from selected mark id???")
                            return
                        end

                        keymap[3](thing, reddit_buf)
                    end, { buffer = buffer })
                end

                if state.mode == "post" then
                    vim.keymap.set("n", "j", function()
                        state.jump(buffer, -1)
                    end, { buffer = buffer })
                    vim.keymap.set("n", "k", function()
                        state.jump(buffer, 1)
                    end, { buffer = buffer })
                end
            end


            if endpoint.type == "listing" then
                ---@param dir "before"|"after"
                local function listing_nav(dir)
                    ---@type string|vim.NIL
                    local from = response.data.data[dir]
                    if from == vim.NIL then
                        print("There is nothing in this direction!")
                        return
                    end ---@cast from -vim.NIL

                    local url = path:gsub("%?.*$", "")

                    endpoint.params.before = nil
                    endpoint.params.after = nil
                    -- the type annotation for tonumber() is incorrect -- it can take any type
                    endpoint.params.count = tostring(
                        (tonumber(endpoint.params.count--[[@as string]], 10) or 0)
                        +
                        (dir == "after" and (tonumber(endpoint.params.limit--[[@as string]], 10) or 25) or 1)
                    )
                    endpoint.params[dir] = from
                    url = url .. "?"
                    for key, value in pairs(endpoint.params) do
                        url = url .. key .. "=" .. value .. "&"
                    end
                    url = url:sub(1, -2)
                    M.open(url)
                end
                vim.keymap.set("n", "gln", function()
                    listing_nav("after")
                end, { buffer = buffer })
                vim.keymap.set("n", "glp", function()
                    listing_nav("before")
                end, { buffer = buffer })
            end

            vim.keymap.set("n", "i", function()
                state.set_mode("post")
            end, { buffer = buffer })

            vim.keymap.set("n", "<Esc>", function()
                state.set_mode("normal")
            end, { buffer = buffer })


            vim.keymap.set("n", "K", function()
                local cursor = vim.api.nvim_win_get_cursor(0);
                local pos = { cursor[1] - 1, cursor[2] }
                local spoiler_marks = vim.api.nvim_buf_get_extmarks(buffer, sns, pos, pos, { details = true, overlap = true })

                local mark_count = #spoiler_marks
                if mark_count == 0 then
                    return
                elseif mark_count > 1 then
                    print("we found more than one spoiler under the cursor?")
                    return
                end

                local found_spoiler_mark = spoiler_marks[1][1]

                local spoiler_id
                for id, id_spoiler_marks in pairs(reddit_buf.spoiler_marks_map) do
                    for _, spoiler_mark in ipairs(id_spoiler_marks) do
                        if spoiler_mark == found_spoiler_mark then
                            spoiler_id = id
                            goto found
                        end
                    end
                end
                if not spoiler_id then
                    print("We couldn't find a spoiler_id that included our found mark!")
                    return
                end
                ::found::

                for _, spoiler_mark in ipairs(reddit_buf.spoiler_marks_map[spoiler_id]) do
                    vim.api.nvim_buf_del_extmark(buffer, sns, spoiler_mark)
                end
                reddit_buf.spoiler_marks_map[spoiler_id] = nil
            end, { buffer = buffer })

            --- FIXME: add "dev" config option or something
            vim.keymap.set("n", "gj", function()
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
            end, { buffer = buffer })
        end)
    end)()
end

---@param args vim.api.keyset.create_autocmd.callback_args
function M.cursor_moved(args)
    local reddit_buf = state.buffers[args.buf]
    local cursor = vim.api.nvim_win_get_cursor(0);
    local pos = { cursor[1] - 1, cursor[2] }
    local buf_marks = vim.api.nvim_buf_get_extmarks(reddit_buf.buffer, tns, pos, pos, { details = true, overlap = true })
    local mark_count = #buf_marks
    if mark_count ~= 1 then
        if mark_count > 1 then
            print("we found more than one mark for this thing???")
            for _, buf_mark in ipairs(buf_marks) do
                vim.print(buf_mark[1], reddit_buf.mark_thing_map[buf_mark[1]]);
            end
        end
        return
    end
    local id, row, col, details = unpack(buf_marks[1])
    -- these conditions have nothing to do with each other, fyi
    if id == reddit_buf.selected_mark_id or details.end_row == pos[1] then
        return
    end

    if reddit_buf.selected_mark_id ~= nil then
        local selectedmark = vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true })
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, tns, selectedmark[1], selectedmark[2], {
            id = reddit_buf.selected_mark_id,
            end_col = selectedmark[3].end_col,
            end_row = selectedmark[3].end_row
        })
    end

    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, tns, row, col, {
        id = id,
        hl_group = "RedditSelected",
        hl_eol = true,
        priority = 50,
        end_col = details.end_col,
        end_row = details.end_row
    })
    reddit_buf.selected_mark_id = id
end

return M
