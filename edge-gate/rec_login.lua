-- rec.example.com: GET/POST /__turnstile/login, the Carbon-style sign-in page.
-- POST checks Turnstile (action rec-login), then the username and password,
-- then sets the session cookie and returns to ?r=.
local auth = package.loaded.site_rec_auth
if not auth then
    auth = dofile("/www/common/turnstile/rec_auth.lua")
    package.loaded.site_rec_auth = auth
end
local ts = auth.ts

local SITEKEY = "YOUR_TURNSTILE_SITEKEY"
local ASSET_V = "21"   -- bump after editing anything in public/rec/
local TEMPLATE = "/www/common/turnstile/templates/rec_login.html"

local function template()
    local t = package.loaded.site_rec_login_tpl
    if t then return t end
    local f = io.open(TEMPLATE, "r")
    if not f then return nil end
    t = f:read("*a")
    f:close()
    package.loaded.site_rec_login_tpl = t
    return t
end

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"']", ESC))
end

-- Carbon icons (32 x 32 artboards, drawn at 16 or 20 px), inlined so they take currentColor.
local ICON = {
    warning = '<path d="M16,2C8.3,2,2,8.3,2,16s6.3,14,14,14s14-6.3,14-14C30,8.3,23.7,2,16,2z M14.9,8h2.2v11h-2.2V8z M16,25c-0.8,0-1.5-0.7-1.5-1.5S15.2,22,16,22c0.8,0,1.5,0.7,1.5,1.5S16.8,25,16,25z"/>',
    error = '<path d="M16,2A13.914,13.914,0,0,0,2,16,13.914,13.914,0,0,0,16,30,13.914,13.914,0,0,0,30,16,13.914,13.914,0,0,0,16,2Zm5.4449,21L9,10.5557,10.5557,9,23,21.4448Z"/>',
    success = '<path d="M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2ZM14,21.5908l-5-5L10.5906,15,14,18.4092,21.41,11l1.5957,1.5859Z"/>',
    info = '<path d="M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2Zm0,6a1.5,1.5,0,1,1-1.5,1.5A1.5,1.5,0,0,1,16,8Zm4,16.125H12v-2.25h2.875v-5.75H13v-2.25h4.125v8H20Z"/>',
}
local function icon(name, size, class)
    return '<svg class="' .. class .. '" focusable="false" aria-hidden="true" width="' .. size .. '" height="' .. size
        .. '" viewBox="0 0 32 32">' .. ICON[name] .. "</svg>"
end

local FIELDS = {
    username = "username-error",
    password = "password-error",
    ts       = "security-check-error",
}

-- Carbon inline notification (low contrast). kind: success | info | error
local function notification(kind, title, subtitle)
    local role = (kind == "error") and "alert" or "status"
    return '      <div class="cds--inline-notification cds--inline-notification--low-contrast cds--inline-notification--'
        .. kind .. ' rec-notification" role="' .. role .. '">\n'
        .. '        <div class="cds--inline-notification__details">\n'
        .. "          " .. icon(kind, 20, "cds--inline-notification__icon") .. "\n"
        .. '          <div class="cds--inline-notification__text-wrapper">\n'
        .. '            <div class="cds--inline-notification__title">' .. esc(title) .. "</div>\n"
        .. (subtitle and ('            <div class="cds--inline-notification__subtitle">' .. esc(subtitle) .. "</div>\n") or "")
        .. "          </div>\n        </div>\n      </div>\n"
end

local function banner(kind)
    if kind == "out" then
        return notification("success", "You have signed out", nil)
    elseif kind == "ended" then
        return notification("info", "Your session has ended", "Sign in again to carry on.")
    end
    return ""
end

