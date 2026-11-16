-- file.example.com (OpenList): Turnstile on password logins and on SSO sign-in.
-- Runs at server level in the rewrite phase, so the 1Panel WAF (access phase)
-- still runs as before.
--
-- Password logins: /api/auth/login* needs a valid X-Turnstile-Token header.
--
-- SSO (Microsoft) sign-in never calls /api/auth/login: the popup goes
--   /api/auth/sso?method=sso_get_token  ->  Microsoft  ->
--   /api/auth/sso_callback?method=sso_get_token  (OpenList hands out its token here)
-- (/api/auth/get_sso_id and /api/auth/sso_get_token are the same callback handler.)
-- So:
--   start     needs ?ts=<Turnstile token> (openlist.js adds it) and must be opened
--             from a file.example.com page; it then gets a signed one-time cookie.
--   callback  needs that cookie; its nonce is burnt on first use.
-- method=get_sso_id (linking a Microsoft account from the profile page, which
-- returns only the Microsoft id, never an OpenList token) is let through.
if ngx.is_subrequest then return end

-- Turnstile check service for rec-status.example.com (signed; its own location in sites/file.conf).
if ngx.var.uri == "/__turnstile/rs-verify" then return end

-- Share links (/@s/...) need their own Turnstile check (share_gate.lua).
local share_gate = package.loaded.site_share_gate
if not share_gate then
    share_gate = dofile("/www/common/turnstile/share_gate.lua")
    package.loaded.site_share_gate = share_gate
end
if share_gate.run() then return end

local uri = string.lower(ngx.var.uri or "")
local is_login = uri:sub(1, 15) == "/api/auth/login"
local is_sso = uri:sub(1, 13) == "/api/auth/sso" or uri:sub(1, 20) == "/api/auth/get_sso_id"
if not is_login and not is_sso then return end
if is_login and ngx.req.get_method() == "OPTIONS" then return end

local ts = package.loaded.site_turnstile
if not ts then
    ts = dofile("/www/common/turnstile/turnstile.lua")
    package.loaded.site_turnstile = ts
end

if is_login then
    local ok, why = ts.verify(ngx.var.http_x_turnstile_token, "openlist-login")
    if ok then return end

    ngx.log(ngx.ERR, "turnstile: blocked OpenList login (", why, ") from ", ts.client_ip())
    if why == "missing-token" then
        return ts.json_403("请先完成人机验证 / Please complete the security check first.")
    end
    return ts.json_403("人机验证失败，请重试 / Security check failed, please try again.")
end

---------------------------------------------------------------------------
-- SSO
---------------------------------------------------------------------------
local COOKIE = "site_sso"
local TTL = 600                 -- time allowed for the Microsoft round trip
local COOKIE_ATTRS = "; Path=/api/auth/; Secure; HttpOnly; SameSite=Lax"

-- Linking flow only: no "sso_get_token" anywhere in the path or the (decoded)
-- query, and asks for get_sso_id. OpenList only issues a token for
-- method=sso_get_token, so such a request cannot sign anyone in.
local args_raw = string.lower(ngx.var.args or "")
local args_dec = string.lower(ngx.unescape_uri(args_raw))
if not uri:find("sso_get_token", 1, true)
    and not args_raw:find("sso_get_token", 1, true)
    and not args_dec:find("sso_get_token", 1, true)
    and args_dec:find("get_sso_id", 1, true) then
    return
end

local function html_403(why)
    ngx.log(ngx.ERR, "turnstile: blocked OpenList SSO ", uri, " (", why, ") from ", ts.client_ip())
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["Set-Cookie"] = COOKIE .. "=" .. COOKIE_ATTRS .. "; Max-Age=0"
    ngx.say([[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>需要人机验证 / Security check required</title>
<style>body{font:16px/1.6 system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f4f4f4;color:#161616}
main{max-width:30rem;margin:16px;padding:24px;background:#fff;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.12)}
h1{font-size:20px;margin:0 0 12px}p{margin:0 0 12px}a,button{font:inherit;color:#0f62fe;background:none;border:0;padding:0;cursor:pointer;text-decoration:underline}</style>
</head><body><main><h1>需要人机验证 / Security check required</h1>
<p>请回到登录页，先完成人机验证，再点击 Microsoft 登录。</p>
<p>Go back to the sign-in page, complete the security check, then use Microsoft sign-in again.</p>
<p><button type="button" onclick="window.opener?window.close():location.href='/@login'">关闭 / Close</button></p>
</main></body></html>]])
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local function key()
    return ts.read_value("cookie_key")
end

local function sign(host, exp, nonce)
    local k = key()
    if not k then return nil end
    return ts.b64url(ngx.hmac_sha1(k, "openlist-sso|" .. host .. "|" .. exp .. "|" .. nonce))
end

local host = ngx.var.host

if uri == "/api/auth/sso" or uri == "/api/auth/sso/" then
    -- Only a file.example.com page may start it (stops other sites opening the
    -- popup with a token they solved themselves). Browsers without
    -- Sec-Fetch-Site still need the Turnstile token.
    local site = ngx.var.http_sec_fetch_site
    if site and site ~= "same-origin" then
        return html_403("cross-site-start:" .. tostring(site))
    end

    local args = ngx.req.get_uri_args(50)
    local token = args.ts
    if type(token) == "table" then return html_403("duplicate-token") end
    local ok, why = ts.verify(token, "openlist-login")
    if not ok then return html_403(why) end

    -- Keep the Turnstile token out of OpenList and its logs.
    args.ts = nil
    ngx.req.set_uri_args(args)

    local nonce = require("resty.string").to_hex(require("resty.random").bytes(16, true) or ngx.md5(ngx.now() .. ngx.worker.pid()))
    local exp = tostring(ngx.time() + TTL)
    local mac = sign(host, exp, nonce)
    if not mac then return html_403("not-configured") end
    ngx.header["Set-Cookie"] = COOKIE .. "=" .. exp .. "." .. nonce .. "." .. mac
        .. COOKIE_ATTRS .. "; Max-Age=" .. TTL
    return
end

-- Callback (sso_callback, get_sso_id, sso_get_token, anything else under them).
local v = ngx.var["cookie_" .. COOKIE]
if type(v) ~= "string" or v == "" then return html_403("no-sso-cookie") end
local exp, nonce, got = v:match("^(%d+)%.(%x+)%.([%w_-]+)$")
if not exp then return html_403("bad-sso-cookie") end
if tonumber(exp) <= ngx.time() then return html_403("expired-sso-cookie") end
local want = sign(host, exp, nonce)
if not want or #want ~= #got then return html_403("bad-sso-mac") end
local diff = 0
for i = 1, #want do
    if want:byte(i) ~= got:byte(i) then diff = diff + 1 end
end
if diff ~= 0 then return html_403("bad-sso-mac") end

local used = ngx.shared.site_turnstile
if not used then return html_403("no-shared-dict") end
local added, err = used:add("sso:" .. nonce, true, TTL + 60)
if not added then
    return html_403(err == "exists" and "replayed-sso-cookie" or ("shared-dict:" .. tostring(err)))
end

-- One callback per Turnstile check.
ngx.header["Set-Cookie"] = COOKIE .. "=" .. COOKIE_ATTRS .. "; Max-Age=0"
