# Daniel 背包管家（DanielAddon）

自用插件：自动卖灰色垃圾、按售价整理背包、自动换上属性更好的装备并在背包里高亮，
外加 agent 地图标记、结构化日志和可单测的 Lua 核心。

- 客户端：World of Warcraft: Forever，`## Interface: 16001`
- 只读背包数据 + 商人框卖货，不碰战斗、不读战斗日志、不写任何 secure 属性

## 用法

- `/daniel` 或 `/ds`：开关面板（也可点小地图旁的插件隔舱）
- `/daniel sell`：立刻卖垃圾（需要站在商人面前）
- `/daniel sort`：立刻按类别整理
- `/daniel redsell`：开关「自动卖红装（远程武器除外）」
- `/daniel repair`：开关「在能修的商人处自动维修」
- `/daniel junk <关键词>` / `unjunk <关键词>`：增删白字/绿字自动卖关键词（默认含「破烂的皮革」）
- `/daniel ammo`：查看弹药状态；`ammo auto on|off`、`ammo target <数量>`、`ammo item <ID>`、`ammo buy [叠数]`（强制买，即使已超目标）
- `/daniel pet`：标记附近稀有宠物（Bjarn / Mangeclaw）；`pet bjarn`、`pet mangeclaw`
- `/danielpet`：无空格快捷命令，等同于 `/daniel pet`（手柄/ConsolePort 友好）
- `/rmbear` / `/rmmang` / `/markclear`：无空格删除 Bjarn / Mangeclaw / 全部标记
- `/daniel sortdebug`（或 `/sortdebug`）：打印每个包的类型/空闲格和整理后的实际布局
- `/daniel bagrole`：查看/开关自动分类分装（默认开）
- `/daniel sortopen`：开关「每次打开背包自动整理」
- `/daniel upgrade`：列出背包里能升级的装备
- `/daniel equip`：立刻换上所有升级（手动路径；BoE（Bind on Equip，装备后绑定）也照换）
- `/daniel equipitem <物品ID>`：强制穿指定物品（不看评分/BoE）
- `/equipup`：无空格快捷命令，等同于 `/daniel equip`
- `/daniel highlight`：开关背包升级高亮
- `/daniel ignore <物品ID>` / `/daniel unignore <物品ID>`：忽略/恢复某件装备
- `/daniel mark <zone>|<x>|<y>|<label>`：加地图标记（也支持空格分隔）
- `/daniel mark list` / `clear` / `remove <id>` / `goto <id>`：管理标记
- `/daniel markbatch ...`：一次加多个标记
- `/daniel mapfind <名字>`：查地图名对应的 mapID
- `/daniel state`：立刻导出游戏状态并打印任务摘要
- `/daniel quests`：打印当前任务 + 下一步路径点
- `/daniel questmark [任务ID|all]`：把任务下一步路径点加进地图标记
- `/daniel state auto on|off` / `state log on|off` / `state interval <秒>`：状态导出开关
- `/daniel diag`：采集本机 API/地图/小地图事实并写入日志
- `/daniel log on|off|chat on|off|dump [N]|clear`：结构化日志
- `/daniel value`：播报背包总售价
- `/daniel status`：查看各项开关、标记数与换装接口

面板上的勾选：

