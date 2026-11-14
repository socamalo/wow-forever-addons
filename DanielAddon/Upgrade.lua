-- 背包里比身上更好的装备：识别 + 一键换上
-- 注意：穿装备是受保护操作，真实可靠的路径是玩家点按钮（硬件事件）。
-- 后台自动穿是实验模式，被客户端拦时会自检并自动关掉。
local addonName, ns = ...

local function LogEvent(event, data)
    if ns.Log then ns.Log(event, data) end
end

local SLOT_MAINHAND = 16
local SLOT_OFFHAND = 17
local SLOT_RANGED = 18

-- 单槽位：装备类型 → 槽位
local SINGLE_SLOT = {
    INVTYPE_HEAD = 1,
    INVTYPE_NECK = 2,
    INVTYPE_SHOULDER = 3,
    INVTYPE_CHEST = 5,
    INVTYPE_ROBE = 5,
    INVTYPE_WAIST = 6,
    INVTYPE_LEGS = 7,
    INVTYPE_FEET = 8,
    INVTYPE_WRIST = 9,
    INVTYPE_HANDS = 10,
    INVTYPE_CLOAK = 15,
}

-- 双槽位：戒指/饰品，选当前更弱的那个
local DUAL_SLOT = {
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
}

-- 职业相关属性权重（经典旧世口径）。没有列出的职业退回只比装等。
-- 数值是粗权重：主属性 2，攻强 1，暴击/命中 1.5，耐力 0.5。
local CLASS_WEIGHTS = {
    WARRIOR = {
        STRENGTH = 2.0,
        ATTACK_POWER = 1.0,
        CRIT = 1.5,
        HIT = 1.5,
        STAMINA = 0.5,
        AGILITY = 0.5,
    },
    HUNTER = {
        AGILITY = 2.0,
        RANGED_ATTACK_POWER = 1.0,
        ATTACK_POWER = 1.0,
        CRIT = 1.5,
        HIT = 1.5,
        STAMINA = 0.5,
        INTELLECT = 0.3,
    },
}

local function GetClassToken()
    local _, token = UnitClass("player")
    return token
end

-- 用 C_Item.GetItemStats 把属性换成加权分；拿不到数据返回 nil
local function StatScore(link)
    local weights = CLASS_WEIGHTS[GetClassToken()]
    if not weights or not link then return nil end
    if not C_Item.GetItemStats then return nil end
    local ok, stats = pcall(C_Item.GetItemStats, link)
    if not ok or type(stats) ~= "table" then return nil end

    local score, any = 0, false
    for key, value in pairs(stats) do
        if type(key) == "string" and type(value) == "number" then
            local k = key:upper()
            if weights.RANGED_ATTACK_POWER and k:find("RANGED_ATTACK_POWER", 1, true) then
                score = score + value * weights.RANGED_ATTACK_POWER
                any = true
            elseif weights.ATTACK_POWER and k:find("ATTACK_POWER", 1, true) then
                score = score + value * weights.ATTACK_POWER
                any = true
            elseif weights.STRENGTH and k:find("STRENGTH", 1, true) then
                score = score + value * weights.STRENGTH
                any = true
            elseif weights.AGILITY and k:find("AGILITY", 1, true) then
                score = score + value * weights.AGILITY
                any = true
            elseif weights.INTELLECT and k:find("INTELLECT", 1, true) then
                score = score + value * weights.INTELLECT
                any = true
            elseif weights.STAMINA and k:find("STAMINA", 1, true) then
                score = score + value * weights.STAMINA
                any = true
            elseif weights.CRIT and k:find("CRIT", 1, true) then
                score = score + value * weights.CRIT
                any = true
            elseif weights.HIT and k:find("HIT", 1, true) then
                score = score + value * weights.HIT
                any = true
            end
        end
    end

    if not any then return nil end
    return score
end

-- 从物品 tooltip 里读秒伤（客户端没有直接的 DPS API）
-- 结构依据：Baganator 用 C_TooltipInfo.GetHyperlink(link).lines[i].leftText
local dpsCache = {}

