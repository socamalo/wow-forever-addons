---@class BigFootSync
local BigFootSync = select(2, ...)
BigFootSync.info = {}

---@class Info
local I = BigFootSync.info
local U = BigFootSync.utils

function I.UpdateData()
    MU_InfoA = {
        flavor = U.GetClientMappingVersion(),
        region = GetCVar("portal"),
        addonVersion = tonumber(C_AddOns.GetAddOnMetadata("BigFootSync", "Version"):sub(2)),
        -- updateTime = time(),
    }
    MU_InfoC = MU_InfoA
end

function I.RefreshUpdateTime()
    MU_InfoA.updateTime = time()
    MU_InfoC.updateTime = MU_InfoA.updateTime
end