| 选项 | 默认 | 作用 |
|---|---|---|
| 自动卖垃圾 | 开 | `MERCHANT_SHOW` 时自动卖灰色物品 |
| 卖完后按类别整理 | 开 | 卖完自动排序；不想每次开商人都被重排就关掉 |
| 每次打开背包自动整理 | 开 | 打开背包时静默排序；战斗中排队到脱战 |
| 按类别整理（重要在前） | 开 | 任务物品 → 升级装备 → 装备 → 消耗品 → 材料 → 配方 → 其他 → 垃圾 |
| 自动卖红装（远程武器除外） | 开 | 当前角色用不了的装备（等级/职业/护甲/武器）自动卖；远程武器、任务物品、黑名单保留 |
| 自动维修（能修的商人） | 开 | 打开能维修的商人/修理 NPC 时自动修全身；钱不够先卖垃圾再修 |
| 自动卖关键词杂物 | 开 | 默认卖「破烂的皮革」；`/daniel junk` 可加自己的白字杂物 |
| 自动补弹药（猎人） | 开 | 在商人处把当前箭/子弹补到 1000；可用 `/daniel ammo target` 改 |
| 自动穿更好的装备 | 开 | 背包变化 2 秒后自动换；战斗中等到出战斗 |
| 背包里高亮升级装备 | 开 | 绿色光晕 + 绿色箭头，tooltip 里写替换对比 |
| 自动换装跳过装备后绑定 | 开 | 避免把值钱的 BoE 误绑到身上；手动按钮不受影响 |
| 显示小地图标记 | 开 | agent 标记同时画在世界地图和小地图上 |

## 规则

- **垃圾** = 品质为灰色（Poor）、商人收购（`hasNoValue` 为假）、且没被锁定的物品。
  黑色名单在存档里：`DanielAddonDB.blacklist[itemID] = true`。
- **价值** = `C_Item.GetItemInfo(itemID)` 的第 11 个返回值（单价）× 堆叠数量。
  插件没有拍卖行/TSM 数据，所以"贵"用的是**商人售价**，不是市场价。
- **只在自己的通用包之间搬**（`GetContainerNumFreeSlots` 返回 family 为 0 的包）。
  草药包、箭袋、灵魂袋这类专用包不参与，避免物品塞不进去。
- 排序是"把物品压到最前面那几格"，空格统一留在后面。
- **自动维修**：打开能维修的商人窗口时，先检查 `CanMerchantRepair()` 和
  `GetRepairAllCost()`；钱够就 `RepairAllItems()`，钱不够会先卖垃圾，卖完自动重试一次。
  只用个人金币，不动公会银行。**不会自动跑过去点 NPC**，需要你打开维修商。
- **自动卖关键词杂物**：白字/绿字但名字命中 `junkKeywords` 的物品也当垃圾卖。
  默认包含「破烂的皮革 / Ruined Leather Scraps」；只对白字/灰字生效，
  绿色及以上、任务物品和黑名单永远不卖。
  `/daniel junk 名字` 添加，`/daniel unjunk 名字` 删除，`/daniel junk` 查看。
- **售卖后整理**：卖完 0.2 秒、1.2 秒各排一次；关闭商人时如果卖过东西也会在硬件事件里补排一次。
  每个包内部填洞，不会跨包搬，也不留空洞。
- **整理稳定性**：同种物品的堆叠不会互相交换（客户端会合并堆叠，交换会破坏位置模型）；
  `bagFamily=nil` 的未知专用包（箭袋、专业包等）一律跳过；排序最后会把后面的物品
  填进前面最早的空格，尽量保证中间不留洞。
- **自动卖红装**：先检查装备，再决定卖不卖：
  - 戒指、饰品、项链**永不自售**；
  - 护甲对应槽位还空着（比如没戴戒指/胸甲）就留着；
  - 专业工具（剥皮小刀、矿工锄、铁匠锤、扳手、鱼竿、附魔棒等）不卖；
  - 远程武器、任务物品、`/daniel ignore` 黑名单不卖；
  - 只有"当前槽位已有装备 + 这件确实用不了"才卖。
  **绿色及以上品质永远不自动卖**（红字的绿装也保留）；只自动卖白字/灰字。
  卖错可在商人"回购"页买回。
- **自动补弹药（无需命令）**：只对猎人生效。打开能卖箭/子弹的商人时立刻自动买，用武器 **subclassID** 判断：弓(2)/弩(18) → 箭，
  枪(3) → 子弹；弹药同样用 subclassID 判断：箭(2)/子弹(3)，不依赖本地化名称。
  买完自动卖货后再补一次，6 秒兜底
  `ammoTarget`（默认 2000）；优先补当前携带的同一种弹药，没有就买商人最便宜的同类。
  一次最多 20 叠，每次按“一叠”购买，避免不同客户端对 quantity 解释不同。