local function WeaponDPS(link)
    if not link then return nil end
    local cached = dpsCache[link]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local data
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, res = pcall(C_TooltipInfo.GetHyperlink, link)
        if ok then data = res end
    end

    if not data or type(data.lines) ~= "table" then
        return nil          -- 不缓存失败，下次再试
    end

    local found

    -- tooltip 文本在受限制环境下可能是秘密字符串，整套解析放进 pcall
    pcall(function()
        for _, line in ipairs(data.lines) do
            local text = line and line.leftText
            if type(text) ~= "string" and type(text) == "table" and text.value then
                text = text.value
            end
            if type(text) == "string"
                and not (type(issecretvalue) == "function" and issecretvalue(text)) then
                local lower = text:lower()
                if text:find("每秒伤害", 1, true) or lower:find("damage per second", 1, true) then
                    local num = text:match("(%d+%.?%d*)")
                    if num then
                        found = tonumber(num)
                        if found then return end
                    end
                end
            end
        end
    end)

    if found then
        dpsCache[link] = found
        return found
    end

    dpsCache[link] = false
    return nil
end

local function ItemStats(itemID)
    if not itemID or itemID == 0 then return nil end
    -- 第 14 个返回值是 bindType：2 = 装备后绑定（BoE）
    local name, link, quality, ilvl, reqLevel, _, subClass, _, _, _, _, _, _, bindType =
        C_Item.GetItemInfo(itemID)
    if not name then
        if C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return nil
    end
    local _, _, _, equipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    local entry = {
        itemID = itemID,
        name = name,
        link = link,
        quality = quality or 0,
        ilvl = ilvl or 0,
        reqLevel = reqLevel or 0,
        equipLoc = equipLoc,
        classID = classID,
        subClassID = subClassID,
        subClass = subClass,
        bindType = bindType,
        score = StatScore(link),
    }
    if classID == 2 then
        entry.dps = WeaponDPS(link)
    end
    return entry
end

