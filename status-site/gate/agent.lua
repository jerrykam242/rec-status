-- POST /__agent/sync: the request worker on the recorder host (signed like /__ingest, with
-- ingest_key over "ts.body"). It pushes the recordings archive and status updates, and gets back
-- the requests it has to act on: "new" (email the admin, with signed review links) and
-- "approved"/"processing" (copy + share). Also deletes requests 30 days after their last change.
local cjson = require "cjson.safe"
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local S = package.loaded["live.store"] or dofile("/www/sites/live/gate/store_load.lua")
local C = L.config
local dict = ngx.shared.live_status

if ngx.req.get_method() ~= "POST" then return ngx.exit(405) end
local key = L.read_value("ingest_key")
if not key or not L.read_value("admin_key") then return ngx.exit(503) end

local ts = tonumber(ngx.var.http_x_ingest_ts or "")
local sig = ngx.var.http_x_ingest_sig or ""
if not ts or math.abs(ngx.time() - ts) > 300 then return ngx.exit(403) end
ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body or #body > 262144 then return ngx.exit(413) end
if not L.same(L.hex(ngx.hmac_sha1(key, tostring(math.floor(ts)) .. "." .. body)), sig:lower()) then
    return ngx.exit(403)
end
if ts < (dict:get("agent_ts") or 0) then return ngx.exit(409) end
dict:set("agent_ts", ts)

local v = cjson.decode(body)
if type(v) ~= "table" then return ngx.exit(400) end

-- Archive list for the form.
if type(v.archive) == "table" and type(v.archive.rooms) == "table" then
    local rooms = {}
    for _, r in ipairs(v.archive.rooms) do
        if type(r) == "table" and tostring(r.roomId or ""):match("^%d+$") and type(r.dates) == "table" then
            local dates = {}
            for _, d in ipairs(r.dates) do
                if type(d) == "string" and d:match("^%d%d%d%d%-%d%d%-%d%d$") then dates[#dates + 1] = d end
            end
            rooms[#rooms + 1] = { roomId = tostring(r.roomId), name = tostring(r.name or ""):sub(1, 120), dates = dates }
        end
    end
    S.set_archive({ rooms = rooms, updatedAt = ngx.time() })
end

-- What the worker may change: it never decides approve/deny.
local ALLOWED = {
    new = { notified = true },
    approved = { processing = true, shared = true, failed = true },
    processing = { shared = true, failed = true, processing = true },
}

local out, err = S.update(function(data)
    local changed = false
    if type(v.updates) == "table" then
        for _, u in ipairs(v.updates) do
            local r = type(u) == "table" and type(u.id) == "string" and data.requests[u.id]
            if r and ALLOWED[r.status] and ALLOWED[r.status][u.status] then
                r.status = u.status
                r.updated = ngx.time()
                if type(u.note) == "string" then r.statusNote = u.note:sub(1, 300) end
                -- The share, for the visitor's waiting page (shown only if approved in time).
                local sh = u.share
                if u.status == "shared" and type(sh) == "table" and type(sh.url) == "string"
                    and sh.url:match("^https://[%w%.%-]+/@s/[%w_-]+$") and type(sh.pwd) == "string"
                    and sh.pwd:match("^[%w]+$") and #sh.pwd <= 32 and tonumber(sh.expires) then
                    r.share = { url = sh.url, pwd = sh.pwd, expires = math.floor(tonumber(sh.expires)),
                                maxAccess = math.floor(tonumber(sh.maxAccess) or 0) }
                end
                changed = true
            end
        end
    end
    -- Retention.
    local now = ngx.time()
    for id, r in pairs(data.requests) do
        if now - (r.updated or r.created or now) > C.request_keep_days * 86400 then
            data.requests[id] = nil
            changed = true
        end
    end
    local list = {}
    for _, r in pairs(data.requests) do
        if r.status == "new" or r.status == "approved" or r.status == "processing" then
            local item = {
                id = r.id, status = r.status, created = r.created, name = r.name,
                roomId = r.roomId, roomName = r.roomName, date = r.date,
                contactType = r.contactType, contact = r.contact, note = r.note,
                waitUntil = r.waitUntil, decided = r.decided,
            }
            if r.status == "new" then
                local exp = r.created + C.review_days * 86400
                item.approveUrl = S.review_url(r.id, "approve", exp)
                item.denyUrl = S.review_url(r.id, "deny", exp)
                item.reviewExpires = exp
            end
            list[#list + 1] = item
        end
    end
    table.sort(list, function(a, b) return a.created < b.created end)
    return list, changed
end)
if not out then return ngx.exit(500) end
if #out == 0 then out = cjson.empty_array end
return L.json(200, { ok = true, now = ngx.time(), requests = out })