- **自动分类分装（默认开）**：不同类别会挪到不同背包：
  - 5 个包：0 号放炉石/任务/消耗品，1-2 号放装备，3 号放材料，4 号放杂项/专业工具/垃圾；
  - 4 个包：0 号炉石/任务/消耗品，1 号装备，2 号材料，3 号杂项/垃圾。
  某个类别超过它分到的包容量时，多出来的留在原包，不会硬塞进别的类别包。
- **材料优先放材料包（第五格 reagent bag）**：布/皮/矿/草等材料先塞满材料包，
  放不下（或材料包不收这种物品）再进 3 号普通材料包。材料包内部也会按材料子类排序。
- **每个背包内部单独排序**：分装完成后只整理包内顺序，不再跨包搬，不会"全部从前到后"。
- **包内只按类别，不看价格**：炉石 → 任务物品 → 武器装备（按部位/武器类型）→
  消耗品 → 材料 → 配方 → 宝石/强化 → 其他 → 专业工具 → 灰色垃圾。
  同一小类内按品质降序、物品 ID 升序；同物品的多个堆叠放一起。
  升级装备不再单独占一类，只在背包里高亮。

## 实现依据（都来自本机客户端里能跑的插件）

- 卖货：`Baganator/Transfers/VendorItems.lua` —— `ClearCursor()` → `C_Container.PickupContainerItem(bag, slot)` → `SellCursorItem()`
- 换位：`Baganator/Sorting/OrderBags.lua` —— 两次 `PickupContainerItem` + `ClearCursor()`
- 卖价字段：`Questie/Modules/QuestieDebugOffer.lua` —— `GetItemInfo` 第 11 个返回值为 `sellPrice`

## 进游戏要实测的事

1. **自动卖垃圾**：站在商人面前，看灰色物品是否被卖光、聊天框是否报收入。
2. **自动整理**：卖完后看背包顺序对不对。若客户端拦截了非点击触发的物品移动，
   插件会提示"自动整理好像被客户端拦住了"——点面板上的「按类别整理」（真实鼠标点击）
   作为兜底路径。
3. **自动换装**：拾取一件属性更好的装备，等 2 秒看是否自动穿上、聊天框是否报
   「自动换上了 N 件」。如果报「客户端拦住了后台自动换装」，说明这台客户端
   对 `C_Item.EquipItemByName` 还有额外限制，此时绿色高亮 + 面板按钮仍可用。
4. **高亮**：打开背包，升级装备格应有绿色光晕与箭头；悬停 tooltip 应有「↑ 升级」行。
5. **`/daniel status` 最后一段**应显示「换装接口：EquipItemByName」。
6. **地图标记**：`/daniel mark 铁炉堡|55.2|47.8|测试`，打开世界地图和小地图看两个黄点；
   再 `mark list` / `mark clear`。重点看小地图点的方位与距离是否和游戏内实际方向一致。
7. **日志**：`/daniel diag` → `/daniel log dump 5`；`/reload` 后在
   `WTF/Account/<账号>/SavedVariables/DanielAddon.lua` 里应能看到 `DanielAddonDB.logs` 和 `markers`。
8. **agent 桥**：跑 `tools/agent_mark.py --marker "铁炉堡|55.2|47.8|测试"`，粘贴到聊天框回车。
9. **状态出口**：`/daniel state` 后看 `Logs/WoWChatLog.txt`（或 `Logs/General/`）里有没有
   `DANIEL1:` 行；有则 MCP 能读，没有则自我密语被拦，需要改用像素协议。
10. **任务标记**：`/daniel questmark all` 看是否为每个任务标出下一步；没有坐标的任务会跳过。
11. **MCP**：重启 Claude Code 后 `claude mcp list` 应有 `daniel-wow`，调 `get_game_state`；
   再跑 `tools/agent_mark_watch.py --file ~/daniel-markers.json`，把打印出的命令手动粘贴进游戏。

## 装备替换

