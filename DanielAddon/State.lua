-- 游戏状态导出：玩家位置 + 任务日志 + 下一步路径点。
-- 通道：/chatlog 写到 Logs/WoWChatLog.txt，用“对自己的密语”发结构化分片；
-- 外部 MCP server 只读这个文本文件，不读内存、不注入。
local addonName, ns = ...

ns.State = ns.State or {}
local State = ns.State

local PREFIX = "DANIEL1"
local CHUNK = 170          -- 每条密语的 JSON 片段字节数，加上前缀仍 < 255
local SEND_INTERVAL = 1.0  -- 聊天限速，别触发 "sending too quickly"
local hideStateChat = true -- 只在聊天框隐藏 DANIEL1 行；/chatlog 仍会写入

local function Sealed(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

function State.SetHideChat(on)
    hideStateChat = on and true or false
    if ns.db then ns.db.hideStateChat = hideStateChat end
end

local function HideStateMessage(_, _, msg)
    if not hideStateChat then return false end
    if type(msg) ~= "string" or Sealed(msg) then return false end
    if msg:match("^" .. PREFIX .. ":") then return true end
    return false
end

-- 只影响聊天框显示，不影响客户端 /chatlog 写文件
if type(ChatFrame_AddMessageEventFilter) == "function" then
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_WHISPER", HideStateMessage)
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_WHISPER_INFORM", HideStateMessage)
end

local function Truncate(s, n)
    if s == nil then return nil end
    if Sealed(s) then return "<secret>" end
    s = tostring(s)
    if #s <= n then return s end
    local i = n
    while i > 1 do
        local b = string.byte(s, i)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, math.max(1, i - 1)) .. "…"
end

