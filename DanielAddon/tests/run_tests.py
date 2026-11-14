#!/usr/bin/env python3
"""DanielAddon 单元测试：Python + lupa 加载真实 Lua 代码。

运行：
    uv run --with lupa python -I tests/run_tests.py
"""

from __future__ import annotations

import glob
import json
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from harness import Harness  # noqa: E402

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)))


TESTS = []


def run(name):
    def wrapper(fn):
        TESTS.append((name, fn))
        return fn

    return wrapper


def approx(a, b, eps=1e-9):
    try:
        return abs(float(a) - float(b)) <= eps
    except Exception:
        return False


# ---------------------------------------------------------------- syntax
@run("syntax: all Lua files compile")
def test_syntax():
    h = Harness()
    for path in sorted(glob.glob(os.path.join(ADDON_DIR, "*.lua"))):
        with open(path, encoding="utf-8") as f:
            src = f.read()
        try:
            h.L.compile(src, path)
        except Exception as e:
            raise AssertionError(f"{os.path.basename(path)}: {e}")


# ---------------------------------------------------------------- markers
@run("marker: parse pipe / space / batch / invalid")
def test_marker_parse():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({1426: ("丹莫罗", 3, 2)})

    p = h.call("return ADDON_NS.MarkerParse.ParseOne('铁炉堡|55.2|47.8|武器大师')")
    check("parse pipe zone", p["zone"] == "铁炉堡", p)
    check("parse pipe x", approx(p["x"], 0.552), p)
    check("parse pipe y", approx(p["y"], 0.478), p)
    check("parse pipe label", p["label"] == "武器大师", p)

    p = h.call("return ADDON_NS.MarkerParse.ParseOne('Thunder Bluff 30 40')")
    check("parse space zone with spaces", p["zone"] == "Thunder Bluff", p)
    check("parse space coords", approx(p["x"], 0.30) and approx(p["y"], 0.40), p)

    p = h.call("return ADDON_NS.MarkerParse.ParseOne('55.2,47.8')")
    check("parse coords only -> current map", p["zone"] is None and approx(p["x"], 0.552), p)

    p = h.call("local p = ADDON_NS.MarkerParse.ParseOne('1426 69.8 56.8'); return p")
    check("parse numeric mapID zone", p["zone"] == "1426" and approx(p["x"], 0.698)
          and approx(p["y"], 0.568), p)

    p = h.call("local p = ADDON_NS.MarkerParse.ParseOne('丹莫罗 69.8 56.8'); return p")
    check("parse zone name + coords", p["zone"] == "丹莫罗" and approx(p["x"], 0.698), p)

    p, err = h.call("return ADDON_NS.MarkerParse.ParseOne('not a marker')")
    check("parse invalid returns error", p is None and isinstance(err, str), (p, err))

    batch = h.call("return ADDON_NS.MarkerParse.ParseBatch('铁炉堡|55|48|武器大师;铁炉堡|56|49|训练师')")
    check("parse batch count", len(batch) == 2, len(batch))

    batch, err = h.call("return ADDON_NS.MarkerParse.ParseBatch('铁炉堡|55|48|武器大师;bad')")
    check("parse batch reports index", batch is None and "第 2 项" in str(err), err)


@run("marker: map name / alias / substring resolution")
def test_marker_resolve():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({
        1: ("Kalimdor", 2, 0),
        2: ("Eastern Kingdoms", 2, 0),
        87: ("铁炉堡", 3, 2),
        88: ("雷霆崖", 3, 1),
    })

    mid, name = h.call("return ADDON_NS.MarkerCore.ResolveMap('铁炉堡')")
    check("resolve zh exact", mid == 87 and name == "铁炉堡", (mid, name))

    mid, name = h.call("return ADDON_NS.MarkerCore.ResolveMap('Ironforge')")
    check("resolve city alias", mid == 87, (mid, name))

    mid, name = h.call("return ADDON_NS.MarkerCore.ResolveMap('ironf')")
    check("resolve substring", mid == 87, (mid, name))

    mid, err = h.call("return ADDON_NS.MarkerCore.ResolveMap('不存在的地方')")
    check("resolve missing returns error", mid is None and isinstance(err, str), (mid, err))


@run("marker: add / duplicate / remove / clear / world pos")
def test_marker_store():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.execute("CONTINENT_OF[87] = 2")
    h.fire_addon_loaded()

    m = h.call("local m = ADDON_NS.Markers.Add('铁炉堡', 0.55, 0.48, '武器大师'); return m")
    check("add returns marker", m is not None, m)
    check("add zone name", m["zoneName"] == "铁炉堡", m)
    check("add world pos", approx(m["wx"], 550) and approx(m["wy"], 520), (m["wx"], m["wy"]))
    check("add continent", m["continentID"] == 2, m["continentID"])

    m2, err, dup = h.call("return ADDON_NS.Markers.Add('铁炉堡', 0.55, 0.48, '武器大师')")
    check("duplicate returns same id", m2["id"] == m["id"] and dup is True, (m2, dup))
    check("duplicate does not grow", h.call("return #ADDON_NS.Markers.List()") == 1)

    h.call("ADDON_NS.Markers.Add('铁炉堡', 0.56, 0.49, '训练师')")
    check("second marker added", h.call("return #ADDON_NS.Markers.List()") == 2)

    m_api = h.call("local m = DanielAddonAPI.AddMarker('铁炉堡', 0.52, 0.44, 'API 测试'); return m")
    check("public API AddMarker", m_api is not None and h.call("return #ADDON_NS.Markers.List()") == 3, m_api)
    check("public API ListMarkers", h.call("return #DanielAddonAPI.ListMarkers()") == 3)

    removed = h.call(f"return ADDON_NS.Markers.Remove({m['id']})")
    check("remove by id", removed is not None and h.call("return #ADDON_NS.Markers.List()") == 2)

    n = h.call("return ADDON_NS.Markers.Clear()")
    check("clear count", n == 2 and h.call("return #ADDON_NS.Markers.List()") == 0)


@run("marker: map position same map / parent map")
def test_marker_map_position():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.execute("CONTINENT_OF[87] = 2")
    h.fire_addon_loaded()
    m = h.call("local m = ADDON_NS.Markers.Add('铁炉堡', 0.55, 0.48, '武器大师'); return m")

    x, y = h.call(f"return ADDON_NS.MarkerCore.MapPositionOf(ADDON_NS.Markers.Find({m['id']}), 87)")
    check("same map position", approx(x, 0.55) and approx(y, 0.48), (x, y))

    x, y = h.call(f"return ADDON_NS.MarkerCore.MapPositionOf(ADDON_NS.Markers.Find({m['id']}), 2)")
    check("parent map conversion", approx(x, 0.55) and approx(y, 0.48), (x, y))

    r = h.call(f"return ADDON_NS.MarkerCore.MapPositionOf(ADDON_NS.Markers.Find({m['id']}), 1)")
    check("unrelated map hidden", r is None, r)


@run("marker: minimap math and rotation")
def test_marker_math():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])

    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, 0,50, 100, 50,50, true, false, nil)")
    check("north is up", approx(r[0], 0) and approx(r[1], 25) and approx(r[2], 50) and r[3] is False, r)

    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, -50,0, 100, 50,50, true, false, nil)")
    check("east is right (world x is west-positive)", approx(r[0], 25) and approx(r[1], 0), r)
    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, 50,0, 100, 50,50, true, false, nil)")
    check("west is left", approx(r[0], -25) and approx(r[1], 0), r)

    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, 0,200, 100, 50,50, true, false, nil)")
    check("far marker clamps to edge", r[3] is True and approx(r[1], 50), r)

    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, 0,50, 100, 50,50, true, true, math.pi/2)")
    check("rotating minimap: north goes left", approx(r[0], -25) and approx(r[1], 0), r)

    # world y 向南时，北边的点世界 y 更小，屏幕仍应在上方
    r = h.call("return ADDON_NS.MarkerMath.Project(0,0, 0,-50, 100, 50,50, false, false, nil)")
    check("south-positive world still north-up", approx(r[1], 25), r)

    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)}, world_y_north=True)
    check("orientation detects north-positive", h.call("return ADDON_NS.MarkerMath.WorldYIncreasesNorth(87)") is True)
    h2 = Harness()
    h2.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h2.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)}, world_y_north=False)
    check("orientation detects south-positive", h2.call("return ADDON_NS.MarkerMath.WorldYIncreasesNorth(87)") is False)


