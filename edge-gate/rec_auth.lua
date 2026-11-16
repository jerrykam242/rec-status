-- rec.example.com sign-in: credentials, the signed session cookie and the
-- failed-attempt lockout. Used by rec_gate.lua, rec_login.lua, rec_logout.lua.
--
-- The recorder keeps its own Basic auth. rec_auth (root 600, "user:pass", written
-- by set-rec-auth.sh from the recorder container's env) is what the sign-in form
-- is checked against, and nginx sends it upstream as Authorization for every
-- request that carries a valid session. The browser never sees a Basic prompt.
local ts = package.loaded.site_turnstile
if not ts then
    ts = dofile("/www/common/turnstile/turnstile.lua")
    package.loaded.site_turnstile = ts
end

local _M = {}

_M.COOKIE = "site_rec"
_M.SHORT_TTL = 12 * 3600        -- default session (browser-session cookie)
_M.LONG_TTL = 30 * 86400        -- "Keep me signed in"
_M.MAX_FAILS = 10               -- wrong passwords per client IP ...
_M.LOCK_SECS = 15 * 60          -- ... within this window, then locked for the rest of it

local COOKIE_ATTRS = "; Path=/; Secure; HttpOnly; SameSite=Lax"

-- "user:pass" from rec_auth, or nil.
local function creds()
    local v = ts.read_value("rec_auth")
    if not v then
        ngx.log(ngx.ERR, "rec-auth: /www/common/turnstile/rec_auth is missing or empty (run set-rec-auth.sh)")
        return nil
    end
    local u, p = v:match("^([^:]+):(.+)$")
    if not u then
        ngx.log(ngx.ERR, "rec-auth: rec_auth is not in user:pass form")
        return nil
    end
    return u, p, v
end

-- Compare fixed-length digests so neither length nor content leaks through timing.
local function same(a, b)
    a, b = ngx.sha1_bin(a), ngx.sha1_bin(b)
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

-- true / false, or nil + "not-configured".
function _M.check(user, pass)
    local u, p = creds()
    if not u then return nil, "not-configured" end
    local ok_user = same(user, u)
    local ok_pass = same(pass, p)
    return ok_user and ok_pass
end

function _M.upstream_authorization()
    local _, _, v = creds()
    return v and ("Basic " .. ngx.encode_base64(v)) or nil
end

-- The MAC covers the credentials, so changing the recorder password (and rerunning
-- set-rec-auth.sh) signs everyone out.
local function mac(host, exp)
    local key = ts.read_value("cookie_key")
    local _, _, v = creds()
    if not key or not v then return nil end
    return ts.b64url(ngx.hmac_sha1(key, "rec-session|" .. host .. "|" .. exp .. "|" .. ngx.md5(v)))
end

function _M.make_cookie(host, remember)
    local ttl = remember and _M.LONG_TTL or _M.SHORT_TTL
    local exp = tostring(ngx.time() + ttl)
    local m = mac(host, exp)
    if not m then return nil end
    local c = _M.COOKIE .. "=" .. exp .. "." .. m .. COOKIE_ATTRS
    if remember then c = c .. "; Max-Age=" .. ttl end
    return c
end

function _M.clear_cookies()
    return {
        _M.COOKIE .. "=; Max-Age=0" .. COOKIE_ATTRS,
        ts.COOKIE_NAME .. "=; Max-Age=0" .. COOKIE_ATTRS,   -- old Turnstile pass cookie
    }
end

function _M.has_cookie()
    return ngx.var["cookie_" .. _M.COOKIE] ~= nil
end

function _M.session_ok(host)
    local v = ngx.var["cookie_" .. _M.COOKIE]
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

-- Same-site relative path to return to after sign-in; never back into /__turnstile.
function _M.safe_return(r)
    if type(r) ~= "string" or #r > 2048 or not r:match("^/[^/\\]") or r:find("[%c]")
       or r:sub(1, 12) == "/__turnstile" then
        return "/"
    end
    return r
end

local function fail_key()
    return "recfail:" .. ts.client_ip()
end

function _M.locked()
    local d = ngx.shared.site_turnstile
    if not d then return false end
    return (d:get(fail_key()) or 0) >= _M.MAX_FAILS
end

function _M.note_failure()
    local d = ngx.shared.site_turnstile
    if not d then return end
    d:incr(fail_key(), 1, 0, _M.LOCK_SECS)
end

function _M.clear_failures()
    local d = ngx.shared.site_turnstile
    if d then d:delete(fail_key()) end
end

_M.ts = ts
return _M
