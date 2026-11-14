-- One professional posting adapter; all protected calls belong to Market.
local addonName, ns = ... -- luacheck: ignore addonName
local type, pairs, ipairs = type, pairs, ipairs
local floor, max, min = math.floor, math.max, math.min
local L = ns.L
local P = {}; ns.ProfessionPosting = P
local sequence, active = 0, nil
local held={submitted=true,submitting=true,warning=true,['needs-click']=true,uncertain=true}
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for key,entry in pairs(value) do result[key]=copy(entry) end; return result
end
local function integer(value,minimum,maximum)
    return type(value)=='number' and value==value and value>=minimum and value<=maximum and floor(value)==value
end
local function clock() return ns.Now() end
local function sync()
    if active and active.post then
        active.state=active.post.state
        active.error=active.post.message
    end
end
local function busy()
    local market=ns.Market
    return market.IsBusy and market.IsBusy() or market.unresolved or market.postActive
        or (market.scan and market.scan.active)
end
local function changed(request,state,error)
    if active~=request then return end
    request.state,request.error=state,error
    if ns.Emit then ns.Emit('professions:post',P.Snapshot()) end
end
local function bagFor(request)
    for index,row in ipairs(ns.Market.Bags()) do
        if row.bag==request.bag and row.slot==request.slot and ns.Store.Key(row.itemKey)==ns.Store.Key(request.itemKey)
            and row.quantity>=request.quantity and not ns.Market.IsLocked(row.itemKey) then return row end
    end
end
local function quote(request,rows,observedAt)
    if active~=request or request.state~='quoting' then return end
    local minimum
    for index,row in ipairs(rows) do
        if integer(row.unitPrice,1,9007199254740991) and (row.available or 0)>0 then
            minimum=minimum and min(minimum,row.unitPrice) or row.unitPrice
        end
    end
    -- Only an actual current quote can authorize this adapter's sale price.
    if not minimum then changed(request,'failed',L['没有可核验的竞争报价，请在闪卖中手动定价。']); return end
    local root=ns.Store.GetDB(); local settings=root.settings or {}
    local price=minimum
    if settings.undercut==true then price=max(1,price-ns.ProfessionSettings.Get('undercutCopper')) end
    request.unitPrice=ns.Market.NormalizePostPrice(price)
    request.quoteAt=observedAt or clock(); request.quoteExpires=request.quoteAt+30
    local economics=ns.Professions and ns.Professions.GetRanked and ns.Professions.GetRanked({includeUnpriceable=true,
        ignorePostLimit=true,accountWide=true}) or {}
    for index,row in ipairs(economics) do
        if request.recipeID and row.recipeID==request.recipeID and row.cost then
            local cost=row.costPerUnit or (row.cost / max(1,row.outputCount or row.numMade or 1))
            if request.unitPrice*(1-ns.ProfessionSettings.Get('auctionCut'))<cost
                and not ns.ProfessionSettings.Get('allowPostingAtALoss') then
                changed(request,'failed',L['预计亏本，当前设置不允许推荐此价格。']); return
            end
            break
        end
    end
    changed(request,'ready')
end
function P.Prepare(input)
    sync()
    if active and held[active.state] then return nil,L['交易回执尚未确定，请核对并处理完成后重置。'] end
    if type(input)~='table' or (input.version~=nil and input.version~=1)
        or (input.source~=nil and input.source~='professions') or not ns.Store.Key(input.itemKey)
        or not integer(input.bag,0,20) or not integer(input.slot,1,1000)
        or not integer(input.quantity,1,999999) then return nil,'invalid-request' end
    if not ns.Market.open then return nil,L['请先打开拍卖行'] end
    if busy() then return nil,L['拍卖行繁忙，请稍后继续上架'] end
    local duration=input.duration or ns.ProfessionSettings.Get('postDuration')
    if not integer(duration,1,3) then return nil,'invalid-duration' end
    P.Cancel()
    sequence=sequence+1
    local request={version=1,source='professions',requestID=sequence,itemKey=copy(input.itemKey),
        recipeID=input.recipeID,bag=input.bag,slot=input.slot,quantity=input.quantity,duration=duration,state='quoting'}
    local row=bagFor(request); if not row then return nil,L['背包物品已变化，请重新选择'] end
    active=request
    local cached=ns.Market.quotes[ns.Store.Key(request.itemKey)]
    if not ns.ProfessionSettings.Get('verifyPriceBeforePosting') and cached and cached.timestamp
        and clock()-cached.timestamp>=0 and clock()-cached.timestamp<=30 and cached.rows then
        quote(request,cached.rows,cached.timestamp)
    else
        local ok=ns.Market.Search(row.itemKey,function(rows) quote(request,rows) end,
            function(error) if active==request then changed(request,'failed',error) end end)
        if not ok then changed(request,'failed',L['拍卖行繁忙，请稍后继续上架']); return nil,request.error end
        request.search=ns.Market.search
    end
    return request.requestID
end
function P.Submit(requestID)
    sync(); local request=active
    if not request or request.requestID~=requestID or request.state~='ready' then return false,'not-ready' end
    if not ns.Market.open or busy() then return false,L['拍卖行繁忙，请稍后继续上架'] end
    if clock()<request.quoteAt or clock()>request.quoteExpires then
        changed(request,'failed',L['报价已过期，请重新核价。']); return false,request.error
    end
    local row=bagFor(request)
    if not row then changed(request,'failed',L['背包物品已变化，请重新选择']); return false,request.error end
    request.state='submitting'
    local previous=ns.Market.post
    local ok,error=ns.Market.Post(row,request.quantity,request.unitPrice,request.duration,nil,{
        source='professions',requestID=requestID,quoteAt=request.quoteAt,quoteExpires=request.quoteExpires})
    if ns.Market.post and ns.Market.post~=previous then
        request.post=ns.Market.post
        sync()
    else changed(request,'failed',error or L['拍卖行繁忙，请稍后继续上架']) end
    return ok,error
end
function P.Cancel()
    sync(); if not active then return true end
    if held[active.state] then return false,'pending-receipt' end
    local request=active; active=nil
    if request.search and ns.Market.CancelSearch then ns.Market.CancelSearch(request.search) end
    return true
end
function P.Snapshot()
    sync(); if not active then return {state='idle'} end
    local result={}
    for key,value in pairs(active) do if key~='post' and key~='search' then result[key]=copy(value) end end
    return result
end
function P.OnEvent(event)
    sync()
    if event=='AUCTION_HOUSE_CLOSED' and active and not held[active.state] then P.Cancel() end
end
