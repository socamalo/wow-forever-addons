# Changelog

## v1.10.1 — 2026-11-13

### Added

- 材料优先放进第五格材料包（`Enum.BagIndex.ReagentBag = 5`）：先塞材料包，
  满了或该包不收再从普通材料包；材料包内部也按材料子类排序。
- `tests/run_tests.py` 218 项；`tests/test_mcp.py` 14 项。

## v1.10.0 — 2026-11-13

### Added

- **自动分类分装**（默认开）：5 包时 0=炉石/任务/消耗品、1-2=装备、3=材料、
  4=杂项/工具/垃圾；4 包时 0=炉石/任务/消耗品、1=装备、2=材料、3=杂项/垃圾。
  只往空格搬，跨包不交换；类别超容量时溢出留在原包。
- `/daniel bagrole` 查看/开关分类分装。
- `tests/run_tests.py` 215 项；`tests/test_mcp.py` 14 项。

## v1.9.1 — 2026-11-13

### Changed

- 整理改为**每个背包单独排序 + 包内填洞**，不再把后面背包的物品搬到前面，
  保留玩家按背包分类的习惯。面板按钮/自动整理逻辑不变。
- `tests/run_tests.py` 208 项；`tests/test_mcp.py` 14 项。

## v1.9.0 — 2026-11-13

### Changed

- 整理**只按类别，不看价格**：炉石 → 任务 → 装备（部位/武器类型）→ 消耗品 →
  材料 → 配方 → 宝石/强化 → 其他 → 专业工具 → 灰色垃圾。
- 同一小类内按品质降序、物品 ID 升序；同物品多堆叠相邻。
- 移除「只按总价值」模式和 `/daniel sortmode`；升级装备不再单独占一类，只高亮。
- `tests/run_tests.py` 208 项；`tests/test_mcp.py` 14 项。

## v1.8.6 — 2026-11-11

### Fixed

- 护甲材质按布<皮<锁<板比较：皮甲可以自动换掉布甲（褐色毛护腕 3158 这类），
  低材质不会顶高材质。
- 新件没有职业属性时，装等更高或同装等品质更高也会换，解决纯护甲绿装不换的问题。
- `tests/run_tests.py` 207 项；`tests/test_mcp.py` 14 项。

## v1.8.5 — 2026-11-11

### Fixed

- 绿色及以上品质**永不自动出售**：红字绿装保留；`junkKeywords` 也只对白字/灰字生效。
- `tests/run_tests.py` 205 项；`tests/test_mcp.py` 14 项。

## v1.8.4 — 2026-11-11

### Changed

- 自动补弹药完全自动：`MERCHANT_SHOW` 硬件事件里立刻买，卖完再补一次，6 秒兜底；
  不需要任何 `/daniel ammo ...` 命令。目标仍为 2000（旧存档自动迁移）。
- `tests/run_tests.py` 203 项；`tests/test_mcp.py` 14 项。

## v1.8.3 — 2026-11-11

### Fixed

- 剥皮小刀等专业工具不再被识别为升级装备/高亮；分类排序降到 90（材料之后、垃圾之前）。
- 红字装备（`C_Item.IsUsableItem == false`）不参与升级识别、不自动穿、不高亮。
- 补弹药目标迁移到 2000，`/daniel ammo buy [叠数]` 可强制购买（v1.8.2 已包含）。
- `tests/run_tests.py` 202 项；`tests/test_mcp.py` 14 项。

## v1.8.2 — 2026-11-11

### Fixed

- 卖完自动整理：0.2s/1.2s 各排一次，关商人时再补一次；只剩 1 件物品时也整理，避免留洞。
- 补弹药目标默认 2000（旧存档 1000 自动迁移）；`/daniel ammo buy [叠数]` 可强制购买，
  即使当前数量已超目标。
- `tests/run_tests.py` 197 项；`tests/test_mcp.py` 14 项。

## v1.8.1 — 2026-11-11

### Fixed

