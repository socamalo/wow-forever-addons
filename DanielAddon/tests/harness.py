"""WoW Lua 桩环境：用 lupa 加载插件真实代码做单元测试。

用法：
    from harness import Harness
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps(...)
    h.fire_addon_loaded()
    result = h.call("return ADDON_NS.MarkerParse.ParseOne('铁炉堡 55 48')")
"""

from __future__ import annotations

import os
import lupa
from lupa import LuaRuntime

ADDON_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STUBS = r'''
-- ===== 基础全局 =====
GLOBAL_FRAMES = {}
CHAT = {}
ADDON_NS = {}
NOW = 0
function GetTime() return NOW end
function date(fmt) return "2026-11-10 12:00:00" end
function time() return 1762800000 end
function GetBuildInfo() return "1.60.1", "69913", "Nov 4 2026", 16001 end
WOW_PROJECT_ID = 18
WOW_PROJECT_CAMELOT = 18
NUM_BAG_SLOTS = 4
REAGENT_BAG_SLOTS = 0
INVTYPE_HEAD="INVTYPE_HEAD"; INVTYPE_NECK="INVTYPE_NECK"; INVTYPE_SHOULDER="INVTYPE_SHOULDER"
INVTYPE_CHEST="INVTYPE_CHEST"; INVTYPE_ROBE="INVTYPE_ROBE"; INVTYPE_WAIST="INVTYPE_WAIST"
INVTYPE_LEGS="INVTYPE_LEGS"; INVTYPE_FEET="INVTYPE_FEET"; INVTYPE_WRIST="INVTYPE_WRIST"
INVTYPE_HANDS="INVTYPE_HANDS"; INVTYPE_CLOAK="INVTYPE_CLOAK"; INVTYPE_FINGER="INVTYPE_FINGER"
INVTYPE_TRINKET="INVTYPE_TRINKET"; INVTYPE_WEAPON="INVTYPE_WEAPON"
INVTYPE_WEAPONMAINHAND="INVTYPE_WEAPONMAINHAND"; INVTYPE_WEAPONOFFHAND="INVTYPE_WEAPONOFFHAND"
INVTYPE_SHIELD="INVTYPE_SHIELD"; INVTYPE_HOLDABLE="INVTYPE_HOLDABLE"
INVTYPE_2HWEAPON="INVTYPE_2HWEAPON"; INVTYPE_RANGED="INVTYPE_RANGED"
INVTYPE_RANGEDRIGHT="INVTYPE_RANGEDRIGHT"; INVTYPE_THROWN="INVTYPE_THROWN"; INVTYPE_RELIC="INVTYPE_RELIC"

Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5 },
         BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5 } }

function issecretvalue(v) return false end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end

DEFAULT_CHAT_FRAME = { AddMessage = function(self, msg) table.insert(CHAT, msg) end,
  GetID = function() return 1 end }
SlashCmdList = {}
function hooksecurefunc(...) end
INVSLOT_AMMO = 0
INVSLOT_RANGED = 18
EQUIPPED_ITEMS = {}
EQUIPPED_COUNTS = {}
MONEY = 0
REPAIR_COST = 0
REPAIR_CAN = true
REPAIR_CALLS = 0
MERCHANT_ITEMS = {}
BUYS = {}
SOLD = {}
function GetInventoryItemID(unit, slot) return EQUIPPED_ITEMS[slot] end
function GetInventoryItemCount(unit, slot) return EQUIPPED_COUNTS[slot] or 0 end
function GetMoney() return MONEY end
function CanMerchantRepair() return REPAIR_CAN end
function GetRepairAllCost() return REPAIR_COST, REPAIR_CAN end
function RepairAllItems()
  REPAIR_CALLS = REPAIR_CALLS + 1
  MONEY = MONEY - REPAIR_COST
  REPAIR_COST = 0
  return true
end
function SetMoney(v) MONEY = v end
function GetMerchantNumItems() return #MERCHANT_ITEMS end
function GetMerchantItemInfo(i)
  local m = MERCHANT_ITEMS[i]
  if not m then return nil end
  return m.name, nil, m.price or 0, m.stack or 1, m.avail or -1, m.purchasable ~= false
end
function GetMerchantItemID(i) local m = MERCHANT_ITEMS[i]; return m and m.itemID end
function GetMerchantItemLink(i)
  local m = MERCHANT_ITEMS[i]
  return m and ("|Hitem:" .. m.itemID .. "|h") or nil
end
function GetMerchantItemMaxStack(i) local m = MERCHANT_ITEMS[i]; return m and m.stack or 1 end
function BuyMerchantItem(i, qty)
  local m = MERCHANT_ITEMS[i]
  if not m then return false end
  qty = qty or m.stack or 1
  table.insert(BUYS, { index = i, qty = qty, itemID = m.itemID })
  local batches = math.ceil(qty / (m.stack or 1))
  MONEY = MONEY - (m.price or 0) * batches
  return true
end
function SellCursorItem()
  if cursor then table.insert(SOLD, cursor.item.itemID); cursor = nil end
end
CHAT_FILTERS = {}
function ChatFrame_AddMessageEventFilter(event, fn)
  table.insert(CHAT_FILTERS, { event = event, fn = fn })
end

local timers = {}
C_Timer = {
  After = function(delay, fn) table.insert(timers, { at = NOW + (delay or 0), fn = fn }) end,
  NewTimer = function(delay, fn)
    local t = { at = NOW + (delay or 0), fn = fn, cancelled = false }
    function t:Cancel() self.cancelled = true end
    table.insert(timers, t)
    return t
  end,
  NewTicker = function(interval, fn)
    local t = { at = NOW + interval, fn = fn, cancelled = false, interval = interval }
    function t:Cancel() self.cancelled = true end
    table.insert(timers, t)
    return t
  end,
}
function Advance(seconds)
  local target = NOW + seconds
  while true do
    local best, bestIdx
    for i, t in ipairs(timers) do
      if not t.cancelled and t.at <= target and (not best or t.at < best.at) then
        best, bestIdx = t, i
      end
    end
    if not best then break end
    table.remove(timers, bestIdx)
    NOW = best.at
    best.fn()
    if best.interval and not best.cancelled then
      best.at = NOW + best.interval
      table.insert(timers, best)
    end
  end
  NOW = target
end

-- ===== 框体 =====
local function MakeRegion()
  local r = {}
  function r:SetPoint(point, rel, relPoint, x, y)
    self.points = self.points or {}
    table.insert(self.points, { point = point, rel = rel, relPoint = relPoint, x = x, y = y })
  end
  function r:ClearAllPoints() end
  function r:SetSize() end
  function r:SetWidth() end
  function r:SetHeight() end
  function r:SetAllPoints() end
  function r:SetColorTexture() end
  function r:SetTexture() end
  function r:SetAtlas() return true end
  function r:GetAtlas() return "test" end
  function r:SetVertexColor() end
  function r:SetBlendMode() end
  function r:SetDrawLayer() end
  function r:SetTexCoord() end
  function r:CreateAnimationGroup()
    local ag = { playing = false }
    function ag:CreateAnimation()
      local a = {}
      function a:SetFromAlpha() end
      function a:SetToAlpha() end
      function a:SetFromScale() end
      function a:SetToScale() end
      function a:SetDuration() end
      function a:SetSmoothing() end
      function a:SetOrigin() end
      return a
    end
    function ag:SetLooping() end
    function ag:Play() self.playing = true end
    function ag:Stop() self.playing = false end
    return ag
  end
  function r:SetBlendMode() end
  function r:SetAlpha() end
  function r:SetShown(v) self.shown = v end
  function r:Show() self.shown = true end
  function r:Hide() self.shown = false end
  function r:SetText() end
  function r:SetTextColor() end
  function r:SetJustifyH() end
  function r:SetFrameLevel() end
  function r:SetFrameStrata() end
  function r:SetChecked(v) self.checked = v end
  function r:GetChecked() return self.checked end
  function r:SetFontObject() end
  function r:SetShadowColor() end
  function r:SetShadowOffset() end
  function r:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
  function r:StartMoving() end
  function r:StopMovingOrSizing() end
  function r:SetMinMaxValues() end
  function r:SetValue() end
  function r:GetValue() return 0 end
  function r:SetStatusBarTexture() end
  function r:SetAlpha() end
  function r:SetScale() end
  function r:GetText() return self.text end
  function r:GetWidth() return self.width or 100 end
  function r:GetHeight() return self.height or 100 end
  function r:GetFrameLevel() return 1 end
  function r:GetScale() return 1 end
  function r:GetEffectiveScale() return 1 end
  return r
end

GameFontNormalLarge = MakeRegion()
GameFontNormalHuge = MakeRegion()

function CreateFrame(kind, name, parent, template)
  local f = MakeRegion()
  f.kind = kind
  f.name = name
  f.parent = parent
  f.scripts = {}
  f.events = {}
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:GetScript(k) return self.scripts[k] end
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:IsShown() return self.shown ~= false end
  function f:CreateTexture() return MakeRegion() end
  function f:CreateFontString() return MakeRegion() end
  function f:EnableMouse() end
  function f:SetMovable() end
  function f:EnableMouseWheel() end
  function f:RegisterForDrag() end
  function f:RegisterForClicks() end
  function f:SetBackdrop() end
  function f:SetBackdropColor() end
  function f:GetCenter() return 0, 0 end
  function f:GetChildren() return self.children or {} end
  function f:GetRegions() return {} end
  function f:GetID() return self.id or 0 end
  function f:SetID(id) self.id = id end
  function f:GetBagID() return self.bagID or 0 end
  function f:SetBagID(id) self.bagID = id end
  function f:Fire(event, ...)
    local h = self.scripts.OnEvent
    if h then return h(self, event, ...) end
  end
  table.insert(GLOBAL_FRAMES, f)
  if parent then
    parent.children = parent.children or {}
    table.insert(parent.children, f)
  end
  if name then _G[name] = f end
  return f
end

UIParent = CreateFrame("Frame", "UIParent")
Minimap = CreateFrame("Frame", "Minimap")
function Minimap:GetZoom() return 0 end
function Minimap:GetWidth() return 140 end
function Minimap:GetHeight() return 140 end
function Minimap:IsShown() return true end
function Minimap:GetFrameLevel() return 1 end
function Minimap:GetCenter() return 0, 0 end
GameTooltip = CreateFrame("Frame", "GameTooltip")
function GameTooltip:SetOwner() end
function GameTooltip:AddLine() end
function GameTooltip:Show() end
function GameTooltip:Hide() end
function GameTooltip:GetOwner() return nil end
function GameTooltip:HookScript() end

function GetCVar(name)
  if name == "rotateMinimap" then return "0" end
  if name == "minimapZoom" then return "0" end
  return "0"
end
function GetPlayerFacing() return 0 end
function InCombatLockdown() return false end
PLAYER_LEVEL = 60
function UnitLevel() return PLAYER_LEVEL end
CURRENT_CLASS = "WARRIOR"
function UnitClass() return "本地化", CURRENT_CLASS end
function UnitName(unit) return "Daniel" end
function UnitFullName(unit) return "Shorty Ranger", "Realm" end
function GetUnitName(unit, withRealm) return withRealm and "Shorty Ranger-Realm" or "Shorty Ranger" end
JOINED_CHANNELS = {}
function JoinPermanentChannel(name, password, frameID, hasVoice)
  local idx = #JOINED_CHANNELS + 5
  table.insert(JOINED_CHANNELS, { name = name, index = idx })
  return idx, name
end
SENT_CHAT = {}
function SendChatMessage(msg, chatType, lang, target)
  table.insert(SENT_CHAT, { msg = msg, chatType = chatType, target = target })
  return true
end
CHATLOG_ENABLED = false
function LoggingChat(on) CHATLOG_ENABLED = on and true or false end
function IsLoggingChat() return CHATLOG_ENABLED end

-- ===== 地图 =====
MAPS = {}
CURRENT_MAP_ID = 87
PLAYER_MAP_X, PLAYER_MAP_Y = 0.5, 0.5
WORLD_SCALE = 1000
WORLD_Y_NORTH = true       -- true: world y 向北（map y=0 -> world y=1000）
CONTINENT_OF = {}          -- mapID -> continentID，默认自身
MAP_PARENT = {}            -- mapID -> parentMapID
WAYPOINTS = {}

function CreateVector2D(x, y) return { x = x, y = y } end
UiMapPoint = {
  CreateFromCoordinates = function(mapID, x, y)
    return { uiMapID = mapID, position = CreateVector2D(x, y) }
  end,
}

local function worldFromMap(mapID, vec)
  local x = vec.x * WORLD_SCALE
  local y
  if WORLD_Y_NORTH then
    y = (1 - vec.y) * WORLD_SCALE
  else
    y = vec.y * WORLD_SCALE
  end
  return CONTINENT_OF[mapID] or mapID, { x = x, y = y }
end

local function onMap(mapID, ancestor)
  local seen = {}
  while mapID and mapID ~= 0 and not seen[mapID] do
    if mapID == ancestor then return true end
    seen[mapID] = true
    mapID = MAP_PARENT[mapID]
  end
  return false
end

local function mapFromWorld(continentID, vec, overrideMapID)
  if overrideMapID and overrideMapID ~= continentID and not onMap(overrideMapID, continentID) then
    return nil
  end
  local x = vec.x / WORLD_SCALE
  local y
  if WORLD_Y_NORTH then
    y = 1 - vec.y / WORLD_SCALE
  else
    y = vec.y / WORLD_SCALE
  end
  return overrideMapID or continentID, { x = x, y = y }
end

C_Map = {
  GetMapInfo = function(id) return MAPS[id] end,
  GetMapWorldSize = function(mapID) return 1000, 1000 end,
  GetBestMapForUnit = function(unit) return CURRENT_MAP_ID end,
  GetPlayerMapPosition = function(mapID, unit)
    return { x = PLAYER_MAP_X, y = PLAYER_MAP_Y }
  end,
  GetWorldPosFromMapPos = function(mapID, vec)
    return worldFromMap(mapID, vec)
  end,
  GetMapPosFromWorldPos = function(continentID, vec, overrideMapID)
    return mapFromWorld(continentID, vec, overrideMapID)
  end,
  SetUserWaypoint = function(point)
    table.insert(WAYPOINTS, point)
    return true
  end,
}
C_Minimap = { GetViewRadius = function() return 100 end }

-- ===== 背包 / 物品 =====
local bags = {}
BAGS = bags
BAG_SLOTS = 4
REAGENT_BAG_SLOTS = 0
local function bagOf(bag) bags[bag] = bags[bag] or {}; return bags[bag] end
function SetBag(bag, items)
  bags[bag] = {}
  for slot, it in pairs(items) do bags[bag][slot] = it end
end

PRICES = {}
ITEM_DB = {}
ITEM_STATS = {}
EQUIP = {}
function GetInventoryItemLink(unit, slot)
  local id = EQUIP[slot]
  if not id then return nil end
  return "|cffa335ee|Hitem:" .. id .. ":0|h[" .. tostring(id) .. "]|h|r"
end

C_Container = {
  GetContainerNumSlots = function(bag)
    if bag == 5 then return REAGENT_BAG_SLOTS end
    return BAG_SLOTS
  end,
  GetContainerNumFreeSlots = function(bag) return 0, BAG_FAMILY[bag] end,
  GetContainerItemInfo = function(bag, slot)
    local it = bagOf(bag)[slot]
    if not it then return nil end
    return {
      itemID = it.itemID, stackCount = it.count or 1, quality = it.quality or 1,
      isLocked = false, hasNoValue = false,
      itemName = (ITEM_DB[it.itemID] and ITEM_DB[it.itemID].name) or "",
      hyperlink = "|Hitem:" .. it.itemID .. "|h",
    }
  end,
  GetContainerItemQuestInfo = function(bag, slot)
    return QUEST_INFO[bag * 1000 + slot] or {}
  end,
  PickupContainerItem = function(bag, slot)
    local b = bagOf(bag)
    local it = b[slot]
    if cursor == nil then
      if it == nil then return end
      cursor = { item = it, origin = { bag = bag, slot = slot } }
      b[slot] = nil
    elseif it ~= nil then
      local maxStack = it.maxStack or 20
      if it.itemID == cursor.item.itemID
          and (it.count or 1) + (cursor.item.count or 1) <= maxStack then
        -- 客户端对同种可堆叠物品会合并，而不是交换
        it.count = (it.count or 1) + (cursor.item.count or 1)
        cursor = nil
      else
        b[slot] = cursor.item
        cursor = { item = it, origin = { bag = bag, slot = slot }, vacated = cursor.origin }
      end
    else
      b[slot] = cursor.item
      cursor = nil
    end
  end,
  UseContainerItem = function() end,
}

cursor = nil
function ClearCursor()
  if not cursor then return end
  local target = cursor.vacated or cursor.origin
  local b = bagOf(target.bag)
  if b[target.slot] == nil then
    b[target.slot] = cursor.item
  else
    local origin = bagOf(cursor.origin.bag)
    local placed = false
    if origin[cursor.origin.slot] == nil then
      origin[cursor.origin.slot] = cursor.item
      placed = true
    end
    if not placed then
      for bb = 0, 4 do
        for ss = 1, BAG_SLOTS do
          if bagOf(bb)[ss] == nil then bagOf(bb)[ss] = cursor.item; placed = true; break end
        end
        if placed then break end
      end
    end
  end
  cursor = nil
end
function DumpBag(bag)
  local out = {}
  for slot = 1, BAG_SLOTS do
    local it = bagOf(bag)[slot]
    out[#out + 1] = it and tostring(it.itemID) or "-"
  end
  return table.concat(out, " ")
end

C_Item = {
  GetItemInfo = function(itemID)
    local d = ITEM_DB[itemID]
    if d then
      return d.name, "|Hitem:" .. itemID .. "|h", d.quality, d.ilvl, d.reqLevel,
             d.type or "Armor", d.subType or "", d.count or 1, d.equipLoc or "",
             1, PRICES[itemID] or 0, d.classID or 4, d.subclassID or 0, d.bind or 0, 0, 0, false
    end
    local p = PRICES[itemID]
    if p == nil then return nil end
    return "name" .. itemID, "|Hitem:" .. itemID .. "|h", 1, 1, 1, "Misc", "Junk",
           1, "", 1, p, 0, 0, 0, 0, 0, false
  end,
  GetItemInfoInstant = function(itemID)
    local d = ITEM_DB[itemID]
    if d then
      return itemID, d.type or "Armor", d.subType or "", d.equipLoc, 1, d.classID or 4, d.subclassID or 0
    end
    return itemID, "Misc", "Junk", "", 1, 15, 0
  end,
  GetItemStats = function(link)
    local id = tonumber(string.match(link or "", "item:(%d+)"))
    return id and ITEM_STATS[id] or nil
  end,
  IsEquippableItem = function(itemID)
    local d = ITEM_DB[itemID]
    return d ~= nil and d.equippable ~= false
  end,
  GetItemCount = function(itemID)
    local total = 0
    for bag = 0, 4 do
      for slot = 1, BAG_SLOTS do
        local it = bagOf(bag)[slot]
        if it and it.itemID == itemID then total = total + (it.count or 1) end
      end
    end
    return total
  end,
  IsUsableItem = function(itemID)
    local d = ITEM_DB[itemID]
    if not d then return false end
    if d.usable == false then return false end
    return not d.reqLevel or d.reqLevel <= UnitLevel("player")
  end,
  RequestLoadItemDataByID = function() end,
  EquipItemByName = function(itemID, dstSlot)
    local srcBag, srcSlot, it
    for b = 0, 4 do
      for s = 1, BAG_SLOTS do
        local x = bagOf(b)[s]
        if x and x.itemID == itemID then srcBag, srcSlot, it = b, s, x; break end
      end
      if it then break end
    end
    if not it then return end
    local db = ITEM_DB[itemID]
    local target = dstSlot or (db and (db.slot))
    if not target then return end
    local old = EQUIP[target]
    EQUIP[target] = itemID
    bagOf(srcBag)[srcSlot] = old and { itemID = old } or nil
  end,
}
C_TooltipInfo = { GetHyperlink = function() return { lines = {} } end }

QUEST_LOG = {}
QUEST_OBJECTIVES = {}
QUEST_NEXT = {}
BAG_FAMILY = { [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
QUEST_POIS = {}
QUEST_INFO = {}
C_QuestLog = {
  GetNumQuestLogEntries = function() return #QUEST_LOG, #QUEST_LOG end,
  GetInfo = function(i) return QUEST_LOG[i] end,
  GetQuestObjectives = function(id) return QUEST_OBJECTIVES[id] or {} end,
  GetNextWaypoint = function(id)
    local n = QUEST_NEXT[id]
    if not n then return nil end
    return n.map, n.x, n.y
  end,
  GetQuestsOnMap = function(mapID) return QUEST_POIS[mapID] or {} end,
  GetMapForQuestPOIs = function() return CURRENT_MAP_ID end,
  GetQuestTagInfo = function(id)
    local q = QUEST_LOG[id]
    return q and q.tag and { tagName = q.tag } or nil
  end,
  IsComplete = function(id)
    local q = QUEST_LOG[id]
    return q and q.complete or false
  end,
  GetTitleForQuestID = function(id)
    local q = QUEST_LOG[id]
    return q and q.title or nil
  end,
}
'''

