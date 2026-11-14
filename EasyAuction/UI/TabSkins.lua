-- Original bridges to the active auction-house skin; provider code stays with its addon.
local addonName, ns = ... -- luacheck: ignore addonName
local type, ipairs, pcall, setmetatable = type, ipairs, pcall, setmetatable
local globals = _G
local Skins = {}
ns.TabSkins = Skins
local states = setmetatable({}, {__mode = "k"})

local function Ellesmere(native)
    local eui = globals.EllesmereUI
    local module = eui and eui._ModuleNS and eui._ModuleNS.EllesmereUIBlizzardSkin
    local skin = module and module.WSkin
    if not (skin and type(skin.Tab) == "function" and type(skin.GetFFD) == "function"
        and type(skin.UpdateAllTabs) == "function" and type(skin.NormalizeTabRow) == "function"
        and type(eui.GetBlizzWindowStyle) == "function") then return end
    if eui.GetBlizzWindowStyle("auctionhouse") == "off" or not skin.GetFFD(native).bg then return end
    return {name = "EllesmereUI", skin = skin, pixels = eui.PP}
end

local function Elv(native)
    local engine = globals.ElvUI and globals.ElvUI[1]
    local settings = engine and engine.private and engine.private.skins and engine.private.skins.blizzard
    if not (settings and settings.enable and settings.auctionhouse and native.backdrop
        and type(engine.GetModule) == "function") then return end
    local ok, skin = pcall(engine.GetModule, engine, "Skins", true)
    if ok and skin and type(skin.HandleTab) == "function" then
        return {name = "ElvUI", skin = skin, gap = -5}
    end
end

local function NDui(native)
    local provider = globals.NDui
    local base, config = provider and provider[1], provider and provider[2]
    local settings = config and config.db and config.db.Skins
    if base and type(base.ReskinTab) == "function" and settings and settings.BlizzardSkins and native.bg then
        -- Native NDui tabs retain Blizzard's -15 anchor and have 8px inset backdrops.
        return {name = "NDui", skin = base, gap = -15}
    end
end

local function UpdateSelection(button, state)
    local provider = state.provider
    if provider and provider.name == "EllesmereUI" then
        local data = provider.skin.GetFFD(button)
        data.selOverride = state.selected == true
        if data.blizLabel then data.blizLabel:SetTextColor(0, 0, 0, 0) end
        provider.skin.UpdateAllTabs()
    end
end

function Skins.Select(button, selected)
    local state = states[button] or {}
    states[button] = state
    state.selected = selected == true
    UpdateSelection(button, state)
end

-- Call after native layout and again after a deferred AH show: skin addons may load later.
-- A provider owns a tab for this UI session; theme enable/disable changes require /reload.
function Skins.Apply(host, ownTabs)
    local nativeTabs = host and host.Tabs
    local lastNative = nativeTabs and nativeTabs[#nativeTabs]
    if not lastNative or not ownTabs or #ownTabs == 0 then return "native" end
    local skinReference = host.BuyTab or nativeTabs[1]
    local existing = states[ownTabs[1]]
    local provider = existing and existing.provider or Ellesmere(skinReference) or Elv(skinReference) or NDui(skinReference)
    if not provider then return "native" end
    for index, button in ipairs(ownTabs) do
        local state = states[button] or {}
        states[button] = state
        if not state.provider then
            if provider.name == "EllesmereUI" then
                provider.skin.Tab(button)
            elseif provider.name == "ElvUI" then
                provider.skin:HandleTab(button)
            elseif not button.bg then
                provider.skin.ReskinTab(button)
            end
            state.provider = provider
        end
        UpdateSelection(button, state)
        -- Keep all positions owned by EasyAuction, never re-anchor native tabs.
        button:ClearAllPoints()
        button:SetPoint("LEFT", ownTabs[index - 1] or lastNative, "RIGHT", provider.gap or 1, 0)
    end
    if provider.name == "EllesmereUI" then
        provider.skin.NormalizeTabRow(ownTabs)
        local first = ownTabs[1]
        local pixels, scale = provider.pixels, first:GetEffectiveScale()
        local gap = pixels and pixels.mult or 1
        if pixels and pixels.perfect and scale and scale > 0.1 and scale < 10 then gap = pixels.perfect / scale end
        first:ClearAllPoints()
        first:SetPoint("LEFT", lastNative, "RIGHT", gap, 0)
    end
    return provider.name
end
