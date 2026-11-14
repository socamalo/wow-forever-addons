local addonName, ns = ... -- luacheck: ignore addonName
local ipairs, tostring = ipairs, tostring
local sort = table.sort
local format = string.format
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color

local state={data={},lastSignature=nil}
local sourceOrder={vendor=1,auction=2,craft=3,["vendor-sale"]=4,unknown=5}

local function sourceLabel(source)
    return source=="vendor" and L["商人"] or source=="auction" and L["拍卖行"]
        or source=="craft" and L["制作"] or source=="vendor-sale" and L["卖店估值"] or L["未知"]
end

local function search(row)
    if not ns.open then A.SetMessage(L["请先打开拍卖行"]); return end
    local ok=ns.Market.Search(row.itemKey,function() A.SetMessage(L["价格数据已更新"]); A.Refresh(true) end,
        function(err) A.SetMessage(err) end)
    A.SetMessage(ok and L["正在核价"] or L["当前无法查询该物品"])
end

local function buildModel(options)
    local all=ns.Professions.GetShoppingList()
    local rows={}
    for index,row in ipairs(all) do
        if not options.hideSatisfied or (row.shortfall or 0)>0 then rows[#rows+1]=row end
    end
    sort(rows,function(left,right)
        local leftDone,rightDone=(left.shortfall or 0)<=0,(right.shortfall or 0)<=0
        if leftDone~=rightDone then return rightDone end
        if options.sortBy=="name" then return A.Title(left)<A.Title(right) end
        if options.sortBy=="cost" then
            local a,b=left.estimatedCost or 0,right.estimatedCost or 0
            if a~=b then return a>b end
        else
            local a,b=sourceOrder[left.source] or 9,sourceOrder[right.source] or 9
            if a~=b then return a<b end
        end
        return A.Title(left)<A.Title(right)
    end)
    local totals={vendor=0,auction=0,craft=0,unknown=0}; local counts={vendor=0,auction=0,craft=0,unknown=0}
    local outstanding,satisfied,saving=0,0,0
    for index,row in ipairs(all) do
        if (row.shortfall or 0)>0 then
            local source=row.source or "unknown"
            outstanding=outstanding+1; counts[source]=(counts[source] or 0)+1
            totals[source]=(totals[source] or 0)+(row.estimatedCost or 0)
            saving=saving+(row.savingTotal or 0)
        else satisfied=satisfied+1 end
    end
    return {rows=rows,totals=totals,counts=counts,outstanding=outstanding,satisfied=satisfied,saving=saving}
end

local function refresh(force)
    if not state.table then return end
    local options=A.Options("gather")
    if options.hideSatisfied==nil then options.hideSatisfied=true end
    local signature=A.Signature(tostring(options.hideSatisfied)..":"..tostring(options.sortBy or "source"))
    local model,changed=A.Cached("gather:model",signature,function() return buildModel(options) end)
    local rows=model.rows
    state.data=rows
    if force or changed or state.lastSignature~=signature then state.table:SetData(rows,force); state.lastSignature=signature
    else state.table:Render() end
    state.hide:Update(); state.sort:Update()
    state.progress:SetText(format(L["仍缺 %d / %d 种材料"],model.outstanding,model.outstanding+model.satisfied))
    state.vendor:SetText(format(L["商人 %s（%d 种）"],A.Money(model.totals.vendor),model.counts.vendor))
    state.auction:SetText(format(L["拍卖行 %s（%d 种）"],A.Money(model.totals.auction),model.counts.auction))
    state.total:SetText(format(L["合计 %s"],A.Money(model.totals.vendor+model.totals.auction+model.totals.craft
        +(model.totals["vendor-sale"] or 0))))
    state.saving:SetText(model.saving>0 and format(L["选择更便宜的来源可节省 %s"],A.Money(model.saving)) or "")
    state.unknown:SetText(model.counts.unknown>0 and format(L["%d 种材料缺少价格"],model.counts.unknown) or "")
end

local function build(parent)
    local options=A.Options("gather")
    if options.hideSatisfied==nil then options.hideSatisfied=true end
    state.hide=A.Toggle(parent,L["隐藏已备齐材料"],12,-6,146,
        function() return options.hideSatisfied end,function(value) options.hideSatisfied=value end)
    state.sort=A.Dropdown(parent,L["排序"],604,-6,174,{{"source",L["购买来源"]},{"cost",L["成本"]},{"name",L["名称"]}},
        function() return options.sortBy or "source" end,function(value) options.sortBy=value end)
    state.export=W.Button(parent,L["生成补货清单"],166,-6,142,function()
        local list,err=ns.Professions.ExportShoppingList()
        if list then ns.UI.SelectTab("buy"); ns.UI.SelectList(list)
        else A.SetMessage(err and L[err] or L["操作未完成"]) end
    end,true); state.export:SetSize(142,22)
    state.table=A.CreateTable(parent,{x=12,y=-36,width=766,height=310,visible=10,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["材料"],x=8,width=254,sort=A.Title},
            {key="need",label=L["需求"],x=266,width=48,align="RIGHT",sortKey="needed",defaultDescending=true},
            {key="have",label=L["持有"],x=318,width=48,align="RIGHT",defaultDescending=true},
            {key="source",label=L["购买来源"],x=370,width=76,align="RIGHT"},
            {key="unit",label=L["单价"],x=450,width=92,align="RIGHT",sortKey="unitCost",defaultDescending=true},
            {key="cost",label=L["成本"],x=546,width=108,align="RIGHT",sortKey="estimatedCost",defaultDescending=true}},
        createRow=function(row)
            row.search=A.RowButton(row,L["查"],704,48,function() if row.entry then search(row.entry) end end)
        end,
        update=function(widget,row)
            widget.cells.name:SetText(A.Title(row)); widget.cells.need:SetText(tostring(row.needed or 0))
            widget.cells.have:SetText(tostring(row.have or 0))
            widget.cells.source:SetText((row.shortfall or 0)<=0 and L["已备齐"] or sourceLabel(row.source))
            widget.cells.unit:SetText(A.Money(row.unitCost,true)); widget.cells.cost:SetText(A.Money(row.estimatedCost,true))
            widget.search:SetShown((row.shortfall or 0)>0 and row.source=="auction")
        end,
        onClick=function(row)
            state.table:SetSelected(row)
            if ns.UI and ns.UI.OpenAssistantPriceDetail then ns.UI.OpenAssistantPriceDetail(row,"gather") end
        end})
    state.progress=W.Text(parent,"",12,-354,11,C.text,210)
    state.vendor=W.Text(parent,"",12,-376,11,C.accent,210)
    state.auction=W.Text(parent,"",226,-376,11,C.text,210)
    state.total=W.Text(parent,"",440,-376,11,C.gold,210)
    state.saving=W.Text(parent,"",12,-397,10,C.accent,360)
    state.unknown=W.Text(parent,"",390,-397,10,C.muted,360)
end

A.RegisterPage({key="gather",build=build,refresh=refresh,
    snapshot=function() return {rows=#state.data,pooledRows=state.table and #state.table.rows or 0} end,
    layout={kind="table-summary",toolbar="source-filters",columns={"material","need","have","source","unit","cost"}}})