# ---------------------------------------------------------------- log
@run("log: session entry, ring buffer, sanitize, dump")
def test_log():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.fire_addon_loaded()

    check("session.start logged", h.call(
        "for _, e in ipairs(ADDON_NS.db.logs) do if e.e == 'session.start' then return true end end return false"
    ) is True)

    h.execute("ADDON_NS.Log('unit.test', { a = 1, b = 'x' })")
    last = h.call("return ADDON_NS.db.logs[#ADDON_NS.db.logs].e")
    check("custom event logged", last == "unit.test", last)

    h.execute("local t = {}; t.self = t; ADDON_NS.Log('cycle', t)")
    check("cycle sanitized", h.call("return type(ADDON_NS.db.logs[#ADDON_NS.db.logs].d.self)") == "string")

    h.execute("for i = 1, 500 do ADDON_NS.Log('spam', { i = i }) end")
    check("ring buffer caps at 400", h.call("return #ADDON_NS.db.logs") == 400)

    h.execute("CHAT = {}; ADDON_NS.Log.Dump(3)")
    check("dump writes chat", h.call("return #CHAT") >= 4, h.call("return #CHAT"))

    h.execute("ADDON_NS.Log.Clear()")
    check("clear empties", h.call("return #ADDON_NS.db.logs") == 0)


# ---------------------------------------------------------------- upgrade regression
def _install_upgrade_scene(h):
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Upgrade.lua"])
    h.fire_addon_loaded()
    h.execute(
        """
        ITEM_DB = {
          [1000] = { name="旧头盔", ilvl=10, quality=3, reqLevel=1, equipLoc="INVTYPE_HEAD", classID=4, subclassID=5, slot=1 },
          [2000] = { name="新头盔", ilvl=20, quality=3, reqLevel=1, equipLoc="INVTYPE_HEAD", classID=4, subclassID=5, slot=1 },
          [2100] = { name="BoE 新胸甲", ilvl=40, quality=4, reqLevel=1, equipLoc="INVTYPE_CHEST", classID=4, subclassID=4, slot=5, bind=2 },
          [1001] = { name="旧胸甲", ilvl=10, quality=3, reqLevel=1, equipLoc="INVTYPE_CHEST", classID=4, subclassID=4, slot=5 },
        }
        EQUIP = { [1] = 1000, [5] = 1001 }
        SetBag(0, {})
        SetBag(1, {})
        """
    )
    return h


@run("upgrade: auto equip / BoE skip / blacklist")
def test_upgrade():
    h = _install_upgrade_scene(Harness())
    h.execute("SetBag(0, { [1] = { itemID = 2000 } })")
    check("upgrade detected", h.call("return #ADDON_NS.GetUpgrades()") == 1)

    h.execute("ADDON_NS.db.autoEquip = true; ADDON_NS.EquipUpgrades(true); Advance(2)")
    check("auto equip applied", h.call("return EQUIP[1]") == 2000, h.call("return EQUIP[1]"))

    # BoE：自动跳过，手动照换
    h.execute("SetBag(0, { [1] = { itemID = 2100 } }); CHAT = {}")
    h.execute("ADDON_NS.EquipUpgrades(true); Advance(2)")
    check("BoE auto skipped", h.call("return EQUIP[5]") == 1001, h.call("return EQUIP[5]"))
    check("BoE skip logged", h.call(
        "for _, e in ipairs(ADDON_NS.db.logs) do if e.e == 'equip.skip_boe' then return true end end return false"
    ) is True)

    h.execute("ADDON_NS.EquipUpgrades(false); Advance(2)")
    check("BoE manual equips", h.call("return EQUIP[5]") == 2100, h.call("return EQUIP[5]"))

    # 黑名单
    h.execute("EQUIP[1] = 1000; SetBag(0, { [1] = { itemID = 2000 } }); ADDON_NS.db.blacklist[2000] = true")
    check("blacklist hides upgrade", h.call("return #ADDON_NS.GetUpgrades()") == 0)


# ---------------------------------------------------------------- command + UI smoke
@run("ui: slash command mark / markbatch / clear and minimap refresh")
def test_commands():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "UI.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.execute("CONTINENT_OF[87] = 2")
    h.fire_addon_loaded()

    h.lua("SlashCmdList['DANIELADDON']('mark 铁炉堡|55.2|47.8|武器大师')")
    check("slash mark adds", h.call("return #ADDON_NS.Markers.List()") == 1)
    h.lua("SlashCmdList['DANIELADDON']('markbatch 铁炉堡|56|49|训练师;铁炉堡|57|50|旅店老板')")
    check("slash markbatch adds", h.call("return #ADDON_NS.Markers.List()") == 3)

    ok = h.call("return pcall(ADDON_NS.MarkersUI.RefreshMinimap)")
    check("minimap refresh smoke", ok is True, ok)
    ok = h.call("return pcall(ADDON_NS.MarkersUI.RefreshWorld)")
    check("world map refresh smoke", ok is True, ok)

    h.lua("SlashCmdList['DANIELADDON']('mark clear')")
    check("slash mark clear", h.call("return #ADDON_NS.Markers.List()") == 0)


@run("diag: writes an entry without errors")
def test_diag():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()
    h.call("return ADDON_NS.Log.Diag()")
    found = h.call("for _, e in ipairs(ADDON_NS.db.logs) do if e.e == 'diag' then return true end end return false")
    check("diag logged", found is True)


# ---------------------------------------------------------------- fixtures
@run("fixture: SavedVariables -> JSON conversion")
def test_fixture():
    sys.path.insert(0, os.path.join(ADDON_DIR, "tools"))
    import log_to_fixture

    sample = os.path.join(ADDON_DIR, "tests", "fixtures", "sample-DanielAddon.lua")
    db = log_to_fixture.load_db(sample)
    check("fixture markers parsed", len(db.get("markers", [])) == 1, db.get("markers"))
    m = db["markers"][0]
    check("fixture marker fields", m["zoneName"] == "铁炉堡" and approx(m["x"], 0.552), m)
    check("fixture logs parsed", len(db.get("logs", [])) == 2, db.get("logs"))


# ---------------------------------------------------------------- tools
@run("tools: agent_mark encode/split and watcher JSON")
def test_tools():
    import contextlib
    import io
    import json
    import tempfile

    sys.path.insert(0, os.path.join(ADDON_DIR, "tools"))
    import agent_mark
    import agent_mark_watch

    markers = [
        {"zone": "铁炉堡", "x": 50 + i, "y": 48, "label": f"武器大师{i}"}
        for i in range(15)
    ]
    lines = agent_mark.encode(markers)
    check("agent_mark splits long batch", len(lines) >= 2, len(lines))
    check("agent_mark bytes under limit", all(len(l.encode("utf-8")) <= 240 for l in lines),
          [len(l.encode("utf-8")) for l in lines])
    joined = ";".join(lines)
    check("agent_mark keeps all markers", joined.count("武器大师") == 15, joined.count("武器大师"))

    try:
        agent_mark.marker_from_pair("bad")
        invalid = False
    except SystemExit:
        invalid = True
    check("agent_mark rejects bad marker", invalid)

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump({"markers": [{"zone": "铁炉堡", "x": 55.2, "y": 47.8, "label": "测试"}]}, f,
                  ensure_ascii=False)
        path = f.name
    try:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            produced = agent_mark_watch.process(path, False, "World of Warcraft", copy=False)
        check("watcher produces markbatch", len(produced) == 1 and "markbatch" in produced[0], produced)
        check("watcher output printed", "markbatch" in out.getvalue(), out.getvalue())
    finally:
        os.unlink(path)


@run("fixture: replay SavedVariables marker in the Lua harness")
def test_fixture_replay():
    sys.path.insert(0, os.path.join(ADDON_DIR, "tools"))
    import log_to_fixture

    sample = os.path.join(ADDON_DIR, "tests", "fixtures", "sample-DanielAddon.lua")
    db = log_to_fixture.load_db(sample)
    marker = db["markers"][0]

    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.execute("CONTINENT_OF[87] = 2")
    h.fire_addon_loaded()
    h.L.globals()["fixture_marker"] = marker
    h.execute("ADDON_NS.db.markers = { fixture_marker }")

    x, y = h.call("return ADDON_NS.MarkerCore.MapPositionOf(fixture_marker, 87)")
    check("fixture replay map pos", approx(x, marker["x"]) and approx(y, marker["y"]), (x, y))

    pw = h.call("return ADDON_NS.MarkerCore.PlayerWorld()")
    px, py = pw[2], pw[3]
    r = h.call("return ADDON_NS.MarkerMath.Project(" + f"{px},{py}, {marker['wx']},{marker['wy']}, 100, 70,70, true, false, nil" + ")")
    expected = ((marker["wx"] - px) ** 2 + (marker["wy"] - py) ** 2) ** 0.5
    check("fixture replay distance", approx(r[2], expected, 1e-6), (r[2], expected))


