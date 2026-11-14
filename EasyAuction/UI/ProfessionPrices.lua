local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame = CreateFrame
local ipairs, pairs, tostring = ipairs, pairs, tostring
local floor, huge = math.floor, math.huge
local sort, concat = table.sort, table.concat
local format = string.format
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color

local state={data={},selected=nil,lastView=nil,days=1}

local function updateFilters(options)
    local categories=ns.ViewModel.AuctionCategories()
    if #categories==0 then categories=ns.ViewModel.Categories end
    local categoryValues={{id="all",name=L["全部分类"],icon="Interface\\Icons\\INV_Misc_Bag_10"}}
    local category,child,list
    for index,entry in ipairs(categories) do -- luacheck: ignore index
        categoryValues[#categoryValues+1]=entry
        if entry.id==options.categoryID then category=entry end
    end
    for index,entry in ipairs(category and category.children or {}) do -- luacheck: ignore index
        if entry.id==options.subcategoryID then child=entry end
    end
    local listValues={{value="all",text=L["全部物品"]}}
    for index,entry in ipairs(ns.Store.GetLists()) do -- luacheck: ignore index
        listValues[#listValues+1]={value=entry.id,text=entry.name}
        if entry.id==options.listID then list=entry end
    end
    options.categoryID=category and category.id or "all"
    options.subcategoryID=child and child.id or "all"
    options.listID=list and list.id or "all"
    state.category:SetCategories(categoryValues,category,child)
    state.list:SetOptions(listValues); state.list:SetValue(options.listID)
    -- Lists are edited in place without a price revision; include membership in the cache key.
    local keys={}
    for key in pairs(list and list.items or {}) do keys[#keys+1]=key end
    sort(keys)
    local selected=child or category
    return selected and (selected.filters and selected or selected.id),list,
        tostring(options.categoryID).."/"..tostring(options.subcategoryID).."/"..tostring(options.listID).."/"..concat(keys,",")
end

local function buildRows(options,category,list)
    local reagents
    if options.reagentsOnly then reagents=ns.Professions.GetReagentIDs() end
    local rows={}
    local source=ns.ViewModel.PriceRows(ns.Prices.GetItems(),{category=category,list=list,resolveMetadata=category~=nil})
    for index,entry in ipairs(source) do -- luacheck: ignore index
        local record=entry.item
        local itemKey=record.itemKey
        local itemID=itemKey and itemKey.itemID
        if not reagents or reagents[itemID] then
            rows[#rows+1]={itemKey=itemKey,itemID=itemID,name=entry.name,record=record,
                market=record.market or record.last,min=record.min or record.last,quantity=record.bookQuantity or record.quantity or 0,
                liquidity=ns.Prices.GetLiquidity(itemKey),age=ns.Prices.GetAge(itemKey) or huge,updated=record.updated}
        end
    end
    sort(rows,function(left,right)
        local by=options.sortBy or "market"
        if by=="name" then return A.Title(left)<A.Title(right) end
        local a,b=left[by],right[by]
        if by=="age" then a,b=a or huge,b or huge; if a~=b then return a<b end
        else a,b=a or 0,b or 0; if a~=b then return a>b end end
        return A.Title(left)<A.Title(right)
    end)
    return rows
end

local function setDetailValue(key,value,color)
    local label=state.detail.values[key]; label:SetText(value or "—")
    if color then label:SetTextColor(color[1],color[2],color[3]) end
end

local function updateChart(row)
    local points,first,ending=ns.Prices.ChartTrend(row and row.itemKey,state.days)
    if ns.TrendPlot then ns.TrendPlot.Render(state.detail.chart,points,first,ending) end
    state.detail.chartEmpty:SetShown(#points==0)
    state.detail.range:SetValue(state.days)
end

local function updateDetail()
    local row=state.selected; local detail=state.detail
    detail.empty:SetShown(row==nil); detail.content:SetShown(row~=nil)
    if not row then updateChart(nil); return end
    local record=ns.Prices.Get(row.itemKey) or row.record
    detail.title:SetText(A.Title(row))
    setDetailValue("market",A.Money(record.market or record.last),C.gold)
    setDetailValue("min",A.Money(record.min or record.last))
    setDetailValue("rival",A.Money(record.rivalMin))
    setDetailValue("own",A.Money(record.ownMin),ns.Prices.HoldsLowest(row.itemKey) and C.accent or C.text)
    setDetailValue("quantity",tostring(record.bookQuantity or record.quantity or 0))
    setDetailValue("scans",tostring(record.scans or 0))
    local confidence,reason=ns.Prices.GetConfidence(row.itemKey)
    setDetailValue("confidence",format("%d%%%s",floor(confidence*100),reason and (" · "..reason) or ""))
    local liquidity=ns.Prices.GetLiquidity(row.itemKey)
    setDetailValue("liquidity",liquidity and format("%d%%",floor(liquidity*100)) or L["扫描次数不足"])
    updateChart(row)
    W.Enabled(detail.search,ns.open==true)
end

local function refresh(force)
    if not state.table then return end
    local options=A.Options("prices")
    local category,list,filterSignature=updateFilters(options)
    local signature=A.Signature(tostring(options.reagentsOnly)..":"..tostring(options.sortBy or "market")..":"..filterSignature)
    local base,changed=A.Cached("prices:model",signature,function() return buildRows(options,category,list) end)
    local rows,viewChanged=A.FilterCached("prices:view",signature,base,options.search)
    local view=signature..":"..tostring(options.search or "")
    state.data=rows
    if force or changed or viewChanged or state.lastView~=view then state.table:SetData(rows,force); state.lastView=view
    else state.table:Render() end
    if changed or viewChanged then state.selected=A.Reconcile(rows,state.selected) end
    state.table:SetSelected(state.selected); updateDetail()
    state.reagents:Update(); state.sort:Update()
    state.count:SetText(format(L["已定价 %d 种物品"],#rows))
end

local function searchSelected()
    local row=state.selected
    if not row or not ns.open then return end
    ns.UI.SearchAuctionItem(row)
end

local function createDetail()
    local detail=A.CreateDrawer("prices"); state.detail=detail
    detail.empty=W.Text(detail,L["选择物品查看市场详情和历史走势。"],20,-130,11,C.muted,224)
    detail.empty:SetJustifyH("CENTER"); detail.empty:SetWordWrap(true)
    detail.content=CreateFrame("Frame",nil,detail); detail.content:SetAllPoints()
    detail.title=W.Text(detail.content,"",12,-12,13,C.gold,214)
    detail.values={}
    local rows={{"market",L["市场价"]},{"min",L["最低价"]},{"rival",L["竞争者最低价"]},{"own",L["我的最低价"]},
        {"quantity",L["在售数量"]},{"scans",L["扫描次数"]},{"confidence",L["置信度"]},{"liquidity",L["流通度"]}}
    for index,row in ipairs(rows) do
        W.Text(detail.content,row[2],12,-40-(index-1)*22,10,C.muted,108)
        local value=W.Text(detail.content,"—",112,-40-(index-1)*22,10,C.text,136)
        value:SetJustifyH("RIGHT"); detail.values[row[1]]=value
    end
    W.Text(detail.content,L["历史走势"],12,-220,10,C.muted,100)
    detail.chart=W.Surface(detail.content,12,-238,248,58)
    detail.chartEmpty=W.Text(detail.chart,L["暂无历史样本"],0,-22,10,C.muted,248); detail.chartEmpty:SetJustifyH("CENTER")
    local ranges={}
    for index,days in ipairs({1,7,30}) do
        ranges[index]={value=days,text=format(L["最近 %d 天"],days)}
    end
    detail.range=W.Dropdown(detail.content,12,-306,110,ranges,function(days)
        state.days=days; updateChart(state.selected)
    end)
    detail.range:SetValue(state.days)
    detail.search=W.Button(detail.content,L["搜索拍卖行"],130,-306,130,searchSelected,true)
    detail.search:SetSize(130,22)
    return detail
end

local function build(parent)
    local options=A.Options("prices")
    local days=ns.Store.GetDB().settings.historyDays
    state.days=(days==7 or days==30) and days or 1
    state.searchBox=W.Edit(parent,12,-6,510,options.search or ""); state.searchBox:SetSize(510,22)
    A.BindSearch(state.searchBox,"prices",options,function() refresh(true) end)
    state.reagents=A.Toggle(parent,L["仅显示我的制作材料"],542,-36,236,
        function() return options.reagentsOnly==true end,function(value) options.reagentsOnly=value end)
    state.sort=A.Dropdown(parent,L["排序"],534,-6,244,{{"market",L["市场价"]},{"min",L["最低价"]},{"quantity",L["在售数量"]},
        {"age",L["更新时间"]},{"name",L["名称"]}},function() return options.sortBy or "market" end,function(value) options.sortBy=value end)
    state.category=W.CategoryDropdown(parent,12,-36,249,function(categoryID,subcategoryID)
        options.categoryID=categoryID; options.subcategoryID=subcategoryID; refresh(true)
    end)
    state.list=W.Dropdown(parent,273,-36,249,{},function(value)
        options.listID=value; refresh(true)
    end,{fontSize=12})
    W.Hint(state.list,L["自定义物品表"],L["选择购物清单，仅查看清单中的物品；与分类、搜索条件同时生效。"])
    state.table=A.CreateTable(parent,{x=12,y=-64,width=766,height=334,visible=11,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["物品"],x=8,width=286,sort=A.Title},
            {key="market",label=L["市场价"],x=300,width=96,align="RIGHT",color=C.gold,defaultDescending=true},
            {key="min",label=L["最低价"],x=402,width=92,align="RIGHT",defaultDescending=true},
            {key="quantity",label=L["在售"],x=500,width=54,align="RIGHT",defaultDescending=true},
            {key="liquidity",label=L["流通"],x=560,width=62,align="RIGHT",defaultDescending=true},
            {key="age",label=L["时间"],x=628,width=126,align="RIGHT"}},
        update=function(widget,row)
            widget.cells.name:SetText(A.Title(row)); widget.cells.market:SetText(A.Money(row.market,true))
            widget.cells.min:SetText(A.Money(row.min,true)); widget.cells.quantity:SetText(tostring(row.quantity or 0))
            widget.cells.liquidity:SetText(row.liquidity and format("%d%%",floor(row.liquidity*100)) or "—")
            widget.cells.age:SetText(A.Age(row.age))
        end,
        onClick=function(row) state.selected=row; state.table:SetSelected(row); A.OpenDrawer("prices"); updateDetail() end})
    createDetail()
    state.count=W.Text(parent,"",12,-405,10,C.muted,766)
end

A.RegisterPage({key="prices",build=build,refresh=refresh,
    setSearch=function(text) if state.searchBox then state.searchBox:SetText(text); state.searchBox:SetFocus() end end,
    snapshot=function() return {rows=#state.data,pooledRows=state.table and #state.table.rows or 0} end,
    layout={kind="table-drawer",toolbar="price-filters",tableWidth=766,drawerWidth=272,
        columns={"item","market","min","quantity","liquidity","age"},drawer="market-history"}})
