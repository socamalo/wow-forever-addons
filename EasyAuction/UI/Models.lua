-- Pure display models. Bag instances remain separate; price levels aggregate supply.
local addonName, ns = ... -- luacheck: ignore addonName
local type, tostring, pairs, select, setmetatable = type, tostring, pairs, select, setmetatable
local sort = table.sort
local min, max, huge, floor = math.min, math.max, math.huge, math.floor
local lower, find = string.lower, string.find
local C_Item, time, globals = C_Item, time, _G

local L = ns.L
local Model={}
ns.ViewModel=Model
local metadataCache=setmetatable({}, {__mode="k"})
local historyCache=setmetatable({}, {__mode="k"})
local categories={
    {id="materials",name=L["材料"]},
    {id="consumables",name=L["消耗品"]},
    {id="equipment",name=L["装备"]},
    {id="gems",name=L["宝石"]},
    {id="recipes",name=L["配方"]},
    {id="pets",name=L["宠物"]},
    {id="other",name=L["其他"]},
}
local categoryIndex={[7]=1,[0]=2,[2]=3,[4]=3,[3]=4,[9]=5,[17]=6}
Model.Categories=categories

local categoryIcons={
    [0]="INV_Potion_54",[1]="INV_Misc_Bag_08",[2]="INV_Sword_04",[3]="INV_Misc_Gem_01",
    [4]="INV_Chest_Plate04",[7]="INV_Ingot_02",[8]="INV_Enchant_FormulaGood_01",[9]="INV_Scroll_03",[12]="INV_Misc_Book_09",
    [15]="INV_Misc_Gift_01",[16]="INV_Inscription_Tradeskill01",[17]="INV_Box_PetCarrier_01",
    [19]="Trade_BlackSmithing",
}

