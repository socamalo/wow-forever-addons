local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, GameTooltip = CreateFrame, GameTooltip
local ipairs, pairs, tostring, type, unpack = ipairs, pairs, tostring, type, unpack
local concat, sort = table.concat, table.sort
local format = string.format
local date = date
local min, max = math.min, math.max
local time = time
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color

local sales={data={},selected=nil,lastView=nil}
local characters={data={},selected=nil,lastSignature=nil}

local function updateSalesDetail()
    local row=sales.selected; local detail=sales.detail
    detail.empty:SetShown(row==nil); detail.content:SetShown(row~=nil)
    if not row then return end
    detail.title:SetText(A.Title(row)); detail.kind:SetText(row.kind or L["售出"])
    detail.quantity:SetText(tostring(row.quantity or "—")); detail.amount:SetText(A.Money(row.amount or row.gross))
    detail.character:SetText(row.character or "—"); detail.time:SetText(row.at and date("%Y-%m-%d %H:%M",row.at) or "—")
end

local function refreshSales(force)
    if not sales.table then return end
    local options=A.Options("sales")
    local signature=A.Signature(options.view or "sales")
    local base,changed=A.Cached("sales:model",signature,function() return ns.Professions.GetSales({view=options.view}) end)
    local rows,viewChanged=A.FilterCached("sales:view",signature,base,options.search)
    local view=signature..":"..tostring(options.search or "")
    sales.data=rows
    if force or changed or viewChanged or sales.lastView~=view then
        sales.table:SetData(rows,force); sales.lastView=view
    else sales.table:Render() end
    if changed or viewChanged then sales.selected=A.Reconcile(rows,sales.selected) end
    sales.table:SetSelected(sales.selected); updateSalesDetail(); sales.count:SetText(format(L["%d 条记录"],#rows))
end

local function buildSales(parent)
    local options=A.Options("sales")
    sales.search=W.Edit(parent,12,-6,210,options.search or ""); sales.search:SetSize(210,22)
    A.BindSearch(sales.search,"sales",options,function() refreshSales(true) end)
    sales.table=A.CreateTable(parent,{x=12,y=-36,width=766,height=362,visible=12,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["物品"],x=8,width=390,sort=A.Title},
            {key="quantity",label=L["数量"],x=410,width=64,align="RIGHT",defaultDescending=true},
            {key="amount",label=L["金额"],x=490,width=118,align="RIGHT",color=C.gold,defaultDescending=true},
            {key="time",label=L["时间"],x=624,width=130,align="RIGHT",sortKey="at",defaultDescending=true}},
        update=function(widget,row)
            widget.cells.name:SetText(A.Title(row)); widget.cells.quantity:SetText(tostring(row.quantity or "—"))
            widget.cells.amount:SetText(A.Money(row.amount or row.gross,true))
            widget.cells.time:SetText(row.at and date("%m/%d %H:%M",row.at) or "—")
        end,
        onClick=function(row) sales.selected=row; sales.table:SetSelected(row); A.OpenDrawer("sales"); updateSalesDetail() end})
    local detail=A.CreateDrawer("sales"); sales.detail=detail
    detail.empty=W.Text(detail,L["选择一条销售记录查看详情。"],20,-130,11,C.muted,224); detail.empty:SetJustifyH("CENTER")
    detail.content=CreateFrame("Frame",nil,detail); detail.content:SetAllPoints()
    detail.title=W.Text(detail.content,"",12,-14,13,C.gold,214)
    local rows={{"kind",L["类型"]},{"quantity",L["数量"]},{"amount",L["金额"]},{"character",L["角色"]},{"time",L["时间"]}}
    for index,row in ipairs(rows) do
        W.Text(detail.content,row[2],12,-48-(index-1)*28,10,C.muted,92)
        local value=W.Text(detail.content,"—",102,-48-(index-1)*28,11,C.text,146); value:SetJustifyH("RIGHT"); detail[row[1]]=value
    end
    sales.count=W.Text(parent,"",12,-405,10,C.muted,766)
end

