-- 背包里的升级装备高亮：绿色光晕 + 绿色箭头 + tooltip 比较说明
-- 纯展示层：只给 Blizzard 的物品按钮加自己的贴图，不改任何受保护属性。
local addonName, ns = ...

local upgradeSet = {}   -- [bag * 1000 + slot] = GetUpgrades() 里的一条记录
local timer
local hooked

local function HideOverlay(button)
    if button.DanielUpgradeGlow then button.DanielUpgradeGlow:Hide() end
    if button.DanielUpgradeArrow then button.DanielUpgradeArrow:Hide() end
end

local function EnsureOverlay(button)
    if button.DanielUpgradeGlow then return end

    -- 复用客户端自带图集：物品格模板里就有 bags-glow-green / bags-greenarrow
    local glow = button:CreateTexture(nil, "OVERLAY", nil, 6)
    glow:SetAtlas("bags-glow-green", true)
    glow:SetBlendMode("ADD")
    glow:SetPoint("CENTER")
    glow:Hide()
    button.DanielUpgradeGlow = glow

    local arrow = button:CreateTexture(nil, "OVERLAY", nil, 7)
    arrow:SetAtlas("bags-greenarrow")
    arrow:SetSize(16, 16)
    arrow:SetPoint("TOPLEFT", 1, -1)
    arrow:Hide()
    button.DanielUpgradeArrow = arrow
end

local function ApplyToButton(button)
    if not button or not button.GetBagID or not button.GetID then return end
    local up = upgradeSet[button:GetBagID() * 1000 + button:GetID()]
    if up then
        EnsureOverlay(button)
        button.DanielUpgradeGlow:Show()
        button.DanielUpgradeArrow:Show()
    else
        HideOverlay(button)
    end
end

-- 遍历所有打开的背包框（含合并背包）。物品按钮是池化对象，没有全局名字，
-- 只能从 frame:EnumerateValidItems() 拿。
local function ForEachButton(fn)
    local seen = {}
    local function visit(frame)
        if not frame or seen[frame] then return end
        seen[frame] = true
        if frame.IsShown and frame:IsShown() and frame.EnumerateValidItems then
            pcall(function()
                for _, button in frame:EnumerateValidItems() do
                    fn(button)
                end
            end)
        end
    end

    if type(ContainerFrameUtil_EnumerateContainerFrames) == "function" then
        for _, frame in ContainerFrameUtil_EnumerateContainerFrames() do
            visit(frame)
        end
    elseif ContainerFrames then
        for _, frame in ipairs(ContainerFrames) do
            visit(frame)
        end
    end
    visit(_G.ContainerFrameCombinedBags)
end

local function Rebuild()
    wipe(upgradeSet)
    if not ns.db or not ns.db.highlight or not ns.GetUpgrades then
        return false
    end
    for _, up in ipairs(ns.GetUpgrades()) do
        upgradeSet[up.src] = up
    end
    return true
end

function ns.GetUpgradeAt(bag, slot)
    if not bag or not slot then return nil end
    return upgradeSet[bag * 1000 + slot]
end

function ns.RefreshHighlights()
    timer = nil
    Rebuild()
    ForEachButton(ApplyToButton)
end

function ns.ScheduleHighlight(delay)
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(delay or 0.35, ns.RefreshHighlights)
end

function ns.SetHighlight(on)
    if not ns.db then return end
    ns.db.highlight = on and true or false
    ns.RefreshHighlights()
end

-- tooltip 里补一行「升级」，鼠标悬停就能看到替换前后的对比
local function OnTooltipSetItem(tooltip)
    if not ns.db or not ns.db.highlight then return end
    local owner = tooltip:GetOwner()
    if not owner or not owner.GetBagID or not owner.GetID then return end

    local up = upgradeSet[owner:GetBagID() * 1000 + owner:GetID()]
    if not up then return end

    local line = "|cff1eff00↑ 升级|r " .. up.name
    if up.curName then
        line = line .. " （替换 " .. up.curName .. "）"
    end
    tooltip:AddLine(line, 1, 0.82, 0)

    if up.dps and up.curDps then
        tooltip:AddLine(string.format("秒伤 %.1f → %.1f", up.dps, up.curDps), 0.8, 0.8, 0.8)
    elseif up.ilvl and up.curIlvl and up.ilvl ~= up.curIlvl then
        tooltip:AddLine("装等 " .. up.ilvl .. " → " .. up.curIlvl, 0.8, 0.8, 0.8)
    end
    if up.bindType == 2 then
        tooltip:AddLine("装备后绑定：自动换装会跳过，点面板按钮手动换", 1, 0.3, 0.3)
    end
    tooltip:Show()
end

-- Blizzard 重画背包格时把我们的高亮补回去（混合背包的 UpdateItems 是复制过去的，
-- 所以每个 mixin 表都要单独 hook）
local function HookContainerUpdates()
    if hooked then return end
    hooked = true
    local mixins = {
        ContainerFrameMixin,
        ContainerFrameExtendedSlotPack,
        ContainerFrameBackpackMixin,
        ContainerFrameCombinedBagsMixin,
    }
    for _, mixin in ipairs(mixins) do
        if type(mixin) == "table" and mixin.UpdateItems then
            pcall(hooksecurefunc, mixin, "UpdateItems", function()
                ns.ScheduleHighlight(0.05)
            end)
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BAG_NEW_ITEMS_UPDATED")
frame:RegisterEvent("ITEM_LOCK_CHANGED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        HookContainerUpdates()
    end
    if not ns.db or not ns.db.highlight then return end
    ns.ScheduleHighlight(0.4)
end)

if GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
end
