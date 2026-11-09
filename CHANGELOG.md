# Equipment Control 修改记录

## 2026-10-26 — 巨石躲避移植 + 多语言拆分 + 滑条修复

### 巨石躲避（Boulder Dodger）

移植 workshop-3767257007（Boulder Dodger）到 `scripts/Auto/boulderdodge.lua`，
岩石树（Boulderbough）即将砸下巨石时自动走开躲避：

- 双路危险检测：实况坠落动画（`fall_pre` / `fall_miss` / `fall_bounce`）+
  预测（致命刀动画第 5 帧设 1 秒过期窗口）
- 12 角度放射状安全点寻路：从威胁中心向 12 个方向搜索可达位置
- 砍伐计数自学习：按斧头类型分别记录"几刀砍倒"，阈值 = 计数 − 躲闪余量
- 手杖自动切装 / 手动移动覆盖（打断躲避流程）
- `TUNING.TREE_ROCK` 不存在时兜底 `{ROCK1_AOE_RADIUS=3, ROCK2_AOE_RADIUS=4}`

配置项：

| 键 | 默认值 | 说明 |
|----|--------|------|
| `BOULDER_DODGE` | `true` | 总开关 |
| `DODGE_MARGIN` | `1.0` | 躲避余量（0–3，步进 0.5） |
| `DODGE_MANUAL_OVERRIDE` | `true` | 手动移动覆盖 |
| `DODGE_USE_CANE` | `false` | 自动切手杖加速 |
| `DODGE_CHOPS_OVERRIDE` | `0` | 砍倒刀数（0=自动学习） |

### 多语言拆分

`scripts/equipment_control_strings.lua` → `scripts/language/` 目录：

| 文件 | 说明 |
|------|------|
| `language/chinese_s.lua` | 简体中文，`return { CONFIG = {...}, HOVERS = {...} }` |
| `language/english.lua` | 英文兜底，同上结构 |

`modimport` 按 `Language` 动态加载对应文件并写入 `STRINGS.EQUIPMENT_CONTROL`，
命名规范与游戏本体（`chinese_s.po` / `english.po` 等）一致。

### 滑条修复

巨石躲避在 `confighud.lua` 中有两个滑条（`DODGE_MARGIN` 和 `DODGE_CHOPS_OVERRIDE`），
上线后三次崩溃，根因链：

| 次序 | 错误 | 根因 |
|------|------|------|
| 1 | `variable 'Language' is not declared` | `label_format` 直接访问 `Language`；`confighud.lua` 走 `require`（非 `modimport`），strict 模式无该变量 |
| 2 | `variable 'GLOBAL' is not declared` | 改用 `GLOBAL.Language`；`GLOBAL` 同样不在 `require` 环境的全局表 |
| 3 | `attempt to index field 'STRINGS' (a nil value)` | 语言文件是 `return {...}` 格式，`modimport` 的返回值未被赋值给 `STRINGS.EQUIPMENT_CONTROL` → `MOD_EQUIPMENT_CONTROL.STRINGS` 始终为 `nil` |

最终方案：通过 `CONFIG.DODGE_AUTO` 语言键传递"自动"文案，`label_format` 走
`MOD_EQUIPMENT_CONTROL.STRINGS.CONFIG.DODGE_AUTO`（该变量是 `confighud.lua` 已有的合法全局引用）。

`scripts/screens/confighud.lua`：
- 两个滑条去掉多余的 `fn`（框架已自动 `CONFIG[value_key] = newval`），与 GRIDALIGN 滑条一致
- `label_format` 改用 `MOD_EQUIPMENT_CONTROL.STRINGS` 取文案

`scripts/language/chinese_s.lua` / `scripts/language/english.lua`：新增 `DODGE_AUTO` 键

`modmain.lua:10`：`modimport(...)` → `STRINGS.EQUIPMENT_CONTROL = modimport(...)`


## 2026-10-24 — 自定义血条：仅在攻击命中后显示目标血量

参考废弃的 Epic Healthbar 适配模块，保留 Show Me / Insight 取真实血量的思路，但不再扫描附近实体或进行周期刷新：

- 前摇阶段只预取数据，确认攻击命中后才显示本次目标的血条。
- 切换目标时隐藏上一个目标的血条；真实数据异步返回后仅刷新当前显示目标。
- 去除血条周期管理与周期取数任务；现有命中伤害估算仅作为真实数据到达前的临时显示。
- 命中帧若真实血量恰好回传，优先用该数据更新红色填充，避免本地累计伤害覆盖真实填充比例。
- 临时诊断日志输出真实数据、传入绘制的比例/宽度及启用状态，定位数字与红条不一致。
- 抽出统一血条写入函数，按实时真实数据或本地估算二选一传入当前/最大血量，避免重复写值；日志标记实际数据源。
- 命中时优先使用已有的真实血量缓存；修正预取回调早于目标绑定时真实值被忽略、命中仍只画本地预测的问题。

**尚未实机验证**：命中后显示、目标切换时隐藏旧条、Show Me / Insight 环境下的数据回传。

---

## 2026-10-17 — actionutil: 统一包装层重写（1400 → 960 行）

### 现象

`scripts/util/actionutil.lua` 经多轮追加后膨胀到 1400 行：13 个通道、5 张互不相干的
注册表（`clickRegistries` / `mouseActionModifiers` / `clickActionsFilters` /
`controlHandlers` / 各全局列表），C / C2 / D2 三处各自复制了一份「包装取列表 → 分发」
样板；`DoAction` 被落点吸附与动作安检各包一层；死代码（`ValidateToolActions`、
`UnblockAction`、`MakeBlockContext` 导出）无人调用。

### 原因

- 排队论的 `SendAction` 钩子冗余：主机端 `SendAction` 无条件调用
  `playercontroller:DoAction(act)`（`actionqueuer.lua:484-533`），客机端走
  `SendRPCToServer`；两条路径分别由 DoAction 层与 RPC 层覆盖。
- `DoAction` 是动作执行的唯一漏斗（`playercontroller.lua:4514`），两个独立包装可合并。
- 各通道的安装/分发逻辑同构，可收敛为一个通用列表包装器。

### 修改

| 位置 | 修改内容 |
|------|---------|
| `scripts/util/actionutil.lua` | 整体重写；统一 `registries` 弱键表（原 5 张表合一），新增 `DispatchList` / `InstallListHook` 通用包装器，C / C2 / D2 共用 |
| 同上 | 合并 `InstallActionPointSnapHooks` 与 `InstallDoActionSafetyCheck` 为 `InstallDoActionHooks`：屏蔽器 → 拦截器 → 吸附 → 原调用，安装幂等 |
| 同上 | 删除排队论 `HookActionQueuer` 与 `source="queue"`（主机端 DoAction、客机端 RPC 已覆盖）；`DispatchClickHandlers` 只保留 `"rpc"` |
| 同上 | 删除死代码 `ValidateToolActions`、`UnblockAction`、`MakeBlockContext` 导出 |
| 同上 | 保留全部消费方在用的公共 API；全部统一为冒号方法（`ActionUtil:Method(...)`），调用点同步更新 |
| `scripts/Auto/autotool.lua` | 删除手写 `GetActionButtonAction` 包装，改注册通道 H 屏蔽器（仅 `source=="button"`），行为等价 |
| `scripts/Auto/telepoof.lua` | 注释同步：移除已不存在的 `"queue"` 来源说明 |
| `CHANGELOG.md` | 本条目 |

