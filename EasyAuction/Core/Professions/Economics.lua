-- Adapted from Blackthornes Cost/Profit/LevelUp: unknown is never zero;
-- opportunity cost, vendor ceiling, bounded subcrafts and inventory pressure.
local addonName, ns = ... -- luacheck: ignore addonName
local C_Item = C_Item
local issecretvalue = issecretvalue
local type, tonumber, tostring, pcall, select = type, tonumber, tostring, pcall, select
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local format = string.format
local sort = table.sort
local E = ns.ProfessionEngine
local L = ns.L
local X = {}
E.Economics = X

local bindOnCreate = { [1] = true, [4] = true }
local pendingBindItems = {}
local pendingVendorItems = {}

local function itemKey(itemID)
    if not itemID then return nil end
    return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

-- nil means the client has not loaded the item yet. Unknown items stay in the
-- model until item data arrives; only a confirmed bind-on-create is excluded.
local function isBoundOnCreate(itemID)
    if not itemID or not C_Item or type(C_Item.GetItemInfo) ~= "function" then return nil end
    local values = { pcall(C_Item.GetItemInfo, itemID) }
    if not values[1] or (issecretvalue and issecretvalue(values[15])) or type(values[15]) ~= "number" then
        pendingBindItems[itemID] = true
        return nil
    end
    pendingBindItems[itemID] = nil
    return bindOnCreate[values[15]] == true
end

local function vendorSalePrice(itemID)
    if not itemID or not C_Item or type(C_Item.GetItemInfo) ~= "function" then return nil end
    local values = { pcall(C_Item.GetItemInfo, itemID) }
    local price = values[12] -- pcall result precedes GetItemInfo's sellPrice (return 11).
    if not values[1] or (issecretvalue and issecretvalue(price)) or type(price) ~= "number" then
        pendingVendorItems[itemID] = true
        return nil
    end
    pendingVendorItems[itemID] = nil
    if price > 0 then return price end
end

function X.ItemDataLoaded(itemID)
    if not pendingBindItems[itemID] and not pendingVendorItems[itemID] then return false end
    pendingBindItems[itemID] = nil
    pendingVendorItems[itemID] = nil
    return true
end

function X.Price(itemID, kind)
    return ns.Prices and ns.Prices.GetValue(itemID, kind or "min")
end

-- A craft with no recorded materials cannot be priced. Treating it as free
-- would rank a broken harvest above every real recipe, so it stays visible
-- with its reason instead of showing a bogus zero cost.
local function emptyCost(recipe, result)
    if #(recipe.reagents or {}) > 0 or #(recipe.slots or {}) > 0 then return false end
    result.priceable = false
    result.reason = recipe.reason or L["配方没有记录材料"]
    result.total = nil
    return true
end

function X.ReagentPrice(itemID)
    local market = X.Price(itemID, "min")
    local vendor = E.db.vendorPrices[itemID]
    local unit = type(vendor) == "table" and vendor.unitPrice or tonumber(vendor)
    -- A limited-stock vendor is informative, not guaranteed procurement.
    if unit and (type(vendor) ~= "table" or not vendor.limited) and (not market or unit < market) then
        return unit, "vendor"
    end
    if market then return market, "auction" end
    local sale = vendorSalePrice(itemID)
    return sale, sale and "vendor-sale" or "unknown"
end

