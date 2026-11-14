-- 猎人弹药补给：在商人处把当前使用的箭/子弹补到目标数量。
-- 说明：Classic 里背包/箭袋中的同类弹药都算“已装填”，所以这里做的是
--      在商人处买够，而不是把弹药搬到某个装备槽。
local addonName, ns = ...

ns.Ammo = {}
local Ammo = ns.Ammo

local function LogEvent(event, data)
    if ns.Log then ns.Log(event, data) end
end

local function ItemInfo(itemID)
    if not itemID then return nil end
    local name, link, quality, ilvl, reqLevel, class, subClass, maxStack, equipLoc, texture,
        sellPrice, classID, subclassID = C_Item.GetItemInfo(itemID)
    if not name then return nil end
    return {
        name = name, quality = quality, ilvl = ilvl, reqLevel = reqLevel,
        class = class, subClass = subClass, maxStack = maxStack,
        equipLoc = equipLoc, classID = classID, subclassID = subclassID,
    }
end

-- Projectile subclassID：2=Arrow，3=Bullet。用数字而不是本地化 subtype。
function Ammo.KindOf(itemID)
    local d = ItemInfo(itemID)
    if not d then return nil end
    if d.classID ~= 6 and d.equipLoc ~= "INVTYPE_AMMO" then return nil end
    if d.subclassID == 2 then return "Arrow" end
    if d.subclassID == 3 then return "Bullet" end
    local s = tostring(d.subClass or ""):lower()
    if s:find("arrow", 1, true) or s:find("箭", 1, true) then return "Arrow" end
    if s:find("bullet", 1, true) or s:find("子弹", 1, true) or s:find("弹", 1, true) then return "Bullet" end
    local n = tostring(d.name or ""):lower()
    if n:find("箭", 1, true) then return "Arrow" end
    if n:find("弹", 1, true) then return "Bullet" end
    return nil
end

function Ammo.IsHunter()
    if type(UnitClass) ~= "function" then return false end
    local ok, _, class = pcall(UnitClass, "player")
    return ok and class == "HUNTER"
end

function Ammo.RangedKind()
    local slot = _G.INVSLOT_RANGED or 18
    if type(GetInventoryItemID) ~= "function" then return nil end
    local ok, id = pcall(GetInventoryItemID, "player", slot)
    if not ok or not id or id == 0 then
        if type(GetInventoryItemLink) == "function" then
            local lok, link = pcall(GetInventoryItemLink, "player", slot)
            if lok and link then
                id = tonumber(tostring(link):match("item:(%d+)"))
            end
        end
    end
    if not id or id == 0 then
        if ns.Log then ns.Log("ammo.ranged", { id = id, slot = slot, error = "empty" }) end
        return nil
    end
    local d = ItemInfo(id)
    if not d then
        if ns.Log then ns.Log("ammo.ranged", { id = id, slot = slot, error = "no_item_info" }) end
        return nil
    end
    if not d then return nil end
    -- Weapon subclassID：2=Bow，3=Gun，18=Crossbow。本地化 subtype 只做兜底。
    local kind
    if d.classID == 2 then
        if d.subclassID == 2 or d.subclassID == 18 then
            kind = "Arrow"
        elseif d.subclassID == 3 then
            kind = "Bullet"
        end
    end
    if not kind then
        local s = tostring(d.subClass or ""):lower()
        if s:find("bow", 1, true) or s:find("crossbow", 1, true)
            or s:find("弓", 1, true) or s:find("弩", 1, true) then
            kind = "Arrow"
        elseif s:find("gun", 1, true) or s:find("枪", 1, true) then
            kind = "Bullet"
        end
    end
    if ns.Log then
        ns.Log("ammo.ranged", {
            id = id, name = d.name, classID = d.classID, subclassID = d.subclassID,
            subClass = d.subClass, kind = kind,
        })
    end
    return kind, id
end

local function ScanBags(fn)
    for _, bag in ipairs(ns.GetBagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        for slot = 1, n do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then fn(info, bag, slot) end
        end
    end
end

function Ammo.Count(itemID)
    if not itemID then return 0 end
    if C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, itemID, false, false, false)
        if ok and type(n) == "number" then
            local slot = _G.INVSLOT_AMMO or 0
            if type(GetInventoryItemID) == "function"
                and GetInventoryItemID("player", slot) == itemID then
                n = n + (type(GetInventoryItemCount) == "function"
                    and GetInventoryItemCount("player", slot) or 1)
            end
            return n
        end
    end
    local total = 0
    ScanBags(function(info)
        if info.itemID == itemID then total = total + (info.stackCount or 1) end
    end)
    local slot = _G.INVSLOT_AMMO or 0
    if type(GetInventoryItemID) == "function" and GetInventoryItemID("player", slot) == itemID then
        total = total + (type(GetInventoryItemCount) == "function"
            and GetInventoryItemCount("player", slot) or 1)
    end
    return total
end

function Ammo.Preferred(kind)
    if not kind then return nil end
    if ns.db and ns.db.ammoItemID and Ammo.KindOf(ns.db.ammoItemID) == kind then
        return ns.db.ammoItemID
    end
    local slot = _G.INVSLOT_AMMO or 0
    if type(GetInventoryItemID) == "function" then
        local ok, id = pcall(GetInventoryItemID, "player", slot)
        if ok and id and Ammo.KindOf(id) == kind then return id end
    end
    local bestID, bestCount, bestQuality
    ScanBags(function(info)
        if Ammo.KindOf(info.itemID) == kind then
            local count = info.stackCount or 1
            local quality = info.quality or 0
            if not bestID or count > bestCount
                or (count == bestCount and quality > (bestQuality or 0)) then
                bestID, bestCount, bestQuality = info.itemID, count, quality
            end
        end
    end)
    return bestID
