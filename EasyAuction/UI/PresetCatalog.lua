local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, GameTooltip = CreateFrame, GameTooltip
local ipairs, pairs, tostring, unpack = ipairs, pairs, tostring, unpack
local min, max, floor = math.min, math.max, math.floor
local L = ns.L
local W = ns.Widgets
local C = W.color

-- Deliberately use a separate set of item illustrations, not another addon's tab atlases.
local illustrations = {
    shopping="INV_Misc_Note_05", consumables="INV_Alchemy_Elixir_05",
    gems="INV_Misc_Gem_Pearl_04", enchants="INV_Enchant_DustDream", crafting="INV_Hammer_20",
    buffs="Spell_Holy_WordFortitude", food="INV_Misc_Food_65", potions="INV_Potion_161",
    other="INV_Misc_Bag_10", diamonds="INV_Misc_Gem_Diamond_03", bloodstones="INV_Misc_Gem_Bloodstone_03",
    high_gems="INV_Misc_Gem_Emerald_02", low_gems="INV_Misc_Gem_Opal_01",
    enchant_weapon="INV_Sword_27", enchant_helm="INV_Helmet_25", enchant_shoulder="INV_Shoulder_14",
    enchant_chest="INV_Chest_Cloth_17", enchant_legs="INV_Pants_06", enchant_boots="INV_Boots_05",
    enchant_gloves="INV_Gauntlets_06", enchant_ring="INV_Jewelry_Ring_36", enchant_tool="INV_Misc_Wrench_01",
    missive_gear="INV_Scroll_08", missive_tool="INV_Misc_Book_09", embellishments="INV_Misc_ArmorKit_17",
    engineering_gears="Trade_Engineering",
}

function W.CatalogIcon(id)
    return "Interface\\Icons\\" .. (illustrations[id] or illustrations.shopping)
end

local function FilterIcon(button,mode)
    button.icon=CreateFrame("Frame",nil,button)
    button.icon:SetSize(12,12); button.icon:SetPoint("LEFT",7,0)
    button.label:ClearAllPoints(); button.label:SetPoint("LEFT",24,0); button.label:SetWidth(38)
    if mode=="all" then
        for index=1,4 do
            local tile=button.icon:CreateTexture(nil,"ARTWORK")
            tile:SetSize(4,4); tile:SetPoint("TOPLEFT",((index-1)%2)*7,-floor((index-1)/2)*7)
            tile:SetColorTexture(unpack(C.accent))
        end
    else
        local edge,tip=mode=="highest" and 3 or 9,mode=="highest" and 9 or 3
        for index=1,2 do
            local line=button.icon:CreateLine(nil,"ARTWORK")
            line:SetThickness(2); line:SetColorTexture(unpack(mode=="highest" and C.gold or C.muted))
            line:SetStartPoint("BOTTOMLEFT",button.icon,index==1 and 0 or 12,edge)
            line:SetEndPoint("BOTTOMLEFT",button.icon,6,tip)
        end
    end
end

