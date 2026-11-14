local addonName, ns = ... -- luacheck: ignore addonName
-- luacheck: globals C_TradeSkillUI
local CreateFrame, GameTooltip, STANDARD_TEXT_FONT, UIParent = CreateFrame, GameTooltip, STANDARD_TEXT_FONT, UIParent
local C_Item, C_AuctionHouse, C_TradeSkillUI = C_Item, C_AuctionHouse, C_TradeSkillUI
local C_Texture = C_Texture -- luacheck: ignore C_Texture
local GetTime=GetTime
local unpack, tonumber, tostring, ipairs, date, GetMoneyString = unpack, tonumber, tostring, ipairs, date, GetMoneyString
local min, max, floor, huge = math.min, math.max, math.floor, math.huge
local sin = math.sin
local format = string.format
local L=ns.L
local W = {}; ns.Widgets = W
W.color = {bg={0.045,0.058,0.069}, panel={0.073,0.087,0.100}, line={0.17,0.20,0.22},
    text={0.91,0.93,0.92}, muted={0.59,0.65,0.66}, accent={0.39,0.85,0.70}, gold={0.88,0.77,0.53},
    tip={0.70,0.86,0.90}, input={0.035,0.045,0.052}, plot={0.045,0.058,0.069},
    button={0.073,0.087,0.100}, buttonActive={0.12,0.29,0.25}, buttonHover={0.15,0.35,0.30},
    buttonText={0.80,0.96,0.91}, buttonTextActive={0.45,1.00,0.80}, buttonTextDisabled={0.45,0.55,0.55},
    selected={0.39,0.85,0.70}, grid={0.17,0.20,0.22}, stripe={1,1,1}, stripeAlt={1,1,1},
    bull={0.25,0.86,0.48}, bear={0.96,0.30,0.34}, neutral={0.59,0.65,0.66},
    danger={0.95,0.35,0.35}, dangerBg={0.25,0.11,0.12}, warning={0.96,0.68,0.16}}
local C = W.color
local themed = {}

local function copyColor(target, source)
    if not target then target = {} end
    if source then target[1], target[2], target[3] = source[1], source[2], source[3] end
    return target
end

local function applyTheme(palette)
    for key, source in pairs(palette) do
        if type(source) == "table" and C[key] then copyColor(C[key], source) end
    end
end

