-- EasyAuction market boundary for the 12.1 Auction House API.
-- This module deliberately keeps quote/purchase state explicit: a submit call
-- is never treated as a successful trade until Blizzard's receipt event arrives.
local addonName, addonTable = ... -- luacheck: ignore addonName
local C_AuctionHouse = C_AuctionHouse
local C_Timer = C_Timer
local C_Container = C_Container
local ItemLocation = ItemLocation
local NUM_BAG_SLOTS = NUM_BAG_SLOTS
local C_Item = C_Item
local Enum = Enum
local GetMoney = GetMoney
local GetTime = GetTime
local debugprofilestop = debugprofilestop -- luacheck: read globals debugprofilestop
local next = next
local time = time
local type, pcall, tonumber, tostring, pairs, select = type, pcall, tonumber, tostring, pairs, select
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local concat, sort, remove = table.concat, table.sort, table.remove
local AUCTION_HOUSE_THROTTLED_SYSTEM_READY = "AUCTION_HOUSE_THROTTLED_SYSTEM_READY"
local AUCTION_HOUSE_CLOSED = "AUCTION_HOUSE_CLOSED"

addonTable = addonTable or {}
local ns = addonTable
local L = ns.L
local format = string.format
local Store = ns.Store or {}
local Emit = ns.Emit or function() end
local now = ns.Now or time
local AH = C_AuctionHouse or {}
local M = { results = {}, browse = {}, browseState = {}, buy = {}, scan = {}, open = false,
    quotes = {}, listRefresh = {}, clear = {} }
ns.Market = M
local observations, observationOrder = {}, {}
local itemDataRequests={}
local incoming={}
local advanceClear
local activeTransaction
local SCAN_BATCH_SIZE=500
-- A full replicate can legitimately exceed two minutes. The watcher only
-- aborts after a long global ceiling or when both the batch and item-data
-- queues stop moving, so a slow but healthy scan is allowed to finish.
local SCAN_WATCH_INTERVAL=5
local SCAN_MAX_SECONDS=900
local SCAN_STALL_SECONDS=180

local function clearTable(target)
    if type(target) ~= "table" then return end
    for key in pairs(target) do target[key] = nil end
end

local function cancelTimer(owner)
    if owner and owner.timer and type(owner.timer.Cancel) == "function" then
        pcall(owner.timer.Cancel, owner.timer)
    end
    if owner then owner.timer = nil end
end

local function buyPending(buy)
    if type(buy) ~= "table" then return false end
    if buy == M.unresolved then return true end
    local state = buy.state
    return state == "quoting" or state == "ready" or state == "needs-click"
        or state == "awaiting_quote" or state == "submitting" or state == "submitted"
end

local function pruneIncoming()
    for key, tracked in pairs(incoming) do
        if type(tracked) ~= "table" or ((tracked.quantity or 0) <= 0 and (tracked.early or 0) <= 0
            and not buyPending(tracked.inFlight)) then
            incoming[key] = nil
        end
    end
end

local function releaseSingleQuote()
    local buy=M.buy
    if buy.singleRequest and not M.unresolved and (buy.state=="quoting" or buy.state=="ready" or buy.state=="needs-click") then
        M.CancelBuy()
    end
end

local function normalizePostPrice(price)
    if type(price)~="number" or price<=0 then return price end
    -- Retail silently ignores posts with copper remainders. Match Blizzard's
    -- SanitizeAuctionHousePrice; normalize previews as well as API arguments.
    local step=AH.SupportsCopperValues and AH.SupportsCopperValues() and 1 or 100
    return max(step,ceil(price/step)*step)
end
M.NormalizePostPrice=normalizePostPrice

local function normalizeUndercutAmount(value)
    return max(100,floor((tonumber(value) or 100)/100)*100)
end
M.NormalizeUndercutAmount=normalizeUndercutAmount

local function salePrice(price)
    if type(price)~="number" or price<=0 then return price end
    local root=Store.GetDB and Store.GetDB()
    local settings=root and root.settings or {}
    if settings.undercut==true then
        local amount=normalizeUndercutAmount(settings.undercutAmount)
        price=max(1,price-amount)
    end
    return normalizePostPrice(price)
end
M.SalePrice=salePrice

local function batchBusy(excludeList)
    local state=M.clear and M.clear.state
    return (not excludeList and M.listRefresh and M.listRefresh.state=="quoting") or state=="quoting" or state=="ready"
        or state=="running" or state=="needs-click"
end

function M.IsBusy()
    local state=M.buy.state
    return M.scan.active or M.unresolved~=nil or M.postActive~=nil or (M.post and M.post.state=="warning")
        or batchBusy() or (state and state~="complete" and state~="failed" and state~="cancelled") or false
end

function M.CancelSearch(owner)
    if not owner or M.search~=owner or owner.done then return false end
    cancelTimer(owner); owner.done=true; M.pending=nil; M.search=nil
    return true
end

local function cancelListRefresh()
    if M.listRefresh.state~="quoting" then return end
    M.listRefresh.state="cancelled"
    if M.search and M.search.timer then M.search.timer:Cancel() end
    if M.search then M.search.done=true end
    M.search,M.pending=nil,nil
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function safeNumber(value)
    if type(value) == "number" then return value end
    local ok, converted = pcall(tonumber, value)
    if ok then return converted end
    return nil
end

local function keyString(itemKey)
    if type(Store.Key) == "function" then
        local ok, result = pcall(Store.Key, itemKey)
        if ok and result ~= nil then return result end
    end
    if type(itemKey) == "table" then
        return concat({ itemKey.itemID or 0, itemKey.itemLevel or 0, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0 }, ":")
    end
    return tostring(itemKey)
end

local function emit(name, data)
    pcall(Emit, name, data)
end

local function resetBuy()
    if M.buy.timer and type(M.buy.timer.Cancel) == "function" then pcall(M.buy.timer.Cancel, M.buy.timer) end
    M.buy.timer = nil
    if M.buy.state == "awaiting_quote" or M.buy.state == "submitting" then safeCall(AH.CancelCommoditiesPurchase) end
end

local function itemInfo(itemKey)
    local ok, info = safeCall(AH.GetItemKeyInfo, itemKey)
    if ok then return info end
    return nil
end

