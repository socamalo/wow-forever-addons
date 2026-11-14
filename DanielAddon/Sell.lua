-- 自动卖垃圾
-- 卖法跟这台客户端上的 Baganator 一致：
--   ClearCursor() -> C_Container.PickupContainerItem(bag, slot) -> SellCursorItem()
-- 每轮最多 6 件，等服务器确认后再来下一轮，避免连点被卡。
local addonName, ns = ...

local SELL_PER_PASS = 6
local PASS_INTERVAL = 0.5
local MAX_PASSES = 40

local frame = CreateFrame("Frame")

local sellTimer
local passCount = 0
local soldTotal = 0
local moneyStart = 0
local lastJunkLeft = nil
local stuckPasses = 0
local merchantOpen = false

local function StopTimer()
    if sellTimer then
        sellTimer:Cancel()
        sellTimer = nil
    end
end

local upgradeSet

local function RefreshUpgradeSet()
    upgradeSet = {}
    if not ns.GetUpgrades then return end
    local ok, ups = pcall(ns.GetUpgrades)
    if ok and type(ups) == "table" then
        for _, u in ipairs(ups) do upgradeSet[u.itemID] = true end
    end
end

-- 专业工具/剥皮小刀/矿工锄/鱼竿等：名字或子类型命中就不卖
local TOOL_KEYWORDS = {
    "剥皮小刀", "矿工锄", "铁匠锤", "扳手", "鱼竿", "附魔棒", "专业工具",
    "skinning knife", "mining pick", "blacksmith hammer", "arclight spanner",
    "fishing pole", "enchanting rod", "profession tool", "rod", "棒",
}

local TOOL_ITEM_IDS = {
    [7005] = true,   -- 剥皮小刀 / Skinning Knife
    [2901] = true,   -- 矿工锄 / Mining Pick
    [5956] = true,   -- 铁匠锤 / Blacksmith Hammer
    [6219] = true,   -- 扳手 / Arclight Spanner
    [6256] = true,   -- 鱼竿 / Fishing Pole
}

function ns.IsProfessionTool(itemID, name, subClass)
    if TOOL_ITEM_IDS[itemID] then return true end
    local sub = tostring(subClass or ""):lower()
    if sub:find("miscellaneous", 1, true) or sub:find("misc", 1, true)
        or sub:find("tool", 1, true) or sub:find("profession", 1, true)
        or sub:find("杂项", 1, true) or sub:find("工具", 1, true)
        or sub:find("专业", 1, true) then
        return true
    end
    local n = tostring(name or ""):lower()
    for _, kw in ipairs(TOOL_KEYWORDS) do
        if n:find(kw, 1, true) then return true end
    end
    return false
end

local function HasEmptyTargetSlot(bag, slot, itemID)
    if not (ns.PossibleSlotsForItem and type(GetInventoryItemID) == "function") then
        return false
    end
    local ok, slots = pcall(ns.PossibleSlotsForItem, itemID)
    if not ok or type(slots) ~= "table" then return false end
    for _, slotID in ipairs(slots) do
        local equipped = GetInventoryItemID("player", slotID)
        if not equipped or equipped == 0 then return true end
    end
    return false
end

-- 红装：当前角色用不了的装备（等级/职业/护甲类型/武器熟练度）。
-- 先检查装备：戒指/饰品/项链永不自售；有空槽、可升级、专业工具、远程武器都保留。
local function IsUnusableEquipment(bag, slot, itemID, info)
    if not (ns.db and ns.db.sellUnusable ~= false) then return false end
    -- 绿色及以上品质一律不自动出售（红字也不卖），只卖白字/灰字
    if (info and (info.quality or 0) >= 2) then return false end
    local name, _, _, _, reqLevel, _, subClass, _, equipLoc, _, _, classID = C_Item.GetItemInfo(itemID)
    if not equipLoc or equipLoc == "" then return false end
    if classID ~= 2 and classID ~= 4 then return false end

    -- 先检查装备：戒指/饰品/项链一律不自动卖
    if equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_TRINKET" or equipLoc == "INVTYPE_NECK" then
        return false
    end
    if ns.IsProfessionTool(itemID, name, subClass) then return false end
    if upgradeSet and upgradeSet[itemID] then return false end

    -- 任务物品不卖
    local qi = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
    if qi and qi.isQuestItem then return false end

    -- 护甲：对应槽位还空着就留着（比如没戴戒指时不要卖掉戒指）
    if classID == 4 and HasEmptyTargetSlot(bag, slot, itemID) then return false end

    -- 远程武器一律保留，哪怕红字
    if equipLoc:find("RANGED") or equipLoc == "INVTYPE_THROWN" or equipLoc == "INVTYPE_RELIC" then
        return false
    end

    local playerLevel = UnitLevel and UnitLevel("player") or 0
    if reqLevel and reqLevel > playerLevel then return true end
    if C_Item.IsUsableItem then
        local ok, usable = pcall(C_Item.IsUsableItem, itemID)
        if ok and usable == false then return true end
    end
    if C_Item.IsEquippableItem then
        local ok, equippable = pcall(C_Item.IsEquippableItem, itemID)
        if ok and equippable == false then return true end
    end
    return false