@run("load: all TOC files load and handle core events")
def test_full_load():
    h = Harness()
    files = [
        "Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua",
        "Sell.lua", "Ammo.lua", "Repair.lua", "Sort.lua", "Upgrade.lua", "Highlight.lua",
        "Range.lua", "UI.lua",
    ]
    h.load_addon(files)
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()
    h.lua("""
      for _, f in ipairs(GLOBAL_FRAMES) do
        if f.events then
          if f.events.PLAYER_LOGIN then f:Fire("PLAYER_LOGIN") end
          if f.events.PLAYER_ENTERING_WORLD then f:Fire("PLAYER_ENTERING_WORLD") end
          if f.events.WORLD_MAP_OPEN then f:Fire("WORLD_MAP_OPEN") end
          if f.events.BAG_UPDATE then f:Fire("BAG_UPDATE", 0) end
        end
      end
    """)
    h.call("return Advance(3)")
    check("full load survived", True)


# ---------------------------------------------------------------- state export
@run("state: build quest JSON, chunk via self-whisper, reassemble")
def test_state():
    import json as pyjson

    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()
    h.execute("""
      QUEST_LOG = {
        [1] = { questID = 123, title = "测试任务", level = 10, isHeader = false,
                isOnMap = true, tag = "Dungeon", complete = false },
      }
      QUEST_OBJECTIVES = {
        [123] = { { text = "击杀 5 只狼", finished = false, numFulfilled = 2, numRequired = 5 } },
      }
      QUEST_NEXT = { [123] = { map = 87, x = 0.60, y = 0.50 } }
      SENT_CHAT = {}
    """)

    raw = h.call("return ADDON_NS.State.Json(ADDON_NS.State.Build())")
    state = pyjson.loads(raw)
    check("state zone", state["zone"] == "铁炉堡", state.get("zone"))
    check("state player", approx(state["player"]["x"], 0.5), state.get("player"))
    check("state quest count", len(state["quests"]) == 1, state.get("quests"))
    q = state["quests"][0]
    check("state quest id/title", q["id"] == 123 and q["title"] == "测试任务", q)
    check("state quest next", q["next"]["map"] == 87 and approx(q["next"]["x"], 0.6), q.get("next"))
    check("state objective", q["objectives"][0]["text"] == "击杀 5 只狼" and q["objectives"][0]["n"] == 2,
          q.get("objectives"))
    escaped = h.call("return ADDON_NS.State.Json({ x = 'a\\nb\\tc\\1' })")
    check("json escapes control chars", "\\n" in escaped and "\\t" in escaped and "\\u0001" in escaped, escaped)

    h.call("ADDON_NS.State.SendNow('test'); return Advance(6)")
    sent = h.call("return #SENT_CHAT")
    check("state sent chunks", sent >= 1, sent)
    msgs = [h.call(f"return SENT_CHAT[{i}].msg") for i in range(1, sent + 1)]
    check("state chat messages under 255 bytes", all(len(m.encode("utf-8")) <= 255 for m in msgs),
          [len(m.encode("utf-8")) for m in msgs])
    check("state all chunks prefixed", all(m.startswith("DANIEL1:") for m in msgs), msgs[:1])

    sys.path.insert(0, os.path.join(ADDON_DIR, "tools"))
    import state_reader
    parsed = state_reader.reassemble(state_reader.parse_text("\n".join(msgs)))
    check("state reassembled", parsed is not None, parsed)
    check("state reassembled quest", parsed["quests"][0]["id"] == 123, parsed and parsed.get("quests"))


# ---------------------------------------------------------------- deep runtime
@run("runtime: world map + minimap pins create and refresh")
def test_map_pins_runtime():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.execute("CONTINENT_OF[87] = 2")
    h.execute("""
      WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
      local canvas = CreateFrame("Frame", nil, WorldMapFrame)
      canvas.width = 1000; canvas.height = 800
      function WorldMapFrame:GetCanvas() return canvas end
      function WorldMapFrame:GetMapID() return CURRENT_MAP_ID end
      function WorldMapFrame:IsShown() return true end
    """)
    h.fire_addon_loaded()
    h.call("local m = ADDON_NS.Markers.Add('铁炉堡', 0.55, 0.48, '武器大师'); return m")
    ok = h.call("return pcall(ADDON_NS.MarkersUI.Refresh)")
    check("world/minimap refresh no error", ok is True, ok)
    check("world map pin created", h.call("return #WorldMapFrame:GetCanvas():GetChildren() > 0") is True,
          h.call("return #WorldMapFrame:GetCanvas():GetChildren()"))
    ok = h.call("return pcall(function() ADDON_NS.MarkersUI.ScheduleRefresh(0); Advance(1) end)")
    check("scheduled pin refresh no error", ok is True, ok)
    check("minimap pin created", h.call("return #Minimap:GetChildren() > 0") is True,
          h.call("return #Minimap:GetChildren()"))

    # 玩家 0.5/0.5，标记 0.55/0.48：应显示在右上（x>0, y<0）
    h.execute("ADDON_NS.Markers.Clear(); ADDON_NS.Markers.Add('铁炉堡', 0.55, 0.48, 'east-north')")
    h.call("ADDON_NS.MarkersUI.RefreshMinimap()")
    r = h.call("""
      local children = Minimap:GetChildren()
      for _, pin in ipairs(children) do
        if pin.points and #pin.points > 0 then
          local p = pin.points[#pin.points]
          return p.x or 0, p.y or 0
        end
      end
      return 0, 0
    """)
    check("minimap direction east/north", r[0] > 1 and r[1] > 1, r)


@run("runtime: highlight overlay shows and hides on fake bag button")
def test_highlight_runtime():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Upgrade.lua", "Highlight.lua"])
    h.fire_addon_loaded()
    h.execute("""
      ITEM_DB = {
        [1000] = { name="旧头盔", ilvl=10, quality=3, reqLevel=1, equipLoc="INVTYPE_HEAD", classID=4, subclassID=5, slot=1 },
        [2000] = { name="新头盔", ilvl=20, quality=3, reqLevel=1, equipLoc="INVTYPE_HEAD", classID=4, subclassID=5, slot=1 },
      }
      EQUIP = { [1] = 1000 }
      SetBag(0, { [1] = { itemID = 2000 } })
      local cf = CreateFrame("Frame", "FakeContainer", UIParent)
      cf.shown = true
      local b = CreateFrame("Frame", nil, cf)
      b:SetBagID(0); b:SetID(1)
      cf.EnumerateValidItems = function(self)
        local i = 0
        return function()
          i = i + 1
          if i == 1 then return i, b end
        end
      end
      ContainerFrames = { cf }
      FAKE_BUTTON = b
    """)
    ok = h.call("return pcall(ADDON_NS.RefreshHighlights)")
    check("highlight refresh no error", ok is True, ok)
    check("highlight shown", h.call("return FAKE_BUTTON.DanielUpgradeGlow ~= nil and FAKE_BUTTON.DanielUpgradeGlow.shown == true") is True)
    h.execute("SetBag(0, {})")
    h.call("return ADDON_NS.RefreshHighlights()")
    check("highlight hidden after item gone", h.call("return FAKE_BUTTON.DanielUpgradeGlow.shown == false") is True)


@run("runtime: panel, all slash commands, range widget")
def test_ui_runtime():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua",
                  "Sell.lua", "Ammo.lua", "Repair.lua", "Sort.lua", "Upgrade.lua", "Highlight.lua", "UI.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0),
                    1426: ("丹莫罗", 3, 2)})
    h.fire_addon_loaded()

    ok = h.call("return pcall(SlashCmdList['DANIELADDON'], '')")
    check("panel toggle creates frame", ok is True and h.call("return DanielAddonPanel ~= nil") is True, ok)
    ok = h.call("return pcall(SlashCmdList['DANIELADDON'], '')")
    check("panel toggle hides", ok is True)

    h.execute("ADDON_NS.Markers.Clear()")
    h.call("SlashCmdList['DANIELADDON']('pet')")
    check("pet presets add 2", h.call("return #ADDON_NS.Markers.List()") == 2,
          h.call("return #ADDON_NS.Markers.List()"))
    h.execute("ADDON_NS.Markers.Clear()")
    h.call("SlashCmdList['DANIELADDON']('pet bjarn')")
    check("pet bjarn adds 1", h.call("return #ADDON_NS.Markers.List()") == 1)
    h.execute("ADDON_NS.Markers.Clear()")
    ok = h.call("return pcall(SlashCmdList['DANIELSORTDEBUG'])")
    check("sortdebug no-space alias", ok is True)
    h.call("SlashCmdList['DANIELPET']('')")
    check("danielpet no-space alias adds 2", h.call("return #ADDON_NS.Markers.List()") == 2)
    h.call("SlashCmdList['DANIELRMBEAR']()")
    check("rmbear removes only bear", h.call("return #ADDON_NS.Markers.List()") == 1
          and h.call("return ADDON_NS.Markers.List()[1].label") == "Mangeclaw Lv11 Rare",
          h.call("return ADDON_NS.Markers.List()[1] and ADDON_NS.Markers.List()[1].label"))
    h.call("SlashCmdList['DANIELRMMANG']()")
    check("rmmang clears remaining", h.call("return #ADDON_NS.Markers.List()") == 0)
    h.execute("ADDON_NS.Markers.Clear()")

    for cmd in ["status", "value", "sortdebug", "bagrole", "bagrole off", "bagrole on", "repair", "repair", "junk", "junk 自定义", "unjunk 自定义", "upgrade", "mark list", "mark clear",
                "mapfind 铁炉", "quests", "state", "state probe", "state names",
                "state name Shorty Ranger", "state reset", "questmark all", "diag",
                "log dump 3"]:
        ok = h.call(f"return pcall(SlashCmdList['DANIELADDON'], {json.dumps(cmd, ensure_ascii=False)})")
        check(f"slash command: {cmd}", ok is True, ok)