### 验证

- **尚未实机验证**
- `lua5.1 loadfile` 语法检查待跑（分类器暂时不可用）
- 实机回归清单：左右键点击/悬停、空格动作键；关闭斧头/锤子后悬停不显示且点击/空格被拦，
  且不影响同目标其它动作（锤子右键 vs 便携厨具"打开"）；排队论单击/排队/框选（主机 + 客机）；
  传送双击计数在鼠标、空格、RPC 三条路径一致；gridalign 吸附、quickdeploy 受限部署、
  quickactions 书本/研磨/调味、automedal 悬停切主厨勋章。

---

## 2026-10-17 — automedal: 悬停/点击已部署研磨器不切主厨勋章

### 现象

手持可研磨物品（`TUNING_MEDAL.MEDAL_GRINDING_RECIPES` 命中的调料/食材）悬停世界中的已部署便携研磨器
（`portableblender`，带 `mastercookware`）时，不再自动切到主厨勋章；左键点击该目标同样不切。

### 原因

`HOLD_ITEM_TARGET_CONFIG` 第一项的 `medals = {GetFinalPrefab("chefMedal")}` 在**模块加载期**求值。
此时 `BuildMedalGroups()` 尚未运行（它在 `Init` 里才调用），`MEDAL_DEFS` 仍为 `nil`，
`GetFinalPrefab` 一律返回 `nil`，于是 `medals` 实际是 `{ nil }` —— 空表。
`AutoEquipItem` 开头的 `if #prefabs == 0 then return nil end` 直接 no-op，
悬停与点击两条路径都拿不到可切的勋章，表现为"静默失效"。

（同表其它项用的是 `GetGroup` / `GetMedalsByPlayerTag` / `M.*`，都不依赖 `MEDAL_DEFS`，
加载期可用，所以只有研磨这一项坏掉。）

### 修改

`scripts/Auto/automedal.lua`：

| 位置 | 修改内容 |
|------|---------|
| `ResolveConfigMedals`（新） | 统一的惰性取值入口：`medals` 允许是函数/字符串/表，在真正悬停/点击（玩家已加载）时才求值 |
| `HOLD_ITEM_TARGET_CONFIG` 研磨项 | `medals` 改为函数：运行时以 `GetFinalPrefab("chefMedal")`（模组权威数据）为准，取不到再退回本地 `MEDAL` 常量表（`GetMedalsByPlayerTag("seasoningchef")`） |
| 点击 / 悬停两处消费点 | 改走 `ResolveConfigMedals(cfg)`，不再在加载期固化 `cfg.medals` |

与 `MEDAL_ACTION_RULES.MEDAL_GRINDING`（研磨动作本身）使用同一套标签派生口径，两处一致。

### 验证

- `lua5.1 loadfile` 语法检查通过
- **尚未实机验证**
- 手持可研磨物品悬停已部署便携研磨器 → 自动切到主厨（`headchef_certificate`），移开 → 切回
- 手持可研磨物品左键已部署便携研磨器 → 同上；点击执行研磨动作时仍由 `MEDAL_GRINDING` 规则兜底
- 手持非可研磨物品悬停研磨器 → 不切换

---

## 2026-10-17 — automedal: 制作时巧手连续换入两次

### 现象

佩戴融合勋章制作/建造、前置勋章已满足时，巧手勋章仍会**连续切换两次**；
第二批换入会把这批刚换进箱的巧手当成牺牲品顶出去，结果制作执行时箱内可能没有巧手。

### 原因

客机上同一次制作会走两条钩子，各调一次 `_HandleCraftRecipe`：

1. `builder_replica:MakeRecipeFromMenu/AtPoint`（制作菜单点击时同步，`widgetutil.lua:87` 等）
2. 该调用内部的 `RemoteMakeRecipeFromMenu/AtPoint` 最终 `SendRPCToServer` → 模组在 RPC 层又拦一次

两次调用的箱内容快照相同（第一批 swap 的 RPC 还没回传），于是各自独立预算：
第一次把巧手换入（顶出受害者 A），第二次仍以为巧手不在箱内，再从同一源槽发起 swap ——
此时源槽里已被放回受害者 A，第二批就把 A 换进箱、把巧手换出来。终态箱内没有巧手。

另有独立的时序问题：批量 swap 原本统一 `DoTaskInTime(0)` 下一帧才发，
而制作 RPC 在点击当下就发出 → 服端先执行制作、swap 后到。

还有一处"前置勋章再切一次"：前置本来由**配方页点击**（`PrepareBuilderTagRecipe`）按 `builder_tag`
自动切好，但制作时 `_HandleCraftRecipe` 又用 `PlayerUtil:HasBuilderTagFromMedal` 按**玩家标签**重判。
勋章刚换入融合箱时标签要等服端回传才生效，这个窗口里重判失败 → 再走一次 `AutoEquipMedal(prefabs)`，
又是一次多余的切换。

### 修改

`scripts/Auto/automedal.lua`：

| 位置 | 修改内容 |
|------|---------|
| `_HandleCraftRecipe` | 以 `recipe.name` + 0.5s 窗口去重：同一次制作无论从哪条钩子进来只处理一次。两条钩子都保留（RPC 层仍兜住模组直接发 RPC 的路径） |
| `_HandleCraftRecipe` | 点过配方页（`_craft_builder_pending` 命中当前配方）时**不再按玩家标签重判前置**，直接以前置勋章为保护集补巧手；未经配方页（模组直接发 RPC 等）才按标签兜底补装 |
| `_HandleCraftRecipe` | 处理期间置 `_swap_flush_now = true`（结束复位），使本次制作的批量 swap 当场同步发出 |
| `BatchSwapMedalsIntoTargetBox` | 新增 `_swap_flush_now` 分支：为 true 时跳过"每帧 5 枚"的分帧发送、一次性同步发出；攻击链等其它路径保持分帧，RPC 限流不受影响 |

### 验证

- `lua5.1 loadfile` 语法检查通过
- **尚未实机验证**
- 佩戴含前置勋章的融合箱（箱满）制作 `builder_tag` 配方 → 点配方页只切一次前置、制作时前置不再被重判切换，只发生一次巧手换入，制作执行时箱内同时有前置勋章与巧手
- 客机建造（`MakeRecipeAtPoint`）同上
- 战斗/本源组合等其它批量换入不受影响（仍分帧发送）

---

## 2026-10-17 — autotool: 关闭的工具动作在手持工具时仍显示提示

### 现象

在配置里关闭某个快速工具（如斧头），空手时悬停目标不再显示该动作、点击/空格也确实被拦截；
但**手里拿着对应工具**（如斧头）时，光标悬停目标仍显示「砍伐」，只是点击和空格没有反应 ——
显示与实际拦截不一致。

### 原因

关闭开关的拦截只挂在"动作已被选中"之后的两处：

- `RegisterDoActionInterceptor`（鼠标点击、排队论等 `DoAction` 路径）
- `GetActionButtonAction` 包装（空格键 / 附近交互键）

