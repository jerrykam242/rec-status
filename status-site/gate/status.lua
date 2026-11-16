-- GET /api/status: the latest snapshot (signed-in visitors only; gate.lua checks that).
local dict = ngx.shared.live_status
local body = dict and dict:get("body")
local received = dict and dict:get("received")
ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.header["Cache-Control"] = "private, no-store"
ngx.header["X-Content-Type-Options"] = "nosniff"
ngx.say('{"serverTime":', string.format("%.3f", ngx.now()),
        ',"receivedAt":', received and string.format("%.3f", received) or "null",
        ',"data":', body or "null", "}")