local function registerTheme(object, callback)
    local entry = {object=object, callback=callback}
    themed[#themed+1] = entry
    callback(object)
    return entry
end

function W.ApplyTheme()
    for index=#themed,1,-1 do
        local entry=themed[index]
        if entry.object then entry.callback(entry.object) else table.remove(themed,index) end
    end
end

function W.GetPaletteColor(role)
    return C[role] or C.text
end

function W.SetTextRole(label, role)
    if not label then return end
    label.__EAThemeRole=role
    if label.__EAThemeEntry then label.__EAThemeEntry.callback(label) end
end

function W.ThemeTexture(texture, role, alpha)
    if not texture then return texture end
    registerTheme(texture,function(region)
        local color=C[role] or C.text
        region:SetColorTexture(color[1],color[2],color[3],alpha or 1)
    end)
    return texture
end

function W.ThemeBackdrop(frame, background, border, backgroundAlpha, borderAlpha)
    if not frame then return frame end
    registerTheme(frame,function(panel)
        local bg=C[background or "bg"] or C.bg
        local edge=C[border or "line"] or C.line
        panel:SetBackdropColor(bg[1],bg[2],bg[3],backgroundAlpha or 1)
        panel:SetBackdropBorderColor(edge[1],edge[2],edge[3],borderAlpha or 1)
    end)
    return frame
end

if ns.Style then ns.Style:OnTheme(applyTheme) end
local requested, metadataCache={},{ }
local dropdowns={}

local function MetadataKey(itemKey)
    if type(itemKey)~="table" then return tostring(itemKey or "") end
    return tostring(itemKey.itemID or 0)..":"..tostring(itemKey.itemLevel or 0)..":"..
        tostring(itemKey.itemSuffix or 0)..":"..tostring(itemKey.battlePetSpeciesID or 0)
end

local function colorRole(value)
    for _, role in ipairs({"bg","panel","line","text","muted","accent","gold","tip","input","plot",
        "button","buttonActive","buttonHover","buttonText","buttonTextActive","buttonTextDisabled",
        "selected","grid","stripe","stripeAlt","bull","bear","neutral","danger","dangerBg","warning"}) do
        if value == C[role] then return role end
    end
end

function W.Text(parent, text, x, y, size, color, width)
    local label=parent:CreateFontString(nil,"OVERLAY","GameFontNormal")
    local initial=color or C.text; local role=colorRole(initial)
    label:SetFont(STANDARD_TEXT_FONT,size or 12,""); label:SetPoint("TOPLEFT",x,y)
    label:SetTextColor(unpack(initial)); label:SetJustifyH("LEFT")
    if width then label:SetWidth(width); label:SetWordWrap(false) end
    label:SetText(text or "")
    if role then
        label.__EAThemeRole=role
        label.__EAThemeEntry=registerTheme(label,function(fontString)
            local current=C[fontString.__EAThemeRole] or C.text
            fontString:SetTextColor(unpack(current))
        end)
    end
    return label
end

function W.Surface(parent,x,y,width,height,role)
    local panel=CreateFrame("Frame",nil,parent,"BackdropTemplate")
    panel:SetPoint("TOPLEFT",x,y); panel:SetSize(width,height)
    panel:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    panel.__EAThemeRole=role or "bg"
    W.ThemeBackdrop(panel,panel.__EAThemeRole,"line")
    return panel
end

function W.Hint(widget,title,body)
    widget:SetScript("OnEnter",function(self)
        local style = ns.Style
        local tip, accent = C.muted, C.accent
        if style then
            tip = select(3, style:TooltipColors())
            accent = select(4, style:TooltipColors())
        end
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetText(title,accent[1],accent[2],accent[3])
        if body then GameTooltip:AddLine(body,tip[1],tip[2],tip[3],true) end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave",function() GameTooltip:Hide() end)
end

function W.Button(parent,text,x,y,width,click,primary,height)
    local button=CreateFrame("Button",nil,parent,"BackdropTemplate")
    button:SetPoint("TOPLEFT",x,y); button:SetSize(width,height or 28)
    button:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"})
    button.__EAThemeActive=primary==true
    button.label=W.Text(button,text,0,0,12,primary and C.buttonTextActive or C.buttonText)
    button.label:ClearAllPoints(); button.label:SetPoint("CENTER")
    button.label:SetWidth(width-8); button.label:SetWordWrap(false)
    button.label:SetJustifyH("CENTER")
    button:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    button:GetHighlightTexture():SetVertexColor(1,1,1,0.07)
    button.__EAThemeEntry=registerTheme(button,function(control)
        local active=control.__EAThemeActive==true
        local background=active and C.buttonActive or C.button
        local foreground=active and C.buttonTextActive or C.buttonText
        if control.__EAThemeDisabled then
            background=C.bg; foreground=C.buttonTextDisabled
        end
        control:SetBackdropColor(background[1],background[2],background[3],1)
        control:SetBackdropBorderColor((active and C.accent or C.line)[1],(active and C.accent or C.line)[2],
            (active and C.accent or C.line)[3],control.__EAThemeDisabled and 0.45 or 1)
        if control.label then control.label:SetTextColor(foreground[1],foreground[2],foreground[3],1) end
    end)
    button:SetScript("OnClick",click); return button
end

function W.SetButtonState(button, active, disabled)
    if not button then return end
    button.__EAThemeActive=active==true
    button.__EAThemeDisabled=disabled==true
    if button.__EAThemeEntry then button.__EAThemeEntry.callback(button) end
end

function W.Enabled(button,value)
    local enabled=value==true
    button:SetEnabled(enabled); button:SetAlpha(enabled and 1 or 0.35)
    W.SetButtonState(button,button.__EAThemeActive,not enabled)
end

-- 紧凑勾选行：只有 Button 支持 OnClick；普通 Frame 会报
-- "script type not supported by this object"（Workbench 过滤面板案例）。
function W.Check(parent,x,y,width,height)
    local button=CreateFrame("Button",nil,parent,"BackdropTemplate")
    button:SetPoint("TOPLEFT",x,y); button:SetSize(width,height or 20)
    button:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    button.label=W.Text(button,"",8,-3,11,C.buttonText,width-16)
    button.__EAThemeEntry=registerTheme(button,function(control)
        local background=control.__EAThemeChecked and C.selected or C.input
        local border=control.__EAThemeChecked and C.accent or C.line
        control:SetBackdropColor(background[1],background[2],background[3],1)
        control:SetBackdropBorderColor(border[1],border[2],border[3],1)
    end)
    function button:SetChecked(checked)
        self.__EAThemeChecked=checked==true
        if self.__EAThemeEntry then self.__EAThemeEntry.callback(self) end
    end
    return button
end

function W.ButtonIcon(button, texture)
    if not button.icon then
        button.icon=button:CreateTexture(nil,"ARTWORK")
        button.icon:SetSize(18,18); button.icon:SetPoint("LEFT",8,0)
        button.icon:SetTexCoord(0.08,0.92,0.08,0.92)
        button.label:ClearAllPoints(); button.label:SetPoint("LEFT",32,0)
        button.label:SetWidth(button:GetWidth()-38); button.label:SetJustifyH("LEFT")
    end
    button.icon:SetTexture(texture)
end

function W.Edit(parent,x,y,width,value)
    local box=CreateFrame("EditBox",nil,parent,"BackdropTemplate")
    box:SetPoint("TOPLEFT",x,y); box:SetSize(width,28)
    box:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    box.__EAThemeEntry=registerTheme(box,function(control)
        local border=control:HasFocus() and C.accent or C.line
        control:SetBackdropColor(C.input[1],C.input[2],C.input[3],1)
        control:SetBackdropBorderColor(border[1],border[2],border[3],1)
        control:SetTextColor(C.text[1],C.text[2],C.text[3],1)
    end)
    box:SetFont(STANDARD_TEXT_FONT,12,""); box:SetTextInsets(8,8,0,0)
    box:SetAutoFocus(false); box:SetMaxLetters(160); box:SetText(value or "")
    box:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
    box:HookScript("OnEditFocusGained",function(self) if self.__EAThemeEntry then self.__EAThemeEntry.callback(self) end end)
    box:HookScript("OnEditFocusLost",function(self) if self.__EAThemeEntry then self.__EAThemeEntry.callback(self) end end)
    return box
end

local function OptionValue(option)
    return option.value~=nil and option.value or option[1]
end

local function OptionText(option)
    return option.text or option.label or option[2] or tostring(OptionValue(option) or "")
end

-- Compact menu control matching the original profession assistant. Opening the
-- menu never mutates the setting; a value is committed only by an entry click.
function W.Dropdown(parent,x,y,width,options,onSelect,opts)
    opts=opts or {}
    local control=CreateFrame("Button",nil,parent,"BackdropTemplate")
    control:SetPoint("TOPLEFT",x,y); control:SetSize(width,opts.height or 22)
    control:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    control.__EAThemeEntry=registerTheme(control,function(dropdown)
        dropdown:SetBackdropColor(C.input[1],C.input[2],C.input[3],1)
        dropdown:SetBackdropBorderColor(C.line[1],C.line[2],C.line[3],1)
        if dropdown.label then dropdown.label:SetTextColor(C.buttonText[1],C.buttonText[2],C.buttonText[3],1) end
        if dropdown.arrow then dropdown.arrow:SetTextColor(C.muted[1],C.muted[2],C.muted[3],1) end
    end)
    control.label=W.Text(control,"",7,0,opts.fontSize or 11,C.buttonText,width-28)
    control.label:ClearAllPoints(); control.label:SetPoint("LEFT",7,0); control.label:SetJustifyH("LEFT")
    control.arrow=W.Text(control,"v",0,0,10,C.muted,16)
    control.arrow:ClearAllPoints(); control.arrow:SetPoint("RIGHT",-5,0); control.arrow:SetJustifyH("CENTER")
    control.menu=W.Surface(UIParent,0,0,width,8,"panel")
    control.menu:SetFrameStrata("TOOLTIP"); control.menu:SetFrameLevel(200)
    control.menu.entries={}; control.menu:SetClampedToScreen(true); control.menu:Hide()
    if control.GetEffectiveScale and control.menu.SetScale then control.menu:SetScale(control:GetEffectiveScale() or 1) end
    control.menu.__EAThemeEntry=registerTheme(control.menu,function(menu)
        menu:SetBackdropColor(C.panel[1],C.panel[2],C.panel[3],1)
        menu:SetBackdropBorderColor(C.line[1],C.line[2],C.line[3],1)
    end)
    dropdowns[#dropdowns+1]=control

    local function CloseOthers()
        for index,dropdown in ipairs(dropdowns) do
            if dropdown~=control then dropdown.menu:Hide() end
        end
    end

    function control:SetOptions(values)
        self.options=values or {}
        for index,option in ipairs(self.options) do
            local entry=self.menu.entries[index]
            if not entry then
                entry=W.Button(self.menu,"",4,-4-(index-1)*20,width-8,function(button)
                    local selected=button.option
                    self.value=OptionValue(selected); self:UpdateLabel(); self.menu:Hide()
                    if onSelect then onSelect(self.value,selected) end
                end)
                entry:SetSize(width-8,20); entry.label:SetFont(STANDARD_TEXT_FONT,opts.fontSize or 11,"")
                entry.label:ClearAllPoints(); entry.label:SetPoint("LEFT",6,0); entry.label:SetJustifyH("LEFT")
                self.menu.entries[index]=entry
            end
            entry.option=option
            -- opts.swatch(option) 返回 RGB 时在条目左侧渲染色块（主题选择等场景）。
            local rgb=opts.swatch and opts.swatch(option)
            if rgb then
                if not entry.swatch then
                    entry.swatch=entry:CreateTexture(nil,"ARTWORK")
                    entry.swatch:SetSize(10,10); entry.swatch:SetPoint("LEFT",7,0)
                end
                entry.swatch:SetColorTexture(rgb[1],rgb[2],rgb[3],1); entry.swatch:SetShown(true)
                entry.label:ClearAllPoints(); entry.label:SetPoint("LEFT",23,0); entry.label:SetWidth(width-31)
            elseif entry.swatch then
                entry.swatch:SetShown(false); entry.label:ClearAllPoints(); entry.label:SetPoint("LEFT",6,0)
                entry.label:SetWidth(width-16)
            end
            entry.label:SetText(OptionText(option)); entry:SetShown(true)
        end
        for index=#self.options+1,#self.menu.entries do self.menu.entries[index]:Hide() end
        self.menu:SetSize(width,max(8,#self.options*20+8)); self:UpdateLabel()
    end
    function control:UpdateLabel()
        local label=opts.placeholder or ""
        for index,option in ipairs(self.options or {}) do
            if OptionValue(option)==self.value then label=OptionText(option); break end
        end
        self.label:SetText(label)
    end
    function control:SetValue(value) self.value=value; self:UpdateLabel() end
    function control:GetValue() return self.value end
    control:SetScript("OnClick",function(self)
        if self.menu:IsShown() then self.menu:Hide(); return end
        CloseOthers(); self.menu:ClearAllPoints(); self.menu:SetPoint("TOPLEFT",self,"BOTTOMLEFT",0,-2); self.menu:Show()
    end)
    control:SetScript("OnHide",function(self) self.menu:Hide() end)
    control:SetOptions(options)
    return control
end

-- Original price-library picker: a single control with two independently scrollable columns.
function W.CategoryDropdown(parent,x,y,width,onSelect)
    local control=W.Dropdown(parent,x,y,width,{},nil,{fontSize=12})
    local menu=control.menu
    local fallback="Interface\\Icons\\INV_Misc_QuestionMark"
    menu:SetClampedToScreen(true); menu:EnableMouse(true)
    menu.primary={}; menu.secondary={}; menu.offset=0; menu.childOffset=0
    W.ButtonIcon(control,fallback); control.label:SetWidth(width-58)
    local divider=W.Surface(menu,211,-8,1,300)
    divider:SetBackdropColor(unpack(C.line))
    menu.help=W.Text(menu,L["选择一级分类"],228,-18,11,C.muted,180)

    local function setCategoryIcon(texture,category)
        if category and category.atlas then
            texture:SetAtlas(category.atlas,false)
            texture:SetTexCoord(0,1,0,1)
        else
            texture:SetTexture(category and category.icon or fallback)
            texture:SetTexCoord(0.08,0.92,0.08,0.92)
        end
    end

    function control:UpdateLabel()
        local selected=self.selected
        self.label:SetText(selected and selected.name or L["全部分类"])
        if self.icon then setCategoryIcon(self.icon,selected) end
    end
    function control:RenderCategories()
        local categories=self.categories or {}
        local children=menu.current and menu.current.children or {}
        menu.offset=min(max(0,menu.offset),max(0,#categories-10))
        menu.childOffset=min(max(0,menu.childOffset),max(0,#children-10))
        for index=1,10 do
            local primary,secondary=menu.primary[index],menu.secondary[index]
            local category,child=categories[menu.offset+index],children[menu.childOffset+index]
            primary.category=category; primary:SetShown(category~=nil)
            secondary.category=child; secondary:SetShown(child~=nil)
            if category then
                primary.label:SetText(category.name)
                setCategoryIcon(primary.icon,category)
                primary.arrow:SetShown(#(category.children or {})>0)
                primary.label:SetTextColor(unpack(menu.current==category and C.accent or C.text))
            end
            if child then
                secondary.label:SetText(child.name); setCategoryIcon(secondary.icon,child)
                secondary.label:SetTextColor(unpack(self.selected==child and C.accent or C.text))
            end
        end
        menu.help:SetShown(#children==0)
        menu:SetSize(424,316)
    end
    function control:SetCategories(categories,category,child)
        self.categories=categories; self.selected=child or category or categories[1]
        local currentID=menu.current and menu.current.id
        menu.current=nil
        for index,entry in ipairs(categories) do -- luacheck: ignore index
            if entry.id==currentID then menu.current=entry end
        end
        self:UpdateLabel(); self:RenderCategories()
    end
    for index=1,10 do
        local primary=W.Button(menu,"",8,-8-(index-1)*30,196,function(button)
            local category=button.category
            menu.current=category; menu.childOffset=0
            onSelect(category.id,"all")
            control:RenderCategories()
            if #(category.children or {})==0 then menu:Hide() end
        end)
        local secondary=W.Button(menu,"",220,-8-(index-1)*30,196,function(button)
            onSelect(menu.current.id,button.category.id); menu:Hide()
        end)
        for position,button in ipairs({primary,secondary}) do -- luacheck: ignore position
            W.ButtonIcon(button,fallback); button.label:SetFont(STANDARD_TEXT_FONT,12,"")
            button.label:SetWidth(144)
        end
        primary.arrow=W.Text(primary,"›",0,0,14,C.muted,12)
        primary.arrow:ClearAllPoints(); primary.arrow:SetPoint("RIGHT",-6,0)
        menu.primary[index]=primary; menu.secondary[index]=secondary
    end
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel",function(self,delta)
        local inChildren=false
        for index,button in ipairs(self.secondary) do -- luacheck: ignore index
            if button:IsShown() and button:IsMouseOver() then inChildren=true; break end
        end
        if inChildren then self.childOffset=self.childOffset-delta*3
        else self.offset=self.offset-delta*3 end
        control:RenderCategories()
    end)
    control:HookScript("OnClick",function(self)
        if not menu:IsShown() then return end
        menu.offset=0; menu.childOffset=0; menu.current=nil
        for index,category in ipairs(self.categories or {}) do
            local selected=self.selected==category
            for childIndex,child in ipairs(category.children or {}) do
                if self.selected==child then selected=true; menu.childOffset=max(0,childIndex-10) end
            end
            if selected then menu.current=category; menu.offset=max(0,index-10); break end
        end
        self:RenderCategories()
    end)
    return control
end

function W.Checkbox(parent,label,x,y,width,value,onChange)
    local control=CreateFrame("Button",nil,parent)
    control:SetPoint("TOPLEFT",x,y); control:SetSize(width,18)
    control.box=W.Surface(control,0,-2,14,14,"input")
    control.mark=W.Text(control.box,"x",0,0,11,C.accent,14)
    control.mark:ClearAllPoints(); control.mark:SetPoint("CENTER",0,0); control.mark:SetJustifyH("CENTER")
    control.label=W.Text(control,label,20,-3,11,C.text,max(0,width-20))
    control:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    control:GetHighlightTexture():SetVertexColor(1,1,1,0.04)
    function control:SetChecked(checked)
        self.checked=checked==true; self.mark:SetShown(self.checked)
        self.box:SetBackdropBorderColor(unpack(self.checked and C.accent or C.line))
        self.mark:SetTextColor(unpack(self.checked and C.accent or C.muted))
    end
    function control:GetChecked() return self.checked==true end
    control:SetScript("OnClick",function(self)
        self:SetChecked(not self:GetChecked())
        if onChange then onChange(self:GetChecked()) end
    end)
    control:SetChecked(value)
    return control
end

local dropdownDismiss=CreateFrame("Frame",nil,UIParent)
dropdownDismiss:RegisterEvent("GLOBAL_MOUSE_DOWN")
dropdownDismiss:SetScript("OnEvent",function()
    for index,control in ipairs(dropdowns) do
        if control.menu:IsShown() and not control:IsMouseOver() and not control.menu:IsMouseOver() then control.menu:Hide() end
    end
end)

function W.MoneyEdit(parent,x,y,width,copper,silverOnly)
    local control=CreateFrame("Frame",nil,parent)
    width=min(240,max(180,width or 236))
    control:SetPoint("TOPLEFT",x,y); control:SetSize(width,28); control.fields={}
    local goldWidth=width-(silverOnly and 56 or 112)
    local parts={{"gold",0,goldWidth,"Gold",9},{"silver",goldWidth+6,50,"Silver",2}}
    if not silverOnly then parts[3]={"copper",goldWidth+62,50,"Copper",2} end
    for index,part in ipairs(parts) do
        local box=W.Edit(control,part[2],0,part[3],"0")
        box:SetNumeric(true); box:SetMaxLetters(part[5]); box:SetTextInsets(6,19,0,0)
        local coin=box:CreateTexture(nil,"OVERLAY"); coin:SetSize(12,12); coin:SetPoint("RIGHT",-4,0)
        coin:SetTexture("Interface\\MoneyFrame\\UI-"..part[4].."Icon")
        control.fields[part[1]]=box
        box:SetScript("OnEnterPressed",function(self) self:ClearFocus() end)
    end
    function control:SetCopper(value)
        if value==nil then
            for index,part in ipairs(parts) do self.fields[part[1]]:SetText("") end
            return
        end
        value=max(0,floor(tonumber(value) or 0))
        self.fields.gold:SetText(tostring(floor(value/10000)))
        self.fields.silver:SetText(tostring(floor(value/100)%100))
        if self.fields.copper then self.fields.copper:SetText(tostring(value%100)) end
    end
    function control:GetCopper()
        local total=0
        for index,part in ipairs(parts) do
            local key=part[1]
            local text=self.fields[key]:GetText()
            if text~="" and not text:match("^%d+$") then return nil end
            local value=tonumber(text) or 0
            if (index>1 and value>99) or (index==1 and value>999999999) then return nil end
            total=total+value*(index==1 and 10000 or index==2 and 100 or 1)
        end
        return total
    end
    function control:ClearFocus()
        for index,part in ipairs(parts) do self.fields[part[1]]:ClearFocus() end
    end
    control:SetCopper(copper)
    return control
end

function W.Metadata(entry)
    local key=entry.itemKey
    if not key then return {} end
    local cacheKey=MetadataKey(key); local cached=metadataCache[cacheKey]
    if cached and cached.result then return cached.result end
    if not cached then cached={}; metadataCache[cacheKey]=cached end
    local values=C_Item and C_Item.GetItemInfo and {C_Item.GetItemInfo(entry.link or key.itemID)} or {}
    local instant=C_Item and C_Item.GetItemInfoInstant and {C_Item.GetItemInfoInstant(key.itemID)} or {}
    local info=C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(key)
    local itemInfo=entry.link or key.itemID
    local qualityInfo=C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityInfo
        and C_TradeSkillUI.GetItemReagentQualityInfo(itemInfo)
    local reagentQuality=qualityInfo and qualityInfo.quality or (C_TradeSkillUI
        and C_TradeSkillUI.GetItemReagentQualityByItemInfo and C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemInfo))
    if not qualityInfo and C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityInfo then
        qualityInfo=C_TradeSkillUI.GetItemCraftedQualityInfo(itemInfo)
    end
    if not values[1] and C_Item and C_Item.RequestLoadItemDataByID then
        local now=GetTime()
        if not requested[key.itemID] or now-requested[key.itemID]>5 then
            requested[key.itemID]=now; C_Item.RequestLoadItemDataByID(key.itemID)
        end
    end
    local quality=entry.quality or values[3] or (info and info.quality) or cached.quality
    local icon=entry.icon or values[10] or instant[5] or (info and info.iconFileID) or cached.icon or 134400
    if quality~=nil then cached.quality=quality end
    if icon~=nil then cached.icon=icon end
    local resolved=values[1] or (info and info.itemName)
    if resolved then cached.name=resolved end
    local result={icon=icon,
        quality=quality or 1,qualityKnown=quality~=nil,
        reagentQuality=reagentQuality,craftingQuality=qualityInfo and qualityInfo.quality or reagentQuality,
        qualityAtlas=qualityInfo and (qualityInfo.iconInventory or qualityInfo.iconSmall),
        inventoryQualityAtlas=qualityInfo and qualityInfo.iconInventory~=nil,
        name=resolved or cached.name or entry.name or tostring(key.itemID),link=entry.link or values[2]}
    -- 名称解析成功后冻结整份元数据：全拍卖行列表逐行刷新时同一 key 只打一次 API；
    -- 返回的是共享缓存表，调用方只读。
    if resolved then cached.result=result end
    return result
end

function W.Identity(entry)
    if not entry or not entry.itemKey then return "" end
    return "ID "..tostring(entry.itemKey.itemID)
end

local function DisplayName(entry,label,meta)
    return label and not tonumber(label) and label or meta.name or entry.name or ""
end

function W.Tooltip(owner,entry)
    if not entry or not entry.itemKey then return end
    GameTooltip:SetOwner(owner,"ANCHOR_RIGHT")
    if entry.bag and entry.slot then GameTooltip:SetBagItem(entry.bag,entry.slot)
    elseif entry.link then GameTooltip:SetHyperlink(entry.link)
    else
        owner._easyAuctionKey=nil
        local key=entry.itemKey
        local pet=(tonumber(key.battlePetSpeciesID) or 0)>0 or key.itemID==82800
        -- 拍卖行搜索结果没有实例链接：对齐原生浏览页用 itemKey 出提示；
        -- SetItemByID 只显示基础模板，装备会被压到最低物品等级（如 232 显示成 27）。
        if not pet and GameTooltip.SetItemKey then
            local required=C_AuctionHouse.GetItemKeyRequiredLevel
                and C_AuctionHouse.GetItemKeyRequiredLevel(key)
            GameTooltip:SetItemKey(key.itemID,key.itemLevel or 0,key.itemSuffix or 0,required)
            owner._easyAuctionKey=key
        else GameTooltip:SetItemByID(key.itemID) end
    end
    GameTooltip:Show()
end

function W.QualityBadge(texture,meta,iconSize)
    texture:SetShown(meta.qualityAtlas~=nil)
    if not meta.qualityAtlas then return end
    texture:SetAtlas(meta.qualityAtlas)
    local atlas=C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(meta.qualityAtlas)
    if atlas and atlas.width>0 and atlas.height>0 then
        local scale=meta.inventoryQualityAtlas and min(1.05,max(0.85,iconSize/32)) or 1
        scale=min(scale,(iconSize+6)/max(atlas.width,atlas.height))
        texture:SetSize(atlas.width*scale,atlas.height*scale)
    else texture:SetSize(20,20) end
end

function W.Icon(parent,x,y,size,click)
    local icon=CreateFrame("Button",nil,parent,"BackdropTemplate")
    icon:SetPoint("TOPLEFT",x,y); icon:SetSize(size,size)
    icon:SetBackdrop({edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=2})
    icon.texture=icon:CreateTexture(nil,"ARTWORK"); icon.texture:SetPoint("TOPLEFT",2,-2)
    icon.texture:SetPoint("BOTTOMRIGHT",-2,2); icon.texture:SetTexCoord(0.07,0.93,0.07,0.93)
    icon.count=W.Text(icon,"",0,0,11,C.text)
    icon.count:ClearAllPoints(); icon.count:SetPoint("BOTTOMRIGHT",-2,2)
    icon.count:SetFont(STANDARD_TEXT_FONT,11,"OUTLINE")
    icon.craftingQuality=icon:CreateTexture(nil,"OVERLAY")
    icon.craftingQuality:SetPoint("TOPLEFT",-2,2); icon.craftingQuality:SetDrawLayer("OVERLAY",7)
    icon.craftingQuality:Hide()
    icon.selected=icon:CreateTexture(nil,"OVERLAY"); icon.selected:SetAllPoints()
    W.ThemeTexture(icon.selected,"selected",0.20); icon.selected:Hide()
    icon.selectionGlow=CreateFrame("Frame",nil,icon); icon.selectionGlow:SetAllPoints(); icon.selectionGlow:EnableMouse(false)
    icon.selectionGlow.edges={}
    local edgeNames={"TOPLEFT","BOTTOMLEFT","TOPLEFT","TOPRIGHT"}
    for index,point in ipairs(edgeNames) do
        local edge=icon.selectionGlow:CreateTexture(nil,"OVERLAY")
        W.ThemeTexture(edge,"accent",0.85)
        if index==1 then edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(2)
        elseif index==2 then edge:SetPoint("BOTTOMLEFT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetHeight(2)
        elseif index==3 then edge:SetPoint("TOPLEFT"); edge:SetPoint("BOTTOMLEFT"); edge:SetWidth(2)
        else edge:SetPoint("TOPRIGHT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetWidth(2) end
        icon.selectionGlow.edges[index]=edge
    end
    icon.selectionGlow:Hide(); icon.glowRunning=false; icon.glowTime=0
    function icon:SetSpecialSelected(active)
        active=active==true; self.specialSelected=active; self.selectionGlow:SetShown(active)
        if not active then self.glowRunning=false; self.selectionGlow:SetScript("OnUpdate",nil); return end
        if self.glowRunning then return end
        self.glowRunning=true; self.glowTime=0
        self.selectionGlow:SetScript("OnUpdate",function(glow,elapsed)
            glow._time=(glow._time or 0)+elapsed
            local alpha=0.45+0.40*(0.5+0.5*sin(glow._time*4))
            for index,edge in ipairs(glow.edges) do edge:SetAlpha(alpha) end
        end)
    end
    icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    icon:SetScript("OnEnter",function(self) W.Tooltip(self,self.entry) end)
    icon:SetScript("OnLeave",function() GameTooltip:Hide() end)
    icon:SetScript("OnClick",function(self,button) if self.entry and click then click(self.entry,button) end end)
    icon:RegisterForClicks("LeftButtonUp","RightButtonUp")
    function icon:SetEntry(entry,count,chosen)
        local identity=MetadataKey(entry.itemKey)
        if self.identity~=identity then
            self.identity=identity; self.quality,self.qualityColor=nil,nil
            self:SetBackdropBorderColor(unpack(C.line))
        end
        self.entry=entry
        local meta=W.Metadata(entry); self.texture:SetTexture(meta.icon)
        if meta.qualityKnown then self.quality=meta.quality end
        if self.quality and C_Item and C_Item.GetItemQualityColor then
            local r,g,b=C_Item.GetItemQualityColor(self.quality)
            if r and g and b then self.qualityColor={r,g,b} end
        end
        if self.qualityColor then
            self:SetBackdropBorderColor(self.qualityColor[1],self.qualityColor[2],self.qualityColor[3],1)
        end
        self.count:SetText(count and count>1 and tostring(count) or ""); self.selected:SetShown(chosen == true)
        self:SetSpecialSelected(chosen == true)
        W.QualityBadge(self.craftingQuality,meta,self:GetWidth() or size)
        return meta
    end
    function icon:SetSpell(entry)
        self.identity="spell:"..tostring(entry and entry.spellID or "")
        self.entry=nil; self.quality,self.qualityColor=nil,nil
        self:SetBackdropBorderColor(unpack(C.line))
        self.texture:SetTexture(entry and entry.icon or 134400)
        self.count:SetText(""); self.selected:Hide(); self:SetSpecialSelected(false)
        self.craftingQuality:Hide()
    end
    return icon
end

-- Reused rows with an optional direct action and inline quantity editor.
-- rowHeight defaults to 42; compact rows (30) match the restock table rhythm.
-- headers={{label,x,width,key,col}} renders clickable sort headings and, for
-- col=true entries, per-row cells fed from data[key]; sorting itself stays
-- with the caller via the onSort(key,descending) callback.
function W.Rows(parent,x,y,width,count,rowHeight,headers)
    rowHeight=tonumber(rowHeight) or 42
    local stride=rowHeight+2; local rowH=stride-2
    local compact=rowH<38
    local iconSize=compact and 26 or 36; local textX=iconSize+10
    local topPad=headers and 18 or 0
    local nameWidth=width-196
    if headers and headers[2] then nameWidth=headers[2].x-textX-12 end
    local list=CreateFrame("Frame",nil,parent); list:SetPoint("TOPLEFT",x,y)
    list:SetSize(width,count*stride+24+topPad); list.data={}; list.rows={}; list.offset=0
    list.headerCols=headers; list._nameWidth=nameWidth
    list.empty=W.Text(list,L["暂无物品"],0,-36,12,C.muted,width); list.empty:SetJustifyH("CENTER")
    if headers then
        list.headerButtons={}
        for hi,column in ipairs(headers) do
            local heading=W.Button(list,column.label,column.x,-2,column.width,function()
                local key=column.key
                if list.sortKey==key then list.sortDesc=not list.sortDesc
                else list.sortKey,list.sortDesc=key,false end
                list:UpdateHeaders()
                if list.onSort then list.onSort(list.sortKey,list.sortDesc) end
            end,nil,16)
            heading.sortKey=column.key
            heading.labelText=column.label
            heading.label:SetFont(STANDARD_TEXT_FONT,10,"")
            heading.label:ClearAllPoints(); heading.label:SetPoint("LEFT",4,0)
            heading.label:SetJustifyH("LEFT"); heading.label:SetTextColor(unpack(C.muted))
            list.headerButtons[hi]=heading
        end
        function list:UpdateHeaders()
            for _,heading in ipairs(self.headerButtons) do
                local active=self.sortKey==heading.sortKey
                heading.label:SetText(heading.labelText..(active and (self.sortDesc and " ▼" or " ▲") or ""))
                heading.label:SetTextColor(unpack(active and C.accent or C.muted))
            end
        end
    end
    local function Quantity(entry,value,delta)
        return min(entry and entry.maxQuantity or 9999999,max(1,floor(tonumber(value) or tonumber(entry and entry.buyQuantity)
            or tonumber(entry and entry.editQuantity) or 1)+(delta or 0)))
    end
    local function Submit(row,delta)
        local box=row.qty
        local entry,change=box.editEntry or row.entry,box.editChange or list.change
        local quantity=Quantity(entry,box:GetText(),delta)
        box.submitting=true; box:ClearFocus(); box.submitting=nil
        box.editEntry,box.editChange=nil,nil; box:SetText(tostring(quantity))
        if entry and change then change(entry,quantity) end
        return quantity
    end
    local controlsY=compact and -2 or -6
    for i=1,count do
        -- 行位于表头之下：topPad 把首行向下推（WoW 的 y 向上为正）。
        local row=CreateFrame("Button",nil,list); row:SetPoint("TOPLEFT",0,-topPad-(i-1)*stride); row:SetSize(width,rowH)
        row.fill=row:CreateTexture(nil,"BACKGROUND"); row.fill:SetAllPoints()
        W.ThemeTexture(row.fill,"stripe",i%2==0 and 0.018 or 0.035)
        row.icon=W.Icon(row,2,-2,iconSize,function() if row.entry and list.click then list.click(row.entry) end end)
        row.name=W.Text(row,"",textX,compact and -3 or -5,compact and 11 or 12,C.text,nameWidth)
        row.sub=W.Text(row,"",textX,compact and -16 or -23,compact and 9 or 10,C.muted,nameWidth)
        row.value=W.Text(row,"",width-144,compact and -9 or -13,11,C.gold,108); row.value:SetJustifyH("RIGHT")
        if headers then
            row.cols={}
            for hi,column in ipairs(headers) do
                if column.col then
                    row.cols[hi]=W.Text(row,"",column.x,-8,11,C.text,column.width-8)
                end
            end
        end
        row.action=W.Button(row,"+",width-28,controlsY,26,function(button)
            if row.entry and list.action then list.action(row.entry,button or row.action) end
        end)
        W.Hint(row.action,L["加入购物清单"],L["选择要添加到的清单。"])
        row.qty=W.Edit(row,width-112,controlsY,68)
        row.qty:SetNumeric(true); row.qty:SetMaxLetters(7); row.qty:SetJustifyH("CENTER")
        row.minus=W.Button(row,"−",width-202,controlsY,26,function() Submit(row,-1) end)
        row.plus=W.Button(row,"+",width-120,controlsY,26,function() Submit(row,1) end)
        row.buy=W.Button(row,L["买"],width-91,controlsY,48,function()
            local entry=row.entry
            if not entry or not entry.canBuy or not list.buy then return end
            local buy=list.buy
            local quantity=Submit(row)
            -- A quantity callback may rerender the list; buy the original row identity.
            buy(entry,quantity)
        end,true)
        row.qty:SetScript("OnEditFocusGained",function(self)
            self.editEntry,self.editChange=row.entry,list.change
        end)
        row.qty:SetScript("OnTextChanged",function(self)
            W.Enabled(row.minus,Quantity(row.entry,self:GetText())>1)
        end)
        row.qty:SetScript("OnEnterPressed",function() Submit(row) end)
        row.qty:SetScript("OnEditFocusLost",function(self)
            if not list.rendering and not self.submitting then Submit(row) end
        end)
        row:SetScript("OnClick",function() if row.entry and list.click then list.click(row.entry) end end)
        row:SetScript("OnEnter",function() if row.entry then W.Tooltip(row,row.entry.item or row.entry) end end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        list.rows[i]=row
    end
    list.prev=W.Button(list,"‹",0,-(topPad+count*stride),24,function() list.offset=list.offset-count; list:Render() end)
    list.next=W.Button(list,"›",width-24,-(topPad+count*stride),24,function() list.offset=list.offset+count; list:Render() end)
    list.page=W.Text(list,"",30,-(topPad+count*stride)-7,10,C.muted,width-60); list.page:SetJustifyH("CENTER")
    function list:Render()
        self.rendering=true
        local commits={}
        self.offset=min(max(0,self.offset),max(0,#self.data-count)); self.empty:SetShown(#self.data==0)
        for i=1,count do
            local row=self.rows[i]; local data=self.data[self.offset+i]
            local oldItem=row.entry and (row.entry.item or row.entry)
            local newItem=data and (data.item or data)
            if row.qty:HasFocus() and oldItem~=newItem then
                commits[#commits+1]={entry=row.qty.editEntry or row.entry,
                    change=row.qty.editChange or self.change,quantity=Quantity(row.entry,row.qty:GetText())}
                row.qty:ClearFocus(); row.qty.editEntry,row.qty.editChange=nil,nil
            end
            row.entry=data; row:SetShown(data~=nil)
            if data then
                local item=data.item or data
                local meta=row.icon:SetEntry(item,nil,data.selected)
                row.name:SetText(DisplayName(item,data.label or data.name,meta))
                row.name:SetTextColor(unpack(row.icon.qualityColor or C.text))
                row.sub:SetText(W.Identity(item,meta)..(data.sub and data.sub~="" and (" · "..data.sub) or ""))
                local buying=data.buyQuantity~=nil
                local rowNameWidth=self._nameWidth or (width-(buying and 390 or 196))
                row.name:SetWidth(rowNameWidth); row.sub:SetWidth(rowNameWidth)
                row.value:ClearAllPoints(); row.value:SetPoint("TOPLEFT",width-(buying and 330 or 144),-13)
                row.value:SetWidth(buying and 116 or 108)
                row.value:SetText(data.value or ""); row.value:SetShown(buying or not data.editQuantity)
                if self.headerCols then
                    for hi,column in ipairs(self.headerCols) do
                        local cell=row.cols and row.cols[hi]
                        if cell then cell:SetText(tostring(data[column.key] or "")) end
                    end
                end
                row.qty:ClearAllPoints(); row.qty:SetPoint("TOPLEFT",width-(buying and 173 or 112),-6)
                row.qty:SetWidth(buying and 50 or 68)
                row.qty:SetShown(buying or data.editQuantity~=nil)
                if (buying or data.editQuantity) and not row.qty:HasFocus() then
                    row.qty:SetText(tostring(Quantity(data,data.buyQuantity or data.editQuantity)))
                end
                row.minus:SetShown(buying); row.plus:SetShown(buying); row.buy:SetShown(buying)
                W.Enabled(row.minus,Quantity(data,row.qty:GetText())>1); W.Enabled(row.buy,buying and data.canBuy)
                row.action:SetShown(data.action~=nil); row.action.label:SetText(data.action or "+")
                if data.quantityColumn then
                    row.name:SetWidth(width-350); row.sub:SetWidth(width-350)
                    row.minus:ClearAllPoints(); row.minus:SetPoint("TOPLEFT",width-330,-6)
                    row.qty:ClearAllPoints(); row.qty:SetPoint("TOPLEFT",width-300,-6); row.qty:SetWidth(56)
                    row.plus:ClearAllPoints(); row.plus:SetPoint("TOPLEFT",width-240,-6)
                    row.value:ClearAllPoints(); row.value:SetPoint("TOPLEFT",width-208,-13); row.value:SetWidth(172)
                    row.value:Show(); row.minus:Show(); row.plus:Show()
                    W.Enabled(row.qty,data.editable); W.Enabled(row.action,data.editable)
                    W.Enabled(row.minus,data.editable and Quantity(data,row.qty:GetText())>1)
                    W.Enabled(row.plus,data.editable and Quantity(data,row.qty:GetText())<(data.maxQuantity or 9999999))
                end
            end
        end
        self.page:SetText(#self.data==0 and "" or (tostring(self.offset+1).."–"..min(self.offset+count,#self.data).." / "..#self.data))
        W.Enabled(self.prev,self.offset>0); W.Enabled(self.next,self.offset+count<#self.data)
        self.rendering=false
        for i,commit in ipairs(commits) do
            if commit.entry and commit.change then commit.change(commit.entry,commit.quantity) end
        end
    end
    function list:Set(data,click,action,change,buy)
        self.data,self.click,self.action,self.change,self.buy=data,click,action,change,buy; self:Render()
    end
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel",function(self,delta)
        self.offset=self.offset-delta*3; self:Render()
    end)
    return list
end

-- A restock row keeps quantity editing bound to its original list and item.
function W.RestockTable(parent,x,y,width,count)
    count=count or 5
    local pagerY=24+count*32
    local list=CreateFrame("Frame",nil,parent); list:SetPoint("TOPLEFT",x,y); list:SetSize(width,pagerY+28)
    list.data,list.rows,list.offset={},{},0
    local columns={{L["物品"],4,174},{L["最低单价"],188,92},{L["保持数量"],292,110},
        {L["上限 / 金"],414,106},{L["拥有"],532,54},{L["缺口"],598,54}}
    for i,column in ipairs(columns) do W.Text(list,column[1],column[2],-5,11,C.muted,column[3]) end
    list.empty=W.Text(list,L["添加物品，设定需要保持的数量"],0,-110,12,C.muted,width)
    list.empty:SetJustifyH("CENTER")
    local function Quantity(entry,value,delta)
        return min(9999999,max(1,floor(tonumber(value) or tonumber(entry and entry.target) or 1)+(delta or 0)))
    end
    local function PriceText(value)
        return value and format("%.4f",value/10000):gsub("0+$",""):gsub("%.$","") or ""
    end
    local function ParsePrice(text)
        text=text:match("^%s*(.-)%s*$")
        if text=="" then return true,nil end
        if not text:match("^%d+%.?%d*$") or #(text:match("%.(%d*)$") or "")>4 then return false end
        local value=tonumber(text)
        if not value or value<=0 or value==huge then return false end
        return true,floor(value*10000+0.5)
    end
    local function Submit(row,delta)
        local box=row.qty
        local entry,change=box.editEntry or row.entry,box.editChange or list.change
        local quantity=Quantity(entry,box:GetText(),delta)
        box.submitting=true; box:ClearFocus(); box.submitting=nil
        box.editEntry,box.editChange=nil,nil
        box:SetText(tostring(quantity))
        if entry and change then change(entry,quantity) end
    end
    local function SubmitPrice(row)
        local box=row.cap
        local entry,change=box.editEntry or row.entry,box.editChange or list.priceChange
        local valid,price=ParsePrice(box:GetText())
        box.submitting=true; box:ClearFocus(); box.submitting=nil
        box.editEntry,box.editChange=nil,nil
        if valid then
            box:SetText(PriceText(price))
            if entry and change then change(entry,price) end
        else box:SetText(PriceText(entry and entry.maxUnitPrice)) end
    end
    for i=1,count do
        local row=CreateFrame("Button",nil,list); row:SetPoint("TOPLEFT",0,-20-(i-1)*32); row:SetSize(width,30)
        row.fill=row:CreateTexture(nil,"BACKGROUND"); row.fill:SetAllPoints()
        W.ThemeTexture(row.fill,"stripe",i%2==0 and 0.018 or 0.035)
        row.selectionFill=row:CreateTexture(nil,"BACKGROUND",nil,1); row.selectionFill:SetAllPoints()
        W.ThemeTexture(row.selectionFill,"selected",1); row.selectionFill:Hide()
        row.selectionMark=row:CreateTexture(nil,"ARTWORK")
        row.selectionMark:SetPoint("TOPLEFT",-5,0); row.selectionMark:SetPoint("BOTTOMLEFT",-5,0)
        row.selectionMark:SetWidth(3)
        W.ThemeTexture(row.selectionMark,"accent",1); row.selectionMark:Hide()
        row.icon=W.Icon(row,2,-1,28,function() if row.entry and list.click then list.click(row.entry) end end)
        row.tag=W.Text(row,"",36,-18,9,C.accent,42)
        row.name=W.Text(row,"",36,-2,12,C.text,142)
        row.sub=W.Text(row,"",36,-18,9,C.muted,142)
        row.include=W.Button(row,"",160,-6,18,function()
            if row.entry and list.includeChange then
                list.includeChange(row.entry,row.entry.item.includeInRestock==false)
            end
        end)
        row.include:SetHeight(18)
        row.include.check=row.include:CreateTexture(nil,"OVERLAY")
        row.include.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check"); row.include.check:SetAllPoints()
        W.Hint(row.include,L["参与一键补货"],L["勾选需要补货的材料品质；未勾选的行仍可单独点击买。"])
        row.price=W.Text(row,"",188,-9,11,C.gold,92); row.price:SetJustifyH("RIGHT")
        row.minus=W.Button(row,"-",292,-3,26,function() Submit(row,-1) end)
        row.qty=W.Edit(row,321,-3,50); row.qty:SetTextInsets(4,4,0,0)
        row.qty:SetJustifyH("CENTER"); row.qty:SetNumeric(true); row.qty:SetMaxLetters(7)
        row.plus=W.Button(row,"+",374,-3,26,function() Submit(row,1) end)
        row.cap=W.Edit(row,414,-3,106); row.cap:SetMaxLetters(14); row.cap:SetTextInsets(4,4,0,0)
        W.Hint(row.cap,L["购买单价上限 / 金"],L["留空按当前最低价补货；支持最多 4 位小数。超过上限不会购买。"])
        row.cap:SetScript("OnEditFocusGained",function(self) self.editEntry,self.editChange=row.entry,list.priceChange end)
        row.cap:SetScript("OnEnterPressed",function() SubmitPrice(row) end)
        row.cap:SetScript("OnEditFocusLost",function(self)
            if not list.rendering and not self.submitting then SubmitPrice(row) end
        end)
        row.owned=W.Text(row,"",532,-9,11,C.text,54); row.owned:SetJustifyH("CENTER")
        row.missing=W.Text(row,"",598,-9,11,C.accent,54); row.missing:SetJustifyH("CENTER")
        row.buy=W.Button(row,L["买"],668,-3,44,function()
            if row.entry and row.entry.canBuy and list.buy then list.buy(row.entry) end
        end,true)
        row.remove=W.Button(row,"×",width-28,-3,26,function()
            if row.entry and list.remove then list.remove(row.entry) end
        end)
        for index,control in ipairs({row.minus,row.qty,row.plus,row.cap,row.buy,row.remove}) do control:SetHeight(24) end
        W.Hint(row.remove,L["从清单移除"])
        row.qty:SetScript("OnEditFocusGained",function(self)
            self.editEntry,self.editChange=row.entry,list.change
        end)
        row.qty:SetScript("OnTextChanged",function(self)
            W.Enabled(row.minus,Quantity(row.entry,self:GetText())>1)
        end)
        row.qty:SetScript("OnEnterPressed",function() Submit(row) end)
        row.qty:SetScript("OnEditFocusLost",function(self)
            if not list.rendering and not self.submitting then Submit(row) end
        end)
        row:SetScript("OnClick",function() if row.entry and list.click then list.click(row.entry) end end)
        row:SetScript("OnEnter",function()
            if not row.entry then return end
            W.Tooltip(row,row.entry.item)
            if row.entry.pending and row.entry.pending>0 then
                GameTooltip:AddLine(format(L["已购买 %s，等待领取"],tostring(row.entry.pending)),0.7,0.77,0.76,true)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        list.rows[i]=row
    end
    list.prev=W.Button(list,"‹",0,-pagerY,24,function() list.offset=list.offset-count; list:Render() end)
    list.next=W.Button(list,"›",width-24,-pagerY,24,function() list.offset=list.offset+count; list:Render() end)
    list.page=W.Text(list,"",30,-pagerY-8,10,C.muted,width-60); list.page:SetJustifyH("CENTER")
    function list:Render()
        self.rendering=true
        local commits={}
        self.offset=min(max(0,self.offset),max(0,#self.data-count)); self.empty:SetShown(#self.data==0)
        for i,row in ipairs(self.rows) do
            local data=self.data[self.offset+i]
            if not data or not row.entry or row.entry.item~=data.item or row.entry.binding~=data.binding then
                if row.qty:HasFocus() then
                    local entry=row.qty.editEntry or row.entry
                    commits[#commits+1]={entry=entry,change=row.qty.editChange or self.change,
                        value=Quantity(entry,row.qty:GetText())}
                    row.qty:ClearFocus(); row.qty.editEntry,row.qty.editChange=nil,nil
                end
                if row.cap:HasFocus() then
                    local valid,price=ParsePrice(row.cap:GetText())
                    if valid then commits[#commits+1]={entry=row.cap.editEntry or row.entry,
                        change=row.cap.editChange or self.priceChange,value=price} end
                    row.cap:ClearFocus(); row.cap.editEntry,row.cap.editChange=nil,nil
                end
            end
            row.entry=data; row:SetShown(data~=nil)
            row.selectionFill:SetShown(data~=nil and data.selected==true)
            row.selectionMark:SetShown(data~=nil and data.selected==true)
            if data then
                local meta=row.icon:SetEntry(data.item,nil,data.selected)
                row.include:SetShown(data.item.recipeMaterial==true)
                row.include.check:SetShown(data.item.includeInRestock~=false)
                local includeColor=data.item.includeInRestock==false and C.button or C.buttonActive
                row.include:SetBackdropColor(includeColor[1],includeColor[2],includeColor[3],1)
                row.include:SetBackdropBorderColor(unpack(data.item.includeInRestock==false and C.line or C.accent))
                row.name:SetWidth(data.item.recipeMaterial and 116 or 142)
                local tag,groupName=data.item.tag,data.item.groupName
                -- Group metadata comes from preset catalogs or tracked recipes; list names remain user data.
                if data.item.groupID then
                    if tag then tag=L[tag] end
                    if groupName then groupName=L[groupName] end
                end
                local tagged=tag~=nil
                row.tag:SetText(tag or ""); row.tag:SetShown(tagged)
                row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT",tagged and 84 or 36,-18)
                row.sub:SetWidth(tagged and 94 or 142)
                row.name:SetText(DisplayName(data.item,data.label,meta))
                row.name:SetTextColor(unpack(row.icon.qualityColor or C.text))
                row.sub:SetText((groupName and groupName.." · " or "")..W.Identity(data.item,meta))
                row.price:SetText(data.unitPrice and GetMoneyString(data.unitPrice,true) or (data.quoted and L["无在售"] or L["待查询"]))
                if not row.qty:HasFocus() then row.qty:SetText(tostring(Quantity(data,data.target))) end
                if not row.cap:HasFocus() then row.cap:SetText(PriceText(data.maxUnitPrice)) end
                row.owned:SetText(tostring(data.owned or 0)); row.missing:SetText(tostring(data.missing or 0))
                W.Enabled(row.buy,data.canBuy)
                W.Enabled(row.minus,Quantity(data,row.qty:GetText())>1)
            end
        end
        self.page:SetText(#self.data>0 and (tostring(self.offset+1).."–"..min(self.offset+count,#self.data).." / "..#self.data) or "")
        W.Enabled(self.prev,self.offset>0); W.Enabled(self.next,self.offset+count<#self.data)
        self.rendering=false
        for i,commit in ipairs(commits) do
            if commit.entry and commit.change then commit.change(commit.entry,commit.value) end
        end
    end
    function list:Set(data,click,change,buy,remove,priceChange,includeChange)
        self.data,self.click,self.change,self.buy,self.remove,self.priceChange=data,click,change,buy,remove,priceChange
        self.includeChange=includeChange
        self:Render()
    end
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel",function(self,delta)
        self.offset=self.offset-delta*3; self:Render()
    end)
    return list
end

-- Price columns share fixed anchors so values remain comparable when sorted.
function W.PriceTable(parent,x,y,width,sortClick)
    local list=CreateFrame("Frame",nil,parent); list:SetPoint("TOPLEFT",x,y); list:SetSize(width,356)
    local pageSize=9
    list.data,list.rows,list.offset={},{},0
    local columns={{"name",L["物品"],0,272},{"low",L["历史最低"],280,112},{"high",L["历史最高"],400,112},
        {"latest",L["最新价格"],520,112},{"updated",L["更新时间"],640,126}}
    list.headers={}
    for i,column in ipairs(columns) do
        local button=W.Button(list,column[2],column[3],0,column[4],function() sortClick(column[1]) end)
        list.headers[column[1]]=button
    end
    for i=1,pageSize do
        local row=CreateFrame("Button",nil,list); row:SetPoint("TOPLEFT",0,-32-(i-1)*32); row:SetSize(width,30)
        row.icon=W.Icon(row,2,-1,28,function() if row.entry then list.click(row.entry) end end)
        row.name=W.Text(row,"",38,-2,12,C.text,230)
        row.sub=W.Text(row,"",38,-17,10,C.muted,230)
        row.low=W.Text(row,"",280,-9,11,C.text,112); row.low:SetJustifyH("RIGHT")
        row.high=W.Text(row,"",400,-9,11,C.text,112); row.high:SetJustifyH("RIGHT")
        row.latest=W.Text(row,"",520,-9,11,C.gold,112); row.latest:SetJustifyH("RIGHT")
        row.updated=W.Text(row,"",640,-9,10,C.muted,126); row.updated:SetJustifyH("RIGHT")
        local rule=row:CreateTexture(nil,"BACKGROUND"); rule:SetColorTexture(unpack(C.line))
        rule:SetPoint("BOTTOMLEFT"); rule:SetSize(width,1)
        row:SetScript("OnClick",function() if row.entry then list.click(row.entry) end end)
        row:SetScript("OnEnter",function() if row.entry then W.Tooltip(row,row.entry.item) end end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        list.rows[i]=row
    end
    list.empty=W.Text(list,L["没有符合筛选条件的物品"],0,-100,12,C.muted,width); list.empty:SetJustifyH("CENTER")
    list.page=W.Text(list,"",30,-338,10,C.muted,width-60); list.page:SetJustifyH("CENTER")
    list.prev=W.Button(list,"‹",0,-330,24,function() list.offset=list.offset-pageSize; list:Render() end)
    list.next=W.Button(list,"›",width-24,-330,24,function() list.offset=list.offset+pageSize; list:Render() end)
    function list:Render()
        self.offset=min(max(0,self.offset),max(0,#self.data-pageSize)); self.empty:SetShown(#self.data==0)
        for i,row in ipairs(self.rows) do
            local value=self.data[self.offset+i]; row.entry=value; row:SetShown(value~=nil)
            if value then
                local meta=row.icon:SetEntry(value.item,nil,value.selected)
                row.name:SetText(DisplayName(value.item,value.name,meta)); row.sub:SetText(W.Identity(value.item,meta))
                for index,key in ipairs({"low","high","latest"}) do
                    row[key]:SetText(value[key] and GetMoneyString(value[key],true) or "—")
                end
                row.updated:SetText(value.updated and date("%m/%d %H:%M",value.updated) or "—")
            end
        end
        self.page:SetText(#self.data>0 and (tostring(self.offset+1).."–"..min(self.offset+pageSize,#self.data).." / "..#self.data) or "")
        W.Enabled(self.prev,self.offset>0); W.Enabled(self.next,self.offset+pageSize<#self.data)
    end
    function list:Set(data,click) self.data,self.click=data,click; self:Render() end
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel",function(self,delta)
        self.offset=self.offset-delta*3; self:Render()
    end)
    return list
end
