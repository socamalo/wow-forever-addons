-- luacheck: read globals Minimap GetCursorPosition GetMinimapShape
local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, GameTooltip = CreateFrame, GameTooltip
local GetCursorPosition = GetCursorPosition
local tonumber, type = tonumber, type
local cos, sin, rad, deg, atan2, abs, max, huge = math.cos, math.sin, math.rad, math.deg, math.atan2, math.abs, math.max, math.huge
local L = ns.L
local Entry = {}
ns.Minimap = Entry
local button, minimap, angle = nil, nil, 225

local function Settings()
    local db = ns.Store.GetDB()
    if type(db.settings) ~= "table" then db.settings = {} end
    return db.settings
end

local function Position()
    local x, y = cos(rad(angle)), sin(rad(angle))
    if _G.GetMinimapShape and _G.GetMinimapShape() == "SQUARE" then
        local edge = max(abs(x), abs(y))
        x, y = x / edge, y / edge
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER", x * (minimap:GetWidth() / 2 + 3), y * (minimap:GetHeight() / 2 + 3))
end

local function Drag()
    local centerX, centerY = minimap:GetCenter()
    if not centerX or not centerY then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = minimap:GetEffectiveScale()
    local x, y = cursorX / scale - centerX, cursorY / scale - centerY
    if x == 0 and y == 0 then return end
    angle = deg(atan2(y, x)) % 360
    Position()
end

local function StopDrag()
    if not button.dragging then return end
    button.dragging = false
    button:SetScript("OnUpdate", nil)
    Settings().minimapAngle = angle
end

function Entry.Init()
    if button then return button end
    minimap = _G.Minimap
    if not minimap then return nil end
    local saved = tonumber(Settings().minimapAngle)
    if saved and saved == saved and saved ~= huge and saved ~= -huge then angle = saved % 360 end
    button = CreateFrame("Button", "EasyAuctionMinimapButton", minimap)
    Entry.button = button
    button:SetSize(32, 32)
    button:SetFrameLevel(minimap:GetFrameLevel() + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(25, 25)
    background:SetPoint("CENTER")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\EasyAuction\\media\\EasyAuction.png")
    icon:SetSize(22, 22)
    icon:SetPoint("CENTER")
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    button:SetScript("OnClick", function(self, mouseButton)
        if self.dragging or not ns.UI or not ns.UI.Open then return end
        if mouseButton == "LeftButton" then ns.UI.Open("assistant")
        elseif mouseButton == "RightButton" then ns.UI.Open("settings") end
    end)
    button:SetScript("OnEnter", function(self)
        if self.dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EasyAuction", 1, 0.82, 0)
        GameTooltip:AddDoubleLine(L["左键"], L["专业助手"], 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["右键"], L["设置"], 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddLine(L["拖动调整位置"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", Drag)
    end)
    button:SetScript("OnDragStop", StopDrag)
    button:SetScript("OnHide", StopDrag)
    minimap:HookScript("OnSizeChanged", Position)
    Position()
    return button
end