local function JsonEscape(s)
    if Sealed(s) then return '"<secret>"' end
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("([\1-\31])", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end

local function Json(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if Sealed(v) or v ~= v then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e12 then
            return string.format("%d", v)
        end
        return string.format("%.6f", v)
    end
    if t == "string" then return JsonEscape(v) end
    if t == "table" then
        if v.__array then
            local parts = {}
            for i = 1, #v do parts[#parts + 1] = Json(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            if type(k) == "string" and k:sub(1, 2) ~= "__" then
                parts[#parts + 1] = JsonEscape(k) .. ":" .. Json(val)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

State.Json = Json

-- 当前地图/父地图上的任务 POI（GetNextWaypoint 在 Classic 经常没有坐标）
local function QuestPOIIndex(mapID)
    local out = {}
    if not (C_QuestLog and C_QuestLog.GetQuestsOnMap) then return out end

    local okOrig, origPOI = pcall(C_QuestLog.GetMapForQuestPOIs)
    local maps, seen = {}, {}
    local function addMap(mid)
        if mid and mid ~= 0 and not seen[mid] then
            seen[mid] = true
            maps[#maps + 1] = mid
        end
    end
    addMap(mapID)
    if C_QuestLog.GetMapForQuestPOIs then
        local ok, poiMap = pcall(C_QuestLog.GetMapForQuestPOIs)
        if ok then addMap(poiMap) end
    end
    if mapID and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and info then addMap(info.parentMapID) end
    end

    for _, mid in ipairs(maps) do
        if C_QuestLog.SetMapForQuestPOIs then
            pcall(C_QuestLog.SetMapForQuestPOIs, mid)
        end
        local ok, list = pcall(C_QuestLog.GetQuestsOnMap, mid)
        if ok and type(list) == "table" then
            for _, poi in ipairs(list) do
                if poi.questID and not poi.isQuestStart then
                    local prev = out[poi.questID]
                    -- 优先 inProgress / 非 quest start；多个 POI 时保留第一个
                    if not prev or (poi.inProgress and not prev.inProgress) then
                        out[poi.questID] = {
                            map = poi.mapID or mid,
                            x = poi.x,
                            y = poi.y,
                            inProgress = poi.inProgress and true or false,
                        }
                    end
                end
            end
        end
    end
    if okOrig and origPOI and C_QuestLog.SetMapForQuestPOIs then
        pcall(C_QuestLog.SetMapForQuestPOIs, origPOI)
    end
    return out
end

-- 地图 + 玩家 + 任务。任务只带前 2 条目标，标题截断，避免密语太长。
function State.Build()
    local mapID, continentID, wx, wy, px, py = ns.MarkerCore.PlayerWorld()
    local info
    if mapID and C_Map and C_Map.GetMapInfo then
        local ok, v = pcall(C_Map.GetMapInfo, mapID)
        if ok then info = v end
    end

    local out = {
        v = 3,
        ts = (time and time()) or 0,
        zone = info and info.name or nil,
        mapID = mapID,
        continentID = continentID,
        player = { x = px, y = py, wx = wx, wy = wy },
        quests = { __array = true },
        markers = { __array = true },
    }
    if ns.Markers and ns.Markers.List then
        for _, m in ipairs(ns.Markers.List()) do
            if #out.markers >= 20 then break end
            out.markers[#out.markers + 1] = {
                id = m.id, map = m.uiMapID, x = m.x, y = m.y, label = m.label,
            }
        end
    end
    if UnitLevel then
        local ok, lvl = pcall(UnitLevel, "player")
        if ok and not Sealed(lvl) then out.player.level = lvl end
    end
    if UnitClass then
        local ok, _, classToken = pcall(UnitClass, "player")
        if ok and type(classToken) == "string" then out.player.class = classToken end
    end

    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
        return out
    end

    local poiIndex = QuestPOIIndex(mapID)
    local poiCount = 0
    for _ in pairs(poiIndex) do poiCount = poiCount + 1 end
    out.poiCount = poiCount
    local shown = C_QuestLog.GetNumQuestLogEntries() or 0
    local count = 0
    for i = 1, shown do
        if count >= 20 then break end
        local qi = C_QuestLog.GetInfo(i)
        if qi and not qi.isHeader and qi.questID then
            count = count + 1
            local qid = qi.questID
            local q = {
                id = qid,
                title = Truncate(qi.title, 40),
                level = qi.level,
                onMap = qi.isOnMap and true or false,
            }

            local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(qid)
            if tag and tag.tagName then q.tag = tag.tagName end
            if C_QuestLog.IsComplete then q.complete = C_QuestLog.IsComplete(qid) and true or false end

            local nm, nx, ny
            if C_QuestLog.GetNextWaypoint then
                nm, nx, ny = C_QuestLog.GetNextWaypoint(qid)
            end
            if nm and nx and ny then
                q.next = { map = nm, x = nx, y = ny, from = "waypoint" }
            elseif poiIndex[qid] then
                local poi = poiIndex[qid]
                q.next = { map = poi.map, x = poi.x, y = poi.y, from = "poi" }
            end

            local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(qid)
            if objs and #objs > 0 then
                q.objectives = { __array = true }
                for j = 1, math.min(#objs, 2) do
                    local o = objs[j]
                    q.objectives[#q.objectives + 1] = {
                        text = Truncate(o.text, 32),
                        done = o.finished and true or false,
                        n = o.numFulfilled,
                        need = o.numRequired,
                    }
                end
            end
            out.quests[#out.quests + 1] = q
        end
    end
    return out
end

-- 传输格式 v4：短键 + 数组，比带字段名的大 JSON 小很多。
-- 结构化版本仍由 Build() 提供，MCP 端会把 v4 还原成可读对象。
function State.Pack(s)
    local p = s.player or {}
    local out = {
        v = 4,
        ts = s.ts,
        z = s.zone,
        m = s.mapID,
        p = { __array = true, p.x or 0, p.y or 0, p.level or 0, p.class or "" },
        q = { __array = true },
        mk = { __array = true },
    }
    for _, m in ipairs(s.markers or {}) do
        out.mk[#out.mk + 1] = {
            __array = true, m.id or 0, m.map or 0, m.x or 0, m.y or 0, m.label or "",
        }
    end
    for _, q in ipairs(s.quests or {}) do
        local nxt = q.next
        local row = {
            __array = true,
            q.id or 0,
            Truncate(q.title, 30) or "",
            q.level or 0,
            nxt and nxt.map or 0,
            nxt and nxt.x or 0,
            nxt and nxt.y or 0,
            q.complete and 1 or 0,
            { __array = true },
        }
        for _, o in ipairs(q.objectives or {}) do
            row[8][#row[8] + 1] = {
                __array = true,
                Truncate(o.text, 24) or "",
                o.done and 1 or 0,
                o.n or 0,
                o.need or 0,
            }
        end
        out.q[#out.q + 1] = row
    end
    return out
end

-- 按 UTF-8 字符边界切分，避免把中文截成半个字
local function Utf8Chunks(s, max)
    local out = {}
    local i = 1
    while i <= #s do
        local j = math.min(i + max - 1, #s)
        if j < #s then
            local b = string.byte(s, j + 1)
            while j > i and b and b >= 0x80 and b < 0xC0 do
                j = j - 1
                b = string.byte(s, j + 1)
            end
        end
        out[#out + 1] = s:sub(i, j)
        i = j + 1
    end
    return out
end

local sendGen = 0
local queue = {}
local sending = false

local targetIndex = 1
local channelIndex = nil

local function AddCandidate(out, v)
    if type(v) ~= "string" or v == "" or Sealed(v) then return end
    for _, x in ipairs(out) do
        if x == v then return end
    end
    out[#out + 1] = v
end

-- 候选密语目标：手动设置 > UnitFullName > GetUnitName(带服务器) > UnitName
function State.Candidates()
    local out = {}
    if ns.db then AddCandidate(out, ns.db.stateWhisperName) end
    if UnitFullName then
        local ok, full = pcall(UnitFullName, "player")
        if ok then AddCandidate(out, full) end
    end
    if GetUnitName then
        local ok, full = pcall(GetUnitName, "player", true)
        if ok then AddCandidate(out, full) end
    end
    if UnitName then
        local ok, short = pcall(UnitName, "player")
        if ok then AddCandidate(out, short) end
    end
    return out
end

function State.SetWhisperName(name)
    if not ns.db then return end
    ns.db.stateWhisperName = (name and name ~= "") and name or nil
    targetIndex = 1
    channelIndex = nil
    ns.__channelMode = nil
    if ns.Log then ns.Log("state.name", { name = ns.db.stateWhisperName }) end
end

local function CurrentTarget()
    local list = State.Candidates()
    if #list == 0 then return nil, list end
    if targetIndex > #list then targetIndex = #list end
    return list[targetIndex], list
end

local function SendSelfWhisper(text)
    if channelIndex then
        return pcall(SendChatMessage, text, "CHANNEL", nil, channelIndex)
    end
    local name = CurrentTarget()
    if not name then return false end
    return pcall(SendChatMessage, text, "WHISPER", nil, name)
end

-- 全部密语目标都失败时，切到私有聊天频道（仍然会进 /chatlog）
function State.EnableChannel()
    if channelIndex or ns.__channelMode then return false end
    ns.__channelMode = true
    local name = CurrentTarget() or "player"
    local channel = "danielagent" .. tostring(name):gsub("[^%w]", "")
    if type(JoinPermanentChannel) ~= "function" then return false end
    local ok, idx, joined = pcall(JoinPermanentChannel, channel, nil, DEFAULT_CHAT_FRAME:GetID(), 0)
    if not ok or not idx or idx == 0 then
        if ns.Log then ns.Log("state.channel_fail", { channel = channel, idx = idx }) end
        return false
    end
    channelIndex = idx
    ns.Print("自我密语目标不可用，状态改走私有频道：" .. tostring(joined or channel))
    if ns.Log then ns.Log("state.channel", { channel = tostring(joined or channel), index = idx }) end
    sendGen = sendGen + 1
    sending = false
    queue = {}
    State.SendNow("channel")
    return true
end

local function Pump(gen)
    if gen ~= sendGen then return end
    if InCombatLockdown and InCombatLockdown() then
        C_Timer.After(1, function() Pump(gen) end)
        return
    end
    local text = table.remove(queue, 1)
    if not text then
        sending = false
        if ns.statePendingSend then
            ns.statePendingSend = nil
            State.SendNow("pending")
        end
        return
    end
    local ok = SendSelfWhisper(text)
    if not ok then
        -- 密语被拦时至少留在本地聊天框；能读到的日志见 Log
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
    C_Timer.After(SEND_INTERVAL, function() Pump(gen) end)
end

local function InRestrictedInstance()
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside = pcall(IsInInstance)
    return ok and inside and true or false
end

local lastEventSig

local function QuestSig(payload)
    local parts = {}
    for _, q in ipairs(payload.quests or {}) do
        local n = q.next
        parts[#parts + 1] = tostring(q.id) .. ":" ..
            (n and (tostring(n.map) .. "," .. tostring(n.x) .. "," .. tostring(n.y)) or "-")
    end
    return table.concat(parts, ";")
end

function State.SendNow(reason)
    if not ns.db then return false end
    if sending then
        ns.statePendingSend = true
        if ns.Log then ns.Log("state.busy", { reason = reason }) end
        return false
    end
    local payload = State.Build()
    local sig = QuestSig(payload)
    if reason == "event" and sig == lastEventSig then
        return false
    end
    lastEventSig = sig
    local wire = State.Pack(payload)
    local json = Json(wire)
    ns.db.lastState = Json(payload)

    -- Midnight/Forever：实例内插件不允许发聊天通信，只能等服务出本
    if InRestrictedInstance() then
        if ns.Log then ns.Log("state.skip_instance", { reason = reason, quests = #payload.quests }) end
        return false
    end

    local sid = tostring(math.floor((GetTime() or 0) * 1000)) .. "-" .. tostring(math.random(1000, 9999))
    local chunks = Utf8Chunks(json, CHUNK)
    sendGen = sendGen + 1
    queue = {}
    for i = 1, #chunks do
        queue[#queue + 1] = PREFIX .. ":" .. sid .. ":" .. i .. "/" .. #chunks .. ":" .. chunks[i]
    end
    sending = true
    Pump(sendGen)

    if ns.Log then
        ns.Log("state.send", {
            reason = reason, sid = sid, chunks = #chunks,
            bytes = #json, quests = #payload.quests, poi = payload.poiCount or 0,
        })
    end
    return true
end

function State.EnsureLog(on)
    if type(LoggingChat) ~= "function" then
        ns.Print("客户端没有 LoggingChat；请手动 /chatlog 打开聊天日志。")
        return false
    end
    local okCur, cur = pcall(IsLoggingChat)
    if on and (not okCur or not cur) then
        pcall(LoggingChat, true)
    elseif not on and okCur and cur then
        pcall(LoggingChat, false)
    end
    local okNow, now = pcall(IsLoggingChat)
    if ns.Log then ns.Log("state.chatlog", { want = on, before = cur, after = now }) end
    if on and (not okNow or not now) and not ns.__chatlogWarned then
        ns.__chatlogWarned = true
        ns.Print("聊天日志仍是关闭状态；状态导出需要 /chatlog。请手动输入一次 /chatlog。")
    end
    return okNow and now or false
end

function State.Schedule(reason)
    if not ns.db or ns.db.stateAuto == false then return end
    if ns.stateTimer then ns.stateTimer:Cancel() end
    ns.stateTimer = C_Timer.NewTimer(1.2, function()
        ns.stateTimer = nil
        State.SendNow(reason or "auto")
    end)
end

function State.StartTicker()
    if ns.stateTicker then
        ns.stateTicker:Cancel()
        ns.stateTicker = nil
    end
    if not ns.db or ns.db.stateAuto == false then return end
    local interval = tonumber(ns.db.stateInterval) or 20
    ns.stateTicker = C_Timer.NewTicker(interval, function()
        State.SendNow("tick")
    end)
end

function State.Probe()
    local list = State.Candidates()
    ns.Print("UnitName=" .. tostring(UnitName and UnitName("player")))
    ns.Print("UnitFullName=" .. tostring(UnitFullName and select(1, UnitFullName("player"))))
    ns.Print("GetUnitName=" .. tostring(GetUnitName and GetUnitName("player", true)))
    ns.Print("密语候选=" .. table.concat(list, " ｜ "))
    local okLog, logging = pcall(IsLoggingChat)
    ns.Print("chatlog=" .. tostring(okLog and logging))
    local okIns, inside = pcall(IsInInstance)
    ns.Print("instance=" .. tostring(okIns and inside))
    ns.Print("channelIndex=" .. tostring(channelIndex))
    if ns.Log then ns.Log("state.probe", { candidates = list, logging = logging, inside = inside,
        channel = channelIndex }) end
end

function State.PrintSummary()
    local s = State.Build()
    ns.Print(string.format("%s（mapID %s） 玩家 %.1f,%.1f  任务 %d 个",
        tostring(s.zone), tostring(s.mapID),
        (s.player.x or 0) * 100, (s.player.y or 0) * 100, #s.quests))
    for i = 1, math.min(#s.quests, 6) do
        local q = s.quests[i]
        local nextText = q.next and string.format("  下一步 %.1f,%.1f (map %d)",
            q.next.x * 100, q.next.y * 100, q.next.map) or ""
        ns.Print(string.format("  [%d] %s%s", q.id, tostring(q.title), nextText))
    end
    if #s.quests > 6 then ns.Print("  …还有 " .. (#s.quests - 6) .. " 个") end
    ns.Print("状态已通过自我密语写入聊天日志；MCP 端读 Logs/WoWChatLog.txt。")
end

-- 把某个任务（或全部任务）的下一步路径点加进标记
function State.MarkQuestNext(questID)
    if not (C_QuestLog and C_QuestLog.GetNextWaypoint) then return 0 end
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local poiIndex = QuestPOIIndex(mapID)
    local added = 0
    local function one(qid)
        local nm, x, y
        if C_QuestLog.GetNextWaypoint then
            nm, x, y = C_QuestLog.GetNextWaypoint(qid)
        end
        if not nm and poiIndex[qid] then
            local poi = poiIndex[qid]
            nm, x, y = poi.map, poi.x, poi.y
        end
        if nm and x and y then
            local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qid)
            local m, _, dup = ns.Markers.Add(nm, x, y, "任务：" .. tostring(title or qid))
            if m and not dup then added = added + 1 end
        end
    end

    if questID and questID > 0 then
        one(questID)
    elseif C_QuestLog.GetNumQuestLogEntries then
        local shown = C_QuestLog.GetNumQuestLogEntries() or 0
        for i = 1, shown do
            local qi = C_QuestLog.GetInfo(i)
            if qi and not qi.isHeader and qi.questID then one(qi.questID) end
        end
    end
    if added > 0 and ns.MarkersUI then ns.MarkersUI.ScheduleRefresh(0.05) end
    return added
end

-- 任务/位置变化时自动推送（合并 1.2 秒内的连续事件）
local frame = CreateFrame("Frame")
local events = {
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
    "QUEST_WATCH_LIST_CHANGED", "WAYPOINT_UPDATE", "PLAYER_LEVEL_UP",
    "PLAYER_REGEN_ENABLED",
}
for _, e in ipairs(events) do
    pcall(frame.RegisterEvent, frame, e)
end
pcall(frame.RegisterEvent, frame, "CHAT_MSG_SYSTEM")

local function IsNoPlayerMessage(msg)
    msg = tostring(msg or "")
    return msg:find("未找到名为", 1, true) ~= nil
        or msg:find("No player named", 1, true) ~= nil
        or msg:find("player not found", 1, true) ~= nil
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if not ns.db then return end
    if event == "CHAT_MSG_SYSTEM" then
        if not IsNoPlayerMessage(arg1) then return end
        local _, list = CurrentTarget()
        if ns.Log then ns.Log("state.target_fail", { msg = arg1, index = targetIndex, total = #list }) end
        if targetIndex < #list then
            targetIndex = targetIndex + 1
            sendGen = sendGen + 1
            sending = false
            queue = {}
            ns.Print("自我密语目标不存在，改用：" .. tostring(list[targetIndex]))
            State.SendNow("retry-target")
        elseif not ns.__channelMode then
            ns.Print("所有密语目标都不可用，尝试切换私有频道。")
            State.EnableChannel()
        end
        return
    end
    State.Schedule("event")
end)
