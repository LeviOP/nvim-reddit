local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local buffer = require("nvim-reddit.buffer")
local config = require("nvim-reddit.config")
local util = require("nvim-reddit.util")
local expand = require("nvim-reddit.expand")

local ns = state.ns
local tns = state.tns

local image_api = require("image")

-- This is different than other files! includes a trailing slash. unify at some point
local REDDIT_BASE = "https://www.reddit.com"

local M = {}

---@param thing NvimReddit.Votable
---@param reddit_buf NvimReddit.Buffer
---@param dir 1|0|-1
local function vote(thing, reddit_buf, dir)
    state.reddit:vote(thing.data.name, dir, function(err)
        if err then
            print("Error voting: " .. err)
        end
    end)

    local row, _, details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_lines, thing_style_marks, thing_marks
    if thing.kind == "t1" then
        thing_lines, thing_style_marks, thing_marks = render.comment(thing, false)
    elseif thing.kind == "t3" then
        thing_lines, thing_style_marks, thing_marks = render.link(thing)
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
    vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, details.end_row, false, thing_lines)
    for _, style_mark in ipairs(thing_style_marks) do
        style_mark.details.end_row = style_mark.line + row
        style_mark.details.end_col = style_mark.end_col
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, style_mark.line + row, style_mark.start_col, style_mark.details)
    end
    local thing_mark = thing_marks[1] -- there should only be one... hopefully...
    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, tns, thing_mark.start_line + row, 0, {
        id = reddit_buf.selected_mark_id,
        hl_group = "RedditSelected",
        hl_eol = true,
        priority = 50,
        end_row = thing_mark.start_line + thing_mark.lines + row,
        end_col = 0
    })

    local image = reddit_buf.images[thing.data.id]
    if image then
        -- we have to wait until the text above is rendered so that the marks are "settled"
        vim.schedule(function()
            image:render({
                y = details.end_row - 1,
                x = config.spacing.score_margin + 1
            })
        end)
    end

    -- HACK: writing over existing text causes the folds after the current line to break for...
    -- no reason? if we run zx that will fix it (which makes no sense) but it will open all folds.
    -- setting the foldmethod again will fix it without opening folds
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.upvote(thing, reddit_buf)
    if thing.kind ~= "t1" and thing.kind ~= "t3" then
        return
    end ---@cast thing NvimReddit.Votable

    local dir
    if thing.data.likes == true then
        dir = 0
        thing.data.likes = vim.NIL
        thing.data.score = thing.data.score - 1
    else
        dir = 1
        thing.data.likes = true
        thing.data.score = thing.data.score + 1
    end

    vote(thing, reddit_buf, dir)
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.downvote(thing, reddit_buf)
    if thing.kind ~= "t1" and thing.kind ~= "t3" then
        return
    end ---@cast thing NvimReddit.Votable

    local dir
    if thing.data.likes == false then
        dir = 0
        thing.data.likes = vim.NIL
        thing.data.score = thing.data.score + 1
    else
        dir = -1
        thing.data.likes = false
        thing.data.score = thing.data.score - 1
    end

    vote(thing, reddit_buf, dir)
end

---@param thing NvimReddit.Selectable
function M.open_comments(thing)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.permalink:sub(2))
    end):wait()
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.expand(thing, reddit_buf)
    if thing.kind == "t1" then
        local thing_mark_start = vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, {})[1]
        expand.comment(thing, reddit_buf, thing_mark_start)
    elseif thing.kind == "t3" then
        local thing_mark_start, _, thing_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
        expand.link(thing, reddit_buf, thing_mark_start, thing_details.end_row)
    else
        print("You cannot expand this thing")
    end
end

---@param thing NvimReddit.Selectable
function M.permalink(thing)
    if thing.kind == "more" then
        return
    end
    vim.ui.open(REDDIT_BASE .. thing.data.permalink)
end

