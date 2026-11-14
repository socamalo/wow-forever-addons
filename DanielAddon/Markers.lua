-- 标记的显示层：世界地图 pin + 小地图 pin。
-- 只创建自己的普通 Frame，不碰 Blizzard 的受保护框体。
local addonName, ns = ...

ns.MarkersUI = ns.MarkersUI or {}

-- 醒目：品红 pin + 金色标签 + 呼吸光晕
local YELLOW = { 1.0, 0.15, 0.85 }
local LABEL_COLOR = { 1.0, 0.88, 0.2 }
local PIN_ATLAS = "Waypoint-MapPin-Tracked"
local GLOW_ATLAS = "UI-QuestPoi-OuterGlow"

-- HBD/Questie 用的降级表：C_Minimap.GetViewRadius 不可用时的视野直径
local MINIMAP_VIEW = {
    outdoor = { [0] = 466 + 2 / 3, [1] = 400, [2] = 333 + 1 / 3, [3] = 266 + 2 / 6, [4] = 200, [5] = 133 + 1 / 3 },
    indoor  = { [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50 },
}

local worldPins = {}   -- [markerID] = frame
local miniPins = {}    -- [markerID] = frame

local function Sealed(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

local function SafeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

local function TryAtlas(tex, atlas)
    if tex.SetAtlas then
        local ok = pcall(tex.SetAtlas, tex, atlas, false)
        if ok then return true end
    end
    return false
end

local function StylePin(pin, size)
    pin:SetSize(size, size)

    -- 图标单独放一个子框，呼吸缩放不会带着文字一起抖
    local iconFrame = CreateFrame("Frame", nil, pin)
    iconFrame:SetAllPoints(pin)
    iconFrame:SetFrameLevel((pin:GetFrameLevel() or 1) + 2)
    pin.iconFrame = iconFrame

    local glow = iconFrame:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(size * 2.1, size * 2.1)
    if not TryAtlas(glow, GLOW_ATLAS) then
        glow:SetColorTexture(YELLOW[1], YELLOW[2], YELLOW[3], 0.45)
    else
        glow:SetVertexColor(YELLOW[1], YELLOW[2], YELLOW[3])
    end
    if glow.SetBlendMode then glow:SetBlendMode("ADD") end
    pin.glow = glow

    local icon = iconFrame:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("CENTER")
    icon:SetSize(size, size)
    if not TryAtlas(icon, PIN_ATLAS) then
        icon:SetColorTexture(YELLOW[1], YELLOW[2], YELLOW[3], 1)
    else
        icon:SetVertexColor(YELLOW[1], YELLOW[2], YELLOW[3])
    end
    pin.icon = icon

    -- 呼吸光晕：0.35 ↔ 1，0.9 秒一轮
    if iconFrame.CreateAnimationGroup then
        local pulse = iconFrame:CreateAnimationGroup()
        local fade = pulse:CreateAnimation("Alpha")
        fade:SetFromAlpha(0.35)
        fade:SetToAlpha(1.0)
        fade:SetDuration(0.9)
        fade:SetSmoothing("IN_OUT")
        pulse:SetLooping("BOUNCE")
        pulse:Play()
        pin.pulse = pulse
    end
    return pin
end

local function TooltipText(pin)
    local m = pin.marker
    if not m then return end
    GameTooltip:SetOwner(pin, "ANCHOR_TOP")
    GameTooltip:AddLine(m.label or "标记", YELLOW[1], YELLOW[2], YELLOW[3])
    GameTooltip:AddLine(string.format("%s  %.1f, %.1f", m.zoneName or "?", (m.x or 0) * 100, (m.y or 0) * 100),
        1, 1, 1)
    if pin.distance then
        GameTooltip:AddLine(string.format("%.0f 码", pin.distance), 0.8, 0.8, 0.8)
    end
    GameTooltip:AddLine("点击设为暴雪路径点", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function PlayerDistance(marker)
    local _, _, px, py = ns.MarkerCore.PlayerWorld()
    if not px or not marker.wx then return nil end
    local dx, dy = marker.wx - px, marker.wy - py
    return math.sqrt(dx * dx + dy * dy)
end

-- ---------------- 世界地图 ----------------

local function CreateWorldPin(marker)
    local canvas = WorldMapFrame:GetCanvas()
    local pin = CreateFrame("Frame", nil, canvas)
    StylePin(pin, 42)
    pin:SetFrameLevel((canvas:GetFrameLevel() or 1) + 20)
    pin:EnableMouse(true)

    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.label:SetPoint("TOP", pin, "BOTTOM", 0, -4)
    pin.label:SetJustifyH("CENTER")
    pin.label:SetTextColor(LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3])
    pin.label:SetShadowColor(0, 0, 0, 1)
    pin.label:SetShadowOffset(2, -2)

    pin:SetScript("OnEnter", function(self)
        TooltipText(self)
    end)
    pin:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    pin:SetScript("OnMouseUp", function(self)
        if self.marker then
            local ok = ns.MarkerCore.SetWaypoint(self.marker)
            ns.Print(ok and ("已设为路径点：" .. (self.marker.label or self.marker.zoneName))
                or "设置路径点失败。")
        end
    end)
    pin.marker = marker
    return pin
end

function ns.MarkersUI.RefreshWorld()
    if not (WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame.GetMapID) then return end
    local mapID = WorldMapFrame:GetMapID()
    local canvas = WorldMapFrame:GetCanvas()
    if not mapID or not canvas then return end

    local w, h = canvas:GetWidth(), canvas:GetHeight()
    if not w or not h or w <= 0 or h <= 0 then return end

    local live = {}
    for _, marker in ipairs(ns.Markers.List()) do
        live[marker.id] = true
        local x, y = ns.MarkerCore.MapPositionOf(marker, mapID)
        local pin = worldPins[marker.id]
        if x then
            if not pin then
                pin = CreateWorldPin(marker)
                worldPins[marker.id] = pin
            end
            pin.marker = marker
            pin.distance = PlayerDistance(marker)
            pin.label:SetText(marker.label or "")
            local scale = pin:GetScale() or 1
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", canvas, "TOPLEFT", (w * x) / scale, -(h * y) / scale)
            pin:Show()
        elseif pin then
            pin:Hide()
        end
    end

    for id, pin in pairs(worldPins) do
        if not live[id] then pin:Hide() end
    end
end

-- ---------------- 小地图 ----------------

local function CreateMiniPin(marker)
    local pin = CreateFrame("Frame", nil, Minimap)
    StylePin(pin, 30)
    pin:SetFrameStrata("HIGH")
    pin:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 30)
    pin:EnableMouse(true)
    pin.marker = marker
    pin.distText = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pin.distText:SetPoint("TOP", pin, "BOTTOM", 0, -1)
    pin.distText:SetTextColor(LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3])
    pin.distText:SetShadowColor(0, 0, 0, 1)
    pin.distText:SetShadowOffset(1, -1)
    pin:SetScript("OnEnter", function(self)
        TooltipText(self)
    end)
    pin:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    pin:SetScript("OnMouseUp", function(self)
        if self.marker then
            local ok = ns.MarkerCore.SetWaypoint(self.marker)
            ns.Print(ok and ("已设为路径点：" .. (self.marker.label or self.marker.zoneName))
                or "设置路径点失败。")
        end
    end)
    return pin