@run("state: long multi-chunk payload keeps 20 quests and UTF-8 intact")
def test_state_long_payload():
    import json as pyjson

    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()
    h.execute("""
      QUEST_LOG = {}
      QUEST_OBJECTIVES = {}
      QUEST_NEXT = {}
      for i = 1, 20 do
        QUEST_LOG[i] = { questID = 1000 + i, title = "一个很长很长的中文任务标题" .. i,
                         level = 10, isHeader = false, isOnMap = true, tag = "Dungeon" }
        QUEST_OBJECTIVES[1000 + i] = {
          { text = "收集十个很长的中文任务目标物品" .. i, finished = false, numFulfilled = 3, numRequired = 10 },
        }
        QUEST_NEXT[1000 + i] = { map = 87, x = 0.5 + i / 1000, y = 0.5 }
      end
      SENT_CHAT = {}
    """)
    h.call("ADDON_NS.State.SendNow('long'); return Advance(30)")
    sent = h.call("return #SENT_CHAT")
    check("long state splits into multiple chunks", sent > 1, sent)
    msgs = [h.call(f"return SENT_CHAT[{i}].msg") for i in range(1, sent + 1)]
    check("long state chunks under 255 bytes", all(len(m.encode("utf-8")) <= 255 for m in msgs),
          [len(m.encode("utf-8")) for m in msgs])
    sys.path.insert(0, os.path.join(ADDON_DIR, "tools"))
    import state_reader
    state = state_reader.reassemble(state_reader.parse_text("\n".join(msgs)))
    check("long state reassembles", state is not None, state)
    check("long state keeps 20 quests", len(state["quests"]) == 20, len(state.get("quests", [])))
    check("long state keeps title", state["quests"][19]["title"].startswith("一个很长"), state["quests"][19]["title"])


@run("state: instance skip and chat-send failure fallback")
def test_state_failures():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()

    h.execute("SENT_CHAT = {}; IsInInstance = function() return true, 'party' end")
    h.call("ADDON_NS.State.SendNow('instance'); return Advance(3)")
    check("instance sends no whisper", h.call("return #SENT_CHAT") == 0, h.call("return #SENT_CHAT"))
    check("instance skip logged", h.call(
        "for _, e in ipairs(ADDON_NS.db.logs) do if e.e == 'state.skip_instance' then return true end end return false"
    ) is True)

    h.execute("""
      IsInInstance = function() return false end
      SendChatMessage = function() error("blocked") end
      CHAT = {}
      SENT_CHAT = {}
    """)
    h.call("ADDON_NS.State.SendNow('fallback'); return Advance(10)")
    check("chat failure falls back to local chat", h.call("return #CHAT") >= 1, h.call("return #CHAT"))


@run("state: whisper target fallback and channel mode")
def test_state_targets():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()

    cands = h.call("return ADDON_NS.State.Candidates()")
    check("candidates include full name", "Shorty Ranger" in list(cands.values()), cands)

    h.execute("SENT_CHAT = {}; ADDON_NS.State.SetWhisperName('Custom Name')")
    h.call("ADDON_NS.State.SendNow('target'); return Advance(2)")
    check("manual whisper name used", h.call("return SENT_CHAT[1].target") == "Custom Name",
          h.call("return SENT_CHAT[1].target"))

    # 系统提示目标不存在 -> 自动换下一个候选
    h.execute("SENT_CHAT = {}")
    h.call("""
      for _, f in ipairs(GLOBAL_FRAMES) do
        if f.events and f.events.CHAT_MSG_SYSTEM then
          f:Fire("CHAT_MSG_SYSTEM", "未找到名为“Custom Name”的在线玩家。")
        end
      end
      return Advance(2)
    """)
    check("target fallback after system error", h.call("return SENT_CHAT[1].target") == "Shorty Ranger",
          h.call("return SENT_CHAT[1].target"))
    check("target failure logged", h.call(
        "for _, e in ipairs(ADDON_NS.db.logs) do if e.e == 'state.target_fail' then return true end end return false"
    ) is True)

    # 所有候选都失败 -> 私有频道
    h.execute("ADDON_NS.State.SetWhisperName('Bad'); SENT_CHAT = {}")
    for _ in range(5):
        h.call("""
          for _, f in ipairs(GLOBAL_FRAMES) do
            if f.events and f.events.CHAT_MSG_SYSTEM then
              f:Fire("CHAT_MSG_SYSTEM", "未找到名为“Bad”的在线玩家。")
            end
          end
          return Advance(2)
        """)
    check("falls back to private channel", h.call(
        "for _, m in ipairs(SENT_CHAT) do if m.chatType == 'CHANNEL' then return true end end return false"
    ) is True, h.call("local out='' for _,m in ipairs(SENT_CHAT) do out=out..m.chatType..',' end return out"))
    check("channel joined", h.call("return #JOINED_CHANNELS > 0") is True)


@run("state: quest POI fallback when GetNextWaypoint is empty")
def test_state_poi():
    import json as pyjson

    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.install_maps({87: ("铁炉堡", 3, 2), 2: ("Eastern Kingdoms", 2, 0)})
    h.fire_addon_loaded()
    h.execute("""
      QUEST_LOG = {
        [1] = { questID = 777, title = "POI 任务", level = 8, isHeader = false, isOnMap = true },
      }
      QUEST_OBJECTIVES = { [777] = { { text = "去某处", finished = false, numFulfilled = 0, numRequired = 1 } } }
      QUEST_NEXT = {}
      QUEST_POIS = {
        [87] = { { questID = 777, mapID = 87, x = 0.62, y = 0.52,
                   inProgress = true, isQuestStart = false } },
      }
      SENT_CHAT = {}
    """)
    state = pyjson.loads(h.call("return ADDON_NS.State.Json(ADDON_NS.State.Build())"))
    q = state["quests"][0]
    check("POI fills next", q.get("next", {}).get("map") == 87, q.get("next"))
    check("POI coords", approx(q.get("next", {}).get("x"), 0.62), q.get("next"))
    n = h.call("return ADDON_NS.State.MarkQuestNext(777)")
    check("questmark uses POI", n == 1 and h.call("return #ADDON_NS.Markers.List()") == 1,
          (n, h.call("return #ADDON_NS.Markers.List()")))
    state2 = pyjson.loads(h.call("return ADDON_NS.State.Json(ADDON_NS.State.Build())"))
    check("state includes markers", len(state2.get("markers") or []) == 1
          and state2["markers"][0]["map"] == 87, state2.get("markers"))


@run("state: DANIEL1 whisper is hidden in chat but still sent")
def test_state_chat_filter():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Markers.lua", "State.lua"])
    h.fire_addon_loaded()

    def filter_result(msg):
        return h.call(f"""
          for _, f in ipairs(CHAT_FILTERS) do
            if f.event == 'CHAT_MSG_WHISPER' then return f.fn(nil, 'CHAT_MSG_WHISPER', {json.dumps(msg, ensure_ascii=False)}) end
          end
          return false
        """)

    check("DANIEL1 hidden", filter_result("DANIEL1:abc:1/1:{}") is True)
    check("normal whisper shown", filter_result("hello") is False)

    h.execute("ADDON_NS.State.SetHideChat(false)")
    check("filter can be disabled", filter_result("DANIEL1:abc:1/1:{}") is False)
    h.execute("ADDON_NS.State.SetHideChat(true)")
    check("filter re-enabled", filter_result("DANIEL1:abc:1/1:{}") is True)


