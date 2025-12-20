local render = require("nvim-reddit.render")
local state = require("nvim-reddit.state")
local buffer = require("nvim-reddit.buffer")
local html = require("nvim-reddit.html")
local util = require("nvim-reddit.util")

local ns = state.ns
local tns = state.tns

local image_api = require("image")
vim.async = require("async")

local REDDIT_BASE = "https://www.reddit.com/"

local M = {}

---@param dir 1|0|-1
---@param thing NvimReddit.Votable
---@param reddit_buf NvimReddit.Buffer
local function vote(dir, thing, reddit_buf)
    state.reddit:vote(thing.data.name, dir, function(err)
        -- FIXME: proper voting errors
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
    vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
end

---@param thing NvimReddit.Thing
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

    vote(dir, thing, reddit_buf)
end

---@param thing NvimReddit.Thing
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

    vote(dir, thing, reddit_buf)
end

---@param thing NvimReddit.Thing
function M.open_comments(thing)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.permalink:sub(2))
    end)
end

---@param thing NvimReddit.Thing
---@param reddit_buf NvimReddit.Buffer
function M.expand(thing, reddit_buf)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end

    ---@type _, _, vim.api.keyset.extmark_details
    local _, _, thing_mark_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, tns, reddit_buf.selected_mark_id, { details = true }))
    local thing_mark_end = thing_mark_details.end_row
    ---@cast thing_mark_end -? -- we always set it with an end_row so

    vim.async.run(function()
        local line_num = 0
        local hint = thing.data.post_hint
        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
        if not thing.open then
            if hint then
                if hint == "image" then
                    if reddit_buf.images[thing.data.id] == nil then
                        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                        ---@type Image|nil
                        ---@diagnostic disable-next-line: param-type-mismatch, assign-type-mismatch -- luals is not very smart
                        local image = vim.async.await(3, image_api.from_url, thing.data.url_overridden_by_dest, {
                            buffer = reddit_buf.buffer,
                            window = vim.api.nvim_get_current_win(),
                            with_virtual_padding = true,
                            height = 20
                        })
                        if image == nil then
                            print("image was nil?!?!")
                            goto exit
                        end

                        reddit_buf.images[thing.data.id] = image
                        vim.api.nvim_set_option_value("modifiable", true, { buf = reddit_buf.buffer })
                    end

                    vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {""})
                    reddit_buf.images[thing.data.id]:render({
                        y = thing_mark_end
                    })
                    line_num = line_num + 1
                    ::exit::
                elseif hint ~= "link" and hint ~= "self" then
                    vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {"<" .. hint .. ">"})
                    line_num = line_num + 1
                end
            elseif thing.data.is_gallery then
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {"<gallery>"})
                line_num = line_num + 1
            elseif thing.data.crosspost_parent then
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end, thing_mark_end, false, {"<crosspost>"})
                line_num = line_num + 1
            end

            local selftext_html = thing.data.selftext_html
            if selftext_html ~= vim.NIL then ---@cast selftext_html -vim.NIL -- why can't luals figure this out???
                if thing.parsed == nil then
                    local blocks = html.parse(html.decode(selftext_html))
                    thing.parsed = blocks
                end

                local width = util.get_window_text_width(0)

                local lines, marks = render.blocks(thing.parsed, width)
                vim.api.nvim_buf_set_lines(reddit_buf.buffer, thing_mark_end+line_num, thing_mark_end+line_num, false, lines)
                for _, mark in ipairs(marks) do
                    mark.details.priority = mark.details.priority or 100
                    mark.details.end_row = thing_mark_end+line_num+mark.line
                    mark.details.end_col = mark.end_col
                    vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end+line_num+mark.line, mark.start_col, mark.details)
                end
                line_num = line_num + #lines
            end

            -- we've done nothing!
            if line_num == 0 then
                vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
                return
            end

            thing.expando_mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, thing_mark_end, 0, {
                id = thing.expando_mark,
                end_row = thing_mark_end+line_num
            })

            thing.open = true
        else
            if hint == "image" then
                reddit_buf.images[thing.data.id]:clear()
                reddit_buf.images[thing.data.id] = nil
            end
            local row, _, expando_details = unpack(vim.api.nvim_buf_get_extmark_by_id(reddit_buf.buffer, ns, thing.expando_mark, { details = true }))
            vim.api.nvim_buf_set_lines(reddit_buf.buffer, row, expando_details.end_row, false, {})
            thing.open = false
        end
        vim.api.nvim_set_option_value("modifiable", false, { buf = reddit_buf.buffer })
    end)
end

---@param thing NvimReddit.Thing
function M.permalink(thing)
    if thing.kind ~= "t1" then
        print("not a comment")
        return
    end

    vim.ui.open(REDDIT_BASE .. thing.data.permalink)
end

---@param thing NvimReddit.Thing
function M.open_subreddit(thing)
    if thing.kind ~= "t3" then
        print("not a link")
        return
    end
    vim.async.run(function()
        buffer.open(thing.data.subreddit_name_prefixed)
    end)
end

return M
