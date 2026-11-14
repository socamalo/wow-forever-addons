-- Small integrations with Blizzard profession and auction notifications.
-- This module observes UI state only; it never crafts or submits auctions.
-- luacheck: read globals ProfessionsCraftingPageMixin ERR_AUCTION_SOLD_S SOUNDKIT PlaySound C_TradeSkillUI
local addonName, ns = ... -- luacheck: ignore addonName
local PlaySound, GetMoneyString, GetTime = PlaySound, GetMoneyString, GetTime
local C_TradeSkillUI, Enum, SOUNDKIT = C_TradeSkillUI, Enum, SOUNDKIT
local hooksecurefunc, pcall, type, tostring = hooksecurefunc, pcall, type, tostring
local issecretvalue = issecretvalue
local floor = math.floor
local L = ns.L
local E = {}; ns.ProfessionEnhancements = E
local hooked, valueLabel, lastSaleAt, lastSaleKey = false, nil, nil, nil

local function setting(key)
    return ns.ProfessionSettings and ns.ProfessionSettings.Get(key) == true
end

local function hideValue()
    if valueLabel then valueLabel:Hide() end
end

local function recipeID(info)
    if type(info) ~= "table" then return nil end
    return info.recipeID or info.recipeSpellID
end

local function showValue(page, info)
    hideValue()
    if not setting("showValueInProfessionWindow") or not C_TradeSkillUI then return end
    local id = recipeID(info)
    if not id then return end
    local okQualities, qualities = pcall(C_TradeSkillUI.GetRecipeQualityItemIDs, id)
    if okQualities and type(qualities) == "table" and #qualities > 1 then return end
    local okOutput, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, id)
    if not okOutput or type(output) ~= "table" or not output.itemID then return end
    local price = ns.Prices and ns.Prices.GetValue(output.itemID)
    if not price then return end
    local form = page and page.SchematicForm
    if not form or type(form.CreateFontString) ~= "function" then return end
    if not valueLabel then
        valueLabel = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valueLabel:SetPoint("TOPRIGHT", form, "TOPRIGHT", -34, -46)
        local color=ns.Widgets and ns.Widgets.color and ns.Widgets.color.accent or {0.47,0.82,0.72}
        valueLabel:SetTextColor(color[1],color[2],color[3])
    end
    valueLabel:SetText(L["市场估值："] .. GetMoneyString(floor(price), true))
    valueLabel:Show()
end

local function installHook()
    if hooked or type(ProfessionsCraftingPageMixin) ~= "table"
        or type(ProfessionsCraftingPageMixin.SelectRecipe) ~= "function" then return false end
    hooksecurefunc(ProfessionsCraftingPageMixin, "SelectRecipe", showValue)
    hooked = true
    return true
end

local function soldPattern()
    if type(ERR_AUCTION_SOLD_S) ~= "string" then return nil end
    local placeholder, percent = "\001", "\002"
    local pattern = ERR_AUCTION_SOLD_S:gsub("%%%%", percent)
    pattern = pattern:gsub("%%[%d%$%.%-%+ #]*s", placeholder)
    pattern = pattern:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub(placeholder, ".+")
    pattern = pattern:gsub(percent, "%%")
    return "^" .. pattern .. "$"
end

local chatSalePattern = soldPattern()
local function notifySale(key)
    if not setting("saleAlarm") then return end
    local current = type(GetTime) == "function" and GetTime() or ns.Now()
    key = tostring(key or "sale")
    if lastSaleAt and current >= lastSaleAt and (current - lastSaleAt <= 1
        or current - lastSaleAt <= 2 and key == lastSaleKey) then return end
    lastSaleAt, lastSaleKey = current, key
    if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then
        PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND, "Master")
    end
end

function E.Init()
    installHook()
end

function E.OnEvent(event, notification, text, auctionID)
    -- Chat and notification payloads may be secret even when type() reports string/number.
    if issecretvalue and issecretvalue(notification) then return end
    if event == "ADDON_LOADED" and notification == "Blizzard_Professions" then
        installHook()
        return
    end
    local sold = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold
    if (event == "AUCTION_HOUSE_SHOW_NOTIFICATION" or event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION")
        and sold ~= nil and notification == sold then
        if issecretvalue then
            if issecretvalue(text) then text=nil end
            if issecretvalue(auctionID) then auctionID=nil end
        end
        notifySale(auctionID or text or notification)
    elseif event == "CHAT_MSG_SYSTEM" and chatSalePattern and type(notification) == "string"
        and notification:match(chatSalePattern) then
        notifySale(notification)
    end
end
