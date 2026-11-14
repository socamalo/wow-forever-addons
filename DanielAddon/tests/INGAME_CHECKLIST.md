# 游戏内测试清单（2026-11-10）

安装路径：
`/Volumes/Extra/Games/World of Warcraft/_forever_/Interface/AddOns/DanielAddon/`

## 0. 启动前

```bash
cd "/Volumes/Extra/Games/World of Warcraft/_forever_/Interface/AddOns/DanielAddon"
./tests/run_all.sh          # 本地 106 + 14 项断言
```

- 客户端里启用 `Daniel 背包管家`。
- 新文件较多，建议**完整重启客户端**（不是只 `/reload`）。

## 1. 基础加载

```text
/daniel status
```

应看到：自动卖垃圾/整理/换装、升级高亮、小地图标记、日志、状态导出、
`换装接口：EquipItemByName`。

```text
/daniel log dump 5
```

应至少有 `session.start`，并且没有红字报错。

## 2. 状态出口（最关键）

```text
/daniel state
/daniel quests
```

然后在本机运行：

```bash
uv run python -I tools/state_reader.py
```

期望：

- 打印 `chatlog: /Volumes/.../Logs/.../WoWChatLog.txt`
- 打印 `zone`、`mapID`、`player`、`quests`
- 每个任务有 `id/title/level`；有坐标的任务有 `next{map,x,y}`

先用两条 `/run` 隔离通道问题：

```text
/run print("chatlog", IsLoggingChat()); print("instance", IsInInstance())
/run print("send", pcall(SendChatMessage, "DANIEL1:probe", "WHISPER", nil, UnitName("player")))
```

然后在 `WoWChatLog.txt` 里搜 `DANIEL1:probe`：
- 有：通道 OK，问题在插件分片/读取。
- 没有但 `send=true`：密语没进日志，需要换出口。
- `send=false`：SendChatMessage 被拦，需要像素协议。

如果 `chatlog: None` 或没有 `DANIEL1` 状态：

1. 手动 `/chatlog` 再 `/daniel state`；
2. 看 `Logs/**/WoWChatLog.txt` 是否存在；
3. 把 `/daniel log dump 20` 的输出发回来。
4. 若自我密语被拦，下一步会做屏幕像素协议出口。

## 3. 地图/小地图标记

```text
/daniel mark 铁炉堡|55.2|47.8|武器大师
/daniel markbatch 铁炉堡|56|48.5|训练师;铁炉堡|57|49|旅店老板
/daniel mark list
```

检查：

- 打开世界地图到铁炉堡：3 个黄点，label 正确。
- 小地图：黄点方位与实际方向一致；超出视野贴边。
- 点击黄点：设为暴雪路径点。
- `/daniel mark clear` 清空。
- `/daniel questmark all`：为任务下一步加标记。

## 4. 自动换装 / 高亮

- 拾取一件属性更好的装备，等 2 秒，看是否自动穿上、聊天框报「自动换上了 N 件」。
- 如果是 BoE（装备后绑定），自动模式应跳过并提示；手动点面板按钮应照换。
- 打开背包：升级装备格有绿色光晕 + 箭头；悬停 tooltip 有「↑ 升级」行。
- `/daniel ignore <物品ID>` 后不再识别。

## 5. MCP

重启 Claude Code（让 MCP 工具加载），然后：

```bash
claude mcp list          # daniel-wow 应为 Connected
```

在 Claude 里调用：

```text
get_game_state
get_quests
refresh_state
add_marker("铁炉堡", 55.2, 47.8, "测试")
mark_quest_next(0)
```

输入侧二选一：

```bash
# A. 手动：MCP 写的命令在 ~/daniel-markers.json，watcher 复制/输入
uv run python -I tools/agent_mark_watch.py --file ~/daniel-markers.json --type

# B. 只看不输入
uv run python -I tools/agent_mark_watch.py --file ~/daniel-markers.json --no-copy
```

检查：`add_marker` 后游戏里是否出现 pin；`mark_quest_next` 是否标出任务下一步。

## 6. 如果出问题，收集这些

```text
/daniel diag
/daniel log dump 30
```

```bash
# 状态重组
uv run python -I tools/state_reader.py

# SavedVariables → fixture（退出游戏或 /reload 后）
uv run --with lupa python -I tools/log_to_fixture.py --summary
```

把以上输出，以及报错截图/`Interface action failed because of an AddOn` 计数发回来。
