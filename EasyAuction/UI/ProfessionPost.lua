local addonName, ns = ... -- luacheck: ignore addonName
local ipairs, tostring, tonumber, type = ipairs, tostring, tonumber, type
local min, max, floor = math.min, math.max, math.floor
local format = string.format
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color

local state={data={},quantities={},requestID=nil,requestKey=nil,lastView=nil}

local function setting(key,default)
    local value=ns.ProfessionSettings and ns.ProfessionSettings.Get(key)
    if value==nil then return default end
    return value
end

local function quantity(row,text)
    local value=tonumber(text) or state.quantities[A.RowKey(row)] or row.quantity or 1
    return min(row.quantity or 1,max(1,floor(value)))
end

local function modelRow(row)
    local recipe=ns.Professions.GetRecipeForItem(row.itemID)
    local cost=recipe and ns.Professions.GetCost(recipe.recipeID,recipe.character)
    local price=ns.Prices and ns.Prices.Get(row.itemKey)
    row.recipeID=recipe and recipe.recipeID
    row.unitCost=cost and cost.perUnit
    row.unitPrice=price and (price.rivalMin or price.market or price.last)
    row.postQuantity=quantity(row)
    row.total=row.unitPrice and row.unitPrice*row.postQuantity
    local deposits=ns.Store.GetDB().professions and ns.Store.GetDB().professions.deposits
    local deposit=deposits and deposits[row.itemID]
    row.deposit=type(deposit)=="table" and deposit.unit or deposit
    row.locked=ns.Market.IsLocked(row.itemKey)
    return row
end

