local state = require("nvim-reddit.state")
local config = require("nvim-reddit.config")

local ns = state.ns

---@class NvimReddit.Float
---@field window integer|nil
---@field buffer integer
---@field mark integer
---@field row integer
---@field col integer
---@field bufpos boolean
---@field replying_to NvimReddit.Replyable
---@field reddit_buf NvimReddit.Buffer
---@field close_override true|nil
local Float = {}
Float.__index = Float

---@param reddit_buf NvimReddit.Buffer
---@param row integer
---@param col integer
---@param replying_to NvimReddit.Replyable
---@return NvimReddit.Float
function Float.new(reddit_buf, row, col, replying_to)
    local self = setmetatable({}, Float)

    local virt_lines = {}
    for i = 1, 8 do
        virt_lines[i] = {{" ", ""}}
    end
    local mark = vim.api.nvim_buf_set_extmark(reddit_buf.buffer, ns, row, col, {
        virt_lines = virt_lines,
    })

    local buffer = vim.api.nvim_create_buf(config.reply.float.listed, config.reply.float.scratch)

    local parent_window = vim.api.nvim_get_current_win()
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_set_current_win(parent_window)
    end, { buffer = buffer })

    self.buffer = buffer
    self.mark = mark
    self.row = row
    self.col = col
    self.bufpos = true
    self.replying_to = replying_to
    self.reddit_buf = reddit_buf

    self:enter(parent_window)

    return self
end

---@param parent_window integer
function Float:enter(parent_window)
    local visible, draw = self:is_visible(parent_window)
    if not visible or draw then
        local pos = vim.api.nvim_win_get_cursor(parent_window)
        vim.api.nvim_win_set_cursor(parent_window, { self.row + 1, self.col })
        vim.cmd("normal! zz")
        vim.api.nvim_win_set_cursor(parent_window, pos)
        visible, draw = self:is_visible(parent_window)
    end
    if visible then
        self:draw(parent_window, draw)
        vim.api.nvim_set_current_win(self.window)
    end
end

---@class (exact) NvimReddit.FloatDraw
---@field bufpos? [integer, integer]
---@field row? integer
---@field col? integer
---@field height integer

---@param parent_window integer
---@param draw NvimReddit.FloatDraw|nil
function Float:draw(parent_window, draw)
    if not draw then
        draw = {
            bufpos = {self.row, self.col},
            row = nil,
            col = nil,
            height = 8,
        }
    end
    if self.window then
        vim.api.nvim_win_set_config(self.window, {
            relative = "win",
            bufpos = draw.bufpos,
            row = draw.row,
            col = draw.col,
            win = parent_window,
            width = 70,
            height = draw.height,
        })
    else
        local window = vim.api.nvim_open_win(self.buffer, false, {
            relative = "win",
            bufpos = draw.bufpos,
            row = draw.row,
            col = draw.col,
            win = parent_window,
            width = 70,
            height = draw.height,
        })
        self.window = window
        for option, value in pairs(config.reply.float.options) do
            vim.api.nvim_set_option_value(option, value, { win = window })
        end
        vim.api.nvim_set_option_value("winfixbuf", true, { win = window })
        state.win_float_map[window] = self
    end
    -- else
    --     if self.window then
    --         vim.api.nvim_win_set_config(self.window, {
    --             relative = "win",
    --             bufpos = {self.row, self.col},
    --             win = parent_window,
    --             width = 70,
    --             height = 8,
    --         })
    --     else
    --         local window = vim.api.nvim_open_win(self.buffer, false, {
    --             relative = "win",
    --             bufpos = {self.row, self.col},
    --             win = parent_window,
    --             width = 70,
    --             height = 8,
    --         })
    --         self.window = window
    --         for option, value in pairs(config.reply.float.options) do
    --             vim.api.nvim_set_option_value(option, value, { win = window })
    --         end
    --         vim.api.nvim_set_option_value("winfixbuf", true, { win = window })
    --         state.win_float_map[window] = self
    --     end
    -- end
end

function Float:hide()
    vim.api.nvim_win_close(self.window, false)
    state.win_float_map[self.window] = nil
    self.window = nil
end

---@param window integer
---@return boolean, NvimReddit.FloatDraw|nil
function Float:is_visible(window)
    -- this function is not always called in the window that we're checking
    -- visibility for (like scheduled function after decoration handling)
    local current_win = vim.api.nvim_get_current_win()
    local is_folded
    if window == current_win then
        is_folded = vim.fn.foldclosed(self.row + 1) ~= -1
    else
        vim.api.nvim_command("noautocmd call nvim_set_current_win(" .. window .. ")")
        is_folded = vim.fn.foldclosed(self.row + 1) ~= -1
        vim.api.nvim_command("noautocmd call nvim_set_current_win(" .. current_win .. ")")
    end
    if is_folded then
        return false
    end

    local screenpos = vim.fn.screenpos(window, self.row + 1, self.col)
    local float_last_row = screenpos.row + 8
    if screenpos.row ~= 0 then
        -- The mark is on the screen!
        local window_position = vim.api.nvim_win_get_position(window)
        local window_row = window_position[1] + 1
        local window_height = vim.api.nvim_win_get_height(window)
        local window_last_row = window_row + window_height - 1
        if float_last_row <= window_last_row then
            ---@type NvimReddit.FloatDraw|nil
            local draw = nil
            if not self.bufpos then
                self.bufpos = true
                draw = {
                    bufpos = {self.row, self.col},
                    height = 8,
                }
            end
            return true, draw
        else
            local bottom_rows_cut = float_last_row - window_last_row
            if bottom_rows_cut >= 8 then
                return false
            end
            self.bufpos = false
            ---@type NvimReddit.FloatDraw
            local draw = {
                row = screenpos.row - window_position[1],
                col = screenpos.col - window_position[2],
                height = 8 - bottom_rows_cut,
            }
            return true, draw
        end
    end
    local wininfo = vim.fn.getwininfo(window)[1]

    if wininfo.topline - 1 ~= self.row + 1 then
        return false
    end

    local topline_screen_pos = vim.fn.screenpos(window, wininfo.topline, 0)
    local bottom_rows_visible = topline_screen_pos.row - wininfo.winrow
    if bottom_rows_visible == 0 then
        return false
    end

    self.bufpos = false
    ---@type NvimReddit.FloatDraw
    local draw = {
        row = 0,
        col = wininfo.textoff + self.col,
        height = bottom_rows_visible,
    }
    return true, draw
end

return Float
