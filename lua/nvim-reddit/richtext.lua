local M = {}

local REDDIT_BASE = "https://www.reddit.com"

-- This function is laid out in kind of a stupid way to make lsp work
-- I don't think it should be a huge performance hit (?)

---@param type string
---@param extra any
---@return vim.api.keyset.set_extmark
local function inline_to_details(type, extra)
    ---@type vim.api.keyset.set_extmark
    local details
    if type == "strong" then
        details = {
            hl_group = "RedditStrong"
        }
    elseif type == "em" then
        details = {
            hl_group = "RedditEm"
        }
    elseif type == "del" then
        details = {
            hl_group = "RedditDel"
        }
    elseif type == "code" then
        details = {
            hl_group = "RedditCode"
        }
    elseif type == "a" then
        -- reddit-provided anchors should always have href? (this shouldn't be nil)
        ---@cast extra string
        if extra:match("^/") then
            extra = REDDIT_BASE .. extra
        end
        details = {
            hl_group = "RedditAnchor",
            url = extra
        }
    elseif type == "h1" then
        details = {
            hl_group = "RedditH1"
        }
    elseif type == "h2" then
        details = {
            hl_group = "RedditH2"
        }
    elseif type == "h3" then
        details = {
            hl_group = "RedditH3"
        }
    elseif type == "h4" then
        details = {
            hl_group = "RedditH4"
        }
    elseif type == "h5" then
        details = {
            hl_group = "RedditH5"
        }
    elseif type == "h6" then
        details = {
            hl_group = "RedditH6"
        }
    elseif type == "sup" then
        details = {
            hl_group = "RedditSup"
        }
    elseif type == "span" then
        -- we manually handle this in functions below, because we need
        -- to know how wide the text is to cover it
        details = {}
    else
        print("No mark conversion for this element:", type)
        details = {}
    end

    return details
end

---@class (exact) NvimReddit.RichTextRenderState
---@field lines string[]
---@field line integer
---@field marks NvimReddit.Mark[]
---@field spoilers NvimReddit.Spoiler[]
---@field open ({ type: string, extra: any, line: integer, col: integer })[]
---@field current string
---@field current_bytes integer
---@field word_carry ({ word: string, commands: NvimReddit.RichTextCommand[] })[]

---@param state NvimReddit.RichTextRenderState
---@param offset integer
---@param new_line boolean
local function process_carry(state, offset, new_line)
    -- loop through everything that is currently being carried (which was appended to
    -- the start of the segment (and therefore word) before this function call) and
    -- handle their commands. If the command is opening, add it to the list of open
    -- commands. If the command is closing, remove it from the list of open commands
    -- and create a mark for that now finished command

    -- when we are on a new line, we position the openings at the end the word, in
    -- line with how they were inserted. also set the start of inserted marks to the
    -- offset of the word on the new line, instead of the original opening column.
    for _, carry in ipairs(state.word_carry) do
        local carry_word_bytes = carry.word:len()
        for _, command in ipairs(carry.commands) do
            if command.opening then
                table.insert(state.open, {
                    type = command.type,
                    extra = command.extra,
                    line = state.line,
                    col = offset + (new_line and carry_word_bytes or 0)
                })
            else
                for i, o in ipairs(state.open) do
                    if o.type == command.type then
                        table.remove(state.open, i)

                        local start_col = new_line and o.col or offset
                        local end_col = offset + carry_word_bytes
                        if o.type == "span" then
                            local spoilered = state.current:sub(start_col + 1, end_col + 1)
                            table.insert(state.spoilers, {
                                details = {
                                    virt_text = {{("█"):rep(vim.fn.strdisplaywidth(spoilered)), "RedditSpoiler"}},
                                    virt_text_pos = "overlay",
                                    invalidate = true,
                                },
                                line = state.line,
                                start_col = start_col,
                                end_col = end_col,
                                spoiler = o.extra,
                            })
                        else
                            local details = inline_to_details(o.type, o.extra)
                            table.insert(state.marks, {
                                details = details,
                                line = state.line,
                                start_col = start_col,
                                end_col = end_col,
                            })
                        end
                        break
                    end
                end
            end
        end
        offset = offset + carry_word_bytes
    end
end

---@param state NvimReddit.RichTextRenderState
local function insert_line_marks(state)
    -- loop through the currently open commands and insert marks for them on
    -- the line that we just inserted
    for _, o in ipairs(state.open) do
        -- commands are inserted without knowledge of whether the next word
        -- will actually be on the same line, or wrap. if it wrapped without
        -- affecting any words, don't bother insert it. not sure if this test
        -- will always work. i guess we will find out :)
        if o.col < state.current_bytes then
            local start_col = o.col
            local end_col = state.current_bytes
            if o.type == "span" then
                local spoilered = state.current:sub(start_col + 1, end_col + 1)
                table.insert(state.spoilers, {
                    details = {
                        virt_text = {{("█"):rep(vim.fn.strdisplaywidth(spoilered)), "RedditSpoiler"}},
                        virt_text_pos = "overlay",
                        invalidate = true,
                    },
                    line = o.line,
                    start_col = start_col,
                    end_col = end_col,
                    spoiler = o.extra,
                })
            else
                local details = inline_to_details(o.type, o.extra)
                table.insert(state.marks, {
                    details = details,
                    line = o.line,
                    start_col = start_col,
                    end_col = end_col,
                })
            end
        end
        -- reset the line and column for this open command, which will now be
        -- open on the next line
        o.line = state.line
        o.col = 0
    end
