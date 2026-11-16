-- live status site: runs in the rewrite phase for every request (see proxy/live.conf).
-- 1) Only requests forwarded by ESA are served (edge header).
-- 2) Signing in: /__gate/verify sets a one-time entry pass after ESA has checked the AI captcha;
--    "/" burns it and sets the session, valid a fixed sess_ttl (10 min) from then.
-- 3) Within that window "/" (reloads, new tabs) and the page's polling (/api/*) need no captcha;
--    nothing extends it. Afterwards everything goes back to the sign-in page.
-- Sign-in page, its assets, the privacy policy and terms, the agent's signed endpoints and the signed
-- review links are open.
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")

if ngx.is_subrequest then return end   -- internal subrequests (e.g. /__ts_check)

if not L.edge_ok() then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.say("Forbidden")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local uri = ngx.var.uri or "/"
if uri:sub(1, 8) == "/__gate/" or uri:sub(1, 8) == "/assets/"
    or uri == "/__ingest" or uri == "/__agent/sync" or uri == "/__admin/review"
    or uri == "/favicon.ico" or uri == "/robots.txt" or uri == "/privacy" or uri == "/terms" then
    -- /__agent/sync is HMAC-signed by the worker; /__admin/review links are HMAC-signed for the admin.
    return
end

local host = ngx.var.host

local function to_login()
    ngx.header["Cache-Control"] = "no-store"
    return ngx.redirect("/__gate/login", 302)
end

if uri == "/" then
    if ngx.req.get_method() ~= "GET" and ngx.req.get_method() ~= "HEAD" then
        return ngx.exit(405)
    end
    local nonce = L.check_token(L.ENTRY, host)
    if not nonce or not L.consume(nonce) then
        -- No fresh pass: still signed in within the 10-minute window?
        if L.check_token(L.SESS, host) then return end
        return to_login()
    end
    local sess = L.make_token(L.SESS, host)
    if not sess then return ngx.exit(500) end
    ngx.header["Set-Cookie"] = { L.clear_token(L.ENTRY), sess }
    return
end

-- The visitor's waiting page: authorised by the request's own ticket (request_status.lua), so it
-- keeps working if the 10-minute sign-in ends while they wait.
if uri == "/api/request/status" then return end

if uri:sub(1, 5) == "/api/" then
    if not L.check_token(L.SESS, host) then
        return L.json(401, { ok = false, error = "sign-in-required", login = "/__gate/login" })
    end
    -- Fixed window: polling does not renew the session.
    return
end

-- Anything else (only 404s exist beyond this point).
if ngx.req.get_method() ~= "GET" then
    return L.json(401, { ok = false, error = "sign-in-required", login = "/__gate/login" })
end
return to_login()
