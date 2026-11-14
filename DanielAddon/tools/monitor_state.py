#!/usr/bin/env python3
"""游戏内状态监视：等待聊天日志出现，每收到一帧完整状态就打印一行。

用于 Claude 的 Monitor（stdout 每行一个事件），也可以手动跑：
    uv run python -I tools/monitor_state.py
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import state_reader  # noqa: E402

WOW_PATTERN = "Contents/MacOS/World of Warcraft"
SV_GLOB = "/Volumes/Extra/Games/World of Warcraft/_forever_/WTF/Account/*/SavedVariables/DanielAddon.lua"


def savedvars_info() -> tuple[str | None, float | None, int | None]:
    paths = glob.glob(SV_GLOB)
    if not paths:
        return None, None, None
    path = max(paths, key=os.path.getmtime)
    st = os.stat(path)
    return path, st.st_mtime, st.st_size


def wow_pids() -> list[str]:
    try:
        out = subprocess.run(["pgrep", "-f", WOW_PATTERN], capture_output=True, text=True,
                             timeout=2).stdout
        return [line.strip() for line in out.splitlines() if line.strip()]
    except Exception:
        return []


def summarize(state: dict) -> str:
    p = state.get("player") or {}
    quests = state.get("quests") or []
    bits = [
        f"zone={state.get('zone')}",
        f"map={state.get('mapID')}",
        f"player={p.get('x')},{p.get('y')}",
        f"quests={len(quests)}",
    ]
    for q in quests[:3]:
        nxt = q.get("next")
        loc = f" next={nxt['map']},{nxt['x']:.3f},{nxt['y']:.3f}" if nxt else ""
        bits.append(f"Q{q.get('id')}:{q.get('title')}{loc}")
    return " | ".join(bits)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--heartbeat", type=float, default=120.0)
    args = ap.parse_args()

    last_sid = None
    last_sig = None
    last_chatlog = None
    last_sv = None
    last_size = -1
    last_heartbeat = 0.0
    last_state_at = 0.0
    was_running = bool(wow_pids())
    if was_running:
        print(f"WOW_RUNNING pids={','.join(wow_pids())}", flush=True)

    while True:
        now = time.time()
        path = state_reader.find_chatlog()
        if path != last_chatlog:
            last_chatlog = path
            print(f"CHATLOG {path}" if path else "CHATLOG none", flush=True)

        sv_path, sv_mtime, sv_size = savedvars_info()
        if sv_path and sv_mtime != last_sv:
            last_sv = sv_mtime
            print(f"SAVEDVARS {sv_path} size={sv_size}", flush=True)

        size = os.path.getsize(path) if path else 0
        if size != last_size:
            last_size = size
            print(f"CHATLOG_SIZE {size}", flush=True)

        state = state_reader.read_latest_state(path, wait_seconds=0) if path else None
        if state:
            sid = state.get("_sid")
            sig = (state.get("zone"), state.get("mapID"),
                   tuple((q.get("id"), (q.get("next") or {}).get("map"),
                          round((q.get("next") or {}).get("x") or 0, 3),
                          round((q.get("next") or {}).get("y") or 0, 3))
                         for q in (state.get("quests") or [])))
            if sig != last_sig:
                last_sig = sig
                last_sid = sid
                last_state_at = now
                print(f"STATE {time.strftime('%H:%M:%S')} {summarize(state)}", flush=True)
        elif last_sid and now - last_state_at > 60:
            print(f"STALE 已经 {int(now - last_state_at)} 秒没有新状态", flush=True)
            last_state_at = now

        pids = wow_pids()
        running = bool(pids)
        if was_running and not running:
            print("WOW_EXIT", flush=True)
            return 0
        if not was_running and running:
            print(f"WOW_RUNNING pids={','.join(pids)}", flush=True)
        was_running = running

        if now - last_heartbeat >= args.heartbeat:
            last_heartbeat = now
            print(f"HEARTBEAT {time.strftime('%H:%M:%S')} chatlog={'yes' if path else 'no'} "
                  f"size={os.path.getsize(path) if path else 0} state={'yes' if state else 'no'} "
                  f"sv={sv_size if sv_size is not None else '-'} wow={'yes' if running else 'no'}", flush=True)

        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
