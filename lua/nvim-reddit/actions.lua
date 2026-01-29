local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local buffer = require("nvim-reddit.buffer")
local config = require("nvim-reddit.config")
local util = require("nvim-reddit.util")
local expand = require("nvim-reddit.expand")
local richtext = require("nvim-reddit.richtext")
local float_lib = require("nvim-reddit.float")

local ns = state.ns
local tns = state.tns
local sns = state.sns

local image_api = require("reddit-image")

-- This is different than other files! includes a trailing slash. unify at some point
local REDDIT_BASE = "https://www.reddit.com"

local M = {}

---@param thing NvimReddit.Votable
---@param reddit_buf NvimReddit.Buffer
---@param dir 1|0|-1
local function vote(thing, reddit_buf, dir)
    if thing.data.archived then
        print("You cannot vote on archived posts")
        return
    end
    state.reddit:vote(thing.data.name, dir, function(err)
        if err then
            vim.print("Error voting:", err)
        end
    end)

    local geometry
    local image = reddit_buf.images[thing.data.id]
    if image then
        geometry = {
            y = image.extmark.row,
            x = image.extmark.col
        }
        image:clear()
    end

    local row, _, details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_lines, thing_style_marks, thing_spoilers, thing_marks
    if thing.kind == "t1" then
        thing_lines, thing_style_marks, thing_spoilers, thing_marks = render.comment(thing, false)
    elseif thing.kind == "t3" then
        thing_lines, thing_style_marks, thing_spoilers, thing_marks = render.link(thing)
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
    vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, details.end_row, false, thing_lines)
    for _, style_mark in ipairs(thing_style_marks) do
        style_mark.details.end_row = style_mark.line + row
        style_mark.details.end_col = style_mark.end_col
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, style_mark.line + row, style_mark.start_col, style_mark.details)
    end
    for _, spoiler in ipairs(thing_spoilers) do
        spoiler.details.end_row = spoiler.line + row
        spoiler.details.end_col = spoiler.end_col
        local extmark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, sns, spoiler.line + row, spoiler.start_col, spoiler.details)
        local map = reddit_buf.spoiler_marks_map
        local spoiler_id = spoiler.spoiler
        if not map[spoiler_id] then
            map[spoiler_id] = {}
        end
        table.insert(map[spoiler_id], extmark)
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

    if image then
        image:render(geometry)
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
    if thing.kind == "t3" then
        buffer.open(thing.data.permalink:sub(2))
    elseif thing.kind == "t1" and thing.data.link_permalink then
        buffer.open(thing.data.link_permalink:gsub("^https://www.reddit.com/", ""))
    else
        print("not a link")
    end
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
    buffer.open(thing.data.subreddit_name_prefixed)
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
    buffer.open("user/" .. thing.data.author)
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
---@param dir -1|1
local function gallery_nav(thing, reddit_buf, dir)
    if thing.kind ~= "t3" or not thing.contents_data.is_gallery or not thing.open then
        print("This is not an open gallery")
        return
    end

    if thing.player_job then
        thing.player_job:kill("sigterm")
        thing.player_job = nil
    end

    local last = #thing.contents_data.gallery_data.items
    thing.gallery_selected = thing.gallery_selected + dir
    if thing.gallery_selected == 0 then
        thing.gallery_selected = last
    elseif thing.gallery_selected > last then
        thing.gallery_selected = 1
    end

    local item = thing.contents_data.gallery_data.items[thing.gallery_selected]
    local media = thing.contents_data.media_metadata[item.media_id]
    if not media then
        print("Media was missing?")
        return
    end

    local url = expand.get_best_image_resolution_url(media)

    local margin = config.spacing.score_margin + 1
    local margin_string = (" "):rep(margin)

    local window_width = util.get_window_text_width(0)
    local width = math.min(window_width, config.spacing.max_line_length) - margin

    local lines = {margin_string .. thing.gallery_selected .. " of " .. #thing.contents_data.gallery_data.items}

    local item_line_count = 0
    if item.caption then
        local caption_lines = richtext.render({item.caption}, width)
        for _, caption_line in ipairs(caption_lines) do
            table.insert(lines, margin_string .. caption_line)
        end
        item_line_count = #caption_lines
    end

    ---@type integer, _, vim.api.keyset.extmark_details
    local _, _, thing_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_mark_end = thing_mark_details.end_row
    ---@cast thing_mark_end -? -- we always set it with an end_row so

    local gallery_line = thing.gallery_offset + thing_mark_end

    local url_line
    if item.outbound_url then
        table.insert(lines, margin_string .. item.outbound_url)
        url_line = gallery_line + item_line_count + 1
        item_line_count = item_line_count + 1
    end

    local item_line_diff = thing.gallery_item_line_count - item_line_count

    local row, _, expando_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))

    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
    vim.api.nvim_buf_set_lines(reddit_buf.buffer, gallery_line, gallery_line + thing.gallery_item_line_count + 1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

    if item.outbound_url then
        vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, url_line, margin, {
            hl_group = "RedditAnchor",
            url = item.outbound_url,
            end_col = margin + item.outbound_url:len(),
            end_row = url_line,
            priority = 200,
        })
    end

    thing.gallery_item_line_count = item_line_count

    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, row, 0, {
        id = thing.expando_mark,
        end_row = expando_details.end_row - item_line_diff,
        hl_group = "RedditExpanded",
        hl_eol = true,
        priority = 50,
    })

    if media.e == "AnimatedImage" and config.use_gif_player then
        ---@type string[]
        local player_args = {}
        for i, arg in ipairs(config.gif_player_options) do player_args[i] = arg end
        table.insert(player_args, media.s.mp4)
        thing.player_job = vim.system(player_args, nil, config.player_onexit)
    end

    local existing_image = reddit_buf.images[thing.data.id]
    if existing_image then
        existing_image:clear()
        reddit_buf.images[thing.data.id] = nil
    end

    image_api.from_url(
        url,
        {
            buffer = reddit_buf.buffer,
            window = vim.api.nvim_get_current_win(),
            with_virtual_padding = true,
            x = margin,
            y = gallery_line,
        },
        function(image)
            if not image then
                print("Failed to load image")
                return
            end
            vim.schedule(function()
                if thing.open then
                    -- there is already an image there, this must have started loading when something else was also loading
                    if reddit_buf.images[thing.data.id] then
                        return
                    end
                    expand.watch_image_extmark(image)
                    reddit_buf.images[thing.data.id] = image
                    image:render()
                end
            end)
        end
    )
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_next(thing, reddit_buf)
    gallery_nav(thing, reddit_buf, 1)
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.gallery_prev(thing, reddit_buf)
    gallery_nav(thing, reddit_buf, -1)
