-- 地理标记核心：解析、地图解析、存储、坐标换算。
-- 这里不创建任何 UI，方便用 Python+lupa 直接做单元测试。
local addonName, ns = ...

local function LogEvent(event, data)
    if ns.Log then ns.Log(event, data) end
end

ns.MarkerCore = ns.MarkerCore or {}
ns.MarkerMath = ns.MarkerMath or {}

local MAX_MAP_ID = 2500      -- Classic 世界的地图 ID 远小于这个数
local MAX_MARKERS = 200

local mapIndex                -- 小写地图名 -> { UiMapDetails, ... }

local function Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Sealed(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

-- 常见英文城市名 -> 本客户端（zhCN）地图名。反向也查得到。
local CITY_ALIASES = {
    ["ironforge"] = "铁炉堡",
    ["stormwind"] = "暴风城",
    ["stormwind city"] = "暴风城",
    ["orgrimmar"] = "奥格瑞玛",
    ["thunder bluff"] = "雷霆崖",
    ["undercity"] = "幽暗城",
    ["darnassus"] = "达纳苏斯",
    ["exodar"] = "埃索达",
    ["silvermoon"] = "银月城",
    ["silvermoon city"] = "银月城",
    ["shattrath"] = "沙塔斯城",
    ["dalaran"] = "达拉然",
}

local function NormalizeCoord(v)
    local n = tonumber(v)
    if not n then return nil end
    if n > 1 then n = n / 100 end
    if n < 0 or n > 1 then return nil end
    return n
end

-- 支持 "55.2,47.8" 这种一个 token 里带逗号的写法
local function SplitTokens(text)
    local out = {}
    for tok in tostring(text or ""):gmatch("[^,%s]+") do
        if tok ~= "" then out[#out + 1] = tok end
    end
    return out
end

local function ParseOne(text)
    text = Trim(text)
    if text == "" then return nil, "空标记" end

    -- 管道格式：zone|x|y|label，zone 可以带空格
    if text:find("|", 1, true) then
        local fields = {}
        for field in (text .. "|"):gmatch("(.-)|") do
            fields[#fields + 1] = Trim(field)
        end
        if #fields < 3 then
            return nil, "管道格式需要 zone|x|y[|label]"
        end
        local x, y = NormalizeCoord(fields[2]), NormalizeCoord(fields[3])
        if not x or not y then
            return nil, "坐标不合法（应在 0-100 或 0-1）"
        end
        return {
            zone = fields[1] ~= "" and fields[1] or nil,
            x = x,
            y = y,
            label = fields[4] ~= "" and fields[4] or nil,
        }
    end

    -- 空白/逗号格式：从第一个数字 token 开始切，前面全算 zone
    local tokens = SplitTokens(text)
    if #tokens < 2 then return nil, "至少需要 x y 两个坐标" end

    local firstNum
    -- 支持“数字 mapID + 坐标”：1426 69.8 56.8。
    -- 只有当第一个数字确实是地图 ID，且后面两个 token 是合法坐标时才这样认。
    if #tokens >= 3 and tonumber(tokens[1]) and C_Map and C_Map.GetMapInfo then
        local zid = tonumber(tokens[1])
        local ok, info = pcall(C_Map.GetMapInfo, zid)
        if ok and info and info.name and NormalizeCoord(tokens[2]) and NormalizeCoord(tokens[3]) then
            firstNum = 2
        end
    end
    if not firstNum then
        for i = 1, #tokens do
            if tonumber(tokens[i]) then
                firstNum = i
                break
            end
        end
    end
    if not firstNum then return nil, "找不到坐标数字" end

    local x, y = NormalizeCoord(tokens[firstNum]), NormalizeCoord(tokens[firstNum + 1])
    if not x or not y then return nil, "坐标不合法（应在 0-100 或 0-1）" end

    local zone
    if firstNum > 1 then
        zone = table.concat(tokens, " ", 1, firstNum - 1)
    end
    local label
    if tokens[firstNum + 2] then
        label = table.concat(tokens, " ", firstNum + 2)
    end
    return { zone = zone, x = x, y = y, label = label }
end

-- 批量：用 ; 或换行分隔，每项可以用管道或空白格式
local function ParseBatch(text)
    text = Trim(text)
    if text == "" then return nil, "空批次" end
    local out = {}
    local n = 0
    for piece in (text .. ";"):gmatch("([^;\n]*)[;\n]") do
        local cleaned = Trim(piece)
        if cleaned ~= "" then
            n = n + 1
            local item, err = ParseOne(cleaned)
            if not item then
                return nil, "第 " .. n .. " 项：" .. tostring(err)
            end
            out[#out + 1] = item
        end
    end
    if #out == 0 then return nil, "没有有效标记" end
    return out
end

ns.MarkerParse = {
    ParseOne = ParseOne,
    ParseBatch = ParseBatch,
    NormalizeCoord = NormalizeCoord,
    SplitTokens = SplitTokens,
    Trim = Trim,
}

-- ---------------- 地图名索引 ----------------

local function BuildMapIndex()
    if mapIndex then return mapIndex end
    mapIndex = {}
    if not C_Map or not C_Map.GetMapInfo then return mapIndex end
    for id = 1, MAX_MAP_ID do
        local ok, info = pcall(C_Map.GetMapInfo, id)
        if ok and info and info.name and info.name ~= "" then
            local key = info.name:lower()
            local list = mapIndex[key]
            if not list then
                list = {}
                mapIndex[key] = list
            end
            list[#list + 1] = info
        end
    end
    return mapIndex
end

local MAPTYPE_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local MAPTYPE_MICRO = (Enum and Enum.UIMapType and Enum.UIMapType.Micro) or 5
local MAPTYPE_DUNGEON = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4

local function TypeRank(mapType)
    -- 同名地图时优先 Zone，其次 Micro / Dungeon，最后大洲
    if mapType == MAPTYPE_ZONE then return 1 end
    if mapType == MAPTYPE_MICRO then return 2 end
    if mapType == MAPTYPE_DUNGEON then return 3 end
    return 9
end

local function PickBest(list)
    local best = list[1]
    for _, info in ipairs(list) do
        if TypeRank(info.mapType) < TypeRank(best.mapType) then
            best = info
        end
    end
    return best
end

local function CurrentMapID()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    return C_Map.GetBestMapForUnit("player")
end

-- 返回 uiMapID, mapName；失败返回 nil, 错误文本（可带候选）
function ns.MarkerCore.ResolveMap(query)
    if not query or Trim(query) == "" then
        local id = CurrentMapID()
        if not id then return nil, "拿不到当前地图 ID" end
        local info = C_Map.GetMapInfo(id)
        return id, info and info.name or nil
    end

    local id = tonumber(query)
    if id then
        local info = C_Map.GetMapInfo(id)
        if not info then return nil, "地图 ID " .. id .. " 不存在" end
        return id, info.name
    end

    local key = Trim(query):lower()
    key = CITY_ALIASES[key] and CITY_ALIASES[key]:lower() or key
    -- 英文别名也允许子串：ironf -> ironforge -> 铁炉堡
    if not CITY_ALIASES[key] then
        for alias, zh in pairs(CITY_ALIASES) do
            if alias:find(key, 1, true) then
                key = zh:lower()
                break
            end
        end
    end
    local index = BuildMapIndex()

    local exact = index[key]
    if exact and #exact > 0 then
        local best = PickBest(exact)
        return best.mapID or best.uiMapID, best.name
    end

    -- 子串匹配，收集唯一候选
    local matches, seenID = {}, {}
    for name, list in pairs(index) do
        if name:find(key, 1, true) then
            for _, info in ipairs(list) do
                local mid = info.mapID or info.uiMapID
                if not seenID[mid] then
                    seenID[mid] = true
                    matches[#matches + 1] = info
                end
            end
        end
    end
    if #matches == 1 then
        return matches[1].mapID or matches[1].uiMapID, matches[1].name
    end
    if #matches > 1 then
        table.sort(matches, function(a, b)
            local ra, rb = TypeRank(a.mapType), TypeRank(b.mapType)
            if ra ~= rb then return ra < rb end
            return (a.mapID or a.uiMapID) < (b.mapID or b.uiMapID)
        end)
        local names = {}
        for i = 1, math.min(#matches, 5) do
            names[#names + 1] = matches[i].name .. "(" .. (matches[i].mapID or matches[i].uiMapID) .. ")"
        end
        return nil, "地图名有多个候选：" .. table.concat(names, "，")
    end

    return nil, "找不到地图「" .. query .. "」，可以试 /daniel mapfind " .. query
end

-- ---------------- 标记存储 ----------------

local function MarkerList()
    if not ns.db then return {} end
    ns.db.markers = ns.db.markers or {}
    return ns.db.markers
end

local function NextID()
    if not ns.db then return 1 end
    ns.db.markerNextID = (tonumber(ns.db.markerNextID) or 0) + 1
    return ns.db.markerNextID
end

local function WorldOf(uiMapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and type(CreateVector2D) == "function") then
        return nil
    end
    local ok, continentID, vec = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(x, y))
    if not ok or not vec then return nil end
    local wx, wy = vec.x, vec.y
    if Sealed(wx) or Sealed(wy) then return nil end
    return continentID, wx, wy
end

local function Add(zone, x, y, label)
    if not ns.db then return nil, "存档未初始化" end
    local list = MarkerList()
    if #list >= MAX_MARKERS then
        return nil, "标记数量已达上限 " .. MAX_MARKERS
    end

    local uiMapID, mapName = ns.MarkerCore.ResolveMap(zone)
    if not uiMapID then return nil, mapName end

    local nx, ny = NormalizeCoord(x), NormalizeCoord(y)
    if not nx or not ny then return nil, "坐标不合法" end

    -- 同一张图、同一位置：算重复推送，直接复用（有新标签就更新）
    for _, m in ipairs(list) do
        if m.uiMapID == uiMapID
            and math.abs((m.x or 0) - nx) < 0.0005
            and math.abs((m.y or 0) - ny) < 0.0005 then
            if label and label ~= "" then m.label = label end
            return m, nil, true
        end
    end

    local continentID, wx, wy = WorldOf(uiMapID, nx, ny)
    local marker = {
        id = NextID(),
        uiMapID = uiMapID,
        zoneName = mapName,
        x = nx,
        y = ny,
        label = label,
        continentID = continentID,
        wx = wx,
        wy = wy,
        created = date and date("%Y-%m-%d %H:%M:%S") or nil,
    }
    list[#list + 1] = marker

    if ns.Log then
        LogEvent("marker.add", {
            id = marker.id, mapID = uiMapID, zone = mapName,
            x = nx, y = ny, label = label, continentID = continentID,
        })
    end
    return marker
end

local function Find(idOrIndex)
    local list = MarkerList()
    local n = tonumber(idOrIndex)
    if not n then return nil end
    for _, m in ipairs(list) do
        if m.id == n then return m end
    end
    return list[n]
end

local function Remove(idOrIndex)
    local list = MarkerList()
    local marker = Find(idOrIndex)
    if not marker then return nil end
    for i = #list, 1, -1 do
        if list[i] == marker then
            table.remove(list, i)
            LogEvent("marker.remove", { id = marker.id, zone = marker.zoneName })
            return marker
        end
    end
    return nil
end

local function Clear()
    if not ns.db then return 0 end
    local n = #MarkerList()
    ns.db.markers = {}
    LogEvent("marker.clear", { count = n })
    return n
end

-- 设成暴雪自己的用户路径点（只能同时存在一个）
function ns.MarkerCore.SetWaypoint(marker)
    if not marker or not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then
        return false
    end
    local ok, wasSet = pcall(C_Map.SetUserWaypoint,
        UiMapPoint.CreateFromCoordinates(marker.uiMapID, marker.x, marker.y))
    if ns.Log then
        LogEvent("marker.waypoint", { id = marker.id, mapID = marker.uiMapID, ok = ok, wasSet = wasSet })
    end
    return ok and wasSet and true or false
end

ns.Markers = {
    Add = Add,
    Remove = Remove,
    Clear = Clear,
    Find = Find,
    List = MarkerList,
    Max = MAX_MARKERS,
}

ns.MarkerCore.CurrentMapID = CurrentMapID
ns.MarkerCore.BuildMapIndex = BuildMapIndex
ns.MarkerCore.WorldOf = WorldOf

-- 给其它插件用的公开 API：别的插件（或游戏内 companion）可以直接 AddMarker，
-- 效果和 /daniel mark 一样，不用经过聊天命令。
_G.DanielAddonAPI = {
    version = 1,
    AddMarker = function(zone, x, y, label)
        local m, err, dup = Add(zone, x, y, label)
        if m and ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        return m, err, dup
    end,
    AddMarkers = function(list)
        local out = {}
        for _, item in ipairs(list or {}) do
            local m, err = Add(item.zone, item.x, item.y, item.label)
            if m then out[#out + 1] = m else out[#out + 1] = { error = err } end
        end
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        return out
    end,
    ClearMarkers = function()
        local n = Clear()
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        return n
    end,
    ListMarkers = function()
        return MarkerList()
    end,
    SetWaypoint = function(id)
        local m = Find(id)
        return m and ns.MarkerCore.SetWaypoint(m) or false
    end,
}

-- ---------------- 坐标数学（纯函数，可单测） ----------------

-- 把玩家与目标的 world 坐标换算成小地图上的像素偏移。
-- worldYIncreasesNorth：world y 轴是否向北（不同地图可能不同，运行时探测）。
function ns.MarkerMath.Project(px, py, tx, ty, viewRadius, halfW, halfH, worldYIncreasesNorth, rotate, facing)
    local dx, dy = tx - px, ty - py
    local dist = math.sqrt(dx * dx + dy * dy)
    if not viewRadius or viewRadius <= 0 then viewRadius = 1 end

    -- WoW world x 是“向西增大”，所以屏幕右方对应 world x 更小；
    -- WoW UI 的 y 正方向是“上”，北在上。
    local east = -dx
    local north = worldYIncreasesNorth and dy or -dy
    local sx = east / viewRadius * halfW
    local sy = north / viewRadius * halfH

    if rotate and facing then
        -- facing: 0=北, π/2=东；把“角色朝向”转到屏幕正上方
        local c, s = math.cos(facing), math.sin(facing)
        sx, sy = sx * c - sy * s, sx * s + sy * c
    end

    local edge = math.sqrt((sx / halfW) ^ 2 + (sy / halfH) ^ 2)
    local onEdge = edge > 1
    if onEdge then
        sx, sy = sx / edge, sy / edge
    end
    return sx, sy, dist, onEdge
end

-- 探测某张地图的 world y 轴方向：地图 y=0 是北边，y=1 是南边。
-- 如果北边的 world y 更大，说明 world y 向北。
local yOrientationCache = {}

function ns.MarkerMath.WorldYIncreasesNorth(uiMapID)
    if yOrientationCache[uiMapID] ~= nil then return yOrientationCache[uiMapID] end
    yOrientationCache[uiMapID] = true
    if not (C_Map and C_Map.GetWorldPosFromMapPos and type(CreateVector2D) == "function") then
        return true
    end

    -- 先在地图中心附近取两点，避免地图边缘没有 world 数据
    local okA, cA, base = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(0.5, 0.5))
    local okB, cB, below = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(0.5, 0.6))
    if okA and okB and base and below and cA == cB then
        local by, sy = base.y, below.y
        if not Sealed(by) and not Sealed(sy) then
            -- map y=0.6 在 0.5 的南边；world y 更小说明 world y 向北
            yOrientationCache[uiMapID] = sy < by
            return yOrientationCache[uiMapID]
        end
    end

    local ok1, c1, north = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(0.5, 0))
    local ok2, c2, south = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(0.5, 1))
    if ok1 and ok2 and north and south and c1 == c2 then
        local ny, sy = north.y, south.y
        if not Sealed(ny) and not Sealed(sy) then
            yOrientationCache[uiMapID] = ny > sy
        end
    end
    return yOrientationCache[uiMapID]
end

-- 标记在指定地图上的归一化坐标。同图直接用，跨图用 world 坐标换算。
function ns.MarkerCore.MapPositionOf(marker, uiMapID)
    if not marker then return nil end
    if marker.uiMapID == uiMapID then
        return marker.x, marker.y
    end
    if marker.wx and marker.wy
        and C_Map and C_Map.GetMapPosFromWorldPos and type(CreateVector2D) == "function" then
        -- 这个客户端 continentID 可能是 0；退回用标记自己的地图 ID
        local continent = (marker.continentID and marker.continentID ~= 0) and marker.continentID or marker.uiMapID
        local ok, _, vec = pcall(C_Map.GetMapPosFromWorldPos, continent,
            CreateVector2D(marker.wx, marker.wy), uiMapID)
        if ok and vec then
            local x, y = vec.x, vec.y
            if not Sealed(x) and not Sealed(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                return x, y
            end
        end
    end
    return nil
end

-- 玩家当前 world 坐标（小地图用）
function ns.MarkerCore.PlayerWorld()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition
        and C_Map.GetWorldPosFromMapPos and type(CreateVector2D) == "function") then
        return nil
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local px, py = pos.x, pos.y
    if Sealed(px) or Sealed(py) then return nil end
    local ok, continentID, vec = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(px, py))
    if not ok or not vec then return nil end
    local wx, wy = vec.x, vec.y
    if Sealed(wx) or Sealed(wy) then return nil end
    -- 后两个是地图归一化坐标（0-1），前两个是 world 坐标
    return mapID, continentID, wx, wy, px, py
end
