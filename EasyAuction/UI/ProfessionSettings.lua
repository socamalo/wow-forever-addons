local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, STANDARD_TEXT_FONT = CreateFrame, STANDARD_TEXT_FONT
local tostring, tonumber, ipairs, pairs, type, unpack = tostring, tonumber, ipairs, pairs, type, unpack
local min, max, ceil = math.min, math.max, math.ceil
local W, L = ns.Widgets, ns.L
local V={}; ns.ProfessionSettingsView=V
local groups={pricing=L["定价策略"],inventory=L["库存与上架"],filters=L["筛选条件"],advanced=L["高级配置"]}
local groupOrder={"pricing","inventory","filters","advanced"}
local VIEW_HEIGHT,CONTENT_WIDTH,CELL_WIDTH,ROW_HEIGHT=386,750,368,34

local function settings() return ns.ProfessionSettings end

function V.Create(parent)
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints(); page.controls={}
    local scroll=CreateFrame("ScrollFrame",nil,page); scroll:SetPoint("TOPLEFT",12,-12); scroll:SetSize(764,386)
    local content=CreateFrame("Frame",nil,scroll); content:SetSize(CONTENT_WIDTH,VIEW_HEIGHT); scroll:SetScrollChild(content)
    page.scroll=scroll; page.offset=0
    scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel",function(self,delta)
        page.offset=min(max(0,content:GetHeight()-VIEW_HEIGHT),max(0,page.offset-delta*ROW_HEIGHT*2))
        self:SetVerticalScroll(page.offset)
    end)
    page.message=W.Text(page,"",16,-414,11,W.color.muted,744)
    local grouped={}
    local available=settings() and settings().Definitions or {}
    for definitionIndex=1,#available do
        local definition=available[definitionIndex]
        grouped[definition.group]=grouped[definition.group] or {}
        grouped[definition.group][#grouped[definition.group]+1]=definition
    end
    local y=-4
    for groupIndex=1,#groupOrder do
        local groupKey=groupOrder[groupIndex]
        local definitions=grouped[groupKey] or {}
        W.Text(content,L[groups[groupKey] or groupKey],8,y,11,W.color.gold,CONTENT_WIDTH-16)
        local divider=content:CreateTexture(nil,"ARTWORK")
        divider:SetColorTexture(unpack(W.color.line)); divider:SetPoint("TOPLEFT",8,y-17)
        divider:SetSize(CONTENT_WIDTH-16,1)
        y=y-24
        for index,definition in ipairs(definitions) do
            local column=(index-1)%2
            local rowIndex=ceil(index/2)
            local row=CreateFrame("Frame",nil,content)
            row:SetPoint("TOPLEFT",column*(CELL_WIDTH+10),y-(rowIndex-1)*ROW_HEIGHT)
            row:SetSize(CELL_WIDTH,ROW_HEIGHT)
            local shade=row:CreateTexture(nil,"BACKGROUND"); shade:SetAllPoints()
            W.ThemeTexture(shade,"stripe",rowIndex%2==0 and 0.018 or 0.032)
            local labelArea=CreateFrame("Button",nil,row)
            labelArea:SetPoint("TOPLEFT"); labelArea:SetSize(218,ROW_HEIGHT)
            W.Text(labelArea,definition.label,8,-10,11,W.color.text,202)
            W.Hint(labelArea,definition.label,definition.help)
            local control
            local function commit(value)
                local ok,err=settings().Set(definition.key,value)
                page.message:SetText(ok and L["已保存"] or err and L[err] or L["设置无效"])
                if not ok or definition.type=="number" then page:RefreshControl(definition.key) end
            end
            if definition.type=="boolean" then
                control=W.Checkbox(row,L["开启"],226,-8,132,settings().Get(definition.key),function(value) commit(value) end)
            elseif definition.type=="select" then
                control=W.Dropdown(row,224,-6,136,definition.options or {},function(value) commit(value) end)
            else
                control=W.Edit(row,270,-6,90,"")
                control:SetSize(90,22); control:SetFont(STANDARD_TEXT_FONT,11,"")
                control:SetJustifyH("RIGHT")
                control:SetScript("OnEnterPressed",function(self) self:ClearFocus() end)
                control:HookScript("OnEditFocusLost",function(self) commit(tonumber(self:GetText())) end)
            end
            W.Hint(control,definition.label,definition.help)
            control.definition=definition; page.controls[definition.key]=control
        end
        y=y-ceil(#definitions/2)*ROW_HEIGHT-12
    end
    content:SetHeight(max(VIEW_HEIGHT,-y+4))
    function page:RefreshControl(key)
        local control=self.controls[key]; if not control then return end
        local value=settings().Get(key); local definition=control.definition
        if definition.type=="boolean" then control:SetChecked(value)
        elseif definition.type=="select" then control:SetValue(value)
        elseif not control:HasFocus() then control:SetText(tostring(value==nil and "" or value)) end
    end
    function page:Refresh()
        for key in pairs(self.controls) do self:RefreshControl(key) end
    end
    page:SetScript("OnShow",function() page:Refresh() end)
    page:Refresh(); page:Hide(); return page
end

function V.CreateData(parent)
    local page=CreateFrame("Frame",nil,parent); page:SetAllPoints()
    W.Text(page,L["专业数据管理"],20,-16,15,W.color.text)
    page.summary=W.Text(page,"",20,-45,11,W.color.muted,740)
    page.message=W.Text(page,"",20,-374,11,W.color.muted,740); page.message:SetWordWrap(true)
    local armed
    local function confirm(key,action)
        if armed==key then armed=nil; action(); page:Refresh()
        else armed=key; page.message:SetText(L["再次点击同一按钮确认；切换页面取消。"] ) end
    end
    local prune=W.Button(page,L["移除旧价格"],20,-72,148,function()
        local count=ns.Prices.Prune(); page.message:SetText(L["已移除旧价格"]..": "..tostring(count or 0)); page:Refresh()
    end)
    prune:SetSize(148,22)
    local clear=W.Button(page,L["清空当前行情"],178,-72,148,function() confirm("clear",function()
        local ok,err=ns.Prices.Clear(); page.message:SetText(ok==false and (err and L[err] or L["操作未完成"]) or L["已清空当前行情"])
    end) end)
    clear:SetSize(148,22)
    local reset=W.Button(page,L["恢复专业默认设置"],336,-72,174,function() confirm("reset",function()
        settings().Reset(); page.message:SetText(L["专业设置已恢复默认"])
    end) end)
    reset:SetSize(174,22)
    W.Text(page,L["专业分享码"],20,-116,12,W.color.gold)
    W.Text(page,L["包含专业设置、计划队列和逐物品库存上限。"],20,-140,10,W.color.muted,740)
    local scroll=CreateFrame("ScrollFrame",nil,page,"UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",20,-162); scroll:SetSize(724,156)
    local edit=W.Edit(scroll,0,0,698,""); edit:SetMultiLine(true); edit:SetMaxLetters(65536); edit:SetHeight(156)
    edit:SetFont(STANDARD_TEXT_FONT,11,""); edit:SetTextInsets(8,8,6,6)
    scroll:SetScrollChild(edit); page.transfer=edit
    local export=W.Button(page,L["导出专业数据"],20,-330,148,function()
        local text,err=settings().Export()
        if type(text)=="string" then
            edit:SetText(text); edit:SetFocus(); edit:HighlightText()
            page.message:SetText(L["专业数据已导出，可按 Ctrl+C 复制。"])
        else page.message:SetText(err and L[err] or L["操作未完成"]) end
    end)
    export:SetSize(148,22)
    local import=W.Button(page,L["导入专业数据"],178,-330,148,function() confirm("import",function()
        local ok,err=settings().Import(edit:GetText()); page.message:SetText(ok and L["专业数据已导入"] or err and L[err] or L["导入失败"])
    end) end)
    import:SetSize(148,22)
    edit:HookScript("OnTextChanged",function() armed=nil end)
    function page:Refresh()
        local count=0; for key in pairs(ns.Prices and ns.Prices.GetItems() or {}) do if key then count=count+1 end end
        local snapshot=ns.Professions and ns.Professions.Snapshot() or {}
        self.summary:SetText(L["行情记录"]..": "..count.."    "..L["配方"]..": "..tostring(snapshot.recipes or 0)
            .."    "..L["制作队列"]..": "..tostring(snapshot.queue or 0))
    end
    page:SetScript("OnHide",function() armed=nil; page.message:SetText(""); edit:ClearFocus() end)
    page:SetScript("OnShow",function() page:Refresh() end)
    page:Hide(); return page
end
