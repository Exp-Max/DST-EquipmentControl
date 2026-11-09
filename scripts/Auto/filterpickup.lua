local CraftUtil        = require "util/craftutil"
local InventoryUtil         = require "util/inventoryutil"
local ActionUtil            = require "util/actionutil"
local FileSystem            = require "util/filesystem"
local Say                   = require "util/say"
local TintService           = require "util/tintservice"
local TheInput              = GLOBAL.TheInput
local MOD_EQUIPMENT_CONTROL = GLOBAL.MOD_EQUIPMENT_CONTROL
local KeybindService        = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE
local EQUIPSLOTS            = GLOBAL.EQUIPSLOTS
local ACTIONS               = GLOBAL.ACTIONS
local CanEntitySeeTarget    = GLOBAL.CanEntitySeeTarget
local TOOLACTIONS           = GLOBAL.TOOLACTIONS
local BufferedAction        = GLOBAL.BufferedAction
local TheSim                = GLOBAL.TheSim
local UpvalueHacker         = require "util/upvaluehacker"
local PlayerController      = require "components/playercontroller"
local Namemap               = require "util/blueprint_namemap"

-- Config
local PRIORITIZE_VALUABLE    = MOD_EQUIPMENT_CONTROL.CONFIG.PRIOTIZE_VALUABLE_ITEMS
local IGNORE_KNOWN_BLUEPRINT = MOD_EQUIPMENT_CONTROL.CONFIG.IGNORE_KNOWN_BLUEPRINT
local MEAT_MODE              = MOD_EQUIPMENT_CONTROL.CONFIG.MEAT_PRIORITIZATION_MODE
local Filter_File        = "mod_equipment_control_pickup_filter.txt"
local PrioritizedPickups = {
    greengem                        = .5,  --绿宝石
    yellowgem                       = .45, --黄宝石
    orangegem                       = .4,  --橙宝石
    deerclops_eyeball               = 2,   --巨鹿眼球
    minotaurhorn                    = 1,   --守护者之角
    hivehat                         = 2,   --蜂王冠
    dragon_scales                   = 1,   --鳞片
    bearger_fur                     = 1,   --熊皮
    klaussackkey                    = 2,   --麋鹿茸
    shadowheart                     = 1,   --暗影心房
    skeletonhat                     = 3,   --骨头头盔
    armorskeleton                   = 3,   --骨头盔甲
    shroom_skin                     = 1,   --蘑菇皮
    ["Blue Funcap Blueprint"]       = 3,   --蓝蘑菇帽蓝图
    ["Green Funcap Blueprint"]      = 3,   --绿蘑菇帽蓝图
    ["Red Funcap Blueprint"]        = 3,   --红蘑菇帽蓝图
    ["Mushlight Blueprint"]         = 3,   --蘑菇灯蓝图
    ["Glowcap Blueprint"]           = 3,   --菌伞灯蓝图
    ["Scaled Furnace Blueprint"]    = 2,   --龙鳞火炉蓝图
    ["Bundling Wrap Blueprint"]     = 3,   --捆绑包装蓝图
    ["Winged Sail Kit Blueprint"]   = 3,   --翅膀帆包蓝图
    ["Feathery Canvas Blueprint"]   = 3,   --羽毛画布蓝图
    ["The Lazy Deserter Blueprint"] = 1,   --懒人传送塔蓝图
    ["Strident Trident Blueprint"]  = 3    --刺耳三叉戟蓝图
}

-- Logic
local PickupFilter = {prefabs = {}}

local function SavePickupFilter()
    local list = {}
    for p in pairs(PickupFilter.prefabs) do
        table.insert(list, p)
    end
    FileSystem:SaveTableToFile(Filter_File, list)
end

local function LoadPickupFilter(onLoaded)
    FileSystem:LoadTableFromFile(
        Filter_File,
        function(list)
            for _, p in ipairs(list or {}) do
                PickupFilter.prefabs[p] = true
            end
            if onLoaded then
                onLoaded()
            end
        end
    )
end

