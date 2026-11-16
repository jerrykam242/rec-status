-- live status site: shared helpers (secrets, session cookie, edge check).
-- Lives in /www/sites/<site>/gate/ inside the OpenResty container; see README.
local cjson = require "cjson.safe"
local config = dofile("/www/sites/live/gate/live_config.lua")

local _M = {}

local DIR = config.dir
_M.config = config
_M.COOKIE = "live_sess"

local cache = {}

-- One-line secret file in DIR; nil if missing/empty. Successful reads are cached per worker.
function _M.read_value(name)
    if cache[name] then return cache[name] end
    local f = io.open(DIR .. name, "r")
    if not f then return nil end
    local s = (f:read("*a") or ""):match("^%s*(.-)%s*$")
    f:close()
    if s == "" or s:find("%s") then return nil end
    cache[name] = s
    return s
end

function _M.b64url(s)
    return (ngx.encode_base64(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

function _M.hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function _M.same(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

-- Requests must come through ESA: an ESA rule adds "X-Live-Edge: <edge_key>" to every
-- request it forwards to the origin, so hits on the bare origin IP are refused.
-- Until edge_key exists the check is off (first setup); a warning is logged.
function _M.edge_ok()
    local key = _M.read_value("edge_key")
    if not key then
        ngx.log(ngx.WARN, "live: ", DIR, "edge_key missing, origin is not locked to ESA")
        return true
    end
    return _M.same(ngx.var.http_x_live_edge or "", key)
end

-- Two signed cookies, both HMAC'd with cookie_key and bound to the host and their kind:
--   live_entry  set by /__gate/verify after ESA passed the captcha; valid ENTRY_TTL seconds and
--               single use (its nonce is burnt in the shared dict when "/" is served).
--   live_sess   set when "/" consumes an entry pass: the sign-in. Valid for a fixed SESS_TTL
--               seconds from then (never renewed); "/" and /api/* accept it until it expires.
_M.ENTRY = "live_entry"
_M.SESS = "live_sess"
local ATTRS = "; Path=/; Secure; HttpOnly; SameSite=Lax"

local function mac(kind, host, exp, nonce)
    local key = _M.read_value("cookie_key")
    if not key then
        ngx.log(ngx.ERR, "live: ", DIR, "cookie_key is missing")
        return nil
    end
    return _M.b64url(ngx.hmac_sha1(key, kind .. "|" .. host .. "|" .. exp .. "|" .. nonce))
end

-- kind: _M.ENTRY or _M.SESS. Returns a Set-Cookie value.
function _M.make_token(kind, host)
    local ttl = kind == _M.ENTRY and config.entry_ttl or config.sess_ttl
    local exp = tostring(ngx.time() + ttl)
    local nonce = _M.b64url(ngx.md5_bin(tostring(ngx.now()) .. ngx.var.request_id .. kind))
    local m = mac(kind, host, exp, nonce)
    if not m then return nil end
    -- Max-Age matches the signed expiry, so the cookie also survives a browser restart.
    return kind .. "=" .. exp .. "." .. nonce .. "." .. m .. "; Max-Age=" .. ttl .. ATTRS
end

function _M.clear_token(kind)
    return kind .. "=; Max-Age=0" .. ATTRS
end

-- Returns the nonce when the cookie of this kind is present, unexpired and correctly signed.
function _M.check_token(kind, host)
    local v = ngx.var["cookie_" .. kind]
    if type(v) ~= "string" then return nil end
    local exp, nonce, got = v:match("^(%d+)%.([%w_-]+)%.([%w_-]+)$")
    if not exp or tonumber(exp) <= ngx.time() then return nil end
    if not _M.same(mac(kind, host, exp, nonce) or "", got) then return nil end
    return nonce
end

-- Burns a nonce; true only the first time (shared dict entry outlives the token).
function _M.consume(nonce)
    local dict = ngx.shared.live_status
    if not dict then return false end
    local ok = dict:add("used:" .. nonce, true, config.entry_ttl + 60)
    return ok and true or false
end

-- Only same-site relative paths may be used as the post-sign-in destination.
function _M.safe_next(r)
    if type(r) ~= "string" or #r > 512 then return "/" end
    if r:sub(1, 1) ~= "/" or r:sub(2, 2) == "/" or r:sub(2, 2) == "\\" then return "/" end
    if r:find("[%c\\]") or r:sub(1, 8) == "/__gate/" then return "/" end
    return r
end

function _M.json(status, tbl, extra_headers)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    if extra_headers then
        for k, v in pairs(extra_headers) do ngx.header[k] = v end
    end
    ngx.say(cjson.encode(tbl))
    return ngx.exit(status)
end

function _M.html_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

return _M