- 自动补弹药：改用武器/弹药的 `subclassID`（弓 2、枪 3、弩 18；箭 2、子弹 3），
  不再依赖本地化 subtype；远程槽为空时用物品链接兜底；增加 `ammo.ranged/restock` 日志。
- 排序：炉石（6948）永远放第一格，分类/纯价值模式都生效。
- `tests/run_tests.py` 194 项；`tests/test_mcp.py` 14 项。

## v1.8.0 — 2026-11-11

### Added

- 自动维修：打开能维修的商人时自动 `RepairAllItems()`；钱不够先卖垃圾再重试；
  个人金币；面板开关 / `/daniel repair`。
- 自动卖关键词杂物：默认卖「破烂的皮革」，`/daniel junk` / `unjunk` 管理。
- 修正 schema 迁移顺序，确保旧存档也会重新打开自动换装。
- `tests/run_tests.py` 189 项；`tests/test_mcp.py` 14 项。

## v1.7.3 — 2026-11-11

### Changed

- **不再控制用户的 WoW**：禁用 `--type` / AppleScript 按键、鼠标、`/reload`、聊天命令注入。
  `agent_mark.py`、`agent_mark_watch.py`、MCP `DANIEL_MCP_INPUT=type` 都改为拒绝执行；
  只打印/复制命令或写队列，由用户手动操作。
- `tests/run_tests.py` 172 项；`tests/test_mcp.py` 14 项。

## v1.7.2 — 2026-11-11

### Added

- 无空格标记删除命令：`/rmbear`（Bjarn）、`/rmmang`（Mangeclaw）、`/markclear`（全部）。
- `tests/run_tests.py` 172 项；`tests/test_mcp.py` 14 项。

## v1.7.1 — 2026-11-11

### Fixed

- 整理后中间留空/反复开包顺序变化：
  - 同种物品堆叠不再互相交换（客户端会合并堆叠，交换会让位置模型失真）。
  - `GetContainerNumFreeSlots` 返回 `bagFamily=nil` 的未知专用包（箭袋等）不再当普通包使用。
  - 排序结束后再做一次“填洞”，把后面的物品搬进前面最早的空格。
- 新增 `/sortdebug` 打印每个包的类型/空闲格和整理后布局。
- `tests/run_tests.py` 170 项；`tests/test_mcp.py` 14 项。

## v1.7.0 — 2026-11-11

### Changed

- 自动换装重新开启（schema 8 迁移），修复旧存档里 `autoEquip=false` 一直不换装。
- BoE 保护收窄：只跳蓝/紫（quality>=3）装备后绑定；绿/白 BoE 自动穿。
- 新增 `/equipup`（无空格）和 `/daniel equipitem <ID>` 强制换装。
- `tests/run_tests.py` 160 项；`tests/test_mcp.py` 14 项。

## v1.6.9 — 2026-11-11

### Fixed

- 修正小地图垂直方向：WoW UI 的 y 正方向是“上”，北应显示在上方；
  地图/世界坐标投影和旋转一并修正。
- `tests/run_tests.py` 157 项；`tests/test_mcp.py` 14 项。

## v1.6.8 — 2026-11-11

### Changed

- 小地图边缘标记内缩到 85% 半径，避免大 pin 被圆形边缘裁掉。
- `tests/run_tests.py` 157 项；`tests/test_mcp.py` 14 项。

## v1.6.7 — 2026-11-11

### Fixed

- 小地图改用“地图归一化坐标 + `C_Map.GetMapWorldSize`”投影，避免 world 坐标方向/缩放导致标记位置漂移；
  仅显示当前地图上的标记；保留 world 坐标降级。
- 小地图 pin 显示距离数字。
- `tests/run_tests.py` 157 项；`tests/test_mcp.py` 14 项。

## v1.6.6 — 2026-11-11

### Changed

- 地图/小地图标记改为醒目样式：品红 Waypoint 大 pin + 呼吸光晕 + 金色名字/距离。
- 修复小地图 x 方向反了（WoW world x 向西增大，屏幕右方应取反）。
- 同坐标重复标记会更新标签而不是重复叠加。
- `tests/run_tests.py` 156 项；`tests/test_mcp.py` 14 项。