end

local function ViewRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        local ok, radius = pcall(C_Minimap.GetViewRadius)
        if ok and type(radius) == "number" and radius > 0 and not Sealed(radius) then
            return radius
        end
    end
    local zoom = (Minimap and Minimap.GetZoom and Minimap:GetZoom()) or 0
    local cvarZoom = tonumber(GetCVar("minimapZoom")) or 0
    local indoor = cvarZoom ~= zoom
    local t = indoor and MINIMAP_VIEW.indoor or MINIMAP_VIEW.outdoor
    return (t[zoom] or 100) / 2
end

local function RotateEnabled()
    return tonumber(GetCVar("rotateMinimap")) == 1
end

local function UpdateMiniPins()
    if not (ns.db and ns.db.showMinimapMarkers) then
        for _, pin in pairs(miniPins) do pin:Hide() end
        return
    end
    if not (Minimap and Minimap:IsShown()) then return end

    local markers = ns.Markers.List()
    if #markers == 0 then
        for _, pin in pairs(miniPins) do pin:Hide() end
        return
    end

    local mapID, continentID, wx, wy, playerX, playerY = ns.MarkerCore.PlayerWorld()
    if not mapID then
        for _, pin in pairs(miniPins) do pin:Hide() end
        return
    end

    local halfW, halfH = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
    if halfW <= 0 or halfH <= 0 then return end

    local viewRadius = ViewRadius()
    local rotate = RotateEnabled()
    local facing = rotate and GetPlayerFacing() or nil
    if Sealed(facing) then facing = nil end
    local worldYNorth = ns.MarkerMath.WorldYIncreasesNorth(mapID)

    -- 同一张地图直接用地图归一化坐标 + 地图世界尺寸来算，避免 world x 方向、
    -- 跨地图缩放等问题；小地图只显示当前地图上的标记。
    local mapW, mapH
    if C_Map and C_Map.GetMapWorldSize then
        local ok, w, h = pcall(C_Map.GetMapWorldSize, mapID)
        if ok and w and h and w > 0 and h > 0 and not Sealed(w) and not Sealed(h) then
            mapW, mapH = w, h
        end
    end

    local live = {}
    for _, marker in ipairs(markers) do
        live[marker.id] = true
        local pin = miniPins[marker.id]
        local sx, sy, dist, onEdge

        if marker.uiMapID == mapID and mapW and playerX and playerY and marker.x and marker.y then
            -- 地图 x 向东、y 向南；WoW UI 的屏幕 y 正方向是“上”
            local east = (marker.x - playerX) * mapW
            local north = (playerY - marker.y) * mapH
            dist = math.sqrt(east * east + north * north)
            sx = east / viewRadius * halfW
            sy = north / viewRadius * halfH
            if rotate and facing then
                local c, s = math.cos(facing), math.sin(facing)
                sx, sy = sx * c - sy * s, sx * s + sy * c
            end
            local edge = math.sqrt((sx / halfW) ^ 2 + (sy / halfH) ^ 2)
            onEdge = edge > 1
            if onEdge then
                -- 留 15% 边距，避免大图标被圆形小地图边缘裁掉
                local k = 0.85 / edge
                sx, sy = sx * k, sy * k
            end
        elseif marker.uiMapID == mapID and marker.wx and marker.wy then
            -- 没有 GetMapWorldSize 时退回 world 坐标
            sx, sy, dist, onEdge = ns.MarkerMath.Project(
                wx, wy, marker.wx, marker.wy,
                viewRadius, halfW, halfH, worldYNorth, rotate, facing)
            if onEdge then
                local k = 0.85
                sx, sy = sx * k, sy * k
            end
        end

        if sx then
            if not pin then
                pin = CreateMiniPin(marker)
                miniPins[marker.id] = pin
            end
            pin.marker = marker
            pin.distance = dist
            if pin.distText then
                pin.distText:SetText(dist and string.format("%.0f", dist) or "")
            end
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
            pin:SetAlpha(onEdge and 0.55 or 1)
            pin:Show()
        elseif pin then
            pin:Hide()
        end
    end

    for id, pin in pairs(miniPins) do
        if not live[id] then pin:Hide() end
    end
