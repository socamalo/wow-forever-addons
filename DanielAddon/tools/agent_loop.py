#!/usr/bin/env python3
"""本地机械版陪玩 loop（演示数据流，不是 LLM）。

真正的“思考”由 MCP 客户端里的 agent 完成：它调 get_game_state / add_marker。
这个脚本只演示不依赖 LLM 的最小闭环：
  聊天日志状态 → 每个任务的 next 路径点 → markers.json 队列 → watcher 输入游戏。

用法：
    uv run python -I tools/agent_loop.py --once
    uv run python -I tools/agent_loop.py --interval 10
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import state_reader  # noqa: E402

QUEUE = os.environ.get("DANIEL_QUEUE", os.path.expanduser("~/daniel-markers.json"))


def load_queue() -> dict:
    if not os.path.exists(QUEUE):
        return {"markers": [], "clear": False, "commands": [], "seq": 0}
    try:
        with open(QUEUE, encoding="utf-8") as f:
            data = json.load(f)
        data.setdefault("markers", [])
        data.setdefault("clear", False)
        data.setdefault("commands", [])
        data.setdefault("seq", 0)
        return data
    except Exception:
        return {"markers": [], "clear": False, "commands": [], "seq": 0}


def save_queue(data: dict) -> None:
    data["seq"] = int(data.get("seq") or 0) + 1
    with open(QUEUE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def same(a: dict, b: dict) -> bool:
    return (a.get("zone") == b.get("zone")
            and abs(float(a.get("x", 0)) - float(b.get("x", 0))) < 1e-6
            and abs(float(a.get("y", 0)) - float(b.get("y", 0))) < 1e-6)


def step(seen: set) -> list[str]:
    state = state_reader.read_latest_state(wait_seconds=0)
    if not state:
        print("还没有状态；确认 /daniel state 和聊天日志。", file=sys.stderr)
        return []

    quests = state.get("quests") or []
    zone = state.get("zone") or "?"
    print(f"[{time.strftime('%H:%M:%S')}] {zone} 任务 {len(quests)} 个", file=sys.stderr)

    data = load_queue()
    added = []
    for q in quests:
        nxt = q.get("next")
        if not nxt:
            continue
        key = (q.get("id"), nxt.get("map"), round(float(nxt.get("x", 0)), 4), round(float(nxt.get("y", 0)), 4))
        if key in seen:
            continue
        seen.add(key)
        marker = {"zone": str(nxt.get("map")), "x": float(nxt.get("x", 0)) * 100,
                  "y": float(nxt.get("y", 0)) * 100,
                  "label": "任务：" + str(q.get("title") or q.get("id"))}
        if not any(same(m, marker) for m in data["markers"]):
            data["markers"].append(marker)
            added.append(marker)

    if added:
        data["clear"] = False
        save_queue(data)
        for m in added:
            print("marker:", m, file=sys.stderr)
    return added


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=10.0)
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    seen = set()
    while True:
        try:
            step(seen)
        except Exception as e:
            print("loop error:", e, file=sys.stderr)
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