-- Only visible icons are instantiated. Variants remain separate exact item IDs;
-- opening the catalog never adds a purchasing target.
function W.PresetCatalog(parent, x, y, width, choose)
    local panel = W.Surface(parent, x, y, width, 260)
    panel.groups, panel.icons, panel.offset = {}, {}, 0
    panel.qualityMode, panel.qualityModes, panel.filters = "all", {}, {}
    panel.title = W.Text(panel, "", 164, -10, 12, C.gold, width - 380)
    panel.help = W.Text(panel, L["左键加入当前清单 · 右键查价 / 直接购买"], 164, -29, 10, C.muted, width - 180)
    panel.empty = W.Text(panel, L["此版本的预设物品待补充"], 164, -112, 12, C.muted, width - 180)
    local groupScroll = CreateFrame("ScrollFrame", nil, panel)
    groupScroll:SetPoint("TOPLEFT", 4, -4); groupScroll:SetSize(148, 248)
    local groupContent = CreateFrame("Frame", nil, groupScroll)
    groupContent:SetSize(148, 248); groupScroll:SetScrollChild(groupContent)
    panel.groupScroll, panel.groupContent = groupScroll, groupContent
    groupScroll:EnableMouseWheel(true)
    groupScroll:SetScript("OnMouseWheel", function(self, delta)
        panel.groupOffset = min(max(0, (panel.groupOffset or 0) - delta * 54),
            max(0, groupContent:GetHeight() - 248))
        self:SetVerticalScroll(panel.groupOffset)
    end)
    local columns, capacity = 9, 36
    for index, choice in ipairs({{"all",L["全部"],L["全部品质"]},{"highest",L["最高"],L["最高品质"]},{"lowest",L["最低"],L["最低品质"]}}) do
        local button = W.Button(panel, choice[2], width - 218 + (index - 1) * 70, -5, 68, function()
            panel:SetQualityMode(choice[1])
        end)
        FilterIcon(button,choice[1])
        button.active=button:CreateTexture(nil,"OVERLAY")
        button.active:SetColorTexture(unpack(C.accent)); button.active:SetSize(40,2)
        button.active:SetPoint("BOTTOM",0,0)
        W.Hint(button, choice[3], L["按同物品的制造品质筛选；无品质或资料待加载的规格保留。"])
        panel.filters[choice[1]]=button
    end
    local step = (width - 170) / columns
    for index = 1, capacity do
        local icon = W.Icon(panel, 172 + ((index - 1) % columns) * step,
            -50 - floor((index - 1) / columns) * 44, 28, function(entry, button)
                choose(panel.targetList, entry, button)
            end)
        icon.tag = W.Text(icon, "", -14, -30, 10, C.text, 56)
        icon.tag:SetJustifyH("CENTER")
        icon.added=icon:CreateTexture(nil,"OVERLAY")
        icon.added:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        icon.added:SetSize(16,16); icon.added:SetPoint("BOTTOMRIGHT",3,-3)
        icon:HookScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:AddLine("ID " .. tostring(self.entry.itemKey.itemID), 0.59, 0.65, 0.66)
            local included = panel.targetList and panel.targetList.items[ns.Store.Key(self.entry.itemKey)]
            GameTooltip:AddLine(included and L["已在当前清单 · 左键查看补货，右键直接购买"]
                or L["左键加入当前清单 · 右键查价 / 直接购买"], 0.39, 0.85, 0.70, true)
            GameTooltip:Show()
        end)
        panel.icons[index] = icon
    end
    panel.page = W.Text(panel, "", 202, -240, 10, C.muted, width - 248)
    panel.page:SetJustifyH("CENTER")
    panel.prev = W.Button(panel, "‹", 164, -232, 24, function()
        panel.offset = panel.offset - capacity; panel:Render()
    end)
    panel.next = W.Button(panel, "›", width - 28, -232, 24, function()
        panel.offset = panel.offset + capacity; panel:Render()
    end)
    function panel:Render()
        local definition = self.definition
        local group = definition and definition.groups[self.groupIndex or 1]
        local entries = ns.Presets.GroupEntries(self.owner,self.groupIndex or 1,self.qualityMode)
        self.entries = entries
        for mode, button in pairs(self.filters) do
            local active = self.qualityMode == mode
            button.label:SetTextColor(unpack(active and C.buttonTextActive or C.buttonText))
            button.active:SetShown(active)
            W.SetButtonState(button,active,false)
        end
        self.title:SetText(group and L[group.name or ""] or L["预设目录"])
        self.offset = min(max(0, self.offset), max(0, #entries - capacity))
        self.empty:SetShown(#entries == 0)
        for index, icon in ipairs(self.icons) do
            local entry = entries[self.offset + index]
            icon:SetShown(entry ~= nil)
            if entry then
                local included = self.targetList and self.targetList.items[ns.Store.Key(entry.itemKey)] ~= nil
                icon:SetEntry(entry, nil, false)
                icon.selected:SetShown(included)
                icon.count:SetText(""); icon.added:SetShown(included==true)
                icon.tag:SetText(L[entry.tag or ""])
                icon.tag:SetTextColor(unpack(included and C.accent or C.text))
            else
                icon.entry = nil
            end
        end
        for index, button in ipairs(self.groups) do
            local active = index == self.groupIndex
            W.SetButtonState(button,active,false)
            button.label:SetTextColor(unpack(active and C.buttonTextActive or C.buttonText))
        end
        self.page:SetText(#entries > 0 and (tostring(self.offset + 1) .. "–" ..
            min(self.offset + capacity, #entries) .. " / " .. #entries .. L[" 个品质规格"]) or "")
        W.Enabled(self.prev, self.offset > 0)
        W.Enabled(self.next, self.offset + capacity < #entries)
    end
    function panel:SetQualityMode(mode)
        if not self.filters[mode] then return end
        self.qualityMode, self.offset = mode, 0
        if self.owner then self.qualityModes[self.owner.presetID] = mode end
        self:Render()
    end
    function panel:Set(owner,targetList)
        local definition = ns.Presets and ns.Presets.Definition(owner)
        if self.owner ~= owner or self.definition ~= definition then
            self.groupIndex, self.offset, self.groupOffset = 1, 0, 0
            self.qualityMode = self.qualityModes[owner.presetID] or "all"
            self.groupScroll:SetVerticalScroll(0)
        end
        self.owner, self.definition, self.targetList = owner, definition, targetList
        local groups = definition and definition.groups or {}
        for index, group in ipairs(groups) do
            local button = self.groups[index]
            if not button then
                button = W.Button(self.groupContent, "", 0, -(index - 1) * 29, 144, function()
                    self.groupIndex, self.offset = index, 0; self:Render()
                end)
                self.groups[index] = button
            end
            button.label:SetText(L[group.name or ""])
            W.ButtonIcon(button,W.CatalogIcon(group.id))
        end
        for index, button in ipairs(self.groups) do button:SetShown(index <= #groups) end
        self.groupContent:SetHeight(max(248, #groups * 29))
        self:Render()
    end
    return panel
end
