local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, C_Timer, GameTooltip = CreateFrame, C_Timer, GameTooltip
local STANDARD_TEXT_FONT = STANDARD_TEXT_FONT
local ipairs, pairs, tostring, type, unpack = ipairs, pairs, tostring, type, unpack
local min, max, floor, huge = math.min, math.max, math.floor, math.huge
local format, lower, find = string.format, string.lower, string.find
local concat, sort = table.concat, table.sort
local W, L = ns.Widgets, ns.L
local C = W.color

local A = {tab="profit", pages={}, definitions={}, cache={}, views={}, timers={},drawers={},themeTables={},
    metrics={modelBuilds=0,viewBuilds=0}}
ns.ProfessionAssistant = A

local tabs = {
    {"profit",L["利润"]},{"levelup",L["专业冲级"]},{"queue",L["制作队列"]},{"gather",L["采购"]},
    {"post",L["专业上架"]},{"sales",L["销售"]},{"prices",L["行情"]},{"characters",L["角色"]},
}
local tabKeys = {}
for index, tab in ipairs(tabs) do tabKeys[tab[1]] = index end

local skillLabels={optimal=L["最佳"],medium=L["中等"],easy=L["简单"],trivial=L["灰色"],unknown=L["未知"]}
local skillMarkers={star="★",raid="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t",pip="•"}
local skillColors={optimal={1,.50,.12},medium={1,.82,.18},easy={.32,.90,.38},trivial={.52,.56,.58},unknown=C.muted}

function A.SkillLabel(skillUp)
    local markerKey=ns.ProfessionSettings and ns.ProfessionSettings.Get("skillUpMarker") or "star"
    return (skillMarkers[markerKey] or skillMarkers.star).." "..(skillLabels[skillUp] or skillUp or L["未知"])
end

function A.SkillColor(skillUp)
    return skillColors[skillUp] or skillColors.unknown
end

local function Comma(value)
    return tostring(value):reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")
end