@run("sort: auto sort when a bag opens")
def test_sort_on_open():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("""
      SORT_CALLS = {}
      ADDON_NS.SortByValue = function(auto, silent)
        SORT_CALLS[#SORT_CALLS + 1] = { auto = auto, silent = silent }
      end
      function fire_bag_open(bagID)
        for _, f in ipairs(GLOBAL_FRAMES) do
          if f.events and f.events.BAG_OPEN then f:Fire("BAG_OPEN", bagID or 0) end
        end
      end
    """)

    h.call("fire_bag_open(0); return Advance(1)")
    check("bag open sorts once", h.call("return #SORT_CALLS") == 1, h.call("return #SORT_CALLS"))
    check("bag open sort is silent", h.call("return SORT_CALLS[1].silent") is True,
          h.call("return SORT_CALLS[1].auto, SORT_CALLS[1].silent"))

    h.execute("ADDON_NS.db.sortOnOpen = false; SORT_CALLS = {}")
    h.call("fire_bag_open(0); return Advance(1)")
    check("bag open sort disabled", h.call("return #SORT_CALLS") == 0)

    h.execute("ADDON_NS.db.sortOnOpen = true; SORT_CALLS = {}; InCombatLockdown = function() return true end")
    h.call("fire_bag_open(0); return Advance(1)")
    check("no sort in combat", h.call("return #SORT_CALLS") == 0)
    h.execute("InCombatLockdown = function() return false end")
    h.call("""
      for _, f in ipairs(GLOBAL_FRAMES) do
        if f.events and f.events.PLAYER_REGEN_ENABLED then f:Fire("PLAYER_REGEN_ENABLED") end
      end
      return Advance(1)
    """)
    check("pending sort runs after combat", h.call("return #SORT_CALLS") >= 1,
          h.call("return #SORT_CALLS"))

    h.execute("ADDON_NS.db.sortOnOpen = true; SORT_CALLS = {}")
    h.call("fire_bag_open(1); fire_bag_open(2); return Advance(1)")
    check("rapid opens debounce to one sort", h.call("return #SORT_CALLS") == 1,
          h.call("return #SORT_CALLS"))


