-- /__gate/logout: forget the session and go back to the sign-in page.
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
ngx.header["Set-Cookie"] = { L.clear_token(L.SESS), L.clear_token(L.ENTRY) }
ngx.header["Cache-Control"] = "no-store"
return ngx.redirect("/__gate/login", 302)