local function EquippedItem(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local id = tonumber(string.match(link, "item:(%d+)"))
    if not id then return nil end
    return ItemStats(id)
end

-- 武器按"单手/双手/副手/远程"归类，斧和剑算同类；护甲必须同材质
local function HandCategory(loc)
    if loc == "INVTYPE_2HWEAPON" then return "2h" end
    if loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND"
        or loc == "INVTYPE_WEAPONOFFHAND" then return "1h" end
    if loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" then return "off" end
    if loc == "INVTYPE_RANGED" or loc == "INVTYPE_RANGEDRIGHT"
        or loc == "INVTYPE_THROWN" then return "ranged" end
    if loc == "INVTYPE_RELIC" then return "relic" end
    return loc
end

-- 护甲材质等级：布 1 < 皮 2 < 锁 3 < 板 4
local ARMOR_TIER = { [1] = 1, [2] = 2, [3] = 3, [4] = 4 }

-- 同类才能比：低材质不能顶高材质（布不能顶板），但高材质可以升级低材质（皮顶布）
-- 武器按装等（暴雪的装等本身由 DPS 换算），护甲/饰品优先看职业属性分
local function IsBetter(st, cur)
    if not cur then return st.ilvl > 0 end
    if st.classID ~= cur.classID then return false end
    if st.classID == 4 then
        local stTier, curTier = ARMOR_TIER[st.subClassID], ARMOR_TIER[cur.subClassID]
        if stTier and curTier then
            if stTier < curTier then return false end
            if stTier > curTier then
                -- 材质升级（例如皮甲换布甲）：装等不比身上低就换
                return (st.ilvl or 0) >= (cur.ilvl or 0)
            end
        elseif st.subClassID ~= cur.subClassID then
            return false
        end
    elseif st.classID ~= 2 then
        if HandCategory(st.equipLoc) ~= HandCategory(cur.equipLoc) then
            return false
        end
    end
    -- 武器（classID 2）允许跨手别比较：单手要能顶掉身上的双手，反之亦然

    if st.classID == 2 then
        -- 武器：有秒伤就比秒伤（含跨单手/双手），没有才退回装等
        if st.dps and cur.dps and st.dps ~= cur.dps then
            return st.dps > cur.dps
        end
        -- 只有一边读到秒伤时不硬比，退回装等
        if st.ilvl ~= cur.ilvl then return st.ilvl > cur.ilvl end
        if st.score and cur.score and st.score ~= cur.score then
            return st.score > cur.score
        end
        return (st.quality or 0) > (cur.quality or 0)
    end

    -- 护甲 / 饰品 / 其他：有属性分就比属性分
    if st.score and cur.score then
        if st.score ~= cur.score then return st.score > cur.score end
    elseif st.score and not cur.score then
        return st.score > 0
    elseif cur.score and not st.score then
        -- 新件没有职业属性：装等更高，或同装等但品质更高，就换
        -- （给纯护甲/耐力的升级留条路，例如任务绿装护腕）
        if (st.ilvl or 0) > (cur.ilvl or 0) then return true end
        if (st.ilvl or 0) == (cur.ilvl or 0) and (st.quality or 0) > (cur.quality or 0) then
            return true
        end
        return false
    end

    if st.ilvl ~= cur.ilvl then return st.ilvl > cur.ilvl end
    return (st.quality or 0) > (cur.quality or 0)
end

-- 玩家手动忽略的物品不参与升级识别与自动换装
local BIND_ON_EQUIP = 2

function ns.IsBlacklisted(itemID)
    local list = ns.db and ns.db.blacklist
    return not not (list and itemID and list[itemID])
end

local function CanPlayerEquip(itemID, reqLevel)
    local level = UnitLevel("player")
    if type(level) == "number" and reqLevel and reqLevel > level then
        return false
    end
    if C_Item.IsUsableItem then
        local ok, usable = pcall(C_Item.IsUsableItem, itemID)
        if ok and usable == false then return false end
    end
    if C_Item.IsEquippableItem then
        local ok, res = pcall(C_Item.IsEquippableItem, itemID)
        if ok then return res and true or false end
    end
    return true
end

-- 返回候选目标槽位；返回 nil 表示这件物品不参与自动换装
local function TargetSlotsFor(st)
    local single = SINGLE_SLOT[st.equipLoc]
    if single then return { single } end

    local dual = DUAL_SLOT[st.equipLoc]
    if dual then
        -- 选当前更弱的槽位
        local bestSlot, bestIlvl
        for _, s in ipairs(dual) do
            local cur = EquippedItem(s)
            local ilvl = cur and cur.ilvl or 0
            if not bestIlvl or ilvl < bestIlvl then
                bestSlot, bestIlvl = s, ilvl
            end
        end
        return { bestSlot }
    end

    local main = EquippedItem(SLOT_MAINHAND)
    local off = EquippedItem(SLOT_OFFHAND)
    local mainIs2H = main and main.equipLoc == "INVTYPE_2HWEAPON"

    local loc = st.equipLoc
    if loc == "INVTYPE_2HWEAPON" then
        -- 双手武器始终可以进主手；副手有盾/武器时客户端会把副手退回背包
        return { SLOT_MAINHAND }
    elseif loc == "INVTYPE_WEAPON" then
        local out = { SLOT_MAINHAND }
        -- 副手只在主手本来就是单手时才考虑，避免莫名其妙把盾牌顶掉
        if main and not mainIs2H then
            out[#out + 1] = SLOT_OFFHAND
        end
        return out
    elseif loc == "INVTYPE_WEAPONMAINHAND" then
        return { SLOT_MAINHAND }
    elseif loc == "INVTYPE_WEAPONOFFHAND" or loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" then
        if main and not mainIs2H then return { SLOT_OFFHAND } end
        return nil
    elseif loc == "INVTYPE_RANGED" or loc == "INVTYPE_RANGEDRIGHT"
        or loc == "INVTYPE_THROWN" or loc == "INVTYPE_RELIC" then
        return { SLOT_RANGED }
    end

    return nil
end

-- 扫描背包，返回 { {bag=, slot=, itemID=, target=, name=, ilvl=, curIlvl=}, ... }
-- 每件物品只分一个槽位、每个槽位只收一件：单手武器会同时匹配主手和副手，
-- 不去重的话第二次调用会把刚换下来的旧装备又塞进副手。
-- 给自动卖红装用：返回这件装备可能进入的所有槽位（戒指/饰品两个槽都返回）
function ns.PossibleSlotsForItem(itemID)
    local st = ItemStats(itemID)
    if not st or not st.equipLoc then return nil end
    local dual = DUAL_SLOT[st.equipLoc]
    if dual then return { dual[1], dual[2] } end
    return TargetSlotsFor(st)
end

-- 强制穿某件装备（不看属性评分，也不管 BoE）；给 /daniel equipitem 用
function ns.ForceEquipItem(itemID)
    if not itemID then return false, "没有 itemID" end
    local slots = ns.PossibleSlotsForItem(itemID)
    if not slots or #slots == 0 then return false, "找不到可用槽位" end
    local target
    for _, slot in ipairs(slots) do
        local current = GetInventoryItemID and GetInventoryItemID("player", slot)
        if not current or current == 0 then target = slot; break end
    end
    target = target or slots[1]
    if not C_Item.EquipItemByName then return false, "客户端没有 EquipItemByName" end
    local ok, err = pcall(C_Item.EquipItemByName, itemID, target)
    return ok, err
end

function ns.GetUpgrades()
    local cand = {}
    local missing = 0
    for _, bag in ipairs(ns.GetBagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        for slot = 1, n do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isLocked and (info.quality or 0) > 0 then
                local st = ItemStats(info.itemID)
                if not st then
                    -- 物品数据还没缓存，本轮先跳过，过一会儿重试
                    missing = missing + 1
                end
                if st and st.equipLoc and not ns.IsBlacklisted(st.itemID)
                    and not (ns.IsProfessionTool and ns.IsProfessionTool(st.itemID, st.name, st.subClass)) then
                    local targets = TargetSlotsFor(st)
                    if targets and CanPlayerEquip(st.itemID, st.reqLevel) then
                        -- 一件物品只进一个槽位，按 TargetSlotsFor 的顺序取第一个能提升的槽
                        -- （主手在前，所以单手武器会先补主手）
                        local bestTarget, bestGain, bestCurIlvl, bestCurScore, bestCurDps, bestCurName
                        for _, target in ipairs(targets) do
                            local cur = EquippedItem(target)
                            if IsBetter(st, cur) then
                                local curIlvl = cur and cur.ilvl or 0
                                bestTarget, bestGain, bestCurIlvl = target, st.ilvl - curIlvl, curIlvl
                                bestCurScore = cur and cur.score or 0
                                bestCurDps = cur and cur.dps or nil
                                bestCurName = cur and cur.name or nil
                                break
                            end
                        end
                        if bestTarget then
                            cand[#cand + 1] = {
                                bag = bag,
                                slot = slot,
                                itemID = st.itemID,
                                target = bestTarget,
                                name = st.name,
                                ilvl = st.ilvl,
                                curIlvl = bestCurIlvl,
                                score = st.score,
                                curScore = bestCurScore,
                                dps = st.dps,
                                curDps = bestCurDps,
                                gain = bestGain,
                                src = bag * 1000 + slot,
                                curName = bestCurName,
                                bindType = st.bindType,
                                quality = st.quality,
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(cand, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        return a.ilvl > b.ilvl
    end)

    local out, usedSrc, usedTarget = {}, {}, {}
    for _, c in ipairs(cand) do
        if not usedSrc[c.src] and not usedTarget[c.target] then
            usedSrc[c.src] = true
            usedTarget[c.target] = true
            out[#out + 1] = c
        end
    end

    ns.upgradeDataMissing = missing > 0

    table.sort(out, function(a, b) return a.target < b.target end)
    return out
end

local function VerifyEquips(ups)
    local ok, failed = 0, {}
    for _, u in ipairs(ups) do
        local link = GetInventoryItemLink("player", u.target)
        if link and tonumber(string.match(link, "item:(%d+)")) == u.itemID then
            ok = ok + 1
        else
            failed[#failed + 1] = u
        end
    end
    return ok, failed
end

-- 真正执行一次装备。
-- 优先 C_Item.EquipItemByName：Forever 的生成文档只标了 SecretArguments、没标 protected，
-- 出战斗后不是硬件事件也能穿；这是后台自动换装能成立的前提。
-- C_Container.UseContainerItem 明确是 protected（只能安全代码调用），只在手动点击时兜底。
local function DoEquip(u, allowContainer)
    if C_Item.EquipItemByName then
        local ok = pcall(C_Item.EquipItemByName, u.itemID, u.target)
        if ok then return true end
    end
    if allowContainer then
        C_Container.UseContainerItem(u.bag, u.slot)
        return true
    end
    return false
end

-- BoE 提示每个 itemID 只说一次，避免每次背包变动都刷屏
local boeNotified = {}

-- 自动换装连续两次换不上的物品，本会话内不再自动尝试（手动按钮仍可试）
local autoBadItems = {}

-- 一键换上。手动模式允许 UseContainerItem 兜底；自动模式只走 EquipItemByName
function ns.EquipUpgrades(isAuto, isRetry)
    if InCombatLockdown() then
        if not isAuto then ns.Print("战斗中不能换装备。") end
        return 0
    end
    if ns.CursorBusy() then
        if not isAuto then ns.Print("手上还拿着东西，放下再换。") end
        return 0
    end

    local ups = ns.GetUpgrades()
    if #ups == 0 then
        -- 刚拾取的物品可能还没缓存完，等一下重扫一次
        if ns.upgradeDataMissing and not isRetry then
            C_Timer.After(0.8, function() ns.EquipUpgrades(isAuto, true) end)
            return 0
        end
        if not isAuto then ns.Print("没有找到比身上更好的装备。") end
        return 0
    end

    if isAuto and not C_Item.EquipItemByName then
        if ns.db then ns.db.autoEquip = false end
        ns.Print("当前客户端没有 C_Item.EquipItemByName，后台自动换装不可用；"
            .. "已改为背包绿色高亮，看到后点面板按钮。")
        if ns.RefreshPanel then ns.RefreshPanel() end
        return 0
    end

    -- 自动模式跳过「装备后绑定」：换上去就把 BoE 绑死了，可能值不少钱
    local todo = ups
    if isAuto then
        todo = {}
        for _, u in ipairs(ups) do
            -- 只保护蓝/紫 BoE；绿装/白装该穿就穿，避免升级装备被一直跳过
            if ns.db and ns.db.skipBoE and u.bindType == BIND_ON_EQUIP
                and (u.quality or 0) >= 3 then
                if not boeNotified[u.itemID] then
                    boeNotified[u.itemID] = true
                    LogEvent("equip.skip_boe", {
                        itemID = u.itemID, name = u.name, target = u.target, quality = u.quality,
                    })
                    ns.Print("跳过「" .. u.name .. "」：蓝/紫装备后绑定，自动换会绑身上；"
                        .. "要换就点面板「换上」或 /equipup（手动不跳过）。")
                end
            elseif not autoBadItems[u.itemID] then
                todo[#todo + 1] = u
            end
        end
        if #todo == 0 then return 0 end
    end

    local attempted = 0
    for _, u in ipairs(todo) do
        LogEvent("equip.try", {
            auto = isAuto and true or false,
            itemID = u.itemID, name = u.name, target = u.target,
            ilvl = u.ilvl, curIlvl = u.curIlvl,
            score = u.score, curScore = u.curScore,
            dps = u.dps, curDps = u.curDps,
            bindType = u.bindType,
        })
        if DoEquip(u, not isAuto) then
            attempted = attempted + 1
        end
    end
    if attempted == 0 then
        -- pcall 都失败，说明这个客户端连调用入口都不让走
        if isAuto then
            ns.equipFailures = (ns.equipFailures or 0) + 1
            if ns.equipFailures >= 2 then
                if ns.db then ns.db.autoEquip = false end
                ns.Print("C_Item.EquipItemByName 调用失败，后台自动换装不可用；"
                    .. "已改用背包高亮 + 面板按钮。")
                if ns.RefreshPanel then ns.RefreshPanel() end
            end
        end
        return 0
    end

    C_Timer.After(0.7, function()
        local ok, failed = VerifyEquips(todo)
        local failedIDs = {}
        for _, u in ipairs(failed or {}) do failedIDs[#failedIDs + 1] = u.itemID end
        LogEvent("equip.result", {
            auto = isAuto and true or false,
            attempted = attempted, verified = ok, failed = failedIDs,
        })
        if ok > 0 then
            ns.equipFailures = 0
            if isAuto then
                ns.Print("自动换上了 " .. ok .. " 件更好的装备。")
            else
                ns.Print("换上了 " .. ok .. " 件更好的装备。")
            end
            if ns.ScheduleHighlight then ns.ScheduleHighlight(0.1) end
        else
            ns.equipFailures = (ns.equipFailures or 0) + 1
            if isAuto then
                if ns.equipFailures >= 2 then
                    if ns.db then ns.db.autoEquip = false end
                    ns.Print("客户端拦住了后台自动换装，已关掉这个开关；"
                        .. "背包里的升级装备会用绿色高亮标出，点面板按钮即可。")
                    if ns.RefreshPanel then ns.RefreshPanel() end
                end
            else
                ns.Print("没换上——装备可能被锁定或角色用不了。稍后再点一次。")
            end
        end

        -- 个别换不上的物品（唯一装备冲突、槽位被锁等）单独计数，不拖累整体自动换装
        if isAuto and failed then
            for _, u in ipairs(failed) do
                local n = (autoBadItems[u.itemID] or 0) + 1
                autoBadItems[u.itemID] = n
                if n == 2 then
                    ns.Print("「" .. u.name .. "」自动换了两次都没成功，本会话先不再自动尝试（仍会高亮）。")
                end
            end
        end

        if ns.RefreshPanel then ns.RefreshPanel() end
    end)

    return attempted
end

-- 后台自动换装：背包一变就扫描，延迟 2 秒避免刚拾取时物品锁定。
-- 战斗中先记下来，出战斗（PLAYER_REGEN_ENABLED）再补一次。
local watch = CreateFrame("Frame")
local autoTimer

local function TryAutoEquip()
    autoTimer = nil
    if not ns.db or not ns.db.autoEquip then return end
    if InCombatLockdown() then
        ns.pendingAutoEquip = true
        return
    end
    if ns.CursorBusy() then return end
    ns.EquipUpgrades(true)
end

watch:RegisterEvent("BAG_UPDATE")
-- 刚拾取的物品会短暂锁定；解锁后客户端只发 ITEM_LOCK_CHANGED，不补 BAG_UPDATE
watch:RegisterEvent("ITEM_LOCK_CHANGED")
watch:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
watch:RegisterEvent("PLAYER_ENTERING_WORLD")
watch:RegisterEvent("PLAYER_LEVEL_UP")
watch:RegisterEvent("PLAYER_REGEN_ENABLED")
watch:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if not ns.pendingAutoEquip then return end
        ns.pendingAutoEquip = nil
    end
    if not ns.db or not ns.db.autoEquip then return end
    if autoTimer then autoTimer:Cancel() end
    autoTimer = C_Timer.NewTimer(2, TryAutoEquip)
end)

-- 诊断某件物品为什么没被换上：/daniel why <物品链接或ID>
function ns.Explain(itemID)
    if not itemID then
        ns.Print("用法：/daniel why 12345，或 shift 点物品链接")
        return
    end
    local st = ItemStats(itemID)
    if not st then
        ns.Print("读不到物品 " .. tostring(itemID) .. " 的数据（ID 不对或还没缓存）")
        return
    end

    ns.Print(st.name .. "｜装等 " .. st.ilvl .. "｜类型 " .. tostring(st.equipLoc)
        .. "｜class " .. tostring(st.classID) .. "/" .. tostring(st.subClassID)
        .. (st.bindType == BIND_ON_EQUIP and "｜装备后绑定" or ""))
    if ns.IsBlacklisted(st.itemID) then
        ns.Print("这件物品已被 /daniel ignore 忽略，不参与升级识别。")
    end
    if st.dps then
        ns.Print("秒伤：" .. string.format("%.1f", st.dps))
    end
    if st.score then
        ns.Print("属性分：" .. string.format("%.1f", st.score))
    end
    ns.Print("角色能装备：" .. tostring(CanPlayerEquip(st.itemID, st.reqLevel)))

    local targets = TargetSlotsFor(st)
    if not targets then
        ns.Print("结论：这件物品所在槽位不参与自动换装（多为盾/副手，主手是双手时）")
        return
    end

    for _, target in ipairs(targets) do
        local cur = EquippedItem(target)
        local better = IsBetter(st, cur)
        if cur then
            local curLine = "槽位 " .. target .. "：当前 " .. cur.name
                .. "（装等 " .. cur.ilvl
            if cur.dps then
                curLine = curLine .. "，秒伤 " .. string.format("%.1f", cur.dps)
            end
            ns.Print(curLine .. "）→ " .. (better and "|cff20ff20是升级|r" or "不是升级"))
        else
            ns.Print("槽位 " .. target .. "：空 → " .. (better and "|cff20ff20可装备|r" or "不升级"))
        end
    end
end

function ns.ListUpgrades()
    local ups = ns.GetUpgrades()
    if #ups == 0 then
        ns.Print("没有找到比身上更好的装备。")
        return
    end
    for _, u in ipairs(ups) do
        local boe = u.bindType == BIND_ON_EQUIP and "｜装备后绑定" or ""
        if u.dps and u.curDps then
            ns.Print(string.format("%s（秒伤 %.1f → 当前 %.1f）%s",
                u.name, u.dps, u.curDps, boe))
        else
            local line = u.name .. "（装等 " .. u.ilvl .. " → 当前 " .. u.curIlvl
            if u.score and u.curScore and (u.score > 0 or u.curScore > 0) then
                line = line .. "，属性分 " .. math.floor(u.score) .. " → " .. math.floor(u.curScore)
            end
            ns.Print(line .. "）" .. boe)
        end
    end
    ns.Print("共 " .. #ups .. " 件；已开启自动换装，出战斗后会自动穿；"
        .. "也可 /daniel equip 立即换上。")
end
