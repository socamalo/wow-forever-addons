local addonName, ns = ... -- luacheck: ignore addonName
local STANDARD_TEXT_FONT = STANDARD_TEXT_FONT
local ipairs, pairs, tostring, tonumber, unpack = ipairs, pairs, tostring, tonumber, unpack
local CreateFrame, GameTooltip = CreateFrame, GameTooltip
local min, max, floor = math.min, math.max, math.floor
local concat = table.concat
local format = string.format
local W, L, A = ns.Widgets, ns.L, ns.ProfessionAssistant
local C = W.color
local lossColor={0.96,0.30,0.34}

local profit={selected=nil,data={},lastView=nil}

local function setProfitColor(label,value)
    local color=value and value>0 and C.bull or value and value<0 and C.bear or C.neutral
    label:SetTextColor(color[1],color[2],color[3])
end

local function service(method,...)
    local professions=ns.Professions
    return professions and professions[method] and professions[method](...) or {}
end

local function setValue(values,key,value,color)
    values[key]:SetText(value or "—")
    if color then values[key]:SetTextColor(color[1],color[2],color[3]) end
end

local function createDetail(key,titleText,rows)
    local panel=A.CreateDrawer(key)
    panel.title=W.Text(panel,titleText,12,-12,13,C.gold,214)
    panel.subtitle=W.Text(panel,L["选择一项查看详情"],12,-34,10,C.muted,236)
    panel.values={}; panel.labels={}
    for index,row in ipairs(rows) do
        local label=W.Text(panel,row[2],12,-58-(index-1)*22,10,C.muted,100)
        local value=W.Text(panel,"—",106,-58-(index-1)*22,11,C.text,142)
        value:SetJustifyH("RIGHT"); panel.labels[row[1]]=label; panel.values[row[1]]=value
    end
    local actionY=-76-#rows*22
    panel.orderTitle=W.Text(panel,L["加工单"],12,actionY+24,11,C.gold,236)
    panel.quantity=W.Edit(panel,12,actionY,52,"1"); panel.quantity:SetNumeric(true)
    panel.quantity:SetJustifyH("CENTER"); panel.quantity:SetSize(52,22)
    panel.add=W.Button(panel,L["加入队列"],72,actionY,90,function() end,true); panel.add:SetSize(90,22)
    panel.open=W.Button(panel,L["打开配方"],170,actionY,90,function() end); panel.open:SetSize(90,22)
    panel.empty=W.Text(panel,L["选择一项查看成本、售价、库存和操作。"],20,-130,11,C.muted,224)
    panel.empty:SetJustifyH("CENTER"); panel.empty:SetWordWrap(true)
    return panel
end

local function updateProfitDetail()
    local panel=profit.detail; if not panel then return end
    local row=profit.selected; panel.empty:SetShown(row==nil)
    panel.title:SetShown(row~=nil); panel.subtitle:SetShown(row~=nil)
    for key,value in pairs(panel.values) do value:SetShown(row~=nil); panel.labels[key]:SetShown(row~=nil) end
    panel.orderTitle:SetShown(row~=nil); panel.quantity:SetShown(row~=nil); panel.add:SetShown(row~=nil); panel.open:SetShown(row~=nil)
    if not row then return end
    local vendor=A.Options("profit").analysisMode=="vendor"
    panel.title:SetText(A.Title(row)); panel.subtitle:SetText(row.profession or row.reason or "")
    setValue(panel.values,"yield",tostring(row.cost and row.cost.yield or 1))
    setValue(panel.values,"unitSale",A.Money(row.unitRevenue))
    setValue(panel.values,"live",vendor and "—" or tostring(row.liveCount or 0))
    setValue(panel.values,"craftable",tostring(row.craftableNow or 0))
    local stockLimit=row.postLimit and row.postLimit>0 and tostring(row.postLimit) or "∞"
    setValue(panel.values,"stock",format("%s / %s",tostring(row.stock or 0),stockLimit))
    setValue(panel.values,"age",vendor and "—" or A.Age(row.age))
    setValue(panel.values,"status",not vendor and row.atPostLimit and L["库存已达上限"]
        or row.partialCost and L["部分成本估算：缺价材料未计入，未选品质取已有最低报价"]
        or row.reason or not vendor and row.stale and L["价格已过期"] or L["可加入队列"])
    W.Enabled(panel.add,row.recipeID~=nil); W.Enabled(panel.open,row.recipeID~=nil)
