-- Adapted from Blackthornes Inventory: one bag walk, event invalidation, snapshots.
-- luacheck: read globals GetInboxNumItems GetInboxItem GetInboxInvoiceInfo GetInboxHeaderInfo
-- luacheck: read globals GetMerchantNumItems GetMerchantItemInfo GetMerchantItemLink
-- luacheck: read globals C_MerchantFrame
local addonName, ns = ... -- luacheck: ignore addonName
local C_Container, C_Item, C_AuctionHouse, Enum = C_Container, C_Item, C_AuctionHouse, Enum
local C_MerchantFrame = C_MerchantFrame
local GetMoney, NUM_BAG_SLOTS = GetMoney, NUM_BAG_SLOTS
local GetInboxNumItems, GetInboxItem = GetInboxNumItems, GetInboxItem
local GetInboxInvoiceInfo, GetInboxHeaderInfo = GetInboxInvoiceInfo, GetInboxHeaderInfo
local GetMerchantNumItems, GetMerchantItemInfo = GetMerchantNumItems, GetMerchantItemInfo
local GetMerchantItemLink = GetMerchantItemLink
local type, pairs, tonumber, tostring, pcall = type, pairs, tonumber, tostring, pcall
local max = math.max
local concat, sort, remove = table.concat, table.sort, table.remove
local E = ns.ProfessionEngine
local I = {}
E.Inventory = I

function I.Refresh()
    if not E.current then return end
    local counts = {}
    if C_Container then
        for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
            local slots = E.Call(C_Container.GetContainerNumSlots, bag) or 0
            for slot = 1, slots do
                local info = E.Call(C_Container.GetContainerItemInfo, bag, slot)
                if info and E.Integer(info.itemID, 1) and E.Integer(info.stackCount, 0) then
                    counts[info.itemID] = (counts[info.itemID] or 0) + info.stackCount
                end
            end
        end
    end
    E.current.inventory, E.current.inventoryAt = counts, E.Now()
    E.current.gold = E.Call(GetMoney)
    E.Changed()
end

function I.Count(itemID, character, source)
    local record = E.db and E.db.characters[character or E.character]
    return record and record[source or "inventory"] and record[source or "inventory"][itemID] or 0
end

function I.Owned(itemID, character)
    local held = I.Count(itemID, character) + I.Count(itemID, character, "bank")
    if E.Setting("countMailAsStock", true) then held = held + I.Count(itemID, character, "mail") end
    return held
end

function I.AltCount(itemID)
    local total = 0
    for character in pairs(E.db.characters) do
        if character ~= E.character then total = total + I.Owned(itemID, character) end
    end
    return total
end

function I.ReadBank()
    if not E.current or not C_Item or not C_Item.GetItemCount then return end
    local ids = {}
    for itemID in pairs(E.current.bank) do ids[itemID] = true end
    for itemID in pairs(E.current.inventory) do ids[itemID] = true end
    for recipeID, recipe in pairs(E.current.recipes) do -- luacheck: ignore recipeID
        if recipe.outputItemID then ids[recipe.outputItemID] = true end
        for index = 1, #(recipe.reagents or {}) do ids[recipe.reagents[index].itemID] = true end
    end
    for itemID in pairs(ids) do
        -- Subtract two counts with identical equipped-item semantics. Warband
        -- stock stays excluded, so it is not counted once per character.
        local total = E.Call(C_Item.GetItemCount, itemID, true, false, true, false)
        local carried = E.Call(C_Item.GetItemCount, itemID, false, false, false, false)
        if E.Integer(total, 0) and E.Integer(carried, 0) then E.current.bank[itemID] = max(0, total - carried) end
    end
    E.current.bankAt = E.Now()
    E.Changed()
end

function I.ReadOwnedAuctions()
    if not E.current or not C_AuctionHouse then return end
    local count = E.Call(C_AuctionHouse.GetNumOwnedAuctions)
    if not E.Integer(count, 0) then return end
    local posted = {}
    local active = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active or 0
    for index = 1, count do
        local row = E.Call(C_AuctionHouse.GetOwnedAuctionInfo, index)
        if row and row.itemKey and row.status == active then
            local itemID, quantity = row.itemKey.itemID, E.Integer(row.quantity, 0)
            if itemID and quantity then posted[itemID] = (posted[itemID] or 0) + quantity end
        end
    end
    E.current.posted, E.current.postedAt = posted, E.Now()
    E.Changed()