而光标提示与目标高亮取的是 `playercontroller.LMBaction` / `RMBaction`
（`widgets/hoverer.lua:68-114` → `GetLeftMouseAction()`/`GetRightMouseAction()`），
这两个值由 `playeractionpicker:DoGetMouseActions` 每帧写入（`components/playercontroller.lua:2821`）。
手持工具时游戏原生动作收集器会返回 CHOP 等动作，本模块的鼠标修改器只做"空手注入"，
从不剔除已有动作 —— 于是提示照常显示，直到执行阶段才被拦下。

**追加问题：在 `DoGetMouseActions` 返回后把整键置 `nil`，会连带屏蔽同目标的其它动作。**
`DoGetMouseActions` 每个键只返回候选列表的 `actions[1]`（`playeractionpicker.lua:525-526`），
而这个首选可能被遮挡动作占用：手持锤子右键便携厨具时，右键盘首选是 HAMMER，
「打开」只是候选列表里的次选。把选好的 HAMMER 置 `nil` 等于把整个右键清空，
次选没有机会被选中 —— 表现为"屏蔽锤子右键，便携厨具的右键也一起没了"。

### 修改

`scripts/Auto/autotool.lua`：

| 位置 | 修改内容 |
|------|---------|
| `FilterToolActions`（新） | 按 `IsToolEnabled(action.id)` 过滤 picker 的候选动作列表；无命中时原样返回（零分配） |
| `scripts/util/actionutil.lua` 通道 D2（新） | `RegisterClickActionsFilter`：统一包装 `playeractionpicker:GetLeftClickActions` / `GetRightClickActions` 并分发过滤器（带 `_ec_clickactionsfilter_installed` 幂等标记、无处理器不包裹），与通道 C/C2 同构 |
| `autotool` 钩子 | 不再自行包裹 picker 方法，改为 `ActionUtil:RegisterClickActionsFilter(self.inst, 0, FilterToolActions)` 注册；决策逻辑仍留在 autotool（actionutil 只做包装与分发） |
| `ModifyMouseActions` | 删除原先"返回后把 lmb/rmb 置 nil"的过滤（正是它连坐了次选动作） |

在列表层过滤后，首选被关闭时 picker 的自然回退（取下一个可用动作）照常工作，
显示、目标高亮与实际执行同源；注入逻辑不变（注入前本就有 `IsToolEnabled` 校验），
`DoAction` / `GetActionButtonAction` 两道执行侧拦截保留作兜底。

### 验证

- `lua5.1 loadfile` 语法检查通过
- **尚未实机验证**
- 关闭斧头开关 → 空手/手持斧头悬停树木均不显示「砍伐」，左键点击与空格均无动作
- 重新打开开关 → 空手自动装斧、手持斧头正常显示并执行「砍伐」
- **关闭锤子开关 → 手持锤子右键可锤目标时提示消失、右键无动作；同时右键便携厨具仍显示并执行「打开」**
- 关闭锄头开关 → 空手/手持铲子对可挖目标的提示与动作均消失，其它右键动作不受影响

---

## 2026-10-17 — filterremover: 勋章模组缺席时开局崩溃

### 现象

未启用/未安装勋章模组（1909182187）时进入游戏直接崩溃，日志：

```
[string "scripts/mods.lua"]:854: GameLuaInjectFramework.lua:63:
module 'widgets/medal_spacetimedustover' not found:
... [string "../mods/Equipment Control/scripts/Auto/filter..."]:579: in function 'result'
... [string "../mods/Equipment Control/modmain.lua"]:197: in main chunk
```

崩溃发生在 `modmain.lua:197` 的 `modimport("scripts/Auto/filterremover")` 阶段 ——
此时整个 `filterremover.lua` 只执行到第 579 行，其后的所有滤镜 Hook 全部没注册上。

### 原因

`widgets/medal_spacetimedustover` 是勋章模组提供的 widget，不在游戏本体里。
`AddClassPostConstruct` 内部直接 `require(package)`（`modutil.lua:162`），
模块不存在时抛错；该调用位于 filterremover 顶层（modimport 的 `result` 函数），
异常一路冒泡终止 modmain，整个模组加载失败。

### 修改

`scripts/Auto/filterremover.lua`：

| 位置 | 修改内容 |
|------|---------|
| 第五节「风暴/天气类覆盖层」 | `widgets/medal_spacetimedustover` 的注册改为先 `pcall(require, ...)` 探测，模块可加载才 `AddClassPostConstruct`；勋章模组缺席时静默跳过（该 widget 本来就构造不出来，没有需要 Hook 的对象） |

其余 `sandover` / `moonstormover` / `moonstormover_lightning` / `miasmaover` 均为游戏本体 widget，保持无条件注册。

### 验证

- `lua5.1 loadfile` 语法检查通过
- **尚未实机验证**
- 未启用勋章模组进游戏 → 不再崩溃，其余滤镜消除功能正常
- 启用勋章模组进游戏 → 时空迷雾（`FILTER_SPACETIME_MIST`）仍可被压制

---

## 2026-10-17 — automedal: 制作前置勋章与巧手联动冲突 / 建造不切巧手

### 现象

1. 佩戴融合勋章时制作 `builder_tag` 配方（研磨/冷却/巧手专属道具等）：自动换装把前置勋章插入融合箱后，
   巧手联动再插入巧手时会把刚换入的前置勋章顶出箱子 → 前置标签丢失，制作失败。
2. 佩戴融合勋章建造建筑（`MakeRecipeAtPoint`）时完全不切巧手勋章：`AutoEquipHandyCraftMedal`
   遇到融合箱直接 `return true`，既不整箱替换、也不把巧手换入箱内。

### 原因

`_HandleCraftRecipe` 把"前置勋章"和"巧手"拆成互斥的两段：`ShouldSkipHandy` 命中前置标签就
`EquipCombo({M.handy})` 并提前返回，且 `EquipCombo → PickRemovableContent` 的保护集为空，
巧手换入时可自由以箱内任何勋章（包括刚插入的前置勋章）为牺牲品；未命中前置标签时则只
`AutoEquipMedal(prefabs)` 后返回，永远不再补巧手。非 `builder_tag` 配方（绝大多数建造）走
`AutoEquipHandyCraftMedal`，其融合箱分支只为"不替换箱"而直接返回，于是巧手永远进不了箱。

### 修改

`scripts/Auto/automedal.lua`：

| 位置 | 修改内容 |
|------|---------|
| `EquipCombo` | 新增第 4 参 `protect_prefabs`（硬保护集），透传给 `StepAttackTiers` 的 `target_set` |
| `AutoEquipHandyCraftMedal(recipe, protect_prefabs)` | 融合箱分支不再直接返回：箱内已有巧手（考验/完全体）则跳过，否则用 `EquipCombo` 把巧手换入箱内；`protect_prefabs` 中含完全体巧手时只认完全体（考验勋章没有 `has_handy_medal`） |
| `_HandleCraftRecipe` | 统一流程：`builder_tag` 配方先确保前置勋章生效，佩戴融合箱时再以**前置勋章为保护集**补巧手；单勋章槽位保持"前置优先"；非 `builder_tag` 配方照常走巧手联动 |
| `ShouldSkipHandy` | **删除**（职责已并入 `_HandleCraftRecipe`，且原实现会顶掉前置勋章） |

### 验证

