"""读取 WoW 聊天日志里的 DANIEL1 状态分片。

插件用“对自己的密语”发送：
    DANIEL1:<sid>:<seq>/<total>:<json chunk>
客户端的 /chatlog 把它写进 Logs/WoWChatLog.txt。本模块只读文本文件，
不读游戏内存、不注入。
"""

from __future__ import annotations

import glob
import json
import os
import re
import time

DEFAULT_ROOTS = [
    "/Volumes/Extra/Games/World of Warcraft/_forever_",
    "/Volumes/Extra/Games/World of Warcraft/_retail_",
]

MAGIC_RE = re.compile(r"DANIEL1:([^\s:]+):(\d+)/(\d+):(.*)$")


def find_chatlog(root: str | None = None) -> str | None:
    env = os.environ.get("DANIEL_CHATLOG")
    if env and os.path.exists(env):
        return env
    roots = [root] if root else DEFAULT_ROOTS
    candidates = []
    for base in roots:
        if not base:
            continue
        candidates.extend(glob.glob(os.path.join(base, "Logs", "**", "WoWChatLog.txt"), recursive=True))
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def parse_text(text: str) -> list[dict]:
    out = []
    for line in text.splitlines():
        m = MAGIC_RE.search(line)
        if not m:
            continue
        sid, seq, total, chunk = m.groups()
        try:
            out.append({"sid": sid, "seq": int(seq), "total": int(total), "chunk": chunk})
        except ValueError:
            continue
    return out


def normalize(state: dict) -> dict:
    """把 v4 短键/数组传输格式还原成 agent 友好的对象结构。"""
    if not isinstance(state, dict) or state.get("v", 0) < 4 or not isinstance(state.get("q"), list):
        return state
    p = state.get("p") or []
    out = {
        "v": 4,
        "ts": state.get("ts"),
        "zone": state.get("z"),
        "mapID": state.get("m"),
        "player": {
            "x": p[0] if len(p) > 0 else None,
            "y": p[1] if len(p) > 1 else None,
            "level": p[2] if len(p) > 2 else None,
            "class": p[3] if len(p) > 3 else None,
        },
        "quests": [],
        "markers": [],
    }
    for row in state.get("q") or []:
        q = {
            "id": row[0] if len(row) > 0 else None,
            "title": row[1] if len(row) > 1 else None,
            "level": row[2] if len(row) > 2 else None,
            "complete": bool(row[6]) if len(row) > 6 else False,
            "objectives": [],
        }
        if len(row) > 5 and row[3]:
            q["next"] = {"map": row[3], "x": row[4], "y": row[5]}
        for o in (row[7] if len(row) > 7 else []) or []:
            q["objectives"].append({
                "text": o[0] if len(o) > 0 else None,
                "done": bool(o[1]) if len(o) > 1 else False,
                "n": o[2] if len(o) > 2 else None,
                "need": o[3] if len(o) > 3 else None,
            })
        out["quests"].append(q)
    for row in state.get("mk") or []:
        out["markers"].append({
            "id": row[0] if len(row) > 0 else None,
            "map": row[1] if len(row) > 1 else None,
            "x": row[2] if len(row) > 2 else None,
            "y": row[3] if len(row) > 3 else None,
            "label": row[4] if len(row) > 4 else None,
        })
    if "_sid" in state:
        out["_sid"] = state["_sid"]
    if "_chunks" in state:
        out["_chunks"] = state["_chunks"]
    return out


def reassemble(messages: list[dict]) -> dict | None:
    groups: dict[str, dict[int, str]] = {}
    totals: dict[str, int] = {}
    for m in messages:
        groups.setdefault(m["sid"], {})[m["seq"]] = m["chunk"]
        totals[m["sid"]] = m["total"]

    latest = None
    for sid, parts in groups.items():
        total = totals[sid]
        if len(parts) != total or any(i not in parts for i in range(1, total + 1)):
            continue
        raw = "".join(parts[i] for i in range(1, total + 1))
        try:
            state = json.loads(raw)
        except json.JSONDecodeError:
            continue
        state["_sid"] = sid
        state["_chunks"] = total
        if latest is None or (state.get("ts") or 0) >= (latest.get("ts") or 0):
            latest = state
    return normalize(latest) if latest else None


def read_tail(path: str, max_bytes: int = 2_000_000) -> str:
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - max_bytes))
        return f.read().decode("utf-8", errors="replace")


def read_latest_state(path: str | None = None, wait_seconds: float = 0.0,
                      min_ts: float | None = None) -> dict | None:
    path = path or find_chatlog()
    if not path:
        return None
    start = time.time()
    state = reassemble(parse_text(read_tail(path)))
    if state and (min_ts is None or float(state.get("ts") or 0) >= min_ts):
        return state
    if wait_seconds <= 0:
        return state
    while time.time() - start < wait_seconds:
        time.sleep(0.2)
        state = reassemble(parse_text(read_tail(path)))
        if state and (min_ts is None or float(state.get("ts") or 0) >= min_ts):
            return state
    return state


def state_age(state: dict) -> float | None:
    ts = state.get("ts")
    if not ts:
        return None
    return max(0.0, time.time() - float(ts))


if __name__ == "__main__":
    path = find_chatlog()
    print("chatlog:", path)
    state = read_latest_state(path, wait_seconds=0)
    print(json.dumps(state, ensure_ascii=False, indent=2) if state else "no DANIEL1 state found")
