-- Loads common.lua once per worker (no lua_package_path change needed).
local m = package.loaded["live.common"]
if not m then
    m = dofile("/www/sites/live/gate/common.lua")
    package.loaded["live.common"] = m
end
return m
