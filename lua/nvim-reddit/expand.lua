local config = require("nvim-reddit.config")
local state = require("nvim-reddit.state")
local util = require("nvim-reddit.util")
local html = require("nvim-reddit.html")
local render = require("nvim-reddit.render")

local ns = state.ns

local image_api = require("reddit-image")

local M = {}

---@param thing NvimReddit.Comment
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_start integer
function M.comment(thing, reddit_buf, thing_mark_start)
    if not thing.media then return end
    if not thing.open then
        vim.async.run(function()
            if not reddit_buf.images[thing.data.id] then
                local media = thing.media.media
                local url = M.get_best_image_resolution_url(media)

                if media.e == "AnimatedImage" and config.use_gif_player then
                    ---@type string[]
                    local player_args = {}
                    for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
                    table.insert(player_args, media.s.mp4)
                    thing.player_job = vim.system(player_args, nil, config.player_onexit)
                end

                vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                ---@type Image|nil
                ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                local image = vim.async.await(3, image_api.from_url, url, {
                    buffer = reddit_buf.buffer,
                    window = vim.api.nvim_get_current_win(),
                    with_virtual_padding = true
                })
                if image == nil then
                    print("image was nil?!?!")
                    return
                end

                reddit_buf.images[thing.data.id] = image
            end

            if config.set_topline_on_expand then
                vim.fn.winrestview({ topline = thing_mark_start + 1 })
            end
            local image = reddit_buf.images[thing.data.id]
            image:render({
                y = thing_mark_start + thing.media.line,
                x = thing.padding + 2
            })

            thing.open = true
        end):raise_on_error()
    else
        if thing.player_job then
            thing.player_job:kill("sigterm")
            thing.player_job = nil
        end
        reddit_buf.images[thing.data.id]:clear()
        reddit_buf.images[thing.data.id] = nil
        thing.open = false
    end
end

---@param thing NvimReddit.Link
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_start integer
---@param thing_mark_end integer
function M.link(thing, reddit_buf, thing_mark_start, thing_mark_end)
    if not thing.open then
        vim.async.run(function()
            ---@type string[]
            local lines = {}
            ---@type NvimReddit.Mark[]
            local marks = {}
            ---@type NvimReddit.Spoiler[]
            local spoilers = {}
            local line = 0
            local hint = thing.data.post_hint

            local margin = config.spacing.score_margin + 1

            if hint then
                if hint == "image" then
                    if not reddit_buf.images[thing.data.id] then
                        local url
                        if thing.data.preview then
                            if #thing.data.preview.images ~= 1 then
                                print("More than one preview.images?", #thing.data.preview.images)
                            end
                            local preview = thing.data.preview.images[1]
                            url = M.get_best_image_resolution_url(preview)

                            if config.use_gif_player then
                                local player_url
                                if preview.variants.mp4 then
                                    player_url = preview.variants.mp4.source.url
                                elseif preview.variants.gif then
                                    player_url = preview.variants.gif.source.url
                                end
                                if player_url then
                                    ---@type string[]
                                    local player_args = {}
                                    for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
                                    table.insert(player_args, player_url)
                                    thing.player_job = vim.system(player_args, nil, config.player_onexit)
                                end
                            end
                        end
                        if not url then
                            url = thing.data.url_overridden_by_dest or thing.data.url
                        end

                        ---@type Image|nil
                        ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                        local image = vim.async.await(3, image_api.from_url, url, {
                            buffer = reddit_buf.buffer,
                            window = vim.api.nvim_get_current_win(),
                            with_virtual_padding = true,
                            y = thing_mark_end - 1,
                            x = margin,
                        })
                        if image == nil then
                            print("image was nil?!?!")
                            goto exit
                        end
                        M.watch_image_extmark(image)
                        -- image.ignore_global_max_size = true

                        reddit_buf.images[thing.data.id] = image
                    end

                    ::exit::
                elseif hint ~= "self" then
                    table.insert(lines, (" "):rep(margin) .. "<" .. hint .. ">")
                    line = line + 1
                    if hint == "hosted:video" then
                        ---@type string[]
                        local player_args = {}
                        for i, arg in ipairs(config.player_options) do player_args[i] = arg end
                        table.insert(player_args, thing.data.secure_media.reddit_video.dash_url)
                        thing.player_job = vim.system(player_args, nil, config.player_onexit)
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

                    local url = M.get_best_image_resolution_url(media)

                    if media.e == "AnimatedImage" and config.use_gif_player then
                        ---@type string[]
                        local player_args = {}
                        for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
                        table.insert(player_args, media.s.mp4)
                        thing.player_job = vim.system(player_args, nil, config.player_onexit)
                    end

                    ---@type Image|nil
                    ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                    local image = vim.async.await(3, image_api.from_url, url, {
                        buffer = reddit_buf.buffer,
                        window = vim.api.nvim_get_current_win(),
                        with_virtual_padding = true,
                        y = thing_mark_end,
                        x = margin,
                    })
                    if image == nil then
                        print("image was nil?!?!")
                        goto exit
                    end
                    M.watch_image_extmark(image)
                    -- image.ignore_global_max_size = true

                    reddit_buf.images[thing.data.id] = image
                end

                table.insert(lines, (" "):rep(margin) .. thing.gallery_selected .. " of " .. #thing.data.gallery_data.items)
                line = line + 1

                ::exit::
            elseif thing.data.secure_media ~= vim.NIL then
                if thing.data.secure_media.reddit_video then
                    table.insert(lines, (" "):rep(margin) .. "<hosted:video>")
                    line = line + 1
                    ---@type string[]
                    local player_args = {}
                    for i, arg in ipairs(config.player_options) do player_args[i] = arg end
                    table.insert(player_args, thing.data.secure_media.reddit_video.dash_url)
                    thing.player_job = vim.system(player_args, nil, config.player_onexit)
                end
            elseif thing.data.crosspost_parent then
                table.insert(lines, (" "):rep(margin) .. "<crosspost>")
                line = line + 1
            end

            local selftext_html = thing.data.selftext_html
            if selftext_html ~= vim.NIL then ---@cast selftext_html -vim.NIL -- why can't luals figure this out???
                if thing.parsed == nil then
                    local blocks = html.parse_md(selftext_html)
                    thing.parsed = blocks
                end

                local width = util.get_window_text_width(0)

                local expando_lines, expando_marks, expando_spoilers = render.blocks(thing.parsed, math.min(width, config.spacing.max_line_length) - margin)
                for _, expando_line in ipairs(expando_lines) do
                    if expando_line == "" then
                        table.insert(lines, "")
                    else
                        table.insert(lines, (" "):rep(margin) .. expando_line)
                    end
                end

                for _, mark in ipairs(expando_marks) do
                    if mark.details.virt_text_win_col then
                        mark.details.virt_text_win_col = mark.details.virt_text_win_col + margin
                        if mark.start_col == mark.end_col then
                            goto add
                        end
                    end
                    mark.line = mark.line + line
                    mark.start_col = mark.start_col + margin
                    mark.end_col = mark.end_col + margin
                    ::add::
                    table.insert(marks, mark)
                end
                for _, spoiler in ipairs(expando_spoilers) do
                    spoiler.line = spoiler.line + line
                    spoiler.start_col = spoiler.start_col + margin
                    spoiler.end_col = spoiler.end_col + margin
                    table.insert(spoilers, spoiler)
                end
                line = line + #expando_lines
            end

            ---@type integer[]
            local foldlevels = {}
            for i = 1, #lines do
                foldlevels[i] = 0
            end

            vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })

            util.draw(reddit_buf, lines, marks, spoilers, {}, foldlevels, thing_mark_end, thing_mark_end)

            local image = reddit_buf.images[thing.data.id]
            if image then
                image:render()
            end

            vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

            thing.expando_mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end, 0, {
                id = thing.expando_mark,
                end_row = thing_mark_end + line,
                hl_group = "RedditExpanded",
                hl_eol = true,
                priority = 50,
            })

            if config.set_topline_on_expand then
                vim.fn.winrestview({ topline = thing_mark_start + 1 })
            end

            thing.open = true
        end):raise_on_error()
    else -- closing
        if thing.player_job then
            thing.player_job:kill("sigterm")
            thing.player_job = nil
        end

        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })

        local image = reddit_buf.images[thing.data.id]
        if image then
            image:clear()
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

        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

        thing.open = false
    end
