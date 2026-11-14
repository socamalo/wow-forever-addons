#!/usr/bin/env python3
"""MCP 端测试（需要 mcp 包）：

    uv run --with mcp python -I tests/test_mcp.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(HERE)
TOOLS = os.path.join(ADDON_DIR, "tools")
sys.path.insert(0, TOOLS)

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)))


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="daniel-mcp-test-")
    chatlog = os.path.join(tmp, "WoWChatLog.txt")
    queue = os.path.join(tmp, "markers.json")

    state = {
        "v": 3, "ts": 1762800000, "zone": "铁炉堡", "mapID": 87,
        "player": {"x": 0.55, "y": 0.48, "wx": 550, "wy": 520},
        "quests": [
            {"id": 123, "title": "测试任务", "level": 10, "onMap": True,
             "next": {"map": 87, "x": 0.6, "y": 0.5},
             "objectives": [{"text": "击杀5只狼", "done": False, "n": 2, "need": 5}]},
        ],
    }
    raw = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
    chunks = [raw[i:i + 170] for i in range(0, len(raw), 170)]
    with open(chatlog, "w", encoding="utf-8") as f:
        for i, chunk in enumerate(chunks, 1):
            f.write(f"11/10 18:00:00.000  To [Daniel]: DANIEL1:sid1:{i}/{len(chunks)}:{chunk}\n")

    os.environ["DANIEL_CHATLOG"] = chatlog
    os.environ["DANIEL_QUEUE"] = queue
    os.environ["DANIEL_MCP_INPUT"] = "file"

    import daniel_mcp as d

    result = d.get_game_state(0)
    check("mcp get_game_state ok", result.get("ok") is True, result)
    check("mcp state quest", result["state"]["quests"][0]["title"] == "测试任务", result)

    q = d.get_quests(0)
    check("mcp get_quests", len(q["quests"]) == 1 and q["quests"][0]["id"] == 123, q)

    p = d.get_player()
    check("mcp get_player", p["zone"] == "铁炉堡", p)

    r = d.add_marker("铁炉堡", 56, 48.5, "训练师")
    check("mcp add_marker queued", r.get("ok") and r.get("queued"), r)

    r = d.mark_quest_next(0)
    check("mcp command queued", r.get("sent") == "queue", r)

    r = d.clear_markers()
    check("mcp clear queued", r.get("ok") is True, r)

    with open(queue, encoding="utf-8") as f:
        data = json.load(f)
    check("queue commands present", "/daniel questmark all" in data["commands"], data)
    check("queue clear flag", data["clear"] is True, data)

    # watcher 消费命令
    import agent_mark_watch
    lines = agent_mark_watch.process(queue, False, "World of Warcraft", copy=False)
    check("watcher emits clear first", lines[0] == "/daniel mark clear", lines)
    check("watcher emits questmark", "/daniel questmark all" in lines, lines)
    with open(queue, encoding="utf-8") as f:
        data = json.load(f)
    check("watcher consumes commands", data["commands"] == [] and data["clear"] is False, data)

    # 机械 loop：状态 -> 任务 next -> 队列
    import agent_loop
    agent_loop.QUEUE = os.path.join(tmp, "loop-markers.json")
    seen = set()
    added = agent_loop.step(seen)
    check("agent_loop adds quest marker", len(added) == 1 and added[0]["label"].startswith("任务："), added)
    added2 = agent_loop.step(seen)
    check("agent_loop dedupes", added2 == [], added2)

    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