end

function I.ReadVendor()
    local count = E.Call(GetMerchantNumItems)
    if not E.Integer(count, 0) then return end
    for index = 1, count do
        local link = E.Call(GetMerchantItemLink, index)
        local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)"))
        local info = C_MerchantFrame and E.Call(C_MerchantFrame.GetItemInfo, index)
        local ok, name, price, quantity, available, extended
        if type(info) == "table" then
            ok, name, price, quantity = true, info.name, info.price, info.stackCount
            available, extended = info.numAvailable, info.hasExtendedCost
        else
            local result = { pcall(GetMerchantItemInfo, index) }
            ok, name, price, quantity = result[1], result[2], result[4], result[5]
            available, extended = result[6], result[9]
        end
        if ok and itemID and E.Integer(price, 1) and E.Integer(quantity, 1) and not extended then
            E.db.vendorPrices[itemID] = { unitPrice = price / quantity, limited = available ~= -1,
                name = name, updated = E.Now() }
        end
    end
    E.Changed()
end

function I.ReadMail()
    if not E.current then return end
    local count = E.Call(GetInboxNumItems)
    if not E.Integer(count, 0) then return end
    local stock, seen, previous = {}, {}, E.current.mailSeen or {}
    for index = 1, count do
        for attachment = 1, 16 do
            if type(GetInboxItem) == "function" then
                local result = { pcall(GetInboxItem, index, attachment) }
                local ok, itemID, quantity = result[1], result[3], result[5]
                if ok and E.Integer(itemID, 1) and E.Integer(quantity, 1) then
                    stock[itemID] = (stock[itemID] or 0) + quantity
                end
            end
        end
        if type(GetInboxInvoiceInfo) == "function" and type(GetInboxHeaderInfo) == "function" then
            local ok, kind, name, buyer, bid, buyout, deposit, cut = pcall(GetInboxInvoiceInfo, index)
            local header = { pcall(GetInboxHeaderInfo, index) }
            if ok and kind == "seller" and type(name) == "string" and header[1] then
                local gross = tonumber(buyout) or tonumber(bid)
                local money = tonumber(header[6]) or 0
                local amount = money > 0 and money or (gross and gross - (tonumber(cut) or 0) + (tonumber(deposit) or 0))
                -- Occurrence counts preserve identical simultaneous invoices.
                -- Only currently observed messages participate; no invented auction ID.
                local key = concat({ name, tostring(buyer), tostring(bid), tostring(buyout), tostring(deposit) }, "|")
                seen[key] = (seen[key] or 0) + 1
                if amount and amount > 0 and seen[key] > (previous[key] or 0) then
                    E.db.sales[#E.db.sales + 1] = { kind = "sold", name = name, itemName = name,
                        amount = amount, gross = gross, at = E.Now(), character = E.character,
                        source = "mail-invoice", estimated = money <= 0 }
                end
            end
        end
    end
    E.current.mail, E.current.mailAt, E.current.mailSeen = stock, E.Now(), seen
    while #E.db.sales > 2000 do remove(E.db.sales, 1) end
    E.Changed()
end

function I.Characters()
    local rows = {}
    if not E.db then return rows end
    for character, record in pairs(E.db.characters) do
        local count = 0
        for recipeID in pairs(record.recipes or {}) do if recipeID then count = count + 1 end end
        rows[#rows + 1] = { key = character, name = record.name or character, realm = record.realm,
            isCurrent = character == E.character, recipeCount = count, professions = record.professions or {},
            inventoryAt = record.inventoryAt, bankAt = record.bankAt, gold = record.gold }
    end
    sort(rows, function(a, b)
        if a.isCurrent ~= b.isCurrent then return a.isCurrent end
        return a.key < b.key
    end)
    return rows
end
