local addonName, ns = ...
local CreateFrame, GetTime, GetServerTime = CreateFrame, GetTime, GetServerTime
local GetRealmName, GetCurrentRegion = GetRealmName, GetCurrentRegion
local GetBuildInfo = GetBuildInfo
local time, date, tostring, type, pairs, ipairs = time, date, tostring, type, pairs, ipairs
local C_Timer, C_AddOns, print = C_Timer, C_AddOns, print
local L = ns.L

ns.Now = GetServerTime or time
ns.Date = date
ns.name = addonName
ns.version = "20261007.5"
_G.EasyAuction12 = ns
local refreshPending
function ns.Emit(event, data)
    ns.lastEvent, ns.lastData = event, data
    if event == "market:error" then ns.lastError = data end
    if ns.ItemTooltip and ns.ItemTooltip.Refresh then ns.ItemTooltip.Refresh() end
    if type(ns.AuctionatorCompat) == "table" and ns.AuctionatorCompat.Flush then
        ns.AuctionatorCompat.Flush()
    end
    if ns.UI and not refreshPending then
        refreshPending = true
        C_Timer.After(0, function()
            refreshPending = nil
            ns.UI.Refresh()
        end)
    end
end

function ns.Snapshot()
    local count = 0
    if ns.Store then
        for key in pairs(ns.Store.GetItems()) do
            if key then count = count + 1 end
        end
    end
    return { version = ns.version, ready = ns.ready == true, items = count,
        market = ns.Market and ns.Market.Snapshot(),
        ui = ns.UI and ns.UI.Snapshot(), uptime = GetTime() }
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("TRACKED_RECIPE_UPDATE")
for index, event in ipairs({
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASED",
    "COMMODITY_PURCHASE_FAILED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PRICE_UNAVAILABLE", "AUCTION_HOUSE_PURCHASE_COMPLETED",
    "REPLICATE_ITEM_LIST_UPDATE", "AUCTION_HOUSE_AUCTION_CREATED",
    "AUCTION_HOUSE_POST_ERROR", "AUCTION_HOUSE_SHOW_ERROR", "AUCTION_HOUSE_BROWSE_FAILURE", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
    "ITEM_DATA_LOAD_RESULT", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "AUCTION_MULTISELL_START", "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE",
}) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(self, event, ...)
    local arg = ...
    if event == "ADDON_LOADED" and arg == addonName then
        if type(_G.EasyAuctionDB12) ~= "table" then _G.EasyAuctionDB12 = {} end
        local scope = tostring(GetCurrentRegion()) .. ":" .. GetRealmName()
        -- 拍卖行情按服务器+阵营隔离；同服务器同阵营的角色共用同一份数据。
        local faction = UnitFactionGroup and UnitFactionGroup("player") -- luacheck: globals UnitFactionGroup
        scope = scope .. ":" .. (type(faction) == "string" and faction ~= "" and faction or "Neutral")
        local buildInfo = type(GetBuildInfo) == "function" and { GetBuildInfo() } or {}
        if ns.Presets and ns.Presets.ResolveVersion(buildInfo[1], buildInfo[4]) == "1.60.1" then
            scope = scope .. ":1.60.1"
        end
        ns.Store.Init(_G.EasyAuctionDB12, scope, tostring(GetCurrentRegion()) .. ":" .. GetRealmName())
        local db = ns.Store.GetDB()
        db.uiPalette = ns.Style and ns.Style:NormalizePaletteKey(db.uiPalette) or db.uiPalette
        if ns.Style then ns.Style:ApplyTheme() end
        if ns.Presets then ns.Presets.Init(buildInfo[1], buildInfo[4]) end
        if ns.ProfessionSettings then ns.ProfessionSettings.Init() end
        if ns.Professions then ns.Professions.Init() end
        ns.UI.Init()
        if ns.Minimap then ns.Minimap.Init() end
        if ns.ItemTooltip then ns.ItemTooltip.Init() end
        if ns.RecipeTracker and ns.RecipeTracker.Init then ns.RecipeTracker.Init() end
        if ns.ProfessionEnhancements then ns.ProfessionEnhancements.Init() end
        if ns.Professions and ns.Professions.Events then
            for index, professionEvent in ipairs(ns.Professions.Events) do
                pcall(self.RegisterEvent, self, professionEvent)
            end
        end
        pcall(self.RegisterEvent, self, "AUCTION_HOUSE_SHOW_NOTIFICATION")
        pcall(self.RegisterEvent, self, "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION")
        pcall(self.RegisterEvent, self, "CHAT_MSG_SYSTEM")
        ns.ready = true
    elseif ns.ready then
        if event == "AUCTION_HOUSE_SHOW" then
            ns.UI.Close()
            ns.open = true
        elseif event == "AUCTION_HOUSE_CLOSED" then
            ns.open = false
            ns.UI.Close()
        end
        if event == "ITEM_DATA_LOAD_RESULT" and ns.ViewModel and ns.ViewModel.InvalidateItem then
            ns.ViewModel.InvalidateItem(arg)
        end
        ns.Market.OnEvent(event, ...)
        if ns.RecipeTracker and ns.RecipeTracker.OnEvent then ns.RecipeTracker.OnEvent(event, ...) end
        if ns.Professions then ns.Professions.OnEvent(event, ...) end
        if ns.ProfessionPosting then ns.ProfessionPosting.OnEvent(event, ...) end
        if ns.ProfessionEnhancements then ns.ProfessionEnhancements.OnEvent(event, ...) end
        if event == "AUCTION_HOUSE_SHOW" then
            C_Timer.After(0, function()
                if not ns.open then return end
                ns.UI.Open("buy")
                if ns.ProfessionSettings and ns.ProfessionSettings.Get("autoScan")
                    and ns.Prices and ns.Prices.NeedsScan and ns.Prices.NeedsScan(
                        ns.ProfessionSettings.Get("staleAfterSeconds")) then ns.Market.Scan() end
            end)
        end
        ns.Emit(event, arg)
    end
end)

SLASH_EASYAUCTION121 = "/ea"
SLASH_EASYAUCTION122 = "/easyauction"
SlashCmdList.EASYAUCTION12 = function(command)
    if not ns.ready then print(L["EasyAuction 尚未初始化"]); return end
    if command == "debug" then
        print("EasyAuction", ns.version, L["已加载"], C_AddOns.IsAddOnLoaded(addonName))
    else
        ns.UI.Open()
    end
end
