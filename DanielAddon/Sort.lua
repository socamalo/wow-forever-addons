-- 按“大类 → 小类”整理背包：任务/装备/消耗品/材料/配方/其他/垃圾
-- 同类里再按装备部位、武器类型、材料子类、品质、物品 ID 排，不看价格。
-- 只能在自己的"通用包"之间搬：草药包/箭袋这类专用包不动，免得物品塞不进去。
-- 搬运用的是 Baganator 同款两步 PickupContainerItem + ClearCursor。
local addonName, ns = ...

local sorting = false

-- 炉石永远第一格（不随分类/价值变化）
local HEARTHSTONE_ID = 6948

local function FamilyOf(bag)
    if bag == 0 then return 0 end
    if not C_Container.GetContainerNumFreeSlots then return nil end
    -- bagFamily 是 nilable：拿不到就当“未知包”，不要当普通包往里面塞东西
    -- （箭袋/草药包这类专用包一旦被当成普通包，会不断留下空洞）
    local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
    if not ok or family == nil then return nil end
    return family
end

local function EligibleBags()
    local out = {}
    for _, bag in ipairs(ns.GetBagIDs()) do
        if FamilyOf(bag) == 0 and C_Container.GetContainerNumSlots(bag) > 0 then
            out[#out + 1] = bag
        end
    end
    return out
end

local function KeyOf(bag, slot)
    return bag * 1000 + slot
end

-- 分类优先级：任务物品 > 升级装备 > 装备 > 消耗品 > 材料 > 配方 > 宝石/强化 > 其他 > 垃圾
local function QuestItemAt(bag, slot)
    if not C_Container.GetContainerItemQuestInfo then return nil end
    local ok, info = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
    if ok then return info end
end

local ARMOR_SLOT_RANK = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3,
    INVTYPE_CHEST = 4, INVTYPE_ROBE = 4, INVTYPE_WAIST = 5,
    INVTYPE_LEGS = 6, INVTYPE_FEET = 7, INVTYPE_WRIST = 8,
    INVTYPE_HANDS = 9, INVTYPE_FINGER = 10, INVTYPE_TRINKET = 11,
    INVTYPE_CLOAK = 12, INVTYPE_HOLDABLE = 13, INVTYPE_SHIELD = 14,
    INVTYPE_OFFHAND = 15,
}
local ARMOR_TIER = { [1] = 1, [2] = 2, [3] = 3, [4] = 4 }

-- 返回 大类 rank, 小类 subRank。小类只看类型/部位，不看价格。
local function CategoryRank(bag, slot, info)
    local itemID = info.itemID
    if ns.IsProfessionTool and ns.IsProfessionTool(itemID, info.itemName) then return 90, 0 end

    local qi = QuestItemAt(bag, slot)
    if qi and qi.isQuestItem then return 1, 0 end
    if (info.quality or 0) == 0 then return 99, 0 end

    local classID, subclassID, equipLoc
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, loc, _, cid, sid = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok then classID, subclassID, equipLoc = cid, sid, loc end
    end

    if classID == 12 then return 1, 0 end                 -- 任务物品
    if classID == 2 or classID == 4 then                 -- 武器/护甲
        if classID == 4 then
            local slotRank = ARMOR_SLOT_RANK[equipLoc or ""] or 40
            local tier = ARMOR_TIER[subclassID or 0] or 0
            return 2, slotRank * 100 + tier * 10
        end
        return 2, 2000 + (subclassID or 0)
    end
    if classID == 0 then return 3, 3000 + (subclassID or 0) end   -- 消耗品
    if classID == 7 then return 4, 4000 + (subclassID or 0) end   -- 材料
    if classID == 9 then return 5, 5000 + (subclassID or 0) end   -- 配方
    if classID == 3 or classID == 8 then return 6, 6000 + (classID or 0) * 100 + (subclassID or 0) end
    if classID == 1 then return 7, 7000 + (subclassID or 0) end   -- 容器
    return 7, 8000 + (classID or 0) * 100 + (subclassID or 0)     -- 其他
end

local function EntryLess(a, b)
    if a.pin ~= b.pin then return a.pin < b.pin end
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.subRank ~= b.subRank then return a.subRank < b.subRank end
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    return a.count > b.count
end

