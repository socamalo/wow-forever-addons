-- 已停用（2026-11-11）：用户要求去掉距离提示/音效，本文件不再由 TOC 加载。
-- 猎人距离提示：显示目标距离，35 码内绿、超出红
-- 数据来源分两级：
--   1) UnitDistanceSquared 给出精确码数（若客户端开放且不是秘密值）
--   2) C_Spell.IsSpellInRange / IsSpellInRange 用自动射击判断是否在 35 码内
local addonName, ns = ...

local AUTO_SHOT_ID = 75
local UPDATE_INTERVAL = 0.15
-- 经典旧世猎人远程最小射程 8 码，近于这个距离打不出去
local MIN_RANGE = 8

local widget
local ticker

local function IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

local function SafeExists(unit)
    local ok, res = pcall(UnitExists, unit)
    if not ok then return false end
    if IsSecret(res) then return nil end
    return res and true or false
end

local function GetYards(unit)
    if type(UnitDistanceSquared) ~= "function" then return nil end
    local ok, sq = pcall(UnitDistanceSquared, unit)
    if not ok or sq == nil or IsSecret(sq) or type(sq) ~= "number" then return nil end
    if sq < 0 then return nil end
    return math.sqrt(sq)
end

local function AutoShotName()
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, AUTO_SHOT_ID)
        if ok and type(info) == "table" and info.name then return info.name end
    end
    return nil
end

local function GetInRange(unit)
    if C_Spell and C_Spell.IsSpellInRange then
        local ok, res = pcall(C_Spell.IsSpellInRange, AUTO_SHOT_ID, unit)
        if ok and res ~= nil and not IsSecret(res) then
            return res == 1 or res == true
        end
    end
    local name = AutoShotName()
    if name and type(IsSpellInRange) == "function" then
        local ok, res = pcall(IsSpellInRange, name, unit)
        if ok and res ~= nil and not IsSecret(res) then
            return res == 1 or res == true
        end
    end
    return nil
end

local function CreateWidget()
    local f = CreateFrame("Frame", "DanielAddonRange", UIParent)
    f:SetSize(120, 44)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        if ns.db then
            ns.db.rangePoint = { point, relPoint, x, y }
        end
    end)

    local text = f:CreateFontString(nil, "OVERLAY")
    text:SetPoint("CENTER", f, "CENTER", 0, 0)
    text:SetFontObject(_G["GameFontNormalHuge"] or GameFontNormalLarge)
    text:SetShadowColor(0, 0, 0, 1)
    text:SetShadowOffset(1, -1)
    f.text = text

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("BOTTOM", f, "BOTTOM", 0, -2)
    sub:SetText("8–35 码")
    f.sub = sub

    return f
end

local function RestorePosition()
    local p = ns.db and ns.db.rangePoint
    if p and p[1] then
        widget:ClearAllPoints()
        widget:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    end
end

local function Update()
    if not widget then return end
    if not (ns.db and ns.db.showRange) then
        widget:Hide()
        return
    end
    widget:Show()

    local exists = SafeExists("target")
    if exists ~= true then
        widget.text:SetText(exists == nil and "??" or "无目标")
        widget.text:SetTextColor(0.6, 0.6, 0.6)
        return
    end

    local limit = (ns.db and ns.db.rangeYards) or 35

    local yards = GetYards("target")
    if yards then
        widget.text:SetText(string.format("%.0f码", yards))
        if yards < MIN_RANGE then
            -- 猎人盲区：太近也射不出去
            widget.text:SetTextColor(1.0, 0.6, 0.1)
        elseif yards <= limit then
            widget.text:SetTextColor(0.2, 1.0, 0.2)
        else
            widget.text:SetTextColor(1.0, 0.25, 0.25)
        end
        return
    end

    local inRange = GetInRange("target")
    if inRange ~= nil then
        widget.text:SetText(inRange and (limit .. "内") or (limit .. "外"))
        if inRange then
            widget.text:SetTextColor(0.2, 1.0, 0.2)
        else
            widget.text:SetTextColor(1.0, 0.25, 0.25)
        end
        return
    end

    widget.text:SetText("??")
    widget.text:SetTextColor(0.8, 0.8, 0.3)
end

local function EnsureWidget()
    if not widget then
        widget = CreateWidget()
        RestorePosition()
    end
    if not ticker then
        ticker = C_Timer.NewTicker(UPDATE_INTERVAL, Update)
    end
end

function ns.ToggleRange()
    if not ns.db then return end
    ns.db.showRange = not ns.db.showRange
    if ns.db.showRange then
        EnsureWidget()
        Update()
    elseif widget then
        widget:Hide()
    end
    ns.Print("距离提示：" .. (ns.db.showRange and "开" or "关"))
    if ns.RefreshPanel then ns.RefreshPanel() end
end

-- 进游戏自检：把这条输出发我，就能确认客户端给了哪种距离数据
function ns.RangeProbe()
    ns.Print("UnitDistanceSquared: " .. type(UnitDistanceSquared))
    if type(UnitDistanceSquared) == "function" then
        local ok, sq = pcall(UnitDistanceSquared, "target")
        if not ok then
            ns.Print("  调用失败（可能没有目标）")
        elseif IsSecret(sq) then
            ns.Print("  返回秘密值，不能做比较")
        elseif type(sq) == "number" then
            ns.Print("  平方=" .. tostring(sq) .. " → " .. string.format("%.1f", math.sqrt(sq)) .. " 码")
        else
            ns.Print("  返回 " .. tostring(sq))
        end
    end
    ns.Print("C_Spell.IsSpellInRange: " .. tostring(C_Spell and C_Spell.IsSpellInRange ~= nil))
    ns.Print("IsSpellInRange: " .. type(IsSpellInRange))
    ns.Print("自动射击名称: " .. tostring(AutoShotName()))
    local inRange = GetInRange("target")
    ns.Print("自动射击判定: " .. tostring(inRange))
    ns.Print("UnitExists 返回: " .. tostring(SafeExists("target")))
end

local frame = CreateFrame("Frame")

function frame:PLAYER_LOGIN()
    if not (ns.db and ns.db.showRange) then return end
    EnsureWidget()
    Update()
end

function frame:PLAYER_TARGET_CHANGED()
    if widget and ns.db and ns.db.showRange then
        Update()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if self[event] then self[event](self, ...) end
end)
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
