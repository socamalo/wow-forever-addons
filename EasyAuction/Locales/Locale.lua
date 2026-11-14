-- Locale tables are loaded before addon modules. Source keys are Simplified Chinese.
local addonName, ns = ... -- luacheck: ignore addonName
local GetLocale, setmetatable, pairs, type = GetLocale, setmetatable, pairs, type
local dictionaries = {zhCN={}, zhTW={}, enUS={}}
local Locale = {code="enUS", dictionaries=dictionaries}
ns.Locale = Locale
function Locale.Register(code, entries)
    local dictionary = dictionaries[code]
    if not dictionary or type(entries)~="table" then return end
    for key,value in pairs(entries) do dictionary[key]=value end
end
function Locale.Select(code)
    Locale.code = dictionaries[code] and code or "enUS"
end
ns.L = setmetatable({}, {__index=function(self, key)
    if Locale.code=="zhCN" then return dictionaries.zhCN[key] or key end
    return dictionaries[Locale.code][key] or dictionaries.enUS[key] or key
end})
Locale.Select(GetLocale and GetLocale() or "enUS")