## v1.6.5 — 2026-11-11

### Added

- `/danielpet` 无空格快捷命令，等同于 `/daniel pet`，方便手柄/ConsolePort 输入。
- `tests/run_tests.py` 155 项；`tests/test_mcp.py` 14 项。

## v1.6.4 — 2026-11-11

### Fixed

- 空格格式支持“数字 mapID + 坐标”：`/daniel mark 1426 69.8 56.8` 不再把 1426 当成 x 坐标。
- `tests/run_tests.py` 154 项；`tests/test_mcp.py` 14 项。

## v1.6.3 — 2026-11-11

### Added

- `/daniel pet` 稀有宠物预设标记：Bjarn（丹莫罗 69.8,56.8，12 级稀有精英熊）、
  Mangeclaw（87.4,49.6，11 级稀有熊）。
- `tests/run_tests.py` 152 项；`tests/test_mcp.py` 14 项。

## v1.6.2 — 2026-11-11

### Removed

- 去掉猎人距离提示（包括屏幕小字、音效、`/daniel range`、`/daniel probe`）；
  `Range.lua` 保留在磁盘但不再由 TOC 加载。
- `tests/run_tests.py` 150 项；`tests/test_mcp.py` 14 项。

## v1.6.1 — 2026-11-11

### Fixed

- 自动卖红装前先检查装备：
  - 戒指/饰品/项链永不自售；
  - 护甲对应槽位为空时保留；
  - 剥皮小刀、矿工锄、铁匠锤、扳手、鱼竿、附魔棒等专业工具保留；
  - 可升级装备、远程武器、任务物品、黑名单保留。
- `tests/run_tests.py` 152 项；`tests/test_mcp.py` 14 项。

## v1.6.0 — 2026-11-11

### Added

- 自动卖红装：当前角色用不了的装备（等级/职业/护甲/武器熟练度）在商人处自动卖，
  远程武器、任务物品、黑名单物品保留；`/daniel redsell` 开关。
- 猎人自动补弹药：按远程武器判断箭/子弹，在商人处补到 `ammoTarget`（默认 1000），
  优先当前弹药，一次最多 20 叠、每次买一叠；`/daniel ammo ...` 命令。
- `tests/run_tests.py` 149 项；`tests/test_mcp.py` 14 项。

## v1.5.0 — 2026-11-10

### Changed

- 整理改为**按类别**：任务物品 → 升级装备 → 武器装备 → 消耗品 → 材料 →
  配方 → 宝石/强化 → 其他 → 灰色垃圾；同类别内按总售价降序。
- 开包自动整理优先在 `OpenBag` / `OnShow` 的硬件事件上下文同步执行，
  避免定时器里搬物品被客户端拦截；失败会提示并写日志。
- 面板「按类别整理」开关，`/daniel sortmode` 切换。
- `tests/run_tests.py` 133 项；`tests/test_mcp.py` 14 项。

## v1.4.0 — 2026-11-10

### Added

- 每次打开背包自动整理一次：`BAG_OPEN` / `BAG_CONTAINER_UPDATE` 防抖 0.6 秒，
  静默执行；战斗中排队到 `PLAYER_REGEN_ENABLED`；银行包不触发。
- 面板开关「每次打开背包自动整理」，`/daniel sortopen`。
- `tests/run_tests.py` 131 项；`tests/test_mcp.py` 14 项。

## v1.3.4 — 2026-11-10

### Added

- 状态导出包含当前标记 `markers[{id,map,x,y,label}]`，MCP 可直接确认 questmark 结果。

### Tests

- `tests/run_tests.py` 125 项；`tests/test_mcp.py` 14 项。

## v1.3.3 — 2026-11-10

### Changed

- `DANIEL1:` 自我密语在聊天框隐藏（`ChatFrame_AddMessageEventFilter`），
  `/chatlog` 仍照常写入；游戏内实测日志 49KB → 98KB，未被过滤器拦截。
