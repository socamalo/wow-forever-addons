-- 在能维修的商人处自动修全身装备（只花自己的钱）
local addonName, ns = ...

local frame = CreateFrame("Frame")

local function CanRepair()
    if type(CanMerchantRepair) ~= "function" then return false end
    local ok, can = pcall(CanMerchantRepair)
    return ok and can and true or false
end

function ns.RepairTry(force)
    if not ns.db or ns.db.autoRepair == false then return false end
    if not CanRepair() then return false end

    local okCost, cost, canRepair = pcall(GetRepairAllCost)
    if not okCost or not canRepair or not cost or cost <= 0 then
        return false
    end

    local money = GetMoney and GetMoney() or 0
    if money < cost then
        ns.repairPending = true
        if not ns.__repairMoneyWarned then
            ns.__repairMoneyWarned = true
            ns.Print("维修需要 " .. ns.Money(cost) .. "，钱不够（现有 "
                .. ns.Money(money) .. "），卖完垃圾再试。")
        end
        if ns.Log then
            ns.Log("repair.skip", { cost = cost, money = money, why = "money" })
        end
        return false
    end

    local before = money
    local ok, err = pcall(RepairAllItems)
    local after = select(1, GetRepairAllCost())
    local spent = before - (GetMoney and GetMoney() or before)
    ns.repairPending = false

    if ns.Log then
        ns.Log("repair", {
            cost = cost, spent = spent, remaining = after,
            ok = ok and true or false, err = ok and nil or tostring(err),
        })
    end
    if ok then
        if spent > 0 then
            ns.Print("自动维修完成，花费 " .. ns.Money(spent) .. "。")
        end
    else
        ns.Print("自动维修失败：" .. tostring(err))
    end
    return ok
end

ns.Repair = { Try = ns.RepairTry }

frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        ns.repairPending = false
        ns.__repairMoneyWarned = nil
        -- MERCHANT_SHOW 是硬件事件上下文，优先在这里修
        ns.RepairTry()
    else
        ns.repairPending = false
    end
end)
