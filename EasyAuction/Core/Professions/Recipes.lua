-- Blackthornes recipe harvesting, adapted for retail material alternatives.
-- Ambiguous quality/currency requirements stay visible, but never become free.
-- luacheck: read globals C_TradeSkillUI ProfessionsFrame
local addonName, ns = ... -- luacheck: ignore addonName
local C_TradeSkillUI, Enum, C_Timer = C_TradeSkillUI, Enum, C_Timer
local ProfessionsFrame_LoadUI = ProfessionsFrame_LoadUI -- luacheck: read globals ProfessionsFrame_LoadUI
local globals = _G
local type, pairs, ipairs, next, pcall, tonumber = type, pairs, ipairs, next, pcall, tonumber
local min, max = math.min, math.max
local sort = table.sort
local E = ns.ProfessionEngine
local L = ns.L
local R = {}
E.Recipes = R

-- Map by enum NAME, never by number: the client owns the ordering and an
-- addon that hardcodes 0-3 wrong paints every craft the wrong colour.
local difficultyFields = { Optimal = "optimal", Medium = "medium", Easy = "easy", Trivial = "trivial" }
local function difficulty(info)
    local value = info.relativeDifficulty or info.difficulty
    if type(value) == "string" then
        local word = value:lower()
        if word == "optimal" or word == "medium" or word == "easy" or word == "trivial" then return word end
        return "unknown"
    end
    local enums = Enum and Enum.TradeskillRelativeDifficulty
    for name, tier in pairs(difficultyFields) do
        if enums and enums[name] ~= nil and enums[name] == value then return tier end
    end
    return "unknown"
end