local function canonicalKey(itemKey,commodity)
    if not commodity then return itemKey end
    return {itemID=itemKey.itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
end

local function knownKey(itemKey)
    local info=itemInfo(itemKey)
    return canonicalKey(itemKey,info and info.isCommodity)
end

local function cacheQuote(itemKey,rows,commodity)
    local minimum,available,saleMinimum
    available=0
    for index=1,#rows do
        local row=rows[index]
        local price=row.unitPrice
        if type(price)=="number" and price>0 then
            saleMinimum=saleMinimum and min(saleMinimum,price) or price
            if (row.available or 0)>0 then
                if not minimum or price<minimum then minimum,available=price,row.available
                elseif price==minimum then available=available+row.available end
            end
        end
    end
    local value={unitPrice=minimum,salePrice=saleMinimum and salePrice(saleMinimum) or nil,
        available=available,timestamp=now(),isCommodity=commodity,rows=rows}
    M.quotes[keyString(canonicalKey(itemKey,commodity))]=value
    return value
end

local function normalizeResult(result, itemKey, commodity)
    if type(result) ~= "table" then return nil end
    local row = {
        itemKey = canonicalKey(result.itemKey or itemKey,commodity),
        unitPrice = result.unitPrice,
        totalPrice = result.totalPrice,
        quantity = result.quantity,
        auctionID = result.auctionID,
        owned = result.containsOwnerItem == true or result.containsAccountItem == true,
        buyoutAmount = result.buyoutAmount,
        isCommodity = commodity,
    }
    if commodity then
        local unit, quantity = safeNumber(row.unitPrice), safeNumber(row.quantity)
        if unit and quantity then row.totalPrice = unit * quantity end
    else
        row.totalPrice = row.buyoutAmount
        row.unitPrice = row.totalPrice and ceil(row.totalPrice / (row.quantity or 1))
    end
    row.available = commodity and max(0, (row.quantity or 0) - (result.numOwnerItems or 0)) or (row.owned and 0 or row.quantity)
    return row
end

local function storeSnapshot(itemKey, rows, source)
    if #rows>0 then itemKey=canonicalKey(itemKey,rows[1].isCommodity) end
    if ns.Prices and ns.Prices.ObserveBook then
        local info=itemInfo(itemKey)
        local timestamp=now()
        local ok=ns.Prices.ObserveBook(itemKey,info and info.itemName,rows,timestamp,source)
        if ok then
            local key=keyString(itemKey)
            if not observations[key] then observationOrder[#observationOrder+1]=key end
            observations[key]=timestamp
            if #observationOrder>256 then observations[table.remove(observationOrder,1)]=nil end
        end
        return
    end
    if #rows == 0 or type(Store.Observe) ~= "function" then return end
    local minimum, totalQuantity, name = nil, 0, nil
    for index = 1, #rows do
        local row = rows[index]
        local unit = safeNumber(row.unitPrice)
        local quantity = safeNumber(row.quantity) or 0
        if unit and (not minimum or unit < minimum) then minimum = unit end
        totalQuantity = totalQuantity + quantity
        if not name then
            local info = itemInfo(itemKey)
            name = info and info.itemName
        end
    end
    if minimum then
        local timestamp=now()
        pcall(Store.Observe, itemKey, name, minimum, totalQuantity, timestamp, source)
        observations[keyString(itemKey)]=timestamp
    end
end

local function queryReady()
    local ok, ready = safeCall(AH.IsThrottledMessageSystemReady)
    return not ok or ready == true
end

local function timeout(object, seconds, fn)
    if object.timer then object.timer:Cancel() end
    object.timer = C_Timer.NewTimer(seconds, fn)
end

local function query(fn)
    M.pending = fn
    if queryReady() then M.pending = nil; fn() end
end

local function failBuy(reason)
    resetBuy()
    M.buy.state, M.buy.message = M.unresolved and "uncertain" or "failed", reason
    if M.unresolved then M.buy.cancelRequested=true end
    pruneIncoming()
    emit("market:buy", M.buy)
    return false,reason
end

-- UNKNOWN() has no API name. Attribute it only during our synchronous call,
-- never to a transaction merely waiting for its receipt.
local function transactionCall(kind, fn, ...)
    activeTransaction=kind
    local ok,result=safeCall(fn,...)
    activeTransaction=nil
    return ok,result
end

local function postPreflight(post)
    if not queryReady() then return false,L["拍卖行繁忙，请稍后继续上架"] end
    local ok,deposit
    if post.commodity then ok,deposit=safeCall(AH.CalculateCommodityDeposit,post.itemKey.itemID,post.duration,post.quantity)
    else ok,deposit=safeCall(AH.CalculateItemDeposit,post.item,post.duration,post.quantity) end
    if not ok or type(deposit)~="number" or deposit<0 then return false,L["无法计算保管费，请重新选择物品"] end
    if GetMoney()<deposit then return false,L["金币不足以支付保管费"] end
    return true
end

local function rejectPost(post,message)
    if not post or M.postActive~=post then return end
    cancelTimer(post)
    post.state,post.message="failed",message
    M.postActive=nil
    if post.clear==M.clear then
        M.clear.state,M.clear.message="failed",message
        emit("market:clear",M.clear)
    end
    emit("market:post",post)
end

local function sendBrowse()
    local pending = M.browseState.pending
    if not pending then return end
    if not queryReady() then return end
    M.browseState.pending = nil
    M.browseState.active = pending.text
    M.browseState.done=false
    -- Rarity filters are inclusion flags. Omitting them can exclude all items.
    local quality = Enum.AuctionHouseFilter
    local ok = safeCall(AH.SendBrowseQuery, {
        searchString = pending.text,
        sorts = pending.sorts or { { sortOrder = 0, reverseSort = false } },
        minLevel = pending.minLevel or 0,
        maxLevel = pending.maxLevel or 0,
        filters = pending.filters or { quality.PoorQuality, quality.CommonQuality, quality.UncommonQuality,
            quality.RareQuality, quality.EpicQuality, quality.LegendaryQuality, quality.ArtifactQuality },
        itemClassFilters = pending.itemClassFilters,
    })
    if not ok then M.browseState.active=nil; M.browseState.done=true; emit("market:error", L["浏览请求失败"]); return end
    emit("market:browse", { text = pending.text })
end

function M.Browse(text, options)
    if not M.open or type(text) ~= "string" then return false end
    if batchBusy(true) or M.postActive then return false end
    releaseSingleQuote()
    if M.buy.state and M.buy.state ~= "complete" and M.buy.state ~= "failed" and M.buy.state ~= "cancelled" then return false end
    M.Cancel()
    M.browse={}
    M.browseState.results=nil
    M.browseState.lastEmitAt=nil
    local pending = { text = text }
    if type(options) == "table" then
        -- 与官方浏览查询同形的可选筛选：等级范围、稀有度/标记组、分类树。
        local minLevel = floor(tonumber(options.minLevel) or 0)
        local maxLevel = floor(tonumber(options.maxLevel) or 0)
        if minLevel > 0 then pending.minLevel = min(minLevel, 1000) end
        if maxLevel > 0 then pending.maxLevel = min(max(maxLevel, minLevel), 1000) end
        if type(options.filters) == "table" then
            local seen, filters = {}, {}
            for index = 1, #options.filters do
                local value = floor(tonumber(options.filters[index]) or 0)
                if value >= 1 and value <= 13 and not seen[value] then seen[value] = true end
            end
            for value = 1, 13 do if seen[value] then filters[#filters + 1] = value end end
            if #filters > 0 then pending.filters = filters end
        end
        if type(options.itemClassFilters) == "table" then
            local classFilters = {}
            for index = 1, #options.itemClassFilters do
                local entry = options.itemClassFilters[index]
                local classID = type(entry) == "table" and floor(tonumber(entry.classID) or -1) or -1
                if classID >= 0 and classID <= 20 then
                    local subClassID = type(entry) == "table" and tonumber(entry.subClassID) or nil
                    classFilters[#classFilters + 1] = { classID = classID,
                        subClassID = subClassID and subClassID >= 0 and floor(subClassID) or nil }
                end
            end
            if #classFilters > 0 then pending.itemClassFilters = classFilters end
        end
    end
    M.browseState.pending = pending
    M.browseState.done=false
    timeout(M.browseState, 45, function()
        if M.browseState.pending or (M.browseState.active and not M.browseState.done) then
            M.browseState.pending, M.browseState.active, M.pending = nil, nil, nil
            M.browseState.done=true
            emit("market:error", L["浏览超时，请重试"])
        end
    end)
    sendBrowse()
    return true
end

local function collectSearch(itemKey, commodity)
    local countName = commodity and "GetNumCommoditySearchResults" or "GetNumItemSearchResults"
    local infoName = commodity and "GetCommoditySearchResultInfo" or "GetItemSearchResultInfo"
    local ok, count = safeCall(AH[countName], commodity and itemKey.itemID or itemKey)
    if not ok or type(count) ~= "number" then return {} end
    local found = {}
    for index = 1, count do
        local resultOK, result = safeCall(AH[infoName], commodity and itemKey.itemID or itemKey, index)
        if resultOK then
            local normalized = normalizeResult(result, itemKey, commodity)
            if normalized then found[#found + 1] = normalized end
        end
    end
    return found
end

local function isFull(itemKey, commodity)
    local name = commodity and "HasFullCommoditySearchResults" or "HasFullItemSearchResults"
    local ok, full = safeCall(AH[name], commodity and itemKey.itemID or itemKey)
    return ok and full == true
end

local function requestMore(itemKey, commodity)
    local name = commodity and "RequestMoreCommoditySearchResults" or "RequestMoreItemSearchResults"
    safeCall(AH[name], commodity and itemKey.itemID or itemKey)
end

local function finishSearch(itemKey, commodity)
    local pending = M.search
    if not pending or pending.done or pending.itemKey ~= itemKey then return end
    if not isFull(itemKey, commodity) then
        if not pending.requested then
            pending.requested = true
            query(function()
                if M.search==pending and not pending.done then requestMore(itemKey, commodity) end
            end)
        end
        return
    end
    local found = collectSearch(itemKey, commodity)
    M.results = found
    pending.done = true
    M.pending=nil
    if pending.timer then pending.timer:Cancel() end
    storeSnapshot(itemKey, found, "search")
    cacheQuote(itemKey,found,commodity)
    if type(pending.callback) == "function" then pcall(pending.callback, found, commodity) end
    emit("market:search", { itemKey = itemKey, rows = found, isCommodity = commodity })
end

local function search(itemKey, callback, onError)
    if not M.open or type(itemKey) ~= "table" or not itemKey.itemID then return false end
    if M.buy.state=="awaiting_quote" or M.buy.state=="submitting" or M.buy.state=="submitted" then return false end
    if M.scan.active then return false end
    if M.search and M.search.timer then M.search.timer:Cancel() end
    if M.browseState.timer then M.browseState.timer:Cancel() end
    M.browseState.pending,M.browseState.active,M.pending=nil,nil,nil
    M.browseState.done=true
    M.results={}
    local info = itemInfo(itemKey)
    local commodity = info and info.isCommodity
    itemKey=canonicalKey(itemKey,commodity)
    M.search = { itemKey = itemKey, callback = callback, onError=onError, commodity = commodity, requested = false, done = false }
    local pending = M.search
    emit("market:search_started",{itemKey=itemKey})
    timeout(pending, 45, function()
        if M.search ~= pending or pending.done then return end
        pending.done, M.pending = true, nil
        emit("market:error", L["搜索超时，请重试"])
        if M.buy.state == "quoting" then failBuy(L["清单报价超时"]) end
        if onError then onError(L["搜索超时，请重试"]) end
    end)
    query(function()
        if M.search ~= pending or pending.done then return end
        local order=commodity==false and Enum.AuctionHouseSortOrder.Buyout or Enum.AuctionHouseSortOrder.Price
        pending.sent=true
        if not safeCall(AH.SendSearchQuery, itemKey, { { sortOrder = order, reverseSort = false } }, true) then
            pending.done = true
            emit("market:error", L["搜索请求失败"])
            if M.buy.state == "quoting" then failBuy(L["清单报价失败"]) end
            if onError then onError(L["搜索请求失败"]) end
        end
    end)
    return true
end

function M.Search(itemKey, callback, onError)
    if batchBusy(true) or M.postActive then return false end
    if not M.open or type(itemKey)~="table" or not itemKey.itemID then return false end
    releaseSingleQuote()
    local state=M.buy.state
    if M.unresolved or state=="quoting" or state=="ready" or state=="needs-click" then return false end
    cancelListRefresh()
    return search(itemKey,callback,onError)
end

local function validInteger(value)
    return type(value) == "number" and value > 0 and value < 9007199254740991 and value == floor(value)
end

function M.CanBuyOne(entry)
    if not M.open then return false,L["请先打开拍卖行"] end
    if type(entry)~="table" or type(entry.itemKey)~="table" or not entry.itemKey.itemID
        or not validInteger(entry.quantity) then return false,L["购买数据无效，请重新搜索"] end
    local state=M.buy.state
    if state=="awaiting_quote" then return false,L["等待服务器确认商品价格"] end
    if M.unresolved or state=="submitting" or state=="submitted" or state=="uncertain" then
        return false,L["等待购买回执"]
    end
    if M.scan.active or batchBusy() or M.postActive or (M.post and M.post.state=="warning") then
        return false,L["其他拍卖操作进行中，请稍后购买"]
    end
    if buyPending(M.buy) and not M.buy.singleRequest then
        return false,L["当前购买队列尚未完成"]
    end
    return true
end

local function quoteEntry(entry, rows, commodity)
    entry.itemKey=canonicalKey(entry.itemKey,commodity)
    local remaining, total = entry.quantity, 0
    local tasks = {}
    sort(rows, function(a, b) return (a.unitPrice or 1e15) < (b.unitPrice or 1e15) end)
    for index = 1, #rows do
        local row = rows[index]
        local available = row.available or 0
        if row.unitPrice and row.unitPrice > 0 and available > 0 then
            if entry.maxUnitPrice and entry.maxUnitPrice > 0 and row.unitPrice > entry.maxUnitPrice then break end
            if commodity then
                local amount = min(remaining, available)
                total, remaining = total + amount * row.unitPrice, remaining - amount
            elseif row.auctionID and row.quantity <= remaining then
                tasks[#tasks + 1] = {itemKey=entry.itemKey, name=entry.name, quantity=row.quantity,
                    auctionID=row.auctionID, totalPrice=row.totalPrice, isCommodity=false}
                total, remaining = total + row.totalPrice, remaining - row.quantity
            end
            if remaining == 0 then break end
        end
    end
    if remaining > 0 then return nil end
    if commodity then tasks[1] = {itemKey=entry.itemKey, name=entry.name, quantity=entry.quantity,
        totalPrice=total, isCommodity=true} end
    return tasks, total
end

local function buySourceValid(buy)
    local source=buy.source
    if not source then return true end
    local items=source.list.items or source.list
    if items~=source.items then return false end
    for key,record in pairs(source.records) do
        local current=items[key]
        if current~=record.entry or current.quantity~=record.quantity or current.maxUnitPrice~=record.maxUnitPrice
            or current.includeInRestock~=record.includeInRestock
            or not current.itemKey or keyString(current.itemKey)~=record.itemKey then return false end
    end
    for key,entry in pairs(items) do
        if type(entry)=="table" and entry.itemKey and not source.records[key] then return false end
    end
    return true
end

local function addBuyQuote(buy,entry,rows,commodity,cached)
    if not buySourceValid(buy) then failBuy(L["购物清单已修改，请重新发起补货"]); return false end
    if entry.restockEntry and M.Restock(entry.restockEntry).missing~=entry.quantity then
        failBuy(L["背包数量已变化，请按新的缺口重试"]); return false
    end
    if entry.restockEntry or buy.restockBatch then
        local quote=cached or cacheQuote(entry.itemKey,rows,commodity)
        if not quote.unitPrice then failBuy(L["当前没有可购买的最低价库存"]); return false end
        entry.maxUnitPrice=entry.maxUnitPrice and entry.maxUnitPrice>0
            and min(entry.maxUnitPrice,quote.unitPrice) or quote.unitPrice
    end
    local tasks,total=quoteEntry(entry,rows,commodity)
    if not tasks then failBuy(L["库存不足或超过清单单价上限"]); return false end
    for index=1,#tasks do
        tasks[index].unitCeiling=(entry.restockEntry or buy.restockBatch) and entry.maxUnitPrice
        tasks[index].restockEntry=entry.restockEntry
        tasks[index].quotedAt=cached and not commodity and cached.timestamp or nil
        buy.tasks[#buy.tasks+1]=tasks[index]
    end
    buy.total=buy.total+total
    return true
end

local function quoteNext()
    local buy = M.buy
    if not buySourceValid(buy) then failBuy(L["购物清单已修改，请重新发起补货"]); return end
    local entry = buy.entries[buy.quoteIndex]
    if not entry then
        buy.state, buy.index = "ready", 1
        emit("market:buy", buy)
        return
    end
    if not search(entry.itemKey, function(rows, commodity)
        if M.buy ~= buy or buy.state ~= "quoting" then return end
        if not addBuyQuote(buy,entry,rows,commodity) then return end
        buy.quoteIndex = buy.quoteIndex + 1
        quoteNext()
    end) then failBuy(L["当前不能搜索报价"]) end
end

function M.BuyList(list, source, cachedQuotes)
    if not M.open or type(list) ~= "table" then return false end
    if batchBusy() then return false end
    if M.unresolved or M.postActive or (M.post and M.post.state=="warning") then return false end
    if M.buy.state == "awaiting_quote" or M.buy.state == "submitting" or M.buy.state == "submitted" then return false end
    M.Cancel()
    local entries = {}
    for listKey, entry in pairs(list.items or list) do
        if type(entry) == "table" and entry.itemKey and validInteger(entry.quantity) then
            entries[#entries+1] = {itemKey=entry.itemKey, name=entry.name, quantity=entry.quantity,
                maxUnitPrice=entry.maxUnitPrice, restockEntry=entry.restockEntry, order=tostring(listKey)}
        else return false end
    end
    if #entries == 0 then return false end
    sort(entries, function(a,b) return a.order < b.order end)
    M.buy = {state="quoting", entries=entries, tasks={}, quoteIndex=1, total=0, spent=0,source=source,
        restockBatch=cachedQuotes==true}
    for index=1,#entries do
        local itemKey=knownKey(entries[index].itemKey)
        local key=keyString(itemKey)
        local restock=M.Restock({itemKey=itemKey,quantity=0})
        incoming[key]=incoming[key] or {itemKey=itemKey,quantity=0,owned=restock.owned}
        incoming[key].inFlight,incoming[key].early=M.buy,0
    end
    if cachedQuotes then
        for index=1,#entries do
            local entry=entries[index]
            local quote=M.quotes[keyString(knownKey(entry.itemKey))]
            if not quote or not quote.rows then return failBuy(L["请先刷新清单价格"]) end
            -- Commodity prices are revalidated by StartCommoditiesPurchase.
            -- Individual auction IDs need a recent search snapshot as well.
            local age=now()-quote.timestamp
            if not quote.isCommodity and (age<0 or age>30) then
                return failBuy(L["请先刷新清单价格"])
            end
            if not addBuyQuote(M.buy,entry,quote.rows,quote.isCommodity,quote) then
                return false,M.buy.message
            end
        end
        M.buy.state,M.buy.index="ready",1
        emit("market:buy",M.buy)
    else
        quoteNext()
    end
    return true
end

local function singlePurchase(entry)
    local available,reason=M.CanBuyOne(entry)
    if not available then return false,reason end
    local buy=M.buy
    local key=keyString(knownKey(entry.itemKey))
    local request=buy.singleRequest
    if buyPending(buy) then
        if not request or buy.state=="awaiting_quote" or buy.state=="submitting" or buy.state=="submitted" then
            return false,L["等待购买回执"]
        end
        local same=request.key==key and request.maxUnitPrice==entry.maxUnitPrice and request.restockEntry==entry.restockEntry
            and (request.quantity==entry.quantity or (entry.restockEntry and buy.state=="needs-click"
                and request.targetQuantity==entry.restockEntry.quantity))
        if same then
            if buy.state=="ready" or buy.state=="needs-click" then return M.Confirm() end
            return true -- The existing quote is still being prepared.
        end
        M.CancelBuy()
    end
    local root=Store.GetDB and Store.GetDB()
    local flash=root and root.settings and root.settings.flashBuy==true
    local quote=M.quotes[key]
    local useCachedQuote=flash and quote and type(quote.rows)=="table"
    local started,startReason=M.BuyList({entry},nil,useCachedQuote)
    if not started then return false,startReason or M.buy.message or L["当前购买尚未准备好"] end
    M.buy.singleRequest={key=key,quantity=entry.quantity,maxUnitPrice=entry.maxUnitPrice,restockEntry=entry.restockEntry,
        targetQuantity=entry.restockEntry and entry.restockEntry.quantity}
    if useCachedQuote then return M.Confirm() end
    return true
end

function M.BuyOne(entry)
    return singlePurchase(entry)
end

local function finishBuy(quantity, total)
    local buy = M.buy
    local entry = buy.tasks[buy.index]
    -- Consume the receipt before cleanup; do not cancel a successful purchase
    -- (CancelCommoditiesPurchase can itself dispatch synchronous events).
    M.unresolved=nil
    cancelTimer(buy)
    buy.spent = buy.spent + total
    do
        local key=keyString(entry.itemKey)
        local tracked=incoming[key] or {itemKey=entry.itemKey,quantity=0,owned=M.InventoryCount(entry.itemKey)}
        -- The BAG event may precede the purchase receipt. Credit observed bag
        -- gains once, then reserve only the part still expected through mail.
        local gained=max(0,M.InventoryCount(entry.itemKey)-tracked.owned)
        local delivered=min(quantity,(tracked.early or 0)+gained)
        tracked.early=max(0,(tracked.early or 0)+gained-delivered)
        tracked.owned=M.InventoryCount(entry.itemKey)
        tracked.quantity=tracked.quantity+quantity-delivered
        incoming[key]=tracked
        local quote=M.quotes[key]
        if not entry.isCommodity and quote and quote.rows then
            local remaining={}
            for index=1,#quote.rows do
                local row=quote.rows[index]
                if row.auctionID~=entry.auctionID then remaining[#remaining+1]=row end
            end
            -- A later flash purchase must not reuse the auction we just bought.
            -- Updating stock must not extend the remaining IDs' quote lifetime.
            cacheQuote(entry.itemKey,remaining,false).timestamp=quote.timestamp
        end
    end
    buy.index = buy.index + 1
    if not buySourceValid(buy) then
        buy.cancelRequested,buy.message=true,L["购物清单已修改；已确认成交并停止后续补货"]
    end
    buy.state = buy.cancelRequested and "cancelled" or (buy.index > #buy.tasks and "complete" or "needs-click")
    pruneIncoming()
    emit("market:buy", buy)
end

function M.Confirm()
    if not M.open then return false,L["请先打开拍卖行"] end
    local buy = M.buy
    if M.post and M.post.state == "warning" then
        if M.unresolved then return false end
        local post = M.post
        if post.quoteExpires and (now()<post.quoteAt or now()>post.quoteExpires) then
            post.state,post.message="cancelled",L["报价已过期，请重新核价。"]
            if post.timer then post.timer:Cancel() end
            emit("market:post",post)
            return false,post.message
        end
        if post.clear then
            local clear=post.clear
            local entry=clear.entries and clear.entries[clear.index]
            local age=entry and entry.verifiedAt and now()-entry.verifiedAt
            if clear~=M.clear or clear.state~="needs-click" or clear.index~=post.clearIndex
                or not entry or entry~=post.clearEntry or not entry.bagRow or entry.bagRow.location~=post.item
                or entry.quantity~=post.quantity or entry.unitPrice~=post.unitPrice
                or not age or age<0 or age>30 then
                post.state="cancelled"
                if post.timer then post.timer:Cancel() end
                clear.state,clear.message="failed",L["清包报价已过期或队列已变化，请重新预览并确认"]
                emit("market:post",post); emit("market:clear",clear)
                return false
            end
        end
        local current=C_Container.GetContainerItemInfo(post.bag,post.slot)
        if M.IsLocked(post.itemKey) or not current or current.isLocked or current.stackCount<post.quantity
            or keyString(canonicalKey(AH.GetItemKeyFromItem(post.item),post.commodity))~=keyString(post.itemKey)
            or not AH.IsSellItemValid(post.item,true) then
            post.state="cancelled"
            emit("market:post",post)
            if post.clear==M.clear and M.clear.state=="needs-click" then
                M.clear.state,M.clear.message="failed",L["物品已锁定或背包已变化，已停止清包"]
                emit("market:clear",M.clear)
            end
            return false
        end
        local ready,reason=postPreflight(post)
        if not ready then
            post.message=reason
            if post.clear==M.clear then M.clear.message=reason; emit("market:clear",M.clear) end
            emit("market:error",reason)
            return false
        end
        if post.clear==M.clear then M.clear.state="running" end
        post.state = "submitted"
        M.postActive=post
        local ok
        if post.commodity then ok = transactionCall("post",AH.ConfirmPostCommodity, post.item, post.duration, post.quantity, post.unitPrice)
        else ok = transactionCall("post",AH.ConfirmPostItem, post.item, post.duration, post.quantity, nil, post.unitPrice) end
        if not ok and post.state=="submitted" then post.state = "uncertain" end
        if M.postActive==post and post.state=="submitted" then timeout(post,30,function()
            if M.postActive==post and post.state=="submitted" then
                post.state="uncertain"; emit("market:post",post)
                if post.clear==M.clear then
                    M.clear.state,M.clear.message="failed",L["上架回执超时，已停止后续；请先核对拍卖"]
                    emit("market:clear",M.clear)
                end
            end
        end) end
        emit("market:post",post)
        if post.clear==M.clear and post.state~="complete" and post.state~="failed" then
            M.clear.state=post.state=="submitted" and "running" or (post.state=="needs-click" and "needs-click" or "failed")
            emit("market:clear",M.clear)
        end
        return ok and post.state~="failed",post.message
    end
    if M.unresolved then return false,L["等待购买回执"] end
    if buy.state ~= "ready" and buy.state ~= "needs-click" then return false,L["当前购买尚未准备好"] end
    if not buySourceValid(buy) then return failBuy(L["购物清单已修改，请重新发起补货"]) end
    local entry = buy.tasks[buy.index]
    if not entry then return failBuy(L["当前购买尚未准备好"]) end
    if GetMoney() < entry.totalPrice then return failBuy(L["金币不足"]) end
    if entry.quotedAt and (now()<entry.quotedAt or now()-entry.quotedAt>30) then
        return failBuy(L["请先刷新清单价格"])
    end
    if entry.restockEntry and M.Restock(entry.restockEntry).missing<entry.quantity then
        return failBuy(L["当前缺口已变化，已停止后续购买"])
    end
    if buy.state == "ready" then buy.budget = buy.total end
    if buy.spent + entry.totalPrice > buy.budget then return failBuy(L["超过已确认的清单预算"]) end
    if not queryReady() then
        buy.message=L["拍卖行繁忙，请稍后继续购买"]
        emit("market:buy",buy)
        return false,buy.message
    end
    buy.message=nil
    buy.entry, buy.itemID, buy.quantity = entry, entry.itemKey.itemID, entry.quantity
    buy.expectedTotal, buy.auctionID = entry.totalPrice, entry.auctionID
    buy.unitCeiling=entry.unitCeiling
    buy.state = entry.isCommodity and "awaiting_quote" or "submitted"
    if not entry.isCommodity then M.unresolved=buy end
    timeout(buy, 30, function()
        if M.buy == buy and (buy.state == "awaiting_quote" or buy.state == "submitted" or buy.state == "submitting") then
            if M.unresolved==buy then
                buy.state,buy.cancelRequested="uncertain",true
                buy.message=L["购买已提交但回执超时，核对邮箱与金币前禁止再次购买"]
                emit("market:buy",buy)
            else failBuy(L["报价超时，请重新获取报价"]) end
        end
    end)
    local ok
    if entry.isCommodity then ok = transactionCall("buy",AH.StartCommoditiesPurchase, buy.itemID, buy.quantity)
    else ok = transactionCall("buy",AH.PlaceBid, entry.auctionID, entry.totalPrice) end
    if not ok then
        if M.unresolved then
            buy.state,buy.message="uncertain",L["请求结果不明，等待交易回执"]
            buy.cancelRequested=true
        else
            resetBuy()
            buy.state, buy.message = "needs-click", L["客户端拒绝本次请求，请点击继续"]
        end
    end
    emit("market:buy", buy)
    return ok and buy.state~="failed",buy.message
end

function M.CancelBuy()
    if M.unresolved==M.buy then
        M.buy.cancelRequested=true
        M.buy.message=L["已停止后续购买；等待已提交交易回执"]
        emit("market:buy",M.buy)
        return true
    end
    resetBuy()
    if M.buy.state == "quoting" then
        if M.search and M.search.timer then M.search.timer:Cancel() end
        M.search, M.pending = nil, nil
    end
    M.buy.state = "cancelled"
    pruneIncoming()
    emit("market:buy", M.buy)
    return true
end
local function bagMetadata(info,detail)
    local target=info.hyperlink or info.itemID
    local classID,subClassID
    if C_Item and C_Item.GetItemInfoInstant then classID,subClassID=select(6,C_Item.GetItemInfoInstant(target)) end
    local metadata={name=info.itemName or (detail and detail.itemName),link=info.hyperlink,
        quality=info.quality or (detail and detail.quality),icon=info.iconFileID or (detail and detail.iconFileID),
        classID=classID,subClassID=subClassID}
    if C_Item and C_Item.GetItemInfo and (not metadata.name or not metadata.link or not metadata.quality
        or not metadata.icon or not classID or not subClassID) then
        local cached={C_Item.GetItemInfo(target)}
        metadata.name,metadata.link=metadata.name or cached[1],metadata.link or cached[2]
        metadata.quality,metadata.icon=metadata.quality or cached[3],metadata.icon or cached[10]
        metadata.classID,metadata.subClassID=metadata.classID or cached[12],metadata.subClassID or cached[13]
    end
    metadata.pending=not metadata.name or not metadata.link or not metadata.quality or not metadata.icon
        or not metadata.classID or not metadata.subClassID
    if metadata.pending and C_Item and C_Item.RequestLoadItemDataByID then
        local stamp=now()
        if not itemDataRequests[info.itemID] or stamp-itemDataRequests[info.itemID]>=5 then
            itemDataRequests[info.itemID]=stamp
            safeCall(C_Item.RequestLoadItemDataByID,info.itemID)
        end
    end
    return metadata
end

function M.Bags()
    local rows = {}
    if not C_Container or not C_Container.GetContainerNumSlots then return rows end
    for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
        local slots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isLocked then
                local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local validOK,valid=safeCall(AH.IsSellItemValid,location,false)
                if validOK and valid then
                    local keyOK,itemKey=safeCall(AH.GetItemKeyFromItem,location)
                    if not keyOK then itemKey=nil end
                    local statusOK,status=safeCall(AH.GetItemCommodityStatus,location)
                    if itemKey and statusOK and status~=Enum.ItemCommodityStatus.Unknown then
                        itemKey=canonicalKey(itemKey,status==Enum.ItemCommodityStatus.Commodity)
                        local detail = itemInfo(itemKey)
                        local metadata=bagMetadata(info,detail)
                        rows[#rows+1] = {bag=bag,slot=slot,itemID=info.itemID,itemKey=itemKey,
                            name=metadata.name or tostring(info.itemID),icon=metadata.icon,quality=metadata.quality,
                            classID=metadata.classID,subClassID=metadata.subClassID,link=metadata.link,
                            metadataPending=metadata.pending,quantity=info.stackCount,location=location,
                            isCommodity=status==Enum.ItemCommodityStatus.Commodity}
                    end
                end
            end
        end
    end
    return rows
end

function M.Post(bagRow, quantity, unitPrice, duration, clearOwner, context)
    if not M.open or not bagRow or not bagRow.location or not validInteger(quantity)
        or not validInteger(unitPrice) or not validInteger(duration) or duration > 3 then return false end
    if M.IsLocked(bagRow.itemKey) or (batchBusy() and clearOwner~=M.clear) then return false end
    if M.unresolved or M.postActive or (M.post and M.post.state=="warning") then return false end
    if M.buy.state=="quoting" or M.buy.state=="ready" or M.buy.state=="needs-click"
        or M.buy.state=="awaiting_quote" then return false end
    local current = C_Container.GetContainerItemInfo(bagRow.bag, bagRow.slot)
    if not current or current.isLocked or current.itemID ~= bagRow.itemID or current.stackCount < quantity then
        emit("market:error", L["背包物品已变化，请重新选择"])
        return false
    end
    if not AH.IsSellItemValid(bagRow.location, true) then return false end
    local commodityStatus=AH.GetItemCommodityStatus(bagRow.location)
    if commodityStatus==Enum.ItemCommodityStatus.Unknown then return false end
    local commodity = commodityStatus == Enum.ItemCommodityStatus.Commodity
    local currentKey=canonicalKey(AH.GetItemKeyFromItem(bagRow.location),commodity)
    if keyString(currentKey)~=keyString(canonicalKey(bagRow.itemKey,commodity)) then return false end
    unitPrice=normalizePostPrice(unitPrice)
    local post = {item=bagRow.location,itemKey=currentKey,quantity=quantity,unitPrice=unitPrice,
        total=quantity*unitPrice,duration=duration,commodity=commodity,state="submitted",bag=bagRow.bag,slot=bagRow.slot,
        clear=clearOwner,clearIndex=clearOwner and clearOwner.index,
        clearEntry=clearOwner and clearOwner.entries[clearOwner.index]}
    if type(context)=="table" then
        post.source=context.source
        post.requestID=context.requestID
        post.quoteAt=context.quoteAt
        post.quoteExpires=context.quoteExpires
    end
    local ready,reason=postPreflight(post)
    if not ready then emit("market:error",reason); return false,reason end
    M.post = post
    M.postActive=post
    local ok, needs
    if commodity then ok,needs=transactionCall("post",AH.PostCommodity,post.item,duration,quantity,unitPrice)
    else ok,needs=transactionCall("post",AH.PostItem,post.item,duration,quantity,nil,unitPrice) end
    if post.state=="submitted" and M.postActive==post then
        if not ok then post.state="uncertain"
        elseif needs then post.state="warning"; M.postActive=nil end
    end
    if M.postActive==post and post.state=="submitted" then timeout(post,30,function()
        if M.post==post and post.state=="submitted" then
            post.state="uncertain"; emit("market:post",post)
            if post.clear==M.clear then
                M.clear.state,M.clear.message="failed",L["上架回执超时，已停止后续；请先核对拍卖"]
                emit("market:clear",M.clear)
            end
        end
    end) end
    emit("market:post",post)
    return ok and post.state~="failed",post.message
end

local function replicateKey(scan,itemID,link,record,commodity)
    local key = {itemID=itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
    if commodity then return key,"scan",nil end
    if not link then return nil,nil,"missing-link" end
    local pet = link:match("battlepet:(%d+)")
    if pet then key.battlePetSpeciesID=tonumber(pet); return key,"scan",nil end
    local payload = link:match("item:([^|]+)")
    if not payload then return nil,nil,"invalid-link" end
    local fields={}
    for part in (payload..":"):gmatch("([^:]*):") do fields[#fields+1]=part end
    key.itemSuffix=tonumber(fields[7]) or 0
    local classID=scan.classByID[itemID]
    if classID==nil then
        if not C_Item or not C_Item.GetItemInfoInstant then return nil,nil,"missing-item-info" end
        classID=select(6,C_Item.GetItemInfoInstant(link))
        if classID then scan.classByID[itemID]=classID end
    end
    if not classID then return nil,nil,"missing-class" end
    if classID==2 or classID==4 then
        local level=record and tonumber(record[6])
        if (not level or level<=0) and C_Item.GetDetailedItemLevelInfo then
            level=C_Item.GetDetailedItemLevelInfo(link)
        end
        if not level or level<=0 then return nil,nil,"missing-level" end
        key.itemLevel=level
    end
    return key,"scan",nil
end

local function scanSkip(scan,reason)
    reason=reason or "unknown"
    scan.skipped=scan.skipped+1
    scan.skipReasons[reason]=(scan.skipReasons[reason] or 0)+1
end

local function addScanAggregate(scan,record,itemKey,source)
    local key=keyString(itemKey)
    local aggregate=scan.items[key] or {itemKey=itemKey,name=record[1],quantity=0,source=source,levels={}}
    aggregate.quantity=aggregate.quantity+record[3]
    local unit=ceil(record[10]/record[3])
    aggregate.min=aggregate.min and min(aggregate.min,unit) or unit
    aggregate.levels[unit]=(aggregate.levels[unit] or 0)+record[3]
    scan.items[key]=aggregate
end

local function requestScanItemData(scan,index,itemID)
    if not C_Item or not C_Item.RequestLoadItemDataByID then return false end
    if not scan.pending[index] then
        scan.pending[index]=itemID; scan.pendingCount=scan.pendingCount+1
        local indexes=scan.pendingByItemID[itemID] or {}
        indexes[#indexes+1]=index; scan.pendingByItemID[itemID]=indexes
    end
    if not scan.requestedItemIDs[itemID] then
        scan.requestedItemIDs[itemID]=true; C_Item.RequestLoadItemDataByID(itemID)
    end
    return true
end

local function processScanRecord(scan,index,allowPending)
    local record={AH.GetReplicateItemInfo(index)}
    local quantity,price,itemID=record[3],record[10],record[17]
    if not itemID then scanSkip(scan,"missing-item"); return end
    if record[18]~=true then
        if allowPending and requestScanItemData(scan,index,itemID) then return end
        scanSkip(scan,"incomplete-info"); return
    end
    if not quantity or quantity<=0 then scanSkip(scan,"invalid-quantity"); return end
    if not price or price<=0 then scanSkip(scan,"invalid-price"); return end
    -- 商品状态按 itemID 缓存：同一物品的重复堆叠不再逐条打 GetItemKeyInfo；
    -- 已知商品直接跳过链接解析（商品 key 永远是基础 key）。
    local commodity=scan.commodityByID[itemID]
    if commodity==nil then
        local detail=itemInfo({itemID=itemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0})
        if detail~=nil then
            commodity=detail.isCommodity==true
            scan.commodityByID[itemID]=commodity
        else
            commodity=false
        end
    end
    local link = commodity or AH.GetReplicateItemLink(index)
    local itemKey,source,reason=replicateKey(scan,itemID,link,record,commodity)
    if not itemKey and allowPending and (reason=="missing-link" or reason=="missing-class"
        or reason=="missing-level" or reason=="missing-item-info") then
        if requestScanItemData(scan,index,itemID) then return end
    end
    if not itemKey then scanSkip(scan,reason); return end
    addScanAggregate(scan,record,itemKey,source)
end

local function scanClock()
    return debugprofilestop and debugprofilestop() or ((GetTime and GetTime() or 0)*1000)
end

local function scanBudget()
    return ns.ProfessionSettings and ns.ProfessionSettings.Get("scanBudgetMs") or 8
end

local function finishScan(scan)
    if not scan.initialDone or scan.pendingCount>0 then return end
    if ns.Prices and ns.Prices.PrepareBook and not scan.preparedDone then
        scan.state="processing"
        scan.prepared=scan.prepared or {}
        local started,count=scanClock(),0
        local key,aggregate=next(scan.items,scan.prepareKey)
        while key do
            local rows={}
            for price,quantity in pairs(aggregate.levels) do rows[#rows+1]={unitPrice=price,quantity=quantity} end
            local prepared=ns.Prices.PrepareBook(aggregate.itemKey,aggregate.name,rows,scan.timestamp,aggregate.source)
            if prepared then scan.prepared[#scan.prepared+1]=prepared end
            scan.prepareKey=key; count=count+1
            key,aggregate=next(scan.items,key)
            if key and (count>=SCAN_BATCH_SIZE or scanClock()-started>=scanBudget()) then
                scan.lastProgressAt=GetTime and GetTime() or scan.lastProgressAt
                scan.batchTimer=C_Timer.NewTimer(0.01,function()
                    if M.scan==scan and scan.active then finishScan(scan) end
                end)
                return
            end
        end
        scan.preparedDone=true
    end
    scan.active,scan.state=false,"complete"; scan.finishedAt=GetTime and GetTime() or scan.startedAt
    if scan.timer then scan.timer:Cancel() end
    if scan.prepared then
        for index=1,#scan.prepared do ns.Prices.ObservePrepared(scan.prepared[index]) end
    else
        for itemKey,aggregate in pairs(scan.items) do -- luacheck: ignore itemKey
            Store.Observe(aggregate.itemKey,aggregate.name,aggregate.min,aggregate.quantity,scan.timestamp,aggregate.source)
        end
    end
    if ns.Prices and ns.Prices.MarkScanComplete then ns.Prices.MarkScanComplete(scan.timestamp) end
    scan.prepared=nil
    scan.items=nil
    scan.pending=nil; scan.pendingByItemID=nil; scan.requestedItemIDs=nil
    scan.commodityByID=nil; scan.classByID=nil
    emit("market:scan_complete",{total=scan.total,skipped=scan.skipped,skipReasons=scan.skipReasons})
end

local function failScan(scan,reason)
    if not scan or not scan.active then return end
    scan.active,scan.state=false,"failed"
    scan.elapsed=(GetTime and GetTime() or scan.startedAt)-scan.startedAt
    if scan.batchTimer then scan.batchTimer:Cancel() end
    if scan.timer then scan.timer:Cancel() end
    if M.pending==scan.request then M.pending=nil end
    scan.pending=nil; scan.pendingByItemID=nil; scan.requestedItemIDs=nil
    scan.commodityByID=nil; scan.classByID=nil
    scan.failureReason=reason
    emit("market:error",reason)
end

local function watchScan(scan)
    if not scan.active or M.scan~=scan then return end
    local current=GetTime and GetTime() or scan.startedAt
    scan.elapsed=current-scan.startedAt
    local stalled=current-(scan.lastProgressAt or scan.startedAt)
    if scan.elapsed>=SCAN_MAX_SECONDS then
        failScan(scan,L["全量扫描超过 15 分钟，已停止等待；请检查拍卖行连接后重试"])
        return
    end
    if stalled>=SCAN_STALL_SECONDS then
        failScan(scan,not scan.processing
            and L["全量扫描已超过 3 分钟未收到快照；可能受到 15 分钟账户级限流，请稍后重试"]
            or L["全量扫描已超过 3 分钟没有进度，已停止等待；请检查拍卖行连接后重试"])
        return
    end
    scan.timer=C_Timer.NewTimer(SCAN_WATCH_INTERVAL,function() watchScan(scan) end)
end

local function processPendingScanItem(scan,itemID,success)
    local indexes=scan.pendingByItemID[itemID]
    if not indexes then return end
    scan.pendingByItemID[itemID]=nil; scan.requestedItemIDs[itemID]=nil
    for index=1,#indexes do
        local scanIndex=indexes[index]
        scan.pending[scanIndex]=nil; scan.pendingCount=scan.pendingCount-1
        if success then processScanRecord(scan,scanIndex,false) else scanSkip(scan,"item-data-failed") end
    end
    scan.lastProgressAt=GetTime and GetTime() or scan.lastProgressAt
    if scan.pendingCount==0 and scan.initialDone then finishScan(scan) end
end

local function processScanBatch()
    local scan=M.scan
    if not scan.active or not scan.processing then return end
    local started,count=scanClock(),0
    while scan.index<scan.total do
        processScanRecord(scan,scan.index,true)
        scan.index=scan.index+1; count=count+1
        if count>=SCAN_BATCH_SIZE or scanClock()-started>=scanBudget() then break end
    end
    scan.elapsed=(GetTime and GetTime() or scan.startedAt)-scan.startedAt
    scan.lastProgressAt=GetTime and GetTime() or scan.lastProgressAt
    -- 进度事件按秒节流：全量扫描上万条时每帧 emit 会触发每帧一次的完整 UI 刷新。
    if scan.index>=scan.total or not scan.lastEmitAt or now()-scan.lastEmitAt>=1 then
        scan.lastEmitAt=now()
        emit("market:scan",{done=scan.index,total=scan.total,pending=scan.pendingCount,skipped=scan.skipped})
    end
    if scan.index<scan.total then
        scan.batchTimer=C_Timer.NewTimer(0.01,processScanBatch)
    else
        scan.initialDone=true; scan.state=scan.pendingCount>0 and "loading" or "processing"; finishScan(scan)
    end
end

function M.Scan()
    if not M.open or M.scan.active then return false end
    if batchBusy() or M.postActive then return false end
    if M.buy.state=="awaiting_quote" or M.buy.state=="submitting" or M.buy.state=="submitted" then return false end
    local db=Store.GetDB and Store.GetDB()
    local lastRequest=db and tonumber(db.lastReplicateRequestAt)
    local remaining=lastRequest and lastRequest+900-now() or 0
    if remaining>0 then
        return false,format(L["全量扫描请求有 15 分钟账户级间隔，请等待 %d 秒后重试"],ceil(remaining))
    end
    M.Cancel()
    local startedAt=GetTime and GetTime() or 0
    local scan={active=true,state="waiting",index=0,total=0,items={},timestamp=now(),skipped=0,
        skipReasons={},pending={},pendingByItemID={},requestedItemIDs={},pendingCount=0,
        commodityByID={},classByID={},
        initialDone=false,startedAt=startedAt,lastProgressAt=startedAt,elapsed=0}
    M.scan=scan
    scan.timer=C_Timer.NewTimer(SCAN_WATCH_INTERVAL,function() watchScan(scan) end)
    scan.request=function()
        if M.scan~=scan or not scan.active then return end
        scan.sent=true
        if not safeCall(AH.ReplicateItems) then
            failScan(scan,L["无法开始全量扫描"])
        elseif db then
            db.lastReplicateRequestAt=now()
        end
    end
    query(scan.request)
    return true
end
local function readBrowse(rebuild)
    local browse = M.browseState
    if not browse.active then return end
    local results = AH.GetBrowseResults()
    local normalized = browse.results
    local start = 1
    -- UPDATED 整体替换结果，ADDED 只在尾部追加：空名称浏览全拍卖行时只归一化
    -- 新增尾部行，避免每页事件都重算整个累积列表（二次方开销）。
    if rebuild or type(normalized) ~= "table" or #results < #normalized then
        normalized = {}
    else
        start = #normalized + 1
    end
    for index=start,#results do
        local row=results[index]
        local info=itemInfo(row.itemKey)
        normalized[#normalized+1]={itemKey=canonicalKey(row.itemKey,info and info.isCommodity),
            name=info and info.itemName or tostring(row.itemKey.itemID),
            unitPrice=row.minPrice,quantity=row.totalQuantity,isCommodity=info and info.isCommodity}
    end
    browse.results=normalized
    M.browse=normalized
    -- 空名称搜索会连续收到几十页结果；加载中按秒节流 emit，完成时始终发送。
    local finished = AH.HasFullBrowseResults()
    if finished or not browse.lastEmitAt or now()-browse.lastEmitAt>=1 then
        browse.lastEmitAt=now()
        emit("market:browse_results",normalized)
    end
    if not finished then
        browse.done=false
        timeout(browse,45,function()
            if M.browseState==browse and browse.active and not browse.done then
                browse.active,M.pending,browse.done=nil,nil,true
                emit("market:error",L["浏览超时，请重试"])
            end
        end)
        query(function() if M.browseState==browse and browse.active then AH.RequestMoreBrowseResults() end end)
    else
        -- Item searches also publish browse updates. Keep this text query's
        -- ownership until another action replaces it, so a trailing full event
        -- from an earlier list quote cannot discard the actual browse response.
        browse.done=true
        if browse.timer then browse.timer:Cancel() end
    end
end

local function observeNativeSearch(itemKey,commodity)
    if ns.ProfessionSettings and not ns.ProfessionSettings.Get("learnFromSearches") then return end
    if not M.open or M.scan.active or M.unresolved or (M.search and not M.search.done)
        or M.browseState.pending or (M.browseState.active and not M.browseState.done) then return end
    local state=M.buy.state
    if state and state~="complete" and state~="failed" and state~="cancelled" then return end
    if not itemKey or not itemKey.itemID or not isFull(itemKey,commodity) then return end
    local last=observations[keyString(itemKey)]
    if last and now()-last>=0 and now()-last<60 then return end
    -- Blizzard's own selection can fill the price library without issuing an
    -- extra query, requesting another page, or replacing this workbench's rows.
    storeSnapshot(itemKey,collectSearch(itemKey,commodity),"native-search")
end

-- Only carried bags count. Bound items still satisfy a restock target; bank,
-- mail and account storage are intentionally outside this observable scope.
function M.InventoryCount(itemKey)
    if not itemKey or not C_Container or not C_Container.GetContainerNumSlots then return 0 end
    local wanted=knownKey(itemKey)
    local detail=itemInfo(wanted)
    local commodity=detail and detail.isCommodity
    local wantedKey,total=keyString(wanted),0
    for bag=0,(NUM_BAG_SLOTS or 4)+1 do
        for slot=1,C_Container.GetContainerNumSlots(bag) do
            local info=C_Container.GetContainerItemInfo(bag,slot)
            if info and info.itemID==wanted.itemID then
                local matched=commodity==true
                if not matched and ItemLocation and ItemLocation.CreateFromBagAndSlot then
                    local location=ItemLocation:CreateFromBagAndSlot(bag,slot)
                    local ok,key=safeCall(AH.GetItemKeyFromItem,location)
                    matched=ok and key and keyString(key)==wantedKey
                end
                if matched then total=total+(info.stackCount or 0) end
            end
        end
    end
    return total
end

local function reconcileIncoming(key,itemKey)
    local owned=M.InventoryCount(itemKey)
    local tracked=incoming[key]
    if tracked then
        local gained=max(0,owned-tracked.owned)
        local pendingDelivered=min(tracked.quantity,gained)
        tracked.quantity=tracked.quantity-pendingDelivered
        local buy=tracked.inFlight
        if buy and buy==M.buy and (buy.state=="awaiting_quote" or buy.state=="submitting"
            or buy.state=="submitted" or M.unresolved==buy) then
            tracked.early=(tracked.early or 0)+max(0,gained-pendingDelivered)
        end
        tracked.owned=owned
    end
    local pending=tracked and tracked.quantity or 0
    pruneIncoming()
    return owned,pending
end

function M.Restock(entry)
    local itemKey=knownKey(entry.itemKey)
    local key=keyString(itemKey)
    local owned,pending=reconcileIncoming(key,itemKey)
    local target=max(0,floor(tonumber(entry.quantity) or 0))
    local quote=M.open and M.quotes[key]
    if entry.quantityMode=="required" then
        return {owned=owned,target=owned+pending+target,missing=target,pending=pending,
            unitPrice=quote and quote.unitPrice,quoted=quote~=nil,available=quote and quote.available or 0}
    end
    return {owned=owned,target=target,missing=max(0,target-owned-pending),pending=pending,
        unitPrice=quote and quote.unitPrice,quoted=quote~=nil,available=quote and quote.available or 0}
end

local function transactionsIdle()
    local state=M.buy.state
    return not M.unresolved and not M.postActive and not (M.post and M.post.state=="warning")
        and (not state or state=="complete" or state=="cancelled" or state=="failed")
end

function M.RefreshList(list)
    if not M.open or not list or batchBusy(true) or M.scan.active or not transactionsIdle() then return false end
    M.Cancel()
    local refresh={state="quoting",index=1,entries={},total=0}
    for entryKey,entry in pairs(list.items or list) do -- luacheck: ignore entryKey
        if type(entry)=="table" and entry.itemKey then refresh.entries[#refresh.entries+1]=entry end
    end
    refresh.total=#refresh.entries
    M.listRefresh=refresh
    local nextQuote
    local function failed(reason)
        if M.listRefresh~=refresh or refresh.state~="quoting" then return end
        refresh.state,refresh.message="failed",reason
        emit("market:list",refresh)
    end
    nextQuote=function()
        if M.listRefresh~=refresh or refresh.state~="quoting" then return end
        local entry=refresh.entries[refresh.index]
        if not entry then refresh.state="complete"; emit("market:list",refresh); return end
        if not search(entry.itemKey,function()
            if M.listRefresh~=refresh or refresh.state~="quoting" then return end
            refresh.index=refresh.index+1
            emit("market:list",refresh)
            nextQuote()
        end,failed) then failed(L["当前不能刷新清单价格"]) end
    end
    nextQuote()
    return true
end

function M.BuyMissing(entry)
    if not M.open or not entry or not entry.itemKey or batchBusy() or M.scan.active then return false end
    local restock=M.Restock(entry)
    if restock.missing<1 then return false end
    if not restock.quoted or not restock.unitPrice then
        emit("market:error",L["请先刷新清单价格"]); return false
    end
    local cap=restock.unitPrice
    if entry.maxUnitPrice and entry.maxUnitPrice>0 then cap=min(cap,entry.maxUnitPrice) end
    local itemKey=knownKey(entry.itemKey)
    local key=keyString(itemKey)
    incoming[key]=incoming[key] or {itemKey=itemKey,quantity=0,owned=restock.owned}
    return singlePurchase({itemKey=itemKey,name=entry.name,quantity=restock.missing,maxUnitPrice=cap,restockEntry=entry})
end

function M.BuyRestockList(list)
    if not M.open or not list or batchBusy() or M.scan.active or not transactionsIdle() then return false end
    local entries,entryCount={},0
    local source={list=list,items=list.items or list,records={}}
    for listKey,entry in pairs(list.items or list) do
        if type(entry)=="table" and entry.itemKey then
            source.records[listKey]={entry=entry,quantity=entry.quantity,maxUnitPrice=entry.maxUnitPrice,
                itemKey=keyString(entry.itemKey),includeInRestock=entry.includeInRestock}
            local restock=M.Restock(entry)
            if entry.includeInRestock~=false and restock.missing>0 then
                if not restock.quoted or not restock.unitPrice then
                    emit("market:error",L["部分物品没有当前报价，请先刷新清单"]); return false
                end
                local cap=restock.unitPrice
                if entry.maxUnitPrice and entry.maxUnitPrice>0 then cap=min(cap,entry.maxUnitPrice) end
                entries[listKey]={itemKey=entry.itemKey,name=entry.name,quantity=restock.missing,
                    maxUnitPrice=cap,restockEntry=entry}
                entryCount=entryCount+1
            end
        end
    end
    if entryCount==0 or not M.BuyList(entries,source,true) then return false end
    -- This is still the original button click, so the first protected request
    -- does not need a second total-confirmation click or an event callback.
    return M.Confirm()
end

local fallbackLocks={}
local function locks()
    local root=Store.GetDB and Store.GetDB()
    if not root then return fallbackLocks end
    root.settings=root.settings or {}
    root.settings.lockedItems=root.settings.lockedItems or {}
    return root.settings.lockedItems
end

function M.IsLocked(itemKey)
    return itemKey and locks()[keyString(knownKey(itemKey))]==true or false
end

function M.SetLocked(itemKey,locked)
    if type(itemKey)~="table" or not itemKey.itemID then return false end
    locks()[keyString(knownKey(itemKey))]=locked and true or nil
    emit("market:locks",itemKey)
    return true
end

local function clearChanged(clear,state,message)
    clear.state,clear.message=state,message
    emit("market:clear",clear)
end

local function editableClearIndex(entry)
    local clear=M.clear
    if not M.open or clear.state~="ready" then return end
    for index=1,#clear.entries do
        if clear.entries[index]==entry then return index end
    end
end

local function refreshClearTotals(clear)
    clear.total,clear.quantity=0,0
    for index=1,#clear.entries do
        local entry=clear.entries[index]
        clear.total=clear.total+entry.quantity*entry.unitPrice
        clear.quantity=clear.quantity+entry.quantity
    end
    clearChanged(clear,#clear.entries>0 and "ready" or "complete",
        #clear.entries>0 and L["报价就绪，请确认上架"] or L["没有可上架的物品"])
end

function M.SetClearBagsQuantity(entry,quantity)
    if not editableClearIndex(entry) or not validInteger(quantity)
        or quantity>entry.bagRow.quantity then return false end
    entry.quantity=quantity
    refreshClearTotals(M.clear)
    return true
end

function M.RemoveClearBagsEntry(entry)
    local index=editableClearIndex(entry)
    if not index then return false end
    remove(M.clear.entries,index)
    refreshClearTotals(M.clear)
    return true
end

local function clearRowValid(entry)
    local row=entry.bagRow
    if M.IsLocked(row.itemKey) then return false end
    local info=C_Container.GetContainerItemInfo(row.bag,row.slot)
    if not info or info.isLocked or info.itemID~=row.itemID or (info.stackCount or 0)<entry.quantity then return false end
    local keyOK,key=safeCall(AH.GetItemKeyFromItem,row.location)
    local validOK,valid=safeCall(AH.IsSellItemValid,row.location,false)
    return keyOK and key and keyString(canonicalKey(key,row.isCommodity))==keyString(row.itemKey) and validOK and valid
end

function M.PrepareClearBags(duration)
    if not M.open or batchBusy() or M.scan.active or not transactionsIdle()
        or not validInteger(duration) or duration>3 then return false end
    M.Cancel()
    local clear={state="quoting",entries={},skipped=0,total=0,quantity=0,posted=0,index=1,duration=duration}
    M.clear=clear
    local candidates=M.Bags()
    local nextQuote
    local function failed(reason)
        if M.clear==clear and clear.state=="quoting" then clearChanged(clear,"failed",reason) end
    end
    nextQuote=function()
        if M.clear~=clear or clear.state~="quoting" then return end
        local row=candidates[clear.index]
        if not row then
            clear.index=1
            clearChanged(clear,#clear.entries>0 and "ready" or "complete",#clear.entries>0 and L["报价就绪，请确认上架"] or L["没有可上架的物品"])
            return
        end
        clear.index=clear.index+1
        if M.IsLocked(row.itemKey) then clear.skipped=clear.skipped+1; nextQuote(); return end
        if not search(row.itemKey,function(found,commodity)
            if M.clear~=clear or clear.state~="quoting" then return end
            local quote=cacheQuote(row.itemKey,found,commodity)
            local entry={bagRow=row,quantity=row.quantity,unitPrice=quote.salePrice,verifiedAt=now()}
            if quote.salePrice and clearRowValid(entry) then
                clear.entries[#clear.entries+1]=entry
                clear.total=clear.total+entry.quantity*entry.unitPrice
                clear.quantity=clear.quantity+entry.quantity
            else clear.skipped=clear.skipped+1 end
            emit("market:clear",clear)
            nextQuote()
        end,failed) then failed(L["当前不能查询清包价格"]) end
    end
    nextQuote()
    return true
end

local function submitClear(clear,entry)
    if M.clear~=clear or clear.state~="running" then return false end
    if not clearRowValid(entry) then
        entry.state="skipped"; clear.skipped=clear.skipped+1; clear.index=clear.index+1
        advanceClear(clear); return false
    end
    local ok,reason=M.Post(entry.bagRow,entry.quantity,entry.unitPrice,clear.duration,clear)
    local post=M.post
    if reason and not M.postActive and (not post or post.clear~=clear or post.state=="complete") then
        clearChanged(clear,"needs-click",reason)
    elseif post and post.clear==clear and (post.state=="warning" or post.state=="needs-click") then
        clearChanged(clear,"needs-click",post.state=="warning" and L["客户端要求额外上架确认，请核对后继续"] or L["请点击继续上架"])
    elseif not ok or not post or post.clear~=clear then
        clearChanged(clear,"failed",reason or L["上架未完成，已停止后续；请核对拍卖"])
    end
    return ok,reason
end

advanceClear=function(clear)
    if M.clear~=clear or clear.state~="running" then return end
    local entry=clear.entries[clear.index]
    if not entry then clearChanged(clear,"complete",L["清包上架完成"]); return end
    if not clearRowValid(entry) then
        entry.state="skipped"; clear.skipped=clear.skipped+1; clear.index=clear.index+1
        advanceClear(clear); return
    end
    local function failed(reason)
        if M.clear==clear and clear.state=="running" then clearChanged(clear,"failed",reason) end
    end
    if not search(entry.bagRow.itemKey,function(found,commodity)
        if M.clear~=clear or clear.state~="running" then return end
        local quote=cacheQuote(entry.bagRow.itemKey,found,commodity)
        if quote.salePrice~=entry.unitPrice then
            failed(L["市场最低价已变化，请重新预览并确认清包"]); return
        end
        entry.verifiedAt=now()
        -- Search events cannot carry the hardware interaction required to post.
        if not clearRowValid(entry) then
            advanceClear(clear); return
        end
        clearChanged(clear,"needs-click",L["请点击继续上架"])
    end,failed) then failed(L["当前不能核验上架价格"]) end
end

function M.ConfirmClearBags()
    local clear=M.clear
    if not M.open or clear.state~="ready" or not transactionsIdle() then return false end
    local entry=clear.entries[clear.index]
    local age=entry and entry.verifiedAt and now()-entry.verifiedAt
    local quote=entry and M.quotes[keyString(entry.bagRow.itemKey)]
    if not age or age<0 or age>30 or not quote or quote.salePrice~=entry.unitPrice then
        clearChanged(clear,"failed",L["报价已过期，请重新预览并确认清包"]); return false
    end
    clearChanged(clear,"running",L["正在核验并逐项上架"])
    return submitClear(clear,entry)
end

function M.ContinueClearBags()
    local clear=M.clear
    if not M.open or clear.state~="needs-click" or M.postActive then return false end
    local entry=clear.entries[clear.index]
    if not entry or not clearRowValid(entry) then
        if M.post and M.post.clear==clear then M.post.state="cancelled" end
        clearChanged(clear,"failed",L["物品已锁定或背包已变化"]); return false
    end
    if not entry.verifiedAt or now()-entry.verifiedAt>30 then
        if M.post and M.post.clear==clear then M.post.state="cancelled" end
        clearChanged(clear,"failed",L["报价已过期，请重新预览并确认清包"]); return false
    end
    if M.post and M.post.clear==clear and M.post.state=="warning" then return M.Confirm() end
    clearChanged(clear,"running",L["继续上架"])
    return submitClear(clear,entry)
end

function M.CancelClearBags()
    local clear=M.clear
    if clear.state~="quoting" and clear.state~="ready" and clear.state~="running" and clear.state~="needs-click" then return false end
    if clear.state=="quoting" or (clear.state=="running" and not M.postActive) then
        if M.search and M.search.timer then M.search.timer:Cancel() end
        if M.search then M.search.done=true end
        M.pending=nil
    end
    if M.post and M.post.clear==clear and M.post.state=="warning" then M.post.state="cancelled" end
    if M.postActive and M.postActive.clear==clear and not M.postActive.commodity then safeCall(AH.CancelSell) end
    clearChanged(clear,"cancelled",M.postActive and L["已停止后续；已提交上架仍等待回执"] or L["已取消清包"])
    return true
end

local function postCompleted(post,auctionID)
    post.state,post.auctionID="complete",auctionID or post.auctionID
    M.postActive=nil
    if post.timer then post.timer:Cancel() end
    emit("market:post",post)
    local clear=post.clear
    if clear and clear==M.clear then
        local entry=clear.entries[clear.index]
        if entry then entry.state="posted" end
        clear.posted=clear.posted+1
        clear.index=clear.index+1
        emit("market:clear",clear)
        if clear.state=="running" then advanceClear(clear) end
    end
end

function M.OnEvent(event, ...)
    if event == "AUCTION_HOUSE_SHOW" then M.open=true; M.quotes={}
    elseif event == "BAG_UPDATE_DELAYED" then
        for key,tracked in pairs(incoming) do reconcileIncoming(key,tracked.itemKey) end
        emit("market:inventory")
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemID,success=...
        if itemDataRequests[itemID] and success then
            itemDataRequests[itemID]=nil
            emit("market:item_data",{itemID=itemID})
        end
        if M.scan.active and itemID then
            processPendingScanItem(M.scan,itemID,success==true)
        end
    elseif event == AUCTION_HOUSE_THROTTLED_SYSTEM_READY then
        sendBrowse()
        if M.pending and queryReady() then local pending=M.pending; M.pending=nil; pending() end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
        local updatedItemID = ...
        if M.search and M.search.sent and not M.search.done and M.search.commodity~=false
            and updatedItemID == M.search.itemKey.itemID then
            M.search.commodity=true
            M.search.itemKey=canonicalKey(M.search.itemKey,true)
            M.search.requested=false
            finishSearch(M.search.itemKey, true)
        elseif updatedItemID then
            observeNativeSearch({itemID=updatedItemID,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0},true)
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
        local updatedKey = ...
        if M.search and M.search.sent and not M.search.done and M.search.commodity~=true
            and updatedKey and keyString(updatedKey) == keyString(M.search.itemKey) then
            M.search.commodity=false
            M.search.requested=false
            finishSearch(M.search.itemKey, false)
        else
            observeNativeSearch(updatedKey,false)
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        readBrowse(event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    elseif event == "COMMODITY_PRICE_UPDATED" then
        local unit,total=...
        local buy=M.buy
        if buy.state=="awaiting_quote" then
            if not buySourceValid(buy) then
                failBuy(L["购物清单已修改，请重新发起补货"])
            elseif not validInteger(unit) or not validInteger(total) or total>buy.expectedTotal
                or (buy.unitCeiling and unit>buy.unitCeiling)
                or buy.spent+total>buy.budget or AH.GetQuoteDurationRemaining()<=0 or GetMoney()<total then
                failBuy(L["报价已变化、过期或超过预算；请重新获取报价"])
            else
                buy.actualTotal,buy.state=total,"submitting"
                M.unresolved=buy
                if not transactionCall("buy",AH.ConfirmCommoditiesPurchase,buy.itemID,buy.quantity)
                    and buy.state=="submitting" then failBuy(L["服务器拒绝购买确认"]) end
                emit("market:buy",buy)
            end
        end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        -- Retail's terminal success notification has no payload. Attribute it
        -- only to our confirmed commodity request, including a late receipt.
        local buy=M.buy
        if M.unresolved==buy and buy.entry and buy.entry.isCommodity and buy.actualTotal
            and (buy.state=="submitting" or buy.state=="uncertain") then
            finishBuy(buy.quantity,buy.actualTotal)
        end
    elseif event == "COMMODITY_PURCHASED" then
        local itemID,quantity=...
        if M.unresolved==M.buy and M.buy.entry.isCommodity and itemID==M.buy.itemID then
            -- Details can precede the payload-free SUCCEEDED notification.
            -- Keep ownership until that terminal event so its late arrival
            -- cannot be mistaken for a subsequent purchase's success.
            if quantity==M.buy.quantity then M.buy.receiptQuantity=quantity
            else
                M.buy.state,M.buy.message="uncertain",L["回执数量不一致；请核对邮箱与金币，禁止再次购买"]
                M.buy.cancelRequested=true
                emit("market:buy",M.buy)
            end
        end
    elseif event == "COMMODITY_PURCHASE_FAILED" or event == "COMMODITY_PRICE_UNAVAILABLE" then
        if M.buy.state=="awaiting_quote" or M.buy.state=="submitting" or M.buy.state=="uncertain" then
            if event=="COMMODITY_PURCHASE_FAILED" then M.unresolved=nil end
            if not M.unresolved then failBuy(L["商品购买失败或报价不可用"]) end
        end
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
        local auctionID=...
        if M.unresolved==M.buy and not M.buy.entry.isCommodity and auctionID==M.buy.auctionID then
            finishBuy(M.buy.quantity,M.buy.expectedTotal)
        end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" and M.scan.active and M.scan.sent and not M.scan.processing then
        M.scan.processing=true
        M.scan.state="processing"
        M.scan.total=AH.GetNumReplicateItems()
        processScanBatch()
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        if M.postActive==M.post and M.post then
            if not M.post.commodity and M.post.quantity>1 then M.post.auctionID=...
            else postCompleted(M.post,...) end
        end
    elseif event == "AUCTION_MULTISELL_UPDATE" then
        local posted,total=...
        local post=M.postActive
        if post and not post.commodity and total==post.quantity then
            post.posted=posted
            if posted==total then postCompleted(post) end
        end
    elseif event == "AUCTION_HOUSE_POST_ERROR" then
        if M.postActive==M.post and M.post then
            M.post.state="failed"; M.postActive=nil; emit("market:post",M.post)
            if M.post.clear==M.clear then clearChanged(M.clear,"failed",L["上架失败，已停止后续"]) end
        end
    elseif event == "AUCTION_MULTISELL_FAILURE" then
        local post=M.postActive
        if post and not post.commodity then
            post.state="failed"; M.postActive=nil; emit("market:post",post)
            if post.clear==M.clear then clearChanged(M.clear,"failed",L["批量上架中断，请核对已上架数量"]) end
        end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local source,action=...
        local post=M.postActive
        local buy=M.buy
        if source==addonName and type(action)=="string"
            and ((action:find("CommoditiesPurchase",1,true)
                and (buy.state=="awaiting_quote" or buy.state=="submitting"))
                or (action:find("PlaceBid",1,true) and buy.state=="submitted")
                or (action=="UNKNOWN()" and activeTransaction=="buy"
                    and (buy.state=="awaiting_quote" or buy.state=="submitting" or buy.state=="submitted"))) then
            M.unresolved=nil
            resetBuy()
            buy.state,buy.message="needs-click",L["客户端要求再次点击，请继续购买"]
            emit("market:buy",buy)
        end
        if source==addonName and type(action)=="string"
            and (action:find("Post",1,true) or (action=="UNKNOWN()" and activeTransaction=="post"))
            and post and post.state=="submitted" then
            post.state="needs-click"; M.postActive=nil
            if post.clear==M.clear then clearChanged(M.clear,"needs-click",L["请点击继续上架"]) end
            emit("market:post",post)
        end
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        M.browseState.pending,M.browseState.active=nil,nil
        M.browseState.done=true
        emit("market:error",L["浏览失败，请重试"])
    elseif event == "AUCTION_HOUSE_SHOW_ERROR"
        or (event=="AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and activeTransaction=="buy") then
        if activeTransaction=="post" then
            rejectPost(M.postActive,L["上架被拒绝，请重新选择物品"])
        elseif activeTransaction=="buy" then
            local buy=M.buy
            if buy.state=="awaiting_quote" or buy.state=="submitting" or buy.state=="submitted" then
                M.unresolved=nil
                cancelTimer(buy)
                buy.state,buy.message="failed",L["购买失败"]
                pruneIncoming()
                emit("market:buy",buy)
            end
        end
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if activeTransaction=="post" then
            rejectPost(M.postActive,L["服务器丢弃了请求，请重试"])
            return
        end
        M.Cancel()
        emit("market:error",L["服务器丢弃了请求，请重试"])
    elseif event == AUCTION_HOUSE_CLOSED then
        M.open=false
        if M.post then
            if M.post.timer then M.post.timer:Cancel() end
            if M.post.state=="submitted" then M.post.state="uncertain"
            elseif M.post.state=="warning" then M.post.state="cancelled" end
        end
        M.ReleaseTransient()
    end
end

function M.CancelScan()
    local scan=M.scan
    if not scan or not scan.active then return false end
    if scan.timer then scan.timer:Cancel() end
    if scan.batchTimer then scan.batchTimer:Cancel() end
    if M.pending==scan.request then M.pending=nil end
    scan.state="cancelled"
    scan.elapsed=(GetTime and GetTime() or scan.startedAt or 0)-(scan.startedAt or 0)
    scan.active=false
    scan.items=nil
    scan.prepared=nil
    scan.pending=nil
    scan.pendingByItemID=nil
    scan.requestedItemIDs=nil
    emit("market:scan_cancelled",scan)
    return true
end

function M.Cancel()
    M.CancelClearBags()
    if M.listRefresh.state=="quoting" then M.listRefresh.state="cancelled"; emit("market:list",M.listRefresh) end
    if M.post and M.post.state=="warning" then
        M.post.state="cancelled"
        if M.post.timer then M.post.timer:Cancel() end
    end
    if M.browseState.timer then M.browseState.timer:Cancel() end
    if M.search and M.search.timer then M.search.timer:Cancel() end
    M.CancelScan()
    M.browseState.pending,M.browseState.active,M.search,M.pending=nil,nil,nil,nil
    M.browseState.done=true
    M.CancelBuy()
    pruneIncoming()
    return true
end

-- Releases data owned by the visible auction window. A submitted transaction
-- still needs its receipt handler, so retain only the current item and timer
-- until Blizzard reports the outcome.
function M.ReleaseTransient()
    local unresolvedBuy = M.unresolved
    local activePost = M.postActive
    M.Cancel()

    if unresolvedBuy then
        local current = unresolvedBuy.tasks and unresolvedBuy.tasks[unresolvedBuy.index]
            or unresolvedBuy.entry
        clearTable(unresolvedBuy.entries)
        clearTable(unresolvedBuy.tasks)
        unresolvedBuy.entries = nil
        unresolvedBuy.tasks = current and { current } or {}
        unresolvedBuy.index = 1
        unresolvedBuy.quoteIndex = nil
        unresolvedBuy.source = nil
        if current then current.restockEntry = nil end
        unresolvedBuy.entry = current
        M.buy = unresolvedBuy
    else
        M.buy = {}
    end

    if activePost then
        activePost.clear = nil
        activePost.clearIndex = nil
        activePost.clearEntry = nil
        M.post = activePost
        M.postActive = activePost
    else
        M.post = {}
        M.postActive = nil
    end

    clearTable(M.results)
    clearTable(M.browse)
    clearTable(M.quotes)
    clearTable(itemDataRequests)
    M.search = nil
    M.pending = nil
    cancelTimer(M.browseState)
    clearTable(M.browseState)
    M.browseState.done = true
    clearTable(M.listRefresh)
    clearTable(M.clear)
    clearTable(M.scan)
    pruneIncoming()
    observations, observationOrder = {}, {}
    return true
end

function M.Snapshot()
    local labels={quoting=L["正在逐项获取清单报价"],ready=L["清单报价就绪，请确认总额"],["needs-click"]=L["请点击继续购买下一项"],
        awaiting_quote=L["等待服务器确认商品价格"],submitting=L["等待商品购买回执"],submitted=L["等待购买回执"],
        complete=L["本次清单购买完成"],cancelled=L["已取消"],failed=L["购买失败"]}
    if M.scan.active and M.scan.startedAt then
        M.scan.elapsed=(GetTime and GetTime() or M.scan.startedAt)-M.scan.startedAt
    end
    local message=M.buy.message or labels[M.buy.state] or L["就绪"]
    if M.scan.active then message=format(L["全量扫描中：%d / %d"],M.scan.index,M.scan.total) end
    return {open=M.open,results=M.results,browse=M.browse,buy=M.buy,scan=M.scan,post=M.post,message=message}
end

return M

