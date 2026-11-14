-- luacheck: ignore addonName
local addonName, ns = ...
local type, tonumber, tostring, pairs, ipairs = type, tonumber, tostring, pairs, ipairs
local floor, max, huge = math.floor, math.max, math.huge
local sort, insert, remove, concat = table.sort, table.insert, table.remove, table.concat
local match, gsub = string.match, string.gsub
local byte, char, format, find, gmatch, sub = string.byte, string.char, string.format, string.find, string.gmatch, string.sub
local time = time
local Store = {}
local L = ns.L
ns.Store = Store
local root, market
local RECENT_LIMIT, QUERY_LIMIT = 30, 20
local MAX_INTEGER = 9007199254740991
local TRANSFER_BYTES, TRANSFER_ITEMS = 65536, 200

local function now()
    return (ns.Now or time)()
end

local function trimmedText(value)
    if type(value) ~= "string" then return nil end
    local text = gsub(gsub(value, "^%s+", ""), "%s+$", "")
    if text == "" then return nil end
    return text
end

local function integer(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == huge or value == -huge then return nil end
    if value < minimum or value > MAX_INTEGER or floor(value) ~= value then return nil end
    return value
end

local function identity(value)
    if type(value) == "string" then
        local itemID, itemLevel, itemSuffix, battlePetSpeciesID = match(value, "^(%d+):(%d+):(%d+):(%d+)$")
        if not itemID then return nil end
        value = { itemID = itemID, itemLevel = itemLevel, itemSuffix = itemSuffix,
            battlePetSpeciesID = battlePetSpeciesID }
    elseif type(value) == "number" then
        value = { itemID = value }
    elseif type(value) ~= "table" then
        return nil
    end
    local itemID = integer(value.itemID, 1)
    local itemLevel = integer(value.itemLevel or 0, 0)
    local itemSuffix = integer(value.itemSuffix or 0, 0)
    local battlePetSpeciesID = integer(value.battlePetSpeciesID or 0, 0)
    if not itemID or not itemLevel or not itemSuffix or not battlePetSpeciesID then return nil end
    return { itemID = itemID, itemLevel = itemLevel, itemSuffix = itemSuffix,
        battlePetSpeciesID = battlePetSpeciesID }
end

function Store.Key(itemKey)
    local item = identity(itemKey)
    if not item then return nil end
    return concat({ item.itemID, item.itemLevel, item.itemSuffix, item.battlePetSpeciesID }, ":")
end


---Initializes a versioned database; caller supplies a region/realm market scope.
---legacyScope (e.g. a pre-faction "region:realm" key) migrates into scope once:
---adopted while the target is still empty, always removed afterwards so both
---factions never keep duplicate mixed-market data on disk.
function Store.Init(db, scope, legacyScope)
    root = type(db) == "table" and db or {}
    root.version = 1
    root.scopes = type(root.scopes) == "table" and root.scopes or {}
    scope = tostring(scope or "default")
    root.scopes[scope] = root.scopes[scope] or {}
    if legacyScope ~= nil then
        legacyScope = tostring(legacyScope)
        local legacy = legacyScope ~= scope and root.scopes[legacyScope] or nil
        if type(legacy) == "table" then
            local target = root.scopes[scope]
            if next(target.items or {}) == nil and next(target.lists or {}) == nil then
                root.scopes[scope] = legacy
            end
            root.scopes[legacyScope] = nil
        end
    end
    market = root.scopes[scope]
    market.items = market.items or {}
    market.lists = market.lists or {}
    market.presetInstallations = market.presetInstallations or {}
    market.recents = market.recents or {}
    market.queries = market.queries or {}
    market.nextListID = integer(market.nextListID, 1) or 1
    for id, list in pairs(market.lists) do
        if type(list) == "table" and list.temporary == true then
            market.lists[id] = nil
        else
            local numericID = tonumber(id)
            if numericID then market.nextListID = max(market.nextListID, numericID + 1) end
        end
    end
    ns.Prices.Bind(root, scope)
    while #market.recents > RECENT_LIMIT do remove(market.recents) end
    while #market.queries > QUERY_LIMIT do remove(market.queries) end
    return root
end

-- Compatibility facade: all price observations and analytics have one owner.
function Store.Observe(...) return ns.Prices.Observe(...) end
function Store.Trend(...) return ns.Prices.Trend(...) end
function Store.BestHours(...) return ns.Prices.BestHours(...) end
function Store.CreateList(name, temporary)
    name = trimmedText(name)
    if not market or not name then return nil end
    local id = market.nextListID
    market.nextListID = id + 1
    local list = { id = id, name = name, items = {}, temporary = temporary == true or nil }
    market.lists[id] = list
    return list
end

function Store.RenameList(id, name)
    local list = market and market.lists[id]
    name = trimmedText(name)
    if not list or not name then return false end
    list.name = name
    return true
end

function Store.SetListItem(id, itemKey, name, quantity, maxUnitPrice)
    local list = market and market.lists[id]
    local key = Store.Key(itemKey)
    quantity = integer(quantity, 0)
    if not list or not key or not quantity then return false end
    if quantity == 0 then list.items[key] = nil; return true end
    if maxUnitPrice ~= nil then
        maxUnitPrice = integer(maxUnitPrice, 0)
        if not maxUnitPrice then return false end
    end
    local entry = list.items[key]
    if not entry then
        entry = ns.Presets and ns.Presets.Entry(list, identity(itemKey).itemID) or {}
    end
    entry.key, entry.itemKey = key, identity(itemKey)
    entry.name, entry.quantity, entry.maxUnitPrice = name or entry.name or key, quantity, maxUnitPrice
    list.items[key] = entry
    return true
end

function Store.DeleteList(id)
    if not market or not market.lists[id] then return false end
    market.lists[id] = nil
    return true
end

function Store.SetRestockIncluded(id, itemKey, enabled)
    local list = market and market.lists[id]
    local key = Store.Key(itemKey)
    local entry = list and key and list.items[key]
    if not entry or not entry.recipeMaterial or type(enabled) ~= "boolean" then return false end
    entry.includeInRestock = enabled
    return true
end

local function recipeMaterialMetadata(entry, material, order, included)
    entry.recipeMaterial = true
    entry.includeInRestock = included
    entry.groupID, entry.groupName, entry.groupOrder = "recipe_materials", "配方材料", 1
    entry.itemOrder, entry.slotIndex = order, material.slotIndex
end

-- Recipe sourced lists are kept as ordinary shopping lists with a small
-- association record. This lets users edit quantities and price caps while
-- still allowing the tracker to find the list when a recipe is untracked.
function Store.FindRecipeList(recipeID, isRecraft)
    recipeID = integer(recipeID, 1)
    if not market or not recipeID then return nil end
    for id, list in pairs(market.lists) do -- luacheck: ignore id
        local recipe = type(list) == "table" and list.recipe
        if type(recipe) == "table" and tonumber(recipe.recipeID) == recipeID
            and recipe.isRecraft == (isRecraft == true) then
            return list
        end
    end
    return nil
end

function Store.CreateRecipeList(recipe, materials)
    if type(recipe) ~= "table" or type(materials) ~= "table" then return nil, L["配方材料数据无效"] end
    local recipeID = integer(recipe.recipeID, 1)
    if not recipeID or not market then return nil, L["价格库尚未初始化"] end
    local isRecraft = recipe.isRecraft == true
    local existing = Store.FindRecipeList(recipeID, isRecraft)
    if existing then return existing, false end
    local name = trimmedText(recipe.name) or (format(L["配方 %s"], tostring(recipeID)))
    local list = Store.CreateList(format(L["制作：%s"], name))
    if not list then return nil, L["无法创建购物清单"] end
    list.recipe = { recipeID = recipeID, isRecraft = isRecraft,
        outputItemID = integer(recipe.outputItemID, 1), name = name }
    for index, material in ipairs(materials) do
        if type(material) == "table" then
            local itemKey = material.itemKey or material.itemID
            local quantity = integer(material.quantity or material.qty, 1)
            if itemKey and quantity then
                local itemName = trimmedText(material.name) or (format(L["物品 %s"], tostring(material.itemID or itemKey)))
                if not Store.SetListItem(list.id, itemKey, itemName, quantity, material.maxUnitPrice) then
                    Store.DeleteList(list.id)
                    return nil, format(L["第 %s 项材料无效"], tostring(index))
                end
                recipeMaterialMetadata(list.items[Store.Key(itemKey)], material, index, material.includeInRestock ~= false)
            end
        end
    end
    list.recipe.materialVariants = 1
    return list, true
end

-- A one-time additive migration: existing entries keep quantities, caps and
-- opt-ins; newly exposed alternatives never broaden a user's purchase intent.
function Store.SyncRecipeMaterials(id, materials)
    local list = market and market.lists[id]
    if not list or not list.recipe or list.recipe.materialVariants == 1
        or type(materials) ~= "table" or #materials == 0 then return false end
    for index, material in ipairs(materials) do
        local itemKey = material.itemKey or material.itemID
        local key = Store.Key(itemKey)
        local quantity = integer(material.quantity or material.qty, 1)
        if key and quantity then
            local entry = list.items[key]
            local included = entry and entry.includeInRestock ~= false or false
            if not entry then
                Store.SetListItem(id, itemKey, material.name, quantity, material.maxUnitPrice)
                entry = list.items[key]
            end
            if entry then recipeMaterialMetadata(entry, material, index, included) end
        end
    end
    list.recipe.materialVariants = 1
    return true
end

function Store.DeleteRecipeList(recipeID, isRecraft)
    local list = Store.FindRecipeList(recipeID, isRecraft)
    if not list then return false end
    return Store.DeleteList(list.id)
end

local function validUTF8(text)
    local index = 1
    while index <= #text do
        local lead = byte(text, index)
        local width
        local lower, upper = 128, 191
        if lead == 0 then return false
        elseif lead < 128 then width = 1
        elseif lead >= 194 and lead <= 223 then width = 2
        elseif lead >= 224 and lead <= 239 then
            width = 3
            if lead == 224 then lower = 160 elseif lead == 237 then upper = 159 end
        elseif lead >= 240 and lead <= 244 then
            width = 4
            if lead == 240 then lower = 144 elseif lead == 244 then upper = 143 end
        else return false end
        if index + width - 1 > #text then return false end
        for offset = 1, width - 1 do
            local continuation = byte(text, index + offset)
            local low, high = offset == 1 and lower or 128, offset == 1 and upper or 191
            if continuation < low or continuation > high then return false end
        end
        index = index + width
    end
    return true
end

local function encodeName(text)
    if not trimmedText(text) or not validUTF8(text) then return nil end
    return (gsub(text, "[%%|%c]", function(value) return format("%%%02X", byte(value)) end))
end

local function decodeName(text)
    if find(text, "%c") or find(gsub(text, "%%[%x][%x]", ""), "%%") then return nil end
    local decoded = gsub(text, "%%([%x][%x])", function(value) return char(tonumber(value, 16)) end)
    if not trimmedText(decoded) or not validUTF8(decoded) then return nil end
    return decoded
end

local function decimalInteger(text, minimum)
    if type(text) ~= "string" or not match(text, "^%d+$") then return nil end
    return integer(text, minimum)
end

local function decimalGold(text)
    local whole, fraction = match(text, "^(%d+)%.(%d+)$")
    if not whole then whole, fraction = match(text, "^(%d+)$"), "" end
    if not whole or #fraction > 4 then return nil end
    local gold = decimalInteger(whole, 0)
    if not gold or gold > floor(MAX_INTEGER / 10000) then return nil end
    local copper = tonumber(fraction .. sub("0000", #fraction + 1))
    return integer(gold * 10000 + copper, 0)
end

---EA12|1|escaped-name, followed by key|quantity|copper-or-dash|escaped-item-name.
function Store.ExportList(id)
    local list = market and market.lists[id]
    if not list then return nil, L["清单不存在"] end
    local name = encodeName(list.name)
    if not name then return nil, L["清单名称不是有效的 UTF-8 文本"] end
    local keys = {}
    for key, entry in pairs(list.items) do
        if entry.includeInRestock ~= false then
            keys[#keys + 1] = key
            if #keys > TRANSFER_ITEMS then return nil, L["每份清单最多导出 200 种物品"] end
        end
    end
    sort(keys)
    local lines = { "EA12|1|" .. name }
    for index, key in ipairs(keys) do
        local entry = list.items[key]
        local itemKey = Store.Key(entry.itemKey)
        local itemName = encodeName(entry.name)
        local quantity = integer(entry.quantity, 1)
        local price = entry.maxUnitPrice
        if price ~= nil then price = integer(price, 0) end
        if not itemKey or not itemName or not quantity or (entry.maxUnitPrice ~= nil and not price) then
            return nil, L["清单含有无效物品数据"]
        end
        local item = entry.itemKey
        itemKey = format("%.0f:%.0f:%.0f:%.0f", item.itemID, item.itemLevel or 0,
            item.itemSuffix or 0, item.battlePetSpeciesID or 0)
        lines[#lines + 1] = concat({ itemKey, format("%.0f", quantity),
            price and format("%.0f", price) or "-", itemName }, "|")
    end
    local text = concat(lines, "\n")
    if #text > TRANSFER_BYTES then return nil, L["导出内容超过 64 KiB"] end
    return text
end

---Parses plain data only; no executable input. Commit occurs after every row validates.
function Store.ImportList(text)
    if not market then return nil, L["价格库尚未初始化"] end
    if type(text) ~= "string" or #text > TRANSFER_BYTES then return nil, L["请输入不超过 64 KiB 的文本"] end
    text = gsub(text, "\r\n", "\n")
    local lines = {}
    for line in gmatch(text .. "\n", "([^\n]*)\n") do
        if trimmedText(line) then
            lines[#lines + 1] = line
            if #lines > TRANSFER_ITEMS + 1 then return nil, L["每份清单最多导入 200 种物品"] end
        end
    end
    if #lines == 0 then return nil, L["导入内容为空"] end
    local name, firstRow, protocol = L["导入清单"], 1, false
    if sub(lines[1], 1, 4) == "EA12" then
        local encodedName = match(lines[1], "^EA12|1|([^|]*)$")
        name = encodedName and decodeName(encodedName)
        if not name then return nil, L["清单版本或名称无效"] end
        firstRow, protocol = 2, true
    end
    if #lines - firstRow + 1 > TRANSFER_ITEMS then return nil, L["每份清单最多导入 200 种物品"] end
    local items = {}
    for index = firstRow, #lines do
        local itemKey, quantity, price, itemName
        local line = lines[index]
        if protocol then
            local keyText, quantityText, priceText, encodedName = match(line, "^([^|]+)|([^|]+)|([^|]+)|([^|]*)$")
            if keyText then
                itemKey, quantity, itemName = identity(keyText), decimalInteger(quantityText, 1), decodeName(encodedName)
                if priceText ~= "-" then
                    price = decimalInteger(priceText, 0)
                    if not price then return nil, format(L["第 %s 行价格无效"], index) end
                end
            end
        else
            local fields = {}
            for field in gmatch(line, "%S+") do fields[#fields + 1] = field end
            if #fields == 2 or #fields == 3 then
                local itemID = decimalInteger(fields[1], 1)
                itemKey, quantity = itemID and identity(itemID), decimalInteger(fields[2], 1)
                itemName = itemID and (format(L["物品 %s"], fields[1]))
                if fields[3] then
                    price = decimalGold(fields[3])
                    if not price then return nil, format(L["第 %s 行金币价格无效，最多保留四位小数"], index) end
                end
            end
        end
        if not itemKey or not quantity or not itemName then return nil, format(L["第 %s 行物品格式无效"], index) end
        local key = Store.Key(itemKey)
        if items[key] then return nil, format(L["第 %s 行存在重复物品"], index) end
        items[key] = { key = key, itemKey = itemKey, name = itemName, quantity = quantity, maxUnitPrice = price }
    end
    local list = Store.CreateList(name)
    list.items = items
    return list
end

function Store.Recent(itemKey, name)
    local key = Store.Key(itemKey)
    if not market or not key then return false end
    for index = #market.recents, 1, -1 do
        if market.recents[index].key == key then remove(market.recents, index) end
    end
    insert(market.recents, 1, { key = key, itemKey = identity(itemKey), name = name or key, time = now() })
    while #market.recents > RECENT_LIMIT do remove(market.recents) end
    return true
end

---Remembers actual search terms separately from recently selected item identities.
function Store.RecentQuery(text)
    text = trimmedText(text)
    if not market or not text then return false end
    for index = #market.queries, 1, -1 do
        if market.queries[index].text == text then remove(market.queries, index) end
    end
    insert(market.queries, 1, { text = text, time = now() })
    while #market.queries > QUERY_LIMIT do remove(market.queries) end
    return true
end

function Store.GetItems() return ns.Prices.GetItems() end
function Store.GetRecents() return market and market.recents or {} end
function Store.GetRecentQueries() return market and market.queries or {} end
function Store.GetDB() return root end
function Store.GetPresetInstallations() return market and market.presetInstallations end

function Store.GetLists()
    local result = {}
    if market then
        for id, list in pairs(market.lists) do result[#result + 1] = list end
    end
    sort(result, function(left, right) return left.id < right.id end)
    return result
end