local function KnowsBlueprint(bp)
    if not bp or bp.prefab ~= "blueprint" then
        return false
    end
    local id =
        (bp.replica and bp.replica.blueprint and
        (bp.replica.blueprint.recipename:value() or
            (bp.replica.blueprint.GetRecipeName and bp.replica.blueprint:GetRecipeName()))) or
        Namemap.DisplayToId(bp.name)
    return id and CraftUtil:KnowsRecipe(id)
end

local function IsMeat(ent)
    return ent:HasTag("meat")
end

local function Score(ent)
    if PickupFilter.prefabs[ent.prefab] then
        return -math.huge
    end

    if IsMeat(ent) and MEAT_MODE == "IGNORE" then
        return -math.huge
    end

    if ent.prefab == "blueprint" and KnowsBlueprint(ent) and IGNORE_KNOWN_BLUEPRINT then
        return -math.huge
    end

    if IsMeat(ent) then
        if MEAT_MODE == "FIRST" then
            return 100
        end
        if MEAT_MODE == "LAST" then
            return -100
        end
    end

    if PRIORITIZE_VALUABLE then
        return PrioritizedPickups[ent.name] or PrioritizedPickups[ent.prefab] or 0
    end

    return 0
end

local function TintIfFiltered(inst)
    -- 没有任何过滤项时直接返回：AddPrefabPostInitAny 对每个生成的实体都会回调，
    -- 空集合下本来就是空操作，短路掉可省掉实体的字段访问
    if next(PickupFilter.prefabs) == nil then
        return
    end
    if inst and inst.AnimState and PickupFilter.prefabs[inst.prefab] then
        TintService:AddColor(inst)
    end
end

-- 拾取过滤默认加载：功能开关入口统一收归 confighud，不再受 modinfo 门控
LoadPickupFilter(
    function()
        for _, ent in pairs(GLOBAL.Ents) do
            if PickupFilter.prefabs[ent.prefab] then
                TintService:AddColor(ent)
            end
        end
    end
)

AddPrefabPostInitAny(TintIfFiltered)

-- =========================================================================
-- 内置动作屏蔽（prefab 级，无需按键添加）
-- -------------------------------------------------------------------------
-- 走近 假人/原型机/仓储机器人/锯片/花 时按动作键(空格)常会误触发互动；这里在
-- actionutil 的「动作屏蔽」通道（通道 H）上按 prefab/标签 注册规则，命中即抑制该动作，
-- 动作键改为无作为，仍可主动点击触发。
-- 与用户手动拾取黑名单(PickupFilter)互补：后者按实体实例、按键添加，这里是固定规则。
-- 开销极低：只在官方算完动作后做一次命中判断。
-- 移植自 Lazy Controls 的 actions_filter（workshop-2111412487），但改用更稳健的
-- "返回后抑制"而非 upvalue 改写 GetActionButtonAction / 删 COMPONENT_ACTIONS.SCENE。
--
-- 为什么 sources = { "button" }：这些规则的本意是"动作键误触发"（作者原注：
--   "动作键改为无作为，仍可主动点击触发"），鼠标点击要照常可用 —— 花仍能点着摘、
--   仓储机器人仍能点着取物。去掉 sources 即变成"全路径精准屏蔽"（鼠标/排队论也拦），
--   单条规则切换；通道 H 的其它用法不受影响。
-- enabled 实时读 CONFIG：confighud 的「动作屏蔽」开关即时生效（原先是加载期捕获，开关无效）。
-- =========================================================================

local function ActionsBlockEnabled()
    return MOD_EQUIPMENT_CONTROL.CONFIG.ACTIONS_BLOCK == true
end

