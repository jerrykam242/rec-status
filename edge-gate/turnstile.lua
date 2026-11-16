-- Cloudflare Turnstile helpers shared by file.example.com and rec.example.com.
-- Loaded once per nginx worker (see *_gate.lua). Reload nginx after changing
-- the secret or cookie_key files.
local cjson = require "cjson.safe"

local _M = {}

local DIR = "/www/common/turnstile/"
local VERIFY_LOC = "/__turnstile_siteverify"
local ALLOWED_HOSTS = { ["file.example.com"] = true, ["rec.example.com"] = true }

_M.COOKIE_NAME = "site_ts"
_M.COOKIE_TTL = 12 * 3600

local cache = {}

-- Read a one-line secret file; nil if missing/empty/contains whitespace.
-- Only successful reads are cached, so a file created later is picked up.
local function read_value(name)
    if cache[name] then return cache[name] end
    local f = io.open(DIR .. name, "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    s = s:match("^%s*(.-)%s*$")
    if s == "" or s:find("%s") then return nil end
    cache[name] = s
    return s
end

function _M.client_ip()
    -- Sites sit behind the Cloudflare proxy; remoteip is only an optional hint.
    return ngx.var.http_cf_connecting_ip or ngx.var.remote_addr
end

-- Server-side Siteverify. Returns true, or false + reason.
function _M.verify(token, expected_action)
    if type(token) ~= "string" or #token == 0 or #token > 2048 then
        return false, "missing-token"
    end
    local host = ngx.var.host
    if not ALLOWED_HOSTS[host] then
        return false, "host-not-allowed"
    end
    local secret = read_value("secret")
    if not secret then
        ngx.log(ngx.ERR, "turnstile: ", DIR, "secret is missing or empty")
        return false, "not-configured"
    end

    local res = ngx.location.capture(VERIFY_LOC, {
        method = ngx.HTTP_POST,
        body = ngx.encode_args({
            secret = secret,
            response = token,
            remoteip = _M.client_ip(),
        }),
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "turnstile: siteverify HTTP ", res and res.status or "nil")
        return false, "siteverify-unavailable"
    end

    local data = cjson.decode(res.body)
    if type(data) ~= "table" then
        return false, "siteverify-bad-json"
    end
    if data.success ~= true then
        local codes = data["error-codes"]
        local list = {}
        if type(codes) == "table" then
            for _, c in ipairs(codes) do list[#list + 1] = tostring(c) end
        end
        return false, "rejected:" .. table.concat(list, ",")
    end
    if data.action ~= expected_action then
        return false, "action-mismatch:" .. tostring(data.action)
    end
    if data.hostname ~= host or not ALLOWED_HOSTS[data.hostname] then
        return false, "hostname-mismatch:" .. tostring(data.hostname)
    end
    -- Siteverify accepted the same token twice in quick succession during
    -- testing, so enforce single use here too (tokens live 300 s).
    local used = ngx.shared.site_turnstile
    if used then
        local ok, err = used:add(ngx.md5(token), true, 330)
        if not ok and err == "exists" then
            return false, "replayed-token"
        end
    else
        ngx.log(ngx.ERR, "turnstile: lua_shared_dict site_turnstile missing, replay check skipped")
    end
    return true
end

local function b64url(s)
    return (ngx.encode_base64(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function mac(host, exp)
    local key = read_value("cookie_key")
    if not key then
        ngx.log(ngx.ERR, "turnstile: ", DIR, "cookie_key is missing or empty")
        return nil
    end
    return b64url(ngx.hmac_sha1(key, host .. "|" .. exp))
end

-- Signed "passed Turnstile" cookie value for this host.
function _M.make_cookie(host)
    local exp = tostring(ngx.time() + _M.COOKIE_TTL)
    local m = mac(host, exp)
    if not m then return nil end
    return _M.COOKIE_NAME .. "=" .. exp .. "." .. m
        .. "; Path=/; Max-Age=" .. _M.COOKIE_TTL
        .. "; Secure; HttpOnly; SameSite=Lax"
end

function _M.cookie_ok(host)
    local v = ngx.var["cookie_" .. _M.COOKIE_NAME]
    if type(v) ~= "string" then return false end
    local exp, got = v:match("^(%d+)%.([%w_-]+)$")
    if not exp or tonumber(exp) <= ngx.time() then return false end
    local want = mac(host, exp)
    if not want or #want ~= #got then return false end
    local diff = 0
    for i = 1, #want do
        if want:byte(i) ~= got:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

function _M.json_403(message)
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.say(cjson.encode({ code = 403, message = message, data = cjson.null }))
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

_M.read_value = read_value
_M.b64url = b64url

return _M