- 任务坐标备用：先 `C_QuestLog.SetMapForQuestPOIs`，再
  `C_QuestLog.GetQuestsOnMap` 取 POI；`state.send` 日志新增 `poi=N`。
- `/daniel questmark` 也使用 POI 备用坐标。
- 新增 `/daniel state probe` / `channel` / `chat on|off` / `reset`。
- `tests/run_tests.py` 124 项；`tests/test_mcp.py` 14 项。

## v1.3.2 — 2026-11-10

### Fixed

- 自我密语目标：`UnitName` 只返回 `Shorty` 时不再刷屏；优先 `UnitFullName`，
  失败自动换 `GetUnitName(player,true)` / `UnitName`，全部失败切私有频道。
- 新增 `/daniel state names` 和 `/daniel state name <完整角色名>`。
- 系统提示“未找到名为…”会触发候选切换并写 `state.target_fail` 日志。

### Tests

- 新增密语目标候选、系统错误回退、私有频道回退测试。
- `tests/run_tests.py` 124 项；`tests/test_mcp.py` 14 项。

## v1.3.1 — 2026-11-10

### Changed

- 状态传输改为 v4 紧凑数组格式（短键），20 个任务约 2.2KB；MCP 端自动还原成可读对象。
- 默认状态间隔 20 秒；聊天分片间隔 1 秒，避免限速。
- `State.SendNow` 在上一帧未发完时只记 pending，避免多帧分片交错。

### Tests

- 新增 WorldMapFrame/Minimap pin、Highlight 覆盖层、面板与全部斜杠命令、
  Range widget、20 任务长状态、实例跳过、聊天失败的运行级测试。
- `tests/run_tests.py` 107 项；`tests/test_mcp.py` 14 项。

## v1.3.0 — 2026-11-10

### Added

- `State.lua`：任务/玩家状态导出（`zone`、`mapID`、坐标、任务 ID/标题/目标/`GetNextWaypoint`）。
- 自我密语分片协议 `DANIEL1:<sid>:<seq>/<total>:<chunk>` → `Logs/WoWChatLog.txt`。
- `/daniel state`、`/daniel quests`、`/daniel questmark [id|all]`、`state auto/log/interval`。
- `tools/state_reader.py`：聊天日志 → 重组状态 JSON。
- `tools/daniel_mcp.py`：本地 stdio MCP（`get_game_state`、`get_quests`、`add_marker`、`mark_quest_next` 等）。
- `tools/agent_loop.py`：机械版“状态 → 任务 next → 队列”loop 演示。
- `tools/mcp-config.example.json`；本机已注册 `daniel-wow` MCP。
- 实例内状态暂停保护（`state.skip_instance`）。

## v1.2.0 — 2026-11-10

### Added

- 地图标记系统：`MarkerCore.lua` + `Markers.lua`。
  - `/daniel mark`、`markbatch`、`mark list/clear/remove/goto`、`mapfind`。
  - 世界地图画布 pin + 小地图 pin，多个标记，点击设暴雪路径点。
  - `DanielAddonAPI` 公开 API。
- `tools/agent_mark.py` / `agent_mark_watch.py`：agent 坐标 → 聊天命令 → 游戏。
- 结构化日志 `Log.lua`：400 条环形缓冲、`/daniel diag`、拦截事件记录。
- `tools/log_to_fixture.py`：SavedVariables → JSON fixture。
- `tests/run_tests.py`：Python + lupa 单测。

## v1.1.0 — 2026-11-10

### Added

- 自动换装改走 `C_Item.EquipItemByName`（非 protected），`UseContainerItem` 仅手动兜底。
- 背包升级装备绿色光晕 + 箭头 + tooltip 比较。
- BoE（Bind on Equip）自动跳过；`/daniel ignore/unignore`。
- `tests/harness.py`、升级/自动换装/BoE/黑名单测试。

## v1.0.0 — 2026-11-10

### Added

- 自动卖灰色垃圾、按售价整理背包。
- 装备升级识别（职业权重 / 武器秒伤 / 槽位规则）。
- 猎人距离提示。
- 面板、斜杠命令、插件隔舱入口。
