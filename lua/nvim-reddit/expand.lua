local config = require("nvim-reddit.config")
local state = require("nvim-reddit.state")
local util = require("nvim-reddit.util")
local html = require("nvim-reddit.html")
local render = require("nvim-reddit.render")

local ns = state.ns

local image_api = require("image")

local M = {}

---@param thing NvimReddit.Comment
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_start integer
function M.comment(thing, reddit_buf, thing_mark_start)
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
end

---@param thing NvimReddit.Link
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_end integer
function M.link(thing, reddit_buf, thing_mark_end)
    local line_num = 0
    local hint = thing.data.post_hint
    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
    if not thing.open then
        vim.async.run(function()
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
                            thing.player_job = vim.system(player_args, nil, config.player_onexit)
                        end
                    end
                end
            elseif thing.data.is_gallery then
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
                        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
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

                local rendered_line_count = #lines

                -- FIXME: repeated table.insert is needlessly slow (and in other places)
                local buffer_foldlevels = reddit_buf.foldlevels
                for _ = thing_mark_end, thing_mark_end + line_num + rendered_line_count - 1 do
                    table.insert(buffer_foldlevels, thing_mark_end + 1, 0)
                end

                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end + line_num, thing_mark_end + line_num, false, lines)
                for _, mark in ipairs(marks) do
                    mark.details.priority = mark.details.priority or 100
                    mark.details.end_row = thing_mark_end + line_num + mark.line
                    mark.details.end_col = mark.end_col + margin
                    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end + line_num + mark.line, mark.start_col + margin, mark.details)
                end
                line_num = line_num + rendered_line_count
            end

            thing.expando_mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end, 0, {
                id = thing.expando_mark,
                end_row = thing_mark_end + line_num,
                hl_group = "RedditExpanded",
                hl_eol = true,
                priority = 50,
            })

            thing.open = true
        end):wait()
    else -- closing
        if thing.player_job then
            thing.player_job:kill("sigterm")
            thing.player_job = nil
        end
        if hint == "image" or thing.data.is_gallery then
            reddit_buf.images[thing.data.id]:clear()
            reddit_buf.images[thing.data.id] = nil
        end

        local row, _, expando_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))

        util.array_remove_range(reddit_buf.foldlevels, row + 1, expando_details.end_row)

        -- HACK: for some reason when an image is added (or maybe removed?) after
        -- the post is re-rendered due to voting, the end_row of the mark is set to 0
        if expando_details.end_row > row then
            local cursor = vim.api.nvim_win_get_cursor(0);
            vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, expando_details.end_row, false, {})
            if expando_details.end_row >= cursor[1] and cursor[1] > row then
                vim.api.nvim_win_set_cursor(0, { row, cursor[2] })
            end
        end
        thing.open = false
    end
    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
end

return M
