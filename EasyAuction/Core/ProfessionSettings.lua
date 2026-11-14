-- Unified profession policy. Blackthornes v0.5.0 defaults adapted to Retail.
local addonName, ns = ... -- luacheck: ignore addonName
local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor, huge = math.floor, math.huge
local concat, sort = table.concat, table.sort
local format, byte, char = string.format, string.byte, string.char
local find, gmatch, gsub, match = string.find, string.gmatch, string.gsub, string.match
local L = ns.L
local S = {}; ns.ProfessionSettings = S
local definitions, byKey = {}, {}
local TRANSFER_BYTES, TRANSFER_RECORDS, TRANSFER_QUEUE = 65536, 2000, 1000
S.Definitions, S.Defaults = definitions, {}
local function define(key, group, kind, default, label, help, minimum, maximum, options)
    local entry={key=key,group=group,type=kind,default=default,label=label,help=help,min=minimum,max=maximum,options=options}
    definitions[#definitions+1]=entry; byKey[key]=entry; S.Defaults[key]=default
end
define('valueOwnedMaterials','pricing','boolean',true,L['已持有材料按市价计费'],L['关闭后仅计算缺少材料的采购成本。'])
define('auctionCut','pricing','number',0.05,L['拍卖行手续费率'],L['以小数表示，0.05 表示 5%。'],0,1)
define('expectedRelists','pricing','number',1,L['预计重上架次数'],L['计入预计损失的保证金次数。'],0,100)
define('undercutCopper','pricing','number',100,L['压价金额（铜）'],L['与闪卖共享金额；是否启用由通用设置的自动压价控制。'],100,100000000)
define('unscannedMarkupPercent','pricing','number',50,L['未扫描物品加价比例'],L['估算价仅供参考，不会写入真实价格历史。'],0,1000)
define('priceUnscannedCrafts','pricing','boolean',true,L['使用未扫描估算价'],L['无市场报价时按材料成本及加价比例估算。'])
define('maxPostedPerItem','inventory','number',0,L['每种物品库存上限'],L['0 表示不限；逐物品上限优先。'],0,999999)
define('postDuration','inventory','select',1,L['上架时长'],L['与闪卖共用正式服的上架时长。'],nil,nil,
    {{value=1,label=L['12 小时']},{value=2,label=L['24 小时']},{value=3,label=L['48 小时']}})
define('postShowAllItems','inventory','boolean',true,L['上架显示全部背包物品'],L['关闭后只显示已记录配方的产物。'])
define('verifyPriceBeforePosting','inventory','boolean',true,L['上架前重新核价'],L['关闭后仅复用未过期完整报价，交易校验始终生效。'])
define('confirmBeforePosting','inventory','boolean',true,L['专业上架前确认'],L['始终需要真实点击；关闭后可在点击中使用仍有效的已显示报价。'])
define('allowPostingAtALoss','inventory','boolean',false,L['允许推荐亏本上架'],L['亏本项仍显示风险，确认后才会提交。'])
define('hideAtPostLimit','inventory','boolean',true,L['隐藏库存已满配方'],L['达到全局或逐物品上限时隐藏推荐。'])
define('craftPaneIgnoreLimit','inventory','boolean',false,L['队列忽略库存上限'],L['仅影响加入制作队列，不改动库存上限。'])
define('countMailAsStock','inventory','boolean',true,L['邮件计入库存'],L['只使用实际打开邮箱后记录的库存。'])
define('stockPenalty','inventory','number',1,L['库存对推荐的影响'],L['按利润除以 1 加库存乘权重排序；0 为关闭。'],0,100)
define('staleAfterSeconds','filters','number',172800,L['价格过期时间（秒）'],L['仅标记时效，不删除真实历史。'],60,2592000)
define('minProfit','filters','number',0,L['最低利润（铜）'],L['低于此利润的配方不进入推荐。'],0,9007199254740991)
define('minMarginPercent','filters','number',0,L['最低利润率（%）'],L['按售出收入计算利润率。'],0,100)
define('scanBudgetMs','advanced','number',8,L['每帧扫描预算（毫秒）'],L['同时受单批条数限制，避免长帧阻塞界面。'],2,16)
define('autoScan','advanced','boolean',true,L['打开拍卖行时自动扫描'],L['仅在价格缺失或过期且交易通道空闲时扫描。'])
define('learnFromSearches','advanced','boolean',true,L['记录手动搜索价格'],L['读取已有完整搜索结果，不额外发送请求。'])
define('showValueInProfessionWindow','advanced','boolean',true,L['专业窗口显示估值'],L['在选中配方处显示市场估值，不改动暴雪配方操作。'])
define('showValueOnItemTooltips','advanced','boolean',true,L['物品提示显示价格'],L['与通用设置共用一个提示功能。'])
define('saleAlarm','advanced','boolean',true,L['拍卖售出提示音'],L['仅在客户端明确报告售出时播放。'])
define('autoQueueSubCrafts','advanced','boolean',true,L['自动规划子配方'],L['原料可更便宜制作时规划依赖；制作仍由玩家操作。'])
define('skillUpMarker','advanced','select','star',L['技能提升标记'],L['仅改变显示样式。'],nil,nil,
    {{value='star',label=L['星形']},{value='raid',label=L['团队星标']},{value='pip',label=L['方点']}})
define('debug','advanced','boolean',false,L['调试输出'],L['显示额外诊断信息，不修改交易状态。'])

local function settings()
    local db=ns.Store.GetDB()
    if not db then return nil end
    db.settings=db.settings or {}; db.settings.professions=db.settings.professions or {}
    return db.settings
end
local aliases={undercutCopper='undercutAmount',postDuration='duration',showValueOnItemTooltips='itemTooltip'}
local function valid(entry,value)
    if not entry then return false end
    if entry.type=='boolean' then return type(value)=='boolean' end
    if entry.type=='select' then
        for index,option in ipairs(entry.options) do if option.value==value then return true end end
        return false
    end
    return type(value)=='number' and value==value and value~=huge and value~=-huge
        and value>=entry.min and value<=entry.max and (entry.key=='auctionCut' or entry.key=='stockPenalty'
        or entry.key=='minMarginPercent' or value==floor(value))
end
local function normalize(entry,value)
    if entry.key=='undercutCopper' then return floor(value/100)*100 end
    return value
end
local function storeValue(current,entry,value)
    value=normalize(entry,value)
    if aliases[entry.key] then current[aliases[entry.key]]=value
    else current.professions[entry.key]=value end
end
function S.Get(key)
    local entry=byKey[key]; if not entry then return nil end
    local current=settings(); if not current then return entry.default end
    local value=aliases[key] and current[aliases[key]] or current.professions[key]
    -- Explicit false must survive alias lookup.
    if aliases[key] then value=current[aliases[key]] end
    if not valid(entry,value) then value=entry.default end
    return value
end
function S.Set(key,value)
    local entry=byKey[key]
    if not valid(entry,value) then return false,'invalid-setting' end
    local current=settings(); if not current then return false,'not-ready' end
    storeValue(current,entry,value)
    if ns.Professions and ns.Professions.Invalidate then ns.Professions.Invalidate('settings') end
    if ns.Emit then ns.Emit('professions:settings',key) end
    return true
end
function S.Init()
    local current=settings(); if not current then return end
    for index,entry in ipairs(definitions) do
        local key=entry.key; local target=aliases[key] and current or current.professions
        local field=aliases[key] or key
        if target[field]==nil then target[field]=entry.default end
    end
end
function S.Reset()
    local current=settings(); if not current then return false,'not-ready' end
    for index,entry in ipairs(definitions) do storeValue(current,entry,entry.default) end
    if ns.Professions and ns.Professions.Invalidate then ns.Professions.Invalidate('settings') end
    if ns.Emit then ns.Emit('professions:settings') end
    return true
end
local function decodeHex(value)
    if #value%2~=0 or find(value,'[^%x]') then return nil end
    return (gsub(value,'%x%x',function(c) return char(tonumber(c,16)) end))
end
local function validUTF8(text)
    local position=1
    while position<=#text do
        local lead=byte(text,position)
        local width
        local lower,upper=128,191
        if lead==0 then return false
        elseif lead<128 then width=1
        elseif lead>=194 and lead<=223 then width=2
        elseif lead>=224 and lead<=239 then
            width=3
            if lead==224 then lower=160 elseif lead==237 then upper=159 end
        elseif lead>=240 and lead<=244 then
            width=4
            if lead==240 then lower=144 elseif lead==244 then upper=143 end
        else return false end
        if position+width-1>#text then return false end
        for offset=1,width-1 do
            local continuation=byte(text,position+offset)
            local low=offset==1 and lower or 128
            local high=offset==1 and upper or 191
            if continuation<low or continuation>high then return false end
        end
        position=position+width
    end
    return true
end
local function encodeText(value)
    if type(value)~='string' or not validUTF8(value) then return nil end
    return (gsub(value,'[%%%c|]',function(c) return format('%%%02X',byte(c)) end))
end
local function decodeText(value)
    if type(value)~='string' then return nil end
    local withoutEscapes=gsub(value,'%%[%x][%x]','')
    if find(withoutEscapes,'%%') then return nil end
    local decoded=gsub(value,'%%([%x][%x])',function(c) return char(tonumber(c,16)) end)
    if not validUTF8(decoded) then return nil end
    return decoded
end
local function integer(value,minimum,maximum)
    value=tonumber(value)
    if not value or value~=value or value==huge or value==-huge or value<minimum
        or value>maximum or value~=floor(value) then return nil end
    return value
end
function S.Export()
    local db=ns.Store.GetDB(); if not db then return nil,'not-ready' end
    local lines={'EAPROF2'}
    for index,entry in ipairs(definitions) do
        local value=S.Get(entry.key)
        lines[#lines+1]='S\t'..entry.key..'\t'..(type(value)=='boolean' and (value and 'true' or 'false') or tostring(value))
    end
    local data=db.professions or {}
    local queueCount=0
    for index,entry in ipairs(data.queue or {}) do
        if not entry.isDependency then
            queueCount=queueCount+1
            if queueCount>TRANSFER_QUEUE then return nil,'too-many-queue' end
            local recipeID=integer(entry.recipeID,1,2147483647)
            local quantity=integer(entry.quantity,1,999999)
            local owner=entry.character or entry.characterKey or ''
            owner=encodeText(owner)
            if not recipeID or not quantity or not owner then return nil,'invalid-queue' end
            lines[#lines+1]='Q\t'..tostring(recipeID)..'\t'..tostring(quantity)..'\t'..owner
        end
    end
    local normalizedLimits={}
    for key,value in pairs(data.postLimits or {}) do
        local itemKey=ns.Store.Key(key)
        local limit=integer(value,0,999999)
        if not itemKey or not limit then return nil,'invalid-limit' end
        local canonical=type(key)=='string' and key==itemKey
        if not normalizedLimits[itemKey] or canonical then
            normalizedLimits[itemKey]={key=itemKey,value=limit,canonical=canonical}
        end
    end
    local limits={}
    for itemKey,entry in pairs(normalizedLimits) do
        if itemKey then limits[#limits+1]=entry end
    end
    sort(limits,function(a,b) return tostring(a.key)<tostring(b.key) end)
    for index,entry in ipairs(limits) do
        lines[#lines+1]='L\t'..entry.key..'\t'..tostring(entry.value)
    end
    if #lines-1>TRANSFER_RECORDS then return nil,'too-many-records' end
    local text=concat(lines,'\n')
    if #text>TRANSFER_BYTES then return nil,'export-too-large' end
    return text
end
function S.Import(text)
    if type(text)~='string' or #text>TRANSFER_BYTES then return false,'invalid-data' end
    text=gsub(text,'\r\n','\n')
    if find(text,'\r',1,true) then return false,'invalid-record' end
    local version=match(text,'^([^\n]+)')
    if version~='EAPROF1' and version~='EAPROF2' then return false,'invalid-format' end
    local values,seen,queue,limits,count={},{},{},{},0
    for index,entry in ipairs(definitions) do values[entry.key]=entry.default end
    local firstLine=true
    for line in gmatch(text,'[^\n]+') do
        if firstLine then firstLine=false
        else
            count=count+1; if count>TRANSFER_RECORDS then return false,'too-many-records' end
            local kind,key,value,extra=match(line,'^([SQL])\t([^\t]+)\t([^\t]*)(.*)$')
            if not kind then return false,'invalid-record' end
            if kind=='S' then
                if extra~='' or seen[key] then return false,'invalid-setting' end
                local entry=byKey[key]; if not entry then return false,'unknown-setting' end
                if entry.type=='boolean' then
                    if value~='true' and value~='false' then return false,'invalid-setting' end
                    value=value=='true'
                elseif entry.type=='number' or type(entry.default)=='number' then value=tonumber(value) end
                if not valid(entry,value) then return false,'invalid-setting' end
                values[key]=normalize(entry,value); seen[key]=true
            elseif kind=='Q' then
                local id=integer(key,1,2147483647)
                local quantity=integer(value,1,999999)
                local encodedOwner=match(extra,'^\t(.*)$')
                local owner=encodedOwner and (version=='EAPROF1' and decodeHex(encodedOwner) or decodeText(encodedOwner))
                if owner and not validUTF8(owner) then owner=nil end
                if not id or not quantity or not owner or #queue>=TRANSFER_QUEUE then return false,'invalid-queue' end
                queue[#queue+1]={recipeID=id,quantity=quantity,character=owner~='' and owner or nil}
            else
                if version=='EAPROF1' then key=decodeHex(key) else key=decodeText(key) end
                key=key and ns.Store.Key(key)
                value=integer(value,0,999999)
                if extra~='' or not key or not value or limits[key]~=nil then return false,'invalid-limit' end
                limits[key]=value
            end
        end
    end
    local db=ns.Store.GetDB(); if not db then return false,'not-ready' end
    db.settings=db.settings or {}; db.settings.professions=db.settings.professions or {}
    for index,entry in ipairs(definitions) do storeValue(db.settings,entry,values[entry.key]) end
    db.professions=db.professions or {}
    db.professions.queue=queue; db.professions.postLimits=limits
    if ns.Professions and ns.Professions.Invalidate then ns.Professions.Invalidate('import') end
    if ns.Emit then ns.Emit('professions:import') end
    return true
end
