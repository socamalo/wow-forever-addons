#!/usr/bin/env python3
"""Agent -> WoW 地图标记桥。

WoW 插件不能读文件、不能联网，所以“实时推送”只能靠聊天命令：
本脚本把 agent 查到的坐标整理成 `/daniel markbatch ...`，默认复制到剪贴板，
你切回游戏粘贴一次即可。--type 已禁用：不控制用户的 WoW 客户端。
（需要给终端/Claude 辅助功能权限，且属于外部输入自动化，请自行决定是否使用）。

示例：
    uv run python -I tools/agent_mark.py \
        --marker "铁炉堡|55.2|47.8|武器大师" \
        --marker "铁炉堡|56.1|48.5|训练师"

    uv run python -I tools/agent_mark.py --json markers.json   # 只打印/复制
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys

MAX_LINE = 240  # WoW 聊天输入上限 255 字节，留余量


def fail(msg: str) -> None:
    print("错误：" + msg, file=sys.stderr)
    raise SystemExit(2)


def clean_field(value: str, name: str) -> str:
    value = str(value).strip()
    if not value:
        fail(f"{name} 不能为空")
    if any(ch in value for ch in "|;\n\r"):
        fail(f"{name} 不能包含 | 或 ;：{value!r}")
    return value


def coords(value, name: str) -> float:
    try:
        n = float(value)
    except Exception:
        fail(f"{name} 不是数字：{value!r}")
    if not (0 <= n <= 100):
        fail(f"{name} 应在 0-100 之间：{n}")
    return n


def marker_from_pair(pair: str) -> dict:
    parts = pair.split("|")
    if len(parts) not in (3, 4):
        fail(f"标记格式应为 zone|x|y[|label]：{pair!r}")
    return {
        "zone": clean_field(parts[0], "zone"),
        "x": coords(parts[1], "x"),
        "y": coords(parts[2], "y"),
        "label": clean_field(parts[3], "label") if len(parts) == 4 else "",
    }


def load_json(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get("markers", [data])
    if not isinstance(data, list):
        fail("JSON 应该是数组，或 {\"markers\": [...]}")
    out = []
    for item in data:
        if not isinstance(item, dict):
            fail("JSON 数组元素必须是对象")
        out.append(
            {
                "zone": clean_field(item.get("zone", ""), "zone"),
                "x": coords(item.get("x"), "x"),
                "y": coords(item.get("y"), "y"),
                "label": clean_field(item.get("label", ""), "label") if item.get("label") else "",
            }
        )
    return out


def encode(markers: list[dict]) -> list[str]:
    """生成若干条 /daniel markbatch，每行不超过 MAX_LINE。"""
    lines, current = [], []
    for m in markers:
        field = f"{m['zone']}|{m['x']:g}|{m['y']:g}"
        if m["label"]:
            field += "|" + m["label"]
        candidate = ";".join(current + [field])
        if current and len(("/daniel markbatch " + candidate).encode("utf-8")) > MAX_LINE:
            lines.append("/daniel markbatch " + ";".join(current))
            current = [field]
        else:
            current.append(field)
    if current:
        lines.append("/daniel markbatch " + ";".join(current))
    return lines


def copy_to_clipboard(text: str) -> bool:
    if not shutil.which("pbcopy"):
        return False
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="把 agent 查到的坐标变成 WoW 聊天标记命令")
    ap.add_argument("--marker", action="append", default=[], help="zone|x|y[|label]，可重复")
    ap.add_argument("--json", help="JSON 文件：数组或 {\"markers\": [...]}")
    ap.add_argument("--one", action="store_true", help="输出单条 /daniel mark 而不是 markbatch")
    ap.add_argument("--no-copy", action="store_true", help="不复制到剪贴板")
    ap.add_argument("--type", action="store_true",
                    help="[已禁用] 不控制用户 WoW；请复制命令手动输入")
    ap.add_argument("--app", default="World of Warcraft", help="游戏窗口的应用名")
    args = ap.parse_args()
    if args.type:
        print("已禁用：不控制用户的 WoW 客户端。请复制命令后手动粘贴。", file=sys.stderr)
        return 2

    markers = [marker_from_pair(p) for p in args.marker]
    if args.json:
        markers.extend(load_json(args.json))
    if not markers:
        fail("至少给一个 --marker 或 --json")

    if args.one:
        lines = [
            "/daniel mark " + f"{m['zone']}|{m['x']:g}|{m['y']:g}"
            + ("|" + m["label"] if m["label"] else "")
            for m in markers
        ]
    else:
        lines = encode(markers)

    for line in lines:
        print(line)

    if not args.no_copy:
        if copy_to_clipboard("\n".join(lines)):
            print(f"\n已复制 {len(lines)} 条命令到剪贴板。切回游戏粘贴并回车即可。", file=sys.stderr)
        else:
            print("\n没有 pbcopy，未复制；请手动复制上面的命令。", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
