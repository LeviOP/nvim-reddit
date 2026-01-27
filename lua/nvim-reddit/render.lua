local util = require("nvim-reddit.util")
local html = require("nvim-reddit.html")
local config = require("nvim-reddit.config")
local richtext = require("nvim-reddit.richtext")
local M = {}

local LIST_PADDING = 4
local REDDIT_BASE = "https://www.reddit.com/"

---@class (exact) NvimReddit.Mark
---@field details table<string, any>
---@field line integer
---@field start_col integer
---@field end_col integer

---@class (exact) NvimReddit.Spoiler: NvimReddit.Mark
---@field spoiler integer

---@param list List
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.list(list, width)
    ---@type string[]
    local lines = {}
    local line = 0
    ---@type NvimReddit.Mark[]
    local marks = {}
    ---@type NvimReddit.Spoiler[]
    local spoilers = {}
    for item_num, item in ipairs(list.items) do
        local first_item_line
        if list.ordered then
            first_item_line = string.format("%" .. (LIST_PADDING - 1) .. "s", item_num) .. "."
        else
            first_item_line = (" "):rep(LIST_PADDING - 1) .. "*"
        end
        table.insert(lines, first_item_line)
        for p_num, p in ipairs(item.content) do
            local content_lines, content_marks, content_spoilers = richtext.render(p, width - (LIST_PADDING + 2))
            for content_line_num, content_line in ipairs(content_lines) do
                if p_num == 1 and content_line_num == 1 then
                    local last_index = #lines
                    lines[last_index] = lines[last_index] .. " " .. content_line
                else
                    table.insert(lines, (" "):rep(LIST_PADDING + 1) .. content_line)
                end
            end
            for _, mark in ipairs(content_marks) do
                mark.line = mark.line + line
                mark.end_col = mark.end_col + LIST_PADDING + 1
                mark.start_col = mark.start_col + LIST_PADDING + 1
                table.insert(marks, mark)
            end
            for _, spoiler in ipairs(content_spoilers) do
                spoiler.line = spoiler.line + line
                spoiler.end_col = spoiler.end_col + LIST_PADDING + 1
                spoiler.start_col = spoiler.start_col + LIST_PADDING + 1
                table.insert(spoilers, spoiler)
            end
            line = line + #content_lines
        end
        local p_count = #item.content
        if item.sublist ~= nil then
            local sublist_lines, sublist_marks, sublist_spoilers = M.list(item.sublist, width - (LIST_PADDING * 2))
            for sublist_line_num, sublist_line in ipairs(sublist_lines) do
                if sublist_line_num == 1 and p_count == 0 then
                    local last_index = #lines
                    lines[last_index] = lines[last_index] .. " " .. sublist_line
                else
                    table.insert(lines, (" "):rep(LIST_PADDING + 1) .. sublist_line)
                end
            end
            for _, mark in ipairs(sublist_marks) do
                mark.line = mark.line + line
                mark.end_col = mark.end_col + (LIST_PADDING + 1)
                mark.start_col = mark.start_col + (LIST_PADDING + 1)
                table.insert(marks, mark)
            end
            for _, spoiler in ipairs(sublist_spoilers) do
                spoiler.line = spoiler.line + line
                spoiler.end_col = spoiler.end_col + (LIST_PADDING + 1)
                spoiler.start_col = spoiler.start_col + (LIST_PADDING + 1)
                table.insert(spoilers, spoiler)
            end
            line = line + #sublist_lines
        elseif p_count == 0 then
            line = line + 1
        end
    end
    return lines, marks, spoilers
end

