local config = require("nvim-reddit.config")

local curl = require("plenary.curl")
local uv = vim.uv

local API_BASE = "https://oauth.reddit.com/"

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

function Reddit:wait_for_code(state, port)
    local co = coroutine.running()

    local code

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
                code = params.code

                vim.schedule(function()
                    coroutine.resume(co)
                end)
            end
        end)
    end)

    coroutine.yield()

    return code
end

function Reddit:retrieve_access_token(code)
    local co = coroutine.running()

    local access_token
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
            access_token = json.access_token
            vim.schedule(function()
                coroutine.resume(co)
            end)
        end
    })

    coroutine.yield()

    return access_token
end

function Reddit:get_access_token()
    local co = coroutine.running()

    if vim.fn.filereadable(self.token_file) == 1 then
        local refresh = vim.fn.readfile(self.token_file)[1]
        curl.post("https://www.reddit.com/api/v1/access_token", {
            body = {
                grant_type = "refresh_token",
                refresh_token = refresh
            },
            auth = self.client_id .. ":" .. self.client_secret,
            headers = { ["User-Agent"] = self.useragent },
            ---@param res { body: string, headers: string[], status: integer }
            callback = function(res)
                -- FIXME: there are probably errors to handle here?
                local json = vim.json.decode(res.body)
                self.token = json.access_token
                vim.schedule(function()
                    coroutine.resume(co)
                end)
            end
        })
    else
        local state = tostring(math.random(1, 1e9))
        local url = string.format(
            "https://www.reddit.com/api/v1/authorize?client_id=%s&response_type=code&state=%s&redirect_uri=%s&duration=permanent&scope=read,identity,vote,history,submit",
            self.client_id, state, self.redirect_uri
        )

        vim.ui.open(url)

        local code = self:wait_for_code(state, config.port)
        local token = self:retrieve_access_token(code)
        self.token = token

        vim.schedule(function()
            coroutine.resume(co)
        end)
    end

    coroutine.yield()
end

---@param res { body: string, headers: string[], status: integer }
---@return any, NvimReddit.RedditHttpError|nil
local function handle_http_error(res)
    local ok, result = pcall(vim.json.decode, res.body)
    if not ok then
        if res.status ~= 200 then
            return {
                message = "",
                status = res.status
            }
        else
            return {
                message = res.body,
                status = res.status
            }
        end
    end

    return result
end

---@class (exact) NvimReddit.FetchResponse
---@field data any
---@field rawdata string
---@field location string

---@class (exact) NvimReddit.RedditHttpError
---@field message string
---@field status integer
---@field reason string?

---@param path string
---@return NvimReddit.FetchResponse|nil, NvimReddit.RedditHttpError|nil
function Reddit:fetch(path)
    local co = coroutine.running()

    local location = API_BASE .. path
    ---@type NvimReddit.FetchResponse|nil
    local response
    ---@type NvimReddit.RedditHttpError|nil
    local err
    curl.get(location, {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        ---@param res { body: string, headers: string[], status: integer }
        callback = function(res)
            local result, http_error = handle_http_error(res)
            if err then
                err = http_error
                vim.schedule(function()
                    coroutine.resume(co)
                end)
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
                err = {
                    message = result.message,
                    reason = result.reason,
                    status = res.status
                }

                vim.schedule(function()
                    coroutine.resume(co)
                end)
                return
            end

            response = {
                data = result,
                location = location,
                rawdata = res.body
            }

            vim.schedule(function()
                coroutine.resume(co)
            end)
        end
    })

    coroutine.yield()

    return response, err
end

---@param fullname string
---@param dir 1|0|-1
---@param cb fun(err: NvimReddit.RedditHttpError|nil)
function Reddit:vote(fullname, dir, cb)
    curl.post(API_BASE .. "api/vote", {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        body = {
            id = fullname,
            dir = dir
        },
        ---@param res { body: string, headers: string[], status: integer }
        callback = function(res)
            local result, err = handle_http_error(res)
            if err then
                cb(err)
                return
            end
            if res.status ~= 200 then
                cb({
                    message = result.message,
                    reason = result.reason,
                    status = res.status
                })
                return
            end

            cb(nil)
        end
    })
end

-- ---@param object any
-- ---@return NvimReddit.RedditError[]|nil, any
-- local function handle_json_response(object)
--     local errors_raw = object.json.errors
--     if #errors_raw > 0 then
--         ---@type NvimReddit.RedditError[]
--         local errors = {}
--         for i, error in ipairs(errors_raw) do
--             errors[i] = {
--                 code = error[1],
--                 message = error[2],
--                 field = error[3],
--             }
--         end
--         return errors
--     end
--
--     local data = object.json.data
--     return nil, data
-- end

---@param children string[]
---@param link_id string
---@param cb fun(result: any, err: NvimReddit.RedditHttpError|nil)
function Reddit:morechildren(children, link_id, cb)
    curl.get(API_BASE .. "api/morechildren?api_type=json&children=" .. table.concat(children, ",") .. "&link_id=" .. link_id .. "&raw_json=1", {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        ---@param res { body: string, headers: string[], status: integer }
        callback = function(res)
            local result, err = handle_http_error(res)
            if err then
                cb(nil, err)
                return
            end
            cb(result)
        end
    })
end

---@param fullname string
---@param text string
---@param cb fun(result: any, err: NvimReddit.RedditHttpError|nil)
function Reddit:comment(fullname, text, cb)
    curl.post(API_BASE .. "api/comment?raw_json=1", {
        headers = {
            Authorization = "bearer " .. self.token,
            ["User-Agent"] = self.useragent
        },
        body = {
            api_type = "json",
            text = text,
            thing_id = fullname,
        },
        ---@param res { body: string, headers: string[], status: integer }
        callback = function(res)
            local result, err = handle_http_error(res)
            if err then
                cb(nil, err)
                return
            end
            cb(result)
        end
    })
end


return Reddit