- **尚未实机验证**
- 佩戴含前置勋章的融合箱、箱满时制作研磨类（`seasoningchef`）配方 → 巧手换入后前置主厨勋章仍在箱内，制作成功
- 佩戴不含巧手的融合箱建造普通建筑 → 巧手（有考验则用考验）被换入箱内
- 建造勋章雕像（`builder_tag="has_handy_medal"`）→ 箱内为完全体巧手，建造成功
- 单勋章（非融合箱）状态 → 前置勋章优先，不会被巧手替换

---

## 2026-10-15 — 动作拦截层修复：锤子右键 / 灵魂跳跃拦截 / 精准动作屏蔽

### 现象

1. **自动工具（autotool）把锤子的右键动作注入了左键。** 背包里有锤子、手上空着时，左键点工作台等结构物
   会被劫持成"自动装锤并锤击"；右键点它们反而不装锤子、不锤。
2. **灵魂跳跃（沃拓克斯 BLINK）拦截不生效。** 传送禁用打开时右键地面照样直接跳走；装了排队论
   （2873533916）按住队列键点击时必定复现。
3. **排队论在按住队列键时吃掉本 mod 一批"点击前抢跑"的逻辑**，典型表现是 automedal 的
   "点击切勋章"失效。
4. **"动作屏蔽"只对空格键生效、且开关无效。** 走近花/原型机/假人时按空格被挡，鼠标点击照旧触发；
   在配置 HUD 里关掉「动作屏蔽」也照样挡。
5. 缺少"针对某一个动作的精准拦截屏蔽"的手段。

### 原因

**1) 锤子：用错了判定真值源。**
官方把"某动作在这个目标上算左键还是右键"写在
`componentactions.lua:3174 EntityScript:IsActionValid(action, right)`，以及
`componentactions.lua:3034 ISVALID.workable` 的 `(right or action ~= ACTIONS.HAMMER)` 里：
**HAMMER 只在 `right = true` 时有效**。而 `actions.lua:407 HAMMER = Action({ priority=3 })`
恰好**没有 `rmb` 字段**，autotool 原先只看 `act.rmb`，于是把 HAMMER 判成"左键动作"。

**2) 灵魂跳跃：拦截钩子挂在了不覆盖实际派发路径的层上。**
telepoof 只注册了右键点击处理器，它包的是 `pc:OnRightClick`。排队论的实例级 `OnControl`
（workshop-2873533916 `modmain.lua:177-190`）在**按住队列键 + 鼠标左右键**时**直接 `return`**，
`OnRightClick` 根本不执行 → 拦截处理器永不触发；排队论的两条出口
（`actionqueuer.lua` 主机端 `pc:DoAction`、客机端 `preview_cb → SendRPCToServer`）也都不经过它。
同一个根因还吃掉了 automedal 的**类级** `OnControl`（第 3 条的"点击切勋章失效"）。
叠加三处次要缺陷：`TELEPOOF_WORTOX` / `TELEPOOF_HOVER` 在加载期就被读进 `local`
（配置 HUD 运行时改写 CONFIG 后不生效）；`StoredMouseHovers.SOUL` 只在加载期为真时才登记；
hover 判定只认 `strfn == "SOUL"`，而 `actions.lua:3509-3511` 在免费跳跃时返回 `"FREESOUL"`。

**3) 动作屏蔽挂点太少 + 开关加载期捕获。**
原实现只包 `GetActionButtonAction`（=只覆盖空格键），左键/右键/排队论全放行；
规则形状是 (动作, 目标) 对，表达不了"屏蔽某动作的所有目标"；
`ACTIONS_BLOCK_ENABLED` 是加载期捕获，HUD 开关不生效。

**4) 没有任何一层能否决"绕过 DoAction 的动作"。**
通道 E（点击 RPC）原先只能通知、不能否决。

### 修改

`scripts/util/actionutil.lua`：新增两个通道

| 位置 | 修改内容 |
|------|---------|
| `[13] 通道 H 动作屏蔽` | `RegisterActionBlocker`(策略型) / `BlockAction`+`UnblockAction`(精准规则表) / `IsActionBlockedFor`(只读查询)。安检点两个：DoAction 包装（`source="press"`，覆盖鼠标点击/排队论主机端/客机端/各模块自调 DoAction）与 `GetActionButtonAction` 包装（`source="button"`，空格键唯一路径）。规则项：`enabled`(实时求值) / `sources` / `right` / `target_prefab` / `target_tag` / `target_match` / `invobject_prefab` |
| `[9] 通道 E` | `DispatchClickHandlers` 改为返回"是否被否决"，`SendRPCToServer` 包装在否决时**不发 RPC**（`source="rpc"`，纯否决不计数），并按 `RPC.LeftClick/RightClick` 传入 `right` |
| `[11] 通道 G` | `InstallDoActionInterceptor` → `InstallDoActionSafetyCheck`：先跑屏蔽器、再跑既有拦截器；安装门槛放宽为"有拦截器 **或** 有屏蔽器" |
| `[14] 通道 I 控制前钩子` | `RegisterControlHandler`：骑 `TheInput:AddGeneralControlHandler` 的 oncontrol 监听器（注册于本文件加载期，早于 playercontroller 在 `Activate()` 里注册的自己的监听器），因此**必定先于 `pc:OnControl` 执行，且任何包装 `pc.OnControl` 的模组都遮蔽不了它**；全局只注册一个监听器，调用时用 `ThePlayer` 现取 |

`scripts/Auto/autotool.lua`：新增 `ActionUsesRightButton(target, act, isRMB)`，
复用官方 gate `target:IsActionValid(act, right)`（右键要求"右键有效且左键无效"，与
`playeractionpicker.lua:535-541` 的"左右键都有效时左键优先"去重语义一致；`pcall` 兜底 + 无 gate 时退回 `rmb` 字段）；
`ToolTagForTarget` 改为按固定顺序 `TOOL_ACTION_ORDER` 遍历（原先是 `pairs` 哈希序，多 `_workable` 标签时靠撞运气）。

`scripts/Auto/telepoof.lua`：右键点击处理器 → **动作屏蔽器**（`ActionUtil:RegisterActionBlocker`），
策略一份覆盖所有派发路径；四个配置项全部实时读 `CONFIG`（双击间隔仍读 modinfo，那是开局选项）；
灵魂跳跃识别放宽到 `"SOUL"` / `"FREESOUL"`；双击计数只在 `ctx.source == "press"` 递减；
悬停隐藏改为查询 `IsActionBlockedFor(..., source="hover")`，显示与实际拦截同源。

`scripts/Auto/filterpickup.lua`：5 条内置规则改为 `ActionUtil:BlockAction(...)`（`enabled` 实时读
CONFIG）；拾取黑名单的"重选下一个候选"逻辑保留，并让重选出的候选也过一次屏蔽（避免换成旁边一朵花）。
`scripts/Auto/automedal.lua`：类级 `PlayerController:OnControl` → `ActionUtil:RegisterControlHandler`
（函数体逻辑不变）。`scripts/screens/confighud.lua`：两个传送开关加 `on_toggle` 刷新悬停文本。

### 设计原则

- **判定真值源一律问游戏，不猜字段。** "这个动作走左键还是右键"以
  `target:IsActionValid(act, right)` 为准（`Action.rmb` 会漏掉 HAMMER 这类没有该字段的动作）。
- **屏蔽挂在派发路径的最上游。** DoAction / 动作键 / 点击 RPC 三处安检，一份策略覆盖全部路径；
  挂点越靠前，"先走过去再发 RPC"这类副作用也一并被阻断。
