-- 内置升级指引的运行时逻辑：把 Data/LevelingGuides.lua 的 itemID 路由编译成
-- 可执行的路线（配方匹配、游戏内名称、成本估算、成品复用与采购解析）。
-- 指引页面可能是英文版，名称一律以技能/物品 ID 反查游戏数据，绝不照抄文字。
-- luacheck: globals C_Spell
local addonName, ns = ... -- luacheck: ignore addonName
local C_Spell = C_Spell
local type, pairs, tonumber, max = type, pairs, tonumber, math.max
local concat = table.concat
local format = string.format
local E = ns.ProfessionEngine
local X = E.Economics
local L = ns.L
local G = {}
E.Guides = G

-- 指引专业与游戏内专业名的匹配：label 已本地化（zhCN/zhTW/enUS 客户端的
-- 专业名都能对上），en 片段兜底英文客户端；资料片前缀区分当前资料片专线。
-- icon 是图标兜底：收割记录缺 texture 时标签仍能显示专业图标。
local PROFESSIONS = {
    { key = "engineering", label = L["工程学"], en = "engineering", icon = "Interface\\Icons\\Trade_Engineering" },
    { key = "jewelcrafting", label = L["珠宝加工"], en = "jewelcrafting", icon = "Interface\\Icons\\INV_Misc_Gem_01" },
    { key = "enchanting", label = L["附魔"], en = "enchanting", icon = "Interface\\Icons\\Trade_Engraving" },
    { key = "alchemy", label = L["炼金术"], en = "alchemy", icon = "Interface\\Icons\\Trade_Alchemy" },
    { key = "blacksmithing", label = L["锻造"], en = "blacksmithing", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { key = "leatherworking", label = L["制皮"], en = "leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { key = "tailoring", label = L["裁缝"], en = "tailoring", icon = "Interface\\Icons\\Trade_Tailoring" },
    { key = "inscription", label = L["铭文"], en = "inscription", icon = "Interface\\Icons\\INV_Inscription_Tradeskill01" },
    { key = "cooking", label = L["烹饪"], en = "cooking", icon = "Interface\\Icons\\INV_Misc_Food_15" },
}
G.Professions = PROFESSIONS

local NOTE_TEXT = {
    prospect = L["选矿任意午夜矿石（指引区间）"],
    disenchant = L["分解拾取的装备获取附魔材料"],
    recycle = L["回收药剂转化，按指引消耗中间产物"],
    starter = L["使用初始配方练到指引区间起点"],
    feast = L["香料饼干与丰盛食物交替制作（指引区间）"],
}

function G.NoteText(key)
    return NOTE_TEXT[key] or key
end

-- 按专业 key 找到角色当前资料片对应的专业行（skillLineID/skillLevel）。
-- 排序以“确定已学习”为最高优先级：资料片专线即使匹配也可能因数据未加载
-- 带 learned=false/0 级占位行，绝不能让它们压过真正已学过的行（烹饪误报
-- “未学习”的根源），其次才是当前资料片与技能上限。
function G.Resolve(entry)
    local expansion = L["至暗之夜"]
    local best, fallback
    for index = 1, #(E.current and E.current.professions or {}) do
        local profession = E.current.professions[index]
        local name = type(profession) == "table" and tostring(profession.name or "") or ""
        local lower = name:lower()
        local midnight = name:find(expansion, 1, true) or lower:find("midnight", 1, true)
        local hit = (name:find(entry.label, 1, true) or lower:find(entry.en, 1, true)) ~= nil
        if hit then
            local learned = profession.learned == true or (tonumber(profession.skillLevel) or 0) > 0
            local ranked = {
                score = (learned and 4 or 0) + (midnight and 2 or 1),
                maxSkillLevel = tonumber(profession.maxSkillLevel) or 0,
                skillLevel = tonumber(profession.skillLevel) or 0 }
            if not best or ranked.score > best.score
                or (ranked.score == best.score and ranked.maxSkillLevel > best.maxSkillLevel)
                or (ranked.score == best.score and ranked.maxSkillLevel == best.maxSkillLevel
                    and ranked.skillLevel > best.skillLevel) then
                best = ranked
                fallback = profession
            end
        end
    end
    return fallback
end

-- itemID → 配方：RecipeData 统一查已学（含 complete=false 品质槽）与 learnable
-- 记录。指引不管是否已学都要给出材料，方便一键采购。
local function hasOutput(recipe, itemID)
    if type(recipe) ~= "table" then return false end
    if recipe.outputItemID == itemID then return true end
    for index, outputID in pairs(recipe.outputItemIDs or {}) do -- luacheck: ignore index
        if outputID == itemID then return true end
    end
    return false
end

local function matchRecipe(itemID, spellID)
    local record = E.db and E.db.characters[E.character]
    local best
    if spellID then
        best = record and record.recipes and record.recipes[spellID]
        if best then return best, true end
        best = E.current and E.current.learnable and E.current.learnable[spellID]
        if best then return best, false end
    end
    if not itemID then return nil, false end
    for recipeID, recipe in pairs(record and record.recipes or {}) do
        if hasOutput(recipe, itemID)
            and (not best or recipeID < best.recipeID) then best = recipe end
    end
    if best then return best, true end
    for learnID, entry in pairs(E.current and E.current.learnable or {}) do
        if hasOutput(entry, itemID) then
            return entry, false
        end
    end
    return nil, false
end

-- 从指引文字提取全部训练师与坐标：形如“丹维（43.5, 54.1）或格洛蕾莎（69.3, 84.2）”。
-- 返回 { { name = "丹维", coords = "43.5, 54.1" }, ... }；无名字时只给坐标。
-- 坐标前的名字按 UTF-8 字符回溯截取：Lua 模式按字节匹配，多字节字符不能进
-- 字符类，所以分隔符用明文串逐一比对（纯标点，不含汉字）。
local TRAINERS_DELIMITERS = "，。；、！？：（）()　 "
local function trailingName(before)
    -- 先跳过坐标前紧邻的分隔符（例如全角左括号），再向回截取名字本身。
    local position = #before + 1
    while position > 1 do
        local start = position - 1
        while start > 1 and before:byte(start) >= 128 and before:byte(start) < 192 do start = start - 1 end
        if not TRAINERS_DELIMITERS:find(before:sub(start, position - 1), 1, true) then break end
        position = start
    end
    local nameEnd = position
    while position > 1 do
        local start = position - 1
        while start > 1 and before:byte(start) >= 128 and before:byte(start) < 192 do start = start - 1 end
        if TRAINERS_DELIMITERS:find(before:sub(start, position - 1), 1, true) then break end
        position = start
    end
    if nameEnd > position then return before:sub(position, nameEnd - 1) end
end

local function trainersFromText(text)
    if type(text) ~= "string" then return nil end
    local particleSet = L["训练师名冠词剔除字符"] or ""
    -- 剔除开头的“或/和”等冠词字符：必须按完整 UTF-8 字符比对。Lua 的字符类
    -- 按字节匹配，会把名字首字与冠词重合的字节误剥（丹维 → 维）。
    local function stripParticles(value)
        while value ~= "" do
            local lead = value:byte(1)
            if not lead then return "" end
            local width = lead < 128 and 1 or (lead < 224 and 2 or (lead < 240 and 3 or 4))
            local ch = value:sub(1, width)
            if not particleSet:find(ch, 1, true) then return value end
            value = value:sub(width + 1)
        end
        return ""
    end
    local trainers, seen, position = {}, {}, 1
    while position <= #text do
        local xStart, yEnd, x, y = text:find("(%d+%.?%d*)%s*[,，]%s*(%d+%.?%d*)", position)
        if not x then break end
        local coords = format("%s, %s", x, y)
        if not seen[coords] then
            seen[coords] = true
            local before = text:sub(math.max(1, xStart - 24), xStart - 1)
            local name = trailingName(before)
            name = name and name:gsub("^%s+", ""):gsub("%s+$", "") or nil
            name = name and name ~= "" and stripParticles(name) or nil
            if name and #name <= 3 and name:byte(1) < 128 then name = nil end -- 纯短英文残片不当地名
            trainers[#trainers + 1] = { name = name, coords = coords }
        end
        position = yEnd + 1
    end
    return #trainers > 0 and trainers or nil
end

local function joinTrainers(trainers)
    if type(trainers) ~= "table" then return nil end
    local parts = {}
    for index = 1, #trainers do
        local trainer = trainers[index]
        parts[#parts + 1] = trainer.name and (trainer.name .. " " .. trainer.coords) or trainer.coords
    end
    return #parts > 0 and concat(parts, " · ") or nil
end

-- 步骤级训练师记录 + 汇总到路线级（result.trainers，供指引侧窗直接展示）。
local function applyTrainers(step, text, result, seen)
    local trainers = trainersFromText(text)
    step.trainers = trainers
    step.trainerCoords = joinTrainers(trainers)
    if not trainers or not result then return end
    for index = 1, #trainers do
        local trainer = trainers[index]
        if not seen[trainer.coords] then
            seen[trainer.coords] = true
            result.trainers[#result.trainers + 1] = trainer
        end
    end
end

local function spellMetadata(spellID)
    if not spellID or not C_Spell then return nil, nil end
    local name = E.Call(C_Spell.GetSpellName, spellID)
    local icon = E.Call(C_Spell.GetSpellTexture, spellID)
    if (not name or not icon) and type(C_Spell.RequestLoadSpellData) == "function" then
        E.Call(C_Spell.RequestLoadSpellData, spellID)
    end
    return name, icon
end

function G.Compile(entry)
    local info = G.Resolve(entry)
    -- 未学习该专业不再拦截指引：降级为“仅指引+静态材料采购”。
    local skill = info and (tonumber(info.skillLevel) or 0) or nil
    local maxSkill = info and (tonumber(info.maxSkillLevel) or 0) or 0
    local data = ns.LevelingGuides and ns.LevelingGuides.routes and ns.LevelingGuides.routes[entry.key]
    if not data then
        return { ok = false, guide = true, reason = L["暂无该专业的内置指引，请稍后再试。"] }
    end
    local result = { ok = true, guide = true, version = ns.LevelingGuides.version,
        skillLineID = info and (info.professionID or info.skillLineID) or nil,
        profession = info and info.name or entry.label,
        skill = skill or 0, maxSkill = maxSkill, target = data.covers,
        steps = {}, materials = {}, trainers = {},
        totals = { cost = 0, unpriced = 0, crafts = 0 } }
    local trainerSeen = {}
    if not skill then
        result.reason = format(L["尚未学习%s：路线与采购清单仍可用，制作需先学习。"], entry.label)
    end
    local stepIndex = 0
    for index = 1, #(data.steps or {}) do
        local guideStep = data.steps[index]
        -- 未学习专业（skill 为 nil）时显示全部区间；已学习则只显示未完成区间。
        if skill == nil or (tonumber(guideStep.to) or 0) > skill then
            stepIndex = stepIndex + 1
            local step = { from = tonumber(guideStep.from) or 0, to = tonumber(guideStep.to) or 0,
                count = tonumber(guideStep.count) or 0, owner = E.character,
                skillLineID = result.skillLineID, profession = result.profession, guide = true }
            if guideStep.note then
                step.note = true
                step.noteKey = guideStep.note
                step.name = G.NoteText(guideStep.note)
                step.text = guideStep.text
                applyTrainers(step, guideStep.text, result, trainerSeen)
                result.steps[stepIndex] = step
            else
                local spellID = tonumber(guideStep.spellID)
                local itemID = tonumber(guideStep.itemID)
                local recipe, learned = matchRecipe(itemID, spellID)
                local spellName, spellIcon = spellMetadata(spellID)
                step.spellID = spellID
                step.icon = spellIcon
                step.itemID = itemID
                step.itemKey = itemID and { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } or nil
                step.learned = learned
                if recipe then
                    step.recipeID = recipe.recipeID
                    step.recipe = recipe
                    step.name = recipe.name or spellName
                    step.outputItemID = recipe.outputItemID
                    if not step.itemID and recipe.outputItemID then
                        step.itemID = recipe.outputItemID
                        step.itemKey = { itemID = recipe.outputItemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
                    end
                    step.tier = recipe.skillUp or "unknown"
                    step.gray = tonumber(recipe.gray) or 0
                    step.yield = max(1, tonumber(recipe.quantityMin) or 1)
                else
                    step.name = spellName or (itemID and E.ItemName(itemID))
                        or format(L["施法技能 %s"], tostring(spellID or ""))
                end
                step.text = guideStep.text
                -- 静态指引材料：收割记录缺失或未学习时，采购仍按 wow.gg 数量展开。
                step.materials = guideStep.materials
                applyTrainers(step, guideStep.text, result, trainerSeen)
                if recipe and step.recipeID then
                    local analysis = learned and X.Analyse(step.recipeID, E.character) or nil
                    local cost = not learned and X.CostTable(recipe, E.character, true) or nil
                    step.unitCost = analysis and (analysis.totalCost or analysis.partialCost)
                        or cost and (cost.total or cost.knownTotal) or nil
                    step.cost = step.unitCost and step.unitCost * step.count or nil
                    step.craftableNow = analysis and analysis.craftableNow or 0
                end
                result.steps[stepIndex] = step
                if learned then result.totals.crafts = result.totals.crafts + step.count end
            end
        end
    end
    X.CompileRoute(result)
    result.covered = (skill or 0) < data.covers and data.covers or (skill or 0)
    result.gap = max(0, data.covers - (skill or 0))
    if skill and skill >= data.covers then
        result.reason = format(L["内置指引覆盖到技能 %d，之后请按游戏内橙黄配方继续。"], data.covers)
    end
    return result
end

function G.Snapshot()
    return { version = ns.LevelingGuides and ns.LevelingGuides.version or nil,
        professions = #PROFESSIONS }
end
