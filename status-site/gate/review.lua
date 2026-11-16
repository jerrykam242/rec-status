-- /__admin/review?id=&a=approve|deny&exp=&sig=  (link from the admin email, HMAC with admin_key)
-- GET shows the request and a confirm button; POST (same URL, same origin) applies the decision.
-- Opening the link alone never changes anything, so mail scanners cannot approve requests.
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local S = package.loaded["live.store"] or dofile("/www/sites/live/gate/store_load.lua")
local C = L.config
local esc = L.html_escape

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then return ngx.exit(405) end

local args = ngx.req.get_uri_args(8)
local id, action, exp, sig = args.id, args.a, tonumber(args.exp), args.sig
local CONTACT = { qq = "QQ", email = "邮箱", other = "其他" }
local ACTION = { approve = "批准", deny = "拒绝" }

local function page(status, title, body_html)
    ngx.status = status
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Frame-Options"] = "DENY"
    ngx.header["Referrer-Policy"] = "no-referrer"
    ngx.header["Content-Security-Policy"] =
        "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    ngx.print('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>', esc(title),
        ' – 录播状态</title><meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="robots" content="noindex, nofollow">',
        '<link rel="stylesheet" href="/assets/carbon.css?v=4"><link rel="stylesheet" href="/assets/live.css?v=9">',
        '</head><body><header class="cds--header live-header" data-theme="g100" aria-label="录播状态">',
        '<a class="cds--header__name live-header__name" href="/"><img class="live-header__mark" src="/assets/logo.svg?v=1" width="20" height="20" alt="">录播状态</a></header>',
        '<main class="live-main live-review"><h1 class="live-h2 live-review__title">', esc(title), '</h1>', body_html,
        '</main><footer class="live-footer"><div class="live-footer__inner"><p><a class="cds--link live-footer__link" href="/terms">服务条款 / Terms of Service</a><span class="live-footer__sep" aria-hidden="true">·</span><a class="cds--link live-footer__link" href="/privacy">隐私政策 / Privacy Policy</a></p><p>© 2026 Site operator</p></div></footer></body></html>')
    return ngx.exit(status)
end

if type(id) ~= "string" or not id:match("^R%d%d%d%d%d%d%-%w%w%w%w$") or not ACTION[action] or not exp
    or type(sig) ~= "string" or not L.same(S.review_sig(id, action, math.floor(exp)) or "", sig:lower()) then
    return page(403, "链接无效", '<p class="live-review__p">此审核链接无效。</p>')
end
if exp < ngx.time() then
    return page(410, "链接已过期", '<p class="live-review__p">此审核链接已过期，请求未作处理。</p>')
end

local function details(r)
    local rows = {
        { "请求编号", r.id }, { "称呼", r.name }, { "直播间", (r.roomName or "") .. "（" .. r.roomId .. "）" },
        { "日期", r.date }, { "联系方式", (CONTACT[r.contactType] or "") .. "：" .. r.contact },
        { "备注", (r.note ~= "" and r.note) or "—" },
        { "提交时间", os.date("!%Y-%m-%d %H:%M", r.created + 8 * 3600) .. "（北京时间）" },
        { "当前状态", S.LABELS[r.status] or r.status },
    }
    local h = { '<dl class="live-review__dl">' }
    for _, row in ipairs(rows) do
        h[#h + 1] = "<div><dt>" .. esc(row[1]) .. "</dt><dd>" .. esc(row[2]) .. "</dd></div>"
    end
    h[#h + 1] = "</dl>"
    return table.concat(h)
end

if method == "POST" then
    if not S.same_origin() then return page(403, "请求被拒绝", '<p class="live-review__p">请从审核页面提交。</p>') end
    local r, err = S.update(function(data)
        local r = data.requests[id]
        if not r then return "missing" end
        if not S.OPEN[r.status] then return r end
        r.status = action == "approve" and "approved" or "denied"
        r.updated = ngx.time()
        r.decided = ngx.time()
        return r, true
    end)
    if not r then return page(500, "处理失败", '<p class="live-review__p">暂时无法保存，请稍后重试。</p>') end
    if r == "missing" then return page(404, "请求不存在", '<p class="live-review__p">该请求不存在或已被删除。</p>') end
    ngx.log(ngx.ERR, "live: recording request ", id, " -> ", r.status)
    local waiting = r.waitUntil and r.decided and r.decided <= r.waitUntil
    local msg = r.status == "approved" and (waiting
            and "已批准。申请人仍在等待页面上，链接生成后会直接显示给申请人，同时发送到管理员邮箱。"
            or "已批准。系统正在准备下载链接，完成后会发送到管理员邮箱，请转发给申请人。")
        or r.status == "denied" and (waiting and "已拒绝。申请人的页面会显示“未获批准”。" or "已拒绝。")
        or ("该请求已处理：" .. (S.LABELS[r.status] or r.status))
    return page(200, "请求 " .. id, '<p class="live-review__p">' .. esc(msg) .. "</p>" .. details(r))
end

local r = S.load().requests[id]
if not r then return page(404, "请求不存在", '<p class="live-review__p">该请求不存在或已被删除。</p>') end
if not S.OPEN[r.status] then
    return page(200, "请求 " .. id, '<p class="live-review__p">该请求已处理，无需再次操作。</p>' .. details(r))
end
local btn = action == "approve" and "cds--btn--primary" or "cds--btn--danger"
return page(200, ACTION[action] .. "请求 " .. id,
    '<p class="live-review__p">请确认以下请求，然后点击按钮' .. ACTION[action] .. '。</p>' .. details(r) ..
    '<form method="post" action="/__admin/review?id=' .. esc(id) .. '&amp;a=' .. esc(action) .. '&amp;exp=' ..
    math.floor(exp) .. '&amp;sig=' .. esc(sig) .. '"><button type="submit" class="cds--btn ' .. btn .. '">确认' ..
    ACTION[action] .. '</button></form>')
