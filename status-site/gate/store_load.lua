-- Loads store.lua once per worker.
local m = package.loaded["live.store"]
if not m then
    m = dofile("/www/sites/live/gate/store.lua")
    package.loaded["live.store"] = m
end
return m