---@param thing NvimReddit.Selectable
function M.open_subreddit(thing)
    if thing.kind == "more" then
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.subreddit_name_prefixed)
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.open_user(thing)
    if thing.kind == "more" then
        return
    end
    if thing.data.author == "[deleted]" then
        print("Cannot go to deleted user's profile")
        return
    end
    vim.async.run(function()
        buffer.open("user/" .. thing.data.author)
    end):wait()
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
---@param dir -1|1
local function gallery_nav(thing, reddit_buf, dir)
    if thing.kind ~= "t3" or not thing.data.is_gallery or not thing.open then
        print("This is not an open gallery")
        return
    end

    ---@type integer, _, vim.api.keyset.extmark_details
    local _, _, thing_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_mark_end = thing_mark_details.end_row
    ---@cast thing_mark_end -? -- we always set it with an end_row so

    local last = #thing.data.gallery_data.items
    thing.gallery_selected = thing.gallery_selected + dir
    if thing.gallery_selected == 0 then
        thing.gallery_selected = last
    elseif thing.gallery_selected > last then
        thing.gallery_selected = 1
    end

    local item = thing.data.gallery_data.items[thing.gallery_selected]
    local media = thing.data.media_metadata[item.media_id]
    if not media then
        print("Media was missing?")
        return
    end

    local url
    ---@type NvimReddit.MediaPreview
    local best = { u = "", x = 0, y = 0 }
    for _, res in ipairs(media.p) do
        if res.y > best.y and (best.y == 0 or res.y <= 480) then
            best = res
        end
    end
    if best.y >= 400 then
        url = best.u
    else
        if media.e == "Image" then
            url = media.s.u
        elseif media.e == "AnimatedImage" then
            url = media.s.gif
        else
            print("Unhandled gallery type:", media.e)
            return
        end
    end

    ---@type Image|nil
    ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
    local image = vim.async.await(3, image_api.from_url, url, {
        buffer = reddit_buf.buffer,
        window = vim.api.nvim_get_current_win(),
        with_virtual_padding = true,
        height = 20,
        render_offset_top = config.render_offset_top,
    })
    if image == nil then
        print("image was nil?!?!")
        return
    end

    local margin = config.spacing.score_margin + 1

    if thing.player_job then
        thing.player_job:kill("sigterm")
        thing.player_job = nil
    end

    reddit_buf.images[thing.data.id]:clear()
    reddit_buf.images[thing.data.id] = image
    reddit_buf.images[thing.data.id]:render({
        y = thing_mark_end - 1,
        x = margin
    })

    if media.e == "AnimatedImage" and config.use_gif_player then
        ---@type string[]
        local player_args = {}
        for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
        table.insert(player_args, media.s.mp4)
        thing.player_job = vim.system(player_args, nil, config.player_onexit)
    end
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_next(thing, reddit_buf)
    vim.async.run(function()
        gallery_nav(thing, reddit_buf, 1)
    end):wait()
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_prev(thing, reddit_buf)
    vim.async.run(function()
        gallery_nav(thing, reddit_buf, -1)
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.open_domain(thing)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end
    vim.async.run(function()
        buffer.open(thing.domain_url)
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.yank_permalink(thing)
    if thing.kind == "more" then
        return
    end
    local register = vim.v.register
    local permalink = REDDIT_BASE .. thing.data.permalink
    vim.fn.setreg(register, permalink)
end

---@param thing NvimReddit.Selectable
function M.open_context(thing)
    if thing.kind ~= "t1" then
        print("not a comment")
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.permalink:sub(2) .. "?context=3")
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.open_full_context(thing)
    if thing.kind ~= "t1" then
        print("not a comment")
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.permalink:sub(2) .. "?context=10000")
    end):wait()
end