---@param blocks NvimReddit.Block[]
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.blockquote(blocks, width)
    -- FIXME: make this configurable and only calculated once
    local pad = "┃ "
    local pad_bytes = pad:len()
    local pad_width = vim.fn.strdisplaywidth(pad)

    local pad_no_trailing = pad:gsub("%s+$", "")
    local pad_no_trailing_bytes = pad_no_trailing:len()

    local lines, marks, spoilers = M.blocks(blocks, width - pad_width)

    for _, mark in ipairs(marks) do
        if mark.details.virt_text_win_col then
            mark.details.virt_text_win_col = pad_width + mark.details.virt_text_win_col
            if mark.start_col == mark.end_col then
                goto next
            end
        end
        mark.start_col = mark.start_col + pad_bytes
        mark.end_col = mark.end_col + pad_bytes
        ::next::
    end
    for _, spoiler in ipairs(spoilers) do
        spoiler.start_col = spoiler.start_col + pad_bytes
        spoiler.end_col = spoiler.end_col + pad_bytes
    end
    for i, line in ipairs(lines) do
        if line ~= "" then
            local length = line:len()
            lines[i] = pad .. line
            table.insert(marks, {
                details = {
                    priority = 200,
                    hl_group = "RedditBlockquote"
                },
                line = i - 1,
                start_col = pad_bytes,
                end_col = length + pad_bytes,
            })
            table.insert(marks, {
                details = {
                    priority = 200,
                    hl_group = "RedditBlockquotePad"
                },
                line = i - 1,
                start_col = 0,
                end_col = pad_bytes,
            })
        else
            lines[i] = pad_no_trailing
            table.insert(marks, {
                details = {
                    priority = 200,
                    hl_group = "RedditBlockquotePad"
                },
                line = i - 1,
                start_col = 0,
                end_col = pad_no_trailing_bytes,
            })
        end
    end
    return lines, marks, spoilers
end

---@param _ nil
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.hr(_, width)
    return {("━"):rep(width)}, {}, {}
end

---@param text string
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.pre(text, width)
    ---@type string[]
    local lines = {}
    ---@type NvimReddit.Mark[]
    local marks = {}
    local i = 1
    for line in text:gmatch("(.-)\n") do
        local len = line:len()
        -- virt_text_win_col doesn't use byte indexing because it's not actually positioned as part of the extmark
        local cols = vim.fn.strdisplaywidth(line)
        lines[i] = line
        table.insert(marks, {
            details = {
                hl_group = "RedditCode",
                virt_text = {{(" "):rep(width - cols), "RedditCode"}},
                virt_text_pos = "eol",
                virt_text_win_col = cols,
                priority = 50,
                invalidate = true,
            },
            line = i - 1,
            start_col = 0,
            end_col = len,
        })
        i = i + 1
    end
    return lines, marks, {}
end

---@type table<string, fun(contents: any, width: integer): string[], NvimReddit.Mark[], NvimReddit.Spoiler[]>
local TYPE_RENDERER_MAP = {
    richtext = richtext.render,
    list = M.list,
    blockquote = M.blockquote,
    hr = M.hr,
    pre = M.pre,
}

---Render an array of blocks
---@param blocks NvimReddit.Block[]
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.blocks(blocks, width)
    ---@type string[]
    local lines = {}
    local line = 0
    ---@type NvimReddit.Mark[]
    local marks = {}
    ---@type NvimReddit.Spoiler[]
    local spoilers = {}
    for _, block in ipairs(blocks) do
        local renderer = TYPE_RENDERER_MAP[block.type]
        if renderer == nil then
            print("no renderer for type:", block.type)
            goto continue
        end

        local block_lines, block_marks, block_spoilers = renderer(block.content, width)
        for _, block_line in ipairs(block_lines) do
            table.insert(lines, block_line)
        end
        for _, mark in ipairs(block_marks) do
            mark.line = mark.line + line
            table.insert(marks, mark)
        end
        for _, spoiler in ipairs(block_spoilers) do
            spoiler.line = spoiler.line + line
            table.insert(spoilers, spoiler)
        end
        line = line + #block_lines
        ::continue::
    end

    return lines, marks, spoilers
end

local flair_hls = {}
---@param subreddit string
---@param flair_id string
---@param text_color NvimReddit.FlairTextColor | vim.NIL
---@param background_color string | vim.NIL
---@return string, string
local function get_flair_hl(subreddit, flair_id, text_color, background_color)
    flair_id = subreddit .. flair_id
    if background_color == vim.NIL or background_color == "transparent" or background_color == "" then
        -- FIXME: we swap these because the default text flair is dark.. but on the official reddit
        -- ui the default flair background is white, so the dark text actually makes sense
        return "RedditFlairLightText", "RedditFlair"
    end ---@cast background_color -vim.NIL
    local text_hl = text_color == "light" and "RedditFlairLightText" or "RedditFlairDarkText"
    if flair_id == vim.NIL then print("THIS IS A FAIL") end
    if flair_hls[flair_id] then
        return text_hl, flair_hls[flair_id]
    end

    local hl_name = "RedditFlair_" .. flair_id:gsub("%W", "_")
    vim.api.nvim_set_hl(0, hl_name, { bg = background_color })
    flair_hls[flair_id] = hl_name
    return text_hl, hl_name
