-- POST /__ingest: snapshot pushed by the agent on the recorder host.
-- Signed with ingest_key: X-Ingest-Sig = hex(HMAC-SHA1(key, X-Ingest-Ts .. "." .. body)).
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local cjson = require "cjson.safe"
local dict = ngx.shared.live_status

if ngx.req.get_method() ~= "POST" then return ngx.exit(405) end
if not dict then
    ngx.log(ngx.ERR, "live: lua_shared_dict live_status missing")
    return ngx.exit(500)
end
local key = L.read_value("ingest_key")
if not key then return ngx.exit(503) end

local ts = tonumber(ngx.var.http_x_ingest_ts or "")
local sig = ngx.var.http_x_ingest_sig or ""
if not ts or math.abs(ngx.time() - ts) > 300 then return ngx.exit(403) end

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body or #body > 262144 then return ngx.exit(413) end
if not L.same(L.hex(ngx.hmac_sha1(key, tostring(math.floor(ts)) .. "." .. body)), sig:lower()) then
    return ngx.exit(403)
end
-- Never go back in time (replayed older snapshots).
local last = dict:get("ts") or 0
if ts < last then return ngx.exit(409) end

local data = cjson.decode(body)
if type(data) ~= "table" or type(data.rooms) ~= "table" then return ngx.exit(400) end

dict:set("ts", ts)
dict:set("body", body)
dict:set("received", ngx.now())
ngx.status = 204
return ngx.exit(204)