---@param more NvimReddit.More
---@param reddit_buf NvimReddit.Buffer
local function load_more(more, reddit_buf)
    vim.async.run(function()
        ---@type NvimReddit.FetchResponse, NvimReddit.RedditError|nil
        local response, err = vim.async.await(
            3,
            state.reddit.fetch,
            state.reddit,
            "api/morechildren?api_type=json&children=" .. table.concat(more.data.children, ",") .. "&link_id=" .. more.link_id .. "&raw_json=1"
        ) ---@diagnostic disable-line: param-type-mismatch, assign-type-mismatch
        if err then
            vim.print(err)
            return
        end
        ---@type table<string, NvimReddit.Comment|NvimReddit.Listing>
        local id_cache = {}
        if more.parent.kind == "t1" then
            id_cache["t1_" .. more.parent.data.id] = more.parent
        else
            id_cache[more.link_id] = more.parent
        end

        vim.schedule(function()
            if more.parent.kind == "t1" then
                table.remove(more.parent.data.replies.data.children, more.self_index)
            else
                table.remove(more.parent.data.children, more.self_index)
            end

            ---@type (NvimReddit.Comment|NvimReddit.More)[]
            local base_things = {}

            for _, thing in ipairs(response.data.json.data.things --[[@as (NvimReddit.Comment|NvimReddit.More)[] ]]) do
                local parent = id_cache[thing.data.parent_id]
                if parent == nil then
                    print("couldn't find parent?????")
                    goto continue
                end
                if parent.kind == "t1" then
                    if parent.data.replies == "" then
                        parent.data.replies = {
                            kind = "Listing",
                            data = {
                                children = {},
                                after = vim.NIL,
                                before = vim.NIL,
                                dist = vim.NIL,
                            }
                        }
                    end
                    table.insert(parent.data.replies.data.children, thing)
                    if parent == more.parent then
                        thing.padding = parent.padding + 2
                        table.insert(base_things, thing)
                    end
                else
                    thing.padding = 0
                    table.insert(parent.data.children, thing)
                    table.insert(base_things, thing)
                    if thing.kind == "more" then
                        thing.link_id = thing.data.parent_id
                        -- this should always be at the end of the array but why not calculate things to be sure? :-)
                        thing.self_index = #parent.data.children
                        thing.parent = parent
                    end
                end
                -- we don't need to cache mores because they can't have children
                if thing.kind == "t1" then
                    id_cache["t1_" .. thing.data.id] = thing
                end
                ::continue::
            end

            -- base fold level (indent) for newly rendered things
            local foldlevel = more.padding / 2

            ---@type string[]
            local lines = {}
            ---@type NvimReddit.Mark[]
            local marks = {}
            ---@type NvimReddit.ThingMark[]
            local things = {}
            ---@type NvimReddit.FoldLevels
            local foldlevels = {}
            local line = 0
            for _, thing in ipairs(base_things) do
                local thing_lines, thing_style_marks, thing_marks, thing_foldlevels
                if thing.kind == "t1" then
                    thing_lines, thing_style_marks, thing_marks, thing_foldlevels = render.comment(thing, true)
                else
                    thing_lines, thing_style_marks, thing_marks, thing_foldlevels = render.more(thing)
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
                for _, thing_foldlevel in ipairs(thing_foldlevels) do
                    table.insert(foldlevels, thing_foldlevel)
                end
                line = line + #thing_lines
                table.insert(lines, "")
                table.insert(foldlevels, foldlevel)
                line = line + 1
            end

            -- remove trailing empty line. maybe this should be done some other way but.....
            lines[#lines] = nil
            foldlevels[#foldlevels] = nil

            local start_line = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, {}))
            local end_line = start_line + 1

            -- remove more thing mark
            vim.api.nvim_buf_del_extmark(reddit_buf.buffer, tns, reddit_buf.selected_mark_id)
            reddit_buf.mark_thing_map[reddit_buf.selected_mark_id] = nil
            reddit_buf.selected_mark_id = nil

            vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
            util.draw(reddit_buf, lines, marks, things, foldlevels, start_line, end_line)
            vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
        end)
    end):wait()
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.enter(thing, reddit_buf)
    if thing.kind == "more" then
        if thing.data.count == 0 then
            vim.async.run(function()
                buffer.open(thing.parent.data.permalink:sub(2))
            end):wait()
        else
            load_more(thing, reddit_buf)
        end
    elseif thing.kind == "t3" then
        vim.ui.open(thing.data.url)
    else
        print("no enter action on this thing")
    end
end

return M