- **配置只存"求值方式"，不存"求值结果"。** 规则表里写 `enabled = function() return CONFIG.X end`，
  每次判定实时求值 —— 从根上消灭"加载期捕获 → HUD 开关不生效"这一整类 bug。
- **一次物理动作只被计数一次。** 计数型屏蔽器只在 `source == "press"` 递减；`rpc` / `hover` 层是只读的
  （前者纯否决，后者纯显示），否则同一次点击会被扣两次。
- **不被遮蔽优先于能否决。** 通道 I 用输入事件总线（监听器顺序有保证）而不是"再包一层 pc.OnControl"
  （那要靠加载顺序赌运气），代价是它不能否决 —— 要否决动作走通道 H。
- **内置动作屏蔽保留"只挡动作键"的语义。** 这 5 条规则的本意是"空格误触发"（鼠标点击要照常可用：
  花仍能点着摘、仓储机器人仍能点着取物），故显式写 `sources = {"button"}`；
  要做"全路径精准屏蔽"，把这一项去掉即可（通道 H 默认所有路径都拦）。

## 2026-10-02 — 耐久归零物品快捷栏死循环 + 光源手动换下不切回 + 事件驱动重构 + nil 崩溃修复

### 现象

1. **锻造类物品耐久归零后快捷栏反复尝试装备。** 锻造修补物品（如虚空布帽）耐久归零后游戏强制卸下，但快捷栏仍显示该物品，自动装备逻辑反复尝试装备 → 被服务器卸下 → 再装备，形成死循环。
2. **普通可修复物品在 ≤ 阈值且无修补材料时同样反复装备。** 如足球头盔 3% 耐久，`AutoUnEquip` 卸下后快捷栏又返回该物品。
3. **自动光源手动换下后不能自动切回。** 内循环只等天亮/退光，检测不到玩家手动换下光源。
4. **itemtracker.lua 中 `AddPrefabPostInit`/`AddPlayerPostInit` 未声明导致 strict 报错。**
5. **`TUNING.FREEZING_TEMP`/`OVERHEAT_TEMP` 在 DST 中不存在导致 `attempt to compare number with nil`。**
6. **`voidclothhat` classified 不暴露 `percentused` 字段，`AutoRepair` 直接访问崩溃。**

### 修改

`scripts/components/itemtracker.lua`：

| 位置 | 修改内容 |
|------|---------|
| `IsFuelOrRepairRelated` | 提升至模块作用域，供构造函数内事件监听复用 |
| `OnInventoryPercentUsedDirty` | 移至 `AutoRefuel`/`AutoRepair` 之后，解决 strict 模式下函数前向引用报错 |
| 构造函数（旧 `AddPrefabPostInit`/`AddPlayerPostInit`） | 移除 mod API 钩子调用，改用 `InventoryEventService` 的 `ITEM_ADDED`/`EQUIPPED`/`UNEQUIPPED` 事件替代，组件不再依赖 `GLOBAL` 或 mod API |
| `AutoRepair` | 耐久 `≤ 0` 时调用 `RefreshButtons()` 触发快捷栏即时刷新；加 `classified.percentused and` nil 守卫，防止缺少 percentused 字段的物品（如 voidclothhat）崩溃 |

`scripts/components/actioncontroller.lua`：

| 位置 | 修改内容 |
|------|---------|
| `IsAutoUnEquipping` | 锻造类物品耐久 `≤ 0` 时返回 `true`（普通物品仍走原有 `≤ GetFiniteUses` 阈值），统一为候选列表过滤的唯一真值源 |
| `GetAutoEquipCategoryItem` | 用户选中物品经 `IsAutoUnEquipping` 过滤，耐久不足时退回 `GetBestItem` |
| `GetItemFromCategory` | 同上，统一走 `IsAutoUnEquipping` |

`scripts/Auto/autolight.lua`：

| 位置 | 修改内容 |
|------|---------|
| 内循环 | 加 `not IsEquipped(lightsource)` 检测，玩家手动换下光源立即跳出内循环，外循环重新检测黑暗并装备 |
| Unequip 守卫 | 加 `IsEquipped` 条件，防止对已手动卸下的光源发多余的 Unequip RPC |

`scripts/util/worldutil.lua`：

| 位置 | 修改内容 |
|------|---------|
| `IsFreezingTemperature` | `TUNING.FREEZING_TEMP` → 硬编码 `0`（DST 中不存在此常量） |
| `IsOverheatingTemperature` | `TUNING.OVERHEAT_TEMP` → 硬编码 `70`（同上） |

### 设计原则

- **单一真值源：** `IsAutoUnEquipping` 覆盖锻造（0%）和普通（≤ 阈值）两种场景，四个入库入口（`GetItemPriorityTable`、`GetItemsFromCategory`、`GetItemFromCategory`、`GetAutoEquipCategoryItem`）全部走它，不散落重复判定。
- **服务器不可干预：** 耐久归零时服务器侧 `finiteuses` 强制 `DoUnequip`，客户端不干预此行为，只在卸下后过滤候选列表 + 即时刷新快捷栏。

## 2026-09-30 — mapteleport: 传送轮盘恢复「备份 ↔ 命名一一对应」+ 重登后按坐标恢复名字

### 现象

WX-78 的坐标轮盘里，无论选中传送到哪台备份底盘，圆心悬停提示里的「当前机身」始终是
「未命名」；而圆心管理面板里备份行的改名显示是对的 —— 备份的名字与「当前机身」之间没有通路。

**追加 1：重登一次之后，所有备份底盘的名字集体退回「未命名」**（面板与轮盘外环都是），
要重新一个个手改。这一条本次一并解决。

**追加 2：换身到一台已命名的备份底盘之后，当前机身拿不到那台备份的名字。**
上一版的实现按「点中的底盘会被销毁、旧机身会在原地新生成一台备份」来迁移名字，结果一套都没生效。

### 原因

**1) 圆心按设计只显示"你现在驾驶的这台机身"的名字，它没变过，是因为那个键从来没被写过。**
圆心那句名字是圆心按钮的悬停提示（悬停圆心才出现，恒指向自身机身，不随外环游走；
外环每一格自带"名字 + 坐标"的悬停标签，两者互不越界）。它读 `GetWX78BodyName(ThePlayer.GUID)`，
而**换身时没有人把目标备份的名字交接到"当前机身"这个键上** —— 所以永远是 `nil` ⇒ 「未命名」。
面板正常，是因为面板显示的是备份行（另一套键，且用户改过名）。

**2) 备份名字以地图形标 GUID 为键，而这个键不稳定。**
图标是 `wx78_backupbody_globalicon`（`globalmapicon.lua:396` 生成、`:335 persists = false`），
**每次重登都是新实体、新 GUID**，所以这个键只在本次游戏内有效 —— 这就是"重登后名字全丢"的根因。
本次的修法：**记账时把该底盘的坐标一起存下来**；备份底盘钉在地上不会动，
下一局进游戏后按"哪台底盘离这个坐标最近"把名字重新挂到新的图标键上（`ReanchorBodyNames`）。

**3) 最关键的一条：官方换身根本不是"销毁一台、再新建一台"，所以上一版那套"等图标消失再迁移"的检测永远不触发。**
读 `wx78_backupbody.lua:311 OnActivateFn` 全文（到 `:563` 返回 true）可以看到它做的是一次**双方互换**：

