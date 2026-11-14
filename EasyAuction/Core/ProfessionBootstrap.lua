-- Blackthornes-derived profession logic lives here, never in the host namespace.
-- No standalone event frame, saved variable, scanner or transaction executor.
-- luacheck: read globals UnitName debugprofilestop
local addonName, ns = ... -- luacheck: ignore addonName
local type, tonumber, tostring, pairs, pcall = type, tonumber, tostring, pairs, pcall
local floor, huge = math.floor, math.huge
local time, GetRealmName, UnitName = time, GetRealmName, UnitName
local C_Timer, debugprofilestop = C_Timer, debugprofilestop
local print = print
local E = { revision = 0, cache = {}, timers = {} }
ns.ProfessionEngine = E
local L = ns.L

function E.Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
end

function E.Integer(value, minimum)
    value = tonumber(value)
    if value and value == value and value < huge and value >= (minimum or 0)
        and value <= 9007199254740991 and floor(value) == value then return value end
end

function E.Now() return (ns.Now or time)() end
function E.Setting(key, fallback)
    local value = ns.ProfessionSettings and ns.ProfessionSettings.Get(key)
    if value == nil then return fallback end
    return value
end

function E.Changed()
    E.revision = E.revision + 1
    E.cache = {}
    if E.Setting("debug", false) and print then print("EasyAuction professions revision", E.revision) end
    if ns.Emit then ns.Emit("professions:changed", E.revision) end
end

function E.Later(key, delay, callback)
    local old = E.timers[key]
    if old and old.Cancel then old:Cancel() end
    if C_Timer and C_Timer.NewTimer then
        E.timers[key] = C_Timer.NewTimer(delay, function()
            E.timers[key] = nil
            callback()
        end)
    else callback() end
end

function E.Clock() return debugprofilestop and debugprofilestop() or 0 end

function E.Bind()
    local root = ns.Store.GetDB()
    if not root then return false end
    root.professions = type(root.professions) == "table" and root.professions or {}
    E.db = root.professions
    for key in pairs({ characters = true, queue = true, postLimits = true, sales = true, vendorPrices = true }) do
        if type(E.db[key]) ~= "table" then E.db[key] = {} end
    end
    E.db.version = 1
    -- Copy inside pcall: protected identity values must not escape this boundary.
    local ok, name, realm = pcall(function()
        return tostring(UnitName and UnitName("player") or "Player"), tostring(GetRealmName and GetRealmName() or "Realm")
    end)
    if not ok then E.error = L["角色身份尚不可用"]; return false end
    E.character = name .. "-" .. realm
    local record = E.db.characters[E.character]
    if type(record) ~= "table" then record = {}; E.db.characters[E.character] = record end
    record.name, record.realm = name, realm
    for key in pairs({ recipes = true, learnable = true, inventory = true, bank = true, mail = true, professions = true }) do
        if type(record[key]) ~= "table" then record[key] = {} end
    end
    E.current, E.ready = record, true
    return true
end

function E.Recipe(recipeID, character)
    if not E.db then return nil end
    local record = E.db.characters[character or E.character]
    local own = record and record.recipes and record.recipes[recipeID]
    if own or character then return own, character or E.character end
    for key, candidate in pairs(E.db.characters) do
        if candidate.recipes and candidate.recipes[recipeID] then return candidate.recipes[recipeID], key end
    end
end

-- Read-only catalog lookup for guide/document views: learned first, learnable
-- second. E.Recipe remains the craft-capability lookup for queue/profit paths.
function E.RecipeData(recipeID, character)
    if not E.db then return nil end
    local owner = character or E.character
    local record = E.db.characters[owner]
    local recipe = record and record.recipes and record.recipes[recipeID]
    if recipe then return recipe, owner, true end
    local learnable = record and record.learnable and record.learnable[recipeID]
    if learnable then return learnable, owner, false end
    if character then return nil, owner, false end
    for key, candidate in pairs(E.db.characters) do
        recipe = candidate.recipes and candidate.recipes[recipeID]
        if recipe then return recipe, key, true end
        learnable = candidate.learnable and candidate.learnable[recipeID]
        if learnable then return learnable, key, false end
    end
    return nil, owner, false
end

function E.AllRecipes(accountWide)
    local rows = {}
    if not E.db then return rows end
    for character, record in pairs(E.db.characters) do
        if accountWide or character == E.character then
            for recipeID, recipe in pairs(record.recipes or {}) do
                rows[#rows + 1] = { recipeID = recipeID, recipe = recipe, character = character }
            end
        end
    end
    return rows
end
