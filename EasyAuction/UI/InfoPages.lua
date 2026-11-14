local addonName, ns = ...
local CreateFrame, GetBuildInfo, C_AddOns = CreateFrame, GetBuildInfo, C_AddOns
local tostring, type, pairs, ipairs, unpack = tostring, type, pairs, ipairs, unpack
local L=ns.L
local W=ns.Widgets; local C=W.color
local P={}; ns.InfoPages=P
local media="Interface\\AddOns\\"..addonName.."\\media\\"

local function section(parent,title,x,y,width,height)
    local panel=W.Surface(parent,x,y,width,height,"panel")
    W.Text(panel,title,18,-18,14,C.gold)
    local rule=panel:CreateTexture(nil,"ARTWORK")
    W.ThemeTexture(rule,"line",0.85); rule:SetPoint("TOPLEFT",18,-46); rule:SetSize(width-36,1)
    return panel
end

function P.CreateGeneralSettings(parent,controls,settings,ui)
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints()
    W.Text(page,L["偏好设置"],24,-24,18,C.text)
    W.Text(page,L["按你的习惯，调整行情显示与出售方式"],24,-52,11,C.muted)
    local display=section(page,L["价格显示"],24,-88,360,258)
    local sale=section(page,L["出售偏好"],402,-88,364,258)
    W.Text(display,L["物品价格详情"],18,-70,12,C.text)
    controls.autoDetails=W.Button(display,"",184,-60,158,function()
        settings().autoDetails=settings().autoDetails==false
        if not settings().autoDetails then ui.detailOpen=false; ui.Layout() end
        ui.Refresh()
    end)
    W.Text(display,L["历史范围"],18,-116,12,C.text)
    controls.historyDays=W.Button(display,"",184,-106,158,function()
        local days=({[1]=7,[7]=30,[30]=1})[settings().historyDays] or 1
        settings().historyDays=days; ui.days=days; ui.Refresh()
    end)
    W.Text(display,L["物品鼠标提示"],18,-156,12,C.text)
    controls.itemTooltip=W.Button(display,"",184,-146,158,function()
        settings().itemTooltip=not settings().itemTooltip; ui.Refresh()
    end)
    W.Text(display,L["鼠标提示显示最近采样的单价与在售数量"],18,-196,11,C.muted,324)
    W.Text(display,L["界面主题"],18,-224,12,C.text)
    local themeOptions
    if ns.Style and ns.Style.PaletteOrder and ns.Style.Palettes then
        themeOptions={}
        for _,key in ipairs(ns.Style.PaletteOrder) do
            local palette=ns.Style.Palettes[key]
            if palette then themeOptions[#themeOptions+1]={value=key,text=palette.name,palette=palette} end
        end
    end
    if themeOptions and #themeOptions>0 then
        controls.theme=W.Dropdown(display,184,-214,158,themeOptions,function(key)
            if ns.Style then ns.Style:SetPalette(key) end
        end,{height=28,swatch=function(option)
            if option.value=="class" and ns.Style and ns.Style.ClassColor then
                local r,g,b=ns.Style:ClassColor()
                if r then return {r,g,b} end
            end
            return option.palette and option.palette.accent
        end})
        controls.theme:SetValue(ns.Style:Palette().key)
    else
        controls.theme=W.Button(display,"",184,-214,158,function()
            if ns.Style then ns.Style:CyclePalette() end
            ui.Refresh()
        end)
    end
    --W.Text(display,L["下拉选择界面配色，职业徽记跟随当前角色职业色"],18,-250,10,C.muted,324)
    W.Text(sale,L["上架时长"],18,-70,12,C.text)
    controls.defaultDuration=W.Button(sale,"",184,-60,162,function()
        settings().duration=(settings().duration or 1)%3+1
        controls.durationValue=settings().duration
        controls.duration.label:SetText(({L["12 小时"],L["24 小时"],L["48 小时"]})[controls.durationValue]); ui.Refresh()
    end)
    W.Text(sale,L["自动压价"],18,-116,12,C.text)
    controls.undercut=W.Button(sale,"",184,-106,162,function()
        settings().undercut=not settings().undercut; ui.Refresh()
    end)
    W.Text(sale,L["压价金额"],18,-162,12,C.text)
    controls.undercutAmount=W.MoneyEdit(sale,146,-152,200,settings().undercutAmount,true)
    for fieldName,field in pairs(controls.undercutAmount.fields) do
        field:HookScript("OnEditFocusLost",ui.CommitUndercut)
    end
    W.Text(sale,L["开启后，按最低在售价减去设定金额出售"],18,-218,11,C.muted,328)
    W.Text(page,L["保留 30 天实际行情 · 打开拍卖行默认进入闪购"],24,-382,11,C.muted,562)
    page.resetError=W.Text(page,"",24,-428,11,C.danger,730)
    page.resetButton=W.Button(page,L["重置插件…"],616,-372,150,function()
        page.resetError:SetText("")
        ns.Reset.Request(function(reason) page.resetError:SetText(reason) end)
    end)
    page.resetButton:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
        edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    W.ThemeBackdrop(page.resetButton,"dangerBg","danger")
    page.resetButton.label:SetTextColor(C.danger[1],C.danger[2],C.danger[3],1)
    W.Hint(page.resetButton,L["重置整个插件"],L["清除所有价格、清单与设置。点击后需再次确认。"])
    function page:ApplyTheme()
        if page.resetButton then
            page.resetButton:SetBackdropColor(C.dangerBg[1],C.dangerBg[2],C.dangerBg[3],1)
            page.resetButton:SetBackdropBorderColor(C.danger[1],C.danger[2],C.danger[3],1)
            page.resetButton.label:SetTextColor(C.danger[1],C.danger[2],C.danger[3],1)
        end
    end
    page:SetScript("OnHide",function() ns.Reset.Dismiss() end)
    return page
end

function P.CreateSettings(parent,controls,settings,ui)
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints()
    local body=CreateFrame("Frame",nil,page)
    body:SetPoint("TOPLEFT",0,-34); body:SetPoint("BOTTOMRIGHT")
    local general=P.CreateGeneralSettings(body,controls,settings,ui)
    local professional=ns.ProfessionSettingsView and ns.ProfessionSettingsView.Create(body)
    local data=ns.ProfessionSettingsView and ns.ProfessionSettingsView.CreateData(body)
    local pages={general,professional,data}; local buttons={}
    page.general,page.professional,page.data=general,professional,data
    function page:Select(index)
        for position,child in ipairs(pages) do child:SetShown(position==index) end
        for position,button in ipairs(buttons) do
            W.SetButtonState(button,position==index,false)
        end
        self.active=index
        if index==2 and professional then professional:Refresh() end
        if index==3 and data then data:Refresh() end
    end
    for index,label in ipairs({L["通用设置"],L["专业设置"],L["数据管理"]}) do
        buttons[index]=W.Button(page,label,12+(index-1)*154,-4,146,function() page:Select(index) end)
    end
    function page:ApplyTheme()
        for position,button in ipairs(buttons) do W.SetButtonState(button,position==self.active,false) end
        if self.general and self.general.ApplyTheme then self.general:ApplyTheme() end
        if self.professional and self.professional.Refresh then self.professional:Refresh() end
        if self.data and self.data.Refresh then self.data:Refresh() end
    end
    page:Select(1)
    return page
end

function P.ApplyTheme()
    if ns.UI and ns.UI.GetSettingsPage then
        local page=ns.UI.GetSettingsPage()
        if page and page.ApplyTheme then page:ApplyTheme() end
    end
end

function P.VersionInfo()
    local build=type(GetBuildInfo)=="function" and {GetBuildInfo()} or {}
    local version=C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName,"Version")
    return {game=build[1] or L["未知"],build=build[2] or L["未知"],interface=build[4] or L["未知"],
        addon=version or ns.version or L["未知"],author="黑科研[童]"}