end

---@param state NvimReddit.RichTextRenderState
---@param word string
---@param word_cells integer
---@param width integer
local function maybe_wrap(state, word, word_cells, width)
    local current_cells = vim.fn.strdisplaywidth(state.current)

    -- if the current cell width of our working line and the cell width of our word, plus
    -- one extra cell for a whitespace that will join the two (if current contains something)
    -- is greater than the allowed width, then add the current line to the list of lines and
    -- start working on a new line with our word
    if current_cells + word_cells + (current_cells == 0 and 0 or 1) > width then
        -- if the current line has nothing on it, this implies the single word is longer
        -- than the allowed width, so we just put the word past the allowed width
        if state.current_bytes == 0 then
            state.lines[state.line] = word
        else
            state.lines[state.line + 1] = state.current
            state.line = state.line + 1
        end

        process_carry(state, 0, false)

        -- now that we've processed the carry, we can insert all of the marks for
        -- the line that we just inserted
        insert_line_marks(state)

        -- set the current line to the word which caused us to wrap
        state.current = word
        state.current_bytes = state.current:len()
    else
        -- The word with the current line was not longer than our allowed width,
        -- so we will just add it to the current line

        local carry_offset
        if state.current_bytes == 0 then
            carry_offset = 0
            state.current = word
        else
            carry_offset = state.current_bytes + 1
            state.current = state.current .. " " .. word
        end
        state.current_bytes = state.current:len()

        process_carry(state, carry_offset, true)
    end
end

