-- POST /__gate/verify: the ESA AI captcha rule ("需验签的接口") covers this URI. An entry pass is set
-- only for same-origin requests that came through ESA and carry the captcha parameter; ESA has
-- already rejected invalid tokens by then (see captcha_trust_esa in live_config.lua).
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local cjson = require "cjson.safe"

if ngx.req.get_method() ~= "POST" then
    return L.json(405, { ok = false, error = "method" })
end

-- Same-origin fetch only.
local origin = ngx.var.http_origin
if origin and origin ~= "https://" .. ngx.var.host then
    return L.json(403, { ok = false, error = "origin" })
end
local site = ngx.var.http_sec_fetch_site
if site and site ~= "same-origin" then
    return L.json(403, { ok = false, error = "origin" })
end

local param = ngx.var.http_captcha_verify_param
if not param or #param < 16 then
    return L.json(400, { ok = false, error = "captcha-missing" })
end

-- ESA checks the token on this URI before forwarding: with "拦截空 Token" on, requests with a
-- missing or invalid token get ESA's own 403 (X-Captcha-Verify-Code F003 etc.) and never reach
-- us (verified 2026-11-13). Without that switch ESA checked nothing at all, so captcha_trust_esa
-- must only be true while it is on. Direct hits on the origin are refused by gate.lua (edge header).
local C = L.config
local code = ngx.req.get_headers()[C.captcha_pass_header]
if type(code) == "table" then code = code[1] end
if code and not C.captcha_pass_values[code] then
    return L.json(403, { ok = false, error = "captcha-" .. code }, { ["X-Captcha-Verify-Code"] = code })
end
if not code and not C.captcha_trust_esa then
    ngx.log(ngx.ERR, "live: no ESA verdict and captcha_trust_esa is off; refusing sign-in")
    return L.json(503, { ok = false, error = "captcha-unconfirmed" })
end
ngx.log(ngx.ERR, "live: sign-in accepted (ESA verdict header: ", tostring(code), ")")

-- One-time entry pass for the status page ("/"); gate.lua swaps it for a session.
local cookie = L.make_token(L.ENTRY, ngx.var.host)
if not cookie then
    return L.json(500, { ok = false, error = "not-configured" })
end
return L.json(200, { ok = true, next = "/" }, { ["Set-Cookie"] = cookie })
