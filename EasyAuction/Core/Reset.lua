-- luacheck: ignore addonName
-- luacheck: read globals C_UI ReloadUI StaticPopup_Show StaticPopup_Hide
-- luacheck: globals StaticPopupDialogs
local addonName, ns = ...
local C_UI, ReloadUI, InCombatLockdown = C_UI, ReloadUI, InCombatLockdown
local StaticPopupDialogs, StaticPopup_Show, StaticPopup_Hide = StaticPopupDialogs, StaticPopup_Show, StaticPopup_Hide
local type, pcall = type, pcall
local Reset={}; ns.Reset=Reset
local pendingStates={awaiting_quote=true,submitting=true,submitted=true,uncertain=true}
local popupName="EASYAUCTION_RESET_ALL"
local L = ns.L

local function reloadFunction()
    return C_UI and C_UI.Reload or ReloadUI
end

function Reset.CanReset()
    if ns.resetting then return false,L["正在重置，请稍候。"] end
    if InCombatLockdown and InCombatLockdown() then return false,L["请脱离战斗后重置。"] end
    if type(reloadFunction())~="function" then return false,L["当前客户端无法重载界面，尚未清除数据。"] end
    local market=ns.Market
    if market and (market.unresolved or market.postActive or pendingStates[(market.buy or {}).state]
        or pendingStates[(market.post or {}).state]) then
        return false,L["交易回执尚未确定，请核对并处理完成后重置。"]
    end
    return true
end

function Reset.Dismiss()
    if StaticPopup_Hide then StaticPopup_Hide(popupName) end
end

local function execute(onError)
    local allowed,reason=Reset.CanReset()
    if not allowed then if onError then onError(reason) end; return end
    if ns.Market then ns.Market.Cancel() end
    local saved,wasReady=_G.EasyAuctionDB12,ns.ready
    ns.resetting=true; ns.ready=false
    if ns.UI then ns.UI.Close() end
    -- Replace the entire saved root, including all region/realm scopes and legacy fields.
    -- In-flight callbacks can only see the detached old table until the UI reloads.
    _G.EasyAuctionDB12={}
    local ok=pcall(reloadFunction())
    if not ok then
        _G.EasyAuctionDB12=saved; ns.ready=wasReady; ns.resetting=nil
        if ns.UI then ns.UI.Open(); ns.UI.SelectTab("settings") end
        if onError then onError(L["重载未成功，已保留全部数据。"]) end
    end
end

function Reset.Request(onError)
    local allowed,reason=Reset.CanReset()
    if not allowed then if onError then onError(reason) end; return false end
    if not StaticPopupDialogs or not StaticPopup_Show then
        if onError then onError(L["无法显示确认框，尚未清除数据。"]) end
        return false
    end
    StaticPopupDialogs[popupName]={
        text=L["重置 EasyAuction？\n\n将永久清除所有服务器的价格历史、购物清单、搜索记录、物品锁定和全部设置。\n\n无法撤销。确认后将重载界面。"],
        button1=L["清空并重载"],button2=L["取消"],timeout=0,whileDead=true,hideOnEscape=true,
        preferredIndex=3,OnAccept=function() execute(onError) end,
    }
    StaticPopup_Show(popupName)
    return true
end
