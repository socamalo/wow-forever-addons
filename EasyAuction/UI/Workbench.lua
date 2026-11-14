local addonName, ns = ... -- luacheck: ignore addonName

local CreateFrame, UIParent, C_Timer = CreateFrame, UIParent, C_Timer
local ReloadUI = ReloadUI -- luacheck: read globals ReloadUI
local C_Item, C_AuctionHouse, GetMoneyString = C_Item, C_AuctionHouse, GetMoneyString
-- luacheck: read globals GetAHFilterName GetAHFilterCategoryName
local C_Cursor, Enum = C_Cursor, Enum -- luacheck: read globals C_Cursor
local GetCursorInfo, ClearCursor, IsShiftKeyDown = GetCursorInfo, ClearCursor, IsShiftKeyDown
local hooksecurefunc, UISpecialFrames = hooksecurefunc, UISpecialFrames
local date, tonumber, tostring, pairs, ipairs, type, unpack = date, tonumber, tostring, pairs, ipairs, type, unpack
local min, max, floor = math.min, math.max, math.floor
local ceil=math.ceil
local format, sort, concat = string.format, table.sort, table.concat
local remove=table.remove
local L=ns.L
local UI={tab="buy",days=1,view="list",detailOpen=false,searchQuantities={}}; ns.UI=UI
local W,H,DW=790,476,272
local K=ns.Widgets; local C=K.color
local frame,detail,controls,selected,selectedBag,selectedList,dialog,picker,recentPicker
local assistantPending=false
local assistantPriceEntry,priceDetailContext,assistantPriceTab,scanFooter
local bagIcons,bagHeaders,bars={},{},{}
local rows,shortRows,bagScroll,bagContent,distribution,trade,selectedIcon
local groupOffset,barOffset=0,0
local RefreshTrend,Search,ShowDialog,AddItem,SelectList,ShowAddPicker
local settingsPage,restockTable,restockFooter,clearDialog
local RefreshClearDialog
local menus={}
local function CloseMenus(except)
    for index,menu in ipairs(menus) do if menu~=except then menu:Hide() end end