local function buildModel(showAll)
    local rows={}
    for index,row in ipairs(ns.Market.Bags()) do
        local recipe=ns.Professions.GetRecipeForItem(row.itemID)
        if showAll or recipe then rows[#rows+1]=modelRow(row) end
    end
    return rows
end

local function currentSnapshot()
    return ns.ProfessionPosting and ns.ProfessionPosting.Snapshot() or {}
end

local function updateAction(widget,row)
    local snapshot=currentSnapshot()
    local mine=state.requestKey==A.RowKey(row) and snapshot.requestID==state.requestID
    local busy=mine and (snapshot.state=="quoting" or snapshot.state=="submitted" or snapshot.state=="uncertain")
    local label=L["上架"]
    if mine and snapshot.state=="ready" then label=L["确认上架"]
    elseif mine and (snapshot.state=="warning" or snapshot.state=="needs-click") then label=L["继续"]
    elseif not row.unitPrice then label=L["查价"] end
    widget.post.label:SetText(label)
    W.Enabled(widget.post,not row.locked and ns.open==true and not busy)
end

local function updateRow(widget,row)
    local key=A.RowKey(row); local amount=quantity(row,state.quantities[key])
    row.postQuantity=amount; row.total=row.unitPrice and row.unitPrice*amount
    widget.cells.name:SetText(A.Title(row)); widget.cells.count:SetText(tostring(row.quantity or 0))
    widget.cells.cost:SetText(A.Money(row.unitCost,true)); widget.cells.sale:SetText(A.Money(row.unitPrice,true))
    widget.cells.total:SetText(A.Money(row.total,true)); widget.cells.quantity:SetText(""); widget.cells.action:SetText("")
    widget.rendering=true
    if not widget.qty:HasFocus() then widget.qty:SetText(tostring(amount)) end
    widget.rendering=nil; updateAction(widget,row)
end

local function submit(row,widget)
    if row.locked then A.SetMessage(L["物品已锁定"]); return end
    local amount=quantity(row,widget.qty:GetText()); state.quantities[A.RowKey(row)]=amount
    local snapshot=currentSnapshot(); local mine=state.requestKey==A.RowKey(row) and snapshot.requestID==state.requestID
    local ok,err
    if mine and (snapshot.state=="warning" or snapshot.state=="needs-click") then ok,err=ns.Market.Confirm()
    elseif mine and snapshot.state=="ready" then ok,err=ns.ProfessionPosting.Submit(state.requestID)
    else
        ok,err=ns.ProfessionPosting.Prepare({version=1,source="professions",itemKey=row.itemKey,
            bag=row.bag,slot=row.slot,quantity=amount,recipeID=row.recipeID})
        state.requestID=ok or nil; state.requestKey=ok and A.RowKey(row) or nil
        if ok and not setting("confirmBeforePosting",true) and currentSnapshot().state=="ready" then
            ok,err=ns.ProfessionPosting.Submit(state.requestID)
        end
    end
    A.SetMessage(ok and L["操作已提交"] or err and L[err] or L["操作未完成"])
    updateAction(widget,row)
end

local function refresh(force)
    if not state.table then return end
    local options=A.Options("post")
    local showAll=setting("postShowAllItems",true)
    local signature=A.Signature(tostring(showAll))
    local base,changed=A.Cached("post:model",signature,function() return buildModel(showAll) end)
    local rows,viewChanged=A.FilterCached("post:view",signature,base,options.search)
    local view=signature..":"..tostring(options.search or "")
    state.data=rows
    if force or changed or viewChanged or state.lastView~=view then state.table:SetData(rows,force); state.lastView=view
    else state.table:Render() end
    state.showAll:Update(); state.duration:Update()
    local total,unpriced,losses=0,0,0
    for index,row in ipairs(rows) do
        if row.total then total=total+row.total else unpriced=unpriced+1 end
        if row.unitCost and row.unitPrice and row.unitPrice<row.unitCost then losses=losses+1 end
    end
    state.summary:SetText(format(L["%d 组物品 · 估值 %s%s"],#rows,A.Money(total),
        unpriced>0 and format(L[" · %d 项无价格"],unpriced) or ""))
    state.warning:SetText(losses>0 and format(L["%d 项售价低于材料成本"],losses) or "")
    local snapshot=currentSnapshot()
    if snapshot.state=="quoting" then A.SetMessage(L["正在核价"])
    elseif snapshot.state=="submitted" then A.SetMessage(L["等待上架回执"])
    elseif snapshot.state=="uncertain" then A.SetMessage(L["回执未确定，请核对我的拍卖"])
    elseif snapshot.state=="complete" then A.SetMessage(L["上架成功"]) end
end

local function build(parent)
    local options=A.Options("post")
    state.duration=A.Dropdown(parent,L["拍卖时长"],12,-6,142,{{1,L["12 小时"]},{2,L["24 小时"]},{3,L["48 小时"]}},
        function() return setting("postDuration",2) end,function(value) ns.ProfessionSettings.Set("postDuration",value) end)
    state.showAll=A.Toggle(parent,L["背包全部物品"],162,-6,136,
        function() return setting("postShowAllItems",true) end,
        function(value) ns.ProfessionSettings.Set("postShowAllItems",value) end)
    state.search=W.Edit(parent,510,-6,268,options.search or ""); state.search:SetSize(268,22)
    A.BindSearch(state.search,"post",options,function() refresh(true) end)
    state.table=A.CreateTable(parent,{x=12,y=-36,width=766,height=340,visible=10,rowHeight=27,itemColumn="name",
        columns={{key="name",label=L["物品"],x=8,width=238,sort=A.Title},
            {key="count",label=L["持有"],x=250,width=48,align="RIGHT",sortKey="quantity",defaultDescending=true},
            {key="cost",label=L["成本"],x=302,width=88,align="RIGHT",sortKey="unitCost",defaultDescending=true},
            {key="sale",label=L["售价"],x=394,width=104,align="RIGHT",sortKey="unitPrice",defaultDescending=true},
            {key="total",label=L["总价"],x=502,width=104,align="RIGHT",defaultDescending=true},
            {key="quantity",label=L["数量"],x=610,width=52,align="RIGHT",sortKey="postQuantity",defaultDescending=true},
            {key="action",label=L["操作"],x=666,width=88,align="CENTER",sort=A.Title}},
        createRow=function(row)
            row.qty=A.RowEdit(row,610,52,"1"); row.qty:SetNumeric(true); row.qty:SetMaxLetters(7)
            row.qty:SetScript("OnTextChanged",function(self)
                if row.rendering or not row.entry then return end
                local amount=quantity(row.entry,self:GetText()); state.quantities[A.RowKey(row.entry)]=amount
                row.entry.total=row.entry.unitPrice and row.entry.unitPrice*amount
                row.cells.total:SetText(A.Money(row.entry.total))
            end)
            row.post=A.RowButton(row,L["上架"],666,88,function() if row.entry then submit(row.entry,row) end end,true)
        end,
        update=updateRow,
        onClick=function(row) state.table:SetSelected(row) end})
    state.summary=W.Text(parent,"",12,-384,11,C.text,520)
    state.warning=W.Text(parent,"",540,-384,10,C.gold,238); state.warning:SetJustifyH("RIGHT")
end

A.RegisterPage({key="post",build=build,refresh=refresh,
    setSearch=function(text) if state.search then state.search:SetText(text); state.search:SetFocus() end end,
    snapshot=function() return {rows=#state.data,pooledRows=state.table and #state.table.rows or 0} end,
    layout={kind="posting-table",toolbar="duration-search",
        columns={"item","count","cost","sale","total","quantity","action"}}})
