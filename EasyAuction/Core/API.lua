-- luacheck: ignore addonName
local addonName, ns = ...
local type, rawget, tonumber, pairs = type, rawget, tonumber, pairs
local floor, sort, match = math.floor, table.sort, string.match
local issecretvalue, canaccesstable, time = issecretvalue, canaccesstable, time
local API = { version = 1 }
local MAX_INTEGER = 9007199254740991
_G.EasyAuctionAPI = API

local function readable(value)
    return not issecretvalue or not issecretvalue(value)
end

local function readableTable(value)
    return readable(value) and type(value) == "table" and (not canaccesstable or canaccesstable(value))
end

local function integer(value, minimum)
    if not readable(value) or type(value) ~= "number" then return nil end
    if value ~= value or value < minimum or value > MAX_INTEGER or floor(value) ~= value then return nil end
    return value
end

local function text(value)
    if readable(value) and type(value) == "string" then return value end
end

local function optionalInteger(value)
    if not readable(value) then return nil end
    if value == nil then return 0 end
    return integer(value, 0)
end

local function identity(item)
    if not readable(item) then return nil end
    if type(item) == "number" then
        item = { itemID = item }
    elseif type(item) == "string" then
        if #item > 80 then return nil end
        local id, level, suffix, species = match(item, "^(%d+):(%d+):(%d+):(%d+)$")
        if not id then return nil end
        item = { itemID = tonumber(id), itemLevel = tonumber(level), itemSuffix = tonumber(suffix),
            battlePetSpeciesID = tonumber(species) }
    end
    if not readableTable(item) then return nil end
    local id = integer(rawget(item, "itemID"), 1)
    local level = optionalInteger(rawget(item, "itemLevel"))
    local suffix = optionalInteger(rawget(item, "itemSuffix"))
    local species = optionalInteger(rawget(item, "battlePetSpeciesID"))
    if not id or not level or not suffix or not species then return nil end
    return { itemID = id, itemLevel = level, itemSuffix = suffix, battlePetSpeciesID = species }
end

---True when the current market's saved price database is initialized.
function API.IsReady()
    return ns.resetting ~= true and ns.Store ~= nil and ns.Store.GetDB() ~= nil
end

local function lookup(item)
    if not API.IsReady() then return nil, "not-ready" end
    local itemKey = identity(item)
    if not itemKey then return nil, "invalid-item" end
    local key = ns.Store.Key(itemKey)
    return { key = key, itemKey = itemKey }, ns.Store.GetItems()[key]
end

---@param item number|string|table Exact auction item identity; not an item link.
---@return table|nil snapshot
---@return string|nil errorCode
function API.GetLatest(item)
    local result, entry = lookup(item)
    if not result then return nil, entry end
    if not readableTable(entry) then return nil, "no-data" end
    local price, updated = integer(entry.last, 1), integer(entry.updated, 0)
    if not price or not updated then return nil, "no-data" end
    local quantity = integer(entry.quantity, 0)
    if quantity == nil and readableTable(entry.h) then
        local bucket = entry.h[floor(updated / 3600)]
        if readableTable(bucket) and integer(bucket[3], 1) == price then quantity = integer(bucket[6], 0) end
    end
    result.name, result.price, result.quantity = text(entry.name), price, quantity
    result.updated, result.source = updated, text(entry.source)
    return result
end

local function historyPoint(hour, bucket)
    if not readableTable(bucket) then return nil end
    local minimum, maximum, price = integer(bucket[1], 1), integer(bucket[2], 1), integer(bucket[3], 1)
    local sum, count = integer(bucket[4], 1), integer(bucket[5], 1)
    if not minimum or not maximum or not price or not sum or not count then return nil end
    return { time = hour * 3600, price = price, min = minimum, max = maximum,
        average = sum / count, count = count, quantity = integer(bucket[6], 0) }
end

---@param item number|string|table Exact auction item identity.
---@param days number|nil Integer 1..30; omitted means 30.
---@return table|nil history
---@return string|nil errorCode
function API.GetHistory(item, days)
    local result, entry = lookup(item)
    if not result then return nil, entry end
    if not readable(days) then return nil, "invalid-days" end
    if days == nil then days = 30 end
    days = integer(days, 1)
    if not days or days > 30 then return nil, "invalid-days" end
    if not readableTable(entry) or not readableTable(entry.h) then return nil, "no-data" end
    local currentHour = floor((ns.Now or time)() / 3600)
    local oldest, points = currentHour - days * 24 + 1, {}
    for hour, bucket in pairs(entry.h) do
        if integer(hour, 0) and hour >= oldest and hour <= currentHour then
            local point = historyPoint(hour, bucket)
            if point then points[#points + 1] = point end
        end
    end
    if #points == 0 then return nil, "no-data" end
    sort(points, function(left, right) return left.time < right.time end)
    result.name, result.days, result.points = text(entry.name), days, points
    return result
end