end

---@alias LineValue string|number|fun(): string
---@alias LineConditional LineValue|{ [1]: LineValue, condition: boolean }

---@param value LineConditional|nil
---@return string|nil, boolean
local function get_conditional(value)
    local t = type(value)
    if t == "nil" then
        return nil, false
    elseif t == "string" then
        return value, false
    elseif t == "number" then
        return tostring(value), false
    elseif t == "function" then
        return value(), false
    elseif t == "table" then
        if value.condition ~= nil and value.condition == false then
            return nil, true
        end
        local cond_value = value[1]
        if type(cond_value) == "function" then
            return cond_value(), true
        else
            return tostring(cond_value), true
        end
        -- this is just wrong?? we return on all types of the parameter
    end ---@diagnostic disable-line: missing-return
end

---@param lines NvimReddit.Line[]
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.lines(lines)
    ---@type string[]
    local rendered_lines = {}
    local cur_line = 0
    ---@type NvimReddit.Mark[]
    local marks = {}
    ---@type NvimReddit.Spoiler[]
    local spoilers = {}
    for _, line in ipairs(lines) do
        local rendered_line = "";
        for _, seg in ipairs(line) do
            local cond_value, is_table = get_conditional(seg)
            if cond_value == nil then
                goto continue
            end
            if #rendered_line ~= 0 then
                rendered_line = rendered_line .. " "
            end
            local offset = rendered_line:len()
            if is_table then ---@cast seg LineSegmentTable|LineSegmentMDHTML
                if seg.padding then
                    local cols = vim.fn.strdisplaywidth(cond_value)
                    local padding = math.max(seg.padding - cols, 0)
                    rendered_line = rendered_line .. (" "):rep(padding)
                    offset = rendered_line:len()
                end
                if seg.pre ~= nil then
                    rendered_line = rendered_line .. seg.pre
                    offset = rendered_line:len()
                end
                if seg.marks ~= nil then
                    for _, mark in ipairs(seg.marks) do
                        ---@type table<string, any>
                        local details = {
                            priority = 200,
                        }
                        local added = false
                        for opt, value in pairs(mark) do
                            local maybe_value = get_conditional(value)
                            if maybe_value then
                                details[opt] = maybe_value
                                added = true
                            end
                        end
                        if added then
                            table.insert(marks, {
                                details = details,
                                line = cur_line,
                                start_col = offset,
                                end_col = offset+cond_value:len()
                            })
                        end
                    end
                end
                if seg.mdhtml == true then ---@cast seg LineSegmentMDHTML
                    local width = util.get_window_text_width(0)
                    local blocks = html.parse_md(seg[1])
                    local col = vim.fn.strdisplaywidth(rendered_line)
                    local content_lines, content_marks, content_spoilers = M.blocks(blocks, math.min(width - col, config.spacing.max_line_length))
                    for i, content_line in ipairs(content_lines) do
                        if i == 1 then
                            table.insert(rendered_lines, rendered_line .. content_line)
                            -- out_lines[i] = rendered_line .. content_line
                        else
                            if content_line == "" then
                                table.insert(rendered_lines, "")
                            else
                                table.insert(rendered_lines, (" "):rep(col) .. content_line)
                                -- out_lines[i] = (" "):rep(col) .. content_line
                            end
                        end
                    end
                    for _, mark in ipairs(content_marks) do
                        if mark.details.virt_text_win_col then
                            -- virt_text_win_col doesn't use byte indexing because it's not actually positioned as part of the extmark
                            mark.details.virt_text_win_col = col + mark.details.virt_text_win_col
                            if mark.start_col == mark.end_col then
                                goto add
                            end
                        end
                        mark.end_col = (mark.line == 0 and offset or col) + mark.end_col
                        mark.start_col = (mark.line == 0 and offset or col) + mark.start_col
                        ::add::
                        mark.line = mark.line + cur_line
                        table.insert(marks, mark)
                    end
                    for _, spoiler in ipairs(content_spoilers) do
                        spoiler.end_col = (spoiler.line == 0 and offset or col) + spoiler.end_col
                        spoiler.start_col = (spoiler.line == 0 and offset or col) + spoiler.start_col
                        spoiler.line = spoiler.line + cur_line
                        table.insert(spoilers, spoiler)
                    end
                    if seg.hl_group then
                        for i, content_line in ipairs(content_lines) do
                            table.insert(marks, {
                                details = {
                                    hl_group = seg.hl_group,
                                    priority = 300,
                                },
                                line = i + cur_line - 1,
                                start_col = (i == 1 and offset or col),
                                end_col = (i == 1 and offset or col) + content_line:len()
                            })
                        end
                    end
                    cur_line = cur_line + #rendered_lines
                    goto out
                end
                rendered_line = rendered_line .. cond_value
                if seg.post ~= nil then
                    rendered_line = rendered_line .. seg.post
                end
            else
                rendered_line = rendered_line .. cond_value
            end
            ::continue::
        end
        table.insert(rendered_lines, rendered_line)
        cur_line = cur_line + 1
        ::out::
    end
    return rendered_lines, marks, spoilers