end

local function IsKeywordJunk(info)
    -- 关键词只对白字/灰字生效，绿色及以上永远不自动卖
    if (info.quality or 0) >= 2 then return false end
    local list = ns.db and ns.db.junkKeywords
    if not list or #list == 0 then return false end
    local name = info.itemName
    if not name and C_Item and C_Item.GetItemInfo then
        local ok, n = pcall(C_Item.GetItemInfo, info.itemID)
        if ok then name = n end
    end
    if type(name) ~= "string" or name == "" then return false end
    local lower = name:lower()
    for _, kw in ipairs(list) do
        if type(kw) == "string" and kw ~= "" and lower:find(kw:lower(), 1, true) then
            return true
        end
    end
    return false
end

local function IsJunkAt(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then return false end
    if info.isLocked then return false end
    if info.hasNoValue then return false end
    if ns.db and ns.db.blacklist and ns.db.blacklist[info.itemID] then return false end
    -- 任务物品无论如何不卖（包括关键词命中）
    local qi = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
    if qi and qi.isQuestItem then return false end
    if IsKeywordJunk(info) then return true end
    if info.quality == 0 then return true end
    return IsUnusableEquipment(bag, slot, info.itemID, info)
end

ns.IsSellableJunk = IsJunkAt

local function CountJunk()
    local count = 0
    for _, bag in ipairs(ns.GetBagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        for slot = 1, n do
            if IsJunkAt(bag, slot) then
                count = count + 1
            end
        end
    end
    return count
end

local function CollectJunk(limit)
    local found = {}
    for _, bag in ipairs(ns.GetBagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        for slot = 1, n do
            if IsJunkAt(bag, slot) then
                found[#found + 1] = { bag = bag, slot = slot }
                if #found >= limit then
                    return found
                end
            end
        end
    end
    return found
end

local function Finish()
    StopTimer()
    local profit = GetMoney() - moneyStart
    local sold = soldTotal
    soldTotal = 0
    passCount = 0
    lastJunkLeft = nil
    stuckPasses = 0
    ns.OnSellFinished(sold, profit)
end

local function SellPass()
    sellTimer = nil
    if not merchantOpen then return end

    -- 玩家手上还拿着东西（比如正在拖一件装备），等放下再卖
    if ns.CursorBusy() then
        sellTimer = C_Timer.NewTimer(PASS_INTERVAL, SellPass)
        return
    end

    passCount = passCount + 1
    if passCount > MAX_PASSES then
        ns.Print("这轮卖得有点久，先停下来。")
        Finish()
        return
    end

    local items = CollectJunk(SELL_PER_PASS)
    if #items == 0 then
        Finish()
        return
    end

    -- 商人拒收时物品会一直留着，连查两轮没减少就别死循环
    local left = CountJunk()
    if left >= (lastJunkLeft or (left + 1)) then
        stuckPasses = stuckPasses + 1
        if stuckPasses >= 4 then
            ns.Print("有 " .. left .. " 件垃圾/红装商人不要，先跳过。")
            Finish()
            return
        end
    else
        stuckPasses = 0
    end
    lastJunkLeft = left

    for _, it in ipairs(items) do
        local info = C_Container.GetContainerItemInfo(it.bag, it.slot)
        if info and ns.Log then
            ns.Log("sell.item", {
                itemID = info.itemID, quality = info.quality,
                link = info.hyperlink, red = info.quality ~= 0,
            })
        end
        ClearCursor()
        C_Container.PickupContainerItem(it.bag, it.slot)
        SellCursorItem()
        soldTotal = soldTotal + 1
    end
    ClearCursor()

    sellTimer = C_Timer.NewTimer(PASS_INTERVAL, SellPass)
end

function ns.SellJunkNow()
    if InCombatLockdown() then
        ns.Print("战斗中不卖东西，脱战后再来。")
        return
    end
    if not merchantOpen then
        ns.Print("要站在商人面前才能卖垃圾。")
        return
    end
    StopTimer()
    passCount = 0
    soldTotal = 0
    stuckPasses = 0
    lastJunkLeft = nil
    moneyStart = GetMoney()
    RefreshUpgradeSet()
    SellPass()
end

function ns.IsMerchantOpen()
    return merchantOpen
end

function frame:MERCHANT_SHOW()
    merchantOpen = true
    if ns.db and ns.db.autoSell then
        RefreshUpgradeSet()
        moneyStart = GetMoney()
        soldTotal = 0
        passCount = 0
        stuckPasses = 0
        lastJunkLeft = nil
        C_Timer.After(0.3, function()
            if merchantOpen then
                SellPass()
            end
        end)
    end
end

function frame:MERCHANT_CLOSED()
    merchantOpen = false
    StopTimer()
    if soldTotal > 0 then
        local profit = GetMoney() - moneyStart
        local sold = soldTotal
        soldTotal = 0
        ns.Print("卖出 " .. sold .. " 件垃圾/红装，收入 " .. ns.Money(profit) .. "。")
        -- MERCHANT_CLOSED 是硬件事件上下文，在这里补一次整理更稳
        if ns.db and ns.db.autoSort ~= false and ns.SortByValue then
            ns.SortByValue(true)
        end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