@run("sort: category order (quest > upgrade/equip > consumable > material > junk)")
def test_sort_category():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Upgrade.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [9000] = { name="垃圾", quality=0, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9001] = { name="材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9002] = { name="药水", quality=1, ilvl=1, classID=0, subclassID=0, equipLoc="" },
        [9003] = { name="胸甲", quality=3, ilvl=20, classID=4, subclassID=4, equipLoc="INVTYPE_CHEST" },
        [9004] = { name="任务物品", quality=1, ilvl=1, classID=12, subclassID=0, equipLoc="" },
        [9005] = { name="更强胸甲", quality=4, ilvl=100, classID=4, subclassID=4, equipLoc="INVTYPE_CHEST" },
      }
      PRICES = { [9000]=500, [9001]=10, [9002]=5, [9003]=1, [9004]=0, [9005]=1 }
      EQUIP = { [5] = 9005 }
      QUEST_INFO = { [1001] = { isQuestItem = true } }
      SetBag(0, { [1]={itemID=9000, quality=0}, [2]={itemID=9001}, [3]={itemID=9002},
                  [4]={itemID=9003} })
      SetBag(1, { [1]={itemID=9004} })
      CHAT = {}
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    order = h.call("return DumpBag(0) .. ' | ' .. DumpBag(1)")
    check("category order within each bag", order.startswith("9003 9002 9001 9000 | 9004"), order)

    # 旧的 sortByCategory=false 不再生效：仍然按类别，不按价格
    h.execute("""
      ADDON_NS.db.sortByCategory = false
      SetBag(0, { [1]={itemID=9000, quality=0}, [2]={itemID=9001}, [3]={itemID=9002},
                  [4]={itemID=9003} })
      SetBag(1, { [1]={itemID=9004} })
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    order2 = h.call("return DumpBag(0) .. ' | ' .. DumpBag(1)")
    check("category order always (price ignored)", order2.startswith("9003 9002 9001 9000 | 9004"), order2)


@run("sell: red unusable gear sold, ranged weapons and quest items kept")
def test_sell_red():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Upgrade.lua", "Sell.lua"])
    h.fire_addon_loaded()
    h.execute("""
      UnitLevel = function() return 11 end
      ITEM_DB = {
        [8000] = { name="灰色垃圾", quality=0, ilvl=1, reqLevel=1, classID=15, subclassID=0, equipLoc="" },
        [8001] = { name="红字板甲", quality=1, ilvl=40, reqLevel=40, classID=4, subclassID=4,
                   equipLoc="INVTYPE_CHEST", usable=false },
        [8002] = { name="红字弓", quality=2, ilvl=40, reqLevel=40, classID=2, subclassID=2,
                   equipLoc="INVTYPE_RANGED", usable=false },
        [8003] = { name="可用布甲", quality=2, ilvl=5, reqLevel=5, classID=4, subclassID=1,
                   equipLoc="INVTYPE_CHEST", usable=true },
        [8004] = { name="任务板甲", quality=2, ilvl=40, reqLevel=40, classID=4, subclassID=4,
                   equipLoc="INVTYPE_CHEST", usable=false },
        [8005] = { name="红字戒指", quality=2, ilvl=40, reqLevel=40, classID=4, subclassID=0,
                   equipLoc="INVTYPE_FINGER", usable=false },
        [8006] = { name="剥皮小刀", quality=1, ilvl=1, reqLevel=1, classID=2, subclassID=15,
                   subType="Miscellaneous", equipLoc="INVTYPE_WEAPON", usable=false },
        [8007] = { name="绿字板甲", quality=2, ilvl=40, reqLevel=40, classID=4, subclassID=4,
                   equipLoc="INVTYPE_CHEST", usable=false },
      }
      PRICES = { [8000]=1, [8001]=100, [8002]=100, [8003]=100, [8004]=100 }
      QUEST_INFO = { [1001] = { isQuestItem = true } }
      EQUIPPED_ITEMS = { [5] = 8003 }
      SetBag(0, { [1]={itemID=8000, quality=0}, [2]={itemID=8001}, [3]={itemID=8002},
                  [4]={itemID=8003} })
      SetBag(1, { [1]={itemID=8004}, [2]={itemID=8005}, [3]={itemID=8006}, [4]={itemID=8007, quality=2} })
    """)
    checks = [
        ("gray junk", 0, 1, True),
        ("red plate", 0, 2, True),
        ("red ranged kept", 0, 3, False),
        ("usable gear kept", 0, 4, False),
        ("quest item kept", 1, 1, False),
        ("ring kept", 1, 2, False),
        ("skinning knife kept", 1, 3, False),
        ("green red gear kept", 1, 4, False),
    ]
    for name, bag, slot, want in checks:
        got = h.call(f"return ADDON_NS.IsSellableJunk({bag}, {slot})")
        check("sell " + name, got is want, (got, want))

    # 对应槽位空着 -> 留着（先检查装备）
    h.execute("EQUIPPED_ITEMS = {}")
    check("empty chest slot keeps red plate", h.call("return ADDON_NS.IsSellableJunk(0, 2)") is False)

    h.execute("EQUIPPED_ITEMS = { [5] = 8003 }; ADDON_NS.db.sellUnusable = false")
    check("red off keeps red", h.call("return ADDON_NS.IsSellableJunk(0, 2)") is False)
    check("gray still sold", h.call("return ADDON_NS.IsSellableJunk(0, 1)") is True)


@run("ammo: hunter auto-restocks arrows/bullets at vendor")
def test_ammo():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Ammo.lua"])
    h.fire_addon_loaded()
    h.execute("""
      CURRENT_CLASS = "HUNTER"
      PLAYER_LEVEL = 11
      ITEM_DB = {
        [6000] = { name="训练弓", quality=2, ilvl=10, reqLevel=5, classID=2, subclassID=2,
                   subType="Bow", equipLoc="INVTYPE_RANGED" },
        [6001] = { name="轻箭", quality=1, ilvl=1, reqLevel=1, classID=6, subclassID=2,
                   subType="箭", equipLoc="INVTYPE_AMMO" },
        [6002] = { name="粗糙箭", quality=1, ilvl=1, reqLevel=1, classID=6, subclassID=2,
                   subType="Arrow", equipLoc="INVTYPE_AMMO" },
        [6003] = { name="训练枪", quality=2, ilvl=10, reqLevel=5, classID=2, subclassID=3,
                   subType="Gun", equipLoc="INVTYPE_RANGED" },
        [6004] = { name="轻弹", quality=1, ilvl=1, reqLevel=1, classID=6, subclassID=3,
                   subType="子弹", equipLoc="INVTYPE_AMMO" },
        [6005] = { name="训练弩", quality=2, ilvl=10, reqLevel=5, classID=2, subclassID=18,
                   subType="弩", equipLoc="INVTYPE_RANGED" },
      }
      PRICES = {}
      EQUIPPED_ITEMS = { [18] = 6000 }
      EQUIPPED_COUNTS = {}
      SetBag(0, { [1]={itemID=6001, count=200} })
      SetBag(1, {})
      MERCHANT_ITEMS = {
        { name="轻箭", itemID=6001, price=100, stack=200, avail=-1 },
        { name="粗糙箭", itemID=6002, price=50, stack=200, avail=-1 },
      }
      MONEY = 10000
      BUYS = {}
      ADDON_NS.db.ammoAutoBuy = true
      ADDON_NS.db.ammoTarget = 1000
      ADDON_NS.merchantAmmoDone = nil
    """)
    check("ammo kind", h.call("return (ADDON_NS.Ammo.RangedKind())") == "Arrow")
    check("preferred picks carried ammo", h.call("return ADDON_NS.Ammo.Preferred('Arrow')") == 6001)
    h.call("return ADDON_NS.Ammo.Restock()")
    check("buys missing arrows", h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n") == 800,
          h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n"))
    check("exact preferred item", h.call("return BUYS[1].itemID") == 6001)

    # 已经够了就不买
    h.execute("SetBag(0, { [1]={itemID=6001, count=1200} }); BUYS = {}; ADDON_NS.merchantAmmoDone = nil")
    h.call("return ADDON_NS.Ammo.Restock()")
    check("no buy when full", h.call("return #BUYS") == 0)

    # 强制买 1 叠：即使已经超过目标也买
    h.execute("BUYS = {}; ADDON_NS.merchantAmmoDone = nil")
    h.call("ADDON_NS.Ammo.Restock(1)")
    check("force buy one stack", h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n") == 200,
          h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n"))

    # 枪用子弹，没带弹药时买商人最便宜的同类
    h.execute("""
      EQUIPPED_ITEMS = { [18] = 6003 }
      SetBag(0, {}); SetBag(1, {})
      MERCHANT_ITEMS = { { name="轻弹", itemID=6004, price=80, stack=200, avail=-1 } }
      BUYS = {}; MONEY = 10000
      ADDON_NS.db.ammoTarget = 500
      ADDON_NS.merchantAmmoDone = nil
    """)
    h.execute("EQUIPPED_ITEMS = { [18] = 6005 }")
    check("crossbow uses arrows", h.call("return (ADDON_NS.Ammo.RangedKind())") == "Arrow")
    check("localized arrow detected", h.call("return ADDON_NS.Ammo.KindOf(6001)") == "Arrow")
    check("localized bullet detected", h.call("return ADDON_NS.Ammo.KindOf(6004)") == "Bullet")

    h.execute("EQUIPPED_ITEMS = { [18] = 6003 }")
    check("gun uses bullets", h.call("return (ADDON_NS.Ammo.RangedKind())") == "Bullet")
    h.call("return ADDON_NS.Ammo.Restock()")
    check("buys bullets", h.call("return BUYS[1] and BUYS[1].itemID") == 6004,
          h.call("return BUYS[1] and BUYS[1].itemID"))
    check("bullet quantity", h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n") >= 500)

    # 非猎人不买
    h.execute("CURRENT_CLASS = 'WARRIOR'; BUYS = {}; ADDON_NS.merchantAmmoDone = nil")
    h.call("return ADDON_NS.Ammo.Restock()")
    check("non-hunter no buy", h.call("return #BUYS") == 0)


@run("equip: green BoE auto-equips, epic BoE is protected")
def test_boe_quality():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "MarkerCore.lua", "Upgrade.lua"])
    h.fire_addon_loaded()
    h.execute("""
      CURRENT_CLASS = 'HUNTER'
      ITEM_DB = {
        [7300] = { name="旧胸甲", quality=2, ilvl=10, reqLevel=1, classID=4, subclassID=2,
                   equipLoc="INVTYPE_CHEST" },
        [7301] = { name="黑色熊皮外衣", quality=2, ilvl=14, reqLevel=9, classID=4, subclassID=2,
                   equipLoc="INVTYPE_CHEST", bind=2 },
        [7302] = { name="紫色绑定胸甲", quality=4, ilvl=30, reqLevel=9, classID=4, subclassID=2,
                   equipLoc="INVTYPE_CHEST", bind=2 },
      }
      PRICES = {}
      EQUIP = { [5] = 7300 }
      SetBag(0, { [1]={itemID=7301} })
      SetBag(1, {})
      ADDON_NS.db.autoEquip = true
      ADDON_NS.db.skipBoE = true
    """)
    h.call("ADDON_NS.EquipUpgrades(true); return Advance(2)")
    check("green BoE equipped", h.call("return EQUIP[5]") == 7301, h.call("return EQUIP[5]"))

    h.execute("""
      EQUIP = { [5] = 7300 }
      SetBag(0, { [1]={itemID=7302} })
      SetBag(1, {})
      ADDON_NS.equipFailures = 0
      ADDON_NS.merchantAmmoDone = nil
    """)
    h.call("ADDON_NS.EquipUpgrades(true); return Advance(2)")
    check("epic BoE kept", h.call("return EQUIP[5]") == 7300, h.call("return EQUIP[5]"))

    h.execute("""
      ITEM_DB[7303] = { name="评分更低的胸甲", quality=2, ilvl=9, reqLevel=1, classID=4, subclassID=2,
                        equipLoc="INVTYPE_CHEST" }
      SetBag(0, { [1]={itemID=7303} })
      EQUIP = { [5] = 7300 }
    """)
    check("force equip works", h.call("return (ADDON_NS.ForceEquipItem(7303))") is True
          and h.call("return EQUIP[5]") == 7303, h.call("return EQUIP[5]"))


@run("sort: no holes, duplicate stacks do not merge, repeat is stable")
def test_sort_gaps():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [9100] = { name="贵的材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9101] = { name="中等材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9102] = { name="便宜材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9200] = { name="同种材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="", maxStack=20 },
        [9201] = { name="另一种材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
      }
      PRICES = { [9100]=100, [9101]=50, [9102]=10, [9200]=5, [9201]=1 }
      -- 中间留洞：bag0 1/3，bag1 2
      SetBag(0, { [1]={itemID=9100}, [3]={itemID=9101} })
      SetBag(1, { [2]={itemID=9102} })
      CHAT = {}
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    check("no holes within bag", h.call("return DumpBag(0)") == "9100 9101 - -"
          and h.call("return DumpBag(1)") == "9102 - - -",
          (h.call("return DumpBag(0)"), h.call("return DumpBag(1)")))

    h.execute("""
      SetBag(0, { [1]={itemID=9200, count=5}, [3]={itemID=9200, count=3} })
      SetBag(1, { [2]={itemID=9201} })
      CHAT = {}
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    d0 = h.call("return DumpBag(0)")
    d1 = h.call("return DumpBag(1)")
    occupied = sum(1 for x in (d0 + " " + d1).split() if x != "-")
    total = h.call("local n=0 for b=0,4 do for s=1,4 do local i=BAGS[b][s]; if i then n=n+(i.count or 1) end end end return n")
    check("duplicate stacks not merged", occupied == 3 and total == 9, (d0, d1, occupied, total))
    check("duplicate layout has no hole", d0.split()[:2] == ["9200", "9200"]
          and d1.split()[0] == "9201", (d0, d1))

    before = (d0, d1)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    after = (h.call("return DumpBag(0)"), h.call("return DumpBag(1)"))
    check("sort is idempotent", before == after, (before, after))

    # 同种物品相邻且大小堆顺序相反：不能交换（客户端会合并）
    h.execute("""
      SetBag(0, { [1]={itemID=9200, count=3}, [2]={itemID=9200, count=5} })
      SetBag(1, {})
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    d0 = h.call("return DumpBag(0)")
    occupied = sum(1 for x in d0.split() if x != "-")
    total = h.call("local n=0 for s=1,4 do local i=BAGS[0][s]; if i then n=n+(i.count or 1) end end return n")
    check("adjacent identical stacks not merged", occupied == 2 and total == 8, (d0, occupied, total))


@run("sort: quiver/special bags are never used as sort targets")
def test_sort_special_bags():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [9300] = { name="普通材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9301] = { name="箭", quality=1, ilvl=1, classID=6, subclassID=2, equipLoc="INVTYPE_AMMO" },
        [9302] = { name="另一个", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
      }
      PRICES = { [9300]=100, [9301]=1, [9302]=50 }
      BAG_FAMILY[2] = 1      -- 箭袋
      BAG_FAMILY[3] = nil    -- API 返回 nil 的未知专用包
      SetBag(0, { [1]={itemID=9302}, [3]={itemID=9300} })
      SetBag(1, {})
      SetBag(2, { [1]={itemID=9301, count=200} })
      SetBag(3, { [1]={itemID=9301, count=200} })
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    check("quiver untouched", h.call("return DumpBag(2)") == "9301 - - -", h.call("return DumpBag(2)"))
    check("unknown bag untouched", h.call("return DumpBag(3)") == "9301 - - -", h.call("return DumpBag(3)"))
    check("normal bag sorted", h.call("return DumpBag(0)") == "9300 9302 - -", h.call("return DumpBag(0)"))


@run("repair: auto-repair at repair merchant, money and toggle paths")
def test_repair():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Repair.lua"])
    h.fire_addon_loaded()
    h.execute("""
      function fire_merchant_show()
        for _, f in ipairs(GLOBAL_FRAMES) do
          if f.events and f.events.MERCHANT_SHOW then f:Fire("MERCHANT_SHOW") end
        end
      end
      ADDON_NS.db.autoRepair = true
      REPAIR_CAN = true
      REPAIR_COST = 300
      MONEY = 1000
      REPAIR_CALLS = 0
      CHAT = {}
    """)
    h.call("fire_merchant_show()")
    check("repair called", h.call("return REPAIR_CALLS") == 1, h.call("return REPAIR_CALLS"))
    check("repair spent money", h.call("return MONEY") == 700, h.call("return MONEY"))

    h.execute("REPAIR_COST = 300; MONEY = 100; REPAIR_CALLS = 0; ADDON_NS.repairPending = false")
    h.call("fire_merchant_show()")
    check("no repair when broke", h.call("return REPAIR_CALLS") == 0)
    check("repair pending after broke", h.call("return ADDON_NS.repairPending") is True)

    h.execute("MONEY = 1000")
    h.call("ADDON_NS.Repair.Try(true)")
    check("retry after selling", h.call("return REPAIR_CALLS") == 1 and h.call("return MONEY") == 700,
          (h.call("return REPAIR_CALLS"), h.call("return MONEY")))

    h.execute("REPAIR_COST = 0; REPAIR_CALLS = 0")
    h.call("fire_merchant_show()")
    check("no repair when full durability", h.call("return REPAIR_CALLS") == 0)

    h.execute("ADDON_NS.db.autoRepair = false; REPAIR_COST = 100; REPAIR_CALLS = 0; MONEY = 1000")
    h.call("fire_merchant_show()")
    check("repair toggle off", h.call("return REPAIR_CALLS") == 0)


@run("sell: keyword junk (ruined leather) auto-sells, quest items stay")
def test_sell_keyword():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua"])
    h.fire_addon_loaded()
    h.execute("""
      ITEM_DB = {
        [9400] = { name="破烂的皮革", quality=1, ilvl=5, classID=7, subclassID=0, equipLoc="" },
        [9401] = { name="自定义杂物", quality=1, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9402] = { name="破烂的皮革", quality=1, ilvl=5, classID=12, subclassID=0, equipLoc="" },
        [9403] = { name="破烂的皮革", quality=2, ilvl=5, classID=7, subclassID=0, equipLoc="" },
      }
      PRICES = { [9400]=7, [9401]=1, [9402]=7 }
      QUEST_INFO = { [2] = { isQuestItem = true } }
      SetBag(0, { [1]={itemID=9400}, [2]={itemID=9402}, [3]={itemID=9403, quality=2} })
      SetBag(1, {})
      ADDON_NS.db.junkKeywords = { "破烂的皮革", "Ruined Leather Scraps" }
    """)
    check("ruined leather keyword sells", h.call("return ADDON_NS.IsSellableJunk(0, 1)") is True)
    check("quest item with keyword kept", h.call("return ADDON_NS.IsSellableJunk(0, 2)") is False)
    check("green keyword item kept", h.call("return ADDON_NS.IsSellableJunk(0, 3)") is False)

    h.execute("SetBag(0, { [1]={itemID=9401} })")
    check("custom keyword not yet", h.call("return ADDON_NS.IsSellableJunk(0, 1)") is False)
    h.call("table.insert(ADDON_NS.db.junkKeywords, '自定义杂物')")
    check("custom keyword sells", h.call("return ADDON_NS.IsSellableJunk(0, 1)") is True)
    h.call("for i=#ADDON_NS.db.junkKeywords,1,-1 do if ADDON_NS.db.junkKeywords[i]=='自定义杂物' then table.remove(ADDON_NS.db.junkKeywords,i) end end")
    check("unjunk stops sale", h.call("return ADDON_NS.IsSellableJunk(0, 1)") is False)


@run("sort: hearthstone is always first")
def test_sort_hearthstone():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [6948] = { name="炉石", quality=1, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9500] = { name="很贵的材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9501] = { name="普通材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
      }
      PRICES = { [6948]=0, [9500]=100, [9501]=50 }
      SetBag(0, { [1]={itemID=9500}, [2]={itemID=6948}, [3]={itemID=9501} })
      SetBag(1, {})
      ADDON_NS.db.sortByCategory = true
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    check("hearthstone first (category)", h.call("return DumpBag(0)") == "6948 9500 9501 -",
          h.call("return DumpBag(0)"))

    h.execute("""
      ADDON_NS.db.sortByCategory = false
      SetBag(0, { [1]={itemID=9500}, [2]={itemID=6948}, [3]={itemID=9501} })
      SetBag(1, {})
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    check("hearthstone first (value mode)", h.call("return DumpBag(0)") == "6948 9500 9501 -",
          h.call("return DumpBag(0)"))


@run("sell: auto-sell leaves no holes (sort runs after sale)")
def test_sort_after_sell():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [9600] = { name="灰色垃圾", quality=0, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9601] = { name="好装备", quality=2, ilvl=10, classID=4, subclassID=2, equipLoc="INVTYPE_CHEST" },
      }
      PRICES = { [9600]=10, [9601]=100 }
      SetBag(0, { [1]={itemID=9600, quality=0}, [3]={itemID=9601, quality=2} })
      SetBag(1, {})
      ADDON_NS.db.autoSell = true
      ADDON_NS.db.autoSort = true
      ADDON_NS.db.autoRepair = false
      ADDON_NS.db.ammoAutoBuy = false
    """)
    h.call("""
      for _, f in ipairs(GLOBAL_FRAMES) do
        if f.events and f.events.MERCHANT_SHOW then f:Fire("MERCHANT_SHOW") end
      end
      return Advance(5)
    """)
    check("junk sold and compacted", h.call("return DumpBag(0)") == "9601 - - -",
          h.call("return DumpBag(0)"))
    check("sold item recorded", h.call("return SOLD[1]") == 9600, h.call("return SOLD[1]"))


@run("upgrade: profession tools and red gear are not upgrades/highlighted")
def test_upgrade_filters():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "MarkerCore.lua", "Upgrade.lua"])
    h.fire_addon_loaded()
    h.execute("""
      CURRENT_CLASS = 'HUNTER'
      PLAYER_LEVEL = 13
      ITEM_DB = {
        [7005] = { name="剥皮小刀", quality=1, ilvl=1, reqLevel=1, classID=2, subclassID=15,
                   subType="Miscellaneous", equipLoc="INVTYPE_WEAPON" },
        [7100] = { name="红字胸甲", quality=2, ilvl=20, reqLevel=1, classID=4, subclassID=4,
                   equipLoc="INVTYPE_CHEST", usable=false },
        [7101] = { name="猎人胸甲", quality=2, ilvl=10, reqLevel=1, classID=4, subclassID=2,
                   equipLoc="INVTYPE_CHEST" },
        [7200] = { name="当前武器", quality=2, ilvl=30, reqLevel=1, classID=2, subclassID=2,
                   equipLoc="INVTYPE_WEAPON" },
      }
      EQUIP = { [16] = 7200 }
      SetBag(0, { [1]={itemID=7005}, [2]={itemID=7100}, [3]={itemID=7101} })
      SetBag(1, {})
    """)
    ups = h.call("local u = ADDON_NS.GetUpgrades(); local out={} for _,x in ipairs(u) do out[#out+1]=x.itemID end return out")
    ids = list(ups.values()) if hasattr(ups, "values") else ups
    check("tool not upgrade", 7005 not in ids, ids)
    check("red gear not upgrade", 7100 not in ids, ids)
    check("usable chest is upgrade", 7101 in ids, ids)

    h.execute("EQUIP_CALLS = 0; C_Item.EquipItemByName = function() EQUIP_CALLS = EQUIP_CALLS + 1 end")
    h.call("ADDON_NS.EquipUpgrades(true); return Advance(2)")
    check("no equip red/tool", h.call("return EQUIP_CALLS") == 1, h.call("return EQUIP_CALLS"))


@run("sort: profession tool sits after materials, not second")
def test_sort_tool_rank():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [7005] = { name="剥皮小刀", quality=1, ilvl=1, classID=2, subclassID=15,
                   subType="Miscellaneous", equipLoc="INVTYPE_WEAPON" },
        [9700] = { name="普通材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9701] = { name="胸甲", quality=2, ilvl=10, classID=4, subclassID=2, equipLoc="INVTYPE_CHEST" },
      }
      PRICES = { [7005]=1, [9700]=50, [9701]=100 }
      SetBag(0, { [1]={itemID=7005}, [2]={itemID=9700}, [3]={itemID=9701} })
      SetBag(1, {})
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    check("tool sorted after material", h.call("return DumpBag(0)") == "9701 9700 7005 -",
          h.call("return DumpBag(0)"))


@run("ammo: merchant open auto-buys without any command")
def test_ammo_on_merchant_show():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Ammo.lua"])
    h.fire_addon_loaded()
    h.execute("""
      CURRENT_CLASS = "HUNTER"
      PLAYER_LEVEL = 13
      ITEM_DB = {
        [6000] = { name="训练弓", quality=2, ilvl=10, reqLevel=5, classID=2, subclassID=2,
                   subType="Bow", equipLoc="INVTYPE_RANGED" },
        [6002] = { name="训练枪", quality=2, ilvl=10, reqLevel=5, classID=2, subclassID=3,
                   subType="Gun", equipLoc="INVTYPE_RANGED" },
        [6001] = { name="轻弹丸", quality=1, ilvl=1, reqLevel=1, classID=6, subclassID=3,
                   subType="子弹", equipLoc="INVTYPE_AMMO" },
      }
      PRICES = {}
      EQUIPPED_ITEMS = { [18] = 6002 }
      SetBag(0, { [1]={itemID=6001, count=1000} })
      SetBag(1, {})
      MERCHANT_ITEMS = { { name="轻弹丸", itemID=6001, price=100, stack=200, avail=-1 } }
      MONEY = 10000
      BUYS = {}
      ADDON_NS.db.ammoAutoBuy = true
      ADDON_NS.db.ammoTarget = 2000
      ADDON_NS.merchantAmmoDone = nil
    """)
    h.call("""
      for _, f in ipairs(GLOBAL_FRAMES) do
        if f.events and f.events.MERCHANT_SHOW then f:Fire("MERCHANT_SHOW") end
      end
    """)
    check("auto-buy on merchant show", h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n") == 1000,
          h.call("local n=0 for _,b in ipairs(BUYS) do n=n+b.qty end return n"))


@run("upgrade: leather bracers replace cloth (Burnt Hide Bracers 3158)")
def test_upgrade_leather_over_cloth():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "MarkerCore.lua", "Upgrade.lua"])
    h.fire_addon_loaded()
    h.execute("""
      CURRENT_CLASS = 'HUNTER'
      PLAYER_LEVEL = 13
      ITEM_DB = {
        [7400] = { name="旧布护腕", quality=1, ilvl=10, reqLevel=1, classID=4, subclassID=1,
                   equipLoc="INVTYPE_WRIST" },
        [3158] = { name="褐色毛护腕", quality=2, ilvl=12, reqLevel=10, classID=4, subclassID=2,
                   equipLoc="INVTYPE_WRIST", bind=1 },
      }
      ITEM_STATS = { [7400] = { ITEM_MOD_AGILITY = 1 } }
      EQUIP = { [9] = 7400 }
      SetBag(0, { [1]={itemID=3158, quality=2} })
      SetBag(1, {})
    """)
    ids = h.call("local u=ADDON_NS.GetUpgrades(); local o={} for _,x in ipairs(u) do o[#o+1]=x.itemID end return o")
    ids = list(ids.values()) if hasattr(ids, "values") else ids
    check("3158 is an upgrade", 3158 in ids, ids)
    h.call("ADDON_NS.EquipUpgrades(true); return Advance(2)")
    check("3158 equipped", h.call("return EQUIP[9]") == 3158, h.call("return EQUIP[9]"))


@run("sort: uniform subcategory order (slot/type), no price")
def test_sort_subcategory():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("ADDON_NS.db.autoBagRoles = false")
    h.execute("""
      ITEM_DB = {
        [9801] = { name="板甲胸", quality=1, ilvl=20, classID=4, subclassID=4, equipLoc="INVTYPE_CHEST" },
        [9802] = { name="布甲头", quality=1, ilvl=5, classID=4, subclassID=1, equipLoc="INVTYPE_HEAD" },
        [9803] = { name="剑", quality=1, ilvl=5, classID=2, subclassID=7, equipLoc="INVTYPE_WEAPON" },
        [9804] = { name="布", quality=1, ilvl=1, classID=7, subclassID=1, equipLoc="" },
        [9805] = { name="皮", quality=1, ilvl=1, classID=7, subclassID=2, equipLoc="" },
        [9806] = { name="药水", quality=1, ilvl=1, classID=0, subclassID=0, equipLoc="" },
      }
      PRICES = { [9801]=1, [9802]=9999, [9803]=1, [9804]=1, [9805]=1, [9806]=1 }
      SetBag(0, { [1]={itemID=9805}, [2]={itemID=9803}, [3]={itemID=9801},
                  [4]={itemID=9806} })
      SetBag(1, { [1]={itemID=9804}, [2]={itemID=9802} })
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(1)")
    order = h.call("return DumpBag(0) .. ' | ' .. DumpBag(1)")
    check("subcategory order ignores price",
          order.startswith("9801 9803 9806 9805 | 9802 9804"), order)


@run("sort: auto-distribute categories into different bags")
def test_auto_bag_roles():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("""
      ADDON_NS.db.autoBagRoles = true
      ITEM_DB = {
        [6948] = { name="炉石", quality=1, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9000] = { name="垃圾", quality=0, ilvl=1, classID=15, subclassID=0, equipLoc="" },
        [9001] = { name="材料", quality=1, ilvl=1, classID=7, subclassID=0, equipLoc="" },
        [9002] = { name="药水", quality=1, ilvl=1, classID=0, subclassID=0, equipLoc="" },
        [9003] = { name="胸甲", quality=2, ilvl=20, classID=4, subclassID=4, equipLoc="INVTYPE_CHEST" },
        [9004] = { name="任务物品", quality=1, ilvl=1, classID=12, subclassID=0, equipLoc="" },
        [9005] = { name="护腕", quality=2, ilvl=10, classID=4, subclassID=2, equipLoc="INVTYPE_WRIST" },
      }
      PRICES = { [9000]=500, [9001]=10, [9002]=5, [9003]=1, [9004]=0, [9005]=1 }
      SetBag(0, { [1]={itemID=9003}, [2]={itemID=9001}, [3]={itemID=9000}, [4]={itemID=9004} })
      SetBag(1, { [1]={itemID=9002} })
      SetBag(2, { [1]={itemID=6948}, [2]={itemID=9005} })
      SetBag(3, {})
      SetBag(4, {})
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(2)")
    b0 = h.call("return DumpBag(0)")
    b1 = h.call("return DumpBag(1)")
    b2 = h.call("return DumpBag(2)")
    b3 = h.call("return DumpBag(3)")
    b4 = h.call("return DumpBag(4)")
    check("quest bag has HS/quest/consumable", b0 == "6948 9004 9002 -", b0)
    check("equipment in equip bags", ("9003" in (b1 + b2)) and ("9005" in (b1 + b2)), (b1, b2))
    check("material in material bag", b3 == "9001 - - -", b3)
    check("junk in misc bag", b4 == "9000 - - -", b4)


@run("sort: materials go into the reagent bag first")
def test_reagent_bag_priority():
    h = Harness()
    h.load_addon(["Core.lua", "Log.lua", "Sell.lua", "Sort.lua"])
    h.fire_addon_loaded()
    h.execute("""
      REAGENT_BAG_SLOTS = 2
      ADDON_NS.db.autoBagRoles = true
      ITEM_DB = {
        [9001] = { name="轻皮", quality=1, ilvl=1, classID=7, subclassID=2, equipLoc="" },
        [9006] = { name="破烂的皮革", quality=1, ilvl=1, classID=7, subclassID=2, equipLoc="" },
        [9002] = { name="药水", quality=1, ilvl=1, classID=0, subclassID=0, equipLoc="" },
        [9003] = { name="胸甲", quality=2, ilvl=20, classID=4, subclassID=4, equipLoc="INVTYPE_CHEST" },
      }
      PRICES = { [9001]=10, [9006]=5, [9002]=5, [9003]=1 }
      SetBag(0, { [1]={itemID=9001}, [2]={itemID=9003} })
      SetBag(3, { [1]={itemID=9006}, [2]={itemID=9002} })
      SetBag(5, {})
    """)
    h.call("ADDON_NS.SortByValue(false, true); return Advance(2)")
    b5 = h.call("return DumpBag(5)")
    check("materials in reagent bag first", b5 == "9001 9006 - -", b5)
    check("equipment not in reagent bag", "9003" not in b5, b5)
    check("material bag has no leather left", h.call("return DumpBag(3):find('9006') == nil") is True,
          h.call("return DumpBag(3)"))


# ---------------------------------------------------------------- main
def main():
    for name, fn in TESTS:
        try:
            fn()
        except Exception:
            RESULTS.append((name, False, traceback.format_exc()))
            print("FAIL " + name)
            traceback.print_exc()

    failed = [r for r in RESULTS if not r[1]]
    print()
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:")
        for name, _, detail in failed:
            print(" -", name, detail)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