LOAD_ORDER = ["Core.lua", "Log.lua", "MarkerCore.lua"]


class Harness:
    def __init__(self):
        self.L = LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(STUBS)
        self._chunk_counter = 0

    def execute(self, code):
        return self.L.execute(code)

    def load_addon(self, files=None):
        files = files or LOAD_ORDER
        for name in files:
            path = os.path.join(ADDON_DIR, name)
            with open(path, encoding="utf-8") as f:
                src = f.read()
            chunk_name = f"@test_{self._chunk_counter}_{name}"
            self._chunk_counter += 1
            chunk = self.L.compile(src, chunk_name)
            self.L.globals()[f"_chunk_{self._chunk_counter}"] = chunk
            self.L.execute(
                f'_chunk_{self._chunk_counter}("DanielAddon", ADDON_NS)'
            )

    def fire_addon_loaded(self, name="DanielAddon"):
        self.L.execute(
            """
            for _, f in ipairs(GLOBAL_FRAMES) do
              if f.events and f.events.ADDON_LOADED then
                f:Fire("ADDON_LOADED", ...)
              end
            end
            """.replace("...", f'"{name}"')
        )

    def install_maps(self, maps, current=87, px=0.5, py=0.5, world_y_north=True):
        """maps: dict[int, (name, mapType, parentID)]"""
        rows = []
        for mid, (name, mtype, parent) in maps.items():
            rows.append(
                f'MAPS[{mid}] = {{ mapID = {mid}, name = "{name}", '
                f"mapType = {mtype}, parentMapID = {parent} }}"
            )
        self.execute("\n".join(rows))
        parents = "\n".join(f"MAP_PARENT[{mid}] = {parent}" for mid, (_, _, parent) in maps.items())
        self.execute(parents)
        self.execute(
            f"CURRENT_MAP_ID = {current}; PLAYER_MAP_X = {px}; PLAYER_MAP_Y = {py}; "
            f"WORLD_Y_NORTH = {'true' if world_y_north else 'false'}"
        )

    def call(self, expr):
        return self.L.execute(expr)

    def lua(self, code):
        return self.L.execute(code)