-- st = { errors = { username|password|ts = text, form = {title, subtitle} }, username, r, remember, banner }
local function render(st, status)
    local tpl = template()
    if not tpl then
        ngx.log(ngx.ERR, "rec-auth: cannot read ", TEMPLATE)
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    local errs = st.errors or {}
    local failed = next(errs) ~= nil
    local summary = errs.form and notification("error", errs.form[1], errs.form[2]) or ""

    local function wrap(f) return errs[f] and ' data-invalid="true"' or "" end
    local function ico(f)
        return errs[f] and ("              " .. icon("warning", 16, "cds--text-input__invalid-icon") .. "\n") or ""
    end
    local function input(f) return errs[f] and " cds--text-input--invalid" or "" end
    local function desc(f)
        return errs[f] and (' data-invalid="true" aria-invalid="true" aria-describedby="' .. FIELDS[f] .. '"') or ""
    end
    local function msg(f, indent)
        return errs[f] and (indent .. '<div class="cds--form-requirement" id="' .. FIELDS[f] .. '">'
            .. esc(errs[f]) .. "</div>\n") or ""
    end

    local vars = {
        TITLEPREFIX = failed and "Error: " or "",
        V = ASSET_V,
        SITEKEY = SITEKEY,
        BANNER = failed and "" or banner(st.banner),
        ERRORSUMMARY = summary,
        R = esc(st.r or "/"),
        USERNAME = esc(st.username),
        USERWRAP = wrap("username"), USERICON = ico("username"), USERINPUT = input("username"),
        USERDESC = desc("username"), USERERROR = msg("username", "            "),
        PASSWRAP = wrap("password"), PASSICON = ico("password"), PASSINPUT = input("password"),
        PASSDESC = desc("password"), PASSERROR = msg("password", "            "),
        TSGROUP = errs.ts and " rec-security--invalid" or "", TSERROR = msg("ts", "          "),
        REMEMBER = st.remember and " checked" or "",
    }
    local html = tpl:gsub("{{(%u+)}}", function(k) return vars[k] or "" end)

    ngx.status = status or ngx.HTTP_OK
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Frame-Options"] = "DENY"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.header["Referrer-Policy"] = "same-origin"
    ngx.header["Content-Security-Policy"] = "default-src 'self'; "
        .. "script-src 'self' https://challenges.cloudflare.com; "
        .. "frame-src https://challenges.cloudflare.com; "
        .. "connect-src 'self' https://challenges.cloudflare.com; "
        .. "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; "
        .. "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    ngx.print(html)
    return ngx.exit(ngx.status)
end

local host = ngx.var.host
local method = ngx.req.get_method()

if method == "GET" or method == "HEAD" then
    local q = ngx.req.get_uri_args(10)
    local r = auth.safe_return(type(q.r) == "string" and q.r or "/")
    if auth.session_ok(host) then
        ngx.header["Cache-Control"] = "no-store"
        return ngx.redirect(r, 302)
    end
    return render({ r = r, banner = (q.out and "out") or (q.x and "ended") or nil })
end

if method ~= "POST" then
    return ngx.exit(ngx.HTTP_NOT_ALLOWED)
end

ngx.req.read_body()
local args = ngx.req.get_post_args(20) or {}
local function str(v)
    if type(v) == "table" then v = v[1] end
    return type(v) == "string" and v or ""
end

local username = str(args.username):match("^%s*(.-)%s*$")
local password = str(args.password)
local token = str(args["cf-turnstile-response"])
local st = {
    username = username:sub(1, 200),
    r = auth.safe_return(str(args.r)),
    remember = str(args.remember) == "1",
    errors = {},
}
local e = st.errors

if username == "" then e.username = "Enter your username" end
if password == "" then e.password = "Enter your password" end
if token == "" then e.ts = "Complete the security check" end
if next(e) then return render(st) end

if auth.locked() then
    e.form = { "Too many attempts", "Wait 15 minutes, then try again." }
    ngx.log(ngx.ERR, "rec-auth: sign-in locked for ", ts.client_ip())
    return render(st, 429)
end

local ok, why = ts.verify(token, "rec-login")
if not ok then
    ngx.log(ngx.ERR, "turnstile: rec login failed (", why, ") from ", ts.client_ip())
    if why == "not-configured" or why == "siteverify-unavailable" or why == "siteverify-bad-json" then
        e.ts = "The security check is not working right now. Try again in a few minutes"
    else
        e.ts = "The security check did not work. Complete it again"
    end
    return render(st)
end

local good, err = auth.check(username, password)
if good == nil then
    ngx.log(ngx.ERR, "rec-auth: cannot check sign-in (", err, ")")
    e.form = { "Sign-in isn't set up yet", "Ask the administrator to run set-rec-auth.sh on the server." }
    return render(st, 503)
end
if not good then
    auth.note_failure()
    ngx.log(ngx.ERR, "rec-auth: wrong username or password for '", username:sub(1, 64):gsub("[%c]", "?"),
        "' from ", ts.client_ip())
    e.form = { "Incorrect username or password", "Check them and try again." }
    return render(st)
end

local cookie = auth.make_cookie(host, st.remember)
if not cookie then
    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
auth.clear_failures()
ngx.header["Cache-Control"] = "no-store"
ngx.header["Set-Cookie"] = cookie
return ngx.redirect(st.r, 303)
