-- luacheck: globals C_TradeSkillUI ProfessionsUtil
-- Bridges Blizzard's tracked-profession recipes into optional EasyAuction lists.
-- The tracker only reacts to TRACKED_RECIPE_UPDATE; it never changes recipe
-- tracking itself. Tracking a recipe creates its temporary material list at
-- once (no confirmation popup); untracking removes that list again.
local addonName, ns = ... -- luacheck: ignore addonName
local C_TradeSkillUI = C_TradeSkillUI
local C_Item = C_Item
local ProfessionsUtil = ProfessionsUtil
local GetItemInfo = GetItemInfo
local type, tonumber, tostring, ipairs, pcall, select = type, tonumber, tostring, ipairs, pcall, select
local format = string.format
local L = ns.L

local Tracker = { states = {} }
ns.RecipeTracker = Tracker

local function safeCall(func, ...)
    if type(func) ~= "function" then return nil end
    local ok, first = pcall(func, ...)
    if ok then return first end
    return nil
end

local function recipeKey(recipeID, isRecraft)
    return tostring(recipeID) .. ":" .. (isRecraft and "1" or "0")
end

local function contains(list, value)
    if type(list) ~= "table" then return false end
    for index = 1, #list do
        if list[index] == value then return true end
    end
    return false
end

local function trackedByList(recipeID, isRecraft)
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipesTracked) ~= "function" then
        return nil
    end
    local recipes = safeCall(C_TradeSkillUI.GetRecipesTracked, isRecraft)
    if type(recipes) ~= "table" then return nil end
    return contains(recipes, recipeID)
end

local function isTracked(recipeID, isRecraft, eventTracked)
    if C_TradeSkillUI and type(C_TradeSkillUI.IsRecipeTracked) == "function" then
        local result = safeCall(C_TradeSkillUI.IsRecipeTracked, recipeID, isRecraft)
        if type(result) == "boolean" then return result end
    end
    local listed = trackedByList(recipeID, isRecraft)
    if listed ~= nil then return listed end
    if not isRecraft and type(eventTracked) == "boolean" then return eventTracked end
    return nil
end

local function currentStates()
    local states = {}
    for recraftIndex = 1, 2 do
        local isRecraft = recraftIndex == 2
        if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipesTracked) == "function" then
            local recipes = safeCall(C_TradeSkillUI.GetRecipesTracked, isRecraft)
            if type(recipes) == "table" then
                for index = 1, #recipes do
                    local recipeID = tonumber(recipes[index])
                    if recipeID then states[recipeKey(recipeID, isRecraft)] = true end
                end
            end
        end
    end
    return states
end

local function itemName(itemID)
    if not itemID then return nil end
    if C_Item and type(C_Item.GetItemNameByID) == "function" then
        local name = safeCall(C_Item.GetItemNameByID, itemID)
        if type(name) == "string" and name ~= "" then return name end
    end
    local name = GetItemInfo and select(1, GetItemInfo(itemID))
    if type(name) == "string" and name ~= "" then return name end
    return format(L["物品 %s"], tostring(itemID))
end

local function itemKey(itemID)
    return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function slotReagents(reagents)
    local chosen, chosenTier = nil, -1
    local candidates, seen = {}, {}
    for index = 1, #(reagents or {}) do
        local reagent = reagents[index]
        local reagentID = reagent and tonumber(reagent.itemID)
        if reagentID and reagentID > 0 and not seen[reagentID] then
            seen[reagentID] = true
            candidates[#candidates + 1] = reagentID
            local tier = 0
            if C_TradeSkillUI and type(C_TradeSkillUI.GetItemReagentQualityByItemInfo) == "function" then
                tier = tonumber(safeCall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, reagentID)) or 0
            end
            if tier >= chosenTier then
                chosen, chosenTier = reagentID, tier
            end
        end
    end
    return candidates, chosen
end

