local config = require("nvim-reddit.config")

local curl = require("plenary.curl")
local uv = vim.uv

---@class NvimReddit.RedditClient
---@field redirect_uri string
---@field client_id string
---@field client_secret string
---@field useragent string
---@field token_file string
---@field token? string
local Reddit = {}
Reddit.__index = Reddit

function Reddit.new(opts)
    local self = setmetatable({}, Reddit)

    self.redirect_uri = opts.redirect_uri
    self.client_id = opts.client_id
    self.client_secret = opts.client_secret
    self.token_file = opts.token_file or (vim.fn.stdpath("data") .. "/reddit_refresh_token")
    self.useragent = opts.useragent
    self.token = nil
    return self
end

function Reddit:wait_for_code(state, port, cb)
    local server = uv.new_tcp()
    if not server then
        print("failed to create server!")
        return
    end
    server:bind("127.0.0.1", port)
    server:listen(1, function()
        local client = uv.new_tcp()
        if not client then
            print("failed to create client!")
            return
        end
        server:accept(client)
        client:read_start(function(err, chunk)
            if err then
                print("there was an error!")
                vim.print(err)
                return
            end
            if chunk then
                local params = {}
                for k, v in chunk:gmatch("[?&]([^&#%s=]+)=([^&#%s]*)") do
                    params[k] = v
                end

                if params.state ~= state then
                    print("state mismatch! (do we really care?)")
                    return
                end

                if params.error then
                    print("OAuth error: " .. params.error)
                    return
                end

                if params.code == nil then
                    print("there was not a code!?")
                    return
                end

                client:write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nYou can close this window.\n")
                client:shutdown()
                client:close()
                server:close()
                cb(params.code)
            end
        end)
    end)
end

function Reddit:retrieve_access_token(code, cb)
    curl.post("https://www.reddit.com/api/v1/access_token", {
        body = {
            grant_type = "authorization_code",
            code = code,
            redirect_uri = self.redirect_uri
        },
        auth = self.client_id .. ":" .. self.client_secret,
        headers = { ["User-Agent"] = self.useragent },
        callback = function (res)
            local json = vim.json.decode(res.body)
            if json.refresh_token then
                vim.schedule(function()
                    vim.fn.writefile({ json.refresh_token }, self.token_file)
                end)
            end
            cb(json.access_token)
        end
    })

end

function Reddit:get_access_token(cb)
    if vim.fn.filereadable(self.token_file) == 1 then
        local refresh = vim.fn.readfile(self.token_file)[1]
        local res = curl.post("https://www.reddit.com/api/v1/access_token", {
            body = {
                grant_type = "refresh_token",
                refresh_token = refresh
            },
            auth = self.client_id .. ":" .. self.client_secret,
            headers = { ["User-Agent"] = self.useragent }
        })
        -- FIXME: there are probably errors to handle here?
        local json = vim.json.decode(res.body)
        self.token = json.access_token
        cb()
    else
        local state = tostring(math.random(1, 1e9))
        local url = string.format(
            "https://www.reddit.com/api/v1/authorize?client_id=%s&response_type=code&state=%s&redirect_uri=%s&duration=permanent&scope=read,identity,vote,history",
            self.client_id, state, self.redirect_uri
        )

        vim.ui.open(url)

        self:wait_for_code(state, config.port, function(code)
            self:retrieve_access_token(code, function(token)
                self.token = token
                cb()
            end)
        end)
    end
end

---@class (exact) NvimReddit.FetchResponse
---@field data any
---@field rawdata string
---@field location string

---@class (exact) NvimReddit.RedditError
---@field message string
---@field status integer
---@field reason string?

---@param path string
---@param cb fun(result: NvimReddit.FetchResponse|nil, err: NvimReddit.RedditError|nil)
function Reddit:fetch(path, cb)
    local location = "https://oauth.reddit.com/" .. path
    curl.get(location, {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        ---@param res { body: string, headers: string[], status: integer }
        callback = function(res)
            local ok, result = pcall(vim.json.decode, res.body)
            if not ok then
                if res.status ~= 200 then
                    cb(nil, {
                        message = "",
                        status = res.status
                    })
                    return
                end
                cb(nil, {
                    message = res.body,
                    status = res.status
                })
                return
            end

            -- vim.schedule(function()
            --     vim.fn.writefile({res.body}, "/home/levi/.local/share/nvim/reddit_sample.json")
            -- end)

            if res.status == 302 then
                for _, line in ipairs(res.headers) do
                    ---@type string|nil
                    local value = line:match("^location:%s*(.+)$")
                    if value then
                        location = value
                    end
                end
            elseif res.status ~= 200 then
                cb(nil, {
                    message = result.message,
                    reason = result.reason,
                    status = res.status
                })
            end

            ---@type NvimReddit.FetchResponse
            local response = {
                data = result,
                location = location,
                rawdata = res.body
            }
            cb(response, nil)
        end
    })
end

---@param fullname string
---@param dir 1|0|-1
---@param cb fun(err: string|nil)
function Reddit:vote(fullname, dir, cb)
    curl.post("https://oauth.reddit.com/api/vote", {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        body = {
            id = fullname,
            dir = dir
        },
        callback = function(res)
            if res.status ~= 200 then
                cb("HTTP " .. res.status)
                return
            end
            cb(nil)
        end
    })
end

return Reddit