| 行 | 动作 |
|---|---|
| `:487-497` | `inst.wx78_backupbody_inventory` 与 `doer.components.inventory` 互换背包内容（含容器内物品） |
| `:495-503` | 双方 `skinner` 互换外壳皮肤（`CopySkinsFromPlayer` + `OnLoad`），`upgrademoduleowner` 互换升级模块 |
| `:504-519` | **双方 `Physics:Teleport` 互换位置**：你 → 那台底盘的位置 P，它 → 你原来的位置 Q |

**整个函数里没有 `inst:Remove()`。** 被点中的那台底盘不会消失，它的实体 GUID 与地图形标都还在
（图标挂在同一实体上，`globalmapicon.lua` 给图标挂了跟随目标的 `updatelooper`，它跟着一起挪到 Q）。
`TryToSpawnPossessedBody` 里那句 `inst:Remove()`（`:203`）只走容器 / 断电 / 格斯特笼分支，
`wx78_possessedbody.lua:181 TryToReplaceWithBackupBody` 同理 —— 换身路径两者都不经过。

后果：上一版挂在目标地图图标上的 `onremove` 监听**一次都不会响**（图标没被移除），
而它的"判据一：目标图标仍在 ⇒ 换身没发生"因此**永远判否**，整笔记账在第一次读名字时就被作废 ⇒
名字一动不动。参考模组（WX-78辅助 `3712173567`）也是按"换身后 GUID 仍在"来设计的
（`scripts/body_bind.lua:446 _afterSwap`：按 F1–F4 槽位存名字，GUID 只是一个"定位器"，
换身后把被点槽位的 GUID 交给第一个空槽，**被点的槽位保留名字、只丢掉 GUID**）——
它压根不做任何"事件检测"，而是在发出换身指令的同一刻就把记账做完。

### 修改

`scripts/Auto/mapteleport.lua`：

| 位置 | 修改内容 |
|------|---------|
| `RawSetBodyName` | 裸写表操作，供命名入口复用（不触发重建轮盘）。**值改为 `{ n = 名字, x, z, s }`**：`x/z` 是这台底盘此刻的坐标（调用方留空则自动查、查不到沿用旧值），`s` 标记"这条是当前机身"。读取侧 `GetWX78BodyName` 经 `RecordName` 兼容旧存档的裸字符串 |
| `GetChassisAnchor`（新） | 锚点查询：复用 `GetWX78ChassisList`（它已把"备份底盘 + 当前机身"按 key 列全）把 key 翻成坐标 |
| `ReanchorBodyNames`（新） | **重登后按坐标恢复名字**：把"死键"（上一局的图标 GUID）按坐标最近原则贪心配对（升序排序，近者优先；`REANCHOR_RADIUS_SQ = 12²`）挂到本局新图标键上，配不上就原样留着不删。跳过：本局自身键、已有活键的底盘、无坐标的旧格式记录、`s` 标记的他人当前机身 |
| `GetWX78ChassisList` | 旧存档 `"self"` 键迁移时补写 `s` 标记，避免它日后被当成散落的备份底盘去匹配坐标 |
| `SetBodyRecord`（新） | 整条记录原样写入 / 清除（**不做坐标补查**，这是它与 `RawSetBodyName` 的唯一区别 —— 回滚要原值，不能被补查改写）。旧存档裸字符串按 `{ n = 字符串 }` 兼容 |
| `SwapChassisNames`（新，**取代** `BeginSwapNameTracking`） | **点击那一刻就把两边的名字对调**，确定性、不检测、不轮询：`self` 键（我）拿走被点底盘的名字、锚点写 P（我现在站的、那台底盘原来的位置）；被点底盘那个键拿走我旧机身的名字、锚点写 Q（我原来的位置，它现在停的地方）。`self` 那条补 `s = true`。锚点必须显式写"换身后"的位置，因为重登恢复靠它 |
| `VerifySwapPosition`（新） | 只在服务端**拒绝**换身时兜底：`SWAP_NAME_VERIFY_DELAY = 0.5` 秒后用 `DoTaskInTime` **一次性**核实一次你与 P 的距离（≤ `SWAP_NAME_RADIUS_SQ = 20²`）；不在 P 就把两条记录按点击前抄下的原值写回并重建轮盘。读不到坐标时**不回滚**（宁可留着对调后的名字，也不乱回滚） |
| `RebuildMapWheel` | 去掉换身结算（已无此步骤），只保留 `ReanchorBodyNames` |
| `GetWX78BackupBodies` | 去掉返回值里的 `inst`（不再需要挂 `onremove` 监听） |
| **删除** | `OnSwapTargetRemoved`（目标图标 `onremove` 监听）、`CheckSwapPosition`、`ResolvePendingSwapNames`、换身前图标 GUID 快照 `prev_guids`、以及"旧机身回落成新备份"的邻近搜索 —— 整个模型作废 |
| 名字表注释 | 修正原注释的错误结论：地图形标 **跨重登会换 GUID**，故按图标 GUID 记录只在本局内有效（现已由 `ReanchorBodyNames` 补上跨局恢复） |

三处设计取舍为什么这么定：

- **不做检测，改成"点击即对调"。** 换身是纯服务端行为，客机拿不到它的任何事件或 RPC 回执；
  唯一能观测的只有坐标与图标生命周期，而两者都被证明不可靠（图标不消失；坐标只能证明"人动了"）。
  既然换身是确定性的双方互换，名字的对调也应当在同一刻确定性地完成 —— 这也是参考模组的做法。
- **对调而不是单向迁移，因为名字要跟着"看得见的那台机身"走。** 换身同时互换了**皮肤**：
  P 处的你现在长得就是那台备份底盘，Q 处那一台长得就是你原来的机身。所以名字对调之后，
  两块地方的显示与外观一一对应，`self` 键也终于被写了第一次 —— 圆心那句「当前机身：未命名」随之消失。
- **坐标核实降级为"拒绝换身时的回滚"，而不是迁移的前置条件。** 这条判据原本要挡的场景
  （底盘被锤掉 / 拆掉被误当成换身成功）在新模型下**结构上不可能发生**：拆底盘不会触发任何改名。
  它现在只负责服务端拒绝换身（技能没激活 / 屏障阻断）这一种情况，且延迟特意放宽到 0.5 秒 ——
  换身是服务端改完位置再同步回客机，0.1 秒有可能还没到；"该回滚没回滚"只是名字暂时错位（再改一次名即可），
  "不该回滚却回滚了"恰好是本次要修的 bug。0.5 秒内人走不出 20 单位（步行约 5/秒），不会误判成功。

重登恢复又为什么这么定：

- **只有备份底盘需要恢复，当前机身不用。** 玩家实体 GUID 跟着账号走、跨重登不变
  （存档本就以玩家 GUID / userid 为键），所以"当前机身"那条记录一直是活键；死键只有图标 GUID 那类。
- **每台底盘只恢复一次，且绝不动活键。** 匹配时把"已经有活键的底盘"排除在外，
  既保证幂等（每台最多恢复一次），也杜绝"旧记录把本局某个名字盖掉"。玩家自己新造一台底盘时，
  它在拿到名字之前不占活键 —— 正常情况下本表的死键早已被消费掉，不会再乱挂。
