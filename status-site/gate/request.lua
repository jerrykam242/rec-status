-- POST /api/request: a visitor's recording request (signed-in only; gate.lua checks that).
local cjson = require "cjson.safe"
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local S = package.loaded["live.store"] or dofile("/www/sites/live/gate/store_load.lua")
local C = L.config
local dict = ngx.shared.live_status

if ngx.req.get_method() ~= "POST" then return ngx.exit(405) end
local function fail(status, code) return L.json(status, { ok = false, error = code }) end
if not S.same_origin() then return fail(403, "origin") end

-- Limits: per sign-in session, and for the whole site per hour.
local nonce = L.check_token(L.SESS, ngx.var.host)
if not nonce then return fail(401, "sign-in-required") end
local hour = math.floor(ngx.time() / 3600)
if (dict:get("rq:s:" .. nonce) or 0) >= C.request_per_session
    or (dict:get("rq:h:" .. hour) or 0) >= C.request_per_hour then
    return fail(429, "rate-limited")
end

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body or #body > 4096 then return fail(400, "invalid") end
local v = cjson.decode(body)
if type(v) ~= "table" then return fail(400, "invalid") end

local function str(x) return type(x) == "string" and x:match("^%s*(.-)%s*$") or nil end
local name, room_id, date = str(v.name), str(v.roomId), str(v.date)
local ctype, contact, note = str(v.contactType), str(v.contact), str(v.note) or ""
local n = S.ulen(name)
if not n or n < 1 or n > 40 then return fail(400, "invalid") end
if not room_id or not room_id:match("^%d+$") or not date or not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return fail(400, "invalid")
end
if ctype == "qq" then
    if not contact or not ngx.re.find(contact, "^[1-9][0-9]{4,11}$", "jo") then return fail(400, "invalid") end
elseif ctype == "email" then
    if not contact or #contact > 100 or not ngx.re.find(contact, "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", "jo") then
        return fail(400, "invalid")
    end
elseif ctype == "other" then
    local cn = S.ulen(contact)
    if not cn or cn < 2 or cn > 60 then return fail(400, "invalid") end
else
    return fail(400, "invalid")
end
local nn = S.ulen(note)
if not nn or nn > 200 then return fail(400, "invalid") end
-- Consent to the processing, and the separate consent to cross-border transfer (PIPL Art. 39).
if v.consent ~= true or v.consentTransfer ~= true then return fail(400, "invalid") end

local room = S.has_recording(room_id, date)
if not room then return fail(400, "no-recording") end

local id, err = S.update(function(data)
    local open = 0
    for _, r in pairs(data.requests) do
        if S.OPEN[r.status] then open = open + 1 end
    end
    if open >= C.request_max_open then return "busy" end
    local rid
    repeat
        local h = ngx.md5(ngx.var.request_id .. ngx.now() .. math.random())
        rid = "R" .. os.date("!%y%m%d", ngx.time() + 8 * 3600) .. "-" .. h:sub(1, 4):upper()
    until not data.requests[rid]
    data.requests[rid] = {
        id = rid, status = "new", created = ngx.time(), updated = ngx.time(),
        name = name, roomId = room_id, roomName = tostring(room.name or ""), date = date,
        contactType = ctype, contact = contact, note = note,
        waitUntil = ngx.time() + C.request_wait,
        consent = { policy = C.policy_version, at = ngx.time(), transfer = true },   -- record of consent   -- the visitor's page waits this long for a decision
    }
    return rid, true
end)
if not id then return fail(500, "store") end
if id == "busy" then return fail(503, "busy") end

dict:incr("rq:s:" .. nonce, 1, 0, C.sess_ttl + 60)
dict:incr("rq:h:" .. hour, 1, 0, 3700)
ngx.log(ngx.ERR, "live: recording request ", id, " received")   -- no personal data in logs
local ticket = S.ticket(id, tostring(ngx.time() + C.request_watch))
return L.json(200, { ok = true, id = id, ticket = ticket, wait = C.request_wait })