function A.Money(value, short)
    if type(value)~="number" then return "—" end
    local negative=value<0
    local amount=floor(negative and -value or value)
    local gold=floor(amount/10000)
    local silver=floor(amount/100)%100
    local copper=amount%100
    local parts={}
    if gold>0 then parts[#parts+1]=Comma(gold).."|TInterface\\MoneyFrame\\UI-GoldIcon:10:10:0:0|t" end
    if not (short and gold>=100) then
        if silver>0 or gold>0 then parts[#parts+1]=tostring(silver).."|TInterface\\MoneyFrame\\UI-SilverIcon:10:10:0:0|t" end
        if copper>0 or #parts==0 then parts[#parts+1]=tostring(copper).."|TInterface\\MoneyFrame\\UI-CopperIcon:10:10:0:0|t" end
    end
    return (negative and "-" or "")..concat(parts," ")
end

function A.ItemEntry(row)
    if not row then return nil end
    if row.itemKey then return row end
    local itemID=row.outputItemID or row.itemID
    if not itemID then return nil end
    row.itemKey={itemID=itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
    return row
end

local function SortValue(row,column)
    if column.sort then return column.sort(row) end
    if column.key=="name" then return A.Title(row) end
    return row[column.sortKey or column.key]
end

function A.SortRows(rows,column,descending)
    local copied,indexes={},{}
    for index,row in ipairs(rows or {}) do copied[index]=row; indexes[row]=index end
    sort(copied,function(left,right)
        local a,b=SortValue(left,column),SortValue(right,column)
        if a==nil or b==nil then
            if a==nil and b==nil then return indexes[left]<indexes[right] end
            return b==nil
        end
        if type(a)=="string" then a=lower(a) end
        if type(b)=="string" then b=lower(b) end
        if a==b then return indexes[left]<indexes[right] end
        if descending then return a>b end
        return a<b
    end)
    return copied
end

function A.Age(seconds)
    if type(seconds)~="number" or seconds<0 or seconds==huge then return "—" end
    if seconds<60 then return L["刚刚"] end
    if seconds<3600 then return format(L["%d 分钟前"],floor(seconds/60)) end
    if seconds<86400 then return format(L["%d 小时前"],floor(seconds/3600)) end
    return format(L["%d 天前"],floor(seconds/86400))
end

function A.Title(row)
    return row and (row.name or row.itemName or row.label or row.ownerName
        or tostring(row.itemID or row.outputItemID or row.recipeID or "—")) or "—"
end

function A.RowKey(row)
    if not row then return nil end
    if row.index then return "queue:"..tostring(row.index) end
    if row.bag then return "bag:"..tostring(row.bag)..":"..tostring(row.slot) end
    if row.key then return tostring(row.key) end
    if row.recipeID then return tostring(row.owner or row.character or "")..":"..tostring(row.recipeID) end
    if row.itemKey then return ns.Store.Key(row.itemKey) end
    return A.Title(row)
end

function A.Reconcile(rows, selected)
    local selectedKey=A.RowKey(selected)
    if not selectedKey then return nil end
    for index,row in ipairs(rows) do -- luacheck: ignore index
        if A.RowKey(row)==selectedKey then return row end
    end
    return nil
end

function A.Options(key)
    local db=ns.Store and ns.Store.GetDB and ns.Store.GetDB()
    if not db then
        A.fallback=A.fallback or {}; A.fallback[key]=A.fallback[key] or {}
        return A.fallback[key]
    end
    db.settings=db.settings or {}; db.settings.professionFilters=db.settings.professionFilters or {}
    db.settings.professionFilters[key]=db.settings.professionFilters[key] or {}
    return db.settings.professionFilters[key]
end

function A.Signature(extra)
    local professionRevision=ns.ProfessionEngine and ns.ProfessionEngine.revision or 0
    local priceRevision=ns.Prices and ns.Prices.Revision and ns.Prices.Revision() or 0
    return tostring(professionRevision)..":"..tostring(priceRevision)..":"..tostring(extra or "")
end

function A.Cached(key, signature, producer)
    local cached=A.cache[key]
    if cached and cached.signature==signature then return cached.data,false end
    local data=producer() or {}
    A.cache[key]={signature=signature,data=data}
    A.metrics.modelBuilds=A.metrics.modelBuilds+1
    return data,true
end

function A.Invalidate(key)
    if key then A.cache[key]=nil; A.views[key]=nil
    else A.cache={}; A.views={} end
end

function A.Filter(rows, query)
    query=lower(query or "")
    if query=="" then return rows end
    local filtered={}
    for index,row in ipairs(rows) do
        local text=lower(A.Title(row))
        local id=tostring(row.itemID or row.outputItemID or row.recipeID or "")
        if find(text,query,1,true) or id==query then filtered[#filtered+1]=row end
    end
    return filtered
end

function A.FilterCached(key, signature, rows, query)
    local viewSignature=tostring(signature)..":"..tostring(query or "")
    local cached=A.views[key]
    if cached and cached.signature==viewSignature and cached.source==rows then return cached.data,false end
    local data=A.Filter(rows,query)
    A.views[key]={signature=viewSignature,source=rows,data=data}
    A.metrics.viewBuilds=A.metrics.viewBuilds+1
    return data,true
end

function A.Schedule(key, callback)
    local old=A.timers[key]
    if old and old.Cancel then old:Cancel() end
    if C_Timer and C_Timer.NewTimer then
        A.timers[key]=C_Timer.NewTimer(0.08,function()
            A.timers[key]=nil
            if A.tab==key then callback() end
        end)
    else callback() end
end

function A.BindSearch(box, key, state, callback)
    box:SetText(state.search or "")
    local placeholder=W.Text(box,L["搜索物品名称"],8,0,11,C.muted)
    placeholder:ClearAllPoints(); placeholder:SetPoint("LEFT",8,0); placeholder:SetPoint("RIGHT",-8,0)
    placeholder:SetWordWrap(false); box.searchPlaceholder=placeholder
    local function updatePlaceholder()
        placeholder:SetShown((box:GetText() or "")=="" and not box:HasFocus())
    end
    box:SetScript("OnTextChanged",function(self)
        state.search=self:GetText() or ""
        updatePlaceholder()
        A.Schedule(key,callback)
    end)
    box:HookScript("OnEditFocusGained",updatePlaceholder)
    box:HookScript("OnEditFocusLost",updatePlaceholder)
    updatePlaceholder()
end

function A.Toggle(parent, label, x, y, width, getter, setter)
    local control=W.Checkbox(parent,label,x,y,width,getter(),function(value)
        setter(value); A.Refresh(true)
    end)
    function control:Update() self:SetChecked(getter()) end
    return control
end

function A.Dropdown(parent, label, x, y, width, values, getter, setter)
    local function Options()
        local source=type(values)=="function" and values() or values
        local options={}
        for index,value in ipairs(source or {}) do
            options[index]={value=value.value~=nil and value.value or value[1],
                text=label..": "..(value.text or value.label or value[2] or tostring(value.value or value[1]))}
        end
        return options
    end
    local control=W.Dropdown(parent,x,y,width,Options(),function(value)
        setter(value); A.Refresh(true)
    end)
    function control:Update() self:SetOptions(Options()); self:SetValue(getter()) end
    control:Update()
    return control
end

function A.CreateDrawer(key)
    if A.drawers[key] then return A.drawers[key] end
    local host=A.page and A.page.host
    if not host then return nil end
    local drawer=W.Surface(host,0,0,272,540)
    drawer:SetFrameStrata("DIALOG"); drawer:SetFrameLevel(host:GetFrameLevel()+15); drawer:EnableMouse(true)
    drawer.close=W.Button(drawer,"x",238,-8,24,function() A.CloseDrawer() end)
    drawer.close:SetSize(24,22); drawer:Hide(); drawer.key=key; A.drawers[key]=drawer
    return drawer
end

function A.LayoutDrawer()
    local host=A.page and A.page.host
    for key,drawer in pairs(A.drawers) do
        drawer:ClearAllPoints(); drawer:SetScale(1)
        drawer:SetPoint("TOPLEFT",host,"TOPRIGHT",ns.UI and ns.UI.drawerOverlay and -272 or 8,
            ns.UI and ns.UI.docked and 32 or 0)
        drawer:SetShown(A.drawerOpen==key and A.page:IsShown() and host:IsShown()
            and ns.UI and ns.UI.tab=="assistant")
    end
end

function A.OpenDrawer(key)
    if not A.drawers[key] then return false end
    A.drawerOpen=key; A.LayoutDrawer(); return true
end

function A.CloseDrawer()
    A.drawerOpen=nil; A.LayoutDrawer()
end

function A.RowButton(row,text,x,width,onClick,primary)
    local inset=row.tableInset or 8
    local rowHeight=row:GetHeight() or 28
    local height=min(24,max(20,rowHeight-4))
    local left=min(max(0,x-inset),max(0,(row:GetWidth() or width)-width-2))
    local top=-floor((rowHeight-height)/2)
    local button=W.Button(row,text,left,top,width,onClick,primary,height)
    button:SetSize(width,height); button.label:SetFont(STANDARD_TEXT_FONT,10,"")
    return button
end

function A.RowEdit(row,x,width,value)
    local inset=row.tableInset or 8
    local rowHeight=row:GetHeight() or 28
    local height=min(24,max(22,rowHeight-4))
    local left=min(max(0,x-inset),max(0,(row:GetWidth() or width)-width-2))
    local top=-floor((rowHeight-height)/2)
    local edit=W.Edit(row,left,top,width,value); edit:SetSize(width,height)
    return edit
end

function A.CreateTable(parent, spec)
    local inset=tonumber(spec.inset) or 8
    local list=W.Surface(parent,spec.x,spec.y,spec.width,spec.height,"panel")
    list.data,list.rawData,list.rows,list.headers,list.offset={}, {}, {}, {}, 0
    list.contentInset=inset; list.spec=spec; list.innerWidth=spec.width-inset*2
    A.themeTables[#A.themeTables+1]=list
    list.rowHeight=tonumber(spec.rowHeight) == 40 and 40 or 28
    -- Reserve the header, pager and a gap using the normalized row height.
    list.visible=min(spec.visible or 10,max(1,floor((spec.height-24-24-6)/list.rowHeight)))
    spec.rowHeight=list.rowHeight
    list.key=A.RowKey
    list.columns={}
    for index,column in ipairs(spec.columns) do -- luacheck: ignore index
        list.columns[column.key]=column
        local heading=CreateFrame("Button",nil,list)
        heading:SetPoint("TOPLEFT",column.x,0); heading:SetSize(column.width,24)
        heading.label=W.Text(heading,column.label,0,-6,10,C.muted,column.width)
        heading.label:SetJustifyH(column.align or "LEFT")
        heading:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        heading:GetHighlightTexture():SetVertexColor(1,1,1,.05)
        heading:SetScript("OnClick",function() list:SetSort(column.key) end)
        list.headers[column.key]=heading
    end
    for index=1,list.visible do
        local row=CreateFrame("Button",nil,list,"BackdropTemplate")
        row:SetPoint("TOPLEFT",inset,-24-(index-1)*list.rowHeight)
        row:SetSize(spec.width-inset*2,list.rowHeight-1)
        row.tableInset=inset; row.table=list
        row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"})
        row.selectionMark=row:CreateTexture(nil,"ARTWORK")
        row.selectionMark:SetPoint("TOPLEFT",-min(5,inset),0)
        row.selectionMark:SetPoint("BOTTOMLEFT",-min(5,inset),0)
        row.selectionMark:SetWidth(3)
        row.selectionMark:Hide()
        row.cells={}
        for columnIndex,column in ipairs(spec.columns) do -- luacheck: ignore columnIndex
            local itemColumn=spec.itemColumn==column.key
            local cell=W.Text(row,"",column.x-inset+(itemColumn and 24 or 0),-7,11,column.color or C.text,
                column.width-(itemColumn and 24 or 0))
            cell:SetJustifyH(column.align or "LEFT"); row.cells[column.key]=cell
            if itemColumn then
                row.itemIcon=W.Icon(row,column.x-inset+2,-2,min(22,list.rowHeight-4))
                row.itemIcon:EnableMouse(false)
            end
        end
        if spec.createRow then spec.createRow(row,list) end
        row:RegisterForClicks("LeftButtonUp","RightButtonUp")
        row:SetScript("OnClick",function(self,button)
            if self.entry and spec.onClick then spec.onClick(self.entry,button,self,list) end
        end)
        row:SetScript("OnEnter",function(self)
            local item=A.ItemEntry(self.entry)
            if item then W.Tooltip(self,item) end
            if self.entry and spec.onEnter then spec.onEnter(self,self.entry) end
        end)
        row:SetScript("OnLeave",function(self)
            if GameTooltip then GameTooltip:Hide() end
            if spec.onLeave then spec.onLeave(self) end
        end)
        list.rows[index]=row
    end
    list.empty=W.Text(list,spec.empty or L["暂无符合条件的数据"],12,-80,12,C.muted,spec.width-24)
    list.empty:SetJustifyH("CENTER"); list.empty:SetWordWrap(true)
    list.page=W.Text(list,"",34,-spec.height+20,10,C.muted,spec.width-68); list.page:SetJustifyH("CENTER")
    list.prev=W.Button(list,"‹",inset+4,-spec.height+24,24,function() list.offset=list.offset-list.visible; list:Render() end)
    list.next=W.Button(list,"›",spec.width-inset-28,-spec.height+24,24,function() list.offset=list.offset+list.visible; list:Render() end)
    list.prev:SetSize(24,22); list.next:SetSize(24,22)
    function list:ApplyTheme()
        self:SetBackdropColor(C.panel[1],C.panel[2],C.panel[3],1)
        self:SetBackdropBorderColor(C.line[1],C.line[2],C.line[3],1)
        for _,heading in pairs(self.headers) do heading.label:SetTextColor(C.muted[1],C.muted[2],C.muted[3],1) end
        for _,row in ipairs(self.rows) do row:SetBackdropBorderColor(C.panel[1],C.panel[2],C.panel[3],0) end
    end
    function list:Render()
        self.offset=min(max(0,self.offset),max(0,#self.data-self.visible))
        self.empty:SetShown(#self.data==0)
        for index,row in ipairs(self.rows) do
            local entry=self.data[self.offset+index]
            row.entry=entry; row:SetShown(entry~=nil)
            local selected=entry~=nil and self.selectedKey~=nil and self.selectedKey==self.key(entry)
            row.selectionMark:SetColorTexture(C.accent[1],C.accent[2],C.accent[3],1)
            row.selectionMark:SetShown(selected)
            if entry then
                local rowColor=selected and C.selected or C.stripe
                local rowAlpha=selected and 1 or (index%2==0 and 0.035 or 0.06)
                row:SetBackdropColor(rowColor[1],rowColor[2],rowColor[3],rowAlpha)
                row:SetBackdropBorderColor(C.panel[1],C.panel[2],C.panel[3],0)
                if row.itemIcon then
                    local item=A.ItemEntry(entry)
                    row.itemIcon:SetShown(item~=nil)
                    if item then
                        row.itemIcon:SetEntry(item)
                        local color=spec.itemColor=="skill" and A.SkillColor(entry.skillUp) or row.itemIcon.qualityColor
                        row.cells[spec.itemColumn]:SetTextColor(unpack(color or C.text))
                    else row.cells[spec.itemColumn]:SetTextColor(unpack(C.text)) end
                end
                spec.update(row,entry,list)
            end
        end
        self.page:SetText(#self.data>0 and format(L["%s–%s / %s 项"],tostring(self.offset+1),
            tostring(min(self.offset+self.visible,#self.data)),tostring(#self.data)) or "")
        W.Enabled(self.prev,self.offset>0); W.Enabled(self.next,self.offset+self.visible<#self.data)
    end
    function list:UpdateHeaders()
        for key,heading in pairs(self.headers) do
            local column=self.columns[key]
            local suffix=self.sortKey==key and (self.sortDescending and " ▼" or " ▲") or ""
            heading.label:SetText(column.label..suffix)
            heading.label:SetTextColor(unpack(self.sortKey==key and C.accent or C.muted))
        end
    end
    function list:SetSort(key,descending)
        local column=self.columns[key]
        if not column then return end
        if descending==nil then
            if self.sortKey==key then descending=not self.sortDescending
            else descending=column.defaultDescending==true end
        end
        self.sortKey,self.sortDescending=key,descending==true
        self.data=A.SortRows(self.rawData,column,self.sortDescending)
        self.offset=0; self:UpdateHeaders(); self:Render()
        if spec.onSort then spec.onSort(key,self.sortDescending) end
    end
    function list:SetData(data, reset)
        self.rawData=data or {}
        local column=self.sortKey and self.columns[self.sortKey]
        if column then self.data=A.SortRows(self.rawData,column,self.sortDescending)
        elseif spec.compare then
            self.data={}
            for index,row in ipairs(self.rawData) do self.data[index]=row end
            sort(self.data,spec.compare)
        else
            self.data={}
            for index,row in ipairs(self.rawData) do self.data[index]=row end
        end
        if reset then self.offset=0 end; self:UpdateHeaders(); self:Render()
    end
    function list:SetSelected(entry)
        self.selectedKey=entry and self.key(entry) or nil; self:Render()
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel",function(self,delta) self.offset=self.offset-delta*3; self:Render() end)
    return list
end

function A.ApplyTheme()
    if W.ApplyTheme then W.ApplyTheme() end
    for _,list in ipairs(A.themeTables) do
        if list and list.SetBackdropColor then
            list:SetBackdropColor(C.panel[1],C.panel[2],C.panel[3],1)
            list:SetBackdropBorderColor(C.line[1],C.line[2],C.line[3],1)
        end
        if list and list.ApplyTheme then list:ApplyTheme() end
        if list and list.UpdateHeaders then list:UpdateHeaders() end
        if list and list.Render then list:Render() end
    end
    for index,button in ipairs(A.page and A.page.tabs or {}) do
        W.SetButtonState(button,tabs[index][1]==A.tab,false)
    end
end

function A.SetMessage(text)
    if A.page then A.page.message:SetText(text or "") end
end

function A.RegisterPage(definition)
    if not definition or not tabKeys[definition.key] then return false end
    A.definitions[definition.key]=definition
    return true
end

local function activate(key, force)
    local page=A.page
    local definition=A.definitions[key]
    if not page or not definition then return false end
    for tabKey,frame in pairs(A.pages) do frame:SetShown(tabKey==key) end
    local frame=A.pages[key]
    if not frame then
        frame=CreateFrame("Frame",nil,page.content)
        frame:SetAllPoints(); frame.key=key; A.pages[key]=frame
        definition.build(frame)
    end
    if definition.layout and definition.layout.drawer then A.OpenDrawer(key) else A.CloseDrawer() end
    for index,button in ipairs(page.tabs) do
        local active=tabs[index][1]==key
        W.SetButtonState(button,active,false)
    end
    definition.refresh(force==true)
    return true
end

function A.SelectTab(key)
    if not tabKeys[key] then return false end
    if A.tab~=key then
        if ns.ProfessionPosting then ns.ProfessionPosting.Cancel() end
        if ns.UI and ns.UI.CloseAssistantPriceDetail then ns.UI.CloseAssistantPriceDetail() end
    end
    A.tab=key; A.SetMessage("")
    if A.page then return activate(key,false) end
    return true
end

function A.Refresh(force)
    if not A.page or not A.page:IsShown() or not A.page.host:IsShown()
        or ns.UI and ns.UI.tab~="assistant" then return end
    local definition=A.definitions[A.tab]
    if definition and A.pages[A.tab] then definition.refresh(force==true) end
end

function A.InsertSearchLink(name)
    local definition=A.definitions[A.tab]
    if not definition or not definition.setSearch then return false end
    definition.setSearch(name)
    return true
end

function A.Create(parent)
    if A.page then return A.page end
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints(); page.host=parent; A.page=page
    page.tabs={}
    for index,tab in ipairs(tabs) do
        page.tabs[index]=W.Button(page,tab[2],12+(index-1)*90,-6,86,function() A.SelectTab(tab[1]) end)
        page.tabs[index]:SetSize(86,24); page.tabs[index].label:SetFont(STANDARD_TEXT_FONT,11,"")
    end
    page.content=CreateFrame("Frame",nil,page)
    page.content:SetPoint("TOPLEFT",0,-36); page.content:SetPoint("BOTTOMRIGHT",0,24)
    page.message=W.Text(page,"",12,-456,11,C.muted,762)
    page:SetScript("OnHide",function()
        for key,timer in pairs(A.timers) do
            if timer and timer.Cancel then timer:Cancel() end
            A.timers[key]=nil
        end
        if ns.ProfessionPosting then ns.ProfessionPosting.Cancel() end
        A.CloseDrawer()
    end)
    page:SetScript("OnShow",function()
        local definition=A.definitions[A.tab]
        if definition and definition.layout and definition.layout.drawer then A.OpenDrawer(A.tab) end
    end)
    activate(A.tab,true)
    page:Hide()
    return page
end

function A.Snapshot()
    local definition=A.definitions[A.tab]
    local snapshot=definition and definition.snapshot and definition.snapshot() or {}
    snapshot.tab=A.tab; snapshot.modelBuilds=A.metrics.modelBuilds; snapshot.viewBuilds=A.metrics.viewBuilds
    snapshot.drawerShown=A.drawerOpen~=nil and A.drawers[A.drawerOpen] and A.drawers[A.drawerOpen]:IsShown() or false
    snapshot.drawerKey=A.drawerOpen
    return snapshot
end

function A.LayoutSnapshot(key)
    local definition=A.definitions[key]
    return definition and definition.layout or nil
end

return A