end

---@alias LineMark table<string, LineConditional>

---@class LineSegmentMDHTML
---@field [1] string
---@field mdhtml true
---@field hl_group string?

---@class LineSegmentTable
---@field [1] string|number|fun(): string
---@field pre string?
---@field post string?
---@field padding number?
---@field marks LineMark[]?

---@alias LineSegment LineSegmentTable|LineSegmentMDHTML|string
---@alias NvimReddit.Line (LineSegment)[] -- parentheses so that type expansion doesn't look confusing

---@type table<NvimReddit.LinkContents, string>
local CONTENTS_ICON_MAP = {
    ["image"] = "󰄀",
    ["selftext"] = "󰺫",
    ["link"] = "",
    ["gallery"] = "",
    ["hosted_video"] = "󰦳",
    ["rich_video"] = "󰦳",
    ["crosspost"] = "󱓊",
}

---@param thing NvimReddit.Link
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[], NvimReddit.ThingMark[], NvimReddit.FoldLevels
function M.link(thing)
    local link = thing.data

    local show_arrows = (not link.archived) or (link.likes ~= vim.NIL)

    local link_flair_text = link.link_flair_text
    local link_flair_foreground, link_flair_background
    if link_flair_text ~= vim.NIL then ---@cast link_flair_text -vim.NIL
        link_flair_text = link_flair_text:gsub("%s+$", "")
        link_flair_foreground, link_flair_background = get_flair_hl(link.subreddit, link_flair_text, link.link_flair_text_color, link.link_flair_background_color)
    end

    local author_flair_text = link.author_flair_text
    local author_flair_foreground, author_flair_background
    if author_flair_text ~= vim.NIL then ---@cast author_flair_text -vim.NIL
        author_flair_text = author_flair_text:gsub("%s+$", "")
        author_flair_foreground, author_flair_background = get_flair_hl(link.subreddit, author_flair_text, link.author_flair_text_color, link.author_flair_background_color)
    end

    ---@type NvimReddit.Line[]
    local lines = {
        {
            {
                show_arrows and "󰜷" or " ",
                padding = config.spacing.score_margin,
                marks = {{ hl_group = { "RedditUpvoted", condition = link.likes == true } }},
            },
            {
                link_flair_text --[[@as string]],
                condition = link_flair_text ~= vim.NIL,
                marks = {
                    { hl_group = link_flair_foreground },
                    { hl_group = link_flair_background },
                },
            },
            {
                "",
                condition = link.stickied and not thing.show_subreddit,
                marks = {{ hl_group = "RedditStickied" }}},
            -- apparently post titles are not santized on ingest, but at the client. there can be double spaces, newlines, etc.
            {
                link.title:gsub("%s+", " "),
                marks = {
                    { url = link.url },
                    { hl_group = { "RedditStickied", condition = link.stickied and not thing.show_subreddit } },
                    { hl_group = { "RedditPinned", condition = link.stickied and not thing.show_subreddit } },
                },
            },
            {
                link.domain,
                pre = "(",
                post = ")",
                marks = {{ hl_group = "RedditAnchor", url = { REDDIT_BASE .. thing.domain_url, condition = thing.domain_url ~= "" } }},
            },
        },
        {
            {
                link.score,
                padding = config.spacing.score_margin,
                marks = {{ hl_group = { link.likes and "RedditUpvoted" or "RedditDownvoted", condition = link.likes ~= vim.NIL } }},
            },
            "submitted",
            util.time_ago(link.created),
            "by",
            {
                link.author,
                marks = {
                    { hl_group = { "RedditAnchor", condition = link.author ~= "[deleted]" }, url = { REDDIT_BASE .. "user/" .. link.author, condition = link.author ~= "[deleted]" } },
                    { hl_group = { "RedditModerator", condition = link.distinguished == "moderator" } },
                    { hl_group = { "RedditAdmin", condition = link.distinguished == "admin" } },
                },
            },
            {
                author_flair_text--[[@as string]],
                marks = {
                    { hl_group = author_flair_foreground },
                    { hl_group = author_flair_background },
                },
                condition = (not thing.show_subreddit) and author_flair_text ~= vim.NIL,
            },
            {
                "to",
                condition = thing.show_subreddit,
            },
            {
                link.subreddit_name_prefixed,
                condition = thing.show_subreddit,
                marks = {{ hl_group = "RedditAnchor", url = REDDIT_BASE .. link.subreddit_name_prefixed }},
            },
            {
                "announcment",
                pre = "- ",
                marks = {{ hl_group = "RedditStickied" }},
                condition = link.stickied and not thing.show_subreddit,
            },
            {
                "pinned",
                pre = "- ",
                marks = {{ hl_group = "RedditPinned" }},
                condition = link.pinned and not thing.show_subreddit,
            },
        },
        {
            {
                show_arrows and "󰜮" or " ",
                padding = config.spacing.score_margin,
                marks = {{ hl_group = { "RedditDownvoted", condition = link.likes == false } }},
            },
            {
                "[" .. (CONTENTS_ICON_MAP[thing.contents] or "?") .. "]",
                condition = thing.contents ~= nil,
            },
            {
                "NSFW",
                marks = {{ hl_group = "RedditNSFWTag" }},
                condition = thing.data.over_18,
            },
            {
                "SPOILER",
                marks = {{ hl_group = "RedditSpoilerTag" }},
                condition = thing.data.spoiler,
            },
            {
                link.num_comments .. " comment" .. (link.num_comments ~= 1 and "s" or ""),
                marks = {{ url = REDDIT_BASE .. link.permalink:sub(2) }},
            },
        },
    }


    local rendered_lines, marks, spoilers = M.lines(lines)
    local line_count = #rendered_lines
    ---@type NvimReddit.ThingMark[]
    local things = {{
        start_line = 0,
        lines = line_count,
        thing = thing
    }}

    ---@type NvimReddit.FoldLevels
    local foldlevels = {}
    for line = 1, line_count do
        foldlevels[line] = 0
    end

    return rendered_lines, marks, spoilers, things, foldlevels
