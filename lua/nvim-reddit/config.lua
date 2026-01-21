---@class NvimReddit.SpacingConfig
---@field score_margin integer
---@field max_line_length integer

---@class NvimReddit.Config
---@field data_dir string
---@field platform_resolver fun(): string
---@field port integer
---@field keymaps NvimReddit.Keymap[]
---@field spacing NvimReddit.SpacingConfig
---@field use_gif_player boolean
---@field player_options string[]
---@field gif_player_options string[]
---@field player_onexit fun(out: vim.SystemCompleted)?
---@field icons boolean
---@field refresh_lualine boolean
---@field set_topline_on_expand boolean
---@field max_image_height_window_percentage integer
local M = {}

---@alias NvimReddit.Keymap { [1]: string, [2]: string, [3]: fun(thing: NvimReddit.Selectable, reddit_buf: NvimReddit.Buffer) }

local VERSION = "v0.0.1"

---@param reddit_api_path string
---@return [string, string, string]|nil, string?
function M.setup_reddit_config(reddit_api_path)
    local client_id = vim.fn.input("Client ID: ")
    local client_secret = vim.fn.input("Secret: ")
    local redirect_uri = vim.fn.input("Redirect URI: ")
    local api_json = vim.json.encode({
        client_id = client_id,
        client_secret = client_secret,
        redirect_uri = redirect_uri
    })
    local util = require("nvim-reddit.util")

    util.ensure_dir(M.data_dir)
    local f, oerr = io.open(reddit_api_path, "w")
    if oerr ~= nil or not f then
        return nil, "Couldn't open API config file for writing: " .. oerr
    end
    local _, werr = f:write(api_json)
    if werr then
        return nil, "Coudln't write API config file: " .. werr
    end
    f:close()
    return { client_id, client_secret, redirect_uri }
end

---@param reddit_api_path string
---@param platform string
---@return NvimReddit.RedditClient|nil, string?
function M.setup_reddit(reddit_api_path, platform)
    local util = require("nvim-reddit.util")
    local file, err, err_code = util.read_file(reddit_api_path)
    local client_id, client_secret, redirect_uri
    if err or not file then
        if err_code ~= "ENOENT" then
            return nil, "Couldn't read API config file: " .. err
        end
        print("Enter your Reddit API application client ID, secret, and redirect URI")
        local reddit_config, serr = M.setup_reddit_config(reddit_api_path)
        if serr then
            return nil, serr
        end ---@cast reddit_config -?
        client_id, client_secret, redirect_uri = unpack(reddit_config)
    else
        local ok, result = pcall(vim.json.decode, file)
        if not ok then
            print("Failed to parse JSON in API config:", result)
            local answer = vim.fn.input("Would you like to re-enter your API config? [Y/n]")
            answer = answer:lower()
            if answer == "" or answer == "y" or answer == "yes" then
                local reddit_config, serr = M.setup_reddit_config(reddit_api_path)
                if err then
                    return nil, serr
                end ---@cast reddit_config -?
                client_id, client_secret, redirect_uri = unpack(reddit_config)
            else
                return
            end
        else
            if type(result) ~= "table" then
                return nil, "API config was not a table!"
            end
            if type(result.client_id) ~= "string" then
                return nil, "API config didn't have client_id!"
            end
            client_id = result.client_id
            if type(result.client_secret) ~= "string" then
                return nil, "API config didn't have client_secret!"
            end
            client_secret = result.client_secret
            if type(result.redirect_uri) ~= "string" then
                return nil, "API config didn't have redirect_uri!"
            end
            redirect_uri = result.redirect_uri
        end
    end
    return require("nvim-reddit.reddit").new({
        client_id = client_id,
        client_secret = client_secret,
        redirect_uri = redirect_uri,
        useragent = platform .. ":nvim-reddit:" .. VERSION .. " (by /u/Levi_OP)"
    })
end

---@return NvimReddit.Config
function M.defaults()
    local actions = require("nvim-reddit.actions")
    ---@type NvimReddit.Config
    local defaults = {
        data_dir = vim.fn.stdpath("data") .. "/nvim-reddit/",
        platform_resolver = function ()
            return vim.uv.os_uname().sysname
        end,
        port = 3001,
        keymaps = {
            {"n", "u", actions.upvote},
            {"n", "d", actions.downvote},
            {"n", "c", actions.open_comments},
            {"n", "x", actions.expand},
            {"n", "gp", actions.permalink},
            {"n", "yp", actions.yank_permalink},
            {"n", "gs", actions.open_subreddit},
            {"n", "gl", function(thing) vim.print(thing) end},
            {"n", "gu", actions.open_user},
            {"n", "]g", actions.gallery_next},
            {"n", "[g", actions.gallery_prev},
            {"n", "gd", actions.open_domain},
            {"n", "gc", actions.open_context},
            {"n", "gC", actions.open_full_context},
            {"n", "<CR>", actions.enter},
        },
        spacing = {
            score_margin = 6,
            max_line_length = 120
        },
        use_gif_player = true,
        player_options = {"mpv", "--keep-open=yes", "--loop=inf", "--af=loudnorm=I=-16:LRA=11:TP=-1.5", "--x11-name=mpv-float"},
        gif_player_options = {"mpv", "--keep-open=yes", "--loop=inf", "--x11-name=mpv-gif-float"},
        player_onexit = function (out)
            -- mpv uses exit code 4 when quit due to a signal (which is how we kill it if closing expando)
            if require("nvim-reddit.config").player_options[1] == "mpv" and out.code == 4 then return end
            if out.code == 0 then return end
            if out.stderr ~= "" then
                vim.print(out.stderr)
            elseif out.stdout ~= "" then
                vim.print(out.stdout)
            else
                vim.print("Player closed with non-zero exit code but no output")
            end
        end,
        icons = true,
        refresh_lualine = false,
        set_topline_on_expand = true,
        max_image_height_window_percentage = 50,
    }
    return defaults
end

---@param options NvimReddit.Config|nil
function M.setup(options)
    local new_config = vim.tbl_deep_extend("force", M.defaults(), options or {})
    for k, v in pairs(new_config) do
        M[k] = v
    end
end

return M
