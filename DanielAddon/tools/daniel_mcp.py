#!/usr/bin/env python3
"""DanielAddon MCP server（本地 stdio）。

给 Claude/其它 agent 的接口：
- get_game_state / get_quests / get_player：读聊天日志里的 DANIEL1 状态
- add_marker / add_markers / clear_markers：写 markers.json 队列，
  由 agent_mark_watch.py 送入游戏（或设 DANIEL_MCP_INPUT=type 直接输入）
- mark_quest_next / mark_all_quests / diagnose：发送聊天命令

运行（给 MCP 客户端配置）：
    uv run --with mcp python -I tools/daniel_mcp.py

环境变量：
    DANIEL_CHATLOG   聊天日志路径；不设则自动找 Logs/**/WoWChatLog.txt
    DANIEL_QUEUE     标记队列文件，默认 ~/daniel-markers.json
    DANIEL_MCP_INPUT file | type | clipboard，默认 file
    DANIEL_WOW_APP   游戏应用名，默认 "World of Warcraft"
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import agent_mark  # noqa: E402
import state_reader  # noqa: E402

try:  # MCP 2.x
    from mcp.server.mcpserver import MCPServer  # noqa: E402
    mcp = MCPServer("daniel-wow")
except ImportError:  # MCP 1.x
    from mcp.server.fastmcp import FastMCP  # noqa: E402
    mcp = FastMCP("daniel-wow")

QUEUE = os.environ.get("DANIEL_QUEUE", os.path.expanduser("~/daniel-markers.json"))
INPUT_MODE = os.environ.get("DANIEL_MCP_INPUT", "file")
WOW_APP = os.environ.get("DANIEL_WOW_APP", "World of Warcraft")


def _load_queue() -> dict:
    if not os.path.exists(QUEUE):
        return {"markers": [], "clear": False, "commands": [], "seq": 0}
    try:
        with open(QUEUE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            data = {"markers": data}
        data.setdefault("markers", [])
        data.setdefault("clear", False)
        data.setdefault("commands", [])
        data.setdefault("seq", 0)
        return data
    except Exception:
        return {"markers": [], "clear": False, "commands": [], "seq": 0}


def _save_queue(data: dict) -> None:
    data["seq"] = int(data.get("seq") or 0) + 1
    os.makedirs(os.path.dirname(os.path.abspath(QUEUE)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".daniel-markers-", dir=os.path.dirname(os.path.abspath(QUEUE)))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, QUEUE)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _send_command(command: str) -> dict:
    if INPUT_MODE == "type":
        return {"sent": "blocked", "command": command,
                "note": "已禁用：不控制用户 WoW。请改 DANIEL_MCP_INPUT=file 或 clipboard，由用户手动粘贴。"}
    if INPUT_MODE == "clipboard":
        agent_mark.copy_to_clipboard(command)
        return {"sent": "clipboard", "command": command,
                "note": "已复制到剪贴板，切回游戏粘贴回车。"}
    data = _load_queue()
    data.setdefault("commands", []).append(command)
    _save_queue(data)
    return {"sent": "queue", "command": command, "queue": QUEUE,
            "note": "已写入队列；请用户自己运行 watcher，watcher 默认只打印/复制，不注入游戏。"}


@mcp.tool()
def get_game_state(wait_seconds: float = 2.0) -> dict:
    """读取最新的游戏状态：zone、mapID、玩家坐标、全部任务（含下一步路径点与目标进度）。

    数据来自插件通过聊天日志导出的 DANIEL1 分片；wait_seconds 内没有新状态会返回
    聊天日志里最近一次完整状态（带 age_seconds）。
    """
    import time as _time
    start_ts = _time.time()
    state = state_reader.read_latest_state(wait_seconds=0)
    age = state_reader.state_age(state) if state else None
    if state is None or (age is not None and age > 5):
        fresh = state_reader.read_latest_state(wait_seconds=wait_seconds, min_ts=start_ts - 1)
        if fresh is not None:
            state = fresh
    if not state:
        return {
            "ok": False,
            "error": "没有找到 DANIEL1 状态。确认：1) 插件已加载；2) /daniel state 能发状态；"
                     "3) 客户端 /chatlog 已开（插件默认自动开）；4) DANIEL_CHATLOG 指向 WoWChatLog.txt。",
            "chatlog": state_reader.find_chatlog(),
        }
    age = state_reader.state_age(state)
    return {
        "ok": True,
        "state": state,
        "age_seconds": age,
        "fresh": age is not None and age < 15,
        "chatlog": state_reader.find_chatlog(),
    }


@mcp.tool()
def get_quests(wait_seconds: float = 2.0) -> dict:
    """只返回任务列表（id/title/level/tag/完成状态/next 路径点/objectives）。"""
    result = get_game_state(wait_seconds)
    if not result.get("ok"):
        return result
    state = result["state"]
    return {
        "ok": True,
        "zone": state.get("zone"),
        "mapID": state.get("mapID"),
        "player": state.get("player"),
        "quests": state.get("quests", []),
        "age_seconds": result.get("age_seconds"),
    }


@mcp.tool()
def get_player() -> dict:
    """只返回玩家当前位置、zone、mapID。"""
    result = get_game_state(0)
    if not result.get("ok"):
        return result
    s = result["state"]
    return {"ok": True, "zone": s.get("zone"), "mapID": s.get("mapID"),
            "player": s.get("player"), "age_seconds": result.get("age_seconds")}


@mcp.tool()
def add_marker(zone: str, x: float, y: float, label: str = "") -> dict:
    """加一个地图标记。zone 可用中文名/英文城市名/mapID。x y 用 0-100 的地图坐标。

    默认写进 DANIEL_QUEUE（markers.json），配合 agent_mark_watch.py 自动送入游戏；
    DANIEL_MCP_INPUT 只建议 file/clipboard；type 已禁用（不控制用户 WoW）。
    """
    marker = {"zone": agent_mark.clean_field(zone, "zone"),
              "x": agent_mark.coords(x, "x"),
              "y": agent_mark.coords(y, "y"),
              "label": agent_mark.clean_field(label, "label") if label else ""}
    if INPUT_MODE == "file":
        data = _load_queue()
        if not any(m.get("zone") == marker["zone"] and abs(float(m.get("x", 0)) - marker["x"]) < 1e-6
                   and abs(float(m.get("y", 0)) - marker["y"]) < 1e-6
                   and m.get("label", "") == marker["label"] for m in data["markers"]):
            data["markers"].append(marker)
        data["clear"] = False
        _save_queue(data)
        return {"ok": True, "queued": marker, "queue": QUEUE,
                "note": "agent_mark_watch.py 监听这个文件时才会送进游戏。"}
    command = "/daniel mark " + f"{marker['zone']}|{marker['x']:g}|{marker['y']:g}"
    if marker["label"]:
        command += "|" + marker["label"]
    result = _send_command(command)
    result["ok"] = True
    return result


@mcp.tool()
def add_markers(markers: list[dict]) -> dict:
    """批量加标记。markers 是 [{zone,x,y,label}, ...]。"""
    added = []
    for item in markers:
        added.append(add_marker(item.get("zone", ""), item.get("x"), item.get("y"), item.get("label", "")))
    return {"ok": True, "results": added}


@mcp.tool()
def clear_markers() -> dict:
    """清空所有地图标记。"""
    if INPUT_MODE == "file":
        data = _load_queue()
        data["markers"] = []
        data["clear"] = True
        _save_queue(data)
        return {"ok": True, "queue": QUEUE, "note": "watcher 会把 /daniel mark clear 送进游戏。"}
    return _send_command("/daniel mark clear")


@mcp.tool()
def mark_quest_next(quest_id: int = 0) -> dict:
    """标记任务的下一个路径点；quest_id=0 表示所有任务。"""
    command = "/daniel questmark " + (str(quest_id) if quest_id else "all")
    return _send_command(command)


@mcp.tool()
def mark_all_quests() -> dict:
    """把所有任务的下一个路径点都标出来。"""
    return _send_command("/daniel questmark all")


@mcp.tool()
def refresh_state() -> dict:
    """让插件立刻发一次最新状态（等价 /daniel state），随后再调 get_game_state。"""
    return _send_command("/daniel state")


@mcp.tool()
def diagnose() -> dict:
    """让游戏端采集 build/API/地图/小地图事实（/daniel diag）并写入日志。"""
    return _send_command("/daniel diag")


@mcp.tool()
def set_state_auto(on: bool = True) -> dict:
    """开关插件的自动状态导出（默认开，每 6 秒一次）。"""
    return _send_command("/daniel state auto " + ("on" if on else "off"))


if __name__ == "__main__":
    mcp.run()
