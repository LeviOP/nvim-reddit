local config = require("nvim-reddit.config")
local state = require("nvim-reddit.state")
local util = require("nvim-reddit.util")
local html = require("nvim-reddit.html")
local render = require("nvim-reddit.render")
local richtext = require("nvim-reddit.richtext")

local ns = state.ns

local image_api = require("reddit-image")

local M = {}

---@param thing NvimReddit.Comment
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_start integer
function M.comment(thing, reddit_buf, thing_mark_start)
    if not thing.media then return end
    if not thing.open then
        local media = thing.media.media
        local url = M.get_best_image_resolution_url(media)

        if media.e == "AnimatedImage" and config.use_gif_player then
            ---@type string[]
            local player_args = {}
            for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
            table.insert(player_args, media.s.mp4)
            thing.player_job = vim.system(player_args, nil, config.player_onexit)
        end

        if config.set_topline_on_expand then
            vim.fn.winrestview({ topline = thing_mark_start + 1 })
        end

        thing.open = true

        image_api.from_url(
            url,
            {
                buffer = reddit_buf.buffer,
                window = vim.api.nvim_get_current_win(),
                with_virtual_padding = true,
                x = thing.padding + 2,
                y = thing_mark_start + thing.media.line,
            },
            function(image)
                if not image then
                    print("Failed to load image")
                    return
                end
                vim.schedule(function()
                    if thing.open then
                        if reddit_buf.images[thing.data.id] then
                            return
                        end
                        reddit_buf.images[thing.data.id] = image
                        image:render()
                    end
                end)
            end
        )
    else
        if thing.player_job then
            thing.player_job:kill("sigterm")
            thing.player_job = nil
        end
        local image = reddit_buf.images[thing.data.id]
        if image then
            image:clear()
            reddit_buf.images[thing.data.id] = nil
        end
        thing.open = false
    end
end

---@param thing NvimReddit.Link
---@param reddit_buf NvimReddit.Buffer
---@param thing_mark_start integer
---@param thing_mark_end integer
function M.link(thing, reddit_buf, thing_mark_start, thing_mark_end)
    if not thing.open then
        ---@type string[]
        local lines = {}
        ---@type NvimReddit.Mark[]
        local marks = {}
        ---@type NvimReddit.Spoiler[]
        local spoilers = {}
        local line = 0
        ---@type { url: string; x: integer; y: integer }|nil
        local new_image = nil

        local margin = config.spacing.score_margin + 1
        local margin_string = (" "):rep(margin)
        local window_width = util.get_window_text_width(0)
        local width = math.min(window_width, config.spacing.max_line_length) - margin

        local contents_data = thing.contents_data ---@cast contents_data -?
        if thing.crosspost then
            local header_lines, header_marks = render.crosspost_header(contents_data)
            for _, header_line in ipairs(header_lines) do
                table.insert(lines, margin_string .. header_line)
            end

            for _, mark in ipairs(header_marks) do
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
            line = line + #header_lines
        end

        if thing.contents == "image" then
            local url
            if contents_data.preview then
                if #contents_data.preview.images ~= 1 then
                    print("More than one preview.images?", #contents_data.preview.images)
                end
                local preview = contents_data.preview.images[1]
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
                url = contents_data.url_overridden_by_dest or contents_data.url
            end

            new_image = {
                url = url,
                x = margin,
                y = thing_mark_end - 1
            }
        elseif thing.contents == "hosted_video" then
            table.insert(lines, margin_string .. "<hosted:video>")
            line = line + 1
            ---@type string[]
            local player_args = {}
            for i, arg in ipairs(config.player_options) do player_args[i] = arg end
            table.insert(player_args, contents_data.secure_media.reddit_video.dash_url)
            thing.player_job = vim.system(player_args, nil, config.player_onexit)
        elseif thing.contents == "rich_video" then
            table.insert(lines, margin_string .. "<rich:video>")
            line = line + 1
        elseif thing.contents == "link" then
            table.insert(lines, margin_string .. "<link>")
            line = line + 1
        elseif thing.contents == "gallery" then
            if not thing.gallery_selected then
                thing.gallery_selected = 1
            end
            local item = contents_data.gallery_data.items[thing.gallery_selected]
            local media = contents_data.media_metadata[item.media_id]
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

            thing.gallery_offset = line

            new_image = {
                url = url,
                x = margin,
                y = thing_mark_end + line
            }


            table.insert(lines, margin_string .. thing.gallery_selected .. " of " .. #contents_data.gallery_data.items)
            line = line + 1

            local item_lines = 0
            if item.caption then
                local caption_lines = richtext.render({item.caption}, width)
                for _, caption_line in ipairs(caption_lines) do
                    table.insert(lines, margin_string .. caption_line)
                end
                item_lines = #caption_lines
                line = line + item_lines
            end
            if item.outbound_url then
                table.insert(lines, margin_string .. item.outbound_url)
                table.insert(marks, {
                    details = {
                        hl_group = "RedditAnchor",
                        url = item.outbound_url,
                    },
                    line = line,
                    start_col = margin,
                    end_col = margin + item.outbound_url:len(),
                })
                item_lines = item_lines + 1
                line = line + 1
            end
            thing.gallery_item_line_count = item_lines
        end

        local selftext_html = contents_data.selftext_html
        if selftext_html ~= vim.NIL then ---@cast selftext_html -vim.NIL -- why can't luals figure this out???
            if thing.parsed == nil then
                local blocks = html.parse_md(selftext_html)
                thing.parsed = blocks
            end

            local expando_lines, expando_marks, expando_spoilers = render.blocks(thing.parsed, width)
            for _, expando_line in ipairs(expando_lines) do
                if expando_line == "" then
                    table.insert(lines, "")
                else
                    table.insert(lines, margin_string .. expando_line)
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

        if config.set_topline_on_expand then
            vim.fn.winrestview({ topline = thing_mark_start + 1 })
        end

        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })

        util.draw(reddit_buf, lines, marks, spoilers, {}, foldlevels, thing_mark_end, thing_mark_end)

        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

        thing.expando_mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end, 0, {
            id = thing.expando_mark,
            end_row = thing_mark_end + line,
            hl_group = "RedditExpanded",
            hl_eol = true,
            priority = 50,
        })

        thing.open = true

        if new_image then
            image_api.from_url(
                new_image.url,
                {
                    buffer = reddit_buf.buffer,
                    window = vim.api.nvim_get_current_win(),
                    with_virtual_padding = true,
                    x = new_image.x,
                    y = new_image.y
                },
                function(image)
                    if not image then
                        print("Failed to load image")
                        return
                    end
                    -- have to vim.schedule this or else rendering will mess up setting topline
                    vim.schedule(function()
                        if thing.open then
                            -- there is already an image there, this must have started loading when something else was also loading
                            if reddit_buf.images[thing.data.id] then
                                return
                            end
                            M.watch_image_extmark(image)
                            reddit_buf.images[thing.data.id] = image
                            image:render()
                        end
                    end)
                end
            )
        end
    else -- closing
        if thing.player_job then
            thing.player_job:kill("sigterm")
            thing.player_job = nil
        end

        local image = reddit_buf.images[thing.data.id]
        if image then
            image:clear()
            reddit_buf.images[thing.data.id] = nil
        end
        if thing.expando_mark then
            local row, _, expando_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))

            util.array_remove_range(reddit_buf.foldlevels, row + 1, expando_details.end_row)

            vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })

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
        end


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