- **识别**：背包里装等更高的同类装备会被列出来，面板按钮显示件数（`/daniel upgrade` 看清单）。
- **比较规则**：
  - 护甲按材质等级：布 < 皮 < 锁 < 板。高材质可以顶低材质（皮甲可换布甲），
    低材质不能顶高材质；同材质再比属性分/装等。
  - 新件没有任何职业属性（例如纯护甲的绿装护腕）时，装等更高或同装等品质更高就换。
  - **武器比真实秒伤**：从物品 tooltip 的「每秒伤害 / damage per second」行读取
    （客户端没有每秒伤害（Damage Per Second, DPS）API）。
    秒伤读不到时才退回装等；只有一边读到时不硬比。
  - **武器允许跨手别**：单手可以顶掉身上的双手，双手也可以顶掉单手+盾。
    换双手时客户端会把副手（盾/副手武器）退回背包，消息里会说明。
  - 盾牌/副手只往副手槽建议，且要求主手是单手武器。
  - 戒指/饰品选当前更弱的那个槽位；单手武器先补主手，换下来的旧武器下一轮可以进副手。
  - 会用 `C_Item.IsEquippableItem` 和需求等级过滤，角色穿不了的不会被选中。
  - 物品数据没缓存时会自动重试一次，不会因为刚拾取就漏判。
- **诊断**：`/daniel why <物品ID>` 或 `/daniel why` 后 shift 贴物品链接，
  会打印该物品的装等/秒伤/槽位/当前装备对比，直接看出为什么没换。
- **高亮**：背包里能升级的物品显示绿色光晕 + 左上角绿色箭头；
  鼠标悬停的 tooltip 会多一行「↑ 升级（替换 XXX）」和装等/秒伤变化。
- **换装执行**：优先 `C_Item.EquipItemByName(itemID, dstSlot)`。Forever 的生成文档里
  这个函数只标了 `SecretArguments`、没有 `protected`，所以出战斗后后台事件也能穿。
  `C_Container.UseContainerItem` 是明确的受保护函数（只能安全代码调用），
  仅在手动点击时作为兜底。
- **自动换装**：`BAG_UPDATE` 后延迟 2 秒扫描，出战斗才执行；战斗中的升级会等到
  `PLAYER_REGEN_ENABLED` 再补。连续两次后台失败会自动关掉开关并提示。
- **BoE 保护**：自动模式默认跳过「装备后绑定」的物品（`bindType == 2`），
  因为换上去就会绑定；手动点按钮不跳过。`/daniel ignore <ID>` 可永久忽略某件装备。
- **已知局限**：没有天赋流派/套装/命中阈值的判断；属性权重只有战士和猎人。

## 地图标记（agent 桥）

**先说明物理限制**：WoW 插件不能读文件、不能联网、没有独立进程，所以 agent 不能真的“推送”数据进游戏。
可行的实时通道是**聊天命令**：agent 把坐标整理成 `/daniel markbatch ...`，默认复制到剪贴板，
你切回游戏粘贴一次即可。**脚本不会控制你的 WoW**：不会自动按键、鼠标或输入聊天命令。

命令格式：

```text
/daniel mark 铁炉堡|55.2|47.8|武器大师
/daniel mark 铁炉堡 55.2 47.8 武器大师
/daniel markbatch 铁炉堡|55.2|47.8|武器大师;铁炉堡|56.1|48.5|训练师
```

- 坐标接受 `55.2`（百分比）或 `0.552`；zone 可以写中文名、英文城市名（Ironforge 等别名）、mapID，
  或者省略 zone 表示当前地图。
- 地图名有歧义时用 `/daniel mapfind <名字>` 查 mapID，再写数字。
- 标记会同时画在 **WorldMapFrame 画布**和 **小地图**上；多个标记互不覆盖，超出小地图视野的会贴边显示。
- 点世界地图或小地图上的点，会把它设成暴雪自己的用户路径点（`C_Map.SetUserWaypoint`）。
- 标记存进 SavedVariables，重登后仍在；`/daniel mark clear` 清空。

