local util = require("nvim-reddit.util")
local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local config = require("nvim-reddit.config")

local ns = state.ns
local tns = state.tns

vim.async = require("async")

local M = {}

---@class (exact) NvimReddit.Buffer
---@field buffer integer
---@field mark_thing_map table<integer, NvimReddit.Thing>
---@field selected_mark_id integer|nil
---@field images table<string, Image>

local function cursor_moved(reddit_buf)
    local cursor = vim.api.nvim_win_get_cursor(0);
    local pos = { cursor[1] - 1, cursor[2] }
    local buf_marks = vim.api.nvim_buf_get_extmarks(reddit_buf.buffer, tns, pos, pos, { details = true, overlap = true })
    local mark_count = #buf_marks
    if mark_count ~= 1 then
        if mark_count > 1 then print("we found more than one mark for this thing???") end
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

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
        "Loading..."
    })

    vim.api.nvim_set_current_buf(buffer)

    ---@type NvimReddit.Buffer
    local reddit_buf = {
        buffer = buffer,
        mark_thing_map = {},
        selected_mark_id = nil,
        images = {}
    }

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

    -- if I try to do this with disable-next-line, the type assertion just.. doesn't work. luals is really really really stupid
    ---@type NvimReddit.FetchResponse, NvimReddit.RedditError|nil
    local response, err = vim.async.await(3, state.reddit.fetch, state.reddit, path) ---@diagnostic disable-line: param-type-mismatch, assign-type-mismatch
    if err then
        vim.print(err)
        return
    end

    -- HACK: dev
    local json = response.json
    response.json = nil

    ---@type (NvimReddit.Thing)|((NvimReddit.Thing)[])
    local result = response.data
    -- normalize reddit response type to be an array of listings
    if result.kind ~= nil then
        result = { result }
    end
    -- I'm not sure if this is always the case
    ---@cast result NvimReddit.Thing[]

    vim.schedule(function()
        ---@type string|nil
        local newpath = response.location:match("^https://oauth%.reddit%.com/(.*)$")
        if not newpath then
            print("Couldn't get path from response location???", response.location)
        else
            vim.api.nvim_buf_set_name(buffer, "reddit://" .. newpath)
        end

        ---@type string[]
        local lines = {}
        ---@type NvimReddit.Mark[]
        local marks = {}
        ---@type NvimReddit.ThingMark[]
        local things = {}
        local line = 0
        for _, listing in ipairs(result) do
            if listing.kind ~= "Listing" then
                print("top level was not a listing?")
                return
            end
            for _, thing in ipairs(listing.data.children) do
                local thing_lines, thing_style_marks, thing_marks
                if thing.kind == "t1" then
                    thing_lines, thing_style_marks, thing_marks = render.comment(thing, 0, true)
                elseif thing.kind == "t3" then
                    thing_lines, thing_style_marks, thing_marks = render.link(thing)
                else
                    print("unhandled thing kind!:", thing.kind)
                    goto continue
                end
                for _, thing_line in ipairs(thing_lines) do
                    table.insert(lines, thing_line)
                end
                for _, style_mark in ipairs(thing_style_marks) do
                    style_mark.line = style_mark.line + line
                    table.insert(marks, style_mark)
                end
                for _, thing_mark in ipairs(thing_marks) do
                    thing_mark.start_line = thing_mark.start_line + line
                    table.insert(things, thing_mark)
                end
                line = line + #thing_lines
                table.insert(lines, "")
                line = line + 1
                ::continue::
            end
        end

        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
        for _, mark in ipairs(marks) do
            mark.details.end_row = mark.line
            mark.details.end_col = mark.end_col
            vim.api.nvim_buf_set_extmark(buffer, ns, mark.line, mark.start_col, mark.details)
        end
        for _, thing in ipairs(things) do
            local mark = vim.api.nvim_buf_set_extmark(buffer, tns, thing.start_line, 0, {
                end_row = thing.start_line + thing.lines,
                end_col = 0,
                strict = false
            })
            reddit_buf.mark_thing_map[mark] = thing.thing
        end


        vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
        vim.api.nvim_win_set_cursor(0, {1, 0})

        vim.api.nvim_create_autocmd({"CursorMoved"}, {
            buffer = buffer,
            callback = util.closure(cursor_moved, reddit_buf),
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

        -- HACK: dev
        vim.keymap.set("n", "gj", function()
            -- Format JSON with jq
            local formatted = vim.fn.systemlist("jq .", json)
            if vim.v.shell_error ~= 0 then
                vim.notify("Failed to format JSON with jq", vim.log.levels.ERROR)
                return
            end

            -- Create a new normal buffer
            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_set_option_value("filetype", "json", { buf = buf })
            vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
            vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
            -- vim.api.nvim_buf_set_name(buf, "Reddit response JSON")

            -- Set the formatted JSON lines
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted)

            -- Switch the current window to the new buffer
            vim.api.nvim_set_current_buf(buf)
        end, { buffer = buffer })

    end)
end

return M
