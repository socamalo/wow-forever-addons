-- luacheck: ignore addonName
local addonName, ns = ...
local TooltipDataProcessor, Enum = TooltipDataProcessor, Enum
local C_Item, C_AuctionHouse, GetMoneyString = C_Item, C_AuctionHouse, GetMoneyString
local issecretvalue, canaccesstable = issecretvalue, canaccesstable
local type, tonumber, tostring, select, pairs, setmetatable = type, tonumber, tostring, select, pairs, setmetatable
local floor = math.floor
local L = ns.L
local T = {}; ns.ItemTooltip = T
local registered
local visibleItems=setmetatable({}, {__mode="k"})

local function readable(value)
    return not issecretvalue or not issecretvalue(value)
end

-- Match the price database's auction identity, never another quality ID or item level.
local function itemKey(link)
    if not readable(link) or type(link)~="string" then return end
    local payload=link:match("item:([^|]+)")
    if not payload then return end
    local fields={}
    for part in (payload..":"):gmatch("([^:]*):") do fields[#fields+1]=part end
    local id=tonumber(fields[1])
    if not id or id<=0 then return end
    local key={itemID=id,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
    local info=C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(key)
    if info and readable(info.isCommodity) and info.isCommodity then return key end
    if not C_Item or not C_Item.GetItemInfoInstant then return end
    local classID=select(6,C_Item.GetItemInfoInstant(link))
    if not readable(classID) or not classID then return end
    -- Caged pets require a species identity; an item:82800 link is insufficient.
    if id==82800 then return end
    key.itemSuffix=tonumber(fields[7]) or 0
    if classID==2 or classID==4 then
        local level=C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
        if not readable(level) or type(level)~="number" or level<=0 then return end
        key.itemLevel=level
    end
    return key
end

function T.Append(tooltip, data)
    local db=ns.Store.GetDB()
    if not db or not db.settings or db.settings.itemTooltip~=true then return end
    if not readable(data) or type(data)~="table" or (canaccesstable and not canaccesstable(data)) then return end
    if not readable(data.id) or type(data.id)~="number" then return end
    if not tooltip.GetItem or not tooltip.GetPrimaryTooltipData then return end
    -- Ignore appended reagent/embedded tooltips; each rebuild clears and adds one line.
    if tooltip:GetPrimaryTooltipData()~=data then return end
    if ns.Prices and ns.Prices.Revision then
        visibleItems[tooltip]={data=data,revision=ns.Prices.Revision()}
    end
    local link=select(2,tooltip:GetItem())
    local key
    local owner=tooltip.GetOwner and tooltip:GetOwner()
    local override=owner and type(owner._easyAuctionKey)=="table" and owner._easyAuctionKey or nil
    if override and override.itemID==data.id then
        -- W.Tooltip 的 SetItemKey 气泡没有实例链接：用行数据自带的 itemKey 查库，
        -- 身份才与行情库一致（含正确的物品等级）。
        key=override
    else
        key=itemKey(link)
        if not key and readable(data.id) then
            key={itemID=data.id,itemLevel=0,itemSuffix=0,battlePetSpeciesID=0}
        end
    end
    if not key or key.itemID~=data.id then return end
    local entry=ns.Store.GetItems()[ns.Store.Key(key)]
    if not entry or not entry.last or entry.last<=0 then return end
    local quantity=entry.quantity
    if entry.bookStatus=="empty" then quantity=0
    elseif quantity==nil and entry.bookStatus=="fresh" then
        quantity=entry.bookQuantity
    end
    if quantity==nil and entry.updated and entry.h then
        local bucket=entry.h[floor(entry.updated/3600)]
        if bucket and bucket[3]==entry.last then quantity=bucket[6] end
    end
    local style = ns.Style
    local tip, accent, gold, muted = {0.82,0.92,0.86}, {0.95,0.78,0.25}, {0.95,0.78,0.25}, {0.66,0.70,0.72}
    if style and style.TooltipColors then
        -- TooltipColors 返回五个独立颜色表（text,muted,tip,accent,gold）；
        -- 若当成单表下标取值，拿到的是数字分量，下方索引 valueColor[1] 会断行。
        local mutedColor, tipColor, accentColor, goldColor = select(2,style:TooltipColors())
        muted=mutedColor or muted; tip=tipColor or tip; accent=accentColor or accent; gold=goldColor or gold
    end
    -- GetMoneyString 内嵌白色高亮色码，替换为主题金色让金额跟随主题；离线桩无色码时保持原文。
    local price=GetMoneyString(entry.last,true)
    if type(price)=="string" and price:find("|cff",1,true) then
        price=price:gsub("|cff%x%x%x%x%x%x",string.format("|cff%02X%02X%02X",
            floor(gold[1]*255+0.5),floor(gold[2]*255+0.5),floor(gold[3]*255+0.5)))
    end
    local count=tonumber(quantity)
    local valueColor=count and count>0 and tip or (count==0 and {0.95,0.45,0.42} or muted)
    if quantity==nil and entry.bookStatus=="empty" then quantity=0; valueColor={0.95,0.45,0.42} end
    tooltip:AddDoubleLine("» "..L["拍卖价"],price,accent[1],accent[2],accent[3],gold[1],gold[2],gold[3])
    tooltip:AddDoubleLine("» "..L["在售数"],tostring(quantity or "—"),accent[1],accent[2],accent[3],
        valueColor[1],valueColor[2],valueColor[3])
end

function T.Refresh()
    if not ns.Prices or not ns.Prices.Revision then return end
    local revision=ns.Prices.Revision()
    for tooltip,record in pairs(visibleItems) do
        if record.revision~=revision and not (tooltip.IsForbidden and tooltip:IsForbidden())
            and tooltip.IsShown and tooltip:IsShown()
            and tooltip.GetPrimaryTooltipData and tooltip.RefreshDataNextUpdate then
            local data=tooltip:GetPrimaryTooltipData()
            if readable(data) and data==record.data then
                record.revision=revision
                tooltip:RefreshDataNextUpdate()
            end
        end
    end
end

function T.Init()
    if registered or not TooltipDataProcessor or not TooltipDataProcessor.AddTooltipPostCall
        or not Enum or not Enum.TooltipDataType then return end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,T.Append)
    registered=true
end
