-- GET /__gate/login: the sign-in page (IBM Carbon), with the ESA AI captcha.
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local C = L.config

if ngx.req.get_method() ~= "GET" and ngx.req.get_method() ~= "HEAD" then
    return ngx.exit(405)
end
-- Visitors still inside their 10-minute window go straight to the status page.
if L.check_token(L.SESS, ngx.var.host) then
    ngx.header["Cache-Control"] = "no-store"
    return ngx.redirect("/", 302)
end
local next_path = "/"

local f = io.open(C.dir .. "login.html", "r")
if not f then return ngx.exit(500) end
local tpl = f:read("*a")
f:close()

local vars = {
    V = C.asset_v,
    R = L.html_escape(next_path),
    PREFIX = L.html_escape(C.captcha_prefix),
    SCENE = L.html_escape(C.captcha_scene),
    REGION = L.html_escape(C.captcha_region),
}
local html = tpl:gsub("{{(%u+)}}", function(k) return vars[k] or "" end)

ngx.header["Content-Type"] = "text/html; charset=utf-8"
ngx.header["Cache-Control"] = "no-store"
ngx.header["X-Frame-Options"] = "DENY"
ngx.header["Referrer-Policy"] = "same-origin"
ngx.header["X-Content-Type-Options"] = "nosniff"
ngx.print(html)