end

function ns.MarkersUI.RefreshMinimap()
    UpdateMiniPins()
end

function ns.MarkersUI.Refresh()
    if ns.MarkersUI.RefreshWorld then ns.MarkersUI.RefreshWorld() end
    if ns.MarkersUI.RefreshMinimap then ns.MarkersUI.RefreshMinimap() end
end

-- 标记变化后延迟一拍刷新，避免连续添加时重复建框
local refreshTimer
function ns.MarkersUI.ScheduleRefresh(delay)
    if refreshTimer then refreshTimer:Cancel() end
    refreshTimer = C_Timer.NewTimer(delay or 0.05, function()
        refreshTimer = nil
        ns.MarkersUI.Refresh()
    end)
end

-- 自动记录地图几何原始值：出问题时不用手动 /daniel diag
local function LogMapState(tag)
    if not ns.Log then return end
    local mapID, continentID, px, py = ns.MarkerCore.PlayerWorld()
    local info = mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID) or nil
    local wmMapID, canvasW, canvasH
    if WorldMapFrame and WorldMapFrame.GetMapID then
        local ok, v = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
        wmMapID = ok and v or nil
    end
    if WorldMapFrame and WorldMapFrame.GetCanvas then
        local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
        if ok and canvas then
            local okW, w = pcall(canvas.GetWidth, canvas)
            local okH, h = pcall(canvas.GetHeight, canvas)
            canvasW = okW and w or nil
            canvasH = okH and h or nil
        end
    end
    ns.Log(tag, {
        mapID = mapID,
        zone = info and info.name or nil,
        continentID = continentID,
        playerMapX = px, playerMapY = py,
        worldMapID = wmMapID,
        canvasW = canvasW, canvasH = canvasH,
        minimapZoom = Minimap and Minimap.GetZoom and Minimap:GetZoom(),
        viewRadius = C_Minimap and C_Minimap.GetViewRadius and select(2, pcall(C_Minimap.GetViewRadius)),
        rotateMinimap = GetCVar and GetCVar("rotateMinimap"),
    })
