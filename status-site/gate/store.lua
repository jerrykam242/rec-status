-- live status site: recording requests and the recordings archive list.
-- Requests live in one small JSON file (data_dir/requests.json, root-only, outside the web root),
-- rewritten atomically under a lock; volume is a handful a week. See README "Recording requests".
local cjson = require "cjson.safe"
local resty_lock = require "resty.lock"
local L = package.loaded["live.common"] or dofile("/www/sites/live/gate/load.lua")
local C = L.config

local _M = {}
local DIR = C.data_dir
local REQ_FILE = DIR .. "requests.json"
local ARCH_FILE = DIR .. "archive.json"

-- Status flow: new -> notified (admin emailed) -> approved | denied;
-- approved -> processing (worker copying/sharing) -> shared | failed.
_M.LABELS = {
    new = "等待审核", notified = "等待审核", approved = "已批准，处理中", processing = "已批准，处理中",
    shared = "已完成", failed = "处理失败", denied = "已拒绝",
}
_M.OPEN = { new = true, notified = true }           -- the admin can still decide
_M.FINAL = { shared = true, failed = true, denied = true }

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, s)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then return nil, err end
    f:write(s)
    f:close()
    return os.rename(tmp, path)
end

function _M.load()
    local d = cjson.decode(read_file(REQ_FILE) or "") or {}
    if type(d.requests) ~= "table" then d.requests = {} end
    return d
end

-- Runs fn(data) under the store lock; fn changes data in place and returns (result, changed).
function _M.update(fn)
    local lock, err = resty_lock:new("live_status", { exptime = 10, timeout = 5 })
    if not lock then return nil, err end
    local ok, lerr = lock:lock("store:requests")
    if not ok then return nil, lerr end
    local data = _M.load()
    local res, changed = fn(data)
    if changed then
        local s = cjson.encode(data)
        local wok, werr = write_file(REQ_FILE, s)
        if not wok then
            lock:unlock()
            ngx.log(ngx.ERR, "live: cannot write ", REQ_FILE, ": ", werr)
            return nil, "write"
        end
    end
    lock:unlock()
    return res
end

-- Archive: { rooms = { {roomId=, name=, dates={...}} }, updatedAt = } pushed by the worker.
function _M.archive()
    local dict = ngx.shared.live_status
    local s = dict and dict:get("archive")
    if not s then
        s = read_file(ARCH_FILE)
        if s and dict then dict:set("archive", s) end
    end
    return s and cjson.decode(s) or nil, s
end

function _M.set_archive(tbl)
    local s = cjson.encode(tbl)
    local dict = ngx.shared.live_status
    if dict then dict:set("archive", s) end
    local ok, err = write_file(ARCH_FILE, s)
    if not ok then ngx.log(ngx.ERR, "live: cannot write ", ARCH_FILE, ": ", err) end
    return ok
end

function _M.has_recording(room_id, date)
    local a = _M.archive()
    if type(a) ~= "table" or type(a.rooms) ~= "table" then return nil end
    for _, r in ipairs(a.rooms) do
        if tostring(r.roomId) == room_id and type(r.dates) == "table" then
            for _, d in ipairs(r.dates) do
                if d == date then return r end
            end
        end
    end
    return nil
end

-- Signed review links for the admin: HMAC(admin_key, "review|id|action|exp").
function _M.review_sig(id, action, exp)
    local key = L.read_value("admin_key")
    if not key then return nil end
    return L.hex(ngx.hmac_sha1(key, "review|" .. id .. "|" .. action .. "|" .. exp))
end

function _M.review_url(id, action, exp)
    local sig = _M.review_sig(id, action, exp)
    if not sig then return nil end
    return C.public_url .. "/__admin/review?id=" .. id .. "&a=" .. action .. "&exp=" .. exp .. "&sig=" .. sig
end

-- Status ticket for the visitor who submitted a request: "exp.hmac(cookie_key, watch|id|exp)".
-- Only that browser gets it (in the POST /api/request answer; kept in page memory only).
function _M.ticket(id, exp)
    local key = L.read_value("cookie_key")
    if not key then return nil end
    return exp .. "." .. L.b64url(ngx.hmac_sha1(key, "watch|" .. id .. "|" .. exp))
end

function _M.check_ticket(id, t)
    if type(id) ~= "string" or type(t) ~= "string" then return false end
    local exp = t:match("^(%d+)%.[%w_-]+$")
    if not exp or tonumber(exp) <= ngx.time() then return false end
    return L.same(_M.ticket(id, exp) or "", t)
end

-- Number of UTF-8 characters, or nil if s is not valid UTF-8 / has control characters.
function _M.ulen(s)
    if type(s) ~= "string" then return nil end
    local ok, m = pcall(ngx.re.find, s, "[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]", "jou")
    if not ok or m then return nil end
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- Same-origin check for browser POSTs.
function _M.same_origin()
    local origin = ngx.var.http_origin
    if origin and origin ~= "https://" .. ngx.var.host then return false end
    local site = ngx.var.http_sec_fetch_site
    if site and site ~= "same-origin" then return false end
    return true
end

return _M
