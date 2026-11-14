local addonName, ns = ... -- luacheck: ignore addonName
local ipairs, tostring = ipairs, tostring
local max = math.max
local format = string.format
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color

local state={queue={},materials={},selected=nil,lastSignature=nil}

local function buildModel()
    local model={queue=ns.Professions.GetQueue(),materials=ns.Professions.GetShoppingList()}
    local crafts,totalCost,unknown=0,0,0
    for index,row in ipairs(model.queue) do
        crafts=crafts+(row.quantity or 0)
        if row.totalCost then totalCost=totalCost+row.totalCost else unknown=unknown+1 end
    end
    local shopping,missing=0,0
    for index,row in ipairs(model.materials) do
        if (row.shortfall or 0)>0 then
            missing=missing+1
            if row.estimatedCost then shopping=shopping+row.estimatedCost else unknown=unknown+1 end
        end
    end
    model.crafts,model.totalCost,model.unknown=crafts,totalCost,unknown
    model.shopping,model.missing=shopping,missing
    return model
end

local function refresh(force)
    if not state.queueTable then return end
    local signature=A.Signature("queue")
    local model,changed=A.Cached("queue:model",signature,buildModel)
    state.queue,state.materials=model.queue,model.materials
    if force or changed or state.lastSignature~=signature then
        state.queueTable:SetData(state.queue,force)
        state.materialTable:SetData(state.materials,force)
        state.lastSignature=signature
    else
        state.queueTable:Render(); state.materialTable:Render()
    end
    if changed then state.selected=A.Reconcile(state.queue,state.selected) end
    state.summary:SetText(format(L["%d 次制作 · 材料 %s · 采购 %s%s"],model.crafts,A.Money(model.totalCost),A.Money(model.shopping),
        model.unknown>0 and format(L[" · %d 项无价格"],model.unknown) or ""))
    state.bankNote:SetText(model.missing>0 and format(L["仍缺 %d 种材料"],model.missing) or L["所需材料已备齐"])
    W.Enabled(state.open,state.selected~=nil and state.selected.recipeID~=nil)
end

local function adjust(row,delta)
    if not row.index then return end
    local quantity=max(0,(row.quantity or 0)+delta)
    local ok,err=ns.Professions.SetQuantity(row.index,quantity)
    A.SetMessage(ok and L["已更新制作队列"] or err and L[err] or L["操作未完成"])
    refresh(true)
end

local function searchMaterial(row)
    if not ns.open then A.SetMessage(L["请先打开拍卖行"]); return end
    local ok=ns.Market.Search(row.itemKey,function() A.SetMessage(L["价格数据已更新"]); refresh(true) end,
        function(err) A.SetMessage(err) end)
    if not ok then A.SetMessage(L["当前无法查询该物品"]); return end
    A.SetMessage(L["正在核价"])
end

local function build(parent)
    W.Text(parent,L["制作队列"],12,-10,11,C.muted,260)
    state.clear=W.Button(parent,L["清空"],696,-4,82,function()
        for index=#state.queue,1,-1 do
            local row=state.queue[index]
            if row.index then ns.Professions.RemoveQueue(row.index) end
        end
        state.selected=nil; refresh(true)
    end); state.clear:SetSize(82,22)
    state.queueTable=A.CreateTable(parent,{x=12,y=-32,width=766,height=346,visible=11,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["配方"],x=8,width=390,sort=A.Title},
            {key="cost",label=L["总成本"],x=410,width=110,align="RIGHT",sortKey="totalCost",defaultDescending=true},
            {key="quantity",label=L["数量"],x=530,width=48,align="RIGHT",defaultDescending=true}},
        createRow=function(row)
            row.minus=A.RowButton(row,"−",612,28,function() if row.entry then adjust(row.entry,-1) end end)
            row.plus=A.RowButton(row,"+",646,28,function() if row.entry then adjust(row.entry,1) end end)
            row.remove=A.RowButton(row,"×",710,28,function()
                if row.entry then adjust(row.entry,-(row.entry.quantity or 0)) end
            end)
        end,
        update=function(widget,row)
            widget.cells.name:SetText((row.isDependency and "› " or "")..A.Title(row))
            widget.cells.cost:SetText(A.Money(row.totalCost,true)); widget.cells.quantity:SetText(tostring(row.quantity or 0))
            widget.minus:SetShown(row.index~=nil); widget.plus:SetShown(row.index~=nil); widget.remove:SetShown(row.index~=nil)
        end,
        onClick=function(row)
            state.selected=row; state.queueTable:SetSelected(row); W.Enabled(state.open,row.recipeID~=nil); A.OpenDrawer("queue")
        end})
    local materialPanel=A.CreateDrawer("queue")
    W.Text(materialPanel,L["所需材料"],10,-12,12,C.gold,210)
    state.materialTable=A.CreateTable(materialPanel,{x=8,y=-38,width=256,height=444,visible=15,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["材料"],x=6,width=86,sort=A.Title},
            {key="need",label=L["需求"],x=96,width=30,align="RIGHT",sortKey="needed",defaultDescending=true},
            {key="have",label=L["持有"],x=130,width=30,align="RIGHT",defaultDescending=true},
            {key="cost",label=L["成本"],x=164,width=58,align="RIGHT",sortKey="estimatedCost",defaultDescending=true}},
        createRow=function(row)
            row.search=A.RowButton(row,L["查"],226,26,function() if row.entry then searchMaterial(row.entry) end end)
        end,
        update=function(widget,row)
            widget.cells.name:SetText(A.Title(row)); widget.cells.need:SetText(tostring(row.needed or 0))
            widget.cells.have:SetText(tostring(row.have or 0)); widget.cells.cost:SetText(A.Money(row.estimatedCost,true))
            widget.search:SetShown((row.shortfall or 0)>0 and row.source~="vendor")
        end})
    state.bankNote=W.Text(materialPanel,"",10,-506,10,C.muted,244)
    state.open=W.Button(parent,L["打开下一项配方"],12,-386,148,function()
        local row=state.selected or state.queue[1]
        if not row then return end
        local ok,err=ns.Professions.OpenRecipe(row.recipeID)
        if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
    end,true)
    state.summary=W.Text(parent,"",170,-394,10,C.text,608)
end

A.RegisterPage({key="queue",build=build,refresh=refresh,
    snapshot=function() return {rows=#state.queue,materials=#state.materials,
        pooledRows=(state.queueTable and #state.queueTable.rows or 0)+(state.materialTable and #state.materialTable.rows or 0)} end,
    layout={kind="table-drawer",tableWidth=766,drawerWidth=272,drawer="materials",
        columns={"recipe","cost","quantity","need","have"}}})
