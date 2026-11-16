-- rec.example.com (BililiveRecorder): every request needs the signed session cookie
-- from the sign-in page (/__turnstile/login). With it, nginx adds the recorder's
-- Basic auth header itself, so the browser never shows a Basic-auth prompt.
if ngx.is_subrequest then return end

-- Never forward a visitor's own Authorization header: the recorder would answer
-- 401 vs 404 and act as a password oracle with no Turnstile and no lockout.
-- The only Authorization the recorder sees is the one added below for a session.
ngx.req.clear_header("Authorization")

-- Served by nginx itself (sign-in page, its assets, ACME), never proxied.
local uri = ngx.var.uri or ""
if uri:sub(1, 13) == "/__turnstile/" or uri:sub(1, 28) == "/.well-known/acme-challenge/" then return end

local auth = package.loaded.site_rec_auth
if not auth then
    auth = dofile("/www/common/turnstile/rec_auth.lua")
    package.loaded.site_rec_auth = auth
end

if auth.session_ok(ngx.var.host) then
    local h = auth.upstream_authorization()
    if h then
        ngx.req.set_header("Authorization", h)
        -- Keep HTML uncompressed so sub_filter can add the Sign out button.
        local accept = ngx.var.http_accept
        if accept and accept:find("text/html", 1, true) then
            ngx.req.clear_header("Accept-Encoding")
        end
        return
    end
end

ngx.header["Cache-Control"] = "no-store"
local m = ngx.req.get_method()
if m == "GET" or m == "HEAD" then
    local target = "/__turnstile/login"
    local q = {}
    local ru = ngx.var.request_uri
    if ru and ru ~= "/" then q[#q + 1] = "r=" .. ngx.escape_uri(ru) end
    if auth.has_cookie() then q[#q + 1] = "x=1" end   -- had a session; it ended
    if #q > 0 then target = target .. "?" .. table.concat(q, "&") end
    return ngx.redirect(target, 302)
end

-- API calls from an open recorder tab after the session ended.
ngx.status = ngx.HTTP_UNAUTHORIZED
ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.say('{"code":401,"message":"Sign in required. Reload the page.","data":null}')
return ngx.exit(ngx.HTTP_UNAUTHORIZED)
