#!/usr/bin/env python3
"""读取 WoW SavedVariables 里的 DanielAddonDB，导出成 JSON fixture。

用途：游戏里跑一遍功能 → /reload 落盘 → 把日志变成测试/复现用的 fixture。
无 IO 的沙箱里执行：只保留纯 Lua 数据构造，去掉 os/io/require/loadfile。

示例：
    uv run --with lupa python -I tools/log_to_fixture.py --summary
    uv run --with lupa python -I tools/log_to_fixture.py \
        --file "/path/WTF/Account/xxx/SavedVariables/DanielAddon.lua" \
        --out tests/fixtures/session-2026-11-10.json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import Counter

import lupa
from lupa import LuaRuntime

DEFAULT_ROOT = "/Volumes/Extra/Games/World of Warcraft/_forever_/WTF/Account"
UNSAFE_GLOBALS = [
    "os", "io", "require", "dofile", "loadfile", "load",
    "package", "debug", "collectgarbage", "newproxy",
]


def find_savedvars(root: str) -> list[str]:
    return sorted(glob.glob(os.path.join(root, "*", "SavedVariables", "DanielAddon.lua")))


def to_py(value, depth=0, seen=None):
    if seen is None:
        seen = set()
    if depth > 8:
        return "<max-depth>"
    if lupa.lua_type(value) != "table":
        if isinstance(value, (str, int, float, bool)) or value is None:
            return value
        return str(value)
    ident = id(value)
    if ident in seen:
        return "<cycle>"
    seen.add(ident)
    try:
        # 优先按数组转
        items = []
        n = 0
        for k, v in value.items():
            n += 1
            items.append((k, v))
        if items and all(isinstance(k, int) and k >= 1 for k, _ in items):
            items.sort(key=lambda kv: kv[0])
            if [k for k, _ in items] == list(range(1, len(items) + 1)):
                return [to_py(v, depth + 1, seen) for _, v in items]
        out = {}
        for k, v in items:
            out[str(k)] = to_py(v, depth + 1, seen)
        return out
    finally:
        seen.discard(ident)


def load_db(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        src = f.read()

    L = LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    for name in UNSAFE_GLOBALS:
        g[name] = None

    L.execute(src)
    db = g["DanielAddonDB"]
    if db is None:
        raise SystemExit("文件里没有 DanielAddonDB")
    return to_py(db)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="SavedVariables 文件；不传则在默认 WTF 路径里找最新的")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="WTF/Account 根目录")
    ap.add_argument("--out", help="输出 JSON 路径")
    ap.add_argument("--summary", action="store_true", help="只打印摘要")
    args = ap.parse_args()

    path = args.file
    if not path:
        files = find_savedvars(args.root)
        if not files:
            raise SystemExit(f"找不到 SavedVariables：{args.root}/*/SavedVariables/DanielAddon.lua")
        path = files[-1]

    db = load_db(path)
    last_state = db.get("lastState")
    if isinstance(last_state, str):
        try:
            last_state = json.loads(last_state)
        except json.JSONDecodeError:
            pass
    fixture = {
        "source": path,
        "account": path.split(os.sep)[-3] if os.sep in path else "",
        "markers": db.get("markers", []),
        "logs": db.get("logs", []),
        "last_state": last_state,
    }

    if args.summary or not args.out:
        events = Counter(str(e.get("e")) for e in fixture["logs"] if isinstance(e, dict))
        print(f"文件：{path}")
        print(f"日志 {len(fixture['logs'])} 条；标记 {len(fixture['markers'])} 个")
        if isinstance(fixture.get("last_state"), dict):
            st = fixture["last_state"]
            print(f"最后状态：{st.get('zone')} 任务 {len(st.get('quests') or [])} 个")
        print("事件统计：" + ", ".join(f"{k}={v}" for k, v in events.most_common(12)))
        for e in reversed(fixture["logs"]):
            if isinstance(e, dict) and e.get("e") == "diag":
                print("最近一次 diag：" + json.dumps(e.get("d"), ensure_ascii=False)[:800])
                break
        for m in fixture["markers"]:
            if isinstance(m, dict):
                print(f"  标记 #{m.get('id')} {m.get('zoneName')} "
                      f"{(m.get('x') or 0) * 100:.1f},{(m.get('y') or 0) * 100:.1f} {m.get('label') or ''}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(fixture, f, ensure_ascii=False, indent=2)
        print(f"已写入 {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