end
local function RegisterMenu(menu,owner)
    menu.owner=owner; menus[#menus+1]=menu
    menu:EnableMouse(true)
end

local function clearTable(target)
    if type(target) ~= "table" then return end
    for key in pairs(target) do target[key] = nil end
end

local function clearWidgetData(list)
    if not list then return end
    clearTable(list.data)
    list.offset = 0
    list.click, list.action, list.change, list.buy = nil, nil, nil, nil
    list.remove, list.priceChange, list.includeChange = nil, nil, nil
    for index, row in ipairs(list.rows or {}) do
        row.entry = nil
        if row.qty then row.qty.editEntry, row.qty.editChange = nil, nil end
        if row.cap then row.cap.editEntry, row.cap.editChange = nil, nil end
    end
end

local function clearTransientState()
    selected, selectedBag = nil, nil
    assistantPriceEntry,priceDetailContext,assistantPriceTab=nil,nil,nil
    UI.directResult, UI.catalogID = nil, nil
    UI.detailOpen, UI.searchQuantities = false, {}
    UI.actionError = nil
    CloseMenus()
    if picker then
        picker.addEntry, picker.owner = nil, nil
        for index, button in ipairs(picker.buttons or {}) do button.list = nil end
    end
    if recentPicker then
        recentPicker.owner = nil
        for index, button in ipairs(recentPicker.buttons or {}) do button.query = nil end
    end
    clearWidgetData(rows)
    clearWidgetData(shortRows)
    clearWidgetData(restockTable)
    if controls and controls.catalog then
        local catalog = controls.catalog
        catalog.entries, catalog.owner, catalog.definition, catalog.targetList = nil, nil, nil, nil
        for index, icon in ipairs(catalog.icons or {}) do icon.entry = nil; icon:Hide() end
    end
    if controls and controls.catalogTabs then
        for index, button in ipairs(controls.catalogTabs.buttons or {}) do button.catalog = nil end
    end
    if controls and controls.deleteDialog then controls.deleteDialog.list = nil end
    if controls and controls.scanDialog then
        controls.scanDialog.requested, controls.scanDialog._refresh = false, 0
        controls.scanDialog:Hide()
    end
    for index, icon in ipairs(bagIcons) do icon.entry = nil; icon:Hide() end
    for index, header in ipairs(bagHeaders) do header:SetText(""); header:Hide() end
    for index, bar in ipairs(bars) do bar.entry, bar.bag = nil, nil; bar:Hide() end
    if distribution then distribution.levels = {} end
    if selectedIcon then selectedIcon.entry = nil end
    if detail and detail.plot and ns.TrendPlot then ns.TrendPlot.Render(detail.plot, {}, 0, 0) end
    if ns.ViewModel and ns.ViewModel.ClearCache then ns.ViewModel.ClearCache() end
    if dialog then
        dialog.mode = nil
        dialog.name:SetText(""); dialog.editor:SetText(""); dialog.message:SetText("")
    end
    if clearDialog then clearWidgetData(clearDialog.rows) end
end

local function OfflineEscape(enabled)
    for i=#UISpecialFrames,1,-1 do
        if UISpecialFrames[i]=="EasyAuctionWorkbench" then remove(UISpecialFrames,i) end
    end
    if enabled then UISpecialFrames[#UISpecialFrames+1]="EasyAuctionWorkbench" end
end
local function Settings()
    local db=ns.Store.GetDB()
    if not db.settings then db.settings={autoDetails=true,historyDays=1,duration=1} end
    if db.settings.flashBuy==nil then db.settings.flashBuy=false end
    if db.settings.undercut==nil then db.settings.undercut=false end
    db.settings.undercutAmount=ns.Market.NormalizeUndercutAmount(db.settings.undercutAmount)
    return db.settings
end

local moneyMemo={}
local function Money(price)
    if not price or price<=0 then return "—" end
    local copper=floor(price)
    local text=moneyMemo[copper]
    if not text then text=GetMoneyString(copper,true); moneyMemo[copper]=text end
    return text
end

local function PriceDetailEntry()
    if priceDetailContext=="assistant" then return assistantPriceEntry end
    return selected
end

local function NormalizedAssistantEntry(row)
    if type(row)~="table" then return nil end
    local key=row.itemKey or row.outputItemID or row.itemID
    if type(key)=="number" then
        key={itemID=key,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
    end
    if type(key)~="table" or not tonumber(key.itemID) then return nil end
    return {itemKey={itemID=tonumber(key.itemID),itemLevel=tonumber(key.itemLevel) or 0,
        itemSuffix=tonumber(key.itemSuffix) or 0,battlePetSpeciesID=tonumber(key.battlePetSpeciesID) or 0},
        name=row.name or row.itemName or row.label,link=row.link,icon=row.icon,quality=row.quality}
end

function UI.DrawerOffset(room,count,slot,scale)
    room=max(0,tonumber(room) or 0); count=max(1,floor(tonumber(count) or 1))
    slot=min(count,max(1,floor(tonumber(slot) or 1))); scale=tonumber(scale) or 1
    local unit=DW+8; local base
    if room>=count*unit*scale then base=8
    elseif room>=unit*scale then base=-DW
    else base=-(count*DW+(count-1)*8) end
    return base+(slot-1)*unit
end

function UI.LayoutExternalDrawer(target,slot,count)
    if not target or not frame then return false end
    target:ClearAllPoints(); target:SetScale(1)
    local offset=UI.DrawerOffset(UI.drawerRoom,count,slot,frame:GetScale())
    target:SetPoint("TOPLEFT",frame,"TOPRIGHT",offset,UI.docked and 32 or 0)
    return true
end
function UI.SalePrice(price)
    return ns.Market.SalePrice and ns.Market.SalePrice(price) or price
end
function UI.CommitUndercut()
    local value=controls.undercutAmount:GetCopper()
    Settings().undercutAmount=ns.Market.NormalizeUndercutAmount(value)
    controls.undercutAmount:SetCopper(Settings().undercutAmount); UI.Refresh()
end
local function Say(message) if frame then frame.status:SetText(message or "") end end

-- 闪购搜索过滤：二级分类 + 与官方一致的筛选组（等级范围/稀有程度/内容标记）。
local browseCategories
local function BrowseCategoryOptions()
    if browseCategories then return browseCategories end
    browseCategories={{text=L["全部分类"],value=-1}}
    if C_Item and C_Item.GetItemClassInfo then
        for classID=0,20 do
            local ok,name=pcall(C_Item.GetItemClassInfo,classID)
            if ok and type(name)=="string" and name~="" then
                local subs={{text=L["全部子类"],value=-1}}
                if C_Item.GetItemSubClassInfo then
                    for subClassID=0,20 do
                        local okSub,subName=pcall(C_Item.GetItemSubClassInfo,classID,subClassID)
                        if okSub and type(subName)=="string" and subName~="" then
                            subs[#subs+1]={text=subName,value=subClassID}
                        end
                    end
                end
                browseCategories[#browseCategories+1]={text=name,value=classID,subs=subs}
            end
        end
    end
    return browseCategories
end
local function SubCategoryOptions(classID)
    for _,category in ipairs(BrowseCategoryOptions()) do
        if category.value==classID then return category.subs end
    end
    return {{text=L["全部子类"],value=-1}}
end

local function BrowseFilterState()
    local settings=Settings()
    local state=settings.browseFilter
    if type(state)~="table" then state={}; settings.browseFilter=state end
    if type(state.flags)~="table" then
        -- 默认值只在 flags 首次创建时补齐：此后 nil 表示用户明确取消的稀有度。
        local q=Enum.AuctionHouseFilter or {}
        state.flags={}
        for value=q.PoorQuality or 6,q.ArtifactQuality or 12 do state.flags[value]=true end
    end
    if state.minLevel==nil then state.minLevel="" end
    if state.maxLevel==nil then state.maxLevel="" end
    return state
end
local function ResetBrowseFilterState(state)
    local q=Enum.AuctionHouseFilter or {}
    clearTable(state.flags)
    for value=q.PoorQuality or 6,q.ArtifactQuality or 12 do state.flags[value]=true end
    state.minLevel,state.maxLevel="",""
    state.classID,state.subClassID=nil,nil
end

local QUALITY_LABELS={L["粗糙"],L["普通"],L["优秀"],L["精良"],L["史诗"],L["传说"],L["神器"]}
local function QualityColorHex(value)
    local q=Enum.AuctionHouseFilter or {}
    if value<(q.PoorQuality or 6) or value>(q.ArtifactQuality or 12) then return nil end
    if not (C_Item and C_Item.GetItemQualityColor) then return nil end
    local ok,r,g,b=pcall(C_Item.GetItemQualityColor,value-(q.PoorQuality or 6))
    if not ok or not r then return nil end
    return format("|cff%02x%02x%02x",floor(r*255+0.5),floor(g*255+0.5),floor(b*255+0.5))
end
local function FilterLabel(value)
    if type(GetAHFilterName)=="function" then
        local ok,name=pcall(GetAHFilterName,value)
        if ok and type(name)=="string" and name~="" then return name end
    end
    local q=Enum.AuctionHouseFilter or {}
    if value==q.UncollectedOnly then return L["只显示未获得的"] end
    if value==q.UsableOnly then return L["只显示可用种类"] end
    if value==q.CurrentExpansionOnly then return L["仅限当前内容更新"] end
    if value==q.UpgradesOnly then return L["只显示对我有提升的"] end
    if value>=(q.PoorQuality or 6) and value<=(q.ArtifactQuality or 12) then
        return QUALITY_LABELS[value-(q.PoorQuality or 6)+1] or tostring(value)
    end
    return tostring(value)
end
local function FilterGroupsData()
    if C_AuctionHouse and C_AuctionHouse.GetFilterGroups then
        local ok,groups=pcall(C_AuctionHouse.GetFilterGroups)
        if ok and type(groups)=="table" and #groups>0 then return groups end
    end
    -- 枚举值是客户端稳定常量；Enum 缺失（旧客户端/离线桩）时按字面量兜底。
    local q=Enum.AuctionHouseFilter or {}
    return {{title=L["其他筛选"],filters={q.UncollectedOnly or 1,q.UsableOnly or 2,
            q.CurrentExpansionOnly or 3,q.UpgradesOnly or 4}},
        {title=L["稀有程度"],filters={q.PoorQuality or 6,q.CommonQuality or 7,q.UncommonQuality or 8,
            q.RareQuality or 9,q.EpicQuality or 10,q.LegendaryQuality or 11,q.ArtifactQuality or 12}}}
end
local function FilterGroupTitle(group)
    if group.title then return group.title end
    if type(GetAHFilterCategoryName)=="function" then
        local ok,name=pcall(GetAHFilterCategoryName,group.category)
        if ok and type(name)=="string" and name~="" then return name end
    end
    return L["其他筛选"]
end

local function BrowseFilterOptions()
    local state=BrowseFilterState()
    local q=Enum.AuctionHouseFilter or {}
    local low,high=q.PoorQuality or 6,q.ArtifactQuality or 12
    local filters,hasQuality={},false
    for value=1,13 do
        if state.flags[value] then
            filters[#filters+1]=value
            if value>=low and value<=high then hasQuality=true end
        end
    end
    -- 稀有程度是包含标志：全部取消时服务器不返回任何结果，等价回退为全选。
    if not hasQuality then
        for value=low,high do filters[#filters+1]=value end
    end
    local minLevel=floor(tonumber(state.minLevel) or 0)
    local maxLevel=floor(tonumber(state.maxLevel) or 0)
    if minLevel<0 then minLevel=0 end
    if maxLevel<0 then maxLevel=0 end
    if maxLevel>0 and maxLevel<minLevel then maxLevel=minLevel end
    local isDefault=#filters==(high-low+1)
    if isDefault then
        for index,value in ipairs(filters) do
            if value~=low+index-1 then isDefault=false; break end
        end
    end
    if isDefault and (minLevel~=0 or maxLevel~=0 or state.classID~=nil) then isDefault=false end
    if isDefault then return nil end
    local itemClassFilters
    if state.classID~=nil then
        itemClassFilters={{classID=state.classID,subClassID=state.subClassID}}
    end
    return {minLevel=minLevel,maxLevel=maxLevel,filters=filters,itemClassFilters=itemClassFilters}
end

local function SyncFilterCheck(check,checked,value)
    local name=FilterLabel(value)
    local hex=checked and QualityColorHex(value)
    if hex then name=hex..name.."|r" end
    check.label:SetText((checked and "|cff39d9b3☑|r " or "|cff788a8d☐|r ")..name)
    check:SetChecked(checked)
end
local function SyncFilterPanel()
    local panel=controls.filterPanel
    if not panel then return end
    local state=BrowseFilterState()
    panel.minLevel:SetText(tostring(state.minLevel))
    panel.maxLevel:SetText(tostring(state.maxLevel))
    panel.classDropdown:SetValue(state.classID or -1)
    panel.subDropdown:SetOptions(SubCategoryOptions(state.classID))
    panel.subDropdown:SetValue(state.subClassID or -1)
    for _,check in ipairs(panel.checks) do
        SyncFilterCheck(check,state.flags[check.filterValue]==true,check.filterValue)
    end
end
local function BuildFilterPanel()
    local panel=K.Surface(frame,0,0,330,120)
    controls.filterPanel=panel
    panel:SetFrameLevel(frame:GetFrameLevel()+60); panel:EnableMouse(true)
    panel:ClearAllPoints(); panel:SetPoint("TOPRIGHT",controls.filter,"BOTTOMRIGHT",0,-4)
    K.Text(panel,L["过滤器"],12,-10,13,C.gold)
    K.Button(panel,L["清除"],246,-8,72,function()
        ResetBrowseFilterState(BrowseFilterState()); SyncFilterPanel()
    end)
    local y=30
    K.Text(panel,L["分类"],12,-y,11,C.muted); y=y+16
    panel.classDropdown=K.Dropdown(panel,12,-y,148,BrowseCategoryOptions(),function(value)
        local state=BrowseFilterState()
        state.classID=value~=nil and value>-1 and value or nil
        state.subClassID=nil
        panel.subDropdown:SetOptions(SubCategoryOptions(state.classID))
        panel.subDropdown:SetValue(-1)
    end)
    panel.subDropdown=K.Dropdown(panel,170,-y,148,SubCategoryOptions(nil),function(value)
        BrowseFilterState().subClassID=value~=nil and value>-1 and value or nil
    end)
    y=y+34
    K.Text(panel,L["等级范围"],12,-y,11,C.muted); y=y+16
    panel.minLevel=K.Edit(panel,12,-y,64); panel.minLevel:SetNumeric(true); panel.minLevel:SetMaxLetters(3)
    K.Text(panel,"-",84,-y+8,12,C.muted)
    panel.maxLevel=K.Edit(panel,100,-y,64); panel.maxLevel:SetNumeric(true); panel.maxLevel:SetMaxLetters(3)
    panel.minLevel:HookScript("OnTextChanged",function(self) BrowseFilterState().minLevel=self:GetText() end)
    panel.maxLevel:HookScript("OnTextChanged",function(self) BrowseFilterState().maxLevel=self:GetText() end)
    y=y+36
    panel.checks={}
    for _,group in ipairs(FilterGroupsData()) do
        K.Text(panel,FilterGroupTitle(group),12,-y,11,C.gold); y=y+17
        for _,filterValue in ipairs(group.filters) do
            -- 20px 勾选行必须用 Button 基底：普通 Frame 不支持 OnClick 脚本。
            local check
            check=K.Check(panel,12,-y,306,20)
            check:SetScript("OnClick",function()
                local state=BrowseFilterState()
                if state.flags[filterValue] then state.flags[filterValue]=nil else state.flags[filterValue]=true end
                check:SetChecked(state.flags[filterValue]==true)
                SyncFilterCheck(check,state.flags[filterValue]==true,filterValue)
            end)
            check.filterValue=filterValue
            panel.checks[#panel.checks+1]=check
            y=y+21
        end
        y=y+2
    end
    K.Button(panel,L["搜索"],12,-y,150,function()
        panel:Hide(); Search()
    end)
    K.Button(panel,L["重置"],170,-y,148,function()
        ResetBrowseFilterState(BrowseFilterState()); SyncFilterPanel()
    end)
    panel:SetHeight(y+40)
    return panel
end
function UI.ToggleFilterPanel()
    if not frame or not controls.filter then return end
    local panel=controls.filterPanel
    local wasShown=panel and panel:IsShown()
    if not panel then panel=BuildFilterPanel(); controls.filterPanel=panel end
    if wasShown then
        panel:Hide()
    else
        CloseMenus(panel)
        SyncFilterPanel(); panel:Show()
    end
end
-- 离线探针与集成测试读取当前过滤状态组装结果的出口。
function UI.BrowseFilterOptions() return BrowseFilterOptions() end

local function Invoke(method,...)
    ns.lastError=nil; UI.actionError=nil
    local ok,message=ns.Market[method](...)
    if ok==false then
        UI.actionError=type(message)=="string" and message or ns.lastError or L["当前操作不可用"]
        Say(UI.actionError)
    end
    return ok
end
local function ItemName(entry)
    return K.Metadata(entry).name
end

local function EditListItem(listID,itemKey,name,quantity,price)
    -- A queued purchase must not keep using a replaced target or price cap.
    ns.Market.CancelBuy()
    return ns.Store.SetListItem(listID,itemKey,name,quantity,price)
end

local function BuyActive()
    local state=ns.Market.buy and ns.Market.buy.state
    return ns.Market.unresolved~=nil or state=="quoting" or state=="ready" or state=="needs-click"
        or state=="awaiting_quote" or state=="submitting" or state=="submitted" or state=="uncertain"
end

local function BuyRestockList()
    if BuyActive() then
        if not (ns.Market.unresolved and ns.Market.buy.cancelRequested) then Invoke("CancelBuy") end
    elseif selectedList then
        Invoke("BuyRestockList",selectedList)
    end
    UI.Refresh()
end

local function RefreshListPrices()
    if selectedList and ns.open then Invoke("RefreshList",selectedList) end
end

function UI.IsShown()
    return frame ~= nil and frame:IsShown()
end

function UI.GetSettingsPage()
    return settingsPage
end

function UI.ApplyTheme()
    if not frame then return end
    if K.ApplyTheme then K.ApplyTheme() end
    if frame.SetBackdropColor then frame:SetBackdropColor(unpack(C.bg)); frame:SetBackdropBorderColor(unpack(C.line)) end
    if controls and controls.sellDividers then
        controls.sellDividers.vertical:SetColorTexture(unpack(C.line))
        controls.sellDividers.horizontal:SetColorTexture(unpack(C.line))
    end
    if detail and detail.ranges then
        for _, button in pairs(detail.ranges) do button.active:SetColorTexture(unpack(C.accent)) end
    end
    if detail and detail.plot and detail.plot.gridLines then
        for _, line in ipairs(detail.plot.gridLines) do line:SetColorTexture(unpack(C.grid)) end
    end
    if controls and controls.flashBuy and controls.flashBuy.knob then
        controls.flashBuy.knob:SetColorTexture(unpack(C.buttonText))
    end
    if controls and controls.flashSell and controls.flashSell.knob then
        controls.flashSell.knob:SetColorTexture(unpack(C.buttonText))
    end
    if controls and controls.deleteList then
        controls.deleteList.label:SetTextColor(unpack(C.danger))
        controls.deleteList:SetBackdropColor(unpack(C.dangerBg))
        controls.deleteList:SetBackdropBorderColor(unpack(C.danger))
    end
    if controls and controls.assistantPage and ns.ProfessionAssistant and ns.ProfessionAssistant.ApplyTheme then
        ns.ProfessionAssistant.ApplyTheme()
    end
    if settingsPage and ns.InfoPages and ns.InfoPages.ApplyTheme then ns.InfoPages.ApplyTheme() end
end

function UI.Layout()
    if not frame then return end
    local auction=_G.AuctionHouseFrame
    local screenWidth,screenHeight=UIParent:GetWidth(),UIParent:GetHeight()
    local scale,room
    frame:ClearAllPoints()
    if ns.open and auction and auction:IsShown() then
        local ratio=auction:GetEffectiveScale()/UIParent:GetEffectiveScale()
        room=max(1,screenWidth-(auction:GetRight() or 0)*ratio-16)
        scale=1
        frame:SetScale(scale); frame:SetPoint("TOPLEFT",auction,"TOPLEFT",5,-32)
        UI.docked=true
    else
        scale=min(1,(screenWidth-32)/W,(screenHeight-32)/H)
        frame:SetScale(scale)
        local settings=Settings()
        local position=settings.assistantWindowPoint
        if position and position.x and position.y then
            frame:SetPoint("CENTER",UIParent,"CENTER",position.x,position.y)
        else
            frame:SetPoint("CENTER",UIParent,"CENTER",0,0)
        end
        UI.docked=false; room=(screenWidth-W*scale)/2-16
    end
    UI.drawerRoom=room
    local assistant=ns.ProfessionAssistant
    if priceDetailContext=="assistant" and assistantPriceTab and assistant and assistant.tab~=assistantPriceTab then
        assistantPriceEntry,priceDetailContext,assistantPriceTab=nil,nil,nil
        UI.detailOpen=false
    end
    local professionDrawer=priceDetailContext=="assistant" and assistant and assistant.drawerOpen
        and assistant.drawers and assistant.drawers[assistant.drawerOpen]
    local drawerCount=professionDrawer and 2 or 1
    UI.drawerOverlay=UI.DrawerOffset(room,drawerCount,1,scale)<8
    if assistant and assistant.LayoutDrawer then assistant.LayoutDrawer() end
    if professionDrawer then UI.LayoutExternalDrawer(professionDrawer,1,2) end
    UI.LayoutExternalDrawer(detail,professionDrawer and 2 or 1,drawerCount)
    local entry=PriceDetailEntry()
    local assistantDetail=priceDetailContext=="assistant" and UI.tab=="assistant"
    local regularDetail=priceDetailContext~="assistant" and UI.tab~="settings" and UI.tab~="about" and UI.tab~="assistant"
    detail:SetShown(UI.detailOpen and entry~=nil and (assistantDetail or regularDetail)
        and (frame:IsShown() or (auction and auction:IsShown())))
    if UI.AttachScanFooter then UI.AttachScanFooter() end
end

function UI.OpenAssistantPriceDetail(row,sourceTab)
    local entry=NormalizedAssistantEntry(row)
    if not entry then return false end
    assistantPriceEntry=entry
    priceDetailContext="assistant"
    assistantPriceTab=sourceTab or (ns.ProfessionAssistant and ns.ProfessionAssistant.tab)
    UI.detailOpen=true
    if detail and RefreshTrend then RefreshTrend() end
    UI.Layout()
    return true
end

function UI.CloseAssistantPriceDetail()
    if priceDetailContext~="assistant" then return false end
    assistantPriceEntry,priceDetailContext,assistantPriceTab=nil,nil,nil
    UI.detailOpen=false
    UI.Layout()
    return true
end

function UI.SelectItem(entry,passive)
    if not entry or not entry.itemKey then return end
    assistantPriceEntry,priceDetailContext,assistantPriceTab=nil,nil,nil
    selected=entry; selectedBag=entry.location and entry or nil
    UI.detailOpen=Settings().autoDetails~=false; barOffset=0
    if controls then
        controls.quantity:SetText(tostring(UI.tab=="sell" and selectedBag and selectedBag.quantity or 1))
        if controls.sellPrice then controls.sellPrice:SetCopper(nil) end
    end
    ns.Store.Recent(entry.itemKey,entry.name)
    if ns.open and not passive then
        entry.queryPending,entry.queryError=true,nil
        local function failed(reason)
            entry.queryPending=false
            entry.queryError=reason or L["搜索请求失败"]
            UI.Refresh()
        end
        local ok=Invoke("Search",entry.itemKey,function(found,commodity)
            local minimum,total=nil,0
            for index,offer in ipairs(found) do
                if offer.unitPrice and offer.unitPrice>0 then
                    minimum=minimum and min(minimum,offer.unitPrice) or offer.unitPrice
                    total=total+(offer.quantity or 0)
                end
            end
            entry.unitPrice,entry.availableQuantity,entry.quoted=minimum,total,true
            entry.queryPending,entry.queryError=false,nil
            if selected==entry and UI.tab=="sell" then controls.sellPrice:SetCopper(UI.SalePrice(minimum)) end
            if selected==entry and commodity then
                local copy={}; for key,value in pairs(entry) do copy[key]=value end
                copy.itemKey={itemID=entry.itemKey.itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
                selected=copy
                if UI.directResult==entry then UI.directResult=copy end
            end
            UI.Refresh()
        end,failed)
        if ok==false then failed(UI.actionError) end
    end
    UI.Refresh(); UI.Layout()
    -- 原生浏览页点击物品时主窗体处于隐藏状态，UI.Refresh 会因 frame:IsShown() 早退，
    -- 抽屉已由 Layout 显示却无人渲染；这里针对该状态单独刷新一次。
    if RefreshTrend and detail and detail:IsShown() and frame and not frame:IsShown() then RefreshTrend() end
end

SelectList=function(list)
    selectedList=list; UI.view="list"; rows.offset=0
    UI.catalogID=nil
    if list and ns.RecipeTracker and ns.RecipeTracker.UpdateRecipeList then ns.RecipeTracker.UpdateRecipeList(list) end
    if picker then picker:Hide() end
    UI.Refresh()
    RefreshListPrices()
end

-- Shared by the selector and bounded in-game UI probes.
function UI.SelectList(list) SelectList(list) end

function UI.SelectCatalog(id)
    CloseMenus()
    if dialog then dialog:Hide() end
    if controls.deleteDialog then controls.deleteDialog:Hide() end
    UI.catalogID=id; UI.view="catalog"; UI.detailOpen=false
    UI.Refresh(); UI.Layout()
end

function UI.QuickBuyItem(entry)
    if not entry or not entry.itemKey then return end
    local copy={itemKey=entry.itemKey,name=entry.name,link=entry.link}
    UI.view="search"; UI.directResult=copy; shortRows.offset=0
    UI.searchQuantities[ns.Store.Key(copy.itemKey)]=1
    controls.search:SetText(ItemName(copy))
    UI.SelectItem(copy)
end

AddItem=function(entry,quantity,targetList)
    if not entry or not entry.itemKey then return end
    targetList=targetList or selectedList
    if not targetList then targetList=ns.Store.CreateList(L["购物清单"]); selectedList=targetList end
    local old=targetList.items[ns.Store.Key(entry.itemKey)]
    local count=(old and old.quantity or 0)+(quantity or 1)
    local ok=EditListItem(targetList.id,entry.itemKey,ItemName(entry),count,old and old.maxUnitPrice)
    if ok and entry.tag then
        local saved=targetList.items[ns.Store.Key(entry.itemKey)]
        for index,key in ipairs({"tag","groupID","groupName","groupOrder","itemOrder","variantOrder"}) do
            saved[key]=entry[key]
        end
    end
    UI.Refresh(); Say(ok and format(L["已加入 %s · %s ×%d"],targetList.name,ItemName(entry),count) or L["无法添加物品"])
    return ok
end

function UI.DropListItem()
    if UI.tab~="buy" or UI.view~="list" then return end
    local kind,id,link=GetCursorInfo()
    if kind~="item" or not id then return end
    local location=C_Cursor.GetCursorItem()
    if not location then Say(L["无法添加物品"]); return end
    local key=C_AuctionHouse.GetItemKeyFromItem(location)
    local status=C_AuctionHouse.GetItemCommodityStatus(location)
    if not key or not status or status==Enum.ItemCommodityStatus.Unknown then Say(L["无法添加物品"]); return end
    if status==Enum.ItemCommodityStatus.Commodity then
        key={itemID=key.itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
    end
    if AddItem({itemKey=key,link=link},1) then ClearCursor() end
end

local function DroppedItem()
    local kind,id,link=GetCursorInfo()
    if kind~="item" or not id then return end
    controls.search:SetText(link or tostring(id))
    ClearCursor(); Search()
end

local function TogglePicker()
    if picker:IsShown() then picker:Hide(); return end
    CloseMenus(picker); picker.addEntry=nil
    picker.owner=UI.view=="catalog" and controls.catalogTarget or controls.listPicker
    picker:ClearAllPoints()
    picker:SetPoint("TOPLEFT",picker.owner,"BOTTOMLEFT",0,-4)
    local lists=ns.Store.GetLists()
    local offset=picker.offset or 0
    offset=min(offset,max(0,#lists-8)); picker.offset=offset
    picker:SetHeight(max(48,min(8,#lists)*32+16))
    for i,button in ipairs(picker.buttons) do
        local list=lists[offset+i]; button.list=list; button:SetShown(list~=nil)
        if list then button.label:SetText(list.name) end
    end
    picker.empty:SetText(UI.view=="catalog" and L["请在购物清单标签中新建清单"] or L["先点 + 新建清单"])
    picker.empty:SetShown(#lists==0); picker:Show()
end

ShowAddPicker=function(entry,anchor)
    CloseMenus(picker); picker.addEntry=entry; picker.offset=0
    picker:ClearAllPoints(); picker:SetPoint("TOPRIGHT",anchor,"BOTTOMRIGHT",0,-4)
    picker.owner=anchor
    local lists=ns.Store.GetLists()
    picker:SetHeight(max(48,min(8,#lists)*32+16)); picker.empty:SetShown(#lists==0)
    for i,button in ipairs(picker.buttons) do
        button.list=lists[i]; button:SetShown(lists[i]~=nil)
        if lists[i] then button.label:SetText(lists[i].name) end
    end
    picker:Show()
end

local function BuildRows()
    local data={}
    local listOwner=selectedList
    if UI.view=="list" then
        local totalMissing,totalCost,pending,unknown,kinds=0,0,0,0,0
        if selectedList then
            for key,entry in pairs(selectedList.items) do
                local state=ns.Market.Restock(entry)
                if key then
                    local isSelected=selected and ns.Store.Key(selected.itemKey)==ns.Store.Key(entry.itemKey)
                    data[#data+1]={item=entry,binding=listOwner,label=ItemName(entry),selected=isSelected,target=state.target,
                        owned=state.owned,missing=state.missing,pending=state.pending,quoted=state.quoted,
                        unitPrice=state.unitPrice,maxUnitPrice=entry.maxUnitPrice,
                        canBuy=ns.open==true and state.quoted and state.unitPrice~=nil
                            and state.missing>0 and (not entry.maxUnitPrice or state.unitPrice<=entry.maxUnitPrice)}
                    if entry.includeInRestock~=false then
                        totalMissing=totalMissing+state.missing; pending=pending+(state.pending or 0)
                    end
                    if entry.includeInRestock~=false and state.missing>0 then
                        kinds=kinds+1
                        if state.unitPrice and state.quoted then totalCost=totalCost+state.missing*state.unitPrice
                        else unknown=unknown+1 end
                    end
                end
            end
            sort(data,function(a,b)
                local ag,bg=a.item.groupOrder or 999,b.item.groupOrder or 999
                if ag~=bg then return ag<bg end
                local ai,bi=a.item.itemOrder or 999,b.item.itemOrder or 999
                if ai~=bi then return ai<bi end
                if a.label~=b.label then return a.label<b.label end
                return a.item.itemKey.itemID<b.item.itemKey.itemID
            end)
        end
        controls.restockSummary:SetText(format(L["待补 %d 种 · 缺口 %d · 预计 %s%s"],kinds,totalMissing,
            totalCost>0 and Money(totalCost) or (unknown==0 and L["0 金"] or "—"),unknown>0 and format(L["  / %d 种待报价"],unknown) or ""))
        controls.pendingSummary:SetText(pending>0 and format(L["已购待收取 %d 件"],pending) or
            selectedList and selectedList.recipe and L["勾选参与一键补货的品质 · 未勾选行仍可单独购买"]
            or L["拥有：随身背包 · 报价后按最低价补货"])
        local active=BuyActive()
        controls.restockBuy.label:SetText(active and L["停止"] or L["一键补货"])
        K.Enabled(controls.restockBuy,active and not (ns.Market.unresolved and ns.Market.buy.cancelRequested)
            or (not active and ns.open==true and totalMissing>0 and unknown==0))
        restockTable:Set(data,function(row) UI.SelectItem(row.item) end,function(row,quantity)
            if listOwner then
                EditListItem(listOwner.id,row.item.itemKey,row.item.name,quantity,row.item.maxUnitPrice)
                UI.Refresh()
            end
        end,function(row) Invoke("BuyMissing",row.item) end,function(row)
            if listOwner then EditListItem(listOwner.id,row.item.itemKey,row.item.name,0); UI.Refresh() end
        end,function(row,price)
            if listOwner then
                EditListItem(listOwner.id,row.item.itemKey,row.item.name,row.item.quantity,price)
                UI.Refresh()
            end
        end,function(row,included)
            if listOwner then
                ns.Market.CancelBuy()
                ns.Store.SetRestockIncluded(listOwner.id,row.item.itemKey,included)
                UI.Refresh()
            end
        end)
        return
    else
        -- 空名称搜索会得到全拍卖行列表：selectedKey 提出循环、每行只算一次
        -- Store.Key，名称与图标由 K.Metadata 的缓存兜住，避免逐行重复解析。
        local selectedKey=selected and ns.Store.Key(selected.itemKey)
        local entries=UI.directResult and {UI.directResult} or ns.Market.browse or {}
        -- 表头点击排序：仅在整表浏览（非单品直查）时生效。
        if not UI.directResult and UI.searchSort and UI.searchSort.key then
            entries={}
            for _,entry in ipairs(ns.Market.browse or {}) do entries[#entries+1]=entry end
            local sortKey,sortDesc=UI.searchSort.key,UI.searchSort.desc
            sort(entries,function(a,b)
                local av,bv
                if sortKey=="quantity" then av,bv=a.quantity or 0,b.quantity or 0
                elseif sortKey=="unitPrice" then av,bv=a.unitPrice or 1e15,b.unitPrice or 1e15
                else av,bv=a.name or "",b.name or "" end
                if av==bv then return false end
                if sortDesc then return bv<av end
                return av<bv
            end)
        end
        for index,entry in ipairs(entries) do
            local entryKey=ns.Store.Key(entry.itemKey)
            local isSelected=selected and selectedKey==entryKey
            local buyQuantity=UI.searchQuantities[entryKey] or 1
            local canBuy=ns.open==true and not entry.queryError and entry.unitPrice~=nil and entry.unitPrice>0
            local buyReason
            if canBuy and ns.Market.CanBuyOne then
                canBuy,buyReason=ns.Market.CanBuyOne({itemKey=entry.itemKey,quantity=buyQuantity,
                    maxUnitPrice=entry.unitPrice})
            end
            data[#data+1]={item=entry,label=ItemName(entry),selected=isSelected,value=Money(entry.unitPrice),
                quantity=entry.quantity,unitPrice=entry.unitPrice,
                buyQuantity=buyQuantity,canBuy=canBuy,
                sub=entry.queryError or buyReason or (entry.quoted and ((entry.availableQuantity or 0)>0
                and format(L["在售 %d"],entry.availableQuantity) or L["暂无在售"]))
                or (UI.directResult and (entry.queryPending and L["查询中…"] or L["打开拍卖行查询实时价格"])
                or "")}
        end
    end
    local browsing=ns.Market.browseState or {}
    local waiting=browsing.pending or (browsing.active and not browsing.done)
    rows.empty:SetText(UI.view=="list" and L["拖入物品，或搜索后点 + 添加"]
        or waiting and L["搜索中…"] or L["没有搜索结果"])
    rows:Set(data,function(row)
        UI.SelectItem(row.item,false)
    end,function(row,anchor)
        if UI.view=="list" then
            EditListItem(selectedList.id,row.item.itemKey,row.item.name,0); UI.Refresh()
        else ShowAddPicker(row.item,anchor) end
    end,function(row,quantity)
        if row.buyQuantity then
            row.buyQuantity=quantity
            UI.searchQuantities[ns.Store.Key(row.item.itemKey)]=quantity
        end
    end,function(row,quantity)
        Invoke("BuyOne",{itemKey=row.item.itemKey,name=ItemName(row.item),quantity=quantity,maxUnitPrice=row.item.unitPrice})
    end)
end

local function Bags()
    local bags=ns.Market.Bags()
    local groups=ns.ViewModel.GroupBags(bags)
    local total,priced,missing=ns.ViewModel.BagValue(bags,ns.Store.GetItems())
    controls.bagValue:SetText(format(L["估值 %s%s"],priced>0 and Money(total) or "—",missing>0 and format(L[" · %d 项待报价"],missing) or ""))
    local iconIndex,headerIndex,y=0,0,0
    for index,group in ipairs(groups) do
        headerIndex=headerIndex+1
        local header=bagHeaders[headerIndex]
        if not header then header=K.Text(bagContent,"",0,0,11,C.muted,274); bagHeaders[headerIndex]=header end
        header:ClearAllPoints(); header:SetPoint("TOPLEFT",0,-y); header:SetText(group.name); header:Show(); y=y+22
        for itemIndex,entry in ipairs(group.items) do
            iconIndex=iconIndex+1
            local icon=bagIcons[iconIndex]
            if not icon then
                icon=K.Icon(bagContent,0,0,32,function(item,button)
                    if button=="RightButton" then
                        Invoke("SetLocked",item.itemKey,not ns.Market.IsLocked(item.itemKey)); UI.Refresh()
                    else UI.SelectItem(item) end
                end)
                icon.lock=K.Text(icon,L["锁"],2,-2,10,C.gold)
                bagIcons[iconIndex]=icon
            end
            icon:ClearAllPoints(); icon:SetPoint("TOPLEFT",((itemIndex-1)%7)*38,-y-floor((itemIndex-1)/7)*38)
            icon:SetEntry(entry,entry.quantity,selectedBag and selectedBag.bag==entry.bag and selectedBag.slot==entry.slot)
            icon.lock:SetShown(ns.Market.IsLocked(entry.itemKey))
            icon:Show()
        end
        y=y+ceil(#group.items/7)*38+12
    end
    for i=iconIndex+1,#bagIcons do bagIcons[i]:Hide() end
    for i=headerIndex+1,#bagHeaders do bagHeaders[i]:Hide() end
    bagContent:SetHeight(max(208,y)); groupOffset=min(groupOffset,max(0,y-208)); bagScroll:SetVerticalScroll(groupOffset)
    controls.bagEmpty:SetShown(iconIndex==0)
end

local function Bars()
    local sameSearch=selectedBag and ns.Market.search and ns.Market.search.itemKey
        and ns.Store.Key(selectedBag.itemKey)==ns.Store.Key(ns.Market.search.itemKey)
    local levels,maximum,total=ns.ViewModel.Distribution(sameSearch and ns.Market.results or {})
    distribution.levels=levels
    barOffset=min(max(0,barOffset),max(0,#levels-#bars))
    local pending=selectedBag and (selectedBag.queryPending or (sameSearch and not ns.Market.search.done))
    distribution.empty:SetText(selectedBag and selectedBag.queryError
        or pending and L["查询中…"] or selectedBag and L["暂无在售"] or L["选择左侧物品"])
    distribution.empty:SetShown(#levels==0)
    distribution.total:SetText(total>0 and format(L["在售 %d"],total) or "")
    for i,row in ipairs(bars) do
        local entry=levels[barOffset+i]; row.entry=entry; row:SetShown(entry~=nil)
        if entry then
            row.price:SetText(Money(entry.unitPrice)); row.qty:SetText(tostring(entry.quantity))
            local quick=Settings().flashSell==true
            row.sell:SetShown(quick); row.amount:SetShown(quick)
            row.price:ClearAllPoints(); row.price:SetPoint("TOPLEFT",quick and 104 or 0,-8)
            row.bar:ClearAllPoints(); row.bar:SetPoint("TOPLEFT",quick and 218 or 112,-4)
            row.bar:SetWidth(max(2,(quick and 166 or 264)*entry.quantity/max(1,maximum)))
            if row.bag~=selectedBag then
                row.bag=selectedBag; row.amount:SetText(tostring(selectedBag and selectedBag.quantity or 1))
            end
            K.Enabled(row.sell,ns.open==true and selectedBag~=nil and not ns.Market.IsLocked(selectedBag.itemKey))
            row.bar:SetColorTexture(unpack(i+barOffset==1 and C.accent or C.buttonHover))
        end
    end
    distribution.page:SetText(#levels>0 and format(L["%d–%d / %d 档"],barOffset+1,min(barOffset+#bars,#levels),#levels) or "")
end

RefreshTrend=function()
    local entry=PriceDetailEntry()
    if not detail or not entry then return end
    local key=entry.itemKey; local points,first,ending=ns.Prices.ChartTrend(key,UI.days)
    selectedIcon:SetEntry(entry)
    detail.name:SetText(ItemName(entry))
    local latest=ns.Store.GetItems()[ns.Store.Key(key)]
    detail.latest:SetText(Money(latest and latest.last))
    detail.empty:SetShown(#points==0)
    local low,high=ns.TrendPlot.Render(detail.plot,points,first,ending)
    detail.high:SetText(Money(high)); detail.low:SetText(Money(low))
    for days,button in pairs(detail.ranges) do
        local active=days==UI.days
        K.SetButtonState(button,active,false)
        button.label:SetTextColor(unpack(active and C.buttonTextActive or C.buttonText))
        button.active:SetShown(active)
    end
    local dateFormat=UI.days==1 and "%m/%d %H:%M" or "%m/%d"
    detail.start:SetText(date(dateFormat,first)); detail.ending:SetText(date(dateFormat,ending))
    detail.coverage:SetText(UI.days==1 and format(L["采样 %d / %d 小时"],#points,24)
        or format(L["采样 %d / %d 天"],#points,UI.days))
    local best=ns.Store.BestHours(key); local candidate
    for index,value in ipairs(best) do if value.days>=3 then candidate=value; break end end
    detail.advice:SetText(candidate and #best>=6 and format(L["%02d:00–%02d:00 · 覆盖 %d 天"],
        candidate.hour,(candidate.hour+1)%24,candidate.days) or L["积累 3 天后提供时段建议"])
    local days,keys={},{}
    for index,point in ipairs(ns.Store.Trend(key,7)) do
        local day=date("%Y/%m/%d",point.time)
        if not days[day] then keys[#keys+1]=day end
        if not days[day] or point.min<days[day].min then days[day]=point end
    end
    sort(keys,function(a,b) return a>b end)
    local text={}
    for i=1,min(3,#keys) do
        local point=days[keys[i]]
        text[#text+1]=date("%m/%d  %H:00",point.time).."   "..Money(point.min)
    end
    detail.daily:SetText(#text>0 and concat(text,"\n") or L["暂无采样"])
end

Search=function()
    local query=controls.search:GetText():match("^%s*(.-)%s*$")
    controls.search:ClearFocus()
    UI.tab="buy"; UI.view="search"; rows.offset=0; ns.Store.RecentQuery(query); UI.directResult=nil
    UI.searchQuantities={}; UI.catalogID=nil
    local id=tonumber(query) or tonumber(query:match("item:(%d+)"))
    if id and id>0 and id==floor(id) then
        local entry={itemKey={itemID=id,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}}
        entry.name=ItemName(entry)
        local info=C_AuctionHouse.GetItemKeyInfo(entry.itemKey)
        if info and info.isCommodity then UI.directResult=entry; UI.SelectItem(entry)
        else
            local name=C_Item.GetItemInfo(query:find("item:",1,true) and query or id)
            UI.detailOpen=false
            if name then Invoke("Browse",name,BrowseFilterOptions()) else Say(L["物品尚未缓存，请使用名称搜索"]); return end
        end
    else
        UI.detailOpen=false; Invoke("Browse",query,BrowseFilterOptions())
    end
    UI.Refresh(); UI.Layout()
end

-- Historical non-commodity keys may be synthetic; resolve live variants through browse first.
function UI.SearchAuctionItem(entry)
    if not ns.open or not entry or not entry.itemKey then return false end
    UI.Open("buy")
    local info=C_AuctionHouse.GetItemKeyInfo(entry.itemKey)
    if info and info.isCommodity then
        UI.QuickBuyItem(entry)
    else
        controls.search:SetText(ItemName(entry))
        Search()
    end
    return true
end

function UI.InsertSearchLink(link)
    if not frame or not frame:IsShown() or (UI.tab~="buy" and UI.tab~="assistant")
        or dialog:IsShown() or not IsShiftKeyDown() or type(link)~="string" then return end
    local id=link:match("item:(%d+)")
    if not id then return end
    local name=C_Item.GetItemInfo(link) or link:match("%[([^%]]+)%]")
    if not name then return end
    if UI.tab=="assistant" and ns.ProfessionAssistant then return ns.ProfessionAssistant.InsertSearchLink(name) end
    controls.search:SetText(name); controls.search:SetFocus(); controls.search:HighlightText()
end

local function InitDialog()
    dialog=K.Surface(frame,10,-12,W-20,426); dialog:SetFrameLevel(frame:GetFrameLevel()+40)
    dialog:EnableMouse(true)
    dialog.title=K.Text(dialog,"",16,-16,16,C.text,440)
    K.Button(dialog,"×",W-60,-10,26,function() dialog:Hide() end)
    dialog.name=K.Edit(dialog,16,-50,W-52)
    dialog.help=K.Text(dialog,"",16,-90,11,C.muted,W-52)
    dialog.editorBorder=K.Surface(dialog,16,-114,W-52,248)
    local viewport=CreateFrame("ScrollFrame",nil,dialog.editorBorder)
    viewport:SetPoint("TOPLEFT",8,-8); viewport:SetSize(W-68,232)
    dialog.viewport=viewport
    local editor=CreateFrame("EditBox",nil,viewport)
    editor:SetMultiLine(true); editor:SetAutoFocus(false); editor:SetMaxLetters(65536)
    editor:SetFontObject("ChatFontNormal"); editor:SetWidth(W-84); editor:SetHeight(232)
    editor:SetTextInsets(4,4,4,4)
    viewport:SetScrollChild(editor); dialog.editor=editor
    local example=L["例如：物品ID  数量  单价上限(金)\n\n241322  20  450\n191393  10  2.5\n\n也可粘贴导出的 EA12 清单分享码"]
    dialog.example=K.Text(dialog.editorBorder,example,12,-14,12,C.muted,W-80)
    dialog.example:SetWordWrap(true); dialog.example:SetAlpha(0.45)
    dialog.editorBorder:EnableMouse(true)
    dialog.editorBorder:SetScript("OnMouseDown",function() editor:SetFocus() end)
    editor:SetScript("OnEditFocusGained",function() dialog.editorBorder:SetBackdropBorderColor(unpack(C.accent)) end)
    editor:SetScript("OnEditFocusLost",function() dialog.editorBorder:SetBackdropBorderColor(unpack(C.line)) end)
    editor:SetScript("OnEscapePressed",function(self) self:ClearFocus(); dialog:Hide() end)
    editor:SetScript("OnTextChanged",function(self)
        local text=self:GetText() or ""; local lines=1
        dialog.example:SetShown(dialog.mode=="import" and text=="")
        for line in text:gmatch("\n") do if line then lines=lines+1 end end
        self:SetHeight(max(232,lines*18+40))
    end)
    viewport:EnableMouseWheel(true); viewport:SetScript("OnMouseWheel",function(self,delta)
        self:SetVerticalScroll(max(0,min(editor:GetHeight()-232,(self:GetVerticalScroll() or 0)-delta*36)))
    end)
    editor:SetScript("OnCursorChanged",function(self,x,y,width,height)
        local scroll=viewport:GetVerticalScroll() or 0; local offset=-y
        if offset<scroll then viewport:SetVerticalScroll(max(0,offset))
        elseif offset+height>scroll+232 then viewport:SetVerticalScroll(offset+height-232) end
    end)
    dialog.message=K.Text(dialog,"",16,-367,11,C.gold,W-180)
    dialog.ok=K.Button(dialog,L["确定"],W-160,-384,124,function()
        if dialog.mode=="import" then
            local list,errorText=ns.Store.ImportList(editor:GetText())
            if not list then dialog.message:SetText(errorText or L["导入失败"]); return end
            SelectList(list)
        elseif dialog.mode=="new" then
            local list=ns.Store.CreateList(dialog.name:GetText())
            if not list then dialog.message:SetText(L["请输入清单名称"]); return end
            SelectList(list)
        elseif dialog.mode=="rename" and selectedList then
            if not ns.Store.RenameList(selectedList.id,dialog.name:GetText()) then dialog.message:SetText(L["请输入清单名称"]); return end
        end
        dialog:Hide(); UI.Refresh()
    end,true)
    dialog:Hide()
end

ShowDialog=function(mode)
    if mode=="export" and not selectedList then Say(L["先创建清单"]); return end
    CloseMenus(); dialog.mode=mode; dialog.message:SetText(""); dialog.viewport:SetVerticalScroll(0)
    local textMode=mode=="import" or mode=="export"
    dialog.name:SetShown(not textMode); dialog.editorBorder:SetShown(textMode); dialog.viewport:SetShown(textMode)
    dialog.example:SetShown(mode=="import")
    dialog.help:SetText(mode=="import" and L["粘贴分享码，或每行：物品ID 数量 [最高单价金]"]
        or mode=="export" and L["Ctrl+A 全选 · Ctrl+C 复制"] or L["清单名称"])
    dialog.title:SetText(({new=L["新建清单"],rename=L["重命名"],import=L["导入清单"],export=L["导出清单"]})[mode])
    dialog.ok.label:SetText(mode=="import" and L["导入为新清单"] or mode=="export" and L["完成"] or L["保存"])
    dialog.name:SetText(mode=="rename" and selectedList and selectedList.name or "")
    if mode=="export" then
        local text,errorText=ns.Store.ExportList(selectedList.id)
        dialog.editor:SetText(text or "")
        dialog.message:SetText(errorText or (selectedList.recipe and L["仅导出已勾选的补货材料。"] or ""))
    else dialog.editor:SetText("") end
    dialog:Show()
    if textMode then dialog.editor:SetFocus(); dialog.editor:HighlightText() else dialog.name:SetFocus() end
end

local function InitClearDialog()
    clearDialog=K.Surface(frame,10,-12,W-20,426); clearDialog:SetFrameLevel(frame:GetFrameLevel()+45)
    clearDialog:EnableMouse(true)
    K.Text(clearDialog,L["确认清包"],16,-16,16,C.gold)
    K.Text(clearDialog,L["按当前最低价逐笔上架；锁定物品不会出售。"],16,-48,12,C.text)
    K.Text(clearDialog,L["上架会收取保管费；停止只取消后续物品，已上架物品不会撤回。"],16,-72,11,C.muted)
    K.Text(clearDialog,L["物品"],62,-100,10,C.muted,300)
    K.Text(clearDialog,L["数量"],W-340,-100,10,C.muted,110)
    K.Text(clearDialog,L["单价"],W-218,-100,10,C.muted,140)
    clearDialog.rows=K.Rows(clearDialog,16,-118,W-52,5)
    for index,row in ipairs(clearDialog.rows.rows) do
        K.Hint(row.action,L["移除"],L["移除"])
    end
    clearDialog.summary=K.Text(clearDialog,"",16,-348,12,C.gold,W-52)
    clearDialog.message=K.Text(clearDialog,"",16,-372,10,C.muted,W-210)
    local function cancel() Invoke("CancelClearBags"); clearDialog:Hide(); UI.Refresh() end
    K.Button(clearDialog,"×",W-60,-10,26,cancel)
    K.Button(clearDialog,L["取消"],W-250,-384,76,cancel)
    clearDialog.ok=K.Button(clearDialog,L["确认上架"],W-160,-384,124,function()
        for index,row in ipairs(clearDialog.rows.rows) do
            if row.qty:HasFocus() then row.qty:ClearFocus() end
        end
        if Invoke("ConfirmClearBags") then clearDialog:Hide() end
        UI.Refresh()
    end,true)
    clearDialog:Hide()
end

RefreshClearDialog=function()
    if not clearDialog or not clearDialog:IsShown() then return end
    local state=ns.Market.clear or {}; local data={}
    for index,entry in ipairs(state.entries or {}) do
        local item=entry.bagRow or entry
        data[#data+1]={item=item,clearEntry=entry,label=ItemName(item),
            editQuantity=entry.quantity,maxQuantity=item.quantity or entry.quantity,
            quantityColumn=true,editable=state.state=="ready",action="×",
            value=format(L["%s / 件"],Money(entry.unitPrice))}
    end
    clearDialog.rows.empty:SetText(state.state=="quoting" and L["正在逐项查询最低价…"] or L["没有可上架物品"])
    clearDialog.rows:Set(data,function() end,function(row)
        Invoke("RemoveClearBagsEntry",row.clearEntry); UI.Refresh()
    end,function(row,quantity)
        Invoke("SetClearBagsQuantity",row.clearEntry,quantity); UI.Refresh()
    end)
    clearDialog.summary:SetText(format(L["%d 笔 · 预计 %s · 跳过 %d 项"],#data,Money(state.total),state.skipped or 0))
    clearDialog.message:SetText(state.message or L["不含保管费与成交手续费"])
    K.Enabled(clearDialog.ok,state.state=="ready" and #data>0)
end

local function ScanElapsed(seconds)
    seconds=max(0,tonumber(seconds) or 0)
    return format("%02d:%02d",floor(seconds/60),floor(seconds%60))
end

local function ScanRatio(scan)
    local total=tonumber(scan and scan.total) or 0
    local done=tonumber(scan and scan.index) or 0
    local loaded=max(0,done-(tonumber(scan and scan.pendingCount) or 0))
    return total>0 and min(1,loaded/total) or 0,total,done
end

function UI.RefreshScanFooter()
    if not scanFooter then return end
    local scan=ns.Market.Snapshot().scan or {}
    local total=tonumber(scan.total) or 0
    local done=tonumber(scan.index) or 0
    local active=scan.active==true
    local quoting=ns.Market.listRefresh and ns.Market.listRefresh.state=="quoting"
    scanFooter.button.label:SetText(active and L["停止扫描"] or L["扫描拍卖"])
    K.Enabled(scanFooter.button,active or (ns.open==true and not quoting))
    local text
    if active then
        text=scan.state=="loading" and format(L["已处理 %d / %d 条 · 等待资料 %d 项 · 跳过 %d 条"],
            done,total,scan.pendingCount or 0,scan.skipped or 0)
            or total>0 and format(L["已处理 %d / %d 条 · 跳过 %d 条"],done,total,scan.skipped or 0)
            or L["拍卖行正在准备扫描数据，请稍候"]
    elseif scan.state=="complete" then
        text=format(L["已扫描 %d 条 · 跳过 %d 条"],total,scan.skipped or 0)
    elseif scan.state=="failed" then text=scan.failureReason or L["全量扫描未完成"]
    elseif scan.state=="cancelled" then text=L["扫描已停止"]
    else text="" end
    scanFooter.status:SetText(text)
end

function UI.ToggleMarketScan()
    local scan=ns.Market.Snapshot().scan or {}
    local wasActive=scan.active==true
    if not wasActive and ns.Market.listRefresh and ns.Market.listRefresh.state=="quoting" then
        UI.RefreshScanFooter()
        return false
    end
    local ok,errorText
    if wasActive then ok,errorText=ns.Market.CancelScan()
    else ok,errorText=ns.Market.Scan() end
    if ok and not wasActive and controls and controls.scanDialog then
        controls.scanDialog.requested=true
        controls.scanDialog._refresh=0
    elseif not ok then UI.actionError=errorText or L["操作未完成"] end
    UI.RefreshScanFooter()
    UI.RefreshScanDialog()
    UI.Refresh()
    return ok,errorText
end

function UI.AttachScanFooter()
    local auction=_G.AuctionHouseFrame
    if not auction then return false end
    if not scanFooter then
        scanFooter=CreateFrame("Frame","EasyAuctionScanFooter",auction)
        scanFooter:SetSize(360,22); scanFooter:SetFrameLevel(auction:GetFrameLevel()+10)
        scanFooter.button=K.Button(scanFooter,L["扫描拍卖"],0,0,108,UI.ToggleMarketScan,true)
        scanFooter.button:ClearAllPoints(); scanFooter.button:SetPoint("LEFT",scanFooter,"LEFT",0,0)
        scanFooter.button:SetSize(108,22)
        -- 状态文字限宽放在按钮右侧：脚注只占金额旁一小块，不再横跨底部
        -- 压住原生拍卖的出价/竞标按钮；扫描中的详细进度由扫描弹窗展示。
        scanFooter.status=K.Text(scanFooter,"",116,-6,10,C.muted,240)
        scanFooter:SetScript("OnUpdate",function(self,elapsed)
            self._refresh=(self._refresh or 0)+elapsed
            if self._refresh>=0.25 then self._refresh=0; UI.RefreshScanFooter() end
        end)
    end
    if scanFooter:GetParent()~=auction then scanFooter:SetParent(auction) end
    scanFooter:ClearAllPoints()
    local money=auction.MoneyFrameBorder
    if money then scanFooter:SetPoint("LEFT",money,"RIGHT",10,0)
    else scanFooter:SetPoint("BOTTOMLEFT",auction,"BOTTOMLEFT",171,6) end
    scanFooter:SetShown(ns.open==true and auction:IsShown())
    UI.RefreshScanFooter()
    return true
end

UI.RefreshScanDialog=function()
    local scanDialog=controls and controls.scanDialog
    if not scanDialog then return end
    local scan=ns.Market.Snapshot().scan or {}
    local terminal=scan.state=="complete" or scan.state=="failed" or scan.state=="cancelled"
    if scan.state=="complete" and not scan.active and scanDialog.completedScan~=scan then
        scanDialog.completedScan=scan; scanDialog.requested=true
    end
    local canReload=scanDialog.requested and scan.state=="complete" and not scan.active
    scanDialog.reload:SetShown(canReload)
    K.Enabled(scanDialog.reload,canReload)
    K.SetButtonState(scanDialog.action,scan.active==true,false)
    if not scanDialog.requested or (not scan.active and not terminal) then
        scanDialog:Hide(); return
    end
    scanDialog:Show()
    local ratio,total,done=ScanRatio(scan)
    scanDialog.fill:SetWidth(max(8,scanDialog.progressWidth*ratio))
    if scan.active then
        scanDialog.title:SetText(L["全量扫描进行中"])
        local phase=scan.state=="processing" and L["正在读取拍卖数据并合并价格…"]
            or scan.state=="loading" and L["正在等待物品资料加载…"]
            or L["正在等待拍卖行返回数据…"]
        scanDialog.phase:SetText(phase)
        local scanDetail=scan.state=="loading"
            and format(L["已处理 %d / %d 条 · 等待资料 %d 项 · 跳过 %d 条"],done,total,scan.pendingCount or 0,scan.skipped or 0)
            or total>0 and format(L["已处理 %d / %d 条 · 跳过 %d 条"],done,total,scan.skipped or 0)
            or L["拍卖行正在准备扫描数据，请稍候"]
        scanDialog.detail:SetText(scanDetail)
        scanDialog.elapsed:SetText(format(L["已用时 %s"],ScanElapsed(scan.elapsed)))
        scanDialog.hint:SetText(scan.state=="loading" and L["正在补齐物品资料，资料返回后会继续合并价格。"]
            or L["扫描期间请保持拍卖行打开；数据完成后才会写入价格库。"])
        scanDialog.action.label:SetText(L["停止扫描"])
        scanDialog.fill:SetColorTexture(unpack(C.accent))
    elseif scan.state=="complete" then
        scanDialog.title:SetText(L["全量扫描完成"])
        scanDialog.phase:SetText(L["价格数据已合并并写入当前价格库"])
        scanDialog.detail:SetText(format(L["已处理 %d 条 · 跳过 %d 条"],total,scan.skipped or 0))
        scanDialog.elapsed:SetText(format(L["总用时 %s"],ScanElapsed(scan.elapsed)))
        scanDialog.hint:SetText(L["请重载界面，将行情数据保存到本地。"])
        scanDialog.action.label:SetText(L["关闭"])
        scanDialog.fill:SetWidth(scanDialog.progressWidth); scanDialog.fill:SetColorTexture(unpack(C.gold))
    elseif scan.state=="failed" then
        scanDialog.title:SetText(L["全量扫描未完成"])
        scanDialog.phase:SetText(scan.failureReason or L["拍卖行未在限定时间内完成返回"])
        scanDialog.detail:SetText(format(L["已处理 %d / %d 条"],done,total))
        scanDialog.elapsed:SetText(format(L["已用时 %s"],ScanElapsed(scan.elapsed)))
        scanDialog.hint:SetText(L["本次未完成的数据不会写入价格库；已处理数据也不会部分写入，请稍后重试。"])
        scanDialog.action.label:SetText(L["关闭"])
        scanDialog.fill:SetColorTexture(0.85,0.35,0.30,1)
    else
        scanDialog.title:SetText(L["扫描已停止"])
        scanDialog.phase:SetText(L["已停止后续读取"])
        scanDialog.detail:SetText(format(L["已处理 %d / %d 条"],done,total))
        scanDialog.elapsed:SetText(format(L["已用时 %s"],ScanElapsed(scan.elapsed)))
        scanDialog.hint:SetText(L["未完成的数据不会写入价格库。"])
        scanDialog.action.label:SetText(L["关闭"])
        scanDialog.fill:SetColorTexture(unpack(C.muted))
    end
end

UI.InitScanDialog=function()
    local scanDialog=K.Surface(frame,0,0,360,214); controls.scanDialog=scanDialog
    scanDialog:SetFrameLevel(frame:GetFrameLevel()+50)
    scanDialog:SetPoint("CENTER",frame,"CENTER",0,0); scanDialog:EnableMouse(true); scanDialog.requested=false
    scanDialog.title=K.Text(scanDialog,L["全量扫描"],18,-18,16,C.gold,324)
    scanDialog.phase=K.Text(scanDialog,"",18,-50,12,C.text,324)
    scanDialog.progress=K.Surface(scanDialog,18,-76,324,20)
    scanDialog.progressWidth=324
    scanDialog.fill=scanDialog.progress:CreateTexture(nil,"ARTWORK"); scanDialog.fill:SetPoint("TOPLEFT"); scanDialog.fill:SetHeight(20)
    scanDialog.detail=K.Text(scanDialog,"",18,-112,11,C.text,324)
    scanDialog.elapsed=K.Text(scanDialog,"",18,-136,11,C.gold,324)
    scanDialog.hint=K.Text(scanDialog,"",18,-160,10,C.muted,324); scanDialog.hint:SetWordWrap(true)
    scanDialog.action=K.Button(scanDialog,L["停止扫描"],18,-184,126,function()
        local scan=ns.Market.Snapshot().scan or {}
        if scan.active then Invoke("CancelScan") else scanDialog.requested=false; scanDialog:Hide() end
        UI.Refresh()
    end,true)
    scanDialog.reload=K.Button(scanDialog,L["重载并保存"],162,-184,180,function()
        local scan=ns.Market.Snapshot().scan or {}
        if scanDialog.requested and scan.state=="complete" and not scan.active then ReloadUI() end
    end,true)
    scanDialog.reload:Hide(); K.Enabled(scanDialog.reload,false)
    K.Button(scanDialog,"×",318,-10,26,function()
        local scan=ns.Market.Snapshot().scan or {}
        if scan.active then Invoke("CancelScan") end
        scanDialog.requested=false; scanDialog:Hide(); UI.Refresh()
    end)
    scanDialog:SetScript("OnUpdate",function(self,elapsed)
        if not self:IsShown() then return end
        self._refresh=(self._refresh or 0)+elapsed
        if self._refresh>=0.25 then self._refresh=0; UI.RefreshScanDialog() end
    end)
    scanDialog:Hide()
end

function UI.SelectTab(tab)
    if tab=="price" then
        tab="assistant"
        if ns.ProfessionAssistant then ns.ProfessionAssistant.SelectTab("prices") end
    end
    if tab~="buy" and tab~="sell" and tab~="assistant" and tab~="settings" and tab~="about" then return end
    if UI.tab=="assistant" and tab~="assistant" then
        assistantPriceEntry,priceDetailContext,assistantPriceTab=nil,nil,nil
        if ns.ProfessionPosting then ns.ProfessionPosting.Cancel() end
    end
    if UI.tab~=tab then ns.Market.CancelBuy(); ns.Market.CancelClearBags() end
    UI.tab=tab; UI.view=tab=="buy" and "list" or "search"; UI.detailOpen=false; UI.catalogID=nil
    selectedBag=nil; barOffset=0; groupOffset=0
    if rows then rows.offset=0 end
    if picker then picker:Hide() end
    if recentPicker then recentPicker:Hide() end
    if dialog then dialog:Hide() end
    if controls and controls.deleteDialog then controls.deleteDialog:Hide() end
    if clearDialog then clearDialog:Hide() end
    UI.Refresh(); UI.Layout()
    if tab=="assistant" and not controls.assistantPage and ns.ProfessionAssistant then
        local function createAssistant()
            assistantPending=false
            if not frame or not frame:IsShown() or UI.tab~="assistant" or controls.assistantPage then return end
            controls.assistantPage=ns.ProfessionAssistant.Create(frame)
            controls.assistantPage:SetShown(true)
            UI.Refresh(); UI.Layout()
        end
        if assistantPending then
            createAssistant()
        elseif C_Timer and C_Timer.After then
            assistantPending=true; C_Timer.After(0,createAssistant)
        else
            createAssistant()
        end
    end
    if tab=="buy" then RefreshListPrices() end
end

function UI.Refresh()
    if not frame or not frame:IsShown() or not ns.ready then return end
    if not selectedList then selectedList=ns.Store.GetLists()[1] end
    local buying=UI.tab=="buy"; local selling=UI.tab=="sell"
    local settings=UI.tab=="settings"
    local infoPage=settings or UI.tab=="about" or UI.tab=="assistant"
    local restocking=buying and UI.view=="list"
    local quick=selling and Settings().flashSell==true
    local flashBuy=Settings().flashBuy==true
    controls.flashBuy:SetShown(buying)
    controls.flashBuy.label:SetText(flashBuy and L["闪购：开"] or L["闪购：关"])
    K.SetButtonState(controls.flashBuy,flashBuy,false)
    controls.flashBuy.indicator:SetColorTexture(unpack(flashBuy and C.accent or C.muted))
    controls.flashBuy.knob:ClearAllPoints(); controls.flashBuy.knob:SetPoint("LEFT",flashBuy and 105 or 91,0)
    controls.listTools:SetShown(restocking)
    controls.search:SetShown(not selling and not infoPage); controls.searchButton:SetShown(not selling and not infoPage)
    controls.saleSelection:SetShown(selling)
    controls.saleIcon:SetShown(selling and selectedBag~=nil)
    if selling then
        controls.saleName:SetText(selectedBag and ItemName(selectedBag) or L["从下方选择待售物品"])
        if selectedBag then controls.saleIcon:SetEntry(selectedBag,selectedBag.quantity) end
    end
    controls.sellTitle:SetShown(selling)
    controls.bagValue:SetShown(selling)
    controls.sellDividers:SetShown(selling)
    controls.listPicker.label:SetText(selectedList and selectedList.name.."  v" or L["选择清单  v"])
    K.Enabled(controls.export,selectedList~=nil); K.Enabled(controls.rename,selectedList~=nil)
    K.Enabled(controls.deleteList,selectedList~=nil)
    shortRows:SetShown(buying and UI.view=="search")
    restockTable:SetShown(restocking); restockFooter:SetShown(restocking)
    UI.RefreshCatalogTabs(buying)
    settingsPage:SetShown(settings)
    controls.aboutPage:SetShown(UI.tab=="about")
    if controls.assistantPage then
        controls.assistantPage:SetShown(UI.tab=="assistant")
        if UI.tab=="assistant" then ns.ProfessionAssistant.Refresh() end
    end
    bagScroll:SetShown(selling); distribution:SetShown(selling)
    trade:SetShown(buying or selling)
    trade:ClearAllPoints(); trade:SetPoint("TOPLEFT",12,buying and -414 or -350)
    controls.quantity:SetShown(selling and not quick); controls.quantity.caption:SetShown(selling and not quick)
    controls.sellPrice:SetShown(selling and not quick); controls.sellPrice.caption:SetShown(selling and not quick)
    controls.sellActions:SetShown(selling)
    controls.post:SetShown(not quick)
    controls.duration:ClearAllPoints(); controls.duration:SetPoint("TOPLEFT",quick and 0 or 324,-18)
    controls.lock:SetShown(selling)
    controls.lock.label:SetText(selectedBag and ns.Market.IsLocked(selectedBag.itemKey) and L["解锁物品"] or L["锁定物品"])
    K.Enabled(controls.lock,selectedBag~=nil)
    controls.flashSell:SetShown(selling)
    controls.flashSell.label:SetText(L["闪卖"])
    K.SetButtonState(controls.flashSell,quick,false)
    controls.flashSell.indicator:SetColorTexture(unpack(quick and C.accent or C.muted))
    controls.flashSell.knob:ClearAllPoints(); controls.flashSell.knob:SetPoint("LEFT",quick and 105 or 91,0)
    controls.clearBags:SetShown(quick)
    local clearState=ns.Market.clear and ns.Market.clear.state
    controls.clearContinue:SetShown(quick and clearState=="needs-click")
    controls.clearStop:SetShown(quick and (clearState=="running" or clearState=="quoting" or clearState=="needs-click"))
    K.Enabled(controls.clearBags,ns.open==true and clearState~="running" and clearState~="quoting" and clearState~="needs-click")
    controls.viewList:SetShown(buying and UI.view=="search")
    controls.filter:SetShown(buying and UI.view=="search")
    if controls.filterPanel and controls.filterPanel:IsShown() and not (buying and UI.view=="search") then
        controls.filterPanel:Hide()
    end
    controls.viewList.label:SetText(UI.catalogID and L["返回目录"] or L["返回清单"])
    controls.recent:SetShown(buying)
    controls.recent:ClearAllPoints(); controls.recent:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,-18)
    controls.refreshList:SetShown(restocking)
    local refresh=ns.Market.listRefresh or {}
    controls.refreshList.label:SetText(refresh.state=="quoting" and L["查询中…"] or L["刷新报价"])
    K.Enabled(controls.refreshList,ns.open==true and refresh.state~="quoting")
    controls.detail:SetShown(selected~=nil and not infoPage)
    controls.detail:ClearAllPoints(); controls.detail:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,buying and -52 or -18)
    controls.detail.label:SetText(UI.detailOpen and L["收起详情"] or L["价格详情"])
    controls.offlineClose:SetShown(not ns.open)
    if selling then Bags(); Bars() elseif not infoPage and UI.view~="catalog" then BuildRows() end
    controls.autoDetails.label:SetText(Settings().autoDetails~=false and L["自动展开：开"] or L["自动展开：关"])
    controls.itemTooltip.label:SetText(Settings().itemTooltip==true and L["行情提示：开"] or L["行情提示：关"])
    if controls.theme and ns.Style then
        if controls.theme.SetValue then controls.theme:SetValue(ns.Style:Palette().key)
        else controls.theme.label:SetText(ns.Style:Palette().name) end
    end
    controls.historyDays.label:SetText(({[1]=L["24 小时"],[7]=L["7 天"],[30]=L["30 天"]})[Settings().historyDays] or L["24 小时"])
    controls.defaultDuration.label:SetText(({L["12 小时"],L["24 小时"],L["48 小时"]})[Settings().duration or 1])
    controls.undercut.label:SetText(Settings().undercut and L["压价：开"] or L["压价：关"])
    K.SetButtonState(controls.undercut,Settings().undercut==true,false)
    for fieldName,field in pairs(controls.undercutAmount.fields) do
        field:SetAlpha(Settings().undercut and 1 or 0.45); field:SetEnabled(Settings().undercut)
    end
    local snapshot=ns.Market.Snapshot(); local buy=snapshot.buy or {}; local post=snapshot.post or {}
    K.Enabled(controls.post,ns.open==true and selectedBag~=nil and not ns.Market.IsLocked(selectedBag.itemKey))
    local confirmPost=post.state=="warning" and not post.clear
    local confirmReady=buy.state=="ready" and not buy.restockBatch
    K.Enabled(controls.confirm,ns.open==true and (confirmReady or buy.state=="needs-click" or confirmPost))
    controls.confirm.label:SetText(confirmReady and format(L["确认 %s"],Money(buy.total)) or L["继续"])
    controls.confirm:SetShown(confirmReady or buy.state=="needs-click" or confirmPost)
    controls.confirm:ClearAllPoints()
    if restocking then controls.confirm:SetPoint("TOPLEFT",522,12)
    elseif buying then controls.confirm:SetPoint("TOPRIGHT",trade,"TOPRIGHT",0,-4)
    else controls.confirm:SetPoint("TOPLEFT",544,-18) end
    controls.restockSummary:SetWidth(restocking and controls.confirm:IsShown() and W-286 or W-152)
    controls.stop:SetShown(not restocking and buy.state~=nil and buy.state~="cancelled"
        and buy.state~="complete" and buy.state~="failed")
    controls.stop:ClearAllPoints()
    if buying and not restocking then controls.stop:SetPoint("RIGHT",controls.confirm,"LEFT",-8,0)
    else controls.stop:SetPoint("TOPLEFT",restocking and 478 or 352,restocking and -18 or -58) end
    restockTable.prev:SetShown(not controls.stop:IsShown())
    restockTable.next:SetShown(not controls.stop:IsShown())
    restockTable.page:SetShown(not controls.stop:IsShown())
    frame.status:SetWidth(restocking and W-256 or W-24)
    controls.quantity.caption:SetText(selling and L["数量"] or L["购买数量"])
    local status=ns.open and "" or L["离线价格库"]
    if snapshot.scan and snapshot.scan.active then status=snapshot.message
    elseif buy.state and buy.state~="cancelled" then status=snapshot.message or ""
    elseif snapshot.scan and snapshot.scan.state=="complete" then
        status=format(L["已扫描 %d 条 · 跳过 %d 条"],snapshot.scan.total,snapshot.scan.skipped or 0)
    end
    if selling and post.state then
        status=({submitted=L["等待上架回执"],complete=L["上架成功"],warning=L["物品需要再次确认"],failed=L["上架失败"],
            uncertain=L["回执未确定，请核对我的拍卖"],cancelled=L["已取消"]})[post.state] or status
    end
    local batch=ns.Market.clear
    if selling and batch and batch.state and batch.state~="cancelled" then
        status=batch.message or format(L["清包：已上架 %d / %d 笔"],batch.posted or 0,#(batch.entries or {}))
    end
    local actionError=UI.actionError or ns.lastError or (selling and selectedBag and selectedBag.queryError)
    if actionError then status=actionError end
    RefreshClearDialog()
    UI.RefreshScanDialog()
    UI.RefreshScanFooter()
    frame.status:SetShown(not infoPage)
    Say(status); RefreshTrend()
end

function UI.InitCatalog()
    if not K.PresetCatalog then return end
    controls.catalog=K.PresetCatalog(frame,12,-130,W-24,function(list,entry,button)
        if button=="RightButton" then UI.QuickBuyItem(entry); return end
        local existing=list and list.items[ns.Store.Key(entry.itemKey)]
        if existing then
            SelectList(list)
        else
            AddItem(entry,entry.quantity or 1,list)
        end
    end)
    controls.catalogTabs=CreateFrame("Frame",nil,frame)
    controls.catalogTabs:SetPoint("TOPLEFT",12,-52); controls.catalogTabs:SetSize(W-24,28)
    controls.catalogTabs.buttons={}
    controls.catalogTabs.shopping=K.Button(controls.catalogTabs,L["购物清单"],0,0,120,function() SelectList(selectedList) end)
    K.ButtonIcon(controls.catalogTabs.shopping,K.CatalogIcon("shopping"))
    controls.catalogTarget=K.Button(frame,"",12,-86,280,TogglePicker)
    K.Hint(controls.catalogTarget,L["添加到购物清单"],L["选择目录物品的加入目标；切换清单不会离开当前目录。"])
    controls.catalog:Hide(); controls.catalogTarget:Hide()
end

function UI.RefreshCatalogTabs(visible)
    if not controls.catalogTabs then return end
    controls.catalogTabs:SetShown(visible)
    local catalogShown=visible and UI.view=="catalog"
    controls.catalog:SetShown(catalogShown)
    controls.catalogTarget:SetShown(catalogShown)
    controls.catalogTarget.label:SetText(selectedList and format(L["添加到：%s  v"],selectedList.name) or L["选择购物清单  v"])
    for index,catalog in ipairs(ns.Presets and ns.Presets.Catalogs() or {}) do
        local button=controls.catalogTabs.buttons[index]
        if not button then
            button=K.Button(controls.catalogTabs,"",index*126,0,120,function(self)
                CloseMenus(); UI.SelectCatalog(self.catalog.presetID)
            end)
            controls.catalogTabs.buttons[index]=button
        end
        button.catalog=catalog; button.label:SetText(catalog.name)
        K.ButtonIcon(button,K.CatalogIcon(catalog.presetID))
        local active=UI.catalogID==catalog.presetID
        K.SetButtonState(button,active,false)
        button.label:SetTextColor(unpack(active and C.buttonTextActive or C.buttonText))
        if catalogShown and active then controls.catalog:Set(catalog,selectedList) end
    end
        controls.catalogTabs.shopping.label:SetTextColor(unpack(UI.view=="list" and C.buttonTextActive or C.buttonText))
        K.SetButtonState(controls.catalogTabs.shopping,UI.view=="list",false)
end

function UI.ShowDeleteList()
    if not selectedList then return end
    CloseMenus()
    if not controls.deleteDialog then
        local modal=K.Surface(frame,0,0,380,156); controls.deleteDialog=modal
        modal:ClearAllPoints(); modal:SetPoint("CENTER",frame,"CENTER")
        modal:SetFrameLevel(frame:GetFrameLevel()+60); modal:EnableMouse(true)
        K.Text(modal,L["删除购物清单"],18,-16,15,C.gold)
        modal.message=K.Text(modal,"",18,-48,12,C.text,344); modal.message:SetWordWrap(true)
        modal.cancel=K.Button(modal,L["取消"],170,-112,86,function() modal:Hide() end)
        modal.confirm=K.Button(modal,L["删除"],266,-112,96,function()
            local target=modal.list
            if not target then return end
            ns.Market.CancelBuy()
            if ns.Market.listRefresh and ns.Market.listRefresh.state=="quoting" then ns.Market.Cancel() end
            if ns.Store.DeleteList(target.id) then
                if selectedList==target then SelectList(ns.Store.GetLists()[1]) end
            end
            modal.list=nil; modal:Hide(); UI.Refresh()
        end,true)
    end
    controls.deleteDialog.list=selectedList
    controls.deleteDialog.message:SetText(format(L["删除“%s”及其购物目标？\n价格历史会保留。"],selectedList.name))
    controls.deleteDialog:Show()
end

function UI.Init()
    if frame then return end
    controls={}
    frame=CreateFrame("Frame","EasyAuctionWorkbench",UIParent,"BackdropTemplate")
    frame:SetSize(W,H); frame:SetFrameStrata("HIGH"); frame:EnableMouse(true)
    frame:SetMovable(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart",function(self)
        if not UI.docked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop",function(self)
        self:StopMovingOrSizing()
        if UI.docked then return end
        local x,y=self:GetCenter(); local parentX,parentY=UIParent:GetCenter()
        local scale=self:GetScale() or 1
        if x and y and parentX and parentY then
            Settings().assistantWindowPoint={x=(x-parentX)/scale,y=(y-parentY)/scale}
        end
    end)
    frame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=2})
    frame:SetBackdropColor(unpack(C.bg)); frame:SetBackdropBorderColor(unpack(C.line)); frame:Hide()
    controls.detail=K.Button(frame,L["价格详情"],W-150,-18,120,function()
        UI.detailOpen=not UI.detailOpen; UI.Layout()
    end)
    controls.offlineClose=K.Button(frame,"×",W-30,-2,24,UI.Close)
    controls.search=K.Edit(frame,12,-18,W-256)
    local placeholder=K.Text(controls.search,L["搜索物品名称 / ID / 链接"],8,-8,12,C.muted)
    controls.search:SetScript("OnTextChanged",function(self) placeholder:SetShown(self:GetText()=="") end)
    K.Hint(controls.search,L["搜索物品"],L["名称、物品 ID 或链接；可将背包物品拖入此处。"])
    controls.search:SetScript("OnEnterPressed",function(self) self:ClearFocus(); Search() end)
    controls.search:SetScript("OnReceiveDrag",DroppedItem); frame:SetScript("OnReceiveDrag",DroppedItem)
    controls.searchButton=K.Button(frame,L["搜索"],W-244,-18,84,Search,true)
    controls.flashBuy=K.Button(frame,L["闪购：关"],W-140,-86,128,function()
        Settings().flashBuy=not Settings().flashBuy
        UI.Refresh()
    end)
    controls.flashBuy.label:ClearAllPoints(); controls.flashBuy.label:SetPoint("LEFT",10,0)
    controls.flashBuy.label:SetWidth(66)
    controls.flashBuy.indicator=controls.flashBuy:CreateTexture(nil,"ARTWORK")
    controls.flashBuy.indicator:SetPoint("LEFT",88,0); controls.flashBuy.indicator:SetSize(30,14)
    controls.flashBuy.knob=controls.flashBuy:CreateTexture(nil,"OVERLAY")
    controls.flashBuy.knob:SetColorTexture(0.9,0.95,0.93,1); controls.flashBuy.knob:SetSize(12,12)
    K.Hint(controls.flashBuy,L["闪购"],L["开启后在已有完整报价时直接购买；没有精确报价时仍需确认。"])
    controls.saleSelection=CreateFrame("Frame",nil,frame); controls.saleSelection:SetAllPoints()
    controls.saleIcon=K.Icon(controls.saleSelection,12,-16,32)
    controls.saleName=K.Text(controls.saleSelection,"",54,-28,13,C.text,484)
    controls.listTools=CreateFrame("Frame",nil,frame); controls.listTools:SetAllPoints()
    controls.listPicker=K.Button(controls.listTools,L["选择清单 v"],12,-86,168,TogglePicker)
    controls.newList=K.Button(controls.listTools,"+",186,-86,28,function() ShowDialog("new") end,true)
    K.Hint(controls.newList,L["新建清单"])
    controls.deleteList=K.Button(controls.listTools,"−",220,-86,28,UI.ShowDeleteList)
    controls.deleteList.label:SetTextColor(unpack(C.danger))
    controls.deleteList:SetBackdropColor(unpack(C.dangerBg)); controls.deleteList:SetBackdropBorderColor(unpack(C.danger))
    K.Hint(controls.deleteList,L["删除清单"],L["删除当前购物清单，确认后生效。"])
    controls.rename=K.Button(controls.listTools,L["改名"],254,-86,44,function() ShowDialog("rename") end)
    controls.import=K.Button(controls.listTools,L["导入"],304,-86,60,function() ShowDialog("import") end)
    controls.export=K.Button(controls.listTools,L["导出"],370,-86,60,function() ShowDialog("export") end)
    K.Hint(controls.rename,L["重命名"])
    K.Hint(controls.import,L["导入清单"])
    K.Hint(controls.export,L["导出清单"])
    controls.refreshList=K.Button(controls.listTools,L["刷新报价"],438,-86,116,RefreshListPrices)
    controls.viewList=K.Button(frame,L["返回清单"],12,-86,116,function()
        if UI.catalogID then UI.SelectCatalog(UI.catalogID)
        else UI.view="list"; rows.offset=0; UI.Refresh() end
    end)
    controls.filter=K.Button(frame,L["过滤器"],W-274,-86,120,UI.ToggleFilterPanel)
    controls.recent=K.Button(frame,L["最近搜索"],W-150,-18,120,function()
        local recents=ns.Store.GetRecentQueries(); if #recents==0 then Say(L["暂无搜索记录"]); return end
        if recentPicker:IsShown() then recentPicker:Hide(); return end
        CloseMenus(recentPicker)
        recentPicker:ClearAllPoints(); recentPicker:SetPoint("TOPRIGHT",controls.recent,"BOTTOMRIGHT",0,-4)
        recentPicker:SetHeight(min(8,#recents)*31+16)
        for i,button in ipairs(recentPicker.buttons) do
            local entry=recents[i]; button.query=entry and entry.text; button:SetShown(entry~=nil)
            if entry then button.label:SetText(entry.text) end
        end
        recentPicker:Show()
    end)
    K.Hint(controls.recent,L["最近搜索"])
    controls.sellTitle=K.Text(frame,L["待售物品"],12,-67,12,C.muted)
    local searchHeaders={
        -- x 对齐 buying 布局的实际列位：价格列由 Render 固定在 width-330。
        {label=L["物品名"],x=36,width=310,key="label"},
        {label=L["在售数量"],x=356,width=76,key="quantity",col=true},
        {label=L["在售单价"],x=W-354,width=116,key="unitPrice"},
    }
    shortRows=K.Rows(frame,12,-130,W-24,8,28,searchHeaders)
    shortRows.onSort=function(key,desc)
        UI.searchSort={key=key,desc=desc and true or false}
        UI.Refresh()
    end
    rows=shortRows
    restockTable=K.RestockTable(frame,12,-120,W-24,8)
    restockTable:EnableMouse(true)
    restockTable:SetScript("OnReceiveDrag",UI.DropListItem)
    restockTable.empty:SetText(L["拖入物品，或搜索后点 + 添加"])
    -- Child controls receive mouse input themselves, so bind each drop surface.
    for index,row in ipairs(restockTable.rows) do
        for controlIndex,target in ipairs({row,row.icon,row.include,row.minus,row.qty,row.plus,row.cap,row.buy,row.remove}) do
            target:SetScript("OnReceiveDrag",UI.DropListItem)
        end
    end
    UI.InitCatalog()
    restockFooter=CreateFrame("Frame",nil,frame); restockFooter:SetPoint("TOPLEFT",12,-406); restockFooter:SetSize(W-24,56)
    controls.restockSummary=K.Text(restockFooter,"",0,0,12,C.gold,W-152)
    controls.pendingSummary=K.Text(restockFooter,"",0,-20,10,C.muted,450)
    K.Hint(restockTable,L["清单补货"],L["保持数量为目标库存；拥有只统计随身背包。已购待收取量在本次登录期间抵扣缺口。"])
    controls.restockBuy=K.Button(restockFooter,L["一键补货"],W-140,4,116,BuyRestockList,true)
    restockTable.prev:ClearAllPoints(); restockTable.prev:SetPoint("TOPLEFT",restockFooter,"TOPLEFT",W-236,-26)
    restockTable.next:ClearAllPoints(); restockTable.next:SetPoint("TOPRIGHT",restockFooter,"TOPRIGHT",0,-26)
    restockTable.page:ClearAllPoints(); restockTable.page:SetPoint("TOPLEFT",restockFooter,"TOPLEFT",W-206,-34)
    restockTable.page:SetWidth(152)
    settingsPage=ns.InfoPages.CreateSettings(frame,controls,Settings,UI)
    controls.aboutPage=ns.InfoPages.CreateAbout(frame)
    picker=K.Surface(frame,12,-90,250,272); picker:SetFrameLevel(frame:GetFrameLevel()+30)
    picker.buttons={}; picker.empty=K.Text(picker,L["先点 + 新建清单"],12,-16,12,C.muted)
    for i=1,8 do
        picker.buttons[i]=K.Button(picker,"",8,-8-(i-1)*32,234,function(self)
            if picker.addEntry then AddItem(picker.addEntry,1,self.list); picker:Hide()
            else
                if UI.view=="catalog" then
                    selectedList=self.list; picker:Hide(); UI.Refresh()
                else SelectList(self.list) end
            end
        end)
    end
    RegisterMenu(picker,controls.listPicker)
    picker:EnableMouseWheel(true); picker:SetScript("OnMouseWheel",function(self,delta)
        self.offset=min(max(0,(self.offset or 0)-delta*3),max(0,#ns.Store.GetLists()-8))
        if self.addEntry then
            local lists=ns.Store.GetLists()
            for i,button in ipairs(self.buttons) do
                button.list=lists[self.offset+i]; button:SetShown(button.list~=nil)
                if button.list then button.label:SetText(button.list.name) end
            end
        else self:Hide(); TogglePicker() end
    end); picker:Hide()
    recentPicker=K.Surface(frame,12,-140,300,264); recentPicker:SetFrameLevel(frame:GetFrameLevel()+30)
    recentPicker.buttons={}
    for i=1,8 do
        recentPicker.buttons[i]=K.Button(recentPicker,"",8,-8-(i-1)*31,284,function(self)
            recentPicker:Hide(); controls.search:SetText(self.query); Search()
        end)
    end
    RegisterMenu(recentPicker,controls.recent)
    recentPicker:Hide()
    bagScroll=CreateFrame("ScrollFrame",nil,frame); bagScroll:SetPoint("TOPLEFT",12,-92); bagScroll:SetSize(274,208)
    bagContent=CreateFrame("Frame",nil,bagScroll); bagContent:SetSize(274,208); bagScroll:SetScrollChild(bagContent)
    bagScroll:EnableMouseWheel(true); bagScroll:SetScript("OnMouseWheel",function(self,delta)
        groupOffset=max(0,min(bagContent:GetHeight()-208,groupOffset-delta*40)); self:SetVerticalScroll(groupOffset)
    end)
    controls.bagEmpty=K.Text(bagContent,L["没有可售物品"],0,-25,12,C.muted,176)
    controls.bagValue=K.Text(frame,"",12,-312,11,C.gold,274)
    K.Hint(bagScroll,L["待售物品"],L["估值按价格库最新报价计算；未报价物品不计入金额。"])
    controls.flashSell=K.Button(frame,L["闪卖"],158,-58,128,function()
        Settings().flashSell=not Settings().flashSell
        if not Settings().flashSell then ns.Market.CancelClearBags(); clearDialog:Hide() end
        UI.Refresh()
    end)
    controls.flashSell.label:ClearAllPoints(); controls.flashSell.label:SetPoint("LEFT",10,0)
    controls.flashSell.label:SetWidth(66)
    controls.flashSell.indicator=controls.flashSell:CreateTexture(nil,"ARTWORK")
    controls.flashSell.indicator:SetPoint("LEFT",88,0); controls.flashSell.indicator:SetSize(30,14)
    controls.flashSell.knob=controls.flashSell:CreateTexture(nil,"OVERLAY")
    controls.flashSell.knob:SetColorTexture(0.9,0.95,0.93,1); controls.flashSell.knob:SetSize(12,12)
    K.Hint(controls.flashSell,L["闪卖"],L["开启后可在报价行直接上架。右键背包图标可锁定物品。"])
    controls.sellDividers=CreateFrame("Frame",nil,frame); controls.sellDividers:SetAllPoints()
    controls.sellDividers.vertical=controls.sellDividers:CreateTexture(nil,"BACKGROUND")
    controls.sellDividers.vertical:SetColorTexture(unpack(C.line))
    controls.sellDividers.vertical:SetPoint("TOPLEFT",294,-58); controls.sellDividers.vertical:SetSize(1,268)
    controls.sellDividers.horizontal=controls.sellDividers:CreateTexture(nil,"BACKGROUND")
    controls.sellDividers.horizontal:SetColorTexture(unpack(C.line))
    controls.sellDividers.horizontal:SetPoint("TOPLEFT",12,-338); controls.sellDividers.horizontal:SetSize(W-24,1)
    distribution=CreateFrame("Frame",nil,frame); distribution:SetPoint("TOPLEFT",304,-58); distribution:SetSize(474,270)
    distribution.levels={}
    K.Text(distribution,L["在售分布"],0,-9,12,C.muted)
    distribution.total=K.Text(distribution,"",304,-9,11,C.muted,170); distribution.total:SetJustifyH("RIGHT")
    distribution.empty=K.Text(distribution,L["选择左侧物品"],0,-116,12,C.muted,474); distribution.empty:SetJustifyH("CENTER")
    for i=1,6 do
        local bar=CreateFrame("Button",nil,distribution); bar:SetPoint("TOPLEFT",0,-36-(i-1)*30); bar:SetSize(474,28)
        bar.price=K.Text(bar,"",0,-8,11,C.text,108)
        bar.bar=bar:CreateTexture(nil,"ARTWORK"); bar.bar:SetPoint("TOPLEFT",112,-4); bar.bar:SetHeight(21)
        bar.qty=K.Text(bar,"",392,-8,11,C.muted,82); bar.qty:SetJustifyH("RIGHT")
        bar.amount=K.Edit(bar,42,0,54,"1"); bar.amount:SetNumeric(true); bar.amount:SetMaxLetters(7)
        bar.amount:SetScript("OnEnterPressed",function(self) self:ClearFocus() end)
        bar.sell=K.Button(bar,L["卖"],0,0,36,function()
            if bar.entry and selectedBag then
                bar.amount:ClearFocus()
                Invoke("Post",selectedBag,tonumber(bar.amount:GetText()),UI.SalePrice(bar.entry.unitPrice),controls.durationValue)
            end
        end,true)
        bar:SetScript("OnClick",function(self)
        if self.entry then controls.sellPrice:SetCopper(UI.SalePrice(self.entry.unitPrice)) end
        end)
        K.Hint(bar,L["点击填入单价"],L["柱长表示在售数量；同价格合并。"])
        bars[i]=bar
    end
    distribution.page=K.Text(distribution,"",32,-254,10,C.muted,410); distribution.page:SetJustifyH("CENTER")
    K.Button(distribution,"‹",0,-242,24,function() barOffset=barOffset-#bars; Bars() end)
    K.Button(distribution,"›",450,-242,24,function() barOffset=barOffset+#bars; Bars() end)
    distribution:EnableMouseWheel(true); distribution:SetScript("OnMouseWheel",function(self,delta) barOffset=barOffset-delta*3; Bars() end)
    trade=CreateFrame("Frame",nil,frame); trade:SetPoint("TOPLEFT",12,-350); trade:SetSize(W-24,100)
    trade:SetFrameLevel(frame:GetFrameLevel()+5)
    controls.quantity=K.Edit(trade,0,-18,66,"1"); controls.quantity:SetNumeric(true)
    controls.quantity.caption=K.Text(trade,L["数量"],0,0,10,C.muted)
    controls.sellPrice=K.MoneyEdit(trade,74,-18,240)
    controls.sellPrice.caption=K.Text(trade,L["单价"],74,0,10,C.muted)
    controls.sellActions=CreateFrame("Frame",nil,trade); controls.sellActions:SetAllPoints()
    controls.durationValue=Settings().duration or 1
    controls.duration=K.Button(controls.sellActions,L["12 小时"],324,-18,102,function()
        controls.durationValue=controls.durationValue%3+1
        controls.duration.label:SetText(({L["12 小时"],L["24 小时"],L["48 小时"]})[controls.durationValue])
    end)
    controls.duration.label:SetText(({L["12 小时"],L["24 小时"],L["48 小时"]})[controls.durationValue])
    controls.post=K.Button(controls.sellActions,L["上架"],434,-18,90,function()
        local price=controls.sellPrice:GetCopper()
        if not price or price<=0 then Say(L["请填写单价"]); return end
        price=ns.Market.NormalizePostPrice(price)
        controls.sellPrice:SetCopper(price)
        controls.sellPrice:ClearFocus()
        Invoke("Post",selectedBag,tonumber(controls.quantity:GetText()),price,controls.durationValue)
    end,true)
    controls.lock=K.Button(controls.sellActions,L["锁定物品"],0,-64,102,function()
        if selectedBag then Invoke("SetLocked",selectedBag.itemKey,not ns.Market.IsLocked(selectedBag.itemKey)); UI.Refresh() end
    end)
    K.Text(controls.sellActions,L["右键图标可锁定物品 · 锁定物品不参与清包"],112,-73,10,C.muted)
    controls.clearBags=K.Button(controls.sellActions,L["一键清包"],112,-18,102,function()
        if Invoke("PrepareClearBags",controls.durationValue) then
            UI.detailOpen=false; UI.Layout(); clearDialog:Show(); RefreshClearDialog()
        end
    end,true)
    controls.clearContinue=K.Button(controls.sellActions,L["继续上架"],222,-18,102,function()
        Invoke("ContinueClearBags"); UI.Refresh()
    end,true)
    controls.clearStop=K.Button(controls.sellActions,L["停止清包"],332,-18,78,function()
        Invoke("CancelClearBags"); UI.Refresh()
    end)
    controls.confirm=K.Button(trade,L["继续"],544,-18,122,function() Invoke("Confirm") end,true)
    controls.stop=K.Button(trade,L["停止"],352,-58,54,function() Invoke("CancelBuy") end)
    frame.status=K.Text(frame,"",12,-458,10,C.muted,W-24)
    -- Secondary information is an on-demand drawer, not a permanent third column.
    detail=K.Surface(frame,W+8,0,DW,540); detail:SetFrameLevel(frame:GetFrameLevel()+15)
    detail:EnableMouse(true); detail:Hide()
    selectedIcon=K.Icon(detail,12,-14,36)
    detail.name=K.Text(detail,"",58,-17,13,C.text,170)
    detail.latest=K.Text(detail,"",58,-38,14,C.gold)
    K.Button(detail,"×",DW-34,-8,24,function()
        if priceDetailContext=="assistant" then UI.CloseAssistantPriceDetail()
        else UI.detailOpen=false; UI.Layout() end
    end)
    detail.ranges={}
    for i,choice in ipairs({{1,"24H"},{7,L["7天"]},{30,L["30天"]}}) do
        local button=K.Button(detail,choice[2],12+(i-1)*84,-74,80,function() UI.days=choice[1]; RefreshTrend() end)
        button.active=button:CreateTexture(nil,"OVERLAY"); button.active:SetColorTexture(unpack(C.accent))
        button.active:SetSize(80,2); button.active:SetPoint("BOTTOMLEFT")
        detail.ranges[choice[1]]=button
    end
    detail.high=K.Text(detail,"",24,-121,10,C.muted)
    detail.plot=CreateFrame("Frame",nil,detail); detail.plot:SetPoint("TOPLEFT",24,-145); detail.plot:SetSize(224,104)
    detail.plot.gridLines={}
    for i=0,2 do
        local line=detail.plot:CreateTexture(nil,"BACKGROUND"); line:SetColorTexture(unpack(C.grid)); line:SetAlpha(0.55)
        line:SetSize(224,1); line:SetPoint("BOTTOMLEFT",0,i*52); detail.plot.gridLines[#detail.plot.gridLines+1]=line
    end
    detail.low=K.Text(detail,"",24,-254,10,C.muted)
    detail.empty=K.Text(detail,L["暂无价格"],24,-190,12,C.muted,224); detail.empty:SetJustifyH("CENTER")
    detail.start=K.Text(detail,"",24,-278,9,C.muted,110)
    detail.ending=K.Text(detail,"",140,-278,9,C.muted,110); detail.ending:SetJustifyH("RIGHT")
    detail.coverage=K.Text(detail,"",24,-301,10,C.muted,224)
    --K.Hint(detail.plot,"价格历史","节点为实际小时报价；连线跨过未采样时段，不代表补齐历史。金色节点为最新报价。")
    detail.plot:EnableMouse(true)
    K.Text(detail,L["购买时段"],16,-346,12,C.gold)
    detail.advice=K.Text(detail,"",16,-370,11,C.accent,240)
    K.Text(detail,L["每日观察最低"],16,-412,12,C.gold)
    detail.daily=K.Text(detail,"",16,-438,11,C.muted,240); detail.daily:SetWordWrap(true)
    K.Text(detail,L["历史仅供参考"],16,-514,10,C.muted)
    InitDialog(); InitClearDialog(); UI.InitScanDialog()
    frame:SetScript("OnHide",function()
        detail:Hide(); picker:Hide(); recentPicker:Hide(); dialog:Hide(); clearDialog:Hide()
        if controls.scanDialog then controls.scanDialog.requested=false; controls.scanDialog:Hide() end
        if ns.Market.ReleaseTransient then ns.Market.ReleaseTransient()
        else ns.Market.CancelBuy(); ns.Market.CancelClearBags() end
        clearTransientState()
    end)
    local dismiss=CreateFrame("Frame",nil,frame); dismiss:RegisterEvent("GLOBAL_MOUSE_DOWN")
    dismiss:SetScript("OnEvent",function()
        for index,menu in ipairs(menus) do
            if menu:IsShown() and not menu:IsMouseOver() and not (menu.owner and menu.owner:IsMouseOver()) then menu:Hide() end
        end
    end)
    if _G.HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick",UI.InsertSearchLink) end
    UI.days=Settings().historyDays or 1
end

function UI.Open(tab)
    UI.Init()
    local auction=_G.AuctionHouseFrame
    if ns.open and auction and auction:IsShown() and ns.NativeTabs.Attach(frame) then
        OfflineEscape(false)
        frame:SetParent(auction); detail:SetParent(auction)
        frame:SetFrameStrata(auction:GetFrameStrata()); frame:SetFrameLevel(auction:GetFrameLevel()+5)
        detail:SetFrameStrata("DIALOG")
        ns.NativeTabs.Activate(tab or "buy")
    else
        OfflineEscape(true)
        frame:SetParent(UIParent); frame:SetFrameStrata("DIALOG")
        detail:SetParent(frame); frame:Show()
        UI.SelectTab((tab=="settings" or tab=="about" or tab=="price") and tab or "assistant")
        UI.Refresh(); UI.Layout()
    end
end
function UI.Close()
    if frame then frame:Hide() end
end
function UI.HideDetails()
    UI.detailOpen=false
    if detail then detail:Hide() end
end
function UI.Snapshot()
    return {shown=frame and frame:IsShown() or false,tab=UI.tab,view=UI.view,catalogID=UI.catalogID,
        width=W,height=H,docked=UI.docked,
        drawerOverlay=UI.drawerOverlay,detailShown=detail and detail:IsShown() or false,
        priceDetailContext=priceDetailContext,
        assistantPriceSelected=assistantPriceEntry and assistantPriceEntry.itemKey,
        scanFooterShown=scanFooter and scanFooter:IsShown() or false,
        native=ns.NativeTabs and ns.NativeTabs.IsActive(),selected=selected and selected.itemKey,
        libraryRows=UI.tab=="assistant" and ns.ProfessionAssistant and ns.ProfessionAssistant.Snapshot().rows or 0,
        bagIcons=#bagIcons,categoryHeaders=#bagHeaders,priceLevels=distribution and distribution.levels and #distribution.levels or 0,
        geometry=frame and {x=frame:GetLeft(),y=frame:GetTop(),width=W,height=H,scale=frame:GetScale()}}
end

local hookFrame=CreateFrame("Frame"); hookFrame:RegisterEvent("ADDON_LOADED"); hookFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
hookFrame:SetScript("OnEvent",function()
    local auction=_G.AuctionHouseFrame
    if auction and not UI.hooked then
        UI.hooked=true
        auction:HookScript("OnSizeChanged",UI.Layout)
        auction:HookScript("OnShow",function() if frame and frame:IsShown() then UI.Layout() end end)
        if auction.SelectBrowseResult then
            hooksecurefunc(auction,"SelectBrowseResult",function(self,result)
                if ns.ready and result and result.itemKey then
                    local entry={itemKey=result.itemKey}; entry.name=ItemName(entry)
                    UI.SelectItem(entry,true)
                end
            end)
        end
    end
    if frame and frame:IsShown() then UI.Layout() end
end)
