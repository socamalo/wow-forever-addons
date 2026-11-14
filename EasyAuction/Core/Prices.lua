-- Blackthornes pricing algorithms adapted for exact retail auction identities.
-- One persisted table serves both analytics and the unchanged price API v1.
-- luacheck: ignore addonName
local addonName, ns = ...
local type, tonumber, pairs, ipairs = type, tonumber, pairs, ipairs
local floor, min, max, huge = math.floor, math.min, math.max, math.huge
local sort, remove = table.sort, table.remove
local match = string.match
local time, date = time, date
local Prices = {}; ns.Prices = Prices
local root, market
local marketUpdatedAt
local revision = 0
local RETENTION_HOURS, HISTORY_LIMIT, MAX_INTEGER = 720, 12, 9007199254740991
local L = ns.L

local function now() return (ns.Now or time)() end
local function integer(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == huge or value == -huge
        or value < minimum or value > MAX_INTEGER or floor(value) ~= value then return nil end
    return value
end

local function keyOf(itemKey)
    return ns.Store and ns.Store.Key(itemKey)
end

local function itemKeyFromKey(key)
    local id, level, suffix, species = match(key, "^(%d+):(%d+):(%d+):(%d+)$")
    if not id then return nil end
    return {itemID=tonumber(id),itemLevel=tonumber(level),itemSuffix=tonumber(suffix),
        battlePetSpeciesID=tonumber(species)}
end

local function pruneHours(item, currentHour)
    if type(item.h) ~= "table" then return 0 end
    local oldest = currentHour - RETENTION_HOURS + 1
    local removed = 0
    for hour in pairs(item.h) do
        if type(hour) == "number" and hour < oldest then
            item.h[hour] = nil
            removed = removed + 1
        end
    end
    return removed
end

local function createItem(key, name)
    local itemKey=itemKeyFromKey(key)
    local item = {key=key, itemKey=itemKey,
        name=name or tostring(itemKey and itemKey.itemID or key),h={},history={},scans=0}
    market.items[key] = item
    return item
end

---Bind without copying/deleting legacy records, histories, scopes or extensions.
---Migration is metadata-only: it never invents a scan or ownership observation.
function Prices.Bind(db, scope)
    root = db
    market = db.scopes[scope]
    market.items = type(market.items) == "table" and market.items or {}
    marketUpdatedAt = integer(market.lastFullScanAt, 0)
    for key, item in pairs(market.items) do
        local canonical=keyOf(key)
        if type(item) == "table" and canonical then
            if keyOf(item.itemKey) ~= canonical then item.itemKey=itemKeyFromKey(canonical) end
            if item.h == nil then item.h = {} end
            if item.history == nil then item.history = {} end
            if item.scans == nil then item.scans = 0 end
            if item.market == nil then item.market = integer(item.last, 1) end
            if item.seen == nil then item.seen = integer(item.updated, 0) end
            if item.bookStatus == nil then item.bookStatus = "legacy" end
            pruneHours(item, floor(now() / 3600))
            local observed = max(integer(item.bookUpdated, 0) or 0,
                integer(item.seen, 0) or 0, integer(item.updated, 0) or 0)
            if observed > 0 and (not marketUpdatedAt or observed > marketUpdatedAt) then marketUpdatedAt = observed end
        end
    end
    market.priceVersion = 1
    revision = revision + 1
    return market.items
end

function Prices.GetItems() return market and market.items or {} end
function Prices.GetMarketUpdatedAt() return marketUpdatedAt end
function Prices.Get(itemKey)
    local key = keyOf(itemKey)
    local item = market and key and market.items[key]
    return type(item) == "table" and item or nil
end
function Prices.Revision() return revision end

local function recordObservation(itemKey, name, price, quantity, timestamp, source)
    local key = keyOf(itemKey)
    price, quantity = integer(price, 1), integer(quantity or 0, 0)
    timestamp = integer(timestamp or now(), 0)
    if not market or not key or not price or not quantity or not timestamp then return nil end
    local currentHour, hour = floor(now() / 3600), floor(timestamp / 3600)
    if hour < currentHour - RETENTION_HOURS + 1 then return nil end
    local item = market.items[key]
    if item ~= nil and type(item) ~= "table" then return nil end
    item = item or createItem(key, name)
    if type(item.h) ~= "table" then return nil end
    if name and name ~= "" then item.name = name end
    pruneHours(item, currentHour)
    local bucket = item.h[hour]
    if bucket then
        bucket[1], bucket[2] = min(bucket[1], price), max(bucket[2], price)
        bucket[3], bucket[4], bucket[5], bucket[6] = price, bucket[4] + price, bucket[5] + 1, quantity
    else
        item.h[hour] = {price, price, price, price, 1, quantity}
    end
    if not item.updated or timestamp >= item.updated then
        item.last, item.updated, item.source, item.quantity = price, timestamp, source, quantity
    end
    if not marketUpdatedAt or timestamp > marketUpdatedAt then marketUpdatedAt = timestamp end
    revision = revision + 1
    return item, timestamp
end

local function analytics(item, value, quantity, timestamp)
    -- Late responses may add history, but must not rewind the current book/EMA.
    if item.seen and timestamp < item.seen then return false end
    if value then
        item.market = item.market and min(MAX_INTEGER, floor(item.market * 0.7 + value * 0.3 + 0.5)) or value
    end
    item.seen, item.scans = timestamp, (item.scans or 0) + 1
    item.history = item.history or {}
    local history = item.history
    history[#history + 1] = {t=timestamp,m=item.market,q=quantity}
    while #history > HISTORY_LIMIT do remove(history, 1) end
    return true
end

---Compatibility input: a minimum observation, not a full order book.
function Prices.Observe(itemKey, name, price, quantity, timestamp, source)
    local item, observedAt = recordObservation(itemKey, name, price, quantity, timestamp, source)
    if not item then return false end
    if analytics(item, integer(price, 1), integer(quantity or 0, 0), observedAt) then
        -- A summary cannot settle ownership; never reuse a previous rival quote.
        item.min, item.rivalMin, item.ownMin, item.ignoredLow = integer(price, 1), nil, nil, nil
        item.ownershipKnown = false
        item.bookStatus, item.bookUpdated, item.bookQuantity = "summary", observedAt, integer(quantity or 0, 0)
    end
    return true
end

local function ownQuantity(row, quantity)
    local available = integer(row.available, 0)
    if available then return quantity - min(quantity, available), true end
    local own = integer(row.ownQuantity or row.numOwnerItems, 0)
    if own then return min(quantity, own), true end
    if type(row.owned) == "boolean" then return row.owned and quantity or 0, true end
    if type(row.isOwn) == "boolean" then return row.isOwn and quantity or 0, true end
    return 0, false
end

---Returns marketValue,minBuyout,totalQuantity,rivalMin,ownMin,ignoredLow.
---Input is never sorted/mutated. Price tiers are aggregated before outlier checks.
function Prices.Summarise(rows, reference)
    if type(rows) ~= "table" or #rows == 0 then return nil, nil, 0 end
    local byPrice, levels, totalQuantity, ownershipKnown = {}, {}, 0, true
    for index = 1, #rows do
        local row = rows[index]
        local price = type(row) == "table" and integer(row.unitPrice, 1)
        local quantity = type(row) == "table" and integer(row.quantity, 1)
        if price and quantity then
            local level = byPrice[price]
            if not level then
                level = {price=price,quantity=0,own=0,rival=0,unknown=0}
                byPrice[price], levels[#levels+1] = level, level
            end
            local own, known = ownQuantity(row, quantity)
            if not known then ownershipKnown = false end
            level.quantity = level.quantity + quantity
            level.own = level.own + own
            if known then level.rival = level.rival + quantity - own
            else level.unknown = level.unknown + quantity end
            totalQuantity = totalQuantity + quantity
        end
    end
    if #levels == 0 then return nil, nil, 0 end
    sort(levels, function(a,b) return a.price < b.price end)
    local minimum, ignoredLow, firstIndex = levels[1].price, nil, 1
    local first, second = levels[1], levels[2]
    -- Only one known rival unit can be dismissed as a lone low listing.
    if second and first.quantity == 1 and first.rival == 1 and first.price < second.price / 3
        and (not reference or reference <= 0 or first.price < reference / 3) then
        ignoredLow, firstIndex = first.price, 2
    end
    local rivalMin, ownMin
    for index = firstIndex, #levels do
        local level = levels[index]
        if not rivalMin and level.rival > 0 then rivalMin = level.price end
        if not ownMin and level.own > 0 then ownMin = level.price end
    end
    local eligibleQuantity = totalQuantity - (ignoredLow and first.quantity or 0)
    local target = max(1, floor(eligibleQuantity * 0.25 + 0.5))
    -- Incremental weighted means avoid overflowing intermediate copper*quantity.
    local taken, mean = 0, 0
    for index = firstIndex, #levels do
        local level = levels[index]
        local take = min(level.quantity, target - taken)
        if take <= 0 then break end
        mean = mean + (level.price - mean) * (take / (taken + take))
        taken = taken + take
    end
    local kept, value = 0, 0
    for index = firstIndex, #levels do
        local level = levels[index]
        if level.price >= mean * 0.3 and level.price <= mean * 3 then
            local take = min(level.quantity, target - kept)
            if take > 0 then
                value = value + (level.price - value) * (take / (kept + take))
                kept = kept + take
            end
        end
        if kept >= target then break end
    end
    return min(MAX_INTEGER, floor((kept > 0 and value or mean) + 0.5)), minimum, totalQuantity,
        rivalMin, ownMin, ignoredLow, ownershipKnown
end

---rows MUST be a complete successful response. Failed/partial books are not empty.
---Each row: {unitPrice,quantity,available?}; available is non-owned supply.
---Alternative ownership: ownQuantity/numOwnerItems or explicit owned/isOwn boolean.
function Prices.PrepareBook(itemKey, name, rows, timestamp, source)
    local key = keyOf(itemKey)
    timestamp = integer(timestamp or now(), 0)
    if not market or not key or type(rows) ~= "table" or not timestamp then return nil, "invalid-book" end
    local item = Prices.Get(itemKey)
    local prepared = {key=key,name=name,timestamp=timestamp,source=source,empty=#rows==0,target=market.items}
    if prepared.empty then return prepared end
    prepared.value, prepared.minimum, prepared.quantity, prepared.rival, prepared.own, prepared.ignored, prepared.ownershipKnown =
        Prices.Summarise(rows, item and item.market)
    if not prepared.value then return nil, "invalid-book" end
    return prepared
end

---Publish a precomputed summary; no order-book iteration/sorting occurs here.
---Callers may discard prepared summaries on cancellation without touching saves.
function Prices.ObservePrepared(prepared)
    if type(prepared) ~= "table" or not market or prepared.target ~= market.items then
        return false, "different-market"
    end
    local key, timestamp = prepared.key, prepared.timestamp
    local item = Prices.Get(key)
    if prepared.empty then
        item = item or createItem(key, prepared.name)
        if item.seen and timestamp < item.seen then return false, "older-book" end
        analytics(item, nil, 0, timestamp)
        item.min, item.rivalMin, item.ownMin, item.ignoredLow = nil, nil, nil, nil
        item.ownershipKnown = true
        item.bookStatus, item.bookUpdated, item.bookQuantity = "empty", timestamp, 0
        if not marketUpdatedAt or timestamp > marketUpdatedAt then marketUpdatedAt = timestamp end
        revision = revision + 1
        return true, item
    end
    local recorded, observedAt = recordObservation(key, prepared.name, prepared.minimum,
        prepared.quantity, timestamp, prepared.source)
    if not recorded then return false, "invalid-observation" end
    if analytics(recorded, prepared.value, prepared.quantity, observedAt) then
        recorded.min, recorded.rivalMin, recorded.ownMin, recorded.ignoredLow =
            prepared.minimum, prepared.rival, prepared.own, prepared.ignored
        recorded.ownershipKnown = prepared.ownershipKnown
        recorded.bookStatus, recorded.bookUpdated, recorded.bookQuantity = "fresh", observedAt, prepared.quantity
    end
    return true, recorded
end

function Prices.ObserveBook(itemKey, name, rows, timestamp, source)
    local prepared, reason = Prices.PrepareBook(itemKey, name, rows, timestamp, source)
    if not prepared then return false, reason end
    return Prices.ObservePrepared(prepared)
end

function Prices.GetValue(itemKey, kind)
    local item = Prices.Get(itemKey)
    if not item then return nil end
    if kind == "min" then return item.min or (item.bookStatus == "legacy" and item.last or nil) end
    if kind == "rival" then return item.rivalMin end
    if kind == "own" then return item.ownMin end
    return item.market or item.last
end
function Prices.GetAge(itemKey)
    local item = Prices.Get(itemKey)
    return item and item.seen and now() - item.seen or nil
end
local function staleAfter()
    local settings = root and root.settings and root.settings.professions
    return max(1, tonumber(settings and settings.staleAfterSeconds) or 172800)
end
function Prices.IsStale(itemKey)
    local age = Prices.GetAge(itemKey)
    return not age or age > staleAfter()
end
function Prices.MarkScanComplete(timestamp)
    timestamp = integer(timestamp or now(), 0)
    if not market or not timestamp then return false end
    if not market.lastFullScanAt or timestamp >= market.lastFullScanAt then
        market.lastFullScanAt = timestamp
        if not marketUpdatedAt or timestamp > marketUpdatedAt then marketUpdatedAt = timestamp end
        revision = revision + 1
    end
    return true
end
function Prices.NeedsScan(maxAge)
    if not market then return false end
    maxAge = max(1, tonumber(maxAge) or staleAfter())
    local current = now()
    local completed = integer(market.lastFullScanAt, 0)
    if completed and current >= completed and current - completed <= maxAge then return false end
    for key, item in pairs(market.items) do -- luacheck: ignore key
        if type(item) == "table" then
            local observed = integer(item.bookUpdated, 0) or integer(item.seen, 0) or integer(item.updated, 0)
            if observed and current >= observed and current - observed <= maxAge then return false end
        end
    end
    return true
end
function Prices.HoldsLowest(itemKey)
    local item = Prices.Get(itemKey)
    return item and item.ownershipKnown == true and item.ownMin ~= nil
        and (item.rivalMin == nil or item.ownMin < item.rivalMin) or false
end
function Prices.GetConfidence(itemKey)
    local item = Prices.Get(itemKey)
    if not item then return 0, L["从未见过"] end
    local scans = min(1, max(0, (item.scans or 0) / 5))
    local depth = min(1, max(0, (item.bookQuantity or item.quantity or 0) / 20))
    local age = min(1, max(0, 1 - (Prices.GetAge(itemKey) or huge) / staleAfter()))
    local score, weakest = scans * 0.3 + depth * 0.3 + age * 0.4, min(scans, depth, age)
    if weakest >= 0.8 then return score end
    return score, age == weakest and L["数据过期"] or (depth == weakest and L["上架量较少"] or L["扫描次数较少"])
end
function Prices.GetLiquidity(itemKey)
    local item = Prices.Get(itemKey)
    local history = item and item.history
    if type(history) ~= "table" or #history < 2 then return nil end
    local drops, total = 0, 0
    for index = 2, #history do
        local previous, current = history[index-1].q or 0, history[index].q or 0
        if previous > 0 then drops, total = drops + max(0, previous-current), total + previous end
    end
    if total == 0 then return nil end
    return min(1, drops / total)
end
function Prices.Count()
    local count = 0
    for key in pairs(Prices.GetItems()) do if key then count = count + 1 end end
    return count
end
function Prices.Clear()
    if not market then return false end
    for key in pairs(market.items) do market.items[key] = nil end
    marketUpdatedAt = integer(market.lastFullScanAt, 0)
    revision = revision + 1
    return true
end
function Prices.Prune()
    local currentHour = floor(now() / 3600)
    local removed = 0
    for key, item in pairs(Prices.GetItems()) do -- luacheck: ignore key
        if type(item) == "table" then removed = removed + pruneHours(item, currentHour) end
    end
    if removed > 0 then revision = revision + 1 end
    return removed
end

---Sparse, original observations; analytics never overwrite the API v1 buckets.
function Prices.Trend(itemKey, days)
    local item = Prices.Get(itemKey)
    local result = {}
    if not item or type(item.h) ~= "table" then return result end
    local hours = min(RETENTION_HOURS, max(1, floor((tonumber(days) or 30) * 24)))
    local currentHour = floor(now() / 3600)
    local oldest = currentHour - hours + 1
    for hour, bucket in pairs(item.h) do
        if integer(hour, 0) and hour >= oldest and hour <= currentHour and type(bucket) == "table"
            and integer(bucket[1], 1) and integer(bucket[2], 1) and integer(bucket[3], 1)
            and integer(bucket[4], 1) and integer(bucket[5], 1) then
            result[#result + 1] = {time=hour*3600,price=bucket[3],min=bucket[1],max=bucket[2],
                average=bucket[4]/bucket[5],count=bucket[5],quantity=integer(bucket[6], 0)}
        end
    end
    sort(result, function(left,right) return left.time < right.time end)
    return result
end

---Both UI charts use real minimum observations, never the market-value EMA.
---Daily points retain the last observed hour; missing days remain absent.
function Prices.ChartTrend(itemKey, days)
    if days ~= 7 and days ~= 30 then days = 1 end
    local ending = now()
    local first = ending - 86400
    local calendar = ns.Date or date
    if days > 1 then
        local function midnight(timestamp)
            local parts = calendar("*t", timestamp)
            parts.hour, parts.min, parts.sec, parts.isdst = 0, 0, 0, nil
            return (ns.Time or time)(parts)
        end
        first = midnight(ending)
        for day = 2, days do first = midnight(first - 1) end -- luacheck: ignore day
    end
    local result, lastDay = {}, nil
    -- Read the retained hours before applying the calendar window. A local
    -- daylight-saving transition need not contain exactly 24 hours.
    for index, point in ipairs(Prices.Trend(itemKey, days == 1 and 1 or 30)) do -- luacheck: ignore index
        if point.time >= first and point.time <= ending then
            point.period = days == 1 and "hour" or "day"
            local day = days > 1 and calendar("%Y-%m-%d", point.time) or nil
            if day and day == lastDay then result[#result] = point
            else result[#result + 1] = point end
            lastDay = day
        end
    end
    return result, first, ending
end

function Prices.BestHours(itemKey)
    local days, hours, result = {}, {}, {}
    local calendar = ns.Date or date
    for index, point in ipairs(Prices.Trend(itemKey, 30)) do -- luacheck: ignore index
        local dayKey = calendar("%Y-%m-%d", point.time)
        local day = days[dayKey]
        if not day then day = {sum=0,count=0,points={}}; days[dayKey] = day end
        day.sum, day.count = day.sum + point.average, day.count + 1
        day.points[#day.points+1] = {hour=tonumber(calendar("%H", point.time)),price=point.average}
    end
    for dayKey, day in pairs(days) do
        local baseline = day.sum / day.count
        for index, point in ipairs(day.points) do -- luacheck: ignore index
            local hour = hours[point.hour]
            if not hour then hour = {sum=0,ratioSum=0,count=0,dates={}}; hours[point.hour] = hour end
            hour.sum, hour.ratioSum = hour.sum + point.price, hour.ratioSum + point.price / baseline
            hour.count = hour.count + 1
            hour.dates[dayKey] = true
        end
    end
    for clockHour, hour in pairs(hours) do
        local observedDays = 0
        for dayKey in pairs(hour.dates) do if dayKey then observedDays = observedDays + 1 end end
        result[#result+1] = {hour=clockHour,ratio=hour.ratioSum/hour.count,
            price=hour.sum/hour.count,days=observedDays}
    end
    sort(result, function(left,right)
        if left.ratio == right.ratio then return left.hour < right.hour end
        return left.ratio < right.ratio
    end)
    return result
end