agent 侧桥接脚本：

```bash
# 查完坐标后（默认复制到剪贴板）
uv run python -I tools/agent_mark.py \
  --marker "铁炉堡|55.2|47.8|武器大师" \
  --marker "铁炉堡|56.1|48.5|训练师"

# 从 JSON 批量（只打印/复制，不输入游戏）
uv run python -I tools/agent_mark.py --json markers.json

# 监视 markers.json，变化时打印/复制新命令；由你手动粘贴
uv run python -I tools/agent_mark_watch.py --file markers.json
```

`--type` 已禁用：不会用 AppleScript/System Events 控制你的 WoW。Watcher 也不会开机自启。

给游戏内其它插件用的公开 API（不需要聊天命令）：

```lua
DanielAddonAPI.AddMarker("铁炉堡", 55.2, 47.8, "武器大师")
DanielAddonAPI.AddMarkers({ {zone="铁炉堡", x=56, y=48.5, label="训练师"} })
DanielAddonAPI.ClearMarkers()
DanielAddonAPI.ListMarkers()
DanielAddonAPI.SetWaypoint(id)
```

### 已有的实现（Tavily 搜索结果）

- **xeR's Forever Navigation & Waypoints**：多路径点、路线规划、External Waypoint API，
  是完整的导航套件；面向游戏内 companion addon，不是聊天/agent 桥。
- **PartyPins**：无限 pin + 队伍共享。
- **TomTom**：`/way` 多路径点；搜索结果里有 Forever 上
  `Blizzard_MapCanvas ... AcquirePin OnLoad nil` 的报错报告，且是额外依赖。
- **wow-context-bridge**：用屏幕像素协议把插件内数据传给外部程序；方向是 addon→外部，
  反过来外部→addon 没有通道。

本插件保留自己的标记器：无依赖、同时适配默认地图/小地图、命令协议适合 agent 粘贴、
并且有日志、MCP 接口和 117+14 项断言覆盖。

## Agent 闭环（状态 → 决策 → 标记）

目标：一个本地 agent 陪玩，知道你在哪个图、在做什么任务、下一步去哪，并主动把点标出来。

```text
┌──────────────── WoW ────────────────┐
│ DanielAddon                         │
│  C_QuestLog + 玩家坐标              │
│      │ 自我密语 DANIEL1:...         │
│      ▼                              │
│  Logs/WoWChatLog.txt                │
│      ▲                              │
│      │ /daniel markbatch ...        │
│  markers.json（用户手动执行）       │
└─────────────────────────────────────┘
        │ 读文本                    ▲ 写队列
        ▼                          │
   daniel_mcp.py (本地 stdio MCP) ──┘
        ▲
        │ tools
   Claude / 其它 agent
```

- **状态出口**：`State.lua` 每 20 秒（任务/区域变化时立刻）把
  `{zone, mapID, player{x,y,wx,wy}, quests[{id,title,level,tag,complete,next{map,x,y},objectives[]}]}`
  编成 JSON，按 UTF-8 边界切成 ≤170 字节的片段，用 `DANIEL1:<sid>:<seq>/<total>:<chunk>`
  通过**对自己的密语**发出去；客户端 `/chatlog` 写入 `Logs/WoWChatLog.txt`。
  插件在登录时自动 `LoggingChat(true)`。
- **状态入口**：MCP 的 `add_marker` / `mark_quest_next` / `clear_markers` 写
  `~/daniel-markers.json`；`agent_mark_watch.py` 监视文件并打印命令，由你手动粘贴进游戏。
- **任务坐标**：优先用 `C_QuestLog.GetNextWaypoint(questID)`（返回 mapID,x,y）；
  没有坐标的任务由 agent 用外部数据库查，再 `add_marker`。
- **完整 loop**：agent 调 `get_game_state` → 看到任务/位置 → 决定下一步 →
  `add_marker` 或 `mark_quest_next` → watcher 输入 → 玩家看到地图/小地图 pin。
  也可以定时轮询 `get_game_state(wait_seconds=...)` 做主动提示。
