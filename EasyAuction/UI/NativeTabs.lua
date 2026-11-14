-- Original native AH integration; keep Blizzard's tab registry untouched.
-- luacheck: read globals PanelTemplates_SelectTab PanelTemplates_DeselectTab PanelTemplates_TabResize
local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, hooksecurefunc, C_Timer = CreateFrame, hooksecurefunc, C_Timer
local PanelTemplates_SelectTab, PanelTemplates_DeselectTab = PanelTemplates_SelectTab, PanelTemplates_DeselectTab
local PanelTemplates_TabResize, ipairs, pairs = PanelTemplates_TabResize, ipairs, pairs
local L = ns.L
local Native = {}
ns.NativeTabs = Native
local host, content, activeTab
local buttons, labels = {}, {buy = L["闪购"], sell = L["标签：闪卖"], assistant = L["专业助手"], settings = L["设置"], about = L["关于"]}
local tabOrder = {"buy", "sell", "assistant", "settings", "about"}
local orderedButtons = {}
local icons = {buy="INV_Misc_Bag_10", sell="INV_Misc_Coin_01", assistant="INV_Misc_Book_09",
    settings="Trade_Engineering", about="INV_Misc_Note_01"}
local displayMode = {"EasyAuctionPage"}
local selectionRevision = 0

local function LayoutTabs()
    local nativeTabs = host.Tabs or {}
    local first = buttons.buy
    first:ClearAllPoints()
    if #nativeTabs > 0 then
        first:SetPoint("TOPLEFT", nativeTabs[#nativeTabs], "TOPRIGHT", 3, 0)
    else
        first:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 20, -28)
    end
    if ns.TabSkins then Native.skin = ns.TabSkins.Apply(host, orderedButtons) end
end

local function ClearSelection()
    activeTab = nil
    if ns.UI and ns.UI.HideDetails then ns.UI.HideDetails() end
    if content then content:Hide() end
    for key, button in pairs(buttons) do
        if key then
            PanelTemplates_DeselectTab(button)
            if ns.TabSkins then ns.TabSkins.Select(button, false) end
        end
    end
end

local function DefaultOnOpen()
    LayoutTabs()
    local revision = selectionRevision
    C_Timer.After(0, function()
        if host and host:IsShown() and ns.ready and ns.open and revision == selectionRevision then
            LayoutTabs()
            Native.Activate("buy")
        end
    end)
    -- Skin modules can finish their own deferred auction-house setup after ours.
    for index, delay in ipairs({0.1, 0.5, 1}) do
        C_Timer.After(delay, function()
            if host and host:IsShown() then LayoutTabs() end
        end)
    end
end

function Native.Attach(contentFrame)
    local auctionHouse = _G.AuctionHouseFrame
    if not auctionHouse or not contentFrame then return false end
    if host == auctionHouse then
        if content ~= contentFrame then return false end
        content:SetParent(host)
        LayoutTabs()
        return true
    end
    host, content = auctionHouse, contentFrame
    content:SetParent(host)
    host.EasyAuctionPage = content
    content:Hide()
    -- The inherited template registers itself in parent.Tabs during creation.
    -- Isolate that registry so Blizzard's display-mode indexes stay unchanged.
    local tabBar = CreateFrame("Frame", nil, host)
    tabBar:SetAllPoints(host)
    -- Keep all custom tabs on the native row, directly after Blizzard's tabs.
    local previous
    for index, key in ipairs(tabOrder) do
        local button = CreateFrame("Button", "EasyAuctionNativeTab" .. index, tabBar, "AuctionHouseFrameTabTemplate")
        buttons[key] = button
        orderedButtons[index] = button
        -- Inline textures survive providers that replace the original FontString.
        button:SetText("|TInterface\\Icons\\" .. icons[key] .. ":14:14:0:0|t " .. labels[key])
        PanelTemplates_TabResize(button, 8, nil, 52)
        if previous then
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 3, 0)
        end
        button:SetScript("OnClick", function() Native.Activate(key) end)
        PanelTemplates_DeselectTab(button)
        previous = button
    end
    LayoutTabs()
    hooksecurefunc(host, "SetDisplayMode", function(self, mode)
        if mode ~= displayMode then ClearSelection() end
    end)
    host:HookScript("OnShow", DefaultOnOpen)
    host:HookScript("OnHide", function()
        selectionRevision = selectionRevision + 1
        ClearSelection()
    end)
    if host:IsShown() then DefaultOnOpen() end
    return true
end

function Native.Activate(key)
    if key=="price" then
        key="assistant"
        if ns.ProfessionAssistant then ns.ProfessionAssistant.SelectTab("prices") end
    end
    if not host or not labels[key] or not host:IsShown() then return false end
    selectionRevision = selectionRevision + 1
    host:SetDisplayMode(displayMode)
    for index, button in ipairs(host.Tabs or {}) do
        if index then PanelTemplates_DeselectTab(button) end
    end
    for tab, button in pairs(buttons) do
        if tab == key then PanelTemplates_SelectTab(button) else PanelTemplates_DeselectTab(button) end
        if ns.TabSkins then ns.TabSkins.Select(button, tab == key) end
    end
    activeTab = key
    host:SetTitle("EasyAuction · " .. labels[key])
    content:Show()
    ns.UI.SelectTab(key)
    return true
end

function Native.IsActive()
    return host ~= nil and host:IsShown() and activeTab ~= nil and host:GetDisplayMode() == displayMode
end

local skinEvents = CreateFrame("Frame")
skinEvents:RegisterEvent("ADDON_LOADED")
skinEvents:SetScript("OnEvent", function()
    if host and host:IsShown() then C_Timer.After(0, LayoutTabs) end
end)