end

---@param thing NvimReddit.Selectable
function M.open_domain(thing)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end
    buffer.open(thing.domain_url)
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
    buffer.open(thing.data.permalink:sub(2) .. "?context=3")
end

---@param thing NvimReddit.Selectable
function M.open_full_context(thing)
    if thing.kind ~= "t1" then
        print("not a comment")
        return
    end
    buffer.open(thing.data.permalink:sub(2) .. "?context=10000")
end

---@param more NvimReddit.More
---@param reddit_buf NvimReddit.Buffer
local function load_more(more, reddit_buf)
    state.reddit:morechildren(more.data.children, more.link_id, function(result, err)
        if err then
            vim.print(err)
            return
        end

        -- base fold level (indent) for newly rendered things
        local foldlevel = more.padding / 2

        if more.parent.kind == "t1" then
            table.remove(more.parent.data.replies.data.children, more.self_index)
        else
            table.remove(more.parent.data.children, more.self_index)
        end

        vim.schedule(function()
            local lines, marks, spoilers, things, foldlevels = util.render_appended_things(more.parent, result.json.data.things --[[@as (NvimReddit.Comment|NvimReddit.More)[] ]], foldlevel, true)

            local start_line = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, {}))
            local end_line = start_line + 1

            -- remove more thing mark
            vim.api.nvim_buf_del_extmark(reddit_buf.buffer, tns, reddit_buf.selected_mark_id)
            reddit_buf.mark_thing_map[reddit_buf.selected_mark_id] = nil
            reddit_buf.selected_mark_id = nil

            vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
            util.draw(reddit_buf, lines, marks, spoilers, things, foldlevels, start_line, end_line)
            vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
        end)
    end)
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.enter(thing, reddit_buf)
    if thing.kind == "more" then
        if thing.data.count == 0 then
            -- "continue this thread"
            buffer.open(thing.parent.data.permalink:sub(2))
        else
            load_more(thing, reddit_buf)
        end
    elseif thing.kind == "t3" then
        vim.ui.open(thing.data.url)
    else
        print("no enter action on this thing")
    end
end

---@param thing NvimReddit.Selectable
---@param reddit_buf NvimReddit.Buffer
function M.reply(thing, reddit_buf)
    if thing.kind ~= "t1" and thing.kind ~= "t3" then
        return
    end ---@cast thing NvimReddit.Replyable

    if reddit_buf.endpoint_type ~= "article" then
        print("You can only comment on comment pages!")
        return
    end
    if thing.reply_float then
        local parent_window = vim.api.nvim_get_current_win()
        thing.reply_float:enter(parent_window)
        return
    end

    local row
    if thing.kind == "t3" and thing.open then
        local _, _, expando_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))
        local expando_mark_end = expando_mark_details.end_row ---@cast expando_mark_end -?
        row = expando_mark_end + 1
    else
        ---@type integer, _, vim.api.keyset.extmark_details
        local _, _, thing_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
        local thing_mark_end = thing_mark_details.end_row ---@cast thing_mark_end -?
        row = thing_mark_end + 1
    end

    local col = thing.kind == "t1" and thing.padding + 2 or 0

    local status_lines = {"", (" "):rep(col) .. "Speaking as: " .. state.me.name}
    for _ = 1, #status_lines do
        table.insert(reddit_buf.foldlevels, row, col / 2)
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
    vim.api.nvim_buf_set_lines(reddit_buf.buffer, row - 1, row - 1, true, status_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })

    local float = float_lib.new(reddit_buf, row, col, thing)

    table.insert(reddit_buf.floats, float)
    thing.reply_float = float
end

return M