-- CostTable takes the recipe record itself so guide steps can price
-- unlearned recipes straight from their learnable entries.
function X.CostTable(recipe, character, forceMarket, depth, path, owned)
    character, depth, path = character or E.character, depth or 0, path or {}
    if type(recipe) ~= "table" or not recipe.recipeID then return nil end
    local recipeID = recipe.recipeID
    if path[recipeID] then return nil end
    local result = { total = 0, priceable = recipe.complete ~= false, reagents = {}, unpriced = {}, recipeID = recipeID }
    -- Reagent uncertainty does not invalidate the recorded output quantity.
    result.yield = max(1, ((recipe.quantityMin or 1) + (recipe.quantityMax or recipe.quantityMin or 1)) / 2)
    if recipe.complete == false then result.reason = recipe.reason end

    -- Fixed materials and candidate slots use one path. This is important for
    -- guide-only/unlearned recipes: they have no Blizzard-selected quality yet,
    -- but every candidate still has to appear in the purchase calculation.
    local reagents = {}
    for index = 1, #(recipe.reagents or {}) do
        reagents[#reagents + 1] = recipe.reagents[index]
    end
    local allSlotsPriced = true
    for index = 1, #(recipe.slots or {}) do
        local slot = recipe.slots[index]
        local candidates = slot.candidates or {}
        local bestItem, bestPrice
        for candidateIndex = 1, #candidates do
            local id = candidates[candidateIndex]
            local price = X.ReagentPrice(id)
            if price and (not bestPrice or price < bestPrice) then
                bestItem, bestPrice = id, price
            end
        end
        if bestItem then
            reagents[#reagents + 1] = { itemID = bestItem, quantity = slot.quantity or 0 }
        elseif (slot.quantity or 0) > 0 then
            -- 即使候选材料暂无价格，也保留第一候选作为采购物料，不能让
            -- 未学习配方的品质槽从材料表里消失。
            allSlotsPriced = false
            if candidates[1] then
                reagents[#reagents + 1] = { itemID = candidates[1], quantity = slot.quantity }
            end
        end
    end
    if not allSlotsPriced then result.priceable = false end
    if emptyCost(recipe, result) then return result end
    path[recipeID] = true
    owned = owned or {}
    local cash = not forceMarket and E.Setting("valueOwnedMaterials", true) == false
    for index = 1, #reagents do
        local reagent = reagents[index]
        local itemID, needed = reagent.itemID, reagent.quantity
        local unit, source = X.ReagentPrice(itemID)
        -- Sale fallback values the consumed item itself, not a hypothetical cheaper subcraft.
        if depth < 3 and source ~= "vendor-sale" then
            local subrecipe = E.Recipes.ForItem(itemID, character)
            if subrecipe and not path[subrecipe.recipeID] then
                local subcost = X.Cost(subrecipe.recipeID, character, true, depth + 1, path)
                if subcost and subcost.priceable and subcost.perUnit and (not unit or subcost.perUnit < unit) then
                    unit, source = subcost.perUnit, "craft"
                end
            end
        end
        local held = E.Inventory.Owned(itemID, character)
        local paid = needed
        if cash then
            if owned[itemID] == nil then owned[itemID] = held end
            local allocated = min(needed, owned[itemID])
            paid, owned[itemID] = needed - allocated, owned[itemID] - allocated
        end
        local line = { itemID = itemID, quantity = needed, unitCost = unit, source = source,
            have = held, shortfall = max(0, needed - held), crafted = source == "craft" }
        line.lineCost = paid == 0 and 0 or (unit and unit * paid)
        result.reagents[#result.reagents + 1] = line
        if line.lineCost == nil then
            result.priceable = false
            result.unpriced[#result.unpriced + 1] = itemID
        else
            result.total = result.total + line.lineCost
            result.knownTotal = (result.knownTotal or 0) + line.lineCost
        end
    end
    path[recipeID] = nil
    if result.priceable then
        result.perUnit = result.total / result.yield
    else
        result.total = nil
        -- 品质槽未选不算不可定价：只要每个必需单位都有报价，这就是一份完整
        -- 的估算总成本（按每槽最便宜报价），冲级与利润都应使用它。
        if #result.unpriced == 0 and result.knownTotal then
            result.estimated = true
            result.perUnit = result.knownTotal / result.yield
        end
    end
    return result
end

function X.Cost(recipeID, character, forceMarket, depth, path, owned)
    character = character or E.character
    local recipe = E.Recipe(recipeID, character)
    if not recipe then return nil end
    return X.CostTable(recipe, character, forceMarket, depth, path, owned)
end

function X.Stock(itemID, character)
    character = character or E.character
    local record = E.db.characters[character] or {}
    local posted = record.posted and record.posted[itemID] or 0
    local inMail = E.Setting("countMailAsStock", true) and E.Inventory.Count(itemID, character, "mail") or 0
    local onHand = E.Inventory.Count(itemID, character) + E.Inventory.Count(itemID, character, "bank")
    local queued = 0
    for index = 1, #E.db.queue do
        local entry = E.db.queue[index]
        local recipe = E.Recipe(entry.recipeID, entry.character or E.character)
        if recipe and recipe.outputItemID == itemID and (entry.character or E.character) == character then
            queued = queued + entry.quantity * (recipe.quantityMin or 1)
        end
    end
    local key = ns.Store.Key(itemID)
    local limit = E.db.postLimits[key]
    if limit == nil then limit = E.db.postLimits[itemID] end
    if limit == nil then limit = E.Setting("maxPostedPerItem", 0) end
    return posted, onHand, inMail, queued, limit
end

function X.Craftable(recipe, character)
    if recipe.complete == false then return 0 end
    local count
    for index = 1, #(recipe.reagents or {}) do
        local reagent = recipe.reagents[index]
        local available = floor(E.Inventory.Count(reagent.itemID, character) / reagent.quantity)
        count = count and min(count, available) or available
    end
    return count or 0
end

function X.Analyse(recipeID, character, analysisMode)
    analysisMode = analysisMode == "vendor" and "vendor" or "auction"
    local recipe, owner = E.Recipe(recipeID, character)
    if not recipe then return nil end
    local record = E.db.characters[owner] or {}
    -- Profit measures the full materials consumed, even when procurement only budgets shortfalls.
    local cost = X.Cost(recipeID, owner, true)
    local totalCost = cost and (cost.total or (cost.estimated and cost.knownTotal or nil)) or nil
    local row = { recipeID = recipeID, name = recipe.name or tostring(recipeID), outputItemID = recipe.outputItemID,
        itemKey = itemKey(recipe.outputItemID),
        owner = owner, character = owner, ownerName = record.name or owner, isMine = owner == E.character,
        skillLineID = recipe.skillLineID, profession = recipe.profession, skillUp = recipe.skillUp or "unknown",
        skillUps = recipe.skillUps or 1, craftableNow = X.Craftable(recipe, owner),
        cost = cost, totalCost = totalCost, costPerUnit = cost and cost.perUnit,
        costEstimated = cost and cost.estimated or nil,
        partialCost = cost and not cost.priceable and not cost.estimated and cost.knownTotal or nil,
        priceable = false, reason = recipe.reason, analysisMode = analysisMode }
    if row.totalCost then row.costPerSkillUp = row.totalCost / row.skillUps end
    if not recipe.outputItemID then
        row.sellable = false
        row.reason = row.reason or (analysisMode == "vendor" and L["配方没有固定产物"] or L["配方没有可拍卖的固定产物"])
        return row
    end
    local bound = isBoundOnCreate(recipe.outputItemID)
    row.bindKnown = bound ~= nil
    row.soulbound = bound == true
    if bound and analysisMode ~= "vendor" then
        row.sellable, row.soulbound = false, true
        row.reason = L["制作产物为拾取绑定，无法出售"]
        return row
    end
    row.sellable = true
    row.posted, row.onHand, row.inMail, row.queued, row.postLimit = X.Stock(recipe.outputItemID, owner)
    row.stock = row.posted + row.onHand + row.inMail
    row.atPostLimit = row.postLimit > 0 and row.stock + row.queued >= row.postLimit
    local price
    if analysisMode == "vendor" then
        -- Output saleability does not depend on whether every reagent is priced.
        price = vendorSalePrice(recipe.outputItemID)
        row.vendorSaleKnown = price ~= nil
        row.unitRevenue, row.price = price, price
        row.yield = cost and cost.yield
        row.revenue = price and row.yield and price * row.yield or nil
    end
    local calculationCost = row.totalCost or row.partialCost
    if calculationCost == nil then row.reason = row.reason or L["某种材料暂无价格数据"]; return row end
    row.profitEstimated = row.partialCost ~= nil or row.costEstimated == true
    local detail = ns.Prices and ns.Prices.Get(recipe.outputItemID)
    row.liveCount = detail and (detail.bookQuantity or detail.quantity) or 0
    row.quantity = row.liveCount
    row.updated = detail and (detail.bookUpdated or detail.updated or detail.seen) or nil
    row.priceQuantity, row.priceUpdatedAt = row.liveCount, row.updated
    local rival = analysisMode ~= "vendor" and X.Price(recipe.outputItemID, "rival") or nil
    -- Full scans have no ownership split. Their current minimum is a quote;
    -- the historical EMA is a valuation and must not become an auction price.
    if analysisMode ~= "vendor" then price = rival or X.Price(recipe.outputItemID, "min") end
    if rival and ns.Store.GetDB().settings and ns.Store.GetDB().settings.undercut ~= false then
        price = max(1, floor(rival - E.Setting("undercutCopper", 1)))
    end
    if not price and analysisMode ~= "vendor" and E.Setting("priceUnscannedCrafts", true) then
        local marketCost = X.Cost(recipeID, owner, true)
        if marketCost and marketCost.perUnit then
            price = max(1, floor(marketCost.perUnit * (1 + E.Setting("unscannedMarkupPercent", 50) / 100)))
            row.priceDerived = true
        end
    end
    if not price then
        row.reason = analysisMode == "vendor" and L["产物暂无卖店价"] or L["产物暂无价格数据"]
        return row
    end
    -- Derived estimates stay here: they never write back into the price store.
    row.unitRevenue, row.price, row.yield = price, price, cost.yield
    row.revenue = price * cost.yield
    row.cut = analysisMode == "vendor" and 0 or row.revenue * E.Setting("auctionCut", 0.05)
    local deposit = E.db.deposits and E.db.deposits[recipe.outputItemID]
    if type(deposit) == "table" then
        deposit = deposit.duration == E.Setting("postDuration", 2) and deposit.unit or nil
    end
    row.depositKnown = analysisMode == "vendor" or type(deposit) == "number"
    row.deposit = analysisMode ~= "vendor" and row.depositKnown
        and deposit * cost.yield * max(1, E.Setting("expectedRelists", 1)) or 0
    row.profit = row.revenue - row.cut - calculationCost - row.deposit
    row.profitPerUnit = row.profit / cost.yield
    row.margin = row.profit / row.revenue
    row.roi = calculationCost > 0 and row.profit / calculationCost or 0
    row.priceable = true
    row.age = detail and detail.updated and max(0, E.Now() - detail.updated)
    row.stale = row.age == nil or row.age > E.Setting("staleAfterSeconds", 172800)
    row.recommended = row.skillUp ~= "trivial" and row.skillUp ~= "unknown" and row.profit >= E.Setting("minProfit", 0)
    row.rank = analysisMode == "vendor" and row.profit
        or row.profit / (1 + (row.stock + row.queued) * E.Setting("stockPenalty", 1))
    return row
end

function X.Ranked(options, leveling)
    options = options or {}
    local analysisMode = not leveling and options.analysisMode == "vendor" and "vendor" or "auction"
    local rows = {}
    local minProfit = options.minProfit
    if minProfit == nil then minProfit = analysisMode == "vendor" and 0 or E.Setting("minProfit", 0) end
    local minMargin = options.minMargin
    if minMargin == nil then minMargin = analysisMode == "vendor" and 0 or E.Setting("minMarginPercent", 0) end
    local maxMargin = tonumber(options.maxMargin)
    local minLiveCount = max(0, tonumber(options.minLiveCount) or 0)
    local search = type(options.search) == "string" and options.search:lower() or ""
    local recipes = E.AllRecipes(options.accountWide == true)
    for index = 1, #recipes do
        local entry = recipes[index]
        local row = X.Analyse(entry.recipeID, entry.character, analysisMode)
        local include = row and (search == "" or row.name:lower():find(search, 1, true))
            and (not options.skillLineID or options.skillLineID == row.skillLineID)
            and (not options.skillLineIDs or options.skillLineIDs[row.skillLineID] == true)
        if include and leveling and options.includeTrivial ~= true then include = row.skillUp ~= "trivial" end
        if include and not leveling then
            if row.sellable == false then include = false
            elseif not row.priceable then
                include = options.showUnpriced == true or (analysisMode == "vendor" and row.vendorSaleKnown == true)
                if analysisMode == "vendor" and (options.minProfit ~= nil or options.minMargin ~= nil or maxMargin) then
                    include = false
                end
            else
                if not options.showLoss and row.profit < minProfit then include = false end
                if include and row.margin < minMargin / 100 then include = false end
                if include and maxMargin and row.margin > maxMargin / 100 then include = false end
                if include and analysisMode ~= "vendor" and (row.liveCount or 0) < minLiveCount then include = false end
            end
            if include and analysisMode ~= "vendor" and row.atPostLimit
                and E.Setting("hideAtPostLimit", true) and not options.ignorePostLimit then
                include = false
            end
        end
        if include and options.craftableOnly and (row.craftableNow or 0) < 1 then include = false end
        if include then rows[#rows + 1] = row end
    end
    local sortBy = options.sortBy or (leveling and "costPerSkillUp" or "rank")
    local descending = options.descending
    if descending == nil then descending = options.sortDescending end
    if descending == nil then descending = not leveling end
    local aliases = { cost = "totalCost", sale = "revenue", make = "craftableNow",
        chance = "skillUp", age = "updated", posted = "stock", who = "ownerName" }
    sortBy = aliases[sortBy] or sortBy
    sort(rows, function(a, b)
        local av, bv = a[sortBy], b[sortBy]
        if av == nil or bv == nil then
            if av ~= bv then return av ~= nil end
        elseif type(av) == type(bv) and av ~= bv then
            if type(av) == "string" then av, bv = av:lower(), bv:lower() end
            if descending then return av > bv end
            return av < bv
        end
        if a.name ~= b.name then return (a.name or "") < (b.name or "") end
        if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
        return a.owner < b.owner
    end)
    return rows
end

--------------------------------------------------------------------------------
-- The leveling order and the skill-up plan.
--
-- The Profit list asks what is worth making for gold. Leveling asks a
-- different question: which of the crafts you know will still raise your
-- skill, and which of those costs least. So the order is the skill-up colour
-- first (orange, then yellow, then green, grey last) and cost second, exactly
-- the ranking the original Blackthornes LevelUp tab used. An unread colour
-- sits after green and before grey: it may well be orange, and hiding it on a
-- guess would be worse than showing it lower down.
--------------------------------------------------------------------------------

local BAND = { optimal = 1, medium = 2, easy = 3, unknown = 4, trivial = 5 }
X.BAND = BAND

local function itemKeyOf(itemID)
    return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

function X.BandOf(row)
    return BAND[row and row.skillUp or "unknown"] or BAND.unknown
end

-- Unpriced crafts fall behind every priced one in their band: treating a
-- missing price as free would put the craft you know least about on top.
-- Every tie falls through to the recipe ID so `pairs` order cannot make the
-- list reshuffle itself between refreshes.
function X.CompareLeveling(a, b)
    local bandA, bandB = X.BandOf(a), X.BandOf(b)
    if bandA ~= bandB then return bandA < bandB end
    local costA, costB = a.costPerSkillUp or a.totalCost, b.costPerSkillUp or b.totalCost
    if costA and not costB then return true end
    if costB and not costA then return false end
    if costA and costB and costA ~= costB then return costA < costB end
    if a.name ~= b.name then return (a.name or "") < (b.name or "") end
    return (a.recipeID or 0) < (b.recipeID or 0)
end

-- 12.1 does not hand out yellow/green breakpoints, but it does give the gray
-- point (recipeInfo.maxTrivialLevel) and the colour at the current skill. The
-- plan therefore decays each recipe's chance linearly from its current colour
-- down to zero at its gray point: a craft that is orange today does not stay
-- orange, so the route must rotate instead of dumping every point on one
-- recipe. Switching follows the original Blackthornes hysteresis: keep the
-- incumbent unless another craft is 12% cheaper per expected point, and never
-- let one recipe take more than PLAN_MAX_CONSECUTIVE points in a row.
local TIER_CHANCE = { optimal = 1, medium = 0.7, easy = 0.35, unknown = 0.8 }
local PLAN_MAX_CONSECUTIVE = 5
local PLAN_SWITCH_TOLERANCE = 1.12
-- Recipes whose gray point was never read keep a conservative assumed span.
local GRAY_FALLBACK = { optimal = 15, medium = 10, easy = 6, unknown = 12 }

local function planSkillLine(skillLineID)
    local best, fallback
    for index = 1, #(E.current and E.current.professions or {}) do
        local entry = E.current.professions[index]
        if entry and (skillLineID == nil or entry.professionID == skillLineID or entry.skillLineID == skillLineID) then
            local cap = tonumber(entry.maxSkillLevel) or 0
            if cap > 0 and entry.learned ~= false
                and (not best or cap > (tonumber(best.maxSkillLevel) or 0)
                    or (cap == (tonumber(best.maxSkillLevel) or 0)
                        and (tonumber(entry.skillLevel) or 0) < (tonumber(best.skillLevel) or 0))) then
                best = entry
            end
            fallback = fallback or entry
        end
    end
    return best or fallback
end

local function planCandidates(rows, skill)
    local candidates = {}
    for index = 1, #rows do
        local row = rows[index]
        local recipe = E.Recipe(row.recipeID, row.owner)
        if recipe and (#(recipe.reagents or {}) > 0 or #(recipe.slots or {}) > 0) then
            local gray = tonumber(recipe.gray) or 0
            if gray <= skill then gray = skill + (GRAY_FALLBACK[row.skillUp or "unknown"] or 12) end
            candidates[#candidates + 1] = { row = row, gray = gray,
                baseChance = TIER_CHANCE[row.skillUp or "unknown"] or 0.8,
                skillUps = max(1, row.skillUps or 1) }
        end
    end
    return candidates
end

-- Expected crafts for one point of the chosen candidate at `skill`, or the
-- per-point cost used to compare candidates. Chances below 5% drop out: the
-- linear decay must not creep towards the gray point forever.
local function candidatePointCost(candidate, skill, start)
    local remaining = candidate.gray - skill
    if remaining <= 0 then return nil end
    local chance = candidate.baseChance * remaining / (candidate.gray - start)
    if chance < 0.05 then return nil end
    if chance > 1 then chance = 1 end
    local pointsPerCraft = chance * candidate.skillUps
    if not candidate.row.totalCost then return nil end
    return candidate.row.totalCost / pointsPerCraft, pointsPerCraft
end

function X.Plan(options)
    options = options or {}
    local result = { ok = false, steps = {}, materials = {}, totals = { cost = 0, unpriced = 0, crafts = 0 } }
    local line = planSkillLine(options.skillLineID)
    local skill = line and tonumber(line.skillLevel) or nil
    if not skill then
        result.reason = L["尚未读取技能等级，请打开一次专业窗口。"]
        return result
    end
    local maxSkill = line and tonumber(line.maxSkillLevel) or 0
    local points = E.Integer(options.targetPoints, 1) or 10
    local target = maxSkill > 0 and min(skill + points, maxSkill) or skill + points
    -- 全部专业 without a choice plans for the auto-picked line: its recipes are
    -- what the colours and costs describe, so the steps must not cross lines.
    local filterID = options.skillLineID or line.professionID or line.skillLineID
    result.ok = true
    result.skillLineID = filterID
    result.profession = line.name
    result.skill, result.maxSkill, result.target = skill, maxSkill, target
    local gap = target - skill
    if gap <= 0 then
        result.reason = L["技能已达到目标，请重新调整目标点数。"]
        return result
    end
    local rows = X.Ranked({ skillLineID = filterID, includeTrivial = false }, true)
    local candidates = planCandidates(rows, skill)
    local covered, stepIndex = 0, 0
    local incumbent, incumbentPoints, incumbentCrafts

    local function flushIncumbent()
        if not incumbent then return end
        stepIndex = stepIndex + 1
        local row = incumbent.row
        local recipe = E.Recipe(row.recipeID, row.owner)
        result.steps[stepIndex] = { recipeID = row.recipeID, name = row.name,
            outputItemID = row.outputItemID,
            itemKey = row.outputItemID and itemKeyOf(row.outputItemID) or nil,
            tier = row.skillUp, skillLineID = row.skillLineID, profession = row.profession, owner = row.owner,
            count = incumbentCrafts, unitCost = row.totalCost,
            cost = row.totalCost and row.totalCost * incumbentCrafts or nil,
            craftableNow = row.craftableNow or 0, gray = incumbent.gray,
            yield = recipe and max(1, tonumber(recipe.quantityMin) or 1) or 1 }
        result.totals.crafts = result.totals.crafts + incumbentCrafts
        incumbent, incumbentPoints, incumbentCrafts = nil, nil, nil
    end

    -- 逐点推进：每个技能点上选"每期望点成本"最低的配方；颜色随技能上升而
    -- 衰减，滞回阈值保证路线在多个配方间轮换而不是盯住一个。
    local guard = 0
    while covered < gap and guard < 20000 do
        guard = guard + 1
        local current = skill + covered
        local bestChoice, bestCost, incumbentCost
        for index = 1, #candidates do
            local candidate = candidates[index]
            local pointCost = candidatePointCost(candidate, current, skill)
            if pointCost then
                if candidate == incumbent then incumbentCost = pointCost end
                if not bestCost or pointCost < bestCost then bestChoice, bestCost = candidate, pointCost end
            end
        end
        if not bestChoice then break end
        local chosen
        if incumbent and incumbentCost and incumbentPoints < PLAN_MAX_CONSECUTIVE
            and incumbentCost <= bestCost * PLAN_SWITCH_TOLERANCE then
            chosen = incumbent
        else
            chosen = bestChoice
            -- 连做上限到了：即便原配方仍然最便宜，也让次优的顶上，路线必须轮换。
            if chosen == incumbent and incumbentPoints and incumbentPoints >= PLAN_MAX_CONSECUTIVE then
                local otherChoice, otherCost
                for index = 1, #candidates do
                    local candidate = candidates[index]
                    if candidate ~= incumbent then
                        local pointCost = candidatePointCost(candidate, current, skill)
                        if pointCost and (not otherCost or pointCost < otherCost) then
                            otherChoice, otherCost = candidate, pointCost
                        end
                    end
                end
                if otherChoice then chosen = otherChoice end
            end
        end
        if chosen ~= incumbent then flushIncumbent() end
        incumbent = chosen
        local pointsPerCraft = select(2, candidatePointCost(chosen, current, skill))
        local gain = pointsPerCraft or 1
        incumbentPoints = (incumbentPoints or 0) + gain
        incumbentCrafts = (incumbentCrafts or 0) + 1
        covered = covered + gain
        if covered >= gap then flushIncumbent() end
    end
    flushIncumbent()

    -- 采购解析：按步骤顺序走查，产出进入复用池，后步优先消耗前步产物
    -- （成品复用）；缺口的材料若可由已知配方制作且物料绑定或自制更便宜，
    -- 就在其使用点之前插入"备料"步骤（过渡材料），其余进入采购清单。
    X.CompileRoute(result)
    result.covered = min(covered, gap)
    result.gap = gap
    for index = 1, #result.materials do
        local material = result.materials[index]
        if material.unitCost then
            material.cost = material.unitCost * material.shortfall
            result.totals.cost = result.totals.cost + material.cost
        else
            material.cost = nil
            result.totals.unpriced = result.totals.unpriced + 1
        end
    end
    sort(result.materials, function(a, b)
        local ac, bc = a.cost, b.cost
        if ac and not bc then return true end
        if bc and not ac then return false end
        if ac and bc and ac ~= bc then return ac > bc end
        if a.shortfall ~= b.shortfall then return (a.shortfall or 0) > (b.shortfall or 0) end
        return (a.name or "") < (b.name or "")
    end)
    if covered < gap then
        result.reason = format(L["当前配方最多覆盖 %d 点，可学习以下配方后重新生成。"], result.covered)
        -- 未学习的配方按灰点排序，提示路线还能怎么继续。
        result.learnable = {}
        local learnable = E.current and E.current.learnable
        for recipeID, entry in pairs(learnable or {}) do
            if type(entry) == "table" and (tonumber(entry.gray) or 0) > skill then
                result.learnable[#result.learnable + 1] = { recipeID = recipeID, name = entry.name,
                    outputItemID = entry.outputItemID,
                    itemKey = entry.outputItemID and itemKeyOf(entry.outputItemID) or nil,
                    gray = tonumber(entry.gray), skillLineID = options.skillLineID or filterID }
            end
        end
        sort(result.learnable, function(a, b)
            if a.gray ~= b.gray then return (a.gray or 0) < (b.gray or 0) end
            return (a.name or "") < (b.name or "")
        end)
        for index = 9, #result.learnable do result.learnable[index] = nil end
    end
    return result
end

-- Route compilation shared by the algorithmic plan and the built-in guides:
-- walk the steps in order, pool every step's products so later steps reuse
-- them (成品复用), cover shortfalls from stock, then from inline preparation
-- steps for bindable or cheaper-to-craft materials (过渡材料), and only buy
-- what is left over.
function X.CompileRoute(result)
    local pool = {}
    local purchases = {}
    local matIndex = 0

    local function addPurchase(line, quantity, owner)
        local material = purchases[line.itemID]
        if not material then
            matIndex = matIndex + 1
            material = { itemID = line.itemID, itemKey = itemKeyOf(line.itemID),
                name = E.ItemName(line.itemID), shortfall = 0,
                have = E.Inventory.Owned(line.itemID, owner),
                unitCost = line.unitCost, source = line.source }
            purchases[line.itemID] = material
            result.materials[matIndex] = material
        end
        material.shortfall = material.shortfall + quantity
        if line.unitCost and not material.unitCost then material.unitCost = line.unitCost end
        if line.source and material.source == nil then material.source = line.source end
    end

    local function resolveStep(step, depth)
        local costDetail
        if step.recipe then
            costDetail = X.CostTable(step.recipe, step.owner, true)
        elseif step.recipeID then
            costDetail = X.Cost(step.recipeID, step.owner, true)
        end
        -- 静态指引材料兜底：没有收割记录/未学习配方时按 wow.gg 数量采购，
        -- 不能让配方缺失从材料表里消失。
        local reagents = costDetail and costDetail.reagents
        if (not reagents or #reagents == 0) and type(step.materials) == "table" then
            reagents = {}
            for materialIndex = 1, #step.materials do
                local material = step.materials[materialIndex]
                reagents[#reagents + 1] = {
                    itemID = material.itemID, quantity = material.quantity or 0,
                    unitCost = X.ReagentPrice(material.itemID),
                    source = "auction" }
            end
        end
        for lineIndex = 1, #(reagents or {}) do
            local line = reagents[lineIndex]
            local need = line.quantity * step.count
            local fromPool = min(pool[line.itemID] or 0, need)
            if fromPool > 0 then pool[line.itemID] = pool[line.itemID] - fromPool end
            local remainder = need - fromPool
            local fromOwned = min(E.Inventory.Owned(line.itemID, step.owner), remainder)
            local shortfall = remainder - fromOwned
            if shortfall > 0 and depth < 2 then
                local sub = E.Recipes.ForItem(line.itemID, step.owner)
                local craftable = sub and sub.recipeID ~= step.recipeID
                    and (#(sub.reagents or {}) + #(sub.slots or {}) > 0)
                if craftable then
                    local bound = isBoundOnCreate(line.itemID)
                    local subCost = X.Cost(sub.recipeID, step.owner, true)
                    local craftWorth = bound == true or not line.unitCost
                        or (subCost and subCost.perUnit and subCost.perUnit < line.unitCost)
                    if craftWorth then
                        local subYield = max(1, tonumber(sub.quantityMin) or 1)
                        local prep = { recipeID = sub.recipeID, name = sub.name,
                            outputItemID = sub.outputItemID,
                            itemKey = sub.outputItemID and itemKeyOf(sub.outputItemID) or nil,
                            tier = sub.skillUp, skillLineID = sub.skillLineID,
                            profession = sub.profession, owner = step.owner,
                            count = ceil(shortfall / subYield), kind = "prepare",
                            unitCost = subCost and (subCost.total or (subCost.estimated and subCost.knownTotal or nil)) or nil,
                            yield = subYield }
                        prep.cost = prep.unitCost and prep.unitCost * prep.count or nil
                        table.insert(result.steps, step.walkIndex, prep)
                        result.totals.crafts = result.totals.crafts + prep.count
                        resolveStep(prep, depth + 1)
                        -- 备料产物只补刚才的缺口部分：池子里已有的消耗不能重复扣。
                        local extraPool = min(pool[line.itemID] or 0, remainder)
                        if extraPool > 0 then pool[line.itemID] = pool[line.itemID] - extraPool end
                        shortfall = max(0, remainder - extraPool - fromOwned)
                    end
                end
            end
            if shortfall > 0 then addPurchase(line, shortfall, step.owner) end
        end
        if step.outputItemID then
            pool[step.outputItemID] = (pool[step.outputItemID] or 0) + (step.yield or 1) * step.count
        end
        step.resolved = true
    end

    local walkIndex = 1
    while walkIndex <= #result.steps do
        local step = result.steps[walkIndex]
        step.walkIndex = walkIndex
        if not step.resolved then resolveStep(step, 0) end
        walkIndex = walkIndex + 1
    end
    for index = 1, #result.steps do result.steps[index].walkIndex = nil end
    for index = 1, #result.materials do
        local material = result.materials[index]
        if material.unitCost then
            material.cost = material.unitCost * material.shortfall
            result.totals.cost = result.totals.cost + material.cost
        else
            material.cost = nil
            result.totals.unpriced = result.totals.unpriced + 1
        end
    end
    sort(result.materials, function(a, b)
        local ac, bc = a.cost, b.cost
        if ac and not bc then return true end
        if bc and not ac then return false end
        if ac and bc and ac ~= bc then return ac > bc end
        if a.shortfall ~= b.shortfall then return (a.shortfall or 0) > (b.shortfall or 0) end
        return (a.name or "") < (b.name or "")
    end)
    return result
end