---@param richtext NvimReddit.RichText
---@param width integer
---@return string[], NvimReddit.Mark[], NvimReddit.Spoiler[]
function M.render(richtext, width)
    ---@type NvimReddit.RichTextRenderState
    local state = {
        lines = {},
        line = 0,
        marks = {},
        spoilers = {},
        open = {},
        current = "",
        current_bytes = 0,
        word_carry = {},
    }

    -- loop through all of the segments of the richtext. each segment could be a string or
    -- a "command" (which usually changes the style of the text, but could also be something
    -- like a newline)
    for _, segment in ipairs(richtext) do
        if type(segment) == "string" then
            local carry_words = {}
            for _, carry in ipairs(state.word_carry) do
                table.insert(carry_words, carry.word)
            end
            segment = table.concat(carry_words) .. segment

            local seg_end_byte = segment:len()
            local seg_find_offset = 1
            while true do
                -- find a "word" (contigious non-whitespace bytes) in our string segment
                ---@type integer|nil, integer|nil, string|nil
                local word_start_byte, word_end_byte, word = segment:find("(%S+)", seg_find_offset)
                if word_start_byte == nil then
                    -- the segment ended in whitespace, so we couldn't find another word
                    break
                end ---@cast word -?

                local word_cells = vim.fn.strdisplaywidth(word)

                -- our current word went up until the end of the current segment, but we can't
                -- do anything with it yet because we don't know what comes next (it could be
                -- a command followed by another string segment without any whitespace)
                if word_end_byte == seg_end_byte and word_cells < width then
                    -- FIXME(understand): i'm not sure why we do this instead of just pushing the entire word
                    local carry_bytes = 0
                    for _, carry in ipairs(state.word_carry) do
                        carry_bytes = carry_bytes + carry.word:len()
                    end
                    table.insert(state.word_carry, { word = word:sub(carry_bytes + 1), commands = {} })
                    break
                end
                seg_find_offset = word_end_byte + 1

                maybe_wrap(state, word, word_cells, width)

                state.word_carry = {}
            end
        else
            local word_carry_count = #state.word_carry
            if word_carry_count ~= 0 then
                if segment.type == "br" then
                    -- there was a line break, but it was directly after some text, meaning there was
                    -- a carry. we need to force this carry onto the current line (or wrap it) and
                    -- then force a line break
                    local carry_words = ""
                    for _, carry in ipairs(state.word_carry) do
                        carry_words = carry_words .. carry.word
                    end

                    maybe_wrap(state, carry_words, vim.fn.strdisplaywidth(carry_words), width)

                    state.word_carry = {}

                    -- now that maybe_wrap has either deposited all of the carry onto the current line
                    -- or created a new line, we can force another line (because this is a line break)
                    state.lines[state.line + 1] = state.current
                    state.line = state.line + 1

                    -- we can insert marks for the line we just created immediately because we know
                    -- that there isn't any carry to process (we just cleared it)
                    insert_line_marks(state)

                    -- reset the current line to nothing
                    state.current = ""
                    state.current_bytes = 0
                else
                    -- if we're not a break, but there is a carry, then we attach this command to the
                    -- most recently added carry
                    table.insert(state.word_carry[word_carry_count].commands, segment)
                end
            else
                -- we are at a command but there is no carry. usually happens when commands start at
                -- (or end before) the start of words that had spaces before them
                if segment.type == "br" then
                    -- there was a line break, but it occurred after some whitespace (sometimes multi-
                    -- line code blocks (that are not pre) can have a newline before their end, which
                    -- is converted to whitespace as part of html handling)

                    -- we can safely just add the new line because we know there is no carry.
                    state.lines[state.line + 1] = state.current
                    state.line = state.line + 1

                    -- then we can add marks for currently open stuff
                    insert_line_marks(state)

                    state.current = ""
                    state.current_bytes = 0
                else
                    if segment.opening then
                        table.insert(state.open, {
                            type = segment.type,
                            extra = segment.extra,
                            line = state.line,
                            col = state.current_bytes + (state.current_bytes == 0 and 0 or 1)
                        })
                    else
                        for i, o in ipairs(state.open) do
                            if o.type == segment.type then
                                table.remove(state.open, i)
                                -- if there is no carry and there is no line, why are we inserting a mark?
                                -- (this happens when there are lines in the html with no render. for example,
                                -- if you create insert [](#bot) into your markdown, it will create an empty
                                -- anchor in an empty paragraph with no height. we don't need to render that)
                                if state.current_bytes == 0 then
                                    break
                                end
                                local start_col = o.col
                                local end_col = state.current_bytes
                                if o.type == "span" then
                                    local spoilered = state.current:sub(start_col + 1, end_col + 1)
                                    table.insert(state.spoilers, {
                                        details = {
                                            virt_text = {{("█"):rep(vim.fn.strdisplaywidth(spoilered)), "RedditSpoiler"}},
                                            virt_text_pos = "overlay",
                                            invalidate = true,
                                        },
                                        line = o.line,
                                        start_col = start_col,
                                        end_col = end_col,
                                        spoiler = o.extra,
                                    })
                                else
                                    local details = inline_to_details(o.type, o.extra)
                                    table.insert(state.marks, {
                                        details = details,
                                        line = o.line,
                                        start_col = start_col,
                                        end_col = end_col,
                                    })
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- we have looped through all of the segments. now all that should remain is a series of
    -- carry words and/or commands
    if #state.word_carry ~= 0 then
        local carry_words = ""
        for _, carry in ipairs(state.word_carry) do
            carry_words = carry_words .. carry.word
        end

        maybe_wrap(state, carry_words, vim.fn.strdisplaywidth(carry_words), width)
    end


    -- FIXME: i don't remember why this is here
    if state.current_bytes ~= 0 then
        state.lines[state.line + 1] = state.current
    end
    return state.lines, state.marks, state.spoilers
end

return M