- **贪心配对按距离升序。** 两台底盘挨得近时（比如堆在一起换身），先配最近的一对，
  避免按遍历顺序随手配错。半径收在 12 而非换身的 20：底盘钉在地上不动，12 已经很宽松。
- **配不上就留着，不删。** 那台底盘可能这一局还没同步到本机（图标按需创建），
  删了就等于永久丢名字。留着只是一条不显示的记录，代价可忽略。
- **`s` 标记：存档是整片分片共用的。** 别的玩家驾驶过的机身记录也躺在同一张表里，
  且他们的 GUID 对"我"而言同样是死键、同时带着一个"他们下线时站的位置"当锚点 ——
  不标出来，我在自己的存档里就可能把别人的机身名挂到附近的备份底盘上。

### 影响范围

- 圆心：**行为不变**（仍只显示当前机身自己的名字，不随外环游走），但现在能读到正确的名字
- 外环每格：不变（"名字 + 坐标"的悬停标签与面板同源）；换身后原来那一格顶着"旧机身名字"落在你原来的位置
- 面板：不变（换身后当前机身 / 备份的名字归属自动换位）
- 未命名过的当前机身：圆心提示显示「当前机身：未命名」
- **跨重登：备份名字自动按坐标回到原来的底盘上**（恢复时机是首次重建轮盘，即第一次开轮盘 / 开面板）
- 存档格式：`wx78_bodynames` 的值由字符串变成 `{ n, x, z, s }`。旧存档不必转换 ——
  读取侧兼容裸字符串，只是那些老名字没有坐标、无法跨局恢复，重登一次后会丢；
  对其中任意一台重新改一次名即可重新记账，之后就能跨重登保留

### 已知限制（本次未解决）

- **拒绝换身 + 你与被点底盘相距 20 单位以内时，回滚会失效**（判据是"人是否在 P 附近"，
  站得够近就分不出来），名字会错位，重新改名即可恢复。彻底根除只能等服务端侧可观测信号。
- **0.5 秒内连点两次换身，第一笔的坐标核实会被第二笔顶掉**（不再可能回滚）。
  名字按第二笔的对调结果走，实际效果与"两次都成功"一致。
- **旧格式（裸字符串）的名字跨不了局**：升级到本版本之前存的备份名没有坐标，
  重登一次就退化成未命名，需重新改一次名（见上"存档格式"）。
- **原位重建会被旧名字认领**：拆掉一台有名底盘后，若在它原址 12 单位内另造一台新底盘，
  那条还留着的旧记录会把这台新底盘认成它。名字是纯显示层数据，重新改名即可。

### 验证

- **尚未实机验证**
- 建议验证：
  1. 面板里给若干备份底盘改名 → 传送到其中一台 → **换身后的当前机身应显示该名字**
     （圆心悬停提示 + 面板"当前机身"行同名），外环里原来那一格应顶着"你换身前的机身名"、
     出现在你换身前站的位置上
  2. 未点远程换身技能 / 屏障阻断的情况下传送失败 → 0.5 秒后轮盘与面板名字应恢复原样
  3. **站着不动，用锤子拆掉一台你点过（准备换身但没换）的备份底盘** → 名字不应发生任何迁移
     （新模型下压根没有检测路径，这一条应当天然成立）
  4. **给若干备份底盘改名 → 退出重进 → 开一次轮盘/面板** → 每台底盘的名字应各自回到原位
     （互换过的那些位置也要对：名字跟着底盘走，不跟着格子走）
  5. 上面第 4 条之后**把其中一台搬到别处再重登** → 它应显示未命名（锚点对不上），
     其余各台不受影响
- 若报错，读 `~/Documents/Klei/DoNotStarveTogether/client_log.txt`，
  搜 `LUA ERROR stack traceback:`，按栈里的 `../mods/Equipment Control/scripts/Auto/mapteleport.lua:<行>` 定位

### 参考

- 参考模组 WX-78辅助（Workshop `3712173567`）：`scripts/body_bind.lua`

---

## 2026-10-23 — 移除史诗血条（epichealthbar）：ForceEnableMod 在现代 DST 彻底失效

### 现象

客户端日志报错，Equipment Control 模组被禁用：

```
Mod file access denied: workshop-1185229307/modmain.lua
Mod: workshop-1185229307 (史诗血量条)  Mod had no modmain.lua. Skipping.
[string "scripts/modutil.lua"]:162: module 'widgets/epichealthbar' not found
```

### 原因

epichealthbar 模块通过 `ForceEnableMod` 在 LoadMods 迭代体内将未启用的
Epic Healthbar (workshop-1185229307) 注入 `ModManager.mods`。

DST 的 `kleiregistermods` 是**一次性操作**——LoadMods 在迭代开始前调用它向
C++ 引擎登记模组白名单，之后 `kleiloadlua` 只允许已登记模组的文件被加载。
注入发生在登记之后，注入的模组不在白名单内，所有文件访问均被拒绝。

尝试在注入后补调 `kleiregistermods(ModManager.mods)` 直接触发 C++ 断言崩溃：
`Assert failure 'sRegisteredMods.empty()' at modregistry.cpp(30)`。

### 修改

| 文件 | 修改内容 |
|------|---------|
| `modmain.lua` | 移除 `modimport("scripts/Auto/epichealthbar")` |
| `scripts/util/config.lua` | HEALTHBAR 注释改为 "EC 自研 modhealthbar 实体血条" |
| `scripts/screens/confighud.lua` | hint 文案去掉 "借用 Epic Healthbar" |
| `scripts/components/damagetracker.lua` | 清理 2 处 epichealthbar 引用注释 |
| `scripts/util/showmeutil.lua` | 清理 epichealthbar 引用注释 |

`HEALTHBAR_ENABLED` / `DAMAGE_ESTIMATION` 配置键保留，继续控制 EC 自研的
`damagetracker` + `modhealthbar` 血条系统。

### 参考

- DST 官方 mods.lua：`kleiregistermods(self.mods)` 在 `table.sort` 之后、迭代加载之前（一次性调用）
- C++ 源码：`modregistry.cpp:30` → `sRegisteredMods.empty()` 断言，不允许二次注册
- automedal 的正确模式：`pcall(require, "medal_defs/...")` 读取**已启用**模组文件，
  "有则优、无则退"，不依赖模组注入

---

## 2026-09-28 — quickdeploy: 修复专服客机下可部署物品右键未被替换为「部署」

### 现象

专服客机条件下，右键动作本应是「检查」的可部署物品，右键没有被替换为「部署」（悬停提示仍显示检查）。
同一物品在主机上表现正常；Alt + 右键强制部署在客机上也可用。

### 原因

`GetInventoryActions` 的覆盖钩子判定条件过宽：

```lua
for _, a in ipairs(actions) do
    if a.action == ACTIONS.TOGGLE_DEPLOY_MODE then has_toggle = true
    elseif a.action ~= ACTIONS.DEPLOY and a.action ~= ACTIONS.LOOKAT then has_other = true end
end
local is_check = has_toggle and not has_other
local is_deploy_check = not has_toggle and not has_other
```

旧判定是「扫描整张表，只要存在 TOGGLE_DEPLOY_MODE / DEPLOY / LOOKAT 之外的任何动作就不覆盖」。
客机上这张动作表里多出一条排序更低的动作（右键永远执行不到它），却把整个覆盖否掉了。