end

---@param thing NvimReddit.Comment
---@param render_children boolean
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[], NvimReddit.ThingMark[], NvimReddit.FoldLevels
function M.comment(thing, render_children)
    local comment = thing.data

    if not thing.time_ago then
        thing.time_ago = util.time_ago(comment.created)
        if comment.edited ~= false then
            thing.time_ago = thing.time_ago .. "*"
            thing.time_ago_edited = "(last edited " .. util.time_ago(comment.edited) .. ")"
        end
    end

    local show_arrows = (not comment.archived) or (comment.likes ~= vim.NIL)

    local author_flair_text = comment.author_flair_text
    local author_flair_foreground, author_flair_background
    if author_flair_text ~= vim.NIL then ---@cast author_flair_text -vim.NIL
        author_flair_text = author_flair_text:gsub("%s+$", "")
        author_flair_foreground, author_flair_background = get_flair_hl(comment.subreddit, author_flair_text, comment.author_flair_text_color, comment.author_flair_background_color)
    end

    ---@type NvimReddit.Line[]
    local lines = {
        {
            -- FIXME: use padding?
            {
                (" "):rep(math.max(thing.padding - 1, 0)),
                condition = thing.padding ~= 0,
            },
            {
                show_arrows and "󰜷" or " ",
                marks = {{ hl_group = { "RedditUpvoted", condition = comment.likes == true } }},
            },
            {
                comment.author,
                marks = {
                    { hl_group = { "RedditAnchor", condition = comment.author ~= "[deleted]" }, url = { REDDIT_BASE .. "user/" .. comment.author, condition = comment.author ~= "[deleted]" } },
                    { hl_group = { "RedditSecondary", condition = not comment.author_fullname } },
                    { hl_group = { "RedditOP", condition = comment.is_submitter } },
                    { hl_group = { "RedditModerator", condition = comment.distinguished == "moderator" } },
                    { hl_group = { "RedditAdmin", condition = comment.distinguished == "admin" } },
                },
            },
            {
                author_flair_text--[[@as string]],
                marks = {
                    { hl_group = author_flair_foreground },
                    { hl_group = author_flair_background },
                },
                condition = author_flair_text ~= vim.NIL,
            },
            {
                comment.score .. " point" .. (comment.score == 1 and "" or "s"),
                marks = {{ hl_group = "RedditPoints" }},
                condition = not comment.score_hidden,
            },
            {
                "[score hidden]",
                marks = {{ hl_group = "RedditSecondary" }},
                condition = comment.score_hidden,
            },
            {
                thing.time_ago,
                marks = {{ hl_group = "RedditSecondary" }},
            },
            {
                thing.time_ago_edited,
                marks = {{ hl_group = "RedditSecondary" }},
                condition = comment.edited ~= false,
            },
            {
                "- stickied comment",
                marks = {{ hl_group = "RedditStickied" }},
                condition = comment.stickied,
            },
            {
                "",
                marks = {{ hl_group = "RedditLocked" }},
                condition = comment.locked,
            },
        },
        {
            {
                (" "):rep(math.max(thing.padding - 1, 0)),
                condition = thing.padding ~= 0,
            },
            {
                show_arrows and "󰜮" or " ",
                marks = {{ hl_group = { "RedditDownvoted", condition = comment.likes == false } }}
            },
            { comment.body_html, mdhtml = true, hl_group = comment.removal_reason == "legal" and "RedditAdminTakedown" or nil },
        }
    }

    if comment.link_title then
        ---@type NvimReddit.Line
        local line = {
            { comment.link_title, marks = {{ url = comment.link_url }} },
            "by",
            {
                comment.link_author,
                marks = {{
                    hl_group = { "RedditAnchor", condition = comment.link_author ~= "[deleted]" },
                    url = { REDDIT_BASE .. "user/" .. comment.link_author, condition = comment.link_author ~= "[deleted]" },
                }},
            },
            "in",
            { comment.subreddit, marks = {{ hl_group = "RedditAnchor", url = REDDIT_BASE .. comment.subreddit_name_prefixed }} },
        }
        table.insert(lines, 1, line)
    end


    local rendered_lines, marks, spoilers = M.lines(lines)
    local top_len = #rendered_lines

    ---@type NvimReddit.ThingMark[]
    local things = {{
        start_line = 0,
        lines = top_len,
        thing = thing
    }}

    ---@type NvimReddit.FoldLevels
    local foldlevels = {}
    local foldlevel = thing.padding / 2 + 1
    for line = 1, top_len do
        foldlevels[line] = foldlevel
    end

    local media_metadata = thing.data.media_metadata
    if media_metadata then
        for _, media in pairs(media_metadata) do
            if media.e == "Image" then
                for _, mark in ipairs(marks) do
                    ---@type string|nil
                    local url = mark.details.url
                    if url and url == media.s.u then
                        thing.media = {
                            media = media,
                            line = mark.line,
                            byte = mark.start_col,
                        }
                        -- This is a super duper hack. Doing it in any other way would be way more
                        -- annoying, though. Might cause issues down the line :)
                        local line = rendered_lines[mark.line + 1]
                        rendered_lines[mark.line + 1] = line:sub(1, mark.start_col) .. "<image>"
                        mark.end_col = mark.start_col + 7 -- length of "<image>"

                        goto found
                    end
                end
            elseif media.e == "AnimatedImage" then
                if media.t == "giphy" then
                    for _, mark in ipairs(marks) do
                        ---@type string|nil
                        local url = mark.details.url
                        if url and url == media.ext then
                            thing.media = {
                                media = media,
                                line = mark.line,
                                byte = mark.start_col,
                            }
                            goto found
                        end
                    end
                else
                    for _, mark in ipairs(marks) do
                        local url = mark.details.url
                        if url and url == media.s.gif then
                            thing.media = {
                                media = media,
                                line = mark.line,
                                byte = mark.start_col,
                            }
                            local line = rendered_lines[mark.line + 1]
                            rendered_lines[mark.line + 1] = line:sub(1, mark.start_col) .. "<gif>"
                            mark.end_col = mark.start_col + 5 -- length of "<gif>"

                            goto found
                        end
                    end
                end
            else
                print("Unkown media type:", media.e)
            end
        end
        ::found::
    end

    local line = top_len + 1
    if type(comment.replies) == "table" and render_children then
        if comment.replies.kind ~= "Listing" then
            print("Why aren't the replies a listing!??!!!!")
            return rendered_lines, marks, spoilers, things, {}
        end

        for i, child in ipairs(comment.replies.data.children) do
            local child_lines, child_marks, child_spoilers, child_things, child_foldlevels
            if child.kind == "t1" then
                child.padding = thing.padding + 2
                child_lines, child_marks, child_spoilers, child_things, child_foldlevels = M.comment(child, true)
            elseif child.kind == "more" then
                child.padding = thing.padding + 2
                child.link_id = thing.data.link_id
                child.self_index = i
                child.parent = thing
                child_lines, child_marks, child_spoilers, child_things, child_foldlevels = M.more(child)
            else
                print("Unexpected kind in replies children:", child.kind)
                goto continue
            end

            table.insert(rendered_lines, "")
            table.insert(foldlevels, foldlevel)
            for _, child_line in ipairs(child_lines) do
                table.insert(rendered_lines, child_line)
            end
            for _, mark in ipairs(child_marks) do
                mark.line = mark.line + line
                table.insert(marks, mark)
            end
            for _, spoiler in ipairs(child_spoilers) do
                spoiler.line = spoiler.line + line
                table.insert(spoilers, spoiler)
            end
            local child_line_count = #child_lines
            for _, child_thing in ipairs(child_things) do
                child_thing.start_line = child_thing.start_line + line
                table.insert(things, child_thing)
            end
            for _, child_foldlevel in ipairs(child_foldlevels) do
                table.insert(foldlevels, child_foldlevel)
            end
            line = line + child_line_count + 1
            ::continue::
        end
    end

    return rendered_lines, marks, spoilers, things, foldlevels