end

local function profitSignature(options)
    return A.Signature(concat({tostring(options.professionCategory),tostring(options.skillLineID),tostring(options.craftableOnly),
        tostring(options.showUnpriced),tostring(options.accountWide),tostring(options.ignorePostLimit),
        tostring(options.minLiveCount or 0),tostring(options.minMargin),tostring(options.maxMargin or ""),
        tostring(options.sortBy or "rank"),tostring(options.analysisMode or "auction")},":"))
end

local function refreshProfit(force)
    if not profit.table then return end
    local options=A.Options("profit")
    local categories=service("GetProfessionCategories")
    local validProfession=options.skillLineID==nil
    local validCategory=options.professionCategory==nil
    local skillLineIDs
    for categoryIndex=1,#categories do
        local category=categories[categoryIndex]
        if category.id==options.professionCategory then
            validCategory=true; skillLineIDs={}
            for childIndex=1,#(category.children or {}) do skillLineIDs[category.children[childIndex].id]=true end
        end
        for childIndex=1,#(categories[categoryIndex].children or {}) do
            if tonumber(categories[categoryIndex].children[childIndex].id)==tonumber(options.skillLineID) then validProfession=true end
        end
    end
    if not validCategory then options.professionCategory=nil; skillLineIDs=nil end
    if not validProfession then options.skillLineID=nil end
    local signature=profitSignature(options)
    local base,changed=A.Cached("profit:model",signature,function()
        return service("GetRanked",{skillLineID=options.skillLineID,skillLineIDs=skillLineIDs,
            craftableOnly=options.craftableOnly,
            showUnpriced=options.showUnpriced,accountWide=options.accountWide,
            ignorePostLimit=options.ignorePostLimit,minLiveCount=options.minLiveCount,minMargin=options.minMargin,
            maxMargin=options.maxMargin,sortBy=options.sortBy or "rank",search="",analysisMode=options.analysisMode or "auction"})
    end)
    local vendor=options.analysisMode=="vendor"
    profit.table.columns.sale.label=vendor and L["卖店价"] or L["拍卖价"]
    profit.table.columns.profit.label=vendor and L["卖店利润"] or L["拍卖利润"]
    profit.table.columns.margin.label=vendor and L["卖店利润率"] or L["利润率"]
    profit.detail.labels.unitSale:SetText(vendor and L["单件卖店价"] or L["单件拍卖价"])
    for mode,button in pairs(profit.modes) do
        local active=(mode=="vendor")==vendor
        W.SetButtonState(button,active,false)
        local color=active and C.buttonTextActive or C.buttonText
        button.label:SetTextColor(color[1],color[2],color[3])
    end
    W.Enabled(profit.minLiveCount,not vendor); W.Enabled(profit.stockFilter,not vendor)
    local view=signature..":"..tostring(options.search or "")
    local viewChanged
    profit.data,viewChanged=A.FilterCached("profit:view",signature,base,options.search)
    if force or changed or viewChanged or profit.lastView~=view then
        profit.lastView=view
        profit.table:SetData(profit.data,force)
    else profit.table:Render() end
    if changed or viewChanged then profit.selected=A.Reconcile(profit.data,profit.selected) end
    profit.table:SetSelected(profit.selected); updateProfitDetail()
    categories=service("GetProfessionCategories")
    local selectedCategory,selectedChild=categories[1],nil
    for categoryIndex=1,#categories do
        local category=categories[categoryIndex]
        if category.id==options.professionCategory then selectedCategory=category end
        for childIndex=1,#(category.children or {}) do
            local child=category.children[childIndex]
            if tonumber(child.id)==tonumber(options.skillLineID) then selectedCategory,selectedChild=category,child end
        end
    end
    profit.profession:SetCategories(categories,selectedChild or selectedCategory,selectedChild)
    profit.count:SetText(format(L["%d 个配方"],#profit.data))
end

local function numberFilter(parent,label,x,width,options,key)
    W.Text(parent,label,x,-10,10,C.muted,width)
    local box=W.Edit(parent,x+width,-6,48,tostring(options[key] or "")); box:SetSize(48,22); box:SetNumeric(true)
    box:SetScript("OnEnterPressed",function(self) self:ClearFocus() end)
    box:HookScript("OnEditFocusLost",function(self)
        local value=tonumber(self:GetText())
        if value and value<0 then value=0 end
        options[key]=value
        self:SetText(value and tostring(value) or "")
        refreshProfit(true)
    end)
    return box
end

local function buildProfit(parent)
    local options=A.Options("profit")
    local search=W.Edit(parent,12,-6,136,options.search or ""); search:SetSize(136,22); search:SetFont(STANDARD_TEXT_FONT,11,"")
    A.BindSearch(search,"profit",options,function() refreshProfit(true) end); profit.search=search
    profit.profession=W.CategoryDropdown(parent,156,-6,132,function(categoryID,childID)
        options.professionCategory=categoryID~="all" and categoryID or nil
        options.skillLineID=childID~="all" and tonumber(childID) or nil
        refreshProfit(true)
    end)
    local categories=service("GetProfessionCategories")
    profit.profession:SetCategories(categories,categories[1])
    profit.minLiveCount=numberFilter(parent,L["最低在售"],296,54,options,"minLiveCount")
    numberFilter(parent,L["最低利润率"],406,66,options,"minMargin")
    numberFilter(parent,L["最高利润率"],528,66,options,"maxMargin")
    A.Dropdown(parent,L["排序"],650,-6,128,{{"rank",L["推荐"]},{"profit",L["利润"]},{"margin",L["利润率"]},{"roi",L["投资回报率"]}},
        function() return options.sortBy or "rank" end,function(value) options.sortBy=value end)
    A.Toggle(parent,L["当前可制作"],12,-34,112,function() return options.craftableOnly==true end,function(value) options.craftableOnly=value end)
    A.Toggle(parent,L["显示无价格项"],132,-34,122,function() return options.showUnpriced==true end,function(value) options.showUnpriced=value end)
    A.Toggle(parent,L["全部角色"],262,-34,102,function() return options.accountWide==true end,function(value) options.accountWide=value end)
    profit.stockFilter=A.Toggle(parent,L["显示库存已满项"],372,-34,134,
        function() return options.ignorePostLimit==true end,function(value) options.ignorePostLimit=value end)
    profit.modes={}
    for index,entry in ipairs({{"auction",L["拍卖分析"]},{"vendor",L["卖店分析"]}}) do
        local mode=entry[1]
        local button=W.Button(parent,entry[2],514+(index-1)*134,-32,130,function()
            options.analysisMode=mode; refreshProfit(true)
        end)
        button:SetSize(130,22); profit.modes[mode]=button
    end
    profit.table=A.CreateTable(parent,{x=12,y=-58,width=766,height=340,visible=11,rowHeight=25,itemColumn="name",
        columns={{key="name",label=L["制作物品"],x=8,width=188,sort=A.Title},
            {key="cost",label=L["成本"],x=200,width=80,align="RIGHT",sortKey="totalCost",defaultDescending=true},
            {key="sale",label=L["拍卖价"],x=286,width=86,align="RIGHT",sortKey="revenue",defaultDescending=true},
            {key="profit",label=L["拍卖利润"],x=378,width=86,align="RIGHT",color=C.gold,defaultDescending=true},
            {key="margin",label=L["利润率"],x=470,width=80,align="RIGHT",defaultDescending=true},
            {key="make",label=L["可制作"],x=556,width=46,align="RIGHT",sortKey="craftableNow",defaultDescending=true},
            {key="stock",label=L["库存"],x=608,width=66,align="RIGHT",defaultDescending=true},
            {key="age",label=L["更新"],x=680,width=74,align="RIGHT",sortKey="updated",defaultDescending=true}},
        update=function(widget,row)
            widget.cells.name:SetText((row.recommended and "★ " or "")..A.Title(row))
            widget.cells.cost:SetText(row.partialCost and (A.Money(row.partialCost,true).." *") or A.Money(row.totalCost,true))
            widget.cells.sale:SetText(A.Money(row.revenue,true))
            local estimate = row.profitEstimated and " *" or ""
            widget.cells.profit:SetText(A.Money(row.profit,true)..(row.profit and estimate or ""))
            widget.cells.margin:SetText(row.margin and (format("%.0f%%",row.margin*100)..estimate) or "—")
            setProfitColor(widget.cells.profit,row.profit); setProfitColor(widget.cells.margin,row.margin)
            widget.cells.make:SetText(tostring(row.craftableNow or 0))
            local stockLimit=row.postLimit and row.postLimit>0 and tostring(row.postLimit) or "∞"
            widget.cells.stock:SetText(format("%s/%s",tostring(row.stock or 0),stockLimit))
            widget.cells.age:SetText(options.analysisMode=="vendor" and "—" or A.Age(row.age))
        end,
        onClick=function(row,button)
            if button=="RightButton" then
                local ok,err=ns.Professions.AddQueue(row.recipeID,1,row.owner)
                A.SetMessage(ok and format(L["已加入队列：%s"],A.Title(row)) or err and L[err] or L["操作未完成"])
                return
            end
            profit.selected=row; profit.table:SetSelected(row); A.OpenDrawer("profit"); updateProfitDetail()
            if ns.UI and ns.UI.OpenAssistantPriceDetail then ns.UI.OpenAssistantPriceDetail(row,"profit") end
        end})
    profit.detail=createDetail("profit",L["加工计划"],{{"yield",L["每次产量"]},{"unitSale",L["单件拍卖价"]},
        {"live",L["在售数量"]},{"craftable",L["当前可制作"]},{"stock",L["库存 / 上限"]},
        {"age",L["价格更新"]},{"status",L["状态"]}})
    profit.detail.add:SetScript("OnClick",function()
        local row=profit.selected; local quantity=tonumber(profit.detail.quantity:GetText())
        if not row or not quantity or quantity<1 or quantity~=floor(quantity) then A.SetMessage(L["请输入有效数量"]); return end
        local ok,err=ns.Professions.AddQueue(row.recipeID,quantity,row.owner)
        A.SetMessage(ok and L["操作已提交"] or err and L[err] or L["操作未完成"])
    end)
    profit.detail.open:SetScript("OnClick",function()
        if not profit.selected then return end
        local ok,err=ns.Professions.OpenRecipe(profit.selected.recipeID)
        if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
    end)
    profit.count=W.Text(parent,"",12,-405,10,C.muted,766)
end

-- 专业冲级：主页面是 12.1 九个专业的指引标签页，选中后显示内置升级路线
-- （数据按物品 ID 匹配游戏配方，名称取自游戏客户端），行内可跳转原生专业
-- 界面；外挂侧窗是路线配方与所需物料表，支持一键生成采购清单和打开专业
-- 界面。指引未覆盖的区间由算法路线（X.Plan）兜底，1.60.1 方案预留数据位。
local tierColors={optimal={1.00,0.50,0.25},medium={1.00,1.00,0.00},easy={0.25,0.75,0.25},
    trivial={0.52,0.56,0.58},unknown=C.muted}
local learnColor={1.00,0.62,0.25}
local levelup={data={},guide=nil,stepOffset=0,tabs={}}

local function tierColor(tier)
    return tierColors[tier] or tierColors.unknown
end

local updateLevelDrawer

local function createLevelDrawer()
    local panel=A.CreateDrawer("levelup")
    panel.title=W.Text(panel,L["冲级指引"],12,-12,13,C.gold,236)
    panel.skill=W.Text(panel,"",12,-34,10,C.muted,248)
    panel.trainers=W.Text(panel,"",12,-47,9,C.gold,248)
    W.Text(panel,L["配方"],12,-58,9,C.muted,150)
    local headCount=W.Text(panel,L["次数"],166,-58,9,C.muted,40); headCount:SetJustifyH("RIGHT")
    local headCost=W.Text(panel,L["成本"],210,-58,9,C.muted,46); headCost:SetJustifyH("RIGHT")
    panel.stepRows={}
    for index=1,7 do
        local row=CreateFrame("Button",nil,panel)
        row:SetPoint("TOPLEFT",8,-68-(index-1)*21); row:SetSize(248,21)
        row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        row:GetHighlightTexture():SetVertexColor(1,1,1,0.07)
        row:RegisterForClicks("LeftButtonUp","RightButtonUp")
        row.icon=W.Icon(row,2,0,18); row.icon:EnableMouse(false)
        row.name=W.Text(row,"",25,1,10,C.text,127)
        row.count=W.Text(row,"",158,1,10,C.text,36); row.count:SetJustifyH("RIGHT")
        row.cost=W.Text(row,"",198,1,10,C.text,46); row.cost:SetJustifyH("RIGHT")
        row:SetScript("OnEnter",function(self)
            if self.entry and self.entry.itemKey then W.Tooltip(self,self.entry) end
        end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        row:SetScript("OnClick",function(self,button)
            local step=self.entry
            if not step then return end
            if button=="RightButton" and step.recipeID and (step.count or 0)>0 then
                local ok,err=ns.Professions.AddQueue(step.recipeID,step.count,step.owner)
                A.SetMessage(ok and format(L["已加入队列：%s x%d"],A.Title(step),step.count)
                    or err and L[err] or L["操作未完成"])
                return
            end
            if step.recipeID then
                local ok,err=ns.Professions.OpenRecipe(step.recipeID)
                if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
            end
        end)
        panel.stepRows[index]=row
    end
    panel.stepPage=W.Text(panel,"",12,-219,9,C.muted,248)
    panel.matTitle=W.Text(panel,"",12,-233,10,C.muted,248)
    panel.matRows={}
    for index=1,7 do
        local row=CreateFrame("Button",nil,panel)
        row:SetPoint("TOPLEFT",12,-245-(index-1)*19); row:SetSize(244,19)
        row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        row:GetHighlightTexture():SetVertexColor(1,1,1,0.07)
        row.icon=W.Icon(row,2,-1,18); row.icon:EnableMouse(false)
        row.name=W.Text(row,"",25,0,10,C.text,147)
        row.value=W.Text(row,"",176,0,10,C.text,64); row.value:SetJustifyH("RIGHT")
        row:SetScript("OnEnter",function(self)
            if self.entry and self.entry.itemKey then W.Tooltip(self,self.entry) end
        end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        panel.matRows[index]=row
    end
    panel.total=W.Text(panel,"",12,-386,10,C.gold,248)
    panel.open=W.Button(panel,L["打开专业界面"],12,-404,120,function()
        local guide=levelup.guide
        local ok,err=ns.Professions.OpenProfession(guide and guide.skillLineID)
        if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
    end)
    panel.open:SetSize(120,24)
    panel.export=W.Button(panel,L["加入采购列表"],136,-404,124,function()
        local list,err=ns.Professions.ExportLevelUpPlan(levelup.guide)
        if list then
            ns.UI.SelectTab("buy"); ns.UI.SelectList(list)
            A.SetMessage(format(L["已加入采购列表：%s"],list.name or L["冲级材料"]))
        else A.SetMessage(err and L[err] or L["操作未完成"]) end
    end,true)
    panel.export:SetSize(124,24)
    W.Text(panel,L["◆ 为过渡备料步骤；左键步骤打开配方，右键按次数加入队列。"],12,-438,9,C.muted,248)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel",function(self,delta)
        levelup.stepOffset=levelup.stepOffset-delta*3
        updateLevelDrawer()
    end)
    return panel
end

function updateLevelDrawer()
    local panel=levelup.drawer; if not panel then return end
    local guide=levelup.guide
    if not guide or guide.ok~=true then
        panel.skill:SetText(guide and guide.reason or L["专业指引尚未就绪。"])
        panel.trainers:SetText(""); panel.trainers:SetShown(false)
        for index,row in ipairs(panel.stepRows) do row:SetShown(false); row.entry=nil end -- luacheck: ignore index
        for index,row in ipairs(panel.matRows) do row:SetShown(false); row.entry=nil end -- luacheck: ignore index
        panel.stepPage:SetText(""); panel.matTitle:SetText(""); panel.total:SetText("")
        W.Enabled(panel.export,false); W.Enabled(panel.open,false)
        return
    end
    local trainers=guide.trainers
    if type(trainers)=="table" and #trainers>0 then
        local parts={}
        for index=1,#trainers do
            local trainer=trainers[index]
            parts[#parts+1]=trainer.name and (trainer.name.." "..trainer.coords) or trainer.coords
        end
        panel.trainers:SetText(L["训练师"].."  "..concat(parts," · "))
        panel.trainers:SetShown(true)
    else
        panel.trainers:SetText(""); panel.trainers:SetShown(false)
    end
    local skillText
    if guide.maxSkill and guide.maxSkill>0 then
        skillText=format(L["技能 %d / %d → %d"],guide.skill,guide.maxSkill,guide.target)
    else
        skillText=format(L["技能 %d → %d"],guide.skill,guide.target)
    end
    panel.skill:SetText((guide.profession and (skillText.." · "..guide.profession) or skillText)
        ..(guide.reason and ("（"..guide.reason.."）") or ""))
    local steps=guide.steps or {}
    local offset=min(max(0,levelup.stepOffset),max(0,#steps-7))
    for index=1,7 do
        local row=panel.stepRows[index]
        local step=steps[offset+index]
        row:SetShown(step~=nil); row.entry=step
        if step then
            local color
            if step.note then color=C.muted
            elseif step.learned==false then color=learnColor
            elseif step.kind=="prepare" then color=C.accent
            else color=tierColor(step.tier) end
            local prefix=step.kind=="prepare" and "◆ " or ""
            row.name:SetText(prefix..(step.name or tostring(step.recipeID or "")))
            row.name:SetTextColor(color[1],color[2],color[3])
            if step.spellID and step.icon then
                row.icon:SetSpell(step); row.icon:SetShown(true)
            elseif step.itemKey then
                row.icon:SetEntry(step); row.icon:SetShown(true)
                if row.icon.qualityColor then row.name:SetTextColor(unpack(row.icon.qualityColor)) end
            else row.icon:SetShown(false) end
            row.count:SetText(step.note and "—" or format("x%d",step.count or 0))
            if step.cost then
                row.cost:SetText(A.Money(step.cost,true)); row.cost:SetTextColor(unpack(C.text))
            else
                row.cost:SetText(step.note and "—" or L["无价格"]); row.cost:SetTextColor(unpack(C.muted))
            end
        end
    end
    panel.stepPage:SetText(#steps>0 and format(L["%d–%d / %d 步"],offset+1,min(offset+7,#steps),#steps) or "")
    local materials=guide.materials or {}
    local visible,missing=0,0
    for index=1,#materials do
        local material=materials[index]
        if (material.shortfall or 0)>0 then
            missing=missing+1
            if visible<7 then
                visible=visible+1
                local row=panel.matRows[visible]
                row:SetShown(true); row.entry=material
                if material.itemKey then row.icon:SetEntry(material); row.icon:SetShown(true)
                else row.icon:SetShown(false) end
                row.name:SetText(material.name)
                if row.icon.qualityColor then row.name:SetTextColor(unpack(row.icon.qualityColor))
                else row.name:SetTextColor(unpack(C.text)) end
                row.value:SetText(format(L["缺 x%d"],material.shortfall))
                local valueColor=material.cost and C.text or lossColor
                row.value:SetTextColor(valueColor[1],valueColor[2],valueColor[3])
            end
        end
    end
    for index=visible+1,7 do panel.matRows[index]:SetShown(false); panel.matRows[index].entry=nil end
    panel.matTitle:SetText(missing>0 and format(L["材料（缺口 %d 项）"],missing) or L["材料已备齐"])
    if guide.totals.unpriced>0 then
        panel.total:SetText(format(L["预计采购 %s（%d 种材料缺价）"],A.Money(guide.totals.cost),guide.totals.unpriced))
    else
        panel.total:SetText(format(L["预计采购 %s"],A.Money(guide.totals.cost)))
    end
    W.Enabled(panel.export,missing>0)
    W.Enabled(panel.open,guide.skillLineID~=nil)
end

local function refreshLevelup(force)
    if not levelup.table then return end
    local options=A.Options("levelup")
    local available=ns.Professions.GuideProfessions and ns.Professions.GuideProfessions() or {}
    local valid=false
    for index=1,#available do if available[index].key==options.guideKey then valid=true; break end end
    if not valid then options.guideKey=available[1] and available[1].key or nil end
    if not options.guideKey then
        levelup.guide={ok=false,guide=true,steps={},materials={},reason=L["暂无专业记录"]}
        levelup.table:SetData({},force); updateLevelDrawer(); levelup.count:SetText(L["暂无专业记录"])
        return
    end
    local signature=A.Signature(tostring(options.guideKey))
    local guide,changed=A.Cached("levelup:guide",signature,function()
        return service("GetLevelUpGuide",{guideKey=options.guideKey})
    end)
    levelup.guide=guide
    if changed or force then levelup.table:SetData(guide.steps or {},force)
    else levelup.table:Render() end
    for key,button in pairs(levelup.tabs) do
        local active=key==options.guideKey
        W.SetButtonState(button,active,false)
        local labelColor=active and C.buttonTextActive or C.buttonText
        button.label:SetTextColor(labelColor[1],labelColor[2],labelColor[3])
    end
    updateLevelDrawer()
    local learned,unlearned,notes=0,0,0
    for index,step in ipairs(guide.steps or {}) do -- luacheck: ignore index
        if step.note then notes=notes+1
        elseif step.learned==false then unlearned=unlearned+1
        else learned=learned+1 end
    end
    levelup.count:SetText(format(L["已学 %d · 需学习 %d · 指引提示 %d"],learned,unlearned,notes))
    if #(guide.steps or {})==0 then
        levelup.table.empty:SetText(guide.reason or L["暂无可提升技能的配方。"])
    end
end

local function buildLevelup(parent)
    local options=A.Options("levelup")
    levelup.tabs={}
    local guideProfessions=ns.Professions.GuideProfessions and ns.Professions.GuideProfessions() or {}
    local selected=false
    for index=1,#guideProfessions do if guideProfessions[index].key==options.guideKey then selected=true; break end end
    if not selected then options.guideKey=guideProfessions[1] and guideProfessions[1].key or nil end
    for index,entry in ipairs(guideProfessions) do -- luacheck: ignore index
        local button=W.Button(parent,entry.label,12+(index-1)*84,-6,80,function()
            options.guideKey=entry.key
            A.Invalidate("levelup:guide")
            refreshLevelup(true)
        end)
        button:SetSize(80,22); button.label:SetFont(STANDARD_TEXT_FONT,10,"")
        if entry.texture then
            W.ButtonIcon(button,entry.texture)
            button.icon:ClearAllPoints(); button.icon:SetPoint("LEFT",5,0); button.icon:SetSize(16,16)
            button.label:ClearAllPoints(); button.label:SetPoint("LEFT",25,0); button.label:SetWidth(52)
        end
        levelup.tabs[entry.key]=button
    end
    levelup.table=A.CreateTable(parent,{x=12,y=-36,width=766,height=362,visible=12,rowHeight=25,itemColumn="name",
        columns={{key="range",label=L["技能区间"],x=8,width=72},
            {key="name",label=L["配方"],x=84,width=236,sort=A.Title},
            {key="count",label=L["次数"],x=324,width=52,align="RIGHT",sortKey="count",defaultDescending=true},
            {key="unit",label=L["单次成本"],x=380,width=92,align="RIGHT",sortKey="unitCost",defaultDescending=true},
            {key="cost",label=L["小计"],x=476,width=92,align="RIGHT",sortKey="cost",defaultDescending=true},
            {key="state",label=L["状态"],x=572,width=76,align="RIGHT"},
            {key="view",label=L["查看"],x=652,width=56}},
        createRow=function(row)
            row.view=A.RowButton(row,L["打开"],654,48,function()
                local entry=row.entry
                if not entry or not entry.recipeID then return end
                local ok,err=ns.Professions.OpenRecipe(entry.recipeID)
                if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
            end)
        end,
        update=function(widget,row)
            widget.cells.range:SetText(format("%d-%d",row.from or 0,row.to or 0))
            local color
            if row.note then color=C.muted
            elseif row.learned==false then color=learnColor
            elseif row.kind=="prepare" then color=C.accent
            else color=tierColor(row.tier) end
            local prefix=row.kind=="prepare" and "◆ " or ""
            widget.cells.name:SetText(prefix..(row.name or "—"))
            widget.cells.name:SetTextColor(color[1],color[2],color[3])
            widget.cells.count:SetText(row.note and "—" or format("x%d",row.count or 0))
            if row.unitCost then
                widget.cells.unit:SetText(A.Money(row.unitCost,true))
                widget.cells.unit:SetTextColor(unpack(C.text))
            else
                widget.cells.unit:SetText(row.note and "—" or L["无价格"])
                widget.cells.unit:SetTextColor(unpack(C.muted))
            end
            widget.cells.cost:SetText(row.cost and A.Money(row.cost,true)
                or (row.note and "—" or L["无价格"]))
            widget.cells.state:SetText(row.note and L["指引提示"]
                or row.learned==false and L["需学习"]
                or row.kind=="prepare" and L["备料"] or L["已学"])
            widget.view:SetShown(row.recipeID~=nil)
        end,
        onEnter=function(widget,row)
            GameTooltip:SetOwner(widget,"ANCHOR_RIGHT")
            GameTooltip:SetText(row.name or "",1,1,1)
            GameTooltip:AddDoubleLine(L["技能区间"],format("%d - %d",row.from or 0,row.to or 0),0.7,0.7,0.7,1,1,1)
            if row.text then GameTooltip:AddLine(row.text,0.91,0.93,0.92,true) end
            if type(row.trainers)=="table" then
                for index=1,#row.trainers do
                    local trainer=row.trainers[index]
                    GameTooltip:AddDoubleLine(L["训练师"],
                        trainer.name and (trainer.name.."  "..trainer.coords) or trainer.coords,
                        0.7,0.7,0.7,1,0.82,0.2)
                end
            elseif row.trainerCoords then
                GameTooltip:AddDoubleLine(L["训练师坐标"],row.trainerCoords,0.7,0.7,0.7,1,0.82,0.2)
            end
            if row.learned==false then GameTooltip:AddLine(L["该配方尚未学习，学习后才能制作。"],0.91,0.76,0.35,true) end
            if row.kind=="prepare" then GameTooltip:AddLine(L["过渡材料：先制作该产物供后续步骤使用。"],0.39,0.85,0.70) end
            local recipe=ns.Professions.GetRecipe(row.recipeID,row.owner)
            if recipe and (recipe.gray or 0)>0 then
                GameTooltip:AddDoubleLine(L["灰色点数"],format(L["技能 %d 后不再提升"],recipe.gray),0.7,0.7,0.7,1,1,1)
            end
            if row.unitCost then
                GameTooltip:AddDoubleLine(L["单次成本"],A.Money(row.unitCost),0.7,0.7,0.7,1,1,1)
            end
            GameTooltip:AddLine(L["右键点击，按指引次数加入队列。"],0.5,0.5,0.5)
            GameTooltip:Show()
        end,
        onClick=function(row,button)
            if button=="RightButton" then
                if row.recipeID and (row.count or 0)>0 then
                    local ok,err=ns.Professions.AddQueue(row.recipeID,row.count,row.owner)
                    A.SetMessage(ok and format(L["已加入队列：%s x%d"],A.Title(row),row.count)
                        or err and L[err] or L["操作未完成"])
                end
                return
            end
            if row.recipeID then
                local ok,err=ns.Professions.OpenRecipe(row.recipeID)
                if not ok then A.SetMessage(err and L[err] or L["操作未完成"]) end
            elseif row.note then
                A.SetMessage(row.name or "")
            end
        end})
    levelup.drawer=createLevelDrawer()
    levelup.count=W.Text(parent,"",12,-405,10,C.muted,766)
end

A.RegisterPage({key="profit",build=buildProfit,refresh=refreshProfit,
    setSearch=function(text) if profit.search then profit.search:SetText(text); profit.search:SetFocus() end end,
    snapshot=function() return {rows=#profit.data,pooledRows=profit.table and #profit.table.rows or 0} end,
    layout={kind="table-drawer",toolbar="profit-filters",tableWidth=766,drawerWidth=272,
        columns={"craft","cost","sale","profit","margin","make","stock","age"},drawer="recipe"}})

A.RegisterPage({key="levelup",build=buildLevelup,refresh=refreshLevelup,
    snapshot=function()
        return {rows=levelup.guide and #(levelup.guide.steps or {}) or 0,
            pooledRows=levelup.table and #levelup.table.rows or 0}
    end,
    layout={kind="table-drawer",toolbar="guide-tabs",tableWidth=766,drawerWidth=272,
        columns={"range","craft","count","unit","cost","state","view"},drawer="leveling"}})
