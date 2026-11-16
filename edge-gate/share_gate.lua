-- file.example.com: Turnstile in front of OpenList share links (2026-11-16).
-- Share pages (/@s/<id>...), their API calls (POST /api/fs/* whose path starts with /@s) and
-- share downloads (/sd/...) need the site_share cookie, set after a Turnstile check on our own
-- page. Without it: /@s/ pages get that page; /sd/ redirects to it; API calls get a JSON 403.
-- The cookie is signed with cookie_key, lasts PASS_TTL and works for every share.
-- Called from file_gate.lua; run() returns true when this request was a share request it let
-- through (file_gate.lua then has nothing more to do), false when the request is not a share one.
local cjson = require "cjson.safe"
local _M = {}

local ts = package.loaded.site_turnstile
if not ts then
    ts = dofile("/www/common/turnstile/turnstile.lua")
    package.loaded.site_turnstile = ts
end

local COOKIE = "site_share"
local PASS_TTL = 2 * 3600
local ATTRS = "; Path=/; Secure; HttpOnly; SameSite=Lax"
local ACTION = "openlist-share"
local SITEKEY = "YOUR_TURNSTILE_SITEKEY"
local ASSET_V = "1"
local TEMPLATE = "/www/common/turnstile/templates/share_gate.html"

local function sign(host, exp, nonce)
    local k = ts.read_value("cookie_key")
    if not k then return nil end
    return ts.b64url(ngx.hmac_sha1(k, "openlist-share|" .. host .. "|" .. exp .. "|" .. nonce))
end

local function pass_ok(host)
    local v = ngx.var["cookie_" .. COOKIE]
    if type(v) ~= "string" then return false end
    local exp, nonce, got = v:match("^(%d+)%.([%w_-]+)%.([%w_-]+)$")
    if not exp or tonumber(exp) <= ngx.time() then return false end
    local want = sign(host, exp, nonce)
    if not want or #want ~= #got then return false end
    local diff = 0
    for i = 1, #want do
        if want:byte(i) ~= got:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function make_pass(host)
    local exp = tostring(ngx.time() + PASS_TTL)
    local nonce = ts.b64url(ngx.md5_bin(ngx.now() .. ngx.var.request_id .. math.random()))
    local mac = sign(host, exp, nonce)
    if not mac then return nil end
    return COOKIE .. "=" .. exp .. "." .. nonce .. "." .. mac .. "; Max-Age=" .. PASS_TTL .. ATTRS
end

-- Only share pages may be the destination after the check.
local function safe_return(r)
    if type(r) ~= "string" or #r > 1024 then return "/" end
    if not (r:sub(1, 4) == "/@s/" or r:sub(1, 6):lower() == "/%40s/") then return "/" end
    if r:find("[%c\\]") or r:find("//", 1, true) then return "/" end
    return r
end

local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local tpl_cache
local function page(status, r, err)
    if not tpl_cache then
        local f = io.open(TEMPLATE, "r")
        if not f then return ngx.exit(500) end
        tpl_cache = f:read("*a")
        f:close()
    end
    local vars = {
        V = ASSET_V, SITEKEY = SITEKEY, R = esc(r),
        ERROR = err and ('<div class="cds--inline-notification cds--inline-notification--error cds--inline-notification--low-contrast rec-share-error" role="alert"><div class="cds--inline-notification__details"><div class="cds--inline-notification__text-wrapper"><div class="cds--inline-notification__title">' .. esc(err) .. '</div></div></div></div>') or "",
    }
    local html = tpl_cache:gsub("{{(%u+)}}", function(k) return vars[k] or "" end)
    ngx.status = status
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Frame-Options"] = "DENY"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.header["Referrer-Policy"] = "same-origin"
    ngx.header["X-Robots-Tag"] = "noindex"
    ngx.header["Content-Security-Policy"] = "default-src 'self'; "
        .. "script-src 'self' https://challenges.cloudflare.com; "
        .. "frame-src https://challenges.cloudflare.com; "
        .. "connect-src 'self' https://challenges.cloudflare.com; "
        .. "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; "
        .. "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    ngx.print(html)
    return ngx.exit(status)
end

local function api_block()
    ngx.log(ngx.ERR, "turnstile: share API without pass from ", ts.client_ip())
    ngx.status = 200   -- OpenList's own convention: HTTP 200, error in "code"; its UI shows the message
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.say(cjson.encode({ code = 403, message = "请先完成人机验证：请刷新页面。 / Please reload the page and complete the security check.", data = cjson.null }))
    return ngx.exit(200)
end

-- Does a JSON API body/query refer to a share path?
local function is_share_path(s)
    if type(s) ~= "string" then return false end
    s = s:lower()
    return s:sub(1, 3) == "/@s" or s:sub(1, 5) == "/%40s"
end

local function api_targets_share()
    local args = ngx.req.get_uri_args(20)
    for _, v in pairs(args) do
        if is_share_path(type(v) == "table" and v[1] or v) then return true end
    end
    if ngx.req.get_method() ~= "POST" then return false end
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local f = ngx.req.get_body_file()
        if f then
            local fh = io.open(f, "r")
            if fh then body = fh:read(65536); fh:close() end
        end
    end
    if not body then return false end
    local v = cjson.decode(body)
    if type(v) ~= "table" then
        -- Not JSON: be strict if it mentions a share path at all.
        local l = body:lower()
        return l:find("/@s", 1, true) ~= nil or l:find("/%40s", 1, true) ~= nil
    end
    for _, x in pairs(v) do
        if is_share_path(x) then return true end
        if type(x) == "table" then
            for _, y in pairs(x) do
                if is_share_path(y) then return true end
            end
        end
    end
    return false
end

function _M.run()
    local uri = ngx.var.uri or "/"
    local luri = uri:lower()
    local host = ngx.var.host

    -- The check itself: POST /__turnstile/share  (r, cf-turnstile-response)
    if uri == "/__turnstile/share" then
        if ngx.req.get_method() ~= "POST" then return ngx.redirect("/", 302) end
        local site = ngx.var.http_sec_fetch_site
        if site and site ~= "same-origin" then return page(403, "/", "请求来源无效，请重新打开分享链接。") end
        ngx.req.read_body()
        local args = ngx.req.get_post_args(10)
        local r = safe_return(type(args.r) == "string" and args.r or "/")
        local token = args["cf-turnstile-response"]
        if type(token) == "table" then token = nil end
        local ok, why = ts.verify(token, ACTION)
        if not ok then
            ngx.log(ngx.ERR, "turnstile: share check failed (", why, ") from ", ts.client_ip())
            return page(403, r, why == "missing-token" and "请先完成人机验证。" or "人机验证失败，请重试。")
        end
        local c = make_pass(host)
        if not c then return ngx.exit(500) end
        ngx.header["Set-Cookie"] = c
        ngx.header["Cache-Control"] = "no-store"
        return ngx.redirect(r, 303)
    end

    local is_page = luri == "/@s" or luri:sub(1, 4) == "/@s/"
    -- Share downloads (/sd/) plus OpenList's other share prefixes, in case they get enabled.
    local p2 = luri:match("^(/[a-z]+/)")
    local is_dl = p2 == "/sd/" or p2 == "/sp/" or p2 == "/sad/" or p2 == "/sap/" or p2 == "/sae/"
    local is_api = luri:sub(1, 8) == "/api/fs/"
    if not (is_page or is_dl or is_api) then return false end
    if is_api and (ngx.req.get_method() == "OPTIONS" or not api_targets_share()) then return false end

    if pass_ok(host) then return true end

    if is_page then
        local r = safe_return(ngx.var.request_uri)
        return page(200, r)
    end
    if is_dl then
        -- /sd/<share id>/... -> the share page, which asks for the check.
        local sid = uri:match("^/[^/]+/([%w_-]+)")
        return ngx.redirect(sid and ("/@s/" .. sid) or "/", 302)
    end
    return api_block()
end

return _M