local function professionNames(row)
    local values={}
    for key,value in pairs(row.professions or {}) do
        values[#values+1]=type(value)=="table" and (value.name or tostring(key)) or tostring(value)
    end
    return #values>0 and concat(values,"、") or L["尚未读取"]
end

local function professionTags(row)
    local professions={}
    for key,value in pairs(row.professions or {}) do
        if type(value)=="table" and value.learned~=false then professions[#professions+1]=value
        elseif type(value)~="table" then professions[#professions+1]={name=tostring(value or key),learned=true} end
    end
    sort(professions,function(left,right) return tostring(left.name or "")<tostring(right.name or "") end)
    local tags={}
    for index=1,min(3,#professions) do
        local profession=professions[index]
        local icon=profession.texture and format("|T%s:14:14:0:0|t ",tostring(profession.texture)) or ""
        local level=(profession.maxSkillLevel or 0)>0 and format(" %s/%s",tostring(profession.skillLevel or 0),
            tostring(profession.maxSkillLevel)) or ""
        local accent=C.accent
        tags[#tags+1]=format("|cff%02x%02x%02x%s%s%s|r",accent[1]*255,accent[2]*255,accent[3]*255,
            icon,profession.name or L["专业"],level)
    end
    return #tags>0 and concat(tags,"   ") or L["暂无专业记录"]
end

local function updateCharacterDetail()
    local row=characters.selected; local detail=characters.detail
    detail.empty:SetShown(row==nil); detail.content:SetShown(row~=nil)
    if not row then return end
    detail.title:SetText(A.Title(row)); detail.realm:SetText(row.realm or "—")
    detail.professions:SetText(professionNames(row)); detail.recipes:SetText(tostring(row.recipeCount or 0))
    detail.gold:SetText(A.Money(row.gold)); detail.inventory:SetText(row.inventoryAt and date("%Y-%m-%d %H:%M",row.inventoryAt) or "—")
    detail.bank:SetText(row.bankAt and date("%Y-%m-%d %H:%M",row.bankAt) or L["尚未读取"])
    local best=ns.Professions.GetCharacterBestRecipes and ns.Professions.GetCharacterBestRecipes(row.key,8) or {}
    for index,line in ipairs(detail.bestLines) do
        local recipe=best[index]
        line.entry=recipe; line:SetShown(recipe~=nil)
        if recipe then
            local meta=line.icon:SetEntry(recipe)
            line.name:SetText(meta.name or A.Title(recipe))
            line.name:SetTextColor(unpack(line.icon.qualityColor or C.text))
            line.profit:SetText(A.Money(recipe.profit,true))
        end
    end
    detail.noRecipes:SetShown(#best==0)
    detail.age:SetText(row.isCurrent and L["当前角色的实时数据"] or format(L["背包 %s · 银行 %s"],
        A.Age(row.inventoryAt and max(0,(time and time() or row.inventoryAt)-row.inventoryAt)),
        A.Age(row.bankAt and max(0,(time and time() or row.bankAt)-row.bankAt))))
end

local function refreshCharacters(force)
    if not characters.table then return end
    local signature=A.Signature("characters")
    local rows,changed=A.Cached("characters:model",signature,function() return ns.Professions.GetCharacters() end)
    characters.data=rows
    if force or changed or characters.lastSignature~=signature then characters.table:SetData(rows,force); characters.lastSignature=signature
    else characters.table:Render() end
    if changed then characters.selected=A.Reconcile(rows,characters.selected) end
    characters.table:SetSelected(characters.selected); updateCharacterDetail()
    local totalGold,totalRecipes=0,0
    for index,row in ipairs(rows) do totalGold=totalGold+(row.gold or 0); totalRecipes=totalRecipes+(row.recipeCount or 0) end
    characters.summary:SetText(format(L["%d 个角色 · %d 个配方 · 共计 %s"],#rows,totalRecipes,A.Money(totalGold,true)))
end

local function buildCharacters(parent)
    characters.table=A.CreateTable(parent,{x=12,y=-6,width=766,height=392,visible=8,rowHeight=40,
        columns={{key="name",label=L["角色"],x=8,width=252,sort=A.Title},
            {key="realm",label=L["服务器"],x=264,width=126},
            {key="recipes",label=L["配方"],x=394,width=62,align="RIGHT",sortKey="recipeCount",defaultDescending=true},
            {key="gold",label=L["金币"],x=460,width=126,align="RIGHT",color=C.gold,defaultDescending=true},
            {key="freshness",label=L["数据新鲜度"],x=590,width=164,align="RIGHT",
                sortKey="inventoryAt",defaultDescending=true}},
        createRow=function(row)
            row.professionTags=W.Text(row,"",32,-22,10,C.muted,450)
        end,
        update=function(widget,row)
            widget.cells.name:SetText((row.isCurrent and "★ " or "")..A.Title(row)); widget.cells.realm:SetText(row.realm or "—")
            widget.cells.recipes:SetText(tostring(row.recipeCount or 0)); widget.cells.gold:SetText(A.Money(row.gold,true))
            widget.professionTags:SetText(professionTags(row))
            widget.cells.freshness:SetText(row.isCurrent and L["当前角色"] or format(L["%d 个配方 · %s"],
                row.recipeCount or 0,A.Age(row.inventoryAt and max(0,(time and time() or row.inventoryAt)-row.inventoryAt))))
        end,
        onClick=function(row)
            characters.selected=row; characters.table:SetSelected(row); A.OpenDrawer("characters"); updateCharacterDetail()
        end})
    local detail=A.CreateDrawer("characters"); characters.detail=detail
    detail.empty=W.Text(detail,L["选择角色查看专业与库存快照。"],20,-150,11,C.muted,224); detail.empty:SetJustifyH("CENTER")
    detail.content=CreateFrame("Frame",nil,detail); detail.content:SetAllPoints()
    detail.title=W.Text(detail.content,"",12,-14,13,C.gold,214)
    local rows={{"realm",L["服务器"]},{"professions",L["专业"]},{"recipes",L["配方"]},{"gold",L["金币"]},
        {"inventory",L["背包快照"]},{"bank",L["银行快照"]}}
    for index,row in ipairs(rows) do
        W.Text(detail.content,row[2],12,-42-(index-1)*22,10,C.muted,80)
        local value=W.Text(detail.content,"—",94,-42-(index-1)*22,10,C.text,154); value:SetJustifyH("RIGHT"); detail[row[1]]=value
    end
    W.Text(detail.content,L["此角色的最佳制作配方"],12,-184,11,C.gold,236)
    detail.bestLines={}
    for index=1,8 do
        local line=CreateFrame("Button",nil,detail.content)
        line:SetPoint("TOPLEFT",12,-206-(index-1)*25); line:SetSize(248,24)
        line.icon=W.Icon(line,0,-2,20); line.icon:EnableMouse(false)
        line.name=W.Text(line,"",26,-5,10,C.text,132)
        line.profit=W.Text(line,"",162,-5,10,C.accent,84); line.profit:SetJustifyH("RIGHT")
        line:SetScript("OnEnter",function(self) if self.entry then W.Tooltip(self,self.entry) end end)
        line:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
        line:Hide(); detail.bestLines[index]=line
    end
    detail.noRecipes=W.Text(detail.content,L["暂无已定价配方"],12,-214,10,C.muted,236)
    detail.age=W.Text(detail.content,"",12,-430,10,C.muted,236); detail.age:SetWordWrap(true)
    characters.summary=W.Text(parent,"",12,-405,10,C.muted,766)
end

A.RegisterPage({key="sales",build=buildSales,refresh=refreshSales,
    setSearch=function(text) if sales.search then sales.search:SetText(text); sales.search:SetFocus() end end,
    snapshot=function() return {rows=#sales.data,pooledRows=sales.table and #sales.table.rows or 0} end,
    layout={kind="table-drawer",tableWidth=766,drawerWidth=272,
        columns={"item","quantity","amount","time"},drawer="sale"}})

A.RegisterPage({key="characters",build=buildCharacters,refresh=refreshCharacters,
    snapshot=function() return {rows=#characters.data,pooledRows=characters.table and #characters.table.rows or 0} end,
    layout={kind="table-drawer",tableWidth=766,drawerWidth=272,
        columns={"character","realm","recipes","gold","freshness"},drawer="character"}})
