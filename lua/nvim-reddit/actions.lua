local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local buffer = require("nvim-reddit.buffer")
local html = require("nvim-reddit.html")
local config = require("nvim-reddit.config")
local util = require("nvim-reddit.util")

local ns = state.ns
local tns = state.tns

local image_api = require("image")
vim.async = require("async")

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

    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.upvote(thing, reddit_buf)
    -- NvimReddit.Selectable and NvimReddit.Votable are the same right now, but they aren't always
    -- if thing.kind ~= "t1" and thing.kind ~= "t3" then
    --     return
    -- end ---@cast thing NvimReddit.Votable

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
    -- NvimReddit.Selectable and NvimReddit.Votable are the same right now, but they aren't always
    -- if thing.kind ~= "t1" and thing.kind ~= "t3" then
    --     return
    -- end ---@cast thing NvimReddit.Votable

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
    ---@type integer, _, vim.api.keyset.extmark_details
    local thing_mark_start, _, thing_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_mark_end = thing_mark_details.end_row
    ---@cast thing_mark_end -? -- we always set it with an end_row so

    if thing.kind == "t1" then
        if not thing.media then return end
        if not thing.open then
            vim.async.run(function()
                if reddit_buf.images[thing.data.id] == nil then
                    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                    ---@type Image|nil
                    ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                    local image = vim.async.await(3, image_api.from_url, thing.media.url, {
                        buffer = reddit_buf.buffer,
                        window = vim.api.nvim_get_current_win(),
                        with_virtual_padding = true,
                        height = 20,
                        render_offset_top = config.render_offset_top
                    })
                    if image == nil then
                        print("image was nil?!?!")
                        return
                    end

                    reddit_buf.images[thing.data.id] = image
                end

                reddit_buf.images[thing.data.id]:render({
                    y = thing_mark_start + thing.media.line,
                    x = thing.padding + 5
                })
                thing.open = true
            end):wait()
        else
            reddit_buf.images[thing.data.id]:clear()
            reddit_buf.images[thing.data.id] = nil
            thing.open = false
        end
        return
    end

    vim.async.run(function()
        local line_num = 0
        local hint = thing.data.post_hint
        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
        if not thing.open then
            local margin = config.spacing.score_margin + 1
            if hint then
                if hint == "image" then
                    if not reddit_buf.images[thing.data.id] then
                        -- disable while async
                        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                        ---@type Image|nil
                        ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                        local image = vim.async.await(3, image_api.from_url, thing.data.url_overridden_by_dest, {
                            buffer = reddit_buf.buffer,
                            window = vim.api.nvim_get_current_win(),
                            with_virtual_padding = true,
                            height = 20,
                            render_offset_top = config.render_offset_top,
                        })
                        if image == nil then
                            print("image was nil?!?!")
                            goto exit
                        end

                        reddit_buf.images[thing.data.id] = image
                        -- re-enable after async
                        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
                    end

                    reddit_buf.images[thing.data.id]:render({
                        y = thing_mark_end - 1,
                        x = margin
                    })
                    ::exit::
                elseif hint ~= "link" and hint ~= "self" then
                    vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {(" "):rep(margin) .. "<" .. hint .. ">"})
                    line_num = line_num + 1
                    if hint == "hosted:video" then
                        if thing.data.secure_media.reddit_video then
                            ---@type string[]
                            local player_args = {}
                            for i, arg in ipairs(config.player_options) do player_args[i] = arg end
                            table.insert(player_args, html.decode(thing.data.secure_media.reddit_video.dash_url))
                            thing.player_job = vim.system(player_args)
                        end
                    end
                end
            elseif thing.data.is_gallery then
                -- vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {(" "):rep(margin) .. "<gallery>"})
                -- line_num = line_num + 1
                if not thing.gallery_selected then
                    thing.gallery_selected = 1
                end
                local item = thing.data.gallery_data.items[thing.gallery_selected]
                if not reddit_buf.images[thing.data.id] then
                    local media = thing.data.media_metadata[item.media_id]
                    if not media then
                        print("Media was missing?")
                        return
                    end

                    -- disable while async
                    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                    ---@type Image|nil
                    ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                    local image = vim.async.await(3, image_api.from_url, html.decode(media.s.u), {
                        buffer = reddit_buf.buffer,
                        window = vim.api.nvim_get_current_win(),
                        with_virtual_padding = true,
                        height = 20,
                        render_offset_top = config.render_offset_top,
                    })
                    if image == nil then
                        print("image was nil?!?!")
                        goto exit
                    end

                    reddit_buf.images[thing.data.id] = image
                    -- re-enable after async
                    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
                end

                reddit_buf.images[thing.data.id]:render({
                    y = thing_mark_end - 1,
                    x = margin
                })
                ::exit::
            elseif thing.data.crosspost_parent then
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {(" "):rep(margin) .. "<crosspost>"})
                line_num = line_num + 1
            end

            local selftext_html = thing.data.selftext_html
            if selftext_html ~= vim.NIL then ---@cast selftext_html -vim.NIL -- why can't luals figure this out???
                if thing.parsed == nil then
                    local blocks = html.parse(html.decode(selftext_html))
                    thing.parsed = blocks
                end

                local width = util.get_window_text_width(0)

                local lines, marks = render.blocks(thing.parsed, math.min(width, config.spacing.max_line_length) - margin)
                for i, v in ipairs(lines) do
                    lines[i] = (" "):rep(margin) .. v
                end
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end+line_num, thing_mark_end+line_num, false, lines)
                for _, mark in ipairs(marks) do
                    mark.details.priority = mark.details.priority or 100
                    mark.details.end_row = thing_mark_end+line_num+mark.line
                    mark.details.end_col = mark.end_col+margin
                    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end+line_num+mark.line, mark.start_col+margin, mark.details)
                end
                line_num = line_num + #lines
            end

            thing.expando_mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end, 0, {
                id = thing.expando_mark,
                end_row = thing_mark_end+line_num,
            })

            thing.open = true
        else
            if thing.player_job then
                thing.player_job:kill("sigterm")
                thing.player_job = nil
            end
            if hint == "image" or thing.data.is_gallery then
                reddit_buf.images[thing.data.id]:clear()
                reddit_buf.images[thing.data.id] = nil
            end
            local row, _, expando_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))
            -- HACK: for some reason when an image is added (or maybe removed?) after
            -- the post is re-rendered due to voting, the end_row of the mark is set to 0
            if expando_details.end_row > row then
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, expando_details.end_row, false, {})
            end
            thing.open = false
        end
        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.permalink(thing)
    vim.ui.open(REDDIT_BASE .. thing.data.permalink)
end

---@param thing NvimReddit.Selectable
function M.open_subreddit(thing)
    vim.async.run(function()
        buffer.open(thing.data.subreddit_name_prefixed)
    end):wait()
end

---@param thing NvimReddit.Selectable
function M.open_user(thing)
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

    ---@type Image|nil
    ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
    local image = vim.async.await(3, image_api.from_url, html.decode(media.s.u), {
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

    reddit_buf.images[thing.data.id]:clear()
    reddit_buf.images[thing.data.id] = image
    reddit_buf.images[thing.data.id]:render({
        y = thing_mark_end - 1,
        x = margin
    })
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_next(thing, reddit_buf)
    vim.async.run(function ()
        gallery_nav(thing, reddit_buf, 1)
    end):wait()
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_prev(thing, reddit_buf)
    vim.async.run(function ()
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
    local register = vim.v.register
    local permalink = REDDIT_BASE .. thing.data.permalink
    vim.fn.setreg(register, permalink)
end

return M