-- 命中规则：act.target 满足条件且动作是 action 时屏蔽
--   · 假人 sewing_mannequin（含带娃的 doll 变体）：空格激活换装
--   · 原型机：所有带 prototyper 标签的 crafting station（科学机器/炼金引擎等），空格误激活原型
--   · 仓储机器人 storage_robot（带 storagerobot 标签）：空格把物品取出
--   · 锯片 carpentry_station（带 carpentry_station 标签）：空格取出
--   · 花 flower（带 flower 标签）：空格摘花
local ACTIONS_BLOCK_RULES = {
    { action = "ACTIVATE",
      opts = { target_prefab = { "sewing_mannequin", "sewing_mannequin_doll" } } },
    { action = "ACTIVATE",
      opts = { target_tag = "prototyper" } },
    { action = "PICKUP",
      opts = { target_match = function(t) return t.prefab == "storage_robot" or t:HasTag("storagerobot") end } },
    { action = "TAKEITEM",
      opts = { target_match = function(t) return t.prefab == "carpentry_station" or t:HasTag("carpentry_station") end } },
    { action = "PICK",
      opts = { target_match = function(t) return t.prefab == "flower" or t:HasTag("flower") end } },
}

local function RegisterActionsBlock(inst)
    if inst._ec_filterpickup_block_registered then return end
    inst._ec_filterpickup_block_registered = true
    for _, rule in ipairs(ACTIONS_BLOCK_RULES) do
        ActionUtil:BlockAction(inst, rule.action, {
            sources      = { "button" },
            enabled      = ActionsBlockEnabled,
            right        = rule.opts.right,
            target_prefab    = rule.opts.target_prefab,
            target_tag       = rule.opts.target_tag,
            target_match     = rule.opts.target_match,
            invobject_prefab = rule.opts.invobject_prefab,
        })
    end
end

local GetPickupAction = UpvalueHacker.GetUpvalue(PlayerController.GetActionButtonAction, "GetPickupAction")
local PICKUP_EXCLUDE_TAGS = UpvalueHacker.GetUpvalue(PlayerController.GetActionButtonAction, "PICKUP_TARGET_EXCLUDE_TAGS")

local PICKUP_TAGS = { "_inventoryitem", "pickable" }

-- 扫描缓存：按住动作键自动重复采集时 GetActionButtonAction 每帧被调用，
-- 每帧都 FindEntities + 逐实体 Score + 排序代价偏高。
-- 缓存按时间 + 玩家位置 + directwalking 失效，命中窗口内直接复用，
-- 失效判定后仍会用 GetPickupAction 校验目标是否可取，拿不到就退回 nil。
local SCAN_CACHE_TTL = 0.1
local _scan_cache = { time = -1, x = 0, z = 0, direct = nil, scored = nil }

local function GetScoredPickups(x, y, z, direct)
    local c = _scan_cache
    local now = GetTime()
    if c.scored ~= nil
        and now - c.time < SCAN_CACHE_TTL
        and c.direct == direct
        and math.abs(c.x - x) < .5
        and math.abs(c.z - z) < .5
    then
        return c.scored
    end

    local ents = TheSim:FindEntities(x, y, z, direct and 3 or 6, nil, PICKUP_EXCLUDE_TAGS, PICKUP_TAGS)

    -- 预计算 score 避免排序和遍历时重复调用 Score
    local scored = {}
    for i = 1, #ents do
        scored[i] = { ent = ents[i], score = Score(ents[i]) }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)

    c.time, c.x, c.z, c.direct, c.scored = now, x, z, direct, scored
    return scored
end