end

local eventFrame = CreateFrame("Frame")
SafeRegister(eventFrame, "ADDON_LOADED")
SafeRegister(eventFrame, "PLAYER_ENTERING_WORLD")
SafeRegister(eventFrame, "ZONE_CHANGED")
SafeRegister(eventFrame, "ZONE_CHANGED_NEW_AREA")
SafeRegister(eventFrame, "WORLD_MAP_OPEN")
SafeRegister(eventFrame, "WORLD_MAP_CLOSE")
SafeRegister(eventFrame, "WORLD_MAP_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        -- WorldMapFrame 可能由 Blizzard_WorldMap 按需加载，每次插件加载都试一次
        ns.MarkersUI.HookWorldMap()
        if arg1 ~= addonName then return end
    end
    if event == "WORLD_MAP_OPEN" then
        ns.MarkersUI.ScheduleRefresh(0.1)
        C_Timer.After(0.2, function() LogMapState("map.open") end)
    elseif event == "WORLD_MAP_UPDATE" then
        ns.MarkersUI.ScheduleRefresh(0)
    elseif event == "WORLD_MAP_CLOSE" then
        return
    else
        ns.MarkersUI.ScheduleRefresh(0.2)
        C_Timer.After(0.5, function() LogMapState("map.enter") end)
    end
end)

-- 世界地图切图时也刷新（WorldMapFrame 可能按需加载）
function ns.MarkersUI.HookWorldMap()
    if _G.__DanielWorldMapHooked then return end
    if not (WorldMapFrame and WorldMapFrame.SetMapID) then return end
    _G.__DanielWorldMapHooked = true
    pcall(hooksecurefunc, WorldMapFrame, "SetMapID", function()
        ns.MarkersUI.ScheduleRefresh(0.05)
    end)
    ns.MarkersUI.ScheduleRefresh(0.2)
end

-- 小地图每 0.1 秒重算一次；玩家移动不可能用事件驱动
local accum = 0
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(self, elapsed)
    accum = accum + elapsed
    if accum < 0.1 then return end
    accum = 0
    UpdateMiniPins()
end)