function R.Build(recipeID)
    if not C_TradeSkillUI then return nil end
    local info = E.Call(C_TradeSkillUI.GetRecipeInfo, recipeID)
    local schematic = E.Call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(info) ~= "table" or type(schematic) ~= "table" then return nil end
    -- Hidden system entries (specialisation bookkeeping like 产能/品质/知识)
    -- carry a name but neither output nor materials, and only pollute lists.
    if info.isDummyRecipe == true or info.disabled == true then return nil, "noise" end
    -- learned 只认明确的 false：资料未加载时的 nil 若按“未学习”处理，会把
    -- 已学配方降级进 learnable，指引随即误报“需学习”（永恒之核遮阳镜案例）。
    if info.learned == false then return nil, "unlearned" end
    if info.learned ~= true then return nil end
    local profession = E.Call(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID) or {}
    local recipe = { recipeID = recipeID, spellID = recipeID, name = info.name or schematic.name, outputItemID = schematic.outputItemID,
        quantityMin = max(1, tonumber(schematic.quantityMin) or 1),
        quantityMax = max(1, tonumber(schematic.quantityMax) or tonumber(schematic.quantityMin) or 1),
        skillLineID = profession.professionID or info.skillLineID, profession = profession.professionName,
        skillUp = difficulty(info), skillUps = max(1, tonumber(info.numSkillUps) or 1),
        gray = tonumber(info.maxTrivialLevel) or 0,
        reagents = {}, slots = {}, cachedAt = E.Now(), complete = true }
    local qualityItems = E.Call(C_TradeSkillUI.GetRecipeQualityItemIDs, recipeID)
    if type(qualityItems) == "table" and #qualityItems > 1 then
        recipe.complete, recipe.reason = false, L["产物品质需要在原生专业窗口选择"]
    end
    local aggregated = {}
    for index = 1, #(schematic.reagentSlotSchematics or {}) do
        local slot = schematic.reagentSlotSchematics[index]
        local required = slot.required
        if required == nil then required = slot.reagentType == 1 end
        if required and (slot.quantityRequired or 0) > 0 then
            local candidates, seen = {}, {}
            for candidateIndex = 1, #(slot.reagents or {}) do
                local candidate = slot.reagents[candidateIndex]
                if candidate.itemID and not seen[candidate.itemID] then
                    seen[candidate.itemID] = true
                    candidates[#candidates + 1] = candidate.itemID
                end
            end
            recipe.slots[#recipe.slots + 1] = { slotIndex = index, dataSlotIndex = slot.dataSlotIndex,
                quantity = slot.quantityRequired, candidates = candidates }
            if #candidates == 1 and slot.reagentType == 1 then
                local id = candidates[1]
                aggregated[id] = (aggregated[id] or 0) + slot.quantityRequired
            else
                recipe.complete, recipe.reason = false, L["材料品质或特殊材料需要在原生专业窗口选择"]
            end
        end
    end
    for itemID, quantity in pairs(aggregated) do recipe.reagents[#recipe.reagents + 1] = { itemID = itemID, quantity = quantity } end
    sort(recipe.reagents, function(a, b) return a.itemID < b.itemID end)
    if not recipe.outputItemID and #recipe.reagents == 0 and #recipe.slots == 0 then return nil, "noise" end
    if #recipe.reagents == 0 and #recipe.slots == 0 then return nil end
    if not recipe.outputItemID then recipe.reason = L["配方没有可拍卖的固定产物"] end
    return recipe
end

-- Unlearned recipes are stored light (no profession tags, no yield), only so
-- the leveling plan can say which craft to learn next. Recipes without a
-- usable gray point are skipped: there is nothing to place them against.
function R.BuildLearnable(recipeID)
    if not C_TradeSkillUI then return nil end
    local info = E.Call(C_TradeSkillUI.GetRecipeInfo, recipeID)
    local schematic = E.Call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(info) ~= "table" or type(schematic) ~= "table" then return nil end
    if info.isDummyRecipe == true or info.disabled == true then return nil end
    -- learnable 只收明确未学习的配方；learned=nil 是数据未加载，不能据此入库。
    if info.learned ~= false then return nil end
    local gray = tonumber(info.maxTrivialLevel) or 0
    if gray <= 0 then return nil end
    local profession = E.Call(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID) or {}
    local learnable = { recipeID = recipeID, spellID = recipeID, name = info.name or schematic.name, learned = false,
        outputItemID = schematic.outputItemID, gray = gray, reagents = {}, slots = {}, cachedAt = E.Now(),
        skillLineID = profession.professionID or info.skillLineID, profession = profession.professionName,
        quantityMin = max(1, tonumber(schematic.quantityMin) or 1),
        quantityMax = max(1, tonumber(schematic.quantityMax) or tonumber(schematic.quantityMin) or 1) }
    for index = 1, #(schematic.reagentSlotSchematics or {}) do
        local slot = schematic.reagentSlotSchematics[index]
        local required = slot and slot.required
        if required == nil and slot then required = slot.reagentType == 1 end
        if slot and required and (slot.quantityRequired or 0) > 0 then
            local candidates, seen = {}, {}
            for candidateIndex = 1, #(slot.reagents or {}) do
                local candidate = slot.reagents[candidateIndex]
                if candidate.itemID and not seen[candidate.itemID] then
                    seen[candidate.itemID] = true
                    candidates[#candidates + 1] = candidate.itemID
                end
            end
            if #candidates == 1 then
                learnable.reagents[#learnable.reagents + 1] = { itemID = candidates[1], quantity = slot.quantityRequired }
            elseif #candidates > 1 then
                learnable.slots[#learnable.slots + 1] = { quantity = slot.quantityRequired, candidates = candidates }
            end
        end
    end
    if #learnable.reagents == 0 and #learnable.slots == 0 then return nil end
    return learnable
end

function R.Harvest()
    if not E.ready or not C_TradeSkillUI then return false end
    if E.Call(C_TradeSkillUI.IsTradeSkillLinked) or E.Call(C_TradeSkillUI.IsTradeSkillGuild) then return false end
    local ids = E.Call(C_TradeSkillUI.GetAllRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then return false end
    R.generation = (R.generation or 0) + 1
    local generation, index, record = R.generation, 1, E.current
    E.harvesting = true
    local seen, touched = {}, {}
    local function batch()
        if generation ~= R.generation then return end
        local started, count = E.Clock(), 0
        local budget = min(16, max(1, E.Setting("scanBudgetMs", 8)))
        repeat
            local recipeID = ids[index]
            seen[recipeID] = true
            local profession = E.Call(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID)
            local professionID = type(profession) == "table" and profession.professionID or nil
            if professionID then touched[professionID] = true end
            local recipe, drop = R.Build(recipeID)
            if recipe then
                if recipe.skillLineID then touched[recipe.skillLineID] = true end
                record.recipes[recipe.recipeID] = recipe
                record.learnable[recipeID] = nil
            elseif drop then
                -- 伪技能、未学习与无产物的系统条目：清除旧收割留下的残影。
                record.recipes[recipeID] = nil
                record.learnable[recipeID] = nil
                local learnable = drop == "unlearned" and R.BuildLearnable(recipeID) or nil
                if learnable then record.learnable[recipeID] = learnable end
            end
            index, count = index + 1, count + 1
        until index > #ids or count >= 40 or E.Clock() - started >= budget
        if index <= #ids and C_Timer and C_Timer.After then C_Timer.After(0, batch)
        elseif index <= #ids then batch()
        else
            -- GetAllRecipeIDs may expose only the profession currently opened.
            -- Prune stale rows only inside lines this harvest actually touched.
            for storedID, stored in pairs(record.recipes) do
                local lineID = type(stored) == "table" and stored.skillLineID or nil
                if not seen[storedID] and touched[lineID] then record.recipes[storedID] = nil end
            end
            for storedID, stored in pairs(record.learnable) do
                local lineID = type(stored) == "table" and stored.skillLineID or nil
                if not seen[storedID] and touched[lineID] then record.learnable[storedID] = nil end
            end
            -- 同一配方绝不允许同时存在于 recipes 与 learnable：历史收割残留会
            -- 让指引把已学配方继续标成“需学习”。
            for storedID in pairs(record.learnable) do
                if record.recipes[storedID] then record.learnable[storedID] = nil end
            end
            E.harvesting, E.lastHarvest = false, E.Now()
            record.recipesCachedAt = E.lastHarvest
            R.Professions()
            E.Changed()
        end
    end
    batch()
    return true
end

function R.Professions()
    if not E.current then return {} end
    local grouped, names = {}, {}
    local hadUseful = false
    for index, profession in ipairs(E.current.professions or {}) do -- luacheck: ignore index
        if profession.learned then
            hadUseful = true
            if profession.skillLineID then grouped[profession.skillLineID] = profession end
        end
    end
    local skillLines = E.Call(C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    if type(skillLines) == "table" then
        for index, skillLineID in ipairs(skillLines) do -- luacheck: ignore index
            local info = E.Call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
            local name = type(info) == "table" and info.professionName
            if type(name) == "string" and not name:find("%[DNT%]") then
                local learned = (tonumber(info.maxSkillLevel) or 0) > 0
                -- 未学习的技能线（0/0 占位行）不进入角色专业表：指引标签与
                -- 利润下拉都只应列出真正学习的专业，否则会混入未学专线。
                if learned then
                    local current = names[name]
                    if not current or (learned and not current.learned)
                        or ((tonumber(info.skillLevel) or 0) > (current.skillLevel or 0)) then
                        local professionID = info.professionID or skillLineID
                        local entry = { skillLineID = skillLineID, professionID = professionID, name = name,
                            skillLevel = tonumber(info.skillLevel) or 0,
                            maxSkillLevel = tonumber(info.maxSkillLevel) or 0,
                            learned = learned, isPrimaryProfession = info.isPrimaryProfession == true,
                            parentProfessionID = info.parentProfessionID,
                            texture = E.Call(C_TradeSkillUI.GetTradeSkillTexture, professionID) }
                        names[name] = entry
                    end
                end
            end
        end
        for name, profession in pairs(names) do -- luacheck: ignore name
            if profession.learned then grouped[profession.skillLineID] = profession end
        end
    end
    -- GetProfessions 覆盖烹饪等辅助专业与当前资料片专线：交易技能数据源
    -- 未必把它们列出来，缺了它们指引就无法匹配专业。
    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        -- GetProfessions 的返回中间可能有 nil（如未学第二专业），ipairs 会提前截断。
        local ids = { GetProfessions() }
        for index = 1, 12 do
            local skillLineID = ids[index]
            if skillLineID then
                local values = { GetProfessionInfo(skillLineID) }
                local name, texture = values[1], values[2]
                local skillLevel, maxSkillLevel, skillLine = values[3], values[4], values[7]
                if type(name) == "string" and name ~= "" and not name:find("%[DNT%]")
                    and (tonumber(maxSkillLevel) or 0) > 0 then
                    local resolvedID = tonumber(skillLine) or skillLineID
                    grouped[resolvedID] = {
                        skillLineID = resolvedID,
                        professionID = resolvedID,
                        name = name, skillLevel = tonumber(skillLevel) or 0,
                        maxSkillLevel = tonumber(maxSkillLevel) or 0, learned = true,
                        texture = texture or E.Call(C_TradeSkillUI.GetTradeSkillTexture,
                            resolvedID) or grouped[resolvedID] and grouped[resolvedID].texture }
                end
            end
        end
    end
    -- Auxiliary professions may be absent until their native UI is opened;
    -- harvested recipes still carry an authoritative profession line.
    for recipeID, recipe in pairs(E.current.recipes or {}) do -- luacheck: ignore recipeID
        local id = recipe.skillLineID
        local name = type(recipe.profession) == "string" and recipe.profession or nil
        local lowerName = name and name:lower() or ""
        local auxiliary = name and (name == L["烹饪"] or name == L["钓鱼"]
            or name:find(L["烹饪"], 1, true) or name:find(L["钓鱼"], 1, true)
            or lowerName:find("cooking", 1, true) or lowerName:find("fishing", 1, true)
        )
        if auxiliary and id and name ~= "" and not name:find("%[DNT%]") and not grouped[id] then
            grouped[id] = { skillLineID = id, professionID = id, name = name,
                skillLevel = 0, maxSkillLevel = 0, learned = true,
                texture = E.Call(C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillTexture, id) }
        end
    end
    if not next(grouped) and type(skillLines) == "table" and hadUseful then
        return E.current.professions
    end
    -- Some clients cannot enumerate profession lines until the profession UI
    -- is open. Recipes still provide a useful fallback for the first capture.
    if not next(grouped) then
        for recipeID, recipe in pairs(E.current.recipes) do -- luacheck: ignore recipeID
            local id = recipe.skillLineID
            if id and not grouped[id] then
                grouped[id] = { skillLineID = id, professionID = id,
                    name = recipe.profession or L["专业"], learned = true,
                    texture = E.Call(C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillTexture, id) }
            end
        end
    end
    local professions = {}
    for id, profession in pairs(grouped) do -- luacheck: ignore id
        professions[#professions + 1] = profession
    end
    sort(professions, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.skillLineID < b.skillLineID
    end)
    local useful = false
    for index, profession in ipairs(professions) do -- luacheck: ignore index
        if profession.learned then useful = true; break end
    end
    if useful or not hadUseful then E.current.professions = professions end
    return E.current.professions
end

function R.ForItem(itemID, character)
    local best
    local owner = character or E.character
    local record = E.db and E.db.characters and E.db.characters[owner]
    for recipeID, recipe in pairs(record and record.recipes or {}) do
        if recipe.outputItemID == itemID and recipe.complete ~= false
            and (not best or recipeID < best.recipeID) then best = recipe end
    end
    return best
end

function R.FinishOpen()
    local request = R.openRequest
    if not request or request.queued or not C_Timer or not C_Timer.After then return end
    request.queued = true
    C_Timer.After(0, function()
        request.queued = nil
        if R.openRequest ~= request then return end
        local frame, util = globals.ProfessionsFrame, globals.ProfessionsUtil
        if not frame or not frame:IsShown() or not util or type(util.OpenProfessionFrameToRecipe) ~= "function" then return end
        if E.Call(C_TradeSkillUI.IsDataSourceChanging) then return end
        local skillLineID = E.Call(C_TradeSkillUI.GetTradeSkillLineForRecipe, request.recipeID)
        local profession = E.Call(C_TradeSkillUI.GetChildProfessionInfo)
        if not skillLineID or not profession or profession.professionID ~= skillLineID then return end
        -- Run after Blizzard's default recipe selection, not during its list rebuild.
        R.openRequest = nil
        pcall(util.OpenProfessionFrameToRecipe, request.recipeID)
    end)
end

function R.CancelOpen() R.openRequest = nil end

function R.Open(recipeID)
    R.CancelOpen()
    if not E.Integer(recipeID, 1) or not C_TradeSkillUI or type(C_TradeSkillUI.OpenRecipe) ~= "function" then
        return false, L["此客户端不能打开配方"]
    end
    -- 指引场景允许对未学习配方做 best-effort 打开：learnable 记录同样可用，
    -- 原生窗口拒绝时只影响提示，不影响材料与采购。
    local recipe = E.RecipeData and E.RecipeData(recipeID, E.character) or E.Recipe(recipeID, E.character)
    if not recipe then return false, L["当前角色未记录该配方"] end
    -- Match Blizzard's recipe tracker: register OPEN_RECIPE_RESPONSE before requesting it.
    if type(ProfessionsFrame_LoadUI) == "function" then
        local loaded, result = pcall(ProfessionsFrame_LoadUI)
        if not loaded or result == false then return false, L["无法打开原生专业窗口"] end
    end
    local request = {recipeID = recipeID}
    R.openRequest = request
    local ok = pcall(C_TradeSkillUI.OpenRecipe, recipeID)
    if not ok then R.CancelOpen()
    elseif C_Timer and C_Timer.After then
        R.FinishOpen()
        C_Timer.After(5, function() if R.openRequest == request then R.CancelOpen() end end)
    else R.CancelOpen() end
    return ok, not ok and L["无法打开原生专业窗口"] or nil
end
