-- GET /api/request/status?id=&t=: the submitting visitor's page asks how its request is going.
-- t is the ticket from POST /api/request (no sign-in needed, see gate.lua). The answer is one of
--   waiting    no decision yet, still inside request_wait
--   preparing  approved inside request_wait; the worker is making the link
--   ready      approved inside request_wait and shared: includes the link and code
--   denied     refused inside request_wait
--   manual     anything else (no decision in time, decided later, or processing failed)
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local S = package.loaded["live.store"] or dofile("/www/sites/live/gate/store_load.lua")
local C = L.config

if ngx.req.get_method() ~= "GET" then return ngx.exit(405) end
local args = ngx.req.get_uri_args(5)
local id, t = args.id, args.t
if type(id) ~= "string" or not id:match("^R%d%d%d%d%d%d%-%x%x%x%x$") or not S.check_ticket(id, t) then
    return L.json(403, { ok = false, error = "ticket" })
end
local r = S.load().requests[id]
if not r then return L.json(404, { ok = false, error = "missing" }) end

local now = ngx.time()
local wait_until = r.waitUntil or (r.created + C.request_wait)
local in_time = r.decided and r.decided <= wait_until
local st = r.status
local state
if st == "new" or st == "notified" then
    state = now < wait_until and "waiting" or "manual"
elseif st == "approved" or st == "processing" then
    state = in_time and "preparing" or "manual"
elseif st == "shared" then
    state = (in_time and r.share) and "ready" or "manual"
elseif st == "denied" then
    state = in_time and "denied" or "manual"
else
    state = "manual"
end

local out = { ok = true, id = id, state = state, left = math.max(0, wait_until - now),
              roomName = r.roomName, roomId = r.roomId, date = r.date }
if state == "ready" then out.share = r.share end
return L.json(200, out)
