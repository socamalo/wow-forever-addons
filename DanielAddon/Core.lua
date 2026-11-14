-- DanielAddon 核心：配置、背包遍历、物品定价
local addonName, ns = ...

local PREFIX = "|cffffd100[Daniel]|r "

ns.PREFIX = PREFIX

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

function ns.Money(copper)
    copper = math.floor(tonumber(copper) or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "金" end
    if s > 0 then parts[#parts + 1] = s .. "银" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "铜" end
    return table.concat(parts, " ")
end

-- 0 = 背包，1..N = 装备的包。不用裸数字写死 4
function ns.GetBagIDs()
    local ids = { 0 }
    local count = NUM_BAG_SLOTS
    if not count and Constants and Constants.InventoryConstants then
        count = Constants.InventoryConstants.NumBagSlots
    end
    count = tonumber(count) or 4
    for i = 1, count do
        ids[#ids + 1] = i
    end
    return ids
end

-- 记录哪些 itemID 已经请求过数据，避免每格重复请求
local requested = {}

-- 返回物品单价（铜）。nil = 数据还没加载好，要先请求
function ns.ItemUnitValue(itemID)
    if not itemID or itemID == 0 then return 0 end
    local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(itemID)
    if sellPrice == nil then
        if not requested[itemID] then
            requested[itemID] = true
            if C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(itemID)
            end
        end
        return nil
    end
    return sellPrice
end

function ns.SlotValue(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then return 0 end
    local unit = ns.ItemUnitValue(info.itemID)
    if unit == nil then return 0 end
    return unit * (info.stackCount or 1)
end

function ns.BagTotalValue()
    local total = 0
    for _, bag in ipairs(ns.GetBagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        for slot = 1, n do
            total = total + ns.SlotValue(bag, slot)
        end
    end
    return total
end

local DEFAULTS = {
    autoSell = true,
    sellUnusable = true,
    autoRepair = true,
    -- 自动把不同类别分到不同背包（默认开）
    autoBagRoles = true,
    -- 白字/绿字但用户明确要卖的低价值杂物（按名字包含匹配）
    junkKeywords = { "破烂的皮革", "Ruined Leather Scraps" },
    autoSort = true,
    sortOnOpen = true,
    -- 后台自动穿更好的装备。走 C_Item.EquipItemByName（不是受保护函数），
    -- 被客户端拦时连续两次失败会自动关闭。
    autoEquip = true,
    -- 背包里高亮升级装备（绿色光晕 + tooltip 提示）
    highlight = true,
    -- 自动换装跳过「装备后绑定」的物品，避免把值钱的 BoE 误绑定
    skipBoE = true,
    -- 小地图上的 agent 标记
    showMinimapMarkers = true,
    markers = {},
    markerNextID = 0,
    -- 结构化日志
    logEnabled = true,
    logChat = false,
    logs = {},
    -- 游戏状态导出（自我密语 -> Logs/WoWChatLog.txt）
    stateAuto = true,
    stateLog = true,
    stateInterval = 20,
    hideStateChat = true,
    lastState = nil,
}

local frame = CreateFrame("Frame")

function frame:ADDON_LOADED(name)
    if name ~= addonName then return end
    DanielAddonDB = DanielAddonDB or {}
    local db = DanielAddonDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    -- 存档迁移：旧版把 autoEquip 默认关掉、没有高亮。用户明确要自动换装，升级一次默认值。
    if (tonumber(db.schema) or 1) < 2 then
        db.autoEquip = true
        db.highlight = true
        db.skipBoE = true
        db.schema = 2
    end
    -- schema 3：标记系统 + 结构化日志
    if (tonumber(db.schema) or 1) < 3 then
        db.showMinimapMarkers = true
        db.markers = db.markers or {}
        db.markerNextID = db.markerNextID or 0
        db.logEnabled = true
        db.logs = db.logs or {}
        db.schema = 3
    end
    -- schema 4：游戏状态导出（MCP 读取）
    if (tonumber(db.schema) or 1) < 4 then
        db.stateAuto = true
        db.stateLog = true
        db.stateInterval = 20
        db.hideStateChat = true
        db.schema = 4
    end
    if (tonumber(db.schema) or 1) < 5 then
        db.sortOnOpen = true
        db.schema = 5
    end
    if (tonumber(db.schema) or 1) < 6 then
        db.schema = 6
    end
    if (tonumber(db.schema) or 1) < 7 then
        db.sellUnusable = true
        db.ammoAutoBuy = true
        db.ammoTarget = 1000
        db.schema = 7
    end
    -- 用户明确要求自动穿升级装备：重新打开一次自动换装
    if (tonumber(db.schema) or 1) < 8 then
        db.autoEquip = true
        db.schema = 8
    end

    if (tonumber(db.schema) or 1) < 9 then
        db.autoRepair = true
        db.schema = 9
    end
    if (tonumber(db.schema) or 1) < 10 then
        if db.ammoTarget == nil or db.ammoTarget == 1000 then
            db.ammoTarget = 2000
        end
        db.schema = 10
    end
    db.blacklist = db.blacklist or {}
    if ns.Log then ns.Log.SetChat(db.logChat) end
    ns.db = db
    if ns.State then
        ns.State.SetHideChat(db.hideStateChat ~= false)
        ns.State.EnsureLog(db.stateLog ~= false)
        ns.State.StartTicker()
        ns.State.Schedule("login")
    end
    if ns.Log then
        local v1, v2, _v3, v4 = GetBuildInfo()
        ns.Log("session.start", {
            version = v1, build = v2, toc = v4,
            projectID = WOW_PROJECT_ID, camelot = WOW_PROJECT_CAMELOT,
            markers = #db.markers, logs = #db.logs,
            autoEquip = db.autoEquip, highlight = db.highlight,
        })
    end
    self:UnregisterEvent("ADDON_LOADED")
end

function frame:ITEM_DATA_LOAD_RESULT(itemID)
    requested[itemID] = nil
end

frame:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")

-- 鼠标上是否正拿着东西。拿着时不能动背包，否则 ClearCursor 会把玩家的拖拽取消
function ns.CursorBusy()
    if type(CursorHasItem) ~= "function" then return false end
    local ok, has = pcall(CursorHasItem)
    if not ok then return false end
    return has and true or false
end

-- 卖垃圾结束后的收尾：报告 + 触发自动排序
function ns.OnSellFinished(soldCount, profit)
    if soldCount > 0 then
        ns.Print("卖出 " .. soldCount .. " 件垃圾/红装，收入 " .. ns.Money(profit) .. "。")
    end
    if ns.db and ns.db.autoSort ~= false and ns.SortByValue then
        -- 卖完立刻排一次；1.2 秒后再补一次，防止第一次碰上物品锁定/受保护上下文
        ns.__sortAfterSell = true
        if ns.Log then ns.Log("sort.after_sell", { sold = soldCount, profit = profit }) end
        C_Timer.After(0.2, function() if ns.SortByValue then ns.SortByValue(true) end end)
        C_Timer.After(1.2, function() if ns.SortByValue then ns.SortByValue(true) end end)
    end
    if ns.repairPending and ns.Repair and ns.Repair.Try then
        C_Timer.After(0.2, function()
            if ns.Repair then ns.Repair.Try(true) end
        end)
    end
    if ns.Ammo and ns.Ammo.Restock then
        C_Timer.After(0.8, function()
            if ns.Ammo then ns.Ammo.Restock() end
        end)
    end
end