AddClassPostConstruct("components/playercontroller",function(self)
    if self.inst ~= GLOBAL.ThePlayer then
        return
    end

    -- 内置动作屏蔽改为在 actionutil 的动作屏蔽通道上注册规则（见文件上方 ACTIONS_BLOCK_RULES）。
    -- 本回调跑在组件构造期，此刻 inst.components.playercontroller 还没赋值，故这里只是"登记规则"；
    -- 真正的钩子安装由 actionutil 的 AddComponentPostInit 挂载点补上（那时组件已挂到实体）。
    RegisterActionsBlock(self.inst)

    local _orig = self.GetActionButtonAction
    function self:GetActionButtonAction(force_target, ...)
        local act = _orig(self, force_target, ...)
        if ActionUtil:IsValidBufferedAction(act) and (act.action == ACTIONS.PICK or act.action == ACTIONS.PICKUP) and
                ((PickupFilter.prefabs[act.target.prefab]) or (IsMeat(act.target) and MEAT_MODE == "IGNORE")) then
            local tool = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)

            local x, y, z = self.inst.Transform:GetWorldPosition()
            local scored = GetScoredPickups(x, y, z, self.directwalking)

            for i = 1, #scored do
                local entry = scored[i]
                -- 缓存窗口内实体可能已被拾取/移除，先校验有效性
                if entry.ent:IsValid()
                    and entry.score ~= -math.huge
                    and not PickupFilter.prefabs[entry.ent.prefab]
                    and CanEntitySeeTarget(self.inst, entry.ent) then
                    local a = GetPickupAction(self, entry.ent, tool)
                    if a and (a == ACTIONS.PICK or a == ACTIONS.PICKUP) then
                        local newact = BufferedAction(self.inst, entry.ent, a, tool)
                        -- 重选出来的候选也要过一遍动作屏蔽：这里是"替换"不是"放行"，
                        -- 若替换目标被屏蔽（如换成旁边一朵花），直接跳过继续找下一个候选。
                        -- source 用 "button"：这个替换动作接下来正是由动作键(空格)执行的，
                        -- 与主路径同源，只拦动作键的规则（sources = {"button"}）才会生效
                        if not ActionUtil:IsActionBlockedFor(self.inst, {
                                source = "button", buffaction = newact,
                            }) then
                            return newact
                        end
                    end
                end
            end
            return nil
        end
        return act
    end
end)

local function CanBePickedUp(ent)
    return ent and ent.replica.inventoryitem and ent.replica.inventoryitem:CanBePickedUp() or
        ent and ent:HasTag("pickable")
end

local function AddToFilter(prefab)
    PickupFilter.prefabs[prefab] = not PickupFilter.prefabs[prefab] or nil
    SavePickupFilter()
    return PickupFilter.prefabs[prefab]
end

KeybindService:AddKey("PICKUP_FILTER",function()
    local ent = TheInput:GetWorldEntityUnderMouse()
    if not CanBePickedUp(ent) then
        Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.CANNOT_FILTER)
        return
    end

    local added = AddToFilter(ent.prefab)
    local label = ent.name or ent.prefab

    Say(
        added and string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.FILTER_ADD, label) or
            string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.FILTER_REMOVE, label)
    )

    TintService:TintAllByPrefab(ent.prefab, added and true or false)
end)

local meatModes = {"DISABLED", "FIRST", "LAST", "IGNORE"}

local currentMeatPrioritizationMode = 1
for i, m in ipairs(meatModes) do
    if m == MEAT_MODE then
        currentMeatPrioritizationMode = i
        break
    end
end

local function SetMeatModeByIndex(idx)
    currentMeatPrioritizationMode = idx
    MEAT_MODE = meatModes[idx]
    MOD_EQUIPMENT_CONTROL.CONFIG.MEAT_PRIORITIZATION_MODE = MEAT_MODE   -- 持久化
end

-- 存档里的值若不在档位表内（旧版本残留/手工改过），回落到第一档，
-- 否则 currentMeatPrioritizationMode 与 MEAT_MODE 会错位、循环切换跳档。
if MEAT_MODE ~= meatModes[currentMeatPrioritizationMode] then
    SetMeatModeByIndex(1)
end

KeybindService:AddKey("MEAT_PRIORITIZATION_MODE",function()
    local nextIdx = currentMeatPrioritizationMode % #meatModes + 1
    SetMeatModeByIndex(nextIdx)

    Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.MEAT_MODE, MEAT_MODE))
end)

-- 暴露肉类优先模式，供 confighud 的"肉类优先"按钮显示当前档位
MOD_EQUIPMENT_CONTROL.GetMeatMode = function()
    return ({ DISABLED = "禁用", FIRST = "优先", LAST = "置后", IGNORE = "忽略" })[MEAT_MODE] or MEAT_MODE
end