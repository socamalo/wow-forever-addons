#!/usr/bin/env python3
"""监视 markers.json，变化时把标记命令打印/复制出来；不控制用户 WoW。

这是“实时”能做到的极限：WoW 插件没有文件/网络 IO，外部进程只能通过
默认只打印/复制到剪贴板；--type 已禁用，不会注入游戏输入，
需要给终端/Claude 辅助功能权限，并自行评估外部输入自动化的风险。

用法：
    uv run python -I tools/agent_mark_watch.py --file markers.json
    uv run python -I tools/agent_mark_watch.py --file markers.json
    uv run python -I tools/agent_mark_watch.py --file markers.json --once
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import agent_mark  # noqa: E402


def digest(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def process(path: str, do_type: bool, app: str, copy: bool = True) -> list[str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    commands = []
    clear = False
    if isinstance(data, dict):
        commands = list(data.get("commands") or [])
        clear = bool(data.get("clear"))
        data = data.get("markers", [data])
    markers = []
    for item in data:
        markers.append(
            {
                "zone": agent_mark.clean_field(item.get("zone", ""), "zone"),
                "x": agent_mark.coords(item.get("x"), "x"),
                "y": agent_mark.coords(item.get("y"), "y"),
                "label": agent_mark.clean_field(item.get("label", ""), "label")
                if item.get("label") else "",
            }
        )
    lines = []
    if clear:
        lines.append("/daniel mark clear")
    lines.extend(commands)
    if markers:
        lines.extend(agent_mark.encode(markers))
    for line in lines:
        print(line, flush=True)
    if copy and agent_mark.copy_to_clipboard("\n".join(lines)):
        print(f"已复制 {len(lines)} 条到剪贴板。", file=sys.stderr)
    if do_type:
        agent_mark.type_into_game(lines, app)
        print("已输入到游戏窗口。", file=sys.stderr)
    if commands or clear:
        # 消费掉命令，避免下一次文件变化重复输入
        try:
            with open(path, encoding="utf-8") as f:
                current = json.load(f)
            if isinstance(current, dict):
                current["commands"] = []
                current["clear"] = False
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(current, f, ensure_ascii=False, indent=2)
        except Exception:
            pass
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=os.path.expanduser("~/daniel-markers.json"), help="agent 写入的 JSON 文件")
    ap.add_argument("--interval", type=float, default=1.0, help="轮询间隔秒")
    ap.add_argument("--type", action="store_true",
                    help="[已禁用] 不控制用户 WoW；请手动粘贴")
    ap.add_argument("--app", default="World of Warcraft", help="游戏应用名")
    ap.add_argument("--once", action="store_true", help="只处理一次就退出")
    ap.add_argument("--no-copy", action="store_true", help="不写剪贴板（调试用）")
    args = ap.parse_args()
    if args.type:
        print("已禁用：不控制用户的 WoW 客户端；请手动复制/粘贴命令。", file=sys.stderr)
        return 2

    if not os.path.exists(args.file):
        print(f"等待文件出现：{args.file}", file=sys.stderr)
    last = None
    while True:
        try:
            if os.path.exists(args.file):
                h = digest(args.file)
                if h != last:
                    last = h
                    print(f"检测到变化：{args.file}", file=sys.stderr)
                    process(args.file, args.type, args.app, copy=not args.no_copy)
        except Exception as e:
            print(f"处理失败：{e}", file=sys.stderr)
            last = None
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