而官方两条路径取的都是**排序后的 `actions[1]`**：

- 右键执行：`prefabs/inventory_classified.lua` `local act = actions[1]` → `RemoteUseItemFromInvTile`；
  主机侧 `components/inventory.lua:2281-2296` 同样是 `local act = actions[1]`
- 悬停提示：`widgets/itemtile.lua:487-490` `actions[1]:GetActionString()`

所以 `actions[1]` 才是「右键实际会做什么 / 提示显示什么」。这也解释了 Alt 为何正常：
`is_force` 直接绕过该判定。

### 修改

`scripts/Auto/quickdeploy.lua`：

| 位置 | 修改内容 |
|------|---------|
| `AddComponentPostInit("playeractionpicker")` | 判定改为只看 `actions[1].action`：`nil / LOOKAT / TOGGLE_DEPLOY_MODE / DEPLOY` 才替换为 DEPLOY，其余（打开、吃、Drop…）保留原生行为 |
| 同文件 | 删除新增的 `AddClassPostConstruct("components/playercontroller", ...)` → `RemoteUseItemFromInvTile` 钩子（见下方「排查结论」） |
| `GLOBAL.SendRPCToServer` 拦截 | 保留；`isreleased` 维持 `true` |

### 排查结论（为何不需要额外分发钩子）

一度怀疑客机发不出 `RPC.UseItemFromInvTile(DEPLOY.code)`，理由是 `ACTIONS.DEPLOY` 在 stategraph 里有
专属 ActionHandler（`doshortaction`）会绕过 `PerformPreviewBufferedAction`。该结论**错误**：
客机玩家使用的是 `stategraphs/SGwilson_client.lua`（不是 `wilson`），其 `doshortaction` 状态的
`onenter` 里调用了 `inst:PerformPreviewBufferedAction()`，`preview_cb` 会触发，
原有 `SendRPCToServer` 改写链路本来就是通的。

同时核对确认：

- `networkclientrpc.lua` `ControllerActionButtonDeploy(player, invobject, x, z, rotation, isreleased, platform, platform_relative)`
  的参数校验（`optbool(isreleased)` 等）与本 mod 的 7 个实参逐项吻合，服务端最终执行
  `OnRemoteControllerActionButtonDeploy(invobject, Vector3(x,0,z), rotation, isreleased)`
- `isreleased = true` 与官方客户端自身写法（`not TheInput:IsControlPressed(CONTROL_CONTROLLER_ACTION)`，键鼠下即 `true`）
  以及服务端记账 `remote_controls[CONTROL_CONTROLLER_ACTION] = nil` 一致

### 影响范围

- 客机与主机的 `GetInventoryActions` 覆盖判定统一收敛到 `actions[1]`
- 反例保留：能「打开 / 吃 / 装备」的可部署物品右键行为不变
- Alt + 右键强制部署行为不变

### 验证

- **尚未实机验证**（未在专服 + 客机组合下测试）
- 建议验证：专服客机普通右键可部署物品 → 提示与执行均为「部署」；Alt + 右键仍强制部署；
  能「打开」的可部署物品不受影响
- 若报错，读 `~/Documents/Klei/DoNotStarveTogether/client_log.txt`（专服端看 `master_server_log.txt`），
  搜 `LUA ERROR stack traceback:`

### 未定位项

客机上多出的那条低优先动作来源未确认（本 mod 无 `AddComponentAction`，
`componentactions.lua` 的 INVENTORY 收集器只加 TOGGLE_DEPLOY_MODE / EAT / UNEQUIP / LOOKAT）。
疑为同时启用的其它客户端 mod 所加。新判定不依赖其身份，故不影响本次修复。

---

## 2026-09-13 — quickactions: 修复 `GetMedalIvy` 使用错误的 stackable API

### 错误

```
quickactions.lua:153: attempt to compare number with nil
```

触发场景：右键 `medal_buried_greengem`（生命绿宝石）执行「旋花藤缠绕」快捷操作时。

### 原因

`GetMedalIvy()` 的 `matchFn` 中使用了 `stack.stacksize` 直接访问字段，但 DST 的 `replica.stackable` 将堆叠数存储在 `_stacksize`（netvar）中，
通过 `:StackSize()` 方法获取，**不存在 `.stacksize` 字段**，始终为 `nil`。

即使玩家背包有 3 个旋花藤（`stacksize` 实际值可能是 1 或 3），`stack.stacksize` 永远取到 `nil`，`nil >= 3` 报错。

### 修改

`scripts/Auto/quickactions.lua:153`：`stack.stacksize >= 3` → `stack:StackSize() >= 3`

### 影响范围

- `GetMedalIvy()` 匹配函数，用于旋花藤缠绕生命绿宝石快捷操作（需要 3 个旋花藤）；之前因永远匹配不到导致快捷操作无法触发

---

## 2026-09-12 — automedal: 修复 `HasOriginMedal` 调用方式

### 问题背景

勋章模组（Functional Medal / `1909182187`）更新后，`HasOriginMedal` 被定义为 `EntityScript` 实例方法：

```lua
-- medal_hook.lua:836
EntityScript.HasOriginMedal = function(self, tag)
    if self:HasTag("has_origin_medal") then
        if tag == nil then return true end
        ...
    end
end
```

调用方式应为 `entity:HasOriginMedal(tag)`（实例方法冒号调用）。

### 问题

`automedal.lua` 中 4 处攻击勋章链的逻辑以全局函数方式调用 `GLOBAL.HasOriginMedal(ThePlayer, tag)`，
但 `GLOBAL.HasOriginMedal` 始终为 `nil`（未定义全局函数），导致：

- 所有本源勋章校验**静默失效**（`nil and ...` 短路为 `false`）
- 浴火双判定（本源+浴火+晶甲）永远不触发，攻击勋章链继续切换打散本源组合
- 沉默判定（本源+沉默）同样失效，韦斯伤害累积加成丢失
- 玩家报 `'HasOriginMedal' is not declared`（DST 模组严格模式）

### 修改

| 行号 | 文件 | 修改内容 |
|------|------|---------|
| ~L1895 | `scripts/Auto/automedal.lua` | `GLOBAL.HasOriginMedal(ThePlayer, "has_bathfire_medal")` → `ThePlayer:HasOriginMedal("has_bathfire_medal")` |
| ~L1903 | `scripts/Auto/automedal.lua` | `GLOBAL.HasOriginMedal(ThePlayer, "mime")` → `ThePlayer:HasOriginMedal("mime")` |
| ~L1927 | `scripts/Auto/automedal.lua` | `GLOBAL.HasOriginMedal(ThePlayer, "has_bathfire_medal")` → `ThePlayer:HasOriginMedal("has_bathfire_medal")` |
| ~L1934 | `scripts/Auto/automedal.lua` | `GLOBAL.HasOriginMedal(ThePlayer, "mime")` → `ThePlayer:HasOriginMedal("mime")` |

### 影响范围

- `HandleAttackChain` 融合箱分支（逐档连续换入）：浴火/沉默 stop 判定
- `HandleAttackChain` 非融合箱分支（单勋章直接装备）：浴火/沉默 return 判定

### 验证

- 日志检查：无 LUA ERROR / MOD ERROR
- `automedal.lua` 内已无 `GLOBAL.HasOriginMedal` 残留