end

---@param thing NvimReddit.More
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[], NvimReddit.ThingMark[], NvimReddit.FoldLevels
function M.more(thing)
    local count = thing.data.count
    ---@type NvimReddit.Line[]
    local lines
    if count == 0 then
        lines = {{
            {
                (" "):rep(math.max(thing.padding - 1, 0)),
                condition = thing.padding ~= 0,
            },
            {
                "continue this thread ──▶",
                marks = {{ hl_group = "RedditAnchor", url = REDDIT_BASE .. thing.parent.data.permalink }},
            },
        }}
    else
        lines = {{
            {
                (" "):rep(math.max(thing.padding - 1, 0)),
                condition = thing.padding ~= 0,
            },
            {
                "load more comments",
                marks = {{ hl_group = "RedditMore" }}
            },
            {
                count .. (count == 1 and " reply" or " replies"),
                pre = "(",
                post = ")",
            },
        }}
    end
    local rendered_lines, marks = M.lines(lines)
    ---@type NvimReddit.ThingMark[]
    local things = {{
        start_line = 0,
        lines = #rendered_lines,
        thing = thing
    }}

    return rendered_lines, marks, {}, things, {thing.padding / 2 + 1}
end

---@param thing NvimReddit.Subreddit
---@return string[], NvimReddit.Mark[]
function M.sidebar(thing)
    local subreddit = thing.data
    ---@type NvimReddit.Line[]
    local lines = {
        -- maybe .url should be used instead? this is just more convenient
        { { subreddit.display_name, marks = {{ hl_group = "RedditH1", url = REDDIT_BASE .. subreddit.display_name_prefixed } }} },
        { { subreddit.description_html--[[@as string]], mdhtml = true, condition = subreddit.description_html ~= vim.NIL } },
        -- HACK: add actual hr instead of just replicating markdown html
        { { "<div><hr></div>" , mdhtml = true } },
        { { "a community for " .. util.time_since(subreddit.created_utc) } }
    }
    local rendered_lines, marks = M.lines(lines)
    return rendered_lines, marks
