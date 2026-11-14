local addonName, ns = ... -- luacheck: ignore addonName
local L, select = ns.L, select

local Style = {}
ns.Style = Style
_G.EasyAuctionStyle = Style

local function color(hex)
    return {
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255,
    }
end

local function mix(first, second, ratio)
    return {
        first[1] * (1 - ratio) + second[1] * ratio,
        first[2] * (1 - ratio) + second[2] * ratio,
        first[3] * (1 - ratio) + second[3] * ratio,
    }
end

-- 秘密值防护：职业色来自 UnitClass 身份信息，只用于显示，任何异常都退回静态配色。
local function known(value)
    return not issecretvalue or not issecretvalue(value)
end

local function palette(bg, panel, line, text, muted, accent, gold, tip)
    local p = { bg = color(bg), panel = color(panel), line = color(line), text = color(text),
        muted = color(muted), accent = color(accent), gold = color(gold), tip = color(tip) }
    p.plot = color(bg); p.input = mix(p.plot, p.panel, 0.42)
    p.button = mix(p.plot, p.panel, 0.70); p.buttonActive = mix(p.panel, p.accent, 0.28)
    p.buttonHover = mix(p.panel, p.accent, 0.42); p.selected = mix(p.panel, p.accent, 0.22)
    p.buttonText = mix(p.text, p.tip, 0.35); p.buttonTextActive = p.accent
    p.buttonTextDisabled = p.muted; p.grid = mix(p.plot, p.line, 0.72); p.stripe = { 1, 1, 1 }
    p.stripeAlt = { 1, 1, 1 }
    p.bull = { 0.25, 0.86, 0.48 }; p.bear = { 0.96, 0.30, 0.34 }; p.neutral = { p.muted[1], p.muted[2], p.muted[3] }
    p.danger = p.bear; p.dangerBg = mix(p.bg, p.danger, 0.24)
    p.warning = { 0.96, 0.68, 0.16 }
    return p
end

Style.Palettes = {
    blizzard = palette("17120D", "282018", "B58A42", "FFF7E6", "D6C5A5", "FFD34E", "FFB83D", "A9D9FF"),
    terminal = palette("0B1116", "121D24", "2C5260", "E9FBFF", "9CC0C8", "42E8C4", "FFD166", "A7E8FF"),
    legacy260 = palette("1A1A21", "262433", "B399FF", "FFFFFF", "B8B8C8", "FFD200", "FFD200", "AEDDFF"),
    lunar = palette("101621", "1B2638", "496B9A", "F2F6FF", "B2C5E5", "72B7FF", "FFD166", "C5E1FF"),
    amber = palette("1F1A14", "292116", "6B4F2A", "FFF7ED", "D6B891", "F59E0B", "FFD166", "FBBF24"),
    jade = palette("0D1A16", "152C24", "3D876D", "EDFFF7", "A7D9C4", "45E0A5", "FFD166", "B7F5DA"),
    violet = palette("171225", "251B3A", "7658A8", "FBF7FF", "CBBBEA", "D19BFF", "FFD166", "E4C7FF"),
    fan = palette("211620", "2B1B2A", "8B5A7C", "FFF1F7", "E8AFC9", "F472B6", "FFD166", "F9A8D4"),
    class = palette("171719", "202024", "3F3F46", "F4F4F5", "A1A1AA", "06B6D4", "FFD166", "38BDF8"),
}
local paletteNames = {
    blizzard = L["暴雪风格"], terminal = L["交易终端"], legacy260 = L["经典主题"], lunar = L["月光驿站"],
    amber = L["赤金拍行"], jade = L["翡翠账本"], violet = L["奥术紫晶"], fan = L["粉丝少女"],
    class = L["职业徽记"],
}
for key, value in pairs(Style.Palettes) do value.key, value.name = key, paletteNames[key] end
Style.PaletteOrder = { "blizzard", "terminal", "legacy260", "lunar", "amber", "jade", "violet", "fan", "class" }
Style.DefaultPalette = "blizzard"
Style.ClassPalette = { key = "class", name = paletteNames.class }
Style.listeners = {}

function Style:NormalizePaletteKey(key)
    if self.Palettes[key] then return key end
    return self.DefaultPalette
end

function Style:ClassColor()
    if type(_G.UnitClass) ~= "function" then return nil end
    local classFile = select(2,_G.UnitClass("player"))
    if type(classFile) ~= "string" or not known(classFile) then return nil end
    local custom = _G.CUSTOM_CLASS_COLORS
    local colors = (custom and custom[classFile]) or (_G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classFile])
    if type(colors) ~= "table" then return nil end
    local r, g, b = colors.r or colors[1], colors.g or colors[2], colors.b or colors[3]
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number"
        or not (known(r) and known(g) and known(b)) then return nil end
    return r, g, b
end

function Style:BuildClassPalette()
    local base = self.Palettes.class
    local theme = self.ClassPalette
    for key, value in pairs(base) do
        if type(value) == "table" then
            theme[key] = theme[key] or {}
            theme[key][1], theme[key][2], theme[key][3] = value[1], value[2], value[3]
        else
            theme[key] = value
        end
    end
    local r, g, b = self:ClassColor()
    if r then
        theme.accent[1], theme.accent[2], theme.accent[3] = r, g, b
        theme.buttonActive[1], theme.buttonActive[2], theme.buttonActive[3] = r, g, b
        theme.buttonHover[1], theme.buttonHover[2], theme.buttonHover[3] = r, g, b
        theme.buttonTextActive[1], theme.buttonTextActive[2], theme.buttonTextActive[3] = r, g, b
        theme.selected[1], theme.selected[2], theme.selected[3] = r, g, b
    end
    return theme
end

function Style:Palette()
    local db = ns.Store and ns.Store.GetDB and ns.Store.GetDB()
    local key = self:NormalizePaletteKey(db and db.uiPalette)
    if key == "class" then return self:BuildClassPalette() end
    return self.Palettes[key]
end

function Style:OnTheme(callback)
    self.listeners[#self.listeners + 1] = callback
    callback(self:Palette())
end

function Style:ApplyTheme()
    local currentPalette = self:Palette()
    for index = 1, #self.listeners do self.listeners[index](currentPalette) end
    if ns.UI and ns.UI.ApplyTheme then ns.UI.ApplyTheme(currentPalette) end
end

function Style:SetPalette(key, silent)
    local db = ns.Store and ns.Store.GetDB and ns.Store.GetDB()
    if not db then return nil end
    db.uiPalette = self:NormalizePaletteKey(key)
    local currentPalette = self:Palette()
    self:ApplyTheme()
    if ns.UI and ns.UI.Refresh and ns.UI.IsShown and ns.UI.IsShown() then ns.UI.Refresh() end
    if not silent and print then
        print("|cff" .. string.format("%02X%02X%02X", currentPalette.accent[1] * 255,
            currentPalette.accent[2] * 255, currentPalette.accent[3] * 255)
            .. "[EasyAuction]|r " .. L["界面主题"] .. "：" .. currentPalette.name)
    end
    return currentPalette
end

function Style:CyclePalette()
    local current = self:NormalizePaletteKey(ns.Store.GetDB().uiPalette)
    for index = 1, #self.PaletteOrder do
        if self.PaletteOrder[index] == current then
            return self:SetPalette(self.PaletteOrder[index % #self.PaletteOrder + 1])
        end
    end
    return self:SetPalette(self.PaletteOrder[1])
end

function Style:TooltipColors()
    local currentPalette = self:Palette()
    return currentPalette.text, currentPalette.muted, currentPalette.tip, currentPalette.accent, currentPalette.gold
end

return Style
