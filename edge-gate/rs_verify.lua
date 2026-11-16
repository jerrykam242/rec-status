-- POST /__turnstile/rs-verify: Turnstile check for rec-status.example.com's sign-in (2026-11-16).
-- The Turnstile secret stays on this host; the rec-status server (separate machine) sends the
-- visitor's token here, signed with the key it already shares with this host's request worker
-- (rs_key = rec-status ingest_key): X-RS-Ts, X-RS-Sig = hex HMAC-SHA1(key, "rs-verify|ts|body").
-- Body: token=<turnstile token>&ip=<visitor IP, optional>. Answers {"ok":true} or {"ok":false,"error":...}.
local cjson = require "cjson.safe"
local ts = package.loaded.site_turnstile
if not ts then
    ts = dofile("/www/common/turnstile/turnstile.lua")
    package.loaded.site_turnstile = ts
end

local HOST = "rec-status.example.com"
local ACTION = "rec-status"

local function out(status, tbl)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Cache-Control"] = "no-store"
    ngx.say(cjson.encode(tbl))
    return ngx.exit(status)
end

if ngx.req.get_method() ~= "POST" then return out(405, { ok = false, error = "method" }) end
local key = ts.read_value("rs_key")
if not key then return out(503, { ok = false, error = "not-configured" }) end
local t = tonumber(ngx.var.http_x_rs_ts or "")
if not t or math.abs(ngx.time() - t) > 60 then return out(403, { ok = false, error = "stale" }) end
ngx.req.read_body()
local body = ngx.req.get_body_data() or ""
if #body > 4096 then return out(413, { ok = false, error = "size" }) end
local want = ngx.encode_base16 and ngx.encode_base16(ngx.hmac_sha1(key, "rs-verify|" .. math.floor(t) .. "|" .. body))
    or (ngx.hmac_sha1(key, "rs-verify|" .. math.floor(t) .. "|" .. body):gsub(".", function(c) return string.format("%02x", c:byte()) end))
local got = string.lower(ngx.var.http_x_rs_sig or "")
if #want ~= #got then return out(403, { ok = false, error = "sig" }) end
local diff = 0
for i = 1, #want do if want:byte(i) ~= got:byte(i) then diff = diff + 1 end end
if diff ~= 0 then return out(403, { ok = false, error = "sig" }) end

local args = ngx.decode_args(body, 5)
local token = args.token
if type(token) ~= "string" or #token == 0 or #token > 2048 then return out(200, { ok = false, error = "missing-token" }) end
local secret = ts.read_value("secret")
if not secret then return out(503, { ok = false, error = "not-configured" }) end
local res = ngx.location.capture("/__turnstile_siteverify", {
    method = ngx.HTTP_POST,
    body = ngx.encode_args({ secret = secret, response = token,
                             remoteip = type(args.ip) == "string" and args.ip or nil }),
})
if not res or res.status ~= 200 then return out(502, { ok = false, error = "siteverify-unavailable" }) end
local d = cjson.decode(res.body)
if type(d) ~= "table" or d.success ~= true then
    local codes = type(d) == "table" and type(d["error-codes"]) == "table" and table.concat(d["error-codes"], ",") or ""
    return out(200, { ok = false, error = "rejected:" .. codes })
end
if d.action ~= ACTION then return out(200, { ok = false, error = "action" }) end
if d.hostname ~= HOST then return out(200, { ok = false, error = "hostname" }) end
local used = ngx.shared.site_turnstile
if used then
    local ok, err = used:add("rs:" .. ngx.md5(token), true, 330)
    if not ok and err == "exists" then return out(200, { ok = false, error = "replayed" }) end
end
return out(200, { ok = true })