end

---@class (exact) NvimReddit.InlineMedia
---@field media NvimReddit.Media
---@field line integer
---@field byte integer

---@class (exact) NvimReddit.ThingMark
---@field thing NvimReddit.Selectable
---@field start_line integer
---@field lines integer

---@alias NvimReddit.FoldLevels integer[]

---@param listing NvimReddit.Listing
---@param endpoint NvimReddit.ParsedEndpoint
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[], NvimReddit.ThingMark[], NvimReddit.FoldLevels
function M.listing(listing, endpoint)
    ---@type string[]
    local lines = {}
    ---@type NvimReddit.Mark[]
    local marks = {}
    ---@type NvimReddit.Spoiler[]
    local spoilers = {}
    ---@type NvimReddit.ThingMark[]
    local things = {}
    ---@type NvimReddit.FoldLevels
    local foldlevels = {}
    local line = 0
    for i, thing in ipairs(listing.data.children) do
        local thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels
        if thing.kind == "t1" then
            thing.padding = 0
            thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels = M.comment(thing, true)
        elseif thing.kind == "t3" then
            -- crossposts don't have a domain (also removed posts? even though official reddit ui shows one)
            if thing.data.domain == "" then
                thing.domain_url = ""
            else
                ---@type string
                local url_domain = thing.data.url:match("^%w+://([^/:?#]+)")
                -- url_domain = url_domain:gsub("^www%.", "") -- idr what this was for
                if url_domain ~= thing.data.domain then
                    -- this might not be a good assumption to make, but we'll see i guess
                    thing.domain_url = thing.data.subreddit_name_prefixed
                else
                    thing.domain_url = "domain/" .. thing.data.domain
                end
            end
            thing.show_subreddit = endpoint.subreddit ~= thing.data.subreddit:lower()

            local hint = thing.data.post_hint
            if hint then
                if hint == "image" then
                    thing.contents = "image"
                elseif hint == "link" then
                    thing.contents = "link"
                elseif hint == "self" then
                    thing.contents = "selftext"
                elseif hint == "hosted:video" then
                    thing.contents = "hosted_video"
                elseif hint == "rich:video" then
                    thing.contents = "rich_video"
                else
                    print("Unhandled hint type?", hint)
                end
            elseif thing.data.is_self then
                if thing.data.selftext_html ~= vim.NIL then
                    thing.contents = "selftext"
                end
                -- If is_self is true but there is no selftext, it's a
                -- title-only post with no body
            elseif thing.data.is_gallery then
                thing.contents = "gallery"
            elseif thing.data.secure_media ~= vim.NIL then
                if thing.data.secure_media.reddit_video then
                    thing.contents = "hosted_video"
                elseif thing.data.secure_media.oembed then
                    thing.contents = "rich_video"
                else
                    vim.print("unknown media type?", thing.data.secure_media)
                end
            elseif thing.data.crosspost_parent then
                thing.contents = "crosspost"
            elseif thing.data.selftext_html ~= vim.NIL then
                thing.contents = "selftext"
            else
                thing.contents = "link"
                print("assuming this is a link:", thing.data.title)
            end

            thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels = M.link(thing)
        elseif thing.kind == "more" then
            thing.padding = 0
            thing.link_id = thing.data.parent_id
            thing.self_index = i
            thing.parent = listing
            thing_lines, thing_style_marks, thing_spoilers, thing_marks, thing_foldlevels = M.more(thing)
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
        for _, thing_spoiler in ipairs(thing_spoilers) do
            thing_spoiler.line = thing_spoiler.line + line
            table.insert(spoilers, thing_spoiler)
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
        table.insert(foldlevels, 0)
        line = line + 1
        ::continue::
    end

    if listing.data.after ~= vim.NIL or listing.data.before ~= vim.NIL then
        local more_line = "view more: "
        local prev =  "‹ prev"
        local next =  "next ›"
        local len = more_line:len()
        if listing.data.before ~= vim.NIL then
            more_line = more_line .. prev
            table.insert(marks, {
                details = {
                    hl_group = "RedditNavButton"
                },
                line = line,
                start_col = len,
                end_col = len + prev:len(),
            })
            if listing.data.after ~= vim.NIL then
                more_line = more_line .. " | "
                len = more_line:len()
                more_line = more_line .. next
                table.insert(marks, {
                    details = {
                        hl_group = "RedditNavButton"
                    },
                    line = line,
                    start_col = len,
                    end_col = len + next:len(),
                })
            end
        else
            more_line = more_line .. next
            table.insert(marks, {
                details = {
                    hl_group = "RedditNavButton"
                },
                line = line,
                start_col = len,
                end_col = len + next:len(),
            })
        end
        table.insert(lines, more_line)
    end

    return lines, marks, spoilers, things, foldlevels
end

return M