end

local function copyDialog(page)
    local dialog=W.Surface(page,160,-164,470,136)
    dialog:SetFrameLevel(page:GetFrameLevel()+30); dialog:EnableMouse(true)
    dialog.title=W.Text(dialog,"",16,-16,14,C.gold,388)
    dialog.edit=W.Edit(dialog,16,-48,438,""); dialog.edit:SetMaxLetters(512)
    W.Text(dialog,L["Ctrl+C 复制 · 在浏览器或 QQ 中使用"],16,-94,11,C.muted,410)
    W.Button(dialog,"×",428,-8,30,function() dialog:Hide() end)
    dialog.edit:SetScript("OnEscapePressed",function() dialog:Hide() end)
    dialog.edit:SetScript("OnEnterPressed",function() dialog:Hide() end)
    dialog:SetScript("OnHide",function() dialog.edit:ClearFocus() end)
    dialog:Hide()
    return dialog
end

function P.CreateAbout(parent)
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints()
    local version=P.VersionInfo()
    page.logo=page:CreateTexture(nil,"ARTWORK")
    page.logo:SetTexture(media.."HekLab-ui.png")
    page.logo:SetTexCoord(0,400/512,0,180/256)
    page.logo:SetPoint("TOPLEFT",24,-24); page.logo:SetSize(240,108)
    W.Text(page,"EasyAuction",292,-28,23,C.text)
    W.Text(page,version.author,294,-63,13,C.gold)
    W.Text(page,(L["插件 %s"]):format(tostring(version.addon)),294,-90,11,C.muted,450)
    W.Text(page,(L["魔兽世界 %s  ·  Build %s  ·  Interface %s"]):format(
        tostring(version.game),tostring(version.build),tostring(version.interface)),294,-111,11,C.muted,450)
    local sponsors=section(page,L["支持榜"],24,-162,360,168)
    W.Text(sponsors,"FollenFang",18,-68,16,C.text)
    W.Text(sponsors,L["感谢支持"],18,-112,11,C.muted,324)
    local thanks=section(page,L["特别鸣谢"],402,-162,364,168)
    W.Text(thanks,L["开发工具支持  ·  FollenFang"],18,-91,11,C.muted,328)
    page.copyDialog=copyDialog(page)
    local function showLink(title,value)
        local dialog=page.copyDialog
        dialog.title:SetText(title); dialog.edit:SetText(value)
        dialog:Show(); dialog.edit:SetFocus(); dialog.edit:HighlightText()
    end
    page.toolkitLink=CreateFrame("Button",nil,thanks)
    page.toolkitLink:SetPoint("TOPLEFT",18,-56); page.toolkitLink:SetSize(225,26)
    page.toolkitLink.label=W.Text(page.toolkitLink,"Lychee Dev Toolkit",0,-5,15,C.text,225)
    page.toolkitLink:SetScript("OnClick",function()
        showLink("Lychee Dev Toolkit","https://github.com/Follen/Lychee-Dev")
    end)
    W.Hint(page.toolkitLink,"Lychee Dev Toolkit",L["点击名称复制工具项目地址"])
    page.toolkitLink:HookScript("OnEnter",function() page.toolkitLink.label:SetTextColor(unpack(C.accent)) end)
    page.toolkitLink:HookScript("OnLeave",function() page.toolkitLink.label:SetTextColor(unpack(C.text)) end)
    W.Text(page,L["保持联系"],24,-359,11,C.muted)
    page.links={}
    local links={
        {id="github",label="GitHub",value="https://github.com/JovenCalme/EasyAuction"},
        {id="discord",label="Discord",value="https://discord.gg/2tAa8yg24"},
        {id="qq",label="QQGroup",value="1033067960"},
        {id="paypal",label="PayPal"},
    }
    for index,link in ipairs(links) do
        local button=W.Button(page,link.label,24+(index-1)*124,-385,112,function()
            if link.value then showLink(link.id=="qq" and L["QQ群"] or link.label,link.value) end
        end)
        W.ButtonIcon(button,media.."about-"..link.id..".tga")
        button.icon:SetTexCoord(0,1,0,1)
        W.Hint(button,link.label,link.value and L["点击复制"] or L["赞助入口暂未开放"])
        W.Enabled(button,link.value~=nil); page.links[link.id]=button
    end
    W.Text(page,L["用心做工具，让游戏更轻松"],540,-397,11,C.muted,226)
    page:SetScript("OnHide",function() page.copyDialog:Hide() end)
    return page
end
