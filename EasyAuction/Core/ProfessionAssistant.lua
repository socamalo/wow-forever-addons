-- Public profession facade; all methods are dot calls and all auctions use Market.
local addonName, ns = ... -- luacheck: ignore addonName
local C_Item = C_Item
local type, pairs, tostring = type, pairs, tostring
local floor, max, huge = math.floor, math.max, math.huge
local sort, concat = table.sort, table.concat
local format = string.format
local L = ns.L
local E = ns.ProfessionEngine
local P = {}
ns.Professions = P

function E.ItemName(itemID)
    local name = C_Item and E.Call(C_Item.GetItemNameByID, itemID)
    return name or format(L["物品 %s"], tostring(itemID))
end

function P.Invalidate()
    if ns.Store.GetDB() and ns.Store.GetDB().professions ~= E.db then E.Bind() end
    E.Changed()
end

function P.Init()
    if not E.Bind() then return false end
    E.Inventory.Refresh()
    return true
end

local function signature(options, mode)
    local parts = { mode, tostring(E.revision), tostring(ns.Prices and ns.Prices.Revision() or 0), tostring(floor(E.Now() / 60)) }
    local keys = {}
    for key in pairs(options or {}) do keys[#keys + 1] = key end
    sort(keys)
    for index = 1, #keys do parts[#parts + 1] = tostring(keys[index]) .. "=" .. tostring(options[keys[index]]) end
    return concat(parts, "|")
end

function P.GetRanked(options)
    if not E.ready then return {} end
    local key = signature(options, "profit")
    if not E.cache[key] then E.cache[key] = E.Economics.Ranked(options, false) end
    return E.cache[key]
end

function P.GetLevelUp(options)
    if not E.ready then return {} end
    local key = signature(options, "level")
    if not E.cache[key] then E.cache[key] = E.Economics.Ranked(options, true) end
    return E.cache[key]
end

function P.ItemName(itemID) return E.ItemName(itemID) end

function P.GuideProfessions()
    local source=E.Guides and E.Guides.Professions or {}
    local result={}
    for index,entry in ipairs(source) do
        local info=E.Guides.Resolve(entry)
        -- 只列出真正学习的专业：learned 明确为 true，或技能值大于 0。
        -- 未学习/数据未加载的专线一律不显示标签（九专业标签按已学过滤）。
        if info and (info.learned == true or (tonumber(info.skillLevel) or 0) > 0) then
            local copy={key=entry.key,label=entry.label,en=entry.en,
                texture=info.texture or entry.icon,
                skillLineID=info.professionID or info.skillLineID}
            result[#result+1]=copy
        end
    end
    return result
end

-- 内置指引路线（wow.gg Midnight 数据，按物品 ID 匹配游戏配方）。
function P.GetLevelUpGuide(options)
    if not E.ready then return { ok = false, guide = true, reason = L["专业助手尚未初始化"] } end
    options = options or {}
    local entry
    for index, profession in ipairs(E.Guides.Professions) do
        if profession.key == options.guideKey then entry = profession; break end
    end
    entry = entry or E.Guides.Professions[1]
    local key = signature({ guideKey = entry.key }, "guide")
    if not E.cache[key] then E.cache[key] = E.Guides.Compile(entry) end
    return E.cache[key]
end

-- 打开某专业的原生界面：取该技能线下任意一个已学配方当作入口。
function P.OpenProfession(skillLineID)
    if not E.ready then return false, L["专业助手尚未初始化"] end
    local best
    for recipeID, recipe in pairs(E.current and E.current.recipes or {}) do
        if type(recipe) == "table" and recipe.skillLineID == skillLineID
            and (not best or recipeID < best) then best = recipeID end
    end
    if not best then
        -- 报错显示专业名而非裸 ID，玩家才知道该去学哪条线的配方。
        local name
        for index, profession in ipairs(E.current and E.current.professions or {}) do -- luacheck: ignore index
            if type(profession) == "table"
                and (profession.professionID == skillLineID or profession.skillLineID == skillLineID) then
                name = profession.name
                break
            end
        end
        return false, format(L["尚未学习%s的配方。"], tostring(name or skillLineID))
    end
    return E.Recipes.Open(best)
end

function P.GetLevelUpPlan(options)
    if not E.ready then return { ok = false, steps = {}, materials = {}, totals = { cost = 0, unpriced = 0, crafts = 0 } } end
    local key = signature(options, "plan")
    if not E.cache[key] then E.cache[key] = E.Economics.Plan(options) end
    return E.cache[key]
end

-- One-click procurement: write the plan's missing materials into a dedicated
-- shopping list (the same channel the queue's 生成补货清单 uses), so the buy
-- tab can shop the whole route at once.
function P.ExportLevelUpPlan(plan)
    if not E.ready then return nil, L["专业助手尚未初始化"] end
    if type(plan) ~= "table" or plan.ok ~= true or type(plan.materials) ~= "table" then
        return nil, L["请先生成有效的冲级清单"]
    end
    local totals = {}
    for index = 1, #plan.materials do
        local material = plan.materials[index]
        if (material.shortfall or 0) > 0 then totals[material.itemID] = (totals[material.itemID] or 0) + material.shortfall end
    end
    if not next(totals) then return nil, L["材料已备齐，无需采购"] end
    local source = "levelup:" .. E.character .. ":" .. tostring(plan.skillLineID or 0)
    local target
    for index, list in pairs(ns.Store.GetLists()) do -- luacheck: ignore index
        if list.professionSource == source then target = list; break end
    end
    if not target then
        target = ns.Store.CreateList(plan.profession and format(L["冲级材料·%s"], plan.profession) or L["冲级材料"])
        if not target then return nil, L["无法创建购物清单"] end
        target.professionSource = source
    end
    for key, entry in pairs(target.items) do
        if entry.professionMaterial then target.items[key] = nil end
    end
    for itemID, missing in pairs(totals) do
        local itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
        local held = E.Inventory.Owned(itemID)
        if ns.Store.SetListItem(target.id, itemKey, E.ItemName(itemID), max(0, held) + missing) then
            target.items[ns.Store.Key(itemKey)].professionMaterial = true
        end
    end
    E.Changed()
    return target
end

local function planning()
    if not E.ready then return { {}, {}, 0 } end
    local key = signature(nil, "queue")
    if not E.cache[key] then E.cache[key] = { E.Queue.Build() } end
    return E.cache[key]
end

function P.GetQueue() return planning()[1] end
function P.GetShoppingList() return planning()[2] end
function P.GetCharacters() return E.Inventory.Characters() end
function P.GetCharacterBestRecipes(character, limit)
    if not E.ready or type(character) ~= "string" then return {} end
    limit = E.Integer(limit or 8, 1) or 8
    if limit > 50 then limit = 50 end
    local key = signature({ character = character, limit = limit }, "character-best")
    if E.cache[key] then return E.cache[key] end
    local record = E.db.characters[character]
    local rows = {}
    for recipeID in pairs(record and record.recipes or {}) do
        local row = E.Economics.Analyse(recipeID, character)
        if row and row.sellable ~= false and row.priceable then rows[#rows + 1] = row end
    end
    sort(rows, function(a, b)
        if a.profit ~= b.profit then return (a.profit or -huge) > (b.profit or -huge) end
        if a.name ~= b.name then return (a.name or "") < (b.name or "") end
        return a.recipeID < b.recipeID
    end)
    while #rows > limit do rows[#rows] = nil end
    E.cache[key] = rows
    return rows
end
function P.AddQueue(recipeID, count, character)
    if not E.ready then return false end
    return E.Queue.Add(recipeID, count, character)
end
function P.SetQuantity(index, count) return E.ready and E.Queue.Set(index, count) or false end
function P.RemoveQueue(index) return P.SetQuantity(index, 0) end
function P.OpenRecipe(recipeID) return E.Recipes.Open(recipeID) end
function P.GetRecipeForItem(itemID) return E.Recipes.ForItem(itemID) end
function P.GetRecipe(recipeID, character) return E.Recipe(recipeID, character) end
function P.GetCost(recipeID, character, forceMarket) return E.Economics.Cost(recipeID, character, forceMarket) end
function P.RefreshRecipes() return E.Recipes.Harvest() end

function P.GetReagentIDs()
    local ids = {}
    for index, entry in pairs(E.AllRecipes(true)) do -- luacheck: ignore index
        for slotIndex = 1, #(entry.recipe.slots or {}) do
            local slot = entry.recipe.slots[slotIndex]
            for candidateIndex = 1, #(slot.candidates or {}) do ids[slot.candidates[candidateIndex]] = true end
        end
        for reagentIndex = 1, #(entry.recipe.reagents or {}) do ids[entry.recipe.reagents[reagentIndex].itemID] = true end
    end
    return ids
end

function P.GetProfessionOptions()
    local grouped, rows = {}, {}
    for index, entry in pairs(E.AllRecipes(true)) do -- luacheck: ignore index
        local id = entry.recipe.skillLineID
        if id and not grouped[id] then
            grouped[id] = true
            rows[#rows + 1] = { value = id, skillLineID = id, label = entry.recipe.profession or tostring(id),
                name = entry.recipe.profession or tostring(id) }
        end
    end
    sort(rows, function(a, b) return a.skillLineID < b.skillLineID end)
    return rows
end

function P.GetProfessionCategories()
    local categories = {{ id = "all", name = L["全部专业"], icon = "Interface\\Icons\\INV_Misc_QuestionMark", children = {} }}
    local grouped = {}
    local prefixes = { L["至暗之夜"], L["卡兹阿加"], L["巨龙群岛"], L["暗影界"], L["德拉诺"],
        L["潘达利亚"], L["诺森德"], L["外域"], L["大地的裂变"], L["军团"], L["库尔提拉斯"], L["经典旧世"] }
    local icons = {
        [L["工程学"]] = "Interface\\Icons\\Trade_Engineering",
        [L["附魔"]] = "Interface\\Icons\\Trade_Engraving",
        [L["烹饪"]] = "Interface\\Icons\\INV_Misc_Food_15",
        [L["钓鱼"]] = "Interface\\Icons\\Trade_Fishing",
        [L["炼金术"]] = "Interface\\Icons\\Trade_Alchemy",
        [L["锻造"]] = "Interface\\Icons\\Trade_BlackSmithing",
        [L["珠宝加工"]] = "Interface\\Icons\\INV_Misc_Gem_01",
        [L["制皮"]] = "Interface\\Icons\\Trade_LeatherWorking",
        [L["裁缝"]] = "Interface\\Icons\\Trade_Tailoring",
        [L["铭文"]] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    }
    local function baseName(name)
        name = tostring(name or "")
        for index = 1, #prefixes do name = name:gsub("^" .. prefixes[index], "") end
        return name:gsub("^%s+", "")
    end
    local function excluded(name)
        return name == "" or name == L["考古学"] or name == "Archaeology"
    end
    -- 一级 = 大专业，二级 = 该专业的各资料片子线。只收录真正学习的专业，
    -- 并合并收割配方里的技能线（配方记录跨会话持久，不受“最近一次打开的
    -- 专业界面”影响，专业下拉因此不会塌缩成单个专业）。
    local function addLine(entry, recipeFallback)
        if type(entry) ~= "table" or entry.name == nil then return end
        -- 未学习（learned=false）与未加载占位行（learned=nil 且 0 级）都不展示。
        if entry.learned ~= true and (tonumber(entry.skillLevel) or 0) <= 0 then return end
        local name = baseName(entry.name)
        if excluded(name) then return end
        -- 配方兜底只认十大基础专业名：烧烤之道等子专线的配方记录不建新大专业。
        if recipeFallback and not icons[name] then return end
        local bucket = grouped[name]
        if not bucket then
            bucket = { id = "profession:" .. name, name = name,
                icon = entry.texture or icons[name] or "Interface\\Icons\\INV_Misc_QuestionMark", children = {} }
            grouped[name] = bucket; categories[#categories + 1] = bucket
        end
        local childID = entry.professionID or entry.skillLineID
        if not childID then return end
        local duplicate = false
        for childIndex = 1, #bucket.children do
            if bucket.children[childIndex].id == childID then duplicate = true; break end
        end
        if not duplicate then
            bucket.children[#bucket.children + 1] = { id = childID, name = entry.name,
                icon = entry.texture or icons[name] or bucket.icon, skillLineID = childID }
        end
    end
    for index, entry in ipairs(E.current and E.current.professions or {}) do -- luacheck: ignore index
        addLine(entry)
    end
    -- 收割配方兜底：专业行为空/丢失时，按配方记录的专业名补齐大专业。
    for recipeID, recipe in pairs(E.current and E.current.recipes or {}) do -- luacheck: ignore recipeID
        if type(recipe) == "table" and recipe.skillLineID and type(recipe.profession) == "string" then
            addLine({ skillLineID = recipe.skillLineID, professionID = recipe.skillLineID,
                name = recipe.profession, learned = true }, true)
        end
    end
    sort(categories, function(a, b) return a.id == "all" or (b.id ~= "all" and a.name < b.name) end)
    for index = 2, #categories do sort(categories[index].children, function(a, b) return a.name < b.name end) end
    return categories
end

function P.SetPostLimit(itemID, value)
    if not E.ready then return false end
    local key = ns.Store.Key(itemID)
    local limit = value ~= nil and E.Integer(value, 0) or nil
    if not key or (value ~= nil and (not limit or limit > 100000)) then return false end
    E.db.postLimits[key] = limit
    if type(itemID) == "number" then E.db.postLimits[itemID] = nil end
    E.Changed()
    return true
end

function P.GetSales(options)
    local rows = {}
    if not E.db then return rows end
    options = options or {}
    local cutoff = options.days and E.Now() - options.days * 86400
    local search = type(options.search) == "string" and options.search:lower() or ""
    for index = 1, #E.db.sales do
        local row = E.db.sales[index]
        if (not cutoff or (row.at or 0) >= cutoff)
            and (search == "" or (row.name or row.itemName or ""):lower():find(search, 1, true)) then rows[#rows + 1] = row end
    end
    sort(rows, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return rows
end

function P.ExportShoppingList()
    if not E.ready then return nil, L["专业助手尚未初始化"] end
    local plan = planning()
    if plan[3] > 0 then return nil, L["队列包含未确定的材料或品质，请先在原生专业窗口核对"] end
    local totals = {}
    for index = 1, #plan[2] do
        local row = plan[2][index]
        if row.character == E.character and row.shortfall > 0 and not row.fromVendor then
            totals[row.itemID] = (totals[row.itemID] or 0) + row.shortfall
        end
    end
    local source = "professions:" .. E.character
    local target
    for index, list in pairs(ns.Store.GetLists()) do -- luacheck: ignore index
        if list.professionSource == source then target = list; break end
    end
    if not target then
        target = ns.Store.CreateList(L["专业制作材料"])
        if not target then return nil, L["无法创建购物清单"] end
        target.professionSource = source
    end
    for key, entry in pairs(target.items) do
        if entry.professionMaterial then target.items[key] = nil end
    end
    for itemID, missing in pairs(totals) do
        local itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
        local held = ns.Market and ns.Market.InventoryCount and ns.Market.InventoryCount(itemKey)
            or E.Inventory.Count(itemID)
        if ns.Store.SetListItem(target.id, itemKey, E.ItemName(itemID), max(0, held) + missing) then
            target.items[ns.Store.Key(itemKey)].professionMaterial = true
        end
    end
    E.Changed()
    return target
end

function P.Snapshot()
    local count = 0
    if E.current then for recipeID in pairs(E.current.recipes) do if recipeID then count = count + 1 end end end
    return { ready = E.ready == true, character = E.character, recipes = count,
        queue = E.db and #E.db.queue or 0, harvesting = E.harvesting == true,
        lastHarvest = E.lastHarvest, error = E.error, revision = E.revision,
        unresolved = planning()[3], bankIncludesWarband = false }
end

P.Events = {
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_CLOSE",
    "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED",
    "PLAYERREAGENTBANKSLOTS_CHANGED", "PLAYER_MONEY", "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED",
    "MERCHANT_SHOW", "MERCHANT_UPDATE", "OWNED_AUCTIONS_UPDATED", "TRADE_SKILL_ITEM_CRAFTED_RESULT",
    "SPELL_DATA_LOAD_RESULT",
}

function P.OnEvent(event, ...)
    if not E.ready then
        if event == "PLAYER_LOGIN" then
            -- 12.1 的配方数据源在登录后即可读，不必等玩家打开专业窗口；
            -- 登录收割让存档里的坏枚举颜色和伪技能残留立即被重建与清理。
            if P.Init() then E.Later("recipes", 3, E.Recipes.Harvest) end
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        E.Later("recipes", 1, E.Recipes.Harvest)
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemID = ...
        if E.Economics.ItemDataLoaded(itemID) then E.Later("profession-item-data", 0.1, E.Changed) end
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        E.Changed()
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        E.Recipes.FinishOpen()
        E.Later("recipes", 0.2, E.Recipes.Harvest)
    elseif event == "TRADE_SKILL_CLOSE" then E.Recipes.CancelOpen()
    elseif event == "BAG_UPDATE_DELAYED" then
        E.Later("bags", 0.1, E.Inventory.Refresh)
    elseif event == "PLAYER_MONEY" then
        E.Later("bags", 0.1, E.Inventory.Refresh)
    elseif event == "BANKFRAME_OPENED" then
        E.bankOpen = true
        E.Inventory.ReadBank()
    elseif event == "BANKFRAME_CLOSED" then E.bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERREAGENTBANKSLOTS_CHANGED" then
        if E.bankOpen then E.Later("bank", 0.2, E.Inventory.ReadBank) end
    elseif event == "MAIL_SHOW" then E.mailOpen = true; E.Inventory.ReadMail()
    elseif event == "MAIL_CLOSED" then E.mailOpen = false
    elseif event == "MAIL_INBOX_UPDATE" then
        if E.mailOpen then E.Later("mail", 0.2, E.Inventory.ReadMail) end
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then E.Later("vendor", 0.2, E.Inventory.ReadVendor)
    elseif event == "OWNED_AUCTIONS_UPDATED" then E.Inventory.ReadOwnedAuctions()
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        -- The retail receipt has no recipe ID. Keep manual queue intent until
        -- the user updates it; acquiring an item never proves which plan ran.
        E.Later("bags", 0.1, E.Inventory.Refresh)
    end
end

return P