function Tracker.BuildRecipe(recipeID, isRecraft)
    if not recipeID or not C_TradeSkillUI then return nil end
    local schematic = safeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, isRecraft == true)
    if type(schematic) ~= "table" then return nil end
    local info = safeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    local name = type(info) == "table" and info.name or schematic.name
    local materials, byItem = {}, {}
    for slotIndex, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local required = slot.required
        if ProfessionsUtil and type(ProfessionsUtil.IsReagentSlotRequired) == "function" then
            local helperRequired = safeCall(ProfessionsUtil.IsReagentSlotRequired, slot)
            if helperRequired ~= nil then required = helperRequired end
        end
        if required == nil then required = slot.reagentType == 1 end
        -- Reagent type 1 is the basic required material. Optional and
        -- embellishment slots are deliberately left to the crafting UI.
        if required and slot.reagentType == 1 then
            local candidates, chosen = slotReagents(slot.reagents)
            local quantity = tonumber(slot.quantityRequired) or 0
            if quantity > 0 then
                for index = 1, #candidates do
                    local reagentID = candidates[index]
                    local existing = byItem[reagentID]
                    if existing then
                        existing.quantity = existing.quantity + quantity
                        existing.includeInRestock = existing.includeInRestock or reagentID == chosen
                    else
                        local material = { itemID = reagentID, itemKey = itemKey(reagentID),
                            name = itemName(reagentID), quantity = quantity, slotIndex = slotIndex,
                            includeInRestock = reagentID == chosen }
                        materials[#materials + 1] = material; byItem[reagentID] = material
                    end
                end
            end
        end
    end
    return { recipeID = recipeID, isRecraft = isRecraft == true,
        outputItemID = schematic.outputItemID, name = name or (format(L["配方 %s"], tostring(recipeID))),
        materials = materials }
end

function Tracker.Init()
    Tracker.states = currentStates()
    for index, list in ipairs(ns.Store.GetLists()) do -- luacheck: ignore index
        Tracker.UpdateRecipeList(list)
    end
end

function Tracker.UpdateRecipeList(list)
    if not list or not list.recipe or list.recipe.materialVariants == 1 then return false end
    local recipe = Tracker.BuildRecipe(list.recipe.recipeID, list.recipe.isRecraft)
    if not recipe or #recipe.materials == 0 then return false end
    return ns.Store.SyncRecipeMaterials(list.id, recipe.materials)
end

local function Say(message)
    if print then print("|cff77bbddEasyAuction|r " .. message) end
end

local function handleTransition(recipeID, isRecraft, eventTracked)
    local key = recipeKey(recipeID, isRecraft)
    local current = isTracked(recipeID, isRecraft, eventTracked)
    if type(current) ~= "boolean" then return end
    local previous = Tracker.states[key]
    if previous == nil then previous = false end
    Tracker.states[key] = current
    if current then Tracker.UpdateRecipeList(ns.Store.FindRecipeList(recipeID, isRecraft)) end
    if previous == current then return end
    local recipe = Tracker.BuildRecipe(recipeID, isRecraft)
    if current then
        -- 追踪即建单：直接生成临时材料采购清单，不再弹窗打断（参考
        -- DFCN_PatronOffers 的临时清单模式）。清单随取消追踪一并移除。
        if recipe and #recipe.materials > 0 and not ns.Store.FindRecipeList(recipeID, isRecraft) then
            local list = ns.Store.CreateRecipeList(recipe, recipe.materials)
            if list then
                Say(format(L["已为追踪配方生成临时采购清单：%s"], list.name or recipe.name or tostring(recipeID)))
                if ns.Emit then ns.Emit("professions:changed") end
            else
                ns.lastError = L["无法生成配方材料购物清单"]
            end
        end
    else
        local list = ns.Store.FindRecipeList(recipeID, isRecraft)
        if list and ns.Store.DeleteList(list.id) then
            Say(format(L["已移除追踪配方“%s”的临时采购清单"], list.name or tostring(recipeID)))
            if ns.Emit then ns.Emit("professions:changed") end
        end
    end
end

function Tracker.OnEvent(event, ...)
    if event ~= "TRACKED_RECIPE_UPDATE" then return end
    local recipeID, tracked = ...
    if not recipeID then return end
    handleTransition(recipeID, false, tracked)
    handleTransition(recipeID, true, nil)
end

return Tracker
