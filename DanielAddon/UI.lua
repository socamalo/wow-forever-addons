-- 面板、斜杠命令、小地图插件隔舱入口
local addonName, ns = ...

local panel
local refreshTimer
local checks = {}

local function UpdateValue()
    if not panel then return end
    if panel.valueText then
        local markerCount = ns.Markers and #ns.Markers.List() or 0
        panel.valueText:SetText("背包总值：" .. ns.Money(ns.BagTotalValue())
            .. " ｜ 标记：" .. markerCount)
    end
    if panel.equipBtn and ns.GetUpgrades then
        panel.equipBtn:SetText("换上更好的（" .. #ns.GetUpgrades() .. "）")
    end
end

function ns.RefreshPanel()
    if not panel or not panel:IsShown() then return end
    if refreshTimer then
        refreshTimer:Cancel()
        refreshTimer = nil
    end
    refreshTimer = C_Timer.NewTimer(0.25, function()
        refreshTimer = nil
        if panel and panel:IsShown() then
            UpdateValue()
        end
    end)
end

local function MakeCheck(parent, name, label, x, y, getValue, setValue)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local text = _G[name .. "Text"]
    if text then
        text:SetText(label)
    end
    cb.getValue = getValue
    cb:SetChecked(getValue())
    cb:SetScript("OnClick", function(self)
        setValue(self:GetChecked() and true or false)
        ns.RefreshPanel()
    end)
    checks[#checks + 1] = cb
    return cb
end

local function MakeButton(parent, label, x, y, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 120, 24)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    btn:SetText(label)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function CreatePanel()
    local f = CreateFrame("Frame", "DanielAddonPanel", UIParent, "BackdropTemplate")
    f:SetSize(284, 500)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("Daniel 背包管家")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 4)
    close:SetScript("OnClick", function() f:Hide() end)

    f.valueText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.valueText:SetPoint("TOP", f, "TOP", 0, -44)
    f.valueText:SetText("背包总值：计算中…")

    MakeButton(f, "卖掉垃圾", 16, -72, 120, function()
        ns.SellJunkNow()
    end)
    MakeButton(f, "按类别整理", 148, -72, 120, function()
        ns.SortByValue(false)
    end)

    f.equipBtn = MakeButton(f, "换上更好的（0）", 16, -104, 252, function()
        ns.EquipUpgrades(false)
    end)

    MakeCheck(f, "DanielAddonCheckSell", "自动卖垃圾（打开商人时）", 16, -140,
        function() return ns.db and ns.db.autoSell end,
        function(v) if ns.db then ns.db.autoSell = v end end)

    MakeCheck(f, "DanielAddonCheckSort", "卖完后按类别整理背包", 16, -168,
        function() return ns.db and ns.db.autoSort end,
        function(v) if ns.db then ns.db.autoSort = v end end)

    MakeCheck(f, "DanielAddonCheckEquip", "自动穿更好的装备（出战斗后）", 16, -196,
        function() return ns.db and ns.db.autoEquip end,
        function(v) if ns.db then ns.db.autoEquip = v end end)

    MakeCheck(f, "DanielAddonCheckHighlight", "背包里高亮升级装备", 16, -224,
        function() return ns.db and ns.db.highlight end,
        function(v) if ns.SetHighlight then ns.SetHighlight(v) end end)

    MakeCheck(f, "DanielAddonCheckBoE", "自动换装跳过蓝/紫绑定装备", 16, -252,
        function() return ns.db and ns.db.skipBoE end,
        function(v) if ns.db then ns.db.skipBoE = v end end)

    MakeCheck(f, "DanielAddonCheckMiniMap", "显示小地图标记", 16, -280,
        function() return ns.db and ns.db.showMinimapMarkers end,
        function(v)
            if ns.db then ns.db.showMinimapMarkers = v end
            if ns.MarkersUI then ns.MarkersUI.Refresh() end
        end)

    MakeCheck(f, "DanielAddonCheckSortOpen", "每次打开背包自动整理", 16, -308,
        function() return ns.db and ns.db.sortOnOpen end,
        function(v) if ns.db then ns.db.sortOnOpen = v end end)

    MakeCheck(f, "DanielAddonCheckSellRed", "自动卖红装（远程武器除外）", 16, -336,
        function() return ns.db and ns.db.sellUnusable end,
        function(v) if ns.db then ns.db.sellUnusable = v end end)

    MakeCheck(f, "DanielAddonCheckRepair", "自动维修（能修的商人）", 16, -364,
        function() return ns.db and ns.db.autoRepair end,
        function(v) if ns.db then ns.db.autoRepair = v end end)

    MakeCheck(f, "DanielAddonCheckAmmo", "自动补弹药（猎人）", 16, -420,
        function() return ns.db and ns.db.ammoAutoBuy end,
        function(v) if ns.db then ns.db.ammoAutoBuy = v end end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    hint:SetText("/daniel · mark · sell · sort · ammo · log · diag")

    f:SetScript("OnShow", function()
        for _, cb in ipairs(checks) do
            cb:SetChecked(cb.getValue())
        end
        UpdateValue()
    end)

    return f
end

function ns.TogglePanel()
    if not panel then
        panel = CreatePanel()
    end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        ns.RefreshPanel()
    end
end

-- TOC 里 AddonCompartmentFunc 指向这个全局函数，名字必须逐字一致
function DanielAddon_CompartmentClick()
    ns.TogglePanel()
    return true
end

local function MarkHelp()
    ns.Print("标记：/daniel mark 铁炉堡|55.2|47.8|武器大师（也支持空格分隔）；"
        .. "mark list / mark clear / mark remove <id> / mark goto <id>；"
        .. "批量：/daniel markbatch 铁炉堡|55.2|47.8|武器大师;铁炉堡|56|48|训练师")
end

local function MarkerListText()
    local list = ns.Markers.List()
    if #list == 0 then
        ns.Print("没有地图标记。" .. "用法：" .. "/daniel mark 铁炉堡|55.2|47.8|武器大师")
        return
    end
    for i, m in ipairs(list) do
        ns.Print(string.format("%d. #%d %s (%.1f, %.1f) %s", i, m.id,
            m.zoneName or "?", (m.x or 0) * 100, (m.y or 0) * 100, m.label or ""))
    end
    ns.Print("共 " .. #list .. " 个标记；点击地图/小地图上的点可设为暴雪路径点。")
end

local function HandleMark(raw)
    local arg = ns.MarkerParse.Trim(raw:sub(6))
    local lower = arg:lower()

    if arg == "" then
        MarkHelp()
    elseif lower == "list" then
        MarkerListText()
    elseif lower == "clear" then
        local n = ns.Markers.Clear()
        ns.Print("已清除 " .. n .. " 个地图标记。")
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        ns.RefreshPanel()
    elseif lower:find("^remove ") then
        local id = tonumber(arg:match("(%d+)"))
        local m = id and ns.Markers.Remove(id)
        if m then
            ns.Print("已删除标记 #" .. m.id .. " " .. (m.label or m.zoneName or ""))
            if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
            ns.RefreshPanel()
        else
            ns.Print("找不到标记 " .. tostring(id))
        end
    elseif lower:find("^goto ") then
        local id = tonumber(arg:match("(%d+)"))
        local m = id and ns.Markers.Find(id)
        if m and ns.MarkerCore.SetWaypoint(m) then
            ns.Print("已设为路径点：" .. (m.label or m.zoneName or ""))
        else
            ns.Print("设置路径点失败。")
        end
    else
        local parsed, err = ns.MarkerParse.ParseOne(arg)
        if not parsed then
            ns.Print("标记解析失败：" .. tostring(err))
            MarkHelp()
            return
        end
        local m, addErr, dup = ns.Markers.Add(parsed.zone, parsed.x, parsed.y, parsed.label)
        if not m then
            ns.Print("标记失败：" .. tostring(addErr))
            return
        end
        ns.Print((dup and "标记已存在 #" or "已添加标记 #") .. m.id .. " "
            .. (m.zoneName or "?") .. string.format(" (%.1f, %.1f) ", m.x * 100, m.y * 100)
            .. (m.label or ""))
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        ns.RefreshPanel()
    end
end

local function HandleCommand(msg)
    local raw = tostring(msg or "")
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    local msg = raw:lower()

    if ns.Log then
        ns.Log("cmd", { cmd = raw })
    end

    if msg == "" or msg == "toggle" then
        ns.TogglePanel()
    elseif msg == "sell" then
        ns.SellJunkNow()
    elseif msg == "sort" then
        ns.SortByValue(false)
    elseif msg == "ammo" then
        ns.Ammo.PrintStatus()
    elseif msg:find("^ammo ") then
        local arg = ns.MarkerParse.Trim(raw:sub(6)):lower()
        if arg == "auto on" then
            ns.db.ammoAutoBuy = true
            ns.Print("自动补弹药：开")
        elseif arg == "auto off" then
            ns.db.ammoAutoBuy = false
            ns.Print("自动补弹药：关")
        elseif arg:find("^target ") then
            local n = tonumber(arg:match("(%d+)"))
            if n and n > 0 then
                ns.db.ammoTarget = n
                ns.Print("弹药目标数量：" .. n)
            end
        elseif arg:find("^item ") then
            local id = tonumber(raw:match("item:(%d+)") or raw:match("(%d+)"))
            if id and ns.Ammo.KindOf(id) then
                ns.db.ammoItemID = id
                ns.Print("固定弹药：" .. id .. " " .. ns.Ammo.Name(id))
            else
                ns.Print("不是有效的弹药 itemID。")
            end
        elseif arg == "buy" or arg:find("^buy ") then
            local n = tonumber(arg:match("(%d+)")) or 1
            ns.merchantAmmoDone = nil
            ns.Ammo.Restock(n)
        else
            ns.Print("用法：/daniel ammo · ammo auto on|off · ammo target <数量> · ammo item <ID> · ammo buy")
        end
    elseif msg == "pet" or msg:find("^pet ") then
        local arg = ns.MarkerParse.Trim(raw:sub(4)):lower()
        local presets = {
            bjarn = { map = 1426, x = 69.8, y = 56.8, label = "Bjarn Lv12 Rare-Elite" },
            mangeclaw = { map = 1426, x = 87.4, y = 49.6, label = "Mangeclaw Lv11 Rare" },
        }
        local wanted = {}
        if arg == "" or arg == "all" then
            wanted = { presets.bjarn, presets.mangeclaw }
        elseif presets[arg] then
            wanted = { presets[arg] }
        else
            ns.Print("宠物预设：/daniel pet · pet bjarn · pet mangeclaw")
            return
        end
        local added = 0
        for _, p in ipairs(wanted) do
            local m = ns.Markers.Add(p.map, p.x / 100, p.y / 100, p.label)
            if m then added = added + 1 end
        end
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        ns.Print("已添加 " .. added .. " 个稀有宠物标记。打开地图看青色点。")
        ns.RefreshPanel()
    elseif msg == "boe" then
        if ns.db then
            ns.db.skipBoE = not ns.db.skipBoE
            ns.Print("自动换装跳过蓝/紫绑定装备：" .. (ns.db.skipBoE and "开" or "关"))
            ns.RefreshPanel()
        end
    elseif msg == "junk" or msg:find("^junk ") then
        ns.db.junkKeywords = ns.db.junkKeywords or {}
        local kw = ns.MarkerParse.Trim(raw:sub(5))
        if kw == "" then
            ns.Print("自动卖关键词：" .. table.concat(ns.db.junkKeywords or {}, "、"))
        else
            for _, x in ipairs(ns.db.junkKeywords or {}) do
                if x:lower() == kw:lower() then
                    ns.Print("关键词已存在：" .. kw); return
                end
            end
            table.insert(ns.db.junkKeywords, kw)
            ns.Print("已加入自动卖关键词：" .. kw)
        end
    elseif msg:find("^unjunk ") then
        local kw = ns.MarkerParse.Trim(raw:sub(8)):lower()
        local list = ns.db.junkKeywords or {}
        ns.db.junkKeywords = list
        for i = #list, 1, -1 do
            if list[i]:lower() == kw then table.remove(list, i) end
        end
        ns.Print("已移除自动卖关键词：" .. kw)
    elseif msg == "repair" then
        if ns.db then
            ns.db.autoRepair = not ns.db.autoRepair
            ns.Print("自动维修：" .. (ns.db.autoRepair and "开" or "关"))
            ns.RefreshPanel()
        end
    elseif msg == "redsell" then
        if ns.db then
            ns.db.sellUnusable = not ns.db.sellUnusable
            ns.Print("自动卖红装（远程武器除外）：" .. (ns.db.sellUnusable and "开" or "关"))
            ns.RefreshPanel()
        end
    elseif msg == "bagrole" then
        ns.Print("分类分装：" .. (ns.db and ns.db.autoBagRoles and "开" or "关")
            .. "（5包：0炉石/任务/消耗品，1-2装备，3材料，4杂项/垃圾）")
    elseif msg == "bagrole on" then
        if ns.db then ns.db.autoBagRoles = true end
        ns.Print("分类分装：开")
    elseif msg == "bagrole off" then
        if ns.db then ns.db.autoBagRoles = false end
        ns.Print("分类分装：关")
    elseif msg == "sortdebug" then
        ns.SortDebug()
    elseif msg == "sortopen" then
        if ns.db then
            ns.db.sortOnOpen = not ns.db.sortOnOpen
            ns.Print("每次打开背包自动整理：" .. (ns.db.sortOnOpen and "开" or "关"))
            ns.RefreshPanel()
        end
    elseif msg == "value" then
        ns.Print("背包总值：" .. ns.Money(ns.BagTotalValue()))
    elseif msg == "equip" then
        ns.EquipUpgrades(false)
    elseif msg:find("^equipitem ") then
        local id = tonumber(raw:match("item:(%d+)") or raw:match("(%d+)"))
        local ok, err = ns.ForceEquipItem(id)
        if ok then
            ns.Print("已强制换上物品 " .. tostring(id) .. "。")
            C_Timer.After(0.6, function()
                if ns.ScheduleHighlight then ns.ScheduleHighlight(0.1) end
                ns.RefreshPanel()
            end)
        else
            ns.Print("强制换装失败：" .. tostring(err))
        end
    elseif msg == "upgrade" or msg == "upgrades" then
        ns.ListUpgrades()
    elseif msg:find("^why ") then
        local id = raw:match("item:(%d+)") or raw:match("(%d+)")
        ns.Explain(id and tonumber(id))
    elseif msg:find("^mark ") then
        HandleMark(raw)
    elseif msg == "mark" then
        MarkHelp()
    elseif msg:find("^markbatch ") then
        local parsed, err = ns.MarkerParse.ParseBatch(raw:sub(11))
        if not parsed then
            ns.Print("批量标记解析失败：" .. tostring(err))
            return
        end
        local added, dup = 0, 0
        for _, p in ipairs(parsed) do
            local m, addErr, isDup = ns.Markers.Add(p.zone, p.x, p.y, p.label)
            if m then
                if isDup then dup = dup + 1 else added = added + 1 end
            else
                ns.Print("跳过一项：" .. tostring(addErr))
            end
        end
        ns.Print("批量标记完成：新增 " .. added .. "，重复 " .. dup .. "。")
        if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
        ns.RefreshPanel()
    elseif msg:find("^mapfind ") then
        local q = ns.MarkerParse.Trim(raw:sub(9)):lower()
        local index = ns.MarkerCore.BuildMapIndex()
        local shown = 0
        for name, list in pairs(index) do
            if name:find(q, 1, true) then
                for _, info in ipairs(list) do
                    local id = info.mapID or info.uiMapID
                    ns.Print(string.format("%s  mapID=%d", info.name, id))
                    shown = shown + 1
                    if shown >= 15 then break end
                end
                if shown >= 15 then break end
            end
        end
        if shown == 0 then ns.Print("没有匹配的地图名。") end
    elseif msg == "state" then
        if ns.State then
            ns.State.SendNow("cmd")
            ns.State.PrintSummary()
        end
    elseif msg:find("^state ") then
        local arg = ns.MarkerParse.Trim(raw:sub(7)):lower()
        if not ns.State then return end
        if arg == "auto on" then
            ns.db.stateAuto = true
            ns.State.StartTicker()
            ns.State.SendNow("cmd")
            ns.Print("状态自动导出：开")
        elseif arg == "auto off" then
            ns.db.stateAuto = false
            ns.State.StartTicker()
            ns.Print("状态自动导出：关")
        elseif arg == "chat on" then
            ns.State.SetHideChat(true)
            ns.Print("DANIEL1 密语已在聊天框隐藏（仍写入 /chatlog）。")
        elseif arg == "chat off" then
            ns.State.SetHideChat(false)
            ns.Print("DANIEL1 密语现在会显示在聊天框。")
        elseif arg == "log on" then
            ns.db.stateLog = true
            ns.State.EnsureLog(true)
            ns.Print("聊天日志：开（Logs/WoWChatLog.txt）")
        elseif arg == "log off" then
            ns.db.stateLog = false
            ns.State.EnsureLog(false)
            ns.Print("聊天日志：关")
        elseif arg:find("^interval ") then
            local n = tonumber(arg:match("(%d+)"))
            if n and n >= 2 then
                ns.db.stateInterval = n
                ns.State.StartTicker()
                ns.Print("状态导出间隔：" .. n .. " 秒")
            end
        else
            ns.Print("用法：/daniel state · state auto on|off · state log on|off · state probe · state channel · state chat on|off · state names · state name <完整角色名> · state reset · state interval <秒>")
        end
    elseif msg == "quests" then
        if ns.State then ns.State.PrintSummary() end
    elseif msg:find("^questmark") then
        local arg = ns.MarkerParse.Trim(raw:sub(10)):lower()
        local id = tonumber(arg:match("(%d+)"))
        local added = ns.State and ns.State.MarkQuestNext(id) or 0
        ns.Print("已为任务下一步添加 " .. added .. " 个标记。")
        if ns.RefreshPanel then ns.RefreshPanel() end
    elseif msg == "diag" then
        ns.Log.Diag()
    elseif msg:find("^log") then
        local arg = ns.MarkerParse.Trim(raw:sub(4)):lower()
        if arg == "on" then
            ns.Log.SetEnabled(true); ns.Print("日志：开")
        elseif arg == "off" then
            ns.Log.SetEnabled(false); ns.Print("日志：关")
        elseif arg == "chat on" then
            ns.Log.SetChat(true); ns.Print("日志聊天输出：开")
        elseif arg == "chat off" then
            ns.Log.SetChat(false); ns.Print("日志聊天输出：关")
        elseif arg == "clear" then
            ns.Log.Clear(); ns.Print("日志已清空。")
        elseif arg == "dump" or arg == "" then
            ns.Log.Dump(10)
        elseif arg:find("^dump ") then
            ns.Log.Dump(tonumber(arg:match("(%d+)")) or 10)
        else
            ns.Print("日志：/daniel log on|off · chat on|off · dump [N] · clear")
        end
    elseif msg == "highlight" then
        if ns.db then
            ns.SetHighlight(not ns.db.highlight)
            ns.Print("背包升级高亮：" .. (ns.db.highlight and "开" or "关"))
            ns.RefreshPanel()
        end
    elseif msg:find("^ignore ") then
        local id = tonumber(raw:match("item:(%d+)") or raw:match("(%d+)"))
        if id and ns.db then
            ns.db.blacklist[id] = true
            ns.Print("已忽略物品 " .. id .. "，不再参与升级识别与自动换装。")
            if ns.ScheduleHighlight then ns.ScheduleHighlight(0.1) end
            ns.RefreshPanel()
        end
    elseif msg:find("^unignore ") then
        local id = tonumber(raw:match("item:(%d+)") or raw:match("(%d+)"))
        if id and ns.db then
            ns.db.blacklist[id] = nil
            ns.Print("已恢复物品 " .. id .. "。")
            if ns.ScheduleHighlight then ns.ScheduleHighlight(0.1) end
            ns.RefreshPanel()
        end
    elseif msg == "status" then
        ns.Print("自动卖垃圾：" .. (ns.db and ns.db.autoSell and "开" or "关")
            .. "；卖完自动整理：" .. (ns.db and ns.db.autoSort and "开" or "关")
            .. "；卖红装：" .. (ns.db and ns.db.sellUnusable and "开" or "关")
            .. "；自动维修：" .. (ns.db and ns.db.autoRepair and "开" or "关")
            .. "；补弹药：" .. (ns.db and ns.db.ammoAutoBuy and "开" or "关")
            .. "(" .. tostring(ns.db and ns.db.ammoTarget or 1000) .. ")"
            .. "；开包自动整理：" .. (ns.db and ns.db.sortOnOpen and "开" or "关")
            .. "；分类分装：" .. (ns.db and ns.db.autoBagRoles and "开" or "关")
            .. "；自动换装：" .. (ns.db and ns.db.autoEquip and "开" or "关")
            .. "；升级高亮：" .. (ns.db and ns.db.highlight and "开" or "关")
            .. "；自动跳过 BoE：" .. (ns.db and ns.db.skipBoE and "开" or "关")
            .. "；小地图标记：" .. (ns.db and ns.db.showMinimapMarkers and "开" or "关")
            .. "；标记数：" .. (ns.Markers and #ns.Markers.List() or 0)
            .. "；日志：" .. (ns.db and ns.db.logEnabled and "开" or "关")
            .. "(" .. ns.Log.Count() .. " 条)"
            .. "；状态导出：" .. (ns.db and ns.db.stateAuto and "开" or "关")
            .. "；换装接口：" .. (C_Item and C_Item.EquipItemByName and "EquipItemByName" or "缺失"))
    else
        ns.Print("命令：/daniel 面板 · sell · redsell · repair · ammo · sort · sortdebug · bagrole · sortopen · upgrade · equip · equipitem <ID> · mark <zone>|<x>|<y>|<label> · "
            .. "mark list/clear/remove/goto · pet · mapfind <name> · diag · log · value · status")
    end
end

SLASH_DANIELADDON1 = "/daniel"
SLASH_DANIELADDON2 = "/ds"
SlashCmdList["DANIELADDON"] = HandleCommand

-- 无空格快捷命令：手柄/ConsolePort 下空格容易触发别的动作
SLASH_DANIELEQUIP1 = "/equipup"
SlashCmdList["DANIELEQUIP"] = function()
    HandleCommand("equip")
end
local function RemovePetPreset(key)
    local coords = {
        bjarn = { 1426, 0.698, 0.568 },
        mangeclaw = { 1426, 0.874, 0.496 },
    }
    local c = coords[key]
    if not c then return end
    local removed = 0
    for _, m in ipairs(ns.Markers.List()) do
        if m.uiMapID == c[1] and math.abs(m.x - c[2]) < 0.0005 and math.abs(m.y - c[3]) < 0.0005 then
            ns.Markers.Remove(m.id)
            removed = removed + 1
        end
    end
    if ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
    ns.Print(removed > 0 and ("已删除 " .. removed .. " 个宠物标记。") or "没有找到对应宠物标记。")
    ns.RefreshPanel()
end

SLASH_DANIELRMBEAR1 = "/rmbear"
SlashCmdList["DANIELRMBEAR"] = function() RemovePetPreset("bjarn") end
SLASH_DANIELRMMANG1 = "/rmmang"
SlashCmdList["DANIELRMMANG"] = function() RemovePetPreset("mangeclaw") end
SLASH_DANIELMARKCLEAR1 = "/markclear"
SlashCmdList["DANIELMARKCLEAR"] = function() HandleCommand("mark clear") end

SLASH_DANIELSORTDEBUG1 = "/sortdebug"
SlashCmdList["DANIELSORTDEBUG"] = function()
    HandleCommand("sortdebug")
end

SLASH_DANIELPET1 = "/danielpet"
SlashCmdList["DANIELPET"] = function(msg)
    local arg = tostring(msg or "")
    if arg == "" then
        HandleCommand("pet")
    else
        HandleCommand("pet " .. arg)
    end
end

local frame = CreateFrame("Frame")
local bagUpdateTimer

frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event)
    if not panel or not panel:IsShown() then return end
    if bagUpdateTimer then bagUpdateTimer:Cancel() end
    bagUpdateTimer = C_Timer.NewTimer(0.3, function()
        bagUpdateTimer = nil
        UpdateValue()
    end)
end)
