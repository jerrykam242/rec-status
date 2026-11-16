-- GET /api/archive: rooms and dates that have recordings (for the request form; signed-in only).
local S = package.loaded["live.store"] or dofile("/www/sites/live/gate/store_load.lua")
local _, raw = S.archive()
ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.header["Cache-Control"] = "private, no-store"
ngx.say(raw or '{"rooms":[]}')
