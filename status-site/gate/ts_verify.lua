-- POST /__gate/check: Cloudflare Turnstile sign-in (since 2026-11-16; replaced the ESA captcha
-- on /__gate/verify, which needed a click). The Turnstile secret lives on the recorder host, so the
-- token is checked there: POST https://file.example.com/__turnstile/rs-verify, signed with
-- ingest_key (HMAC-SHA1 over "rs-verify|ts|body"), via the internal location /__ts_check.
-- On success: the one-time entry pass, exactly like verify.lua.
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local cjson = require "cjson.safe"

if ngx.req.get_method() ~= "POST" then return L.json(405, { ok = false, error = "method" }) end
local origin = ngx.var.http_origin
if origin and origin ~= "https://" .. ngx.var.host then return L.json(403, { ok = false, error = "origin" }) end
local site = ngx.var.http_sec_fetch_site
if site and site ~= "same-origin" then return L.json(403, { ok = false, error = "origin" }) end

ngx.req.read_body()
local v = cjson.decode(ngx.req.get_body_data() or "")
local token = type(v) == "table" and v.token
if type(token) ~= "string" or #token < 16 or #token > 2048 then
    return L.json(400, { ok = false, error = "captcha-missing" })
end

local key = L.read_value("ingest_key")
if not key then return L.json(500, { ok = false, error = "not-configured" }) end
local body = ngx.encode_args({ token = token })
local ts = tostring(ngx.time())
local sig = L.hex(ngx.hmac_sha1(key, "rs-verify|" .. ts .. "|" .. body))
local res = ngx.location.capture("/__ts_check", { method = ngx.HTTP_POST, body = body, args = { ts = ts, sig = sig } })
local d = res and res.status == 200 and cjson.decode(res.body)
if type(d) ~= "table" or d.ok ~= true then
    ngx.log(ngx.ERR, "live: turnstile sign-in refused (", res and res.status or "nil", " ",
        type(d) == "table" and tostring(d.error) or "no answer", ")")
    return L.json(403, { ok = false, error = "captcha-failed" })
end
ngx.log(ngx.ERR, "live: sign-in accepted (turnstile)")

local cookie = L.make_token(L.ENTRY, ngx.var.host)
if not cookie then return L.json(500, { ok = false, error = "not-configured" }) end
return L.json(200, { ok = true, next = "/" }, { ["Set-Cookie"] = cookie })
