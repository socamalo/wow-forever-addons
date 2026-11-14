-- Blackthornes-derived dependency planning. Only manual intent is persisted.
-- A shared inventory ledger prevents two branches spending the same materials.
local addonName, ns = ... -- luacheck: ignore addonName
local pairs, tostring, type = pairs, tostring, type
local min, max, ceil, abs = math.min, math.max, math.ceil, math.abs
local sort, remove = table.sort, table.remove
local E = ns.ProfessionEngine
local L = ns.L
local Q = {}
E.Queue = Q

function Q.Add(recipeID, count, character)
    count, character = E.Integer(count, 1), character or E.character
    if not count or count > 100000 then return false, L["制作数量无效"] end
    if not E.Recipe(recipeID, character) then return false, L["该角色未记录配方"] end
    for index = 1, #E.db.queue do
        local entry = E.db.queue[index]
        if entry.recipeID == recipeID and (entry.character or E.character) == character then
            entry.quantity = min(100000, entry.quantity + count)
            E.Changed()
            return true
        end
    end
    E.db.queue[#E.db.queue + 1] = { recipeID = recipeID, quantity = count, character = character }
    E.Changed()
    return true
end

function Q.Set(index, count)
    index, count = E.Integer(index, 1), E.Integer(count, 0)
    if not index or not count or count > 100000 or not E.db.queue[index] then return false end
    if count == 0 then remove(E.db.queue, index) else E.db.queue[index].quantity = count end
    E.Changed()
    return true
end

function Q.Build()
    local rows, materials, remaining, derived = {}, {}, {}, {}
    local unresolved = 0
    local function material(itemID, character)
        local key = character .. ":" .. itemID
        local row = materials[key]
        if not row then
            local unit, source = E.Economics.ReagentPrice(itemID)
            local auctionUnit = E.Economics.Price(itemID, "min")
            local vendorRecord = E.db.vendorPrices[itemID]
            local vendorUnit = type(vendorRecord) == "table" and vendorRecord.unitPrice or vendorRecord
            row = { itemID = itemID, itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
                character = character, needed = 0, have = 0, queuedToMake = 0, shortfall = 0,
                inBags = E.Inventory.Count(itemID, character), inBank = E.Inventory.Count(itemID, character, "bank"),
                inMail = E.Setting("countMailAsStock", true) and E.Inventory.Count(itemID, character, "mail") or 0,
                onAlts = E.Inventory.AltCount(itemID), unitCost = unit, source = source, fromVendor = source == "vendor",
                vendorUnit = vendorUnit, auctionUnit = auctionUnit,
                vendorLimited = type(vendorRecord) == "table" and vendorRecord.limited == true }
            materials[key] = row
            remaining[key] = E.Inventory.Owned(itemID, character)
        end
        return row, key
    end
    local expand
    expand = function(recipe, quantity, character, depth, path)
        if recipe.complete == false then unresolved = unresolved + 1; return end
        path[recipe.recipeID] = true
        for reagentIndex = 1, #(recipe.reagents or {}) do
            local reagent = recipe.reagents[reagentIndex]
            local row, key = material(reagent.itemID, character)
            local need = reagent.quantity * quantity
            local held = min(need, remaining[key])
            remaining[key] = remaining[key] - held
            row.needed, row.have = row.needed + need, row.have + held
            local missing = need - held
            local sub = E.Recipes.ForItem(reagent.itemID, character)
            local craft = missing > 0 and E.Setting("autoQueueSubCrafts", true) and depth < 3
                and sub and not path[sub.recipeID]
            if craft then
                local cost = E.Economics.Cost(sub.recipeID, character, true)
                local bought = E.Economics.ReagentPrice(reagent.itemID)
                craft = cost and cost.priceable and cost.perUnit and (not bought or cost.perUnit < bought)
            end
            if craft then
                local count = ceil(missing / max(1, sub.quantityMin or 1))
                local depKey = character .. ":" .. sub.recipeID
                local dep = derived[depKey]
                if not dep then
                    dep = { recipeID = sub.recipeID, name = sub.name, character = character,
                        outputItemID = sub.outputItemID,
                        itemKey = sub.outputItemID and { itemID = sub.outputItemID, itemLevel = 0,
                            itemSuffix = 0, battlePetSpeciesID = 0 } or nil,
                        ownerName = (E.db.characters[character] or {}).name or character,
                        quantity = 0, isDependency = true, depth = depth + 1,
                        craftableNow = E.Economics.Craftable(sub, character) }
                    derived[depKey] = dep
                end
                dep.quantity, dep.depth = dep.quantity + count, max(dep.depth, depth + 1)
                row.queuedToMake = row.queuedToMake + missing
                remaining[key] = remaining[key] + count * max(1, sub.quantityMin or 1) - missing
                expand(sub, count, character, depth + 1, path)
            else row.shortfall = row.shortfall + missing end
        end
        path[recipe.recipeID] = nil
    end
    for index = 1, #E.db.queue do
        local entry = E.db.queue[index]
        local character = entry.character or E.character
        local recipe = E.Recipe(entry.recipeID, character)
        local cost = recipe and E.Economics.Cost(entry.recipeID, character)
        rows[#rows + 1] = { index = index, recipeID = entry.recipeID,
            name = recipe and recipe.name or tostring(entry.recipeID), quantity = entry.quantity,
            outputItemID = recipe and recipe.outputItemID,
            itemKey = recipe and recipe.outputItemID and { itemID = recipe.outputItemID,
                itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } or nil,
            character = character, ownerName = (E.db.characters[character] or {}).name or character,
            craftableNow = recipe and E.Economics.Craftable(recipe, character) or 0,
            reason = not recipe and L["配方尚未读取"] or recipe.reason,
            totalCost = cost and cost.total and cost.total * entry.quantity, isDependency = false }
        if recipe then expand(recipe, entry.quantity, character, 0, {}) else unresolved = unresolved + 1 end
    end
    local dependencies = {}
    for key, dep in pairs(derived) do -- luacheck: ignore key
        dependencies[#dependencies + 1] = dep
    end
    sort(dependencies, function(a, b)
        if a.depth ~= b.depth then return a.depth > b.depth end
        if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
        return a.character < b.character
    end)
    for index = 1, #rows do dependencies[#dependencies + 1] = rows[index] end
    local shopping = {}
    for key, row in pairs(materials) do -- luacheck: ignore key
        row.estimatedCost = row.unitCost and row.unitCost * row.shortfall
        if row.vendorUnit and row.auctionUnit and row.shortfall > 0 then
            row.savingTotal = max(0, abs(row.vendorUnit - row.auctionUnit) * row.shortfall)
        end
        row.needsBankTrip = row.shortfall == 0 and row.inBags < row.needed - row.queuedToMake
        row.name = E.ItemName(row.itemID)
        shopping[#shopping + 1] = row
    end
    sort(shopping, function(a, b)
        if a.shortfall ~= b.shortfall then return a.shortfall > b.shortfall end
        if a.itemID ~= b.itemID then return a.itemID < b.itemID end
        return a.character < b.character
    end)
    return dependencies, shopping, unresolved
end
