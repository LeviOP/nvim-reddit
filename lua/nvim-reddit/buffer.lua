local util = require("nvim-reddit.util")
local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local config = require("nvim-reddit.config")

local tns = state.tns

---@module "reddit-image"

local M = {}

---@class (exact) NvimReddit.Buffer
---@field buffer integer
---@field mark_thing_map table<integer, NvimReddit.Selectable>
---@field selected_mark_id integer|nil
---@field images table<string, Image>
--- 1-indexed
---@field foldlevels NvimReddit.FoldLevels

---@param path string
function M.open(path)
    local buffer = vim.api.nvim_get_current_buf()
    if vim.bo[buffer].modified or vim.api.nvim_buf_get_name(buffer) ~= "" then
        buffer = vim.api.nvim_create_buf(true, true)
    end
    vim.api.nvim_set_option_value("filetype", "reddit", { buf = buffer })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buffer })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buffer })
    vim.api.nvim_buf_set_name(buffer, "reddit://" .. path)

    -- FIXME: window stuff should maybe be separate in the future (sidebar)
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
    vim.api.nvim_set_option_value("foldexpr", "v:lua.require'nvim-reddit.fold'.expr()", { win = 0 })
    vim.api.nvim_set_option_value("foldtext", "v:lua.require'nvim-reddit.fold'.text()", { win = 0 })

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
        foldlevels = {},
    }

    state.buffers[buffer] = reddit_buf

    vim.api.nvim_create_autocmd({"BufDelete"}, {
        buffer = buffer,
        callback = function()
            state.buffers[buffer] = nil
        end,
    })

    if state.reddit == nil then
        local reddit_api_path = vim.fs.joinpath(config.data_dir, "api.json")
        local reddit, err = config.setup_reddit(reddit_api_path, config.platform_resolver())
        if err ~= nil then
            print("Error loading Reddit API config:", err)
            return
        end ---@cast reddit -?
        state.reddit = reddit
    end

    if state.reddit.token == nil then
        ---@diagnostic disable-next-line: param-type-mismatch -- luals is not very smart
        vim.async.await(2, state.reddit.get_access_token, state.reddit)
    end

    -- HACK: do actual query params parsing...
    if path:find("?") then
        path = path .. "&raw_json=1"
    else
        path = path .. "?raw_json=1"
    end

    -- if I try to do this with disable-next-line, the type assertion just.. doesn't work. luals is really really really stupid
    ---@type NvimReddit.FetchResponse, NvimReddit.RedditError|nil
    local response, err = vim.async.await(3, state.reddit.fetch, state.reddit, path) ---@diagnostic disable-line: param-type-mismatch, assign-type-mismatch
    if err then
        vim.print(err)
        return
    end

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
    -- it's nicer if we don't let the user (or code) know about this
    endpoint.params["raw_json"] = nil

    vim.schedule(function()
        vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
        if endpoint.type == "listing" then
            ---@type NvimReddit.Listing
            local listing = response.data
            local lines, marks, things, foldlevels = render.listing(listing, endpoint)
            util.draw(reddit_buf, lines, marks, things, foldlevels, 0)
        elseif endpoint.type == "article" then
            ---@type NvimReddit.Link
            local link = response.data[1].data.children[1]
            ---@type NvimReddit.Listing
            local comments = response.data[2]

            -- HACK: this is stuff that we usually set up in in render.listing.
            -- we might want to move this to a standard place instead of at
            -- every call site
            ---@type string
            local url_domain = link.data.url:match("^%w+://([^/:?#]+)")
            if url_domain ~= link.data.domain then
                -- this might not be a good assumption to make, but we'll see i guess
                link.domain_url = link.data.subreddit_name_prefixed
            else
                link.domain_url = "domain/" .. link.data.domain
            end
            link.show_subreddit = endpoint.subreddit ~= link.data.subreddit:lower()

            local lines, marks, things, foldlevels = render.link(link)
            table.insert(lines, "")
            table.insert(foldlevels, 0)
            util.draw(reddit_buf, lines, marks, things, foldlevels, 0)
            local c_lines, c_marks, c_things, c_foldlevels = render.listing(comments, endpoint)
            util.draw(reddit_buf, c_lines, c_marks, c_things, c_foldlevels, #lines)
        elseif endpoint.type == "about" then
            if endpoint.user then
                --- TODO: user endpoints (not user subreddit, maybe should be normalized)
                vim.print("user info not supported")
            else
                ---@type NvimReddit.Subreddit
                local subreddit = response.data
                local lines, marks = render.sidebar(subreddit)
                util.draw(reddit_buf, lines, marks, {}, {}, 0)
            end
        end

        vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
        vim.api.nvim_win_set_cursor(0, {1, 0})

        vim.api.nvim_create_autocmd({"CursorMoved"}, {
            buffer = buffer,
            callback = util.closure(M.cursor_moved, reddit_buf),
        })

        vim.api.nvim_create_autocmd({"BufWinEnter"}, {
            buffer = buffer,
            callback = function()
                vim.schedule(function()
                    for _, image in pairs(reddit_buf.images) do
                        image:render()
                    end
                end)
            end,
        })

        for _, keymap in ipairs(config.keymaps) do
            vim.keymap.set(keymap[1], keymap[2], function ()
                if reddit_buf.selected_mark_id == nil then
                    return
                end

                local thing = reddit_buf.mark_thing_map[reddit_buf.selected_mark_id]
                if thing == nil then
                    print("dind't find thing from selected mark id???")
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


        if endpoint.type == "listing" then
            ---@param dir "before"|"after"
            local function listing_nav(dir)
                ---@type string|vim.NIL
                local from = response.data.data[dir]
                if from == vim.NIL then
                    print("There is nothing in this direction!")
                    return
                end ---@cast from -vim.NIL
                vim.async.run(function()
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
                end)
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
end

---@param reddit_buf NvimReddit.Buffer
function M.cursor_moved(reddit_buf)
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