- **机械 loop 演示**：`tools/agent_loop.py` 不做 LLM 推理，只把每个任务的 next 路径点
  自动写进队列，用来验证“状态 → 标记 → 游戏”整条链路；真正的陪玩决策走 MCP。

### 本地 MCP 配置

```bash
claude mcp add daniel-wow -- \
  uv run --with mcp python -I "/Volumes/Extra/Games/World of Warcraft/_forever_/Interface/AddOns/DanielAddon/tools/daniel_mcp.py"
```

或使用 `tools/mcp-config.example.json`。常用环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `DANIEL_CHATLOG` | 自动找 `Logs/**/WoWChatLog.txt` | 状态日志路径 |
| `DANIEL_QUEUE` | `~/daniel-markers.json` | 标记/命令队列 |
| `DANIEL_MCP_INPUT` | `file` | `file` 写队列；`clipboard` 复制；`type` 已禁用 |
| `DANIEL_WOW_APP` | `World of Warcraft` | 游戏应用名 |

MCP 工具：`refresh_state`、`get_game_state`、`get_quests`、`get_player`、`add_marker`、`add_markers`、
`clear_markers`、`mark_quest_next`、`mark_all_quests`、`diagnose`、`set_state_auto`。

配套 watcher（由你手动启动；只打印/复制，不输入游戏）：

```bash
uv run python -I tools/agent_mark_watch.py --file ~/daniel-markers.json
```

> 限制：WoW 插件没有文件/网络 IO，所以状态是“插件 → 聊天日志 → 本地文件”的只读通道；
> 反向只能靠聊天命令/系统输入。自我密语会出现在聊天框里，介意的话可以后续加聊天过滤器。
> `GetNextWaypoint` 对部分任务没有坐标，需要 agent 外部补全。
> **副本/团本内**：Midnight 规则禁止插件发送聊天通信，状态导出会暂停（`state.skip_instance`），
> 出本后自动恢复；MCP 端看 `age_seconds` 变大 / `fresh=false`。
>
> 本机已经注册了本地 MCP：`claude mcp list` 里能看到 `daniel-wow`。
> 当前会话是中途注册的，需要重开 Claude Code 才会出现 `mcp__daniel-wow__*` 工具。

## 日志与自诊断

- 关键原始数据自动写进 `DanielAddonDB.logs`（环形缓冲 400 条）：
  客户端 build、每条命令、换装候选/结果、BoE 跳过、标记增删、`ADDON_ACTION_BLOCKED` 等。
- 日志不写文件系统（插件没有 IO），而是随 SavedVariables 落盘：
  `WTF/Account/<账号>/SavedVariables/DanielAddon.lua`；`/reload` 或退出后更新。
- `/daniel diag` 会把 build、项目 ID、`C_Item` / `C_Map` / `C_Minimap` 函数是否存在、
  玩家地图坐标、`GetWorldPosFromMapPos` 原始返回、WorldMapFrame / Minimap 状态一次性记下来。
- 用法：`/daniel log dump 20` 看最近 20 条；`/daniel log chat on` 边玩边在聊天框看。
- 把日志变成开发环境 fixture：
  ```bash
  uv run --with lupa python -I tools/log_to_fixture.py --summary
  uv run --with lupa python -I tools/log_to_fixture.py \
      --out tests/fixtures/session-2026-11-10.json
  ```
  脚本在去掉 `os/io/require/loadfile` 的 Lua 沙箱里读 SavedVariables，只导出数据，不执行文件操作。

## 测试（TDD）

Lua 在 WoW 里没有内建测试框架；本插件用 **Python + lupa** 把真实 `.lua` 代码加载进桩环境跑断言：

```bash
cd "/Volumes/Extra/Games/World of Warcraft/_forever_/Interface/AddOns/DanielAddon"
uv run --with lupa python -I tests/run_tests.py
```