end

local image_utils = require("reddit-image.utils")

--TODO: Make this generic (almost added to luals :D)
---@param preview NvimReddit.PreviewImage|NvimReddit.Media
---@return string
function M.get_best_image_resolution_url(preview)
    local term_size = image_utils.term.get_size()
    local window = image_utils.window.get_window(vim.api.nvim_get_current_win()) or { height = term_size.screen_rows }

    local max_rows = math.floor(window.height * (config.max_image_height_window_percentage / 100))
    local max_height = term_size.cell_height * max_rows

    local source_key, resolutions_key, height_key, url_key
    if preview.e then
        source_key = "s"
        resolutions_key = "p"
        height_key = "y"
        url_key = "u"
    else
        source_key = "source"
        resolutions_key = "resolutions"
        height_key = "height"
        url_key = "url"
    end

    local best = preview[source_key]
    local best_dist = math.abs(preview[source_key][height_key] - max_height)
    for _, res in ipairs(preview[resolutions_key]) do
        local dist = math.abs(max_height - res[height_key])
        if dist < best_dist then
            best = res
            best_dist = dist
        end
    end
    -- print("window.height", window.height, "percentage", (config.max_image_height_window_percentage / 100), "max rows:", max_rows, "max height:", max_height, "best height:", best[height_key])

    -- HACK: gifs don't have a url field in their source (only "gif" and "mp4"),
    -- but that seems to always mean they have one preview with a thumbnail url
    return best[url_key] or preview[resolutions_key][1][url_key]
end

---@param image Image
function M.watch_image_extmark(image)
    local old_mt = getmetatable(image) or {}
    local old_index = old_mt.__index

    local extmark
    setmetatable(image, {
        __index = function(t, key)
            if key == "extmark" then
                return extmark
            end
            if type(old_index) == "function" then
                return old_index(t, key)
            elseif type(old_index) == "table" then
                return old_index[key]
            else
                return rawget(t, key)
            end
        end,
        __newindex = function(t, key, value)
            if key == "extmark" then
                extmark = value

                local image_ns = t.global_state.extmarks_namespace

                local row, col, details = unpack(vim.api.nvim_buf_get_extmark_by_id(t.buffer, image_ns, value.id, { details = true }))
                details.ns_id = nil
                details.id = value.id
                for _, virt_line in ipairs(details.virt_lines) do
                    virt_line[1][1] = (" "):rep(vim.api.nvim_win_get_width(0))
                    virt_line[1][2] = "RedditExpanded"
                end

                vim.api.nvim_buf_set_extmark(t.buffer, image_ns, row, col, details)
                return
            end
            rawset(t, key, value)
        end
    })
end

return M
