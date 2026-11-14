-- luacheck: ignore addonName
local addonName, ns = ...
local type, rawget, tonumber, tostring, pairs, ipairs, pcall = type, rawget, tonumber, tostring, pairs, ipairs, pcall
local floor, max = math.floor, math.max
local concat, insert = table.concat, table.insert
local match = string.match
local GetLocale, issecretvalue, time = GetLocale, issecretvalue, time
local C_Item = C_Item

if rawget(_G, "Auctionator") ~= nil then
    ns.AuctionatorCompat = false
    return
end

local L = ns.L
local locale = GetLocale and GetLocale() or "enUS" -- Retained for runtime diagnostics.
_G.AUCTIONATOR_L_REAGENT_SEARCH = _G.AUCTIONATOR_L_REAGENT_SEARCH or L["Auctionator 材料搜索"]
_G.AUCTIONATOR_L_TEMPORARY_LOWER_CASE = _G.AUCTIONATOR_L_TEMPORARY_LOWER_CASE or L["Auctionator 临时"]

local Auctionator = { API = { v1 = {} }, Shopping = { ListManager = {} } }
local v1 = Auctionator.API.v1
local states = {}
local MAX_INTEGER = 9007199254740991
local MAX_AGE_DAYS = 21
local DFCN_CALLER, DFCN_FRESHNESS_ITEM = "DFCN_PatronOffers", 2770

local Compat = { version = 1, owner = addonName, locale = locale }
Auctionator.EasyAuctionCompat = Compat
ns.AuctionatorCompat = Compat
_G.Auctionator = Auctionator

local function readable(value)
    return not issecretvalue or not issecretvalue(value)
end

local function caller(callerID)
    if not readable(callerID) or type(callerID) ~= "string" or callerID == "" then
        error("Invalid callerID. Use the name of your add-on.", 3)
    end
    return callerID
end

local function integer(value, minimum)
    if not readable(value) or type(value) ~= "number" or value ~= value then return nil end
    if value < minimum or value > MAX_INTEGER or floor(value) ~= value then return nil end
    return value
end

local function itemID(value)
    return integer(value, 1)
end

local function itemIDFromLink(link)
    if not readable(link) or type(link) ~= "string" then return nil end
    return itemID(tonumber(match(link, "item:(%d+)")))
end

local function latest(id)
    local api = rawget(_G, "EasyAuctionAPI")
    if not api or type(api.GetLatest) ~= "function" then return nil end
    return api.GetLatest(id)
end

local function checkItemID(callerID, id, method)
    caller(callerID)
    id = itemID(id)
    if not id then error("Usage Auctionator.API.v1." .. method .. "(string, number)", 3) end
    return id
end

local function checkItemLink(callerID, link, method)
    caller(callerID)
    local id = itemIDFromLink(link)
    if not id then error("Usage Auctionator.API.v1." .. method .. "(string, string)", 3) end
    return id
end

function v1.GetAuctionPriceByItemID(callerID, id)
    local snapshot = latest(checkItemID(callerID, id, "GetAuctionPriceByItemID"))
    return snapshot and snapshot.price or nil
end

function v1.GetAuctionPriceByItemLink(callerID, link)
    local snapshot = latest(checkItemLink(callerID, link, "GetAuctionPriceByItemLink"))
    return snapshot and snapshot.price or nil
end

local function age(snapshot)
    if not snapshot or not integer(snapshot.updated, 0) then return nil end
    local days = max(0, ((ns.Now or time)() - snapshot.updated) / 86400)
    if days > MAX_AGE_DAYS then return nil end
    return days
end

function v1.GetAuctionAgeByItemID(callerID, id)
    id = checkItemID(callerID, id, "GetAuctionAgeByItemID")
    local snapshot = latest(id)
    if not snapshot and callerID == DFCN_CALLER and id == DFCN_FRESHNESS_ITEM then
        local updated = ns.Prices and ns.Prices.GetMarketUpdatedAt and ns.Prices.GetMarketUpdatedAt()
        return age(updated and { updated = updated } or nil)
    end
    return age(snapshot)
