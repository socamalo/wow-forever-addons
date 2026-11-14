-- luacheck: ignore addonName
local addonName, ns = ...
local type, tonumber, tostring, ipairs, next = type, tonumber, tostring, ipairs, next
local C_Item, C_TradeSkillUI = C_Item, C_TradeSkillUI -- luacheck: ignore C_TradeSkillUI
local match, gsub = string.match, string.gsub
local Presets = {}
ns.Presets = Presets
local activeVersion
local catalogs = {}
local requestedItems = {}

---Resolve only explicitly supported clients; never inherit another client's item IDs.
function Presets.ResolveVersion(version, interface)
    interface = tonumber(interface)
    if type(version) == "string" and version ~= "" then
        if (version == "12.1" or match(version, "^12%.1%.%d+$"))
            and (not interface or interface == 120100) then return "12.1" end
        if version == "1.60.1" and (not interface or interface == 16001) then return "1.60.1" end
        return nil
    end
    if interface == 120100 then return "12.1" end
    if interface == 16001 then return "1.60.1" end
end

local function configuration()
    local config = ns.DefaultLists
    return config and config.schema == 1 and config.versions and config.versions[activeVersion]
end

local function migrateShoppingLists()
    local versions = ns.DefaultLists and ns.DefaultLists.versions or {}
    for index, list in ipairs(ns.Store.GetLists()) do
        if list.presetID or list.presetVersion then
            local config = versions[list.presetVersion]
            local originalName
            for definitionIndex, definition in ipairs(config and config.lists or {}) do
                if definition.id == list.presetID then originalName = definition.name; break end
            end
            if originalName and list.name == originalName and not next(list.items or {}) then
                ns.Store.DeleteList(list.id)
            else
                if originalName and list.name == originalName then
                    list.name = gsub(originalName, "^默认", "") .. "补货"
                end
                list.presetID, list.presetVersion = nil, nil
            end
        end
    end
end

---Catalog tabs are runtime descriptors; only explicit user actions create purchase lists.
function Presets.Init(version, interface)
    activeVersion = Presets.ResolveVersion(version, interface)
    local config = activeVersion and configuration()
    migrateShoppingLists()
    catalogs = {}
    if not config then return nil end
    for index, definition in ipairs(config.lists or {}) do
        catalogs[index] = { presetID = definition.id, presetVersion = activeVersion,
            name = definition.displayName or gsub(definition.name, "^默认", "") }
    end
    return activeVersion
end

function Presets.Catalogs() return catalogs end

---Read the current catalog, so data-only revisions do not overwrite user settings.
function Presets.Definition(list)
    if not list or not activeVersion or list.presetVersion ~= activeVersion then return nil end
    local config = configuration()
    for index, definition in ipairs(config and config.lists or {}) do
        if definition.id == list.presetID then return definition end
    end
end

local function entryFor(definition, group, item, itemID, groupOrder, itemOrder, variantOrder)
    local itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    return { key = ns.Store.Key(itemKey), itemKey = itemKey, name = tostring(itemID),
        quantity = item.quantity or group.quantity or definition.quantity or 1,
        tag = item.tag, groupID = group.id, groupName = group.name,
        groupOrder = groupOrder, itemOrder = itemOrder, variantOrder = variantOrder }
end

local function craftingQuality(itemID)
    local quality = C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo
        and C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
    if type(quality) == "number" and quality > 0 then return quality end
    local info = C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityInfo
        and C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
    quality = info and info.quality
    if type(quality) == "number" and quality > 0 then return quality end
    -- Finished products can expose only crafted quality, not reagent quality.
    info = C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityInfo
        and C_TradeSkillUI.GetItemCraftedQualityInfo(itemID)
    quality = info and info.quality
    if type(quality) == "number" and quality > 0 then return quality end
    if C_Item and C_Item.RequestLoadItemDataByID and not requestedItems[itemID]
        and (not C_Item.IsItemDataCachedByID or not C_Item.IsItemDataCachedByID(itemID)) then
        -- Bound requests across repeated renders. A later item-data event refreshes the UI.
        requestedItems[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

---Filter each configured family by actual crafting quality, never by ID/order/rarity.
---Unknown and non-quality alternatives remain visible; no purchase list is modified.
function Presets.GroupEntries(catalog, groupIndex, mode)
    local definition = Presets.Definition(catalog)
    local group = definition and definition.groups and definition.groups[groupIndex]
    local entries = {}
    if not group then return entries end
    local filtered = mode == "highest" or mode == "lowest"
    for itemOrder, item in ipairs(group.items or {}) do
        local qualities, chosenQuality = {}, nil
        for variantOrder, itemID in ipairs(item.ids or {}) do
            local quality = craftingQuality(itemID)
            qualities[variantOrder] = quality
            if quality and (not chosenQuality or (mode == "highest" and quality > chosenQuality)
                or (mode == "lowest" and quality < chosenQuality)) then chosenQuality = quality end
        end
        for variantOrder, itemID in ipairs(item.ids or {}) do
            local quality = qualities[variantOrder]
            if not filtered or not quality or quality == chosenQuality then
                entries[#entries + 1] = entryFor(definition, group, item, itemID, groupIndex, itemOrder, variantOrder)
            end
        end
    end
    return entries
end

---Return one exact variant; sibling IDs must never collapse into one purchase target.
function Presets.Entry(list, itemID)
    local definition = Presets.Definition(list)
    itemID = tonumber(itemID)
    if not definition or not itemID then return nil end
    for groupOrder, group in ipairs(definition.groups or {}) do
        for itemOrder, item in ipairs(group.items or {}) do
            for variantOrder, candidateID in ipairs(item.ids or {}) do
                if candidateID == itemID then
                    return entryFor(definition, group, item, itemID, groupOrder, itemOrder, variantOrder)
                end
            end
        end
    end
end