-- Read the loaded Blizzard category data so labels, order and filter unions stay native.
-- Only two levels are exposed; third-level implicit server filters are not local price filters.
function Model.AuctionCategories()
    local result={}
    local function copyCategory(source,id,includeChildren)
        local category={id=id,name=source.name,children={},filters={}}
        for index=1,#(source.filters or {}) do
            local filter=source.filters[index]
            category.filters[index]={classID=filter.classID,subClassID=filter.subClassID,inventoryType=filter.inventoryType}
        end
        local first=category.filters[1]
        category.icon="Interface\\Icons\\"..(categoryIcons[first and first.classID] or "INV_Misc_QuestionMark")
        if first and first.classID==20 then category.atlas="housing-icon-dashboard" end
        if includeChildren then
            for index=1,#(source.subCategories or {}) do
                category.children[index]=copyCategory(source.subCategories[index],id..":"..index,false)
            end
        end
        return category
    end
    for index=1,#(globals.AuctionCategories or {}) do
        local source=globals.AuctionCategories[index]
        local first=source.filters and source.filters[1]
        local isToken=source.flags and source.flags.WOW_TOKEN_FLAG
        if not isToken and not (first and first.classID==18) then
            -- Preserve native IDs when omitting the token category, including categories after it.
            result[#result+1]=copyCategory(source,"native:"..index,true)
        end
    end
    return result
end

function Model.GroupBags(bags)
    local buckets,groups={},{}
    for index=1,#bags do
        local row=bags[index]
        local groupIndex=categoryIndex[row.classID] or 7
        local bucket=buckets[groupIndex]
        if not bucket then bucket={}; buckets[groupIndex]=bucket end
        bucket[#bucket+1]={row=row,index=index,name=tostring(row.name or row.itemID or "")}
    end
    for groupIndex=1,#categories do
        local bucket=buckets[groupIndex]
        if bucket then
            sort(bucket,function(a,b)
                if a.name==b.name then return a.index<b.index end
                return a.name<b.name
            end)
            local category=categories[groupIndex]
            local group={id=category.id,name=category.name,items={}}
            for index=1,#bucket do group.items[index]=bucket[index].row end
            groups[#groups+1]=group
        end
    end
    return groups
end

local function finite(value)
    return type(value)=="number" and value==value and value>-huge and value<huge
end

local function positivePrice(value)
    return finite(value) and value>0 and value or nil
end

function Model.BagValue(bags,items)
    local total,pricedCount,missingCount=0,0,0
    for index=1,#(bags or {}) do
        local bag=bags[index]
        local quantity=bag.quantity
        if finite(quantity) and quantity>0 then
            local key=bag.key or (ns.Store and ns.Store.Key(bag.itemKey))
            local entry=items and key and items[key]
            local price=entry and positivePrice(entry.last)
            if price then
                total,pricedCount=total+price*quantity,pricedCount+1
            else
                missingCount=missingCount+1
            end
        end
    end
    return total,pricedCount,missingCount
end

local function itemMetadata(entry,resolve)
    local itemID=entry.itemID or (entry.itemKey and entry.itemKey.itemID)
    local classID,subClassID=entry.classID,entry.subClassID
    if not resolve then
        return tostring(entry.name or itemID or entry.key or ""),categories[categoryIndex[classID] or 7].id,
            classID,subClassID,itemID
    end
    local cached=metadataCache[entry]
    if cached and cached.itemID==itemID and cached.nameSource==entry.name
        and cached.classSource==classID and cached.subclassSource==subClassID
        and (not resolve or cached.resolved) then
        return cached.name,cached.category,cached.classID,cached.subClassID,cached.itemID
    end
    if resolve and (classID==nil or subClassID==nil) and itemID and C_Item and C_Item.GetItemInfoInstant then
        local resolvedClass,resolvedSubclass=select(6,C_Item.GetItemInfoInstant(entry.link or itemID))
        classID,subClassID=classID or resolvedClass,subClassID or resolvedSubclass
    end
    local name=entry.name
    -- Saved names may come from a different client language; prefer current game data.
    if resolve and itemID and C_Item and C_Item.GetItemInfo then
        name=C_Item.GetItemInfo(entry.link or itemID) or name
    end
    local category=categories[categoryIndex[classID] or 7].id
    metadataCache[entry]={name=tostring(name or itemID or entry.key or ""),category=category,
        classID=classID,subClassID=subClassID,itemID=itemID,nameSource=entry.name,
        classSource=entry.classID,subclassSource=entry.subClassID,resolved=resolve==true}
    cached=metadataCache[entry]
    return cached.name,cached.category,cached.classID,cached.subClassID,cached.itemID
end

local function historySummary(entry,currentHour,oldest)
    local current=entry.h and entry.h[currentHour]
    local cached=historyCache[entry]
    local currentMinimum=current and current[1]
    local currentMaximum=current and current[2]
    local currentLast=current and current[3]
    local currentCount=current and current[5]
    if cached and cached.hour==currentHour and cached.oldest==oldest and cached.updated==entry.updated
        and cached.minimum==currentMinimum and cached.maximum==currentMaximum
        and cached.last==currentLast and cached.count==currentCount then
        return cached.low,cached.high
    end
    local low,high
    for hour,bucket in pairs(entry.h or {}) do
        if finite(hour) and hour>=oldest and hour<=currentHour and type(bucket)=="table" then
            local minimum,maximum=positivePrice(bucket[1]),positivePrice(bucket[2])
            if minimum and maximum and maximum>=minimum and positivePrice(bucket[5]) then
                low=low and min(low,minimum) or minimum
                high=high and max(high,maximum) or maximum
            end
        end
    end
    historyCache[entry]={hour=currentHour,oldest=oldest,updated=entry.updated,
        minimum=currentMinimum,maximum=currentMaximum,last=currentLast,count=currentCount,low=low,high=high}
    return low,high
end

function Model.InvalidateItem(itemID)
    if itemID==nil then return end
    for entry,cached in pairs(metadataCache) do
        if cached.itemID==itemID then metadataCache[entry]=nil end
    end
end

function Model.ClearCache()
    metadataCache=setmetatable({}, {__mode="k"})
    historyCache=setmetatable({}, {__mode="k"})
end

local function matchesCategory(category,legacyCategory,entry,classID,subClassID,itemID)
    if not category or category=="all" then return true end
    if type(category)~="table" then return category==legacyCategory end
    if category.id=="all" then return true end
    local filters=category.filters or {category}
    local inventoryType=entry.inventoryType
    for index=1,#filters do
        local filter=filters[index]
        if (filter.classID==nil or filter.classID==classID) and (filter.subClassID==nil or filter.subClassID==subClassID) then
            if filter.inventoryType==nil then return true end
            if inventoryType==nil and itemID and C_Item and C_Item.GetItemInventoryTypeByID then
                inventoryType=C_Item.GetItemInventoryTypeByID(entry.link or itemID)
            end
            if inventoryType==filter.inventoryType then return true end
        end
    end
    return false
end

---Builds sortable price summaries without mutating saved observations or item identities.
function Model.PriceRows(items,options)
    options=options or {}
    local result={}
    local currentHour=floor((ns.Now and ns.Now() or time and time() or 0)/3600)
    local oldest=currentHour-719
    local query=lower(tostring(options.query or ""))
    local list=options.list and options.list.items
    local resolveMetadata=options.resolveMetadata~=false
    for mapKey,entry in pairs(items or {}) do
        local key=entry.key or (type(mapKey)=="string" and mapKey)
        local name,category,classID,subClassID,itemID=itemMetadata(entry,resolveMetadata)
        local categoryMatches=matchesCategory(options.category,category,entry,classID,subClassID,itemID)
        local listMatches=not options.list or (list and key and list[key])
        local queryMatches=query=="" or find(lower(name),query,1,true) or find(tostring(key or ""),query,1,true)
        if key and categoryMatches and listMatches and queryMatches then
            local low,high=historySummary(entry,currentHour,oldest)
            local latest=positivePrice(entry.last)
            result[#result+1]={item=entry,key=key,name=name,low=low or latest,high=high or latest,
                latest=latest,updated=entry.updated,category=category,hasHistory=low~=nil}
        end
    end
    local sortKey=options.sort or "name"
    if sortKey~="low" and sortKey~="high" and sortKey~="latest" and sortKey~="updated" then sortKey="name" end
    sort(result,function(a,b)
        local left,right=a[sortKey],b[sortKey]
        if left==right then return a.key<b.key end
        -- Missing quotes remain at the bottom in both directions, never become zero prices.
        if left==nil then return false end
        if right==nil then return true end
        if options.descending then return left>right end
        return left<right
    end)
    return result
end

function Model.Distribution(rows)
    local byPrice,levels={},{}
    local maxQuantity,totalQuantity=0,0
    for index=1,#rows do
        local row=rows[index]
        local price,quantity=row.unitPrice,row.quantity
        local hasBuyout=true
        if row.isCommodity~=true then
            if row.buyoutAmount~=nil then hasBuyout=finite(row.buyoutAmount) and row.buyoutAmount>0
            elseif row.totalPrice~=nil then hasBuyout=finite(row.totalPrice) and row.totalPrice>0
            elseif row.isCommodity==false then hasBuyout=false end
        end
        if hasBuyout and finite(price) and price>0 and finite(quantity) and quantity>0 then
            local own=row.ownQuantity or row.numOwnerItems
            if own==nil and finite(row.available) then own=quantity-row.available end
            if own==nil then own=row.owned and quantity or 0 end
            own=finite(own) and min(quantity,max(0,own)) or 0
            local level=byPrice[price]
            if not level then
                level={unitPrice=price,quantity=0,ownQuantity=0}
                byPrice[price]=level
            end
            level.quantity,level.ownQuantity=level.quantity+quantity,level.ownQuantity+own
            totalQuantity=totalQuantity+quantity
        end
    end
    for price,level in pairs(byPrice) do -- luacheck: ignore price
        levels[#levels+1]=level
        maxQuantity=max(maxQuantity,level.quantity)
    end
    sort(levels,function(a,b) return a.unitPrice<b.unitPrice end)
    return levels,maxQuantity,totalQuantity
end