end

function v1.GetAuctionAgeByItemLink(callerID, link)
    return age(latest(checkItemLink(callerID, link, "GetAuctionAgeByItemLink")))
end

local function vendorPrice(id)
    local engine = ns.ProfessionEngine
    local root = ns.Store and ns.Store.GetDB and ns.Store.GetDB()
    local vendorPrices = engine and engine.db and engine.db.vendorPrices
        or root and root.professions and root.professions.vendorPrices
    local record = vendorPrices and vendorPrices[id]
    local price = record and record.unitPrice
    if type(price) == "number" and price > 0 then return price end
end

function v1.GetVendorPriceByItemID(callerID, id)
    return vendorPrice(checkItemID(callerID, id, "GetVendorPriceByItemID"))
end

function v1.GetVendorPriceByItemLink(callerID, link)
    return vendorPrice(checkItemLink(callerID, link, "GetVendorPriceByItemLink"))
end

local function split(value)
    local fields = {}
    for field in (value .. ";"):gmatch("(.-);") do fields[#fields + 1] = field end
    return fields
end

local function numericField(value)
    local number = tonumber(value)
    if number and number ~= 0 then return number end
end

local function splitAdvanced(searchString)
    if not readable(searchString) or type(searchString) ~= "string" then return nil end
    local fields = split(searchString)
    local query = fields[1] or ""
    local exact = match(query, '^"(.*)"$')
    if exact then query = exact end
    local minPrice, maxPrice = numericField(fields[9]), numericField(fields[10])
    return {
        searchString = query,
        isExact = exact ~= nil,
        categoryKey = fields[2] or "",
        minItemLevel = numericField(fields[3]),
        maxItemLevel = numericField(fields[4]),
        minLevel = numericField(fields[5]),
        maxLevel = numericField(fields[6]),
        minCraftedLevel = numericField(fields[7]),
        maxCraftedLevel = numericField(fields[8]),
        minPrice = minPrice and minPrice * 10000 or nil,
        maxPrice = maxPrice and maxPrice * 10000 or nil,
        quality = numericField(fields[11]),
        tier = fields[12] ~= "#" and numericField(fields[12]) or nil,
        expansion = numericField(fields[13]),
        quantity = numericField(fields[14]),
    }
end

local function cleanTerm(term)
    if not readable(term) or type(term) ~= "table" or not readable(term.searchString)
        or type(term.searchString) ~= "string" or term.searchString == "" then return nil end
    if match(term.searchString, "[;^]") or match(term.searchString, '^".*"$') then return nil end
    return term
end

local function reconstitute(term)
    term = cleanTerm(term)
    if not term then return nil end
    local query = term.isExact and ('"' .. term.searchString .. '"') or term.searchString
    return concat({
        query,
        term.categoryKey or "",
        tostring(term.minItemLevel or ""),
        tostring(term.maxItemLevel or ""),
        tostring(term.minLevel or ""),
        tostring(term.maxLevel or ""),
        tostring(term.minCraftedLevel or ""),
        tostring(term.maxCraftedLevel or ""),
        tostring(term.minPrice and term.minPrice / 10000 or ""),
        tostring(term.maxPrice and term.maxPrice / 10000 or ""),
        tostring(term.quality or ""),
        tostring(term.tier or "#"),
        tostring(term.expansion or ""),
        tostring(term.quantity ~= 0 and term.quantity or ""),
    }, ";")
end

function v1.ConvertFromSearchString(callerID, searchString)
    caller(callerID)
    local term = splitAdvanced(searchString)
    if not term then error("Usage Auctionator.API.v1.ConvertFromSearchString(string)", 2) end
    return term
end

function v1.ConvertToSearchString(callerID, term)
    caller(callerID)
    local result = reconstitute(term)
    if not result then error("Usage Auctionator.API.v1.ConvertToSearchString(table)", 2) end
    return result
end

local function itemName(id)
    if not C_Item or type(C_Item.GetItemInfo) ~= "function" then return nil end
    local ok, name = pcall(C_Item.GetItemInfo, id)
    if ok and type(name) == "string" then return name end
end

local function reagentQuality(id, data)
    if type(data) == "table" and type(data.quality) == "number" then return data.quality end
    local trade = rawget(_G, "C_TradeSkillUI")
    if trade and type(trade.GetItemReagentQualityByItemInfo) == "function" then
        local ok, quality = pcall(trade.GetItemReagentQualityByItemInfo, id)
        if ok then return quality end
    end
end

local function matchingItem(items, name, tier, needs)
    local candidate
    for key, record in pairs(items or {}) do
        local id = itemID(type(key) == "number" and key or tonumber(match(tostring(key), "^(%d+)")))
        local knownName = id and (itemName(id) or type(record) == "table" and record.name)
        if id and knownName == name then
            local quality = reagentQuality(id, needs and needs[id] or record)
            if tier and quality == tier then return id end
            if not tier then
                if candidate and candidate ~= id then return nil end
                candidate = id
            end
        end
    end
    return candidate
end

local function resolveItemID(term)
    local name = term.searchString
    local direct = itemID(tonumber(name)) or itemIDFromLink(name)
    if direct then return direct end
    local summary = rawget(_G, "PatronOffersSummary")
    local needs = summary and summary.currentMaterialNeeds
    local resolved = matchingItem(needs, name, term.tier, needs)
    if resolved then return resolved end
    local stored = ns.Store and ns.Store.GetItems and ns.Store.GetItems()
    resolved = matchingItem(stored, name, term.tier)
    if resolved then return resolved end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local result = { pcall(C_Item.GetItemInfo, name) }
        if result[1] then
            resolved = itemIDFromLink(result[3])
            if resolved then return resolved end
        end
    end
    if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
        local ok, instantID = pcall(C_Item.GetItemInfoInstant, name)
        if ok then return itemID(instantID) end
    end
end

local function copyItems(items)
    local result = {}
    for index, value in ipairs(items or {}) do result[index] = value end
    return result
end

local function getState(name, create)
    local state = states[name]
    if not state and create then
        state = { name = name, items = {}, resolved = {} }
        states[name] = state
    end
    return state
end

local function transactionBusy()
    local market = ns.Market
    if not market then return false end
    if market.unresolved then return true end
    local buyState = market.buy and market.buy.state
    if buyState and buyState ~= "complete" and buyState ~= "cancelled" and buyState ~= "failed" then return true end
    return market.listRefresh and market.listRefresh.state == "quoting" or false
end

local function rebuild(state)
    if transactionBusy() then state.rebuildPending = true; return state.list end
    if not ns.Store or not ns.Store.CreateList then return nil end
    if not state.list then state.list = ns.Store.CreateList(state.name, true) end
    if not state.list then return nil end
    local items, resolved = {}, {}
    for _, searchString in ipairs(state.items) do
        local term = splitAdvanced(searchString)
        local id = term and (state.resolved[searchString] or resolveItemID(term))
        if id then
            local key = ns.Store.Key(id)
            local quantity = max(1, floor(tonumber(term.quantity) or 1))
            local entry = items[key]
            if entry then
                entry.quantity = entry.quantity + quantity
            else
                entry = { key = key, itemKey = { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
                    name = itemName(id) or term.searchString, quantity = quantity, quantityMode = "required",
                    includeInRestock = true, auctionatorSearchString = searchString }
                items[key] = entry
            end
            resolved[searchString] = id
        end
    end
    state.resolved, state.list.items, state.rebuildPending = resolved, items, nil
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return state.list
end

local function updateDisplayed(state)
    if state.list then rebuild(state) end
end

function Compat.Flush()
    if transactionBusy() then return false end
    for _, state in pairs(states) do
        if state.rebuildPending then rebuild(state) end
    end
    return true
end

function v1.GetShoppingListItems(callerID, listName)
    caller(callerID)
    if type(listName) ~= "string" then error("Usage Auctionator.API.v1.GetShoppingListItems(string, string)", 2) end
    local state = getState(listName, false)
    if not state then error("Auctionator.API.v1.GetShoppingListItems: List does not exist: " .. tostring(listName), 2) end
    return copyItems(state.items)
end

function v1.CreateShoppingList(callerID, listName, items)
    caller(callerID)
    if type(listName) ~= "string" or type(items) ~= "table" then
        error("Usage Auctionator.API.v1.CreateShoppingList(string, string, string[])", 2)
    end
    local state = getState(listName, true)
    state.items, state.resolved = {}, {}
    for _, searchString in ipairs(items) do
        if type(searchString) ~= "string" then
            error("Usage Auctionator.API.v1.CreateShoppingList(string, string, string[])", 2)
        end
        insert(state.items, searchString)
    end
    updateDisplayed(state)
end

function v1.DeleteShoppingListItem(callerID, listName, searchString)
    caller(callerID)
    local state = getState(listName, false)
    if type(searchString) ~= "string" or not state then
        error("Auctionator.API.v1.DeleteShoppingListItem ShoppingList does not exist: " .. tostring(listName), 2)
    end
    for index, value in ipairs(state.items) do
        if value == searchString then table.remove(state.items, index); break end
    end
    state.resolved[searchString] = nil
    updateDisplayed(state)
end

function v1.AlterShoppingListItem(callerID, listName, oldSearchString, newSearchString)
    caller(callerID)
    local state = getState(listName, false)
    if type(oldSearchString) ~= "string" or type(newSearchString) ~= "string" or not state then
        error("Auctionator.API.v1.AlterShoppingListItem ShoppingList does not exist: " .. tostring(listName), 2)
    end
    for index, value in ipairs(state.items) do
        if value == oldSearchString then
            state.items[index] = newSearchString
            state.resolved[newSearchString] = state.resolved[oldSearchString]
            state.resolved[oldSearchString] = nil
            updateDisplayed(state)
            return
        end
    end
    error("Error in Auctionator.API.v1.AlterShoppingListItem: Could not find item in shopping list:\n" .. oldSearchString, 2)
end

function v1.MultiSearchAdvanced(callerID, searchTerms)
    callerID = caller(callerID)
    if type(searchTerms) ~= "table" then
        error("Usage Auctionator.API.v1.MultiSearchAdvanced(string, table)", 2)
    end
    if not ns.open then error("Auction house is not open", 2) end
    local listName = callerID .. " (" .. _G.AUCTIONATOR_L_TEMPORARY_LOWER_CASE .. ")"
    local state = getState(listName, true)
    state.items, state.resolved = {}, {}
    for index, term in ipairs(searchTerms) do
        local searchString = reconstitute(term)
        if not searchString then
            error("Auctionator.API.v1.MultiSearchAdvanced search term " .. index .. " is invalid", 2)
        end
        insert(state.items, searchString)
        local resolved = resolveItemID(term)
        if resolved then state.resolved[searchString] = resolved end
    end
    local list = rebuild(state)
    if not list then error("EasyAuction price database is not ready", 2) end
    if ns.UI and ns.UI.Open then ns.UI.Open("buy") end
    if ns.UI and ns.UI.SelectList then ns.UI.SelectList(list) end
    return true
end

function Auctionator.Shopping.ListManager:Delete(listName)
    local state = getState(listName, false)
    if not state then error("List doesn't exist", 2) end
    if state.list then
        state.list.items = {}
        if ns.Store and ns.Store.DeleteList then ns.Store.DeleteList(state.list.id) end
    end
    states[listName] = nil
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end