end

local function MerchantItemID(index)
    if type(GetMerchantItemID) == "function" then
        local ok, id = pcall(GetMerchantItemID, index)
        if ok and id then return id end
    end
    if type(GetMerchantItemLink) == "function" then
        local ok, link = pcall(GetMerchantItemLink, index)
        if ok and link then return tonumber(link:match("item:(%d+)")) end
    end
    return nil
end

-- 在商人处补到 db.ammoTarget。优先补当前携带的同一 itemID；没有就挑同类型最便宜的。
function Ammo.Restock(forceStacks)
    if not (ns.db and ns.db.ammoAutoBuy) then return end
    if not Ammo.IsHunter() then return end
    if ns.merchantAmmoDone then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    local kind = Ammo.RangedKind()
    if not kind then
        LogEvent("ammo.skip", { why = "no_ranged" })
        return
    end
    local target = tonumber(ns.db.ammoTarget) or 1000
    local preferred = Ammo.Preferred(kind)
    local current = preferred and Ammo.Count(preferred) or 0
    if not forceStacks and preferred and current >= target then
        ns.merchantAmmoDone = true
        LogEvent("ammo.skip", { why = "full", itemID = preferred, count = current, target = target })
        return
    end
    if type(GetMerchantNumItems) ~= "function" then return end

    local num = GetMerchantNumItems()
    LogEvent("ammo.restock", {
        kind = kind, preferred = preferred, current = current,
        target = target, merchantItems = num,
        forceStacks = forceStacks or 0,
    })
    local exact, fallback
    for i = 1, num do
        local name, _, price, stackCount, numAvailable, isPurchasable = GetMerchantItemInfo(i)
        local itemID = MerchantItemID(i)
        if itemID and price and price >= 0 and isPurchasable ~= false
            and Ammo.KindOf(itemID) == kind then
            local cand = {
                index = i, itemID = itemID, name = name, price = price,
                stack = math.max(stackCount or 1, 1), avail = numAvailable or -1,
            }
            if preferred and itemID == preferred then
                exact = cand
            end
            if not fallback or cand.price < fallback.price then
                fallback = cand
            end
        end
    end
    local cand = exact or fallback
    if not cand then
        LogEvent("ammo.skip", { why = "not_sold", kind = kind, preferred = preferred })
        return
    end

    local needed = target - Ammo.Count(cand.itemID)
    if forceStacks then
        needed = math.max(needed, (tonumber(forceStacks) or 1) * cand.stack)
    end
    if needed <= 0 then
        ns.merchantAmmoDone = true
        LogEvent("ammo.skip", { why = "full", itemID = cand.itemID })
        return
    end
    local money = type(GetMoney) == "function" and GetMoney() or 0
    local batches = math.ceil(needed / cand.stack)
    local affordableBatches = cand.price > 0 and math.floor(money / cand.price) or batches
    local availableBatches = cand.avail >= 0 and math.floor(cand.avail / cand.stack) or batches
    -- 一次最多买 20 个批次；每次不带 quantity，跨版本都按“一叠”买，避免把 800 当 800 叠
    local buyBatches = math.min(batches, affordableBatches, availableBatches, 20)
    if buyBatches <= 0 then
        LogEvent("ammo.skip", { why = "money", price = cand.price, money = money, itemID = cand.itemID })
        return
    end

    local bought, lastErr = 0, nil
    for _ = 1, buyBatches do
        local ok, err = pcall(BuyMerchantItem, cand.index)
        if ok then
            bought = bought + cand.stack
        else
            lastErr = tostring(err)
            break
        end
    end
    ns.merchantAmmoDone = true
    LogEvent("ammo.buy", {
        itemID = cand.itemID, name = cand.name, items = bought, batches = buyBatches,
        price = cand.price, stack = cand.stack, money = money,
        ok = bought > 0, err = lastErr,
    })
    if bought > 0 then
        ns.Print("补充 " .. tostring(cand.name) .. " ×" .. bought .. "。")
    else
        ns.Print("补弹药失败：" .. tostring(lastErr or "商人没货/钱不够"))
    end
end

function Ammo.PrintStatus()
    local kind = Ammo.RangedKind()
    if not Ammo.IsHunter() then
        ns.Print("不是猎人，不需要弹药。")
        return
    end
    if not kind then
        ns.Print("没有识别到需要弹药的远程武器。")
        return
    end
    local preferred = Ammo.Preferred(kind)
    local count = preferred and Ammo.Count(preferred) or 0
    ns.Print("弹药类型：" .. (kind == "Arrow" and "箭" or "子弹")
        .. "；当前：" .. (preferred and (tostring(preferred) .. " " .. Ammo.Name(preferred)) or "无")
        .. " ×" .. count
        .. "；目标：" .. tostring(ns.db and ns.db.ammoTarget or 1000)
        .. "；自动购买：" .. (ns.db and ns.db.ammoAutoBuy and "开" or "关"))
end

function Ammo.Name(itemID)
    local name = C_Item.GetItemInfo(itemID)
    return name or tostring(itemID)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        ns.merchantAmmoDone = nil
        -- 商人一开就先在硬件事件上下文里自动补一次，不需要玩家输入任何命令
        if ns.db and ns.db.ammoAutoBuy then
            Ammo.Restock()
        end
        -- 自动卖货开启时再在卖完后补一次；否则 1 秒后再试
        if ns.db and not ns.db.autoSell then
            C_Timer.After(1.0, function() Ammo.Restock() end)
        else
            C_Timer.After(6.0, function() Ammo.Restock() end)
        end
    else
        ns.merchantAmmoDone = nil
    end
end)