覆盖：Lua 语法、标记解析（管道/空格/批量/非法输入）、地图名与别名解析、标记存储/去重/删除/
跨图坐标换算、小地图投影与旋转、日志环形缓冲/循环表清洗、自动换装与 BoE 跳过、斜杠命令路由、
`/daniel diag`、SavedVariables → JSON fixture、状态 JSON 分片 → 聊天日志 → MCP 重装。
当前 `tests/run_tests.py` 218 项断言、`tests/test_mcp.py` 14 项断言全过。

新增功能时的顺序：先写/改测试 → 跑红 → 改代码 → 跑绿 → commit。

## 版本控制

本目录是 git 仓库（`main` 分支）。每完成一个可验证的小功能或修复就提交，提交前必须跑上面的测试
和语法检查；提交信息用 `feat:` / `fix:` / `test:` / `log:` / `docs:` / `chore:` 前缀。
详细规则同步写在 `~/.claude/skills/wow-forever-addon/SKILL.md`。

## 和 Baganator 的关系

> 当前 Baganator 已移到 `Interface/Baganator` 作为参考代码，不在 `AddOns` 里，不会被加载。
> 下面是以后装回时的注意事项。

- **不抢卖**：Baganator 不注册 `MERCHANT_SHOW`，没有自动卖货，只在你点它的转移按钮时卖。
  本插件只在开商人时自动卖灰装；两边的垃圾判定各自独立，没有共享状态。
- **不抢排序，但规则不同**：Baganator 的排序按钮走 `C_Container.SortBags()`（暴雪规则）。
  如果你点了它的排序，会把"按售价"的顺序推翻成"按类型"。两个排序谁最后跑谁说了算。
- **别同时点**：Baganator 的整理/合堆会跨帧连续移动物品（`SortStatus.WaitingMove`）。
  它跑到一半时本插件插进去搬格子，它的移动队列就会指向旧位置。
  本插件的自动整理只在开商人时触发，正常情况下碰不到。
- 两边都用 `PickupContainerItem`，本插件在每次移动前会读 `isLocked`；
  玩家手上正拿着东西时会等待而不是 `ClearCursor`，不会打断拖拽。
- Baganator 的视图要处于"单背包（single）"才看得出格子顺序；分类视图下排序结果不会显示成顺序。

## 文件

- `DanielAddon.toc`：加载清单，`Interface: 16001`
- `Core.lua`：存档、背包遍历、售价查询、总值
- `Log.lua`：结构化日志、`/daniel diag`、拦截事件记录
- `MarkerCore.lua`：标记解析、地图名解析、存储、world/map 坐标换算（纯逻辑，可单测）
- `Markers.lua`：世界地图 pin、小地图 pin、点击设路径点
- `State.lua`：任务/玩家状态 JSON、自我密语分片、`/daniel state`、questmark
- `Sell.lua`：自动卖垃圾（每轮 6 件，0.5 秒一轮，最多 40 轮）
- `Sort.lua`：分类/价值排序，跳同种堆叠与专用包，最后填洞
- `Upgrade.lua`：升级识别、比较规则、自动/手动换装
- `Highlight.lua`：背包物品格绿色高亮与 tooltip 升级提示
- `UI.lua`：面板、斜杠命令、插件隔舱入口
- `tests/`：Python + lupa 单元测试（`run_tests.py`、`harness.py`、fixtures）
- `tools/agent_mark.py`：agent 坐标 → 聊天标记命令（剪贴板，不输入游戏）
- `tools/agent_mark_watch.py`：监视 `markers.json`，变化时打印/复制命令（不输入游戏）
- `tools/state_reader.py`：解析聊天日志里的 `DANIEL1` 分片
- `tools/daniel_mcp.py`：本地 MCP server（状态读取 + 标记/任务命令）
- `tools/agent_loop.py`：机械版陪玩 loop（状态→任务 next→队列），不是 LLM
- `tools/mcp-config.example.json`：MCP 客户端配置示例
- `tools/log_to_fixture.py`：SavedVariables 日志 → JSON fixture
- `tests/test_mcp.py`：MCP 工具/队列测试（`uv run --with mcp python -I tests/test_mcp.py`）