local function SlotsOf(bag)
    local n = 0
    if C_Container and C_Container.GetContainerNumSlots then
        local ok, v = pcall(C_Container.GetContainerNumSlots, bag)
        if ok and v then n = v end
    end
    if n == 0 and type(ContainerFrame_GetContainerNumSlots) == "function" then
        local ok, v = pcall(ContainerFrame_GetContainerNumSlots, bag)
        if ok and v then n = v end
    end
    return n or 0
end

local function CollectBag(bag)
    local slots, entries = {}, {}
    local locked = false
    local n = SlotsOf(bag)
    for slot = 1, n do
        slots[#slots + 1] = { bag = bag, slot = slot }
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID then
            if info.isLocked then
                locked = true
            else
                local rank, subRank = CategoryRank(bag, slot, info)
                entries[#entries + 1] = {
                    bag = bag, slot = slot, itemID = info.itemID,
                    count = info.stackCount or 1, quality = info.quality or 0,
                    rank = rank, subRank = subRank,
                    pin = (info.itemID == HEARTHSTONE_ID) and 0 or 1,
                }
            end
        end
    end
    return slots, entries, locked
end

-- 单个背包内部排序 + 填洞；绝不跨包搬物品。
local function SortOneBag(bag, slots, entries)
    if #entries == 0 then return 0, 0, true, true end
    table.sort(entries, EntryLess)

    local at = {}
    for _, e in ipairs(entries) do at[KeyOf(e.bag, e.slot)] = e end

    local checkSlot = slots[1].slot
    local expectID = entries[1].itemID
    local moves = 0
    for i = 1, #entries do
        local target = slots[i]
        local desired = entries[i]
        if desired.slot ~= target.slot then
            local srcSlot = desired.slot
            local kSource = KeyOf(bag, srcSlot)
            local kTarget = KeyOf(bag, target.slot)
            local occupant = at[kTarget]

            if occupant and occupant.itemID == desired.itemID then
                -- 同种堆叠不互换，客户端会合并
            else
                ClearCursor()
                if occupant then
                    C_Container.PickupContainerItem(bag, target.slot)
                    C_Container.PickupContainerItem(bag, srcSlot)
                else
                    C_Container.PickupContainerItem(bag, srcSlot)
                    C_Container.PickupContainerItem(bag, target.slot)
                end
                ClearCursor()
                at[kTarget] = desired
                desired.slot = target.slot
                if occupant then
                    at[kSource] = occupant
                    occupant.slot = srcSlot
                else
                    at[kSource] = nil
                end
                moves = moves + 1
            end
        end
    end

    -- 只在这个包内部填洞
    local compacted = 0
    local compactOK = true
    local hole
    for i, s in ipairs(slots) do
        local info = C_Container.GetContainerItemInfo(bag, s.slot)
        if info and info.isLocked then
            compactOK = false
            break
        end
        if not hole then
            if not info or not info.itemID then hole = i end
        elseif info and info.itemID then
            local target = slots[hole]
            ClearCursor()
            C_Container.PickupContainerItem(bag, s.slot)
            C_Container.PickupContainerItem(bag, target.slot)
            ClearCursor()
            local after = C_Container.GetContainerItemInfo(bag, target.slot)
            if not after or not after.itemID then
                compactOK = false
                break
            end
            compacted = compacted + 1
            hole = i
        end
    end

    local first = C_Container.GetContainerItemInfo(bag, checkSlot)
    local movedOK = first and first.itemID == expectID
    return moves, compacted, compactOK, movedOK
end

local REAGENT_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5


local function TryMove(srcBag, srcSlot, dstBag, dstSlot)
    ClearCursor()
    C_Container.PickupContainerItem(srcBag, srcSlot)
    C_Container.PickupContainerItem(dstBag, dstSlot)
    ClearCursor()
    local after = C_Container.GetContainerItemInfo(dstBag, dstSlot)
    return after and after.itemID ~= nil
end

-- 材料优先塞进第五格材料包；放不下（或该包不收）再留给普通材料包
local function MoveMaterialsToReagent(bags)
    local n = SlotsOf(REAGENT_BAG)
    if n == 0 then return 0 end
    local free = {}
    for slot = 1, n do
        local info = C_Container.GetContainerItemInfo(REAGENT_BAG, slot)
        if not info or not info.itemID then free[#free + 1] = slot end
    end
    if #free == 0 then return 0 end

    local moved = 0
    for _, bag in ipairs(bags) do
        local bn = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, bn do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isLocked then
                local rank = CategoryRank(bag, slot, info)
                if rank == 4 then
                    local idx = 1
                    while idx <= #free do
                        if TryMove(bag, slot, REAGENT_BAG, free[idx]) then
                            table.remove(free, idx)
                            moved = moved + 1
                            break
                        end
                        idx = idx + 1
                    end
                end
            end
        end
    end
    return moved
end

-- 类别 -> 背包角色。默认 5 个包：炉石/任务/消耗品、装备、装备、材料、杂项
local function BagRoles(bags)
    local roles = {}
    local n = #bags
    local order = { "quest", "equip", "material", "misc" }
    if n >= 5 then
        roles[bags[1]], roles[bags[2]], roles[bags[3]] = "quest", "equip", "equip"
        roles[bags[4]], roles[bags[5]] = "material", "misc"
    elseif n == 4 then
        roles[bags[1]], roles[bags[2]] = "quest", "equip"
        roles[bags[3]], roles[bags[4]] = "material", "misc"
    elseif n == 3 then
        roles[bags[1]], roles[bags[2]], roles[bags[3]] = "quest", "equip", "material"
    elseif n == 2 then
        roles[bags[1]], roles[bags[2]] = "quest", "equip"
    elseif n == 1 then
        roles[bags[1]] = "quest"
    end
    return roles
end

local function RoleOfRank(rank, pin)
    if pin == 0 or rank == 1 or rank == 3 then return "quest" end
    if rank == 2 then return "equip" end
    if rank == 4 or rank == 5 or rank == 6 then return "material" end
    return "misc"
end

-- 把物品挪到对应角色的背包空格里；只往空格搬，不交换、不跨角色。
local function MoveToRoleBags(bags, roles)
    local movedTotal = 0
    for _ = 1, 4 do
        local free = {}
        for _, bag in ipairs(bags) do
            local role = roles[bag]
            if role then
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for slot = 1, n do
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if not info or not info.itemID then
                        free[role] = free[role] or {}
                        free[role][#free[role] + 1] = { bag = bag, slot = slot }
                    end
                end
            end
        end

        local moved = 0
        for _, bag in ipairs(bags) do
            local bagRole = roles[bag]
            local n = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, n do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID and not info.isLocked then
                    local rank, _ = CategoryRank(bag, slot, info)
                    local pin = (info.itemID == HEARTHSTONE_ID) and 0 or 1
                    local role = RoleOfRank(rank, pin)
                    if bagRole and bagRole ~= role and free[role] then
                        for i = 1, #free[role] do
                            local dest = free[role][i]
                            if TryMove(bag, slot, dest.bag, dest.slot) then
                                table.remove(free[role], i)
                                moved = moved + 1
                                movedTotal = movedTotal + 1
                                free[bagRole] = free[bagRole] or {}
                                free[bagRole][#free[bagRole] + 1] = { bag = bag, slot = slot }
                                break
                            end
                        end
                    end
                end
            end
        end
        if moved == 0 then break end
    end
    return movedTotal
end

local function RunSort(isRetry, isAuto, triesLeft, silent)
    if sorting then return end
    sorting = true
    ns.sortStartedAt = GetTime and GetTime() or 0

    local bags = EligibleBags()
    if not ns.__sortBagLogged then
        ns.__sortBagLogged = true
        local info = {}
        for _, bag in ipairs(ns.GetBagIDs()) do
            local ok, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
            info[#info + 1] = string.format("%d:free=%s,family=%s,slots=%d",
                bag, tostring(ok and free or "err"), tostring(ok and family or "err"),
                C_Container.GetContainerNumSlots(bag) or 0)
        end
        info[#info + 1] = string.format("5(reagent):slots=%d", SlotsOf(REAGENT_BAG))
        if ns.Log then ns.Log("sort.bags", { bags = table.concat(info, " | ") }) end
    end

    -- 玩家手上拿着东西时别动背包
    if ns.CursorBusy() then
        sorting = false
        triesLeft = triesLeft or 3
        if triesLeft > 0 then
            if not isRetry and not silent then
                ns.Print("手上还拿着东西，放下后再整理。")
            end
            C_Timer.After(0.8, function() RunSort(true, isAuto, triesLeft - 1, silent) end)
        else
            if not silent then ns.Print("整理取消：东西一直拿在手上。") end
        end
        return
    end

    local roleMoves = 0
    local reagentMoves = 0
    if ns.db and ns.db.autoBagRoles ~= false then
        reagentMoves = MoveMaterialsToReagent(bags)
        roleMoves = MoveToRoleBags(bags, BagRoles(bags))
    end

    local totalMoves, totalCompacted = 0, 0
    local anyLocked, allOK, compactBlocked = false, true, false
    local details = {}
    local sortBags = {}
    for _, bag in ipairs(bags) do sortBags[#sortBags + 1] = bag end
    if SlotsOf(REAGENT_BAG) > 0 then sortBags[#sortBags + 1] = REAGENT_BAG end

    for _, bag in ipairs(sortBags) do
        local slots, entries, locked = CollectBag(bag)
        if locked then
            anyLocked = true
            details[#details + 1] = bag .. ":locked"
        else
            local m, c, cok, mok = SortOneBag(bag, slots, entries)
            totalMoves = totalMoves + m
            totalCompacted = totalCompacted + c
            if not mok then allOK = false end
            if not cok then compactBlocked = true end
            details[#details + 1] = string.format("%d:%d/%d", bag, m, c)
        end
    end

    sorting = false
    ns.sortStartedAt = nil

    if ns.Log then
        ns.Log("sort.open.result", {
            moves = totalMoves, compacted = totalCompacted,
            role_moves = roleMoves, reagent_moves = reagentMoves,
            locked = anyLocked and true or false,
            compact_ok = not compactBlocked,
            ok = allOK and true or false,
            silent = silent and true or false,
            bags = table.concat(details, " "),
        })
    end

    if silent then
        if not allOK and totalMoves > 0 and not ns.__openSortBlockedWarned then
            ns.__openSortBlockedWarned = true
            ns.Print("开包自动整理被客户端拦截，点面板「按类别整理」即可。")
        end
    elseif anyLocked then
        if not silent then
            ns.Print("有背包物品锁定，已整理其他背包，下次开包再补。")
        end
    elseif compactBlocked then
        ns.Print("有格子被锁定，包内已经排好，空洞下次开包再补。")
    elseif not allOK then
        if isAuto then
            ns.Print("自动整理好像被客户端拦住了，点一下面板里的「按类别整理」再试。")
        else
            ns.Print("有格子没搬成功，可能正被锁定，稍后再点一次。")
        end
    elseif totalMoves + totalCompacted == 0 then
        ns.Print("每个背包都已经按类别排好了。")
    else
        ns.Print("按类别整理完成，移动了 " .. (totalMoves + totalCompacted) .. " 格（每个背包单独整理）。")
    end

    if ns.RefreshPanel then
        ns.RefreshPanel()
    end
end

function ns.SortDebug()
    for _, bag in ipairs(ns.GetBagIDs()) do
        local ok, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
        ns.Print(string.format("bag %d: slots=%d free=%s family=%s%s",
            bag, C_Container.GetContainerNumSlots(bag) or 0,
            tostring(ok and free or "err"), tostring(ok and family or "err"),
            (ok and family == 0 or bag == 0) and "" or "（专用包，跳过）"))
    end
    ns.SortByValue(false, true)
    C_Timer.After(0.5, function()
        for _, bag in ipairs(ns.GetBagIDs()) do
            local n = C_Container.GetContainerNumSlots(bag) or 0
            local parts = {}
            for slot = 1, n do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                parts[#parts + 1] = info and info.itemID
                    and (tostring(info.itemID) .. "x" .. tostring(info.stackCount or 1)) or "."
            end
            ns.Print("bag " .. bag .. ": " .. table.concat(parts, " "))
        end
    end)
end

function ns.SortByValue(isAuto, silent)
    -- 上一次整理还没结束（比如卖货后的排序撞上开包整理）：稍后补一次
    if sorting then
        if GetTime and ns.sortStartedAt and GetTime() - ns.sortStartedAt > 3 then
            sorting = false -- 看门狗：异常卡住时解锁
        else
            if not ns.sortRetryQueued then
                ns.sortRetryQueued = true
                C_Timer.After(0.8, function()
                    ns.sortRetryQueued = nil
                    ns.SortByValue(true, true)
                end)
            end
            return
        end
    end
    if InCombatLockdown() then
        if not silent then ns.Print("战斗中不能整理背包，脱战后手动点一下。") end
        return
    end
    RunSort(false, isAuto, nil, silent)
end

-- 每次打开背包自动整理一次。
-- 搬物品是受保护操作，优先在 OpenBag / OnShow 的硬件事件上下文里同步执行；
-- 失败或物品还没就绪时，再延迟 0.6 秒补一次（定时器里可能被客户端拦）。
local openFrame = CreateFrame("Frame")
local openTimer
local pendingOpenSort
local openSortCooldown = nil

local function HasBagFrames()
    if ContainerFrameCombinedBags then return true end
    if ContainerFrames and #ContainerFrames > 0 then return true end
    return false
end

local function AnyBagShown()
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
        return true
    end
    if ContainerFrames then
        for _, f in ipairs(ContainerFrames) do
            if f and f:IsShown() then
                local id = f.GetBagID and f:GetBagID()
                if not id or (id >= 0 and id <= (NUM_BAG_SLOTS or 4)) then
                    return true
                end
            end
        end
    end
    return false
end

local function TrySortOnOpen(reason, immediate)
    if not ns.db or not ns.db.sortOnOpen then
        if ns.Log then ns.Log("sort.open.skip", { reason = reason, why = "disabled" }) end
        return false
    end
    if HasBagFrames() and not AnyBagShown() then
        if ns.Log then ns.Log("sort.open.skip", { reason = reason, why = "closed" }) end
        return false
    end
    if InCombatLockdown() then
        pendingOpenSort = true
        if ns.Log then ns.Log("sort.open.skip", { reason = reason, why = "combat" }) end
        return false
    end
    if ns.CursorBusy() then
        pendingOpenSort = true
        if ns.Log then ns.Log("sort.open.skip", { reason = reason, why = "cursor" }) end
        return false
    end
    pendingOpenSort = nil
    if ns.Log then
        ns.Log("sort.open.run", { reason = reason, immediate = immediate and true or false })
    end
    ns.SortByValue(true, true)
    return true
end

local function RequestOpenSort(reason)
    if not ns.db or not ns.db.sortOnOpen then return end
    local now = GetTime and GetTime() or 0
    if openSortCooldown and now - openSortCooldown < 1.0 then return end
    openSortCooldown = now
    if ns.Log then ns.Log("sort.open.event", { reason = reason }) end

    -- 硬件事件上下文里先同步试一次；成功就不再补
    local ran = TrySortOnOpen(reason, true)
    if ran then return end

    -- 背包框还没显示/物品没就绪时，等 0.6 秒再补一次
    if openTimer then openTimer:Cancel() end
    openTimer = C_Timer.NewTimer(0.6, function()
        openTimer = nil
        TrySortOnOpen(reason .. ":retry", false)
    end)
end

openFrame:RegisterEvent("BAG_OPEN")
openFrame:RegisterEvent("BAG_CONTAINER_UPDATE")
openFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
openFrame:SetScript("OnEvent", function(self, event, bagID)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingOpenSort then
            C_Timer.After(0.3, function() TrySortOnOpen("regen", false) end)
        end
        return
    end
    if not ns.db or not ns.db.sortOnOpen then return end
    if event == "BAG_OPEN" then
        if bagID and (bagID < 0 or bagID > (NUM_BAG_SLOTS or 4)) then return end
        RequestOpenSort("BAG_OPEN:" .. tostring(bagID))
    elseif event == "BAG_CONTAINER_UPDATE" then
        RequestOpenSort("BAG_CONTAINER_UPDATE")
    end
end)

-- OpenBag 在 Blizzard 的 BAG_OPEN 处理里被调用，hook 后正好在硬件事件上下文、
-- 且背包框已经 show 出来之后执行。
local function HookOpenFunctions()
    for _, name in ipairs({ "OpenBag", "OpenBackpack" }) do
        local fn = _G[name]
        if type(fn) == "function" then
            pcall(hooksecurefunc, name, function(id)
                if name == "OpenBag" and id and (id < 0 or id > (NUM_BAG_SLOTS or 4)) then return end
                RequestOpenSort(name)
            end)
        end
    end
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:SetScript("OnEvent", function()
    HookOpenFunctions()
    local list = {}
    if ContainerFrameCombinedBags then list[#list + 1] = ContainerFrameCombinedBags end
    if ContainerFrames then
        for _, f in ipairs(ContainerFrames) do list[#list + 1] = f end
    end
    for _, f in ipairs(list) do
        if f and f.HookScript and not f.__danielSortOpenHooked then
            f.__danielSortOpenHooked = true
            pcall(f.HookScript, f, "OnShow", function()
                RequestOpenSort("OnShow")
            end)
        end
    end
end)
