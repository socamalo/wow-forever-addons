-- 结构化日志：所有关键原始数据写进 SavedVariables，退出/重载后可从
-- WTF/Account/<账号>/SavedVariables/DanielAddon.lua 读出，给开发环境做 fixture。
local addonName, ns = ...

local MAX_ENTRIES = 400
local MAX_STRING = 300
local chatDebug = false

local Log = {}
setmetatable(Log, { __call = function(_, event, data) return Log.Add(event, data) end })
ns.Log = Log

local function Sealed(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

local function Sanitize(v, depth, seen)
    local t = type(v)
    if t == "string" then
        if Sealed(v) then return "<secret>" end
        if #v > MAX_STRING then return v:sub(1, MAX_STRING) .. "…" end
        return v
    elseif t == "number" or t == "boolean" then
        if Sealed(v) then return "<secret>" end
        return v
    elseif t == "nil" then
        return nil
    elseif t == "table" then
        if depth >= 3 or seen[v] then return "<table>" end
        seen[v] = true
        local out, n = {}, 0
        local ok = pcall(function()
            for k, val in pairs(v) do
                n = n + 1
                if n > 30 then
                    out["..."] = "truncated"
                    break
                end
                local key = type(k) == "string" and k or tostring(k)
                out[key] = Sanitize(val, depth + 1, seen)
            end
        end)
        seen[v] = nil
        if not ok then return "<unreadable table>" end
        return out
    end
    return "<" .. t .. ">"
end

function Log.Text(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    local ok = pcall(function()
        for k, val in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. (type(val) == "table" and "{...}" or tostring(val))
        end
    end)
    if not ok then return "<unreadable table>" end
    table.sort(parts)
    return table.concat(parts, ", ")
end

function Log.Add(event, data)
    local db = ns.db
    if not db or db.logEnabled == false then return end
    db.logs = db.logs or {}

    local ok, clean = pcall(Sanitize, data, 1, {})
    if not ok then clean = "<unserializable>" end

    local entry = {
        t = GetTime and GetTime() or 0,
        ts = date and date("%Y-%m-%d %H:%M:%S") or "",
        e = tostring(event),
        d = clean,
    }
    db.logs[#db.logs + 1] = entry
    while #db.logs > MAX_ENTRIES do
        table.remove(db.logs, 1)
    end

    if chatDebug then
        ns.Print("LOG " .. entry.e .. " " .. (type(clean) == "table" and Log.Text(clean) or tostring(clean)))
    end
end

function Log.Count()
    return ns.db and ns.db.logs and #ns.db.logs or 0
end

function Log.SetEnabled(on)
    if ns.db then ns.db.logEnabled = on and true or false end
end

function Log.SetChat(on)
    chatDebug = on and true or false
end

function Log.Clear()
    if ns.db then ns.db.logs = {} end
end

function Log.Dump(n)
    n = tonumber(n) or 10
    local logs = ns.db and ns.db.logs or {}
    local start = math.max(1, #logs - n + 1)
    if #logs == 0 then
        ns.Print("日志为空。")
        return
    end
    for i = start, #logs do
        local e = logs[i]
        local data = type(e.d) == "table" and Log.Text(e.d) or tostring(e.d)
        ns.Print(string.format("[%d] %s %s %s", i, tostring(e.ts), tostring(e.e), data))
    end
    ns.Print("共 " .. #logs .. " 条；完整内容在 SavedVariables 的 DanielAddonDB.logs。")
end

local function ProbeCall(label, fn, out)
    local ok, a, b, c, d = pcall(fn)
    if ok then
        out[label] = { ok = true, a = a, b = b, c = c, d = d }
    else
        out[label] = { ok = false, err = tostring(a) }
    end
end

-- 一键采集本机客户端事实，用来定位“为什么这个 API 不工作”
function Log.Diag()
    local out = {}
    local v1, v2, v3, v4 = GetBuildInfo()
    out.build = { version = v1, build = v2, buildDate = v3, toc = v4,
        projectID = WOW_PROJECT_ID, camelot = WOW_PROJECT_CAMELOT }

    out.api = {
        EquipItemByName = type(C_Item and C_Item.EquipItemByName),
        GetItemInfo = type(C_Item and C_Item.GetItemInfo),
        SetUserWaypoint = type(C_Map and C_Map.SetUserWaypoint),
        GetWorldPosFromMapPos = type(C_Map and C_Map.GetWorldPosFromMapPos),
        GetMapPosFromWorldPos = type(C_Map and C_Map.GetMapPosFromWorldPos),
        GetPlayerMapPosition = type(C_Map and C_Map.GetPlayerMapPosition),
        GetViewRadius = type(C_Minimap and C_Minimap.GetViewRadius),
        UnitPosition = type(UnitPosition),
        UiMapPoint = type(UiMapPoint),
        rotateMinimap = GetCVar and GetCVar("rotateMinimap"),
        minimapZoom = GetCVar and GetCVar("minimapZoom"),
    }

    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    out.mapID = mapID
    if mapID then
        ProbeCall("playerMapPos", function() return C_Map.GetPlayerMapPosition(mapID, "player") end, out)
        ProbeCall("playerWorldPos", function()
            local pos = C_Map.GetPlayerMapPosition(mapID, "player")
            if not pos then return nil end
            return C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(pos.x, pos.y))
        end, out)
        ProbeCall("worldMapPos", function()
            return C_Map.GetMapPosFromWorldPos(0, CreateVector2D(0, 0), mapID)
        end, out)
    end

    local canvasType
    if WorldMapFrame and WorldMapFrame.GetCanvas then
        local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
        canvasType = ok and type(canvas) or "error"
    end
    local shown, wmMapID
    if WorldMapFrame and WorldMapFrame.IsShown then
        local ok, v = pcall(WorldMapFrame.IsShown, WorldMapFrame)
        shown = ok and v or nil
    end
    if WorldMapFrame and WorldMapFrame.GetMapID then
        local ok, v = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
        wmMapID = ok and v or nil
    end
    out.worldMap = {
        frame = type(WorldMapFrame),
        shown = shown,
        mapID = wmMapID,
        canvas = canvasType,
    }
    out.minimap = {
        shown = Minimap and Minimap:IsShown(),
        zoom = Minimap and Minimap:GetZoom(),
        width = Minimap and Minimap:GetWidth(),
        height = Minimap and Minimap:GetHeight(),
    }
    if C_Minimap and C_Minimap.GetViewRadius then
        ProbeCall("viewRadius", C_Minimap.GetViewRadius, out)
    end
    if UnitPosition then
        ProbeCall("unitPosition", function() return UnitPosition("player") end, out)
    end

    Log("diag", out)
    ns.Print("诊断数据已写入日志（" .. Log.Count() .. " 条）。用 /daniel log dump 5 查看摘要。")
    return out
end

-- 记录客户端拦截/禁止事件：pcall 抓不到的静默失败，这里能看到
local errFrame = CreateFrame("Frame")
pcall(errFrame.RegisterEvent, errFrame, "ADDON_ACTION_BLOCKED")
pcall(errFrame.RegisterEvent, errFrame, "ADDON_ACTION_FORBIDDEN")
errFrame:SetScript("OnEvent", function(self, event, addon, func)
    Log(event, { addon = addon, func = func })
    if not ns.__blockedNotified then
        ns.__blockedNotified = true
        ns.Print("检测到插件动作被客户端拦截，已记录到日志（/daniel log dump 5）。")
    end
end)
