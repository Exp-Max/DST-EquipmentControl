local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local ActionUtil = require "util/actionutil"
local WorldUtil = require "util/worldutil"
local PlayerUtil = require "util/playerutil"
local ConfigUtil = require "util/configutil"

--
-- Events
--

local function OnGetBirdEvent(inst, data, target)
    if data and data.item and data.item:HasTag("bird") then
        SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, ACTIONS.STORE.code, data.item, target)
    end

    inst.components.eventtracker:DetachEvent("OnGetBirdEvent")
end

local function OnBuildFossil(inst, data, target)
    if data and data.item and data.item.prefab == "fossil_piece" and target:HasTag("workrepairable") then
        local act = BufferedAction(inst, target, ACTIONS.REPAIR, data.item)

        if inst.components.locomotor == nil then
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
        else
            act.preview_cb = function()
                SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
            end
        end

        inst.components.playercontroller:DoAction(act)
    else
        inst.components.eventtracker:DetachEvent("OnBuildFossil")
    end
end

local TrackTimeOut = FRAMES * 90

local function GetTrack()
    local time = GetTime()

    local track
    while GetTime() - time < TrackTimeOut do
        track = GetClosestInstWithTag("dirtpile", ThePlayer, 60)

        if track then
            break
        end

        Sleep(FRAMES)
    end

    Sleep(FRAMES * 3)

    return track
end

local function DoTracking()
    ThePlayer.components.eventtracker:DetachEvent("DoTracking")
    StartThread(function()
        local track = GetTrack()

        if not track then
            return
        end

        ThePlayer.components.eventtracker:AddEvent("onremove","DoTracking",DoTracking,track)

        local act = BufferedAction(ThePlayer, track, ACTIONS.ACTIVATE)
        local position = track:GetPosition()

        if ThePlayer.components.locomotor == nil then
            SendRPCToServer(RPC.LeftClick, act.action.code, position.x, position.z, track)
        else
            act.preview_cb = function()
                SendRPCToServer(RPC.LeftClick, act.action.code, position.x, position.z, track)
            end
        end

        ThePlayer.components.playercontroller:DoAction(act)
    end, "TrackingThread")
end

--
-- 通用库存扫描器
-- 统一遍历库存+背包+容器，避免重复扫描
-- @param matchFn(item) -> boolean   物品匹配函数
-- @param priorityFn(item) -> number 优先级函数（有则返回最高优先级物品，无则返回首个匹配）
-- @param equips                     是否包含装备物品
-- @param earlyReturnFn(item) -> boolean 提前返回条件（有则满足条件时立即返回该项）
local function ScanInventory(matchFn, priorityFn, equips, earlyReturnFn)
    local bestItem, bestPriority = nil, -math.huge

    for _, item in pairs(InventoryUtil:GetPlayerInventory(equips, nil, true)) do
        if matchFn(item) then
            if earlyReturnFn and earlyReturnFn(item) then
                return item
            end
            if not priorityFn then
                return item
            end
            local priority = priorityFn(item)
            if priority > bestPriority then
                bestPriority = priority
                bestItem = item
            end
        end
    end

    return bestItem
end

--
-- Helpers
--

local function GetItemFromInventory(prefab)
    return ScanInventory(function(item) return item.prefab == prefab end)
end

local function GetDevourerFood()
    return ScanInventory(
        function(item) return item.prefab == "medal_spacetime_lingshi" or item.prefab == "medal_spacetime_snacks" end,
        function(item) return item.prefab == "medal_spacetime_lingshi" and 2 or 1 end
    )
end

local function GetBloodSugar()
    return GetItemFromInventory("spice_blood_sugar")
end

-- 空白/仿制/融合勋章（融合仪式目标）：融合箱带 multivariate_certificate 标签，
-- 空白与其仿制模板按 prefab 判定（与 automedal 的 IsBlankOrFusion 同口径）。
local function IsBlankOrFusion(item)
    if item == nil then return false end
    if item:HasTag("multivariate_certificate") then return true end
    local p = item.prefab
    return p == "blank_certificate" or p == "copy_blank_certificate"
end

-- 可食用调料：源模组给"可直接吃的调料粉"打的标签（medal_actions.lua:2900 的 testfn 用它判定），
-- 不列具体调料 prefab 清单，源模组/其它模组新增的可吃调料自动适配。
local function IsEdibleSpice(item)
    return item ~= nil and item:HasTag("ediblespice")
end

-- 噬灵勋章（仅基础档 devour_soul_certificate 可用于升级；中级/大级不行）
-- SOULMEDALLEVELUP 的 fn/testfn 限定 invobject.prefab=="devour_soul_certificate"，故按 prefab 精确取。
local function GetDevourSoulMedal()
    return GetItemFromInventory("devour_soul_certificate")
end

-- 空白勋章（POWERABSORB 的 fn 校验 invobject:HasTag("blank_certificate")，故按标签取）
local function GetBlankMedal()
    return ScanInventory(function(item) return item:HasTag("blank_certificate") end)
end

-- 黑暗灵魂(rage_krampus_soul)末段爆魂的本地检测。
-- 背景：生命周期 60 秒由服务端 _task 控制，drop_soul_times 也在 ismastersim 分支后才创建，
--   均不复制到客户端 → 客户端无从得知还剩几秒，且能力勋章全程没有 PushEvent 可供监听。
-- 唯一客户端可见信号：dropSoul 每 3 秒掉 1-3 个 wortox_soul，而"倒数第二下"一次性掉 8 个
--   （krampus_soul.lua:84-86，注释即"提醒玩家即将结束"）。
-- 故按"附近 wortox_soul 数量"判定进入末段；结果按时间缓存，避免每次悬停都做 FindEntities。
local SOUL_BURST_RADIUS = 8
local SOUL_BURST_COUNT = 5
local SOUL_COUNT_CACHE_INTERVAL = 0.25
local _soul_count_cache = { t = -1, n = 0 }

local function CountNearbySouls()
    local now = GetTime()
    if now - _soul_count_cache.t < SOUL_COUNT_CACHE_INTERVAL then
        return _soul_count_cache.n
    end

    local n = 0
    if ThePlayer ~= nil and ThePlayer.Transform ~= nil then
        local x, _, z = ThePlayer.Transform:GetWorldPosition()
        for _, e in ipairs(TheSim:FindEntities(x, 0, z, SOUL_BURST_RADIUS, nil, { "INLIMBO" })) do
            if e.prefab == "wortox_soul" then
                n = n + 1
            end
        end
    end

    _soul_count_cache.t = now
    _soul_count_cache.n = n
    return n
end

-- 是否已进入爆魂末段（此时黑暗灵魂即将消失，吸收应优先于污染）
local function IsSoulBursting()
    return CountNearbySouls() >= SOUL_BURST_COUNT
end

-- 黑暗灵魂：单击启动自动持久化污染，末段(爆魂)自动切换为吸收。
-- 设计要点（按实测反馈）：
--   ① 灵魂会随机改变位置 → 线程始终锁定同一实体实例(target)，不依赖固定坐标，DoAction 直接作用于该实体；
--   ② 单击启动、自主移动打断即可 → 循环不依赖"按住右键"，玩家走开(PlayerUtil:IsMoving)即停；
--   ③ 每轮重新走 GetRMBOverride 取当前最优动作（未爆魂且有血糖→污染，爆魂→吸收），
--   执行后等动作结束再循环，直到灵魂失效 / 无可用动作(未爆魂且无血糖) / 玩家走开。
local DARK_SOUL_THREAD = "DarkSoulAutoThread"
local _dark_soul_auto_active = false

-- 统一停止：先杀线程再复位标志。线程被 KillThreadsWithID 杀掉时不会执行到末尾，
-- 若只在线程末尾复位，标志会残留并吞掉后续点击。
local function StopDarkSoulAuto()
    KillThreadsWithID(DARK_SOUL_THREAD)
    _dark_soul_auto_active = false
end

local function IsDarkSoul(target)
    return target ~= nil and target.prefab == "rage_krampus_soul"
end

local function IsDarkSoulAutoEnabled()
    return MOD_EQUIPMENT_CONTROL.CONFIG["QUICK_ACTION_MEDAL_SOUL_AUTO"]
end

-- 玩家是否正在自主移动（WASD/鼠标行走）由 PlayerUtil:IsMoving() 提供（已下沉到 playerutil）。
-- 动作执行期间玩家被锁定(busy)不会移动，故在两轮动作之间轮询即可区分
-- "玩家主动走开"与"动作自身的自动寻路"，用作自动线程的打断判据。

-- 等待本次动作执行结束。
-- 注意：PlayerController 的 busy 状态由 IsBusy()（玩家 "busy" 标签 / sg 的 "busy" 状态标签）表示，
-- 组件自身的 self.busy 字段并不会被赋值，故不能用 self.busy 判断。
-- 同时必须等 GetBufferedAction() 清空——否则下一轮 DoAction 会命中 PlayerController:DoAction
-- 内的"重复动作去重"（action+target+pos 相同直接 return 丢弃），导致自动轮次全部静默失效。
local function WaitDarkSoulActionDone(self, max_seconds)
    local step = FRAMES * 5
    local waited = 0
    -- 至少等一个 step 再判定：动作可能尚未起手，立即返回会让下一轮空转。
    -- 之后只在仍 busy / BufferedAction 未清空时继续等，故调用方无需再叠固定 Sleep。
    repeat
        Sleep(step)
        waited = waited + step
        local buffered = self.inst:GetBufferedAction()
        if not self:IsBusy() and buffered == nil then break end
    until waited >= max_seconds
end

local function GetCooldownableItem()
    return ScanInventory(function(item) return item:HasTag("cooldownable") end)
end

local function GetMandrakeItem()
    return ScanInventory(
        function(item) return item.prefab == "mandrake_seeds" or item.prefab == "mandrake" end,
        function(item) return item.prefab == "mandrake_seeds" and 2 or 1 end
    )
end

local function GetMatchingScion(target)
    return ScanInventory(
        function(item)
            return item:HasTag("graftingscion") and item.treename == target.prefab
        end
    )
end

local function GetMedalIvy()
    return ScanInventory(
        function(item)
            if item.prefab ~= "medal_ivy" then return false end
            local stack = item.replica.stackable
            return stack and stack:StackSize() >= 3
        end
    )
end

local function GetEggPriority(item)
    local priority = 0

    if item:HasTag("spoiled") then
        priority = 4 - (ItemUtil:GetHunger(item) * .01)
    elseif item:HasTag("monstermeat") then
        priority = 3
    elseif item:HasTag("badfood") then
        priority = 2.5
    elseif item:HasTag("preparedfood") then
        priority = item:HasTag("stale") and 1 or .5
    elseif item:HasTag("stale") then
        priority = 1.5
    elseif item.prefab == "bird_egg_cooked" then
        priority = 1.6
    end

    return priority
end

local invalid_foods =
{
    "bird_egg",
    "rottenegg",
    "monstermeat",
}

local function GetBirdFood()
    return ScanInventory(
        function(item) return not table.contains(invalid_foods, item.prefab) and item:HasTag("edible_MEAT") end,
        GetEggPriority
    )
end

local function GetKlausSackKey()
    return ScanInventory(
        function(item) return item:HasTag("klaussackkey") end,
        nil, nil,
        function(item) return item.prefab == "klaussackkey" end
    )
end

local function GetDisplayName(item)
    local str = ""

    local adjective = item:GetAdjective()
    if adjective then
        str = adjective .. " "
    end

    return str .. item:GetDisplayName()
end

local function GetBird()
    return ScanInventory(function(item) return item:HasTag("bird") end)
end

local function IsExtinguishable(target)
    return not target:HasTag("campfire")
        and (target:HasTag("fire") or target:HasTag("smolder"))
end

local function IsExtinguishItem(item)
    return item.prefab == "waterballoon"
        or item:HasTag("extinguisher")
        or (item:HasTag("repairer") and item:HasTag("frozen"))
end

local function GetExtinguishItem()
    return ScanInventory(function(item) return IsExtinguishItem(item) end, nil, true)
end

-- =============================================
-- 自动勋章 ↔ 快速动作联动（数据驱动）
-- 扫描勋章：库存有对应勋章组 + 鼠标目标形态 + 可选附加条件（如月圆）→ 显示快速动作；
-- 按下时先由自动勋章模块装备对应勋章组、再执行动作（与 automedal 共享 MEDAL 动作→勋章组映射）
-- =============================================

-- 自动勋章模块导出的联动 API（modmain 环境全局，运行时惰性取用）
local function GetAutoMedalAPI()
    local mec = rawget(_G, "MOD_EQUIPMENT_CONTROL")
    return mec and mec.automedal_api or nil
end

-- 勋章快速动作定义表（数据驱动；group 省略时由自动勋章模块的动作→勋章组映射推导所需勋章）
-- 字段：config=开关键, action=ACTIONS 动作名, item=固定物品prefab(可选),
--       itemfn=动态取物函数(可选), activefn=鼠标持有物判定(可选,与 item/itemfn 互斥),
--       targetfn=目标前置, conditionfn=附加前置(如月圆,可选),
--       stringfn=动作名, group=显式勋章组(可选,优先于动作推导),
--       origin=勋章须在本源融合箱内满足(可选), with_harvest=主勋章外再叠丰收增益(可选)
--       origin_combo=本源组合勋章列表(可选,按重要性排序:主勋章在前+可选增益;统一走 EquipCombo)
local MedalQuickActionDefs = {
    -- 吸收黑暗灵魂：两条并列，按"噬灵优先、空白回退"排序（表内靠前者优先命中）。
    -- 二者都不需要玩家具备任何能力标签（SOULMEDALLEVELUP 无 doer 条件；POWERABSORB 只要 player），
    -- 且都是"拿物品对场景目标使用"，故不带 group → prefabs 为 nil → 走普通 SceneUse
    -- （ControllerUseItemOnSceneFromInvTile），不切勋章，正是"对场景使用那套"。
    -- 时机：爆魂末段(IsSoulBursting)优先吸收；未爆魂时若没有血糖可污染，也让吸收可用。
    {
        config = "QUICK_ACTION_MEDAL_SOUL_ABSORB",
        action = "SOULMEDALLEVELUP",
        itemfn = GetDevourSoulMedal,  -- 基础噬灵勋章 → 升级为中级噬灵
        targetfn = function(target) return target and target.prefab == "rage_krampus_soul" end,
        -- 揣着噬灵证书(意图升级)时，让升级优先于污染——否则只要有血糖就一直污染，
        -- 升级窗口只在"血糖耗尽/爆魂末段"出现，太短且"移开再移回"会因血糖仍在而回退成污染。
        conditionfn = function() return IsSoulBursting() or GetBloodSugar() == nil end,
        stringfn = function() return "吸收 (噬灵升级)" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_SOUL_ABSORB",
        action = "POWERABSORB",
        itemfn = GetBlankMedal,  -- 无噬灵 → 回退空白勋章，吸收得到噬灵勋章
        targetfn = function(target) return target and target.prefab == "rage_krampus_soul" end,
        conditionfn = function() return IsSoulBursting() or GetBloodSugar() == nil end,
        stringfn = function() return "吸收 (空白勋章)" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_POLLUTE",
        action = "MEDALPOLLUTE",
        itemfn = GetBloodSugar,
        targetfn = function(target) return target and target.prefab == "rage_krampus_soul" end,
        -- 源码 fn/testfn 要求 doer:HasTag("seasoningchef")：该标签仅 final 主厨勋章 headchef_certificate 佩戴后赋予。
        -- 故闸门精确要求"拥有 headchef_certificate"，由 AutoEquipMedal 戴上来满足标签（标签是佩戴结果，非前置，故不放 conditionfn）。
        group = { "headchef_certificate" },
        -- 本源组合[主厨+巧手]：巧手在本源内 → has_handy_medal →
        -- medal_dolongestaction 用时减半（medal_sg.lua:235）；拿不到本源则由通用方法回退单戴主厨。
        origin_combo = { "headchef_certificate", "handy_certificate" },
        stringfn = function() return "污染" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_PLANT_MANDRAKE",
        action = "MAKEMANDRAKEPLANT",
        itemfn = GetMandrakeItem,
        targetfn = function(target) return target and target.prefab == "mound" and not target:HasTag("DIG_workable") end,
        -- 前置与服务端 MAKEMANDRAKEPLANT.fn 一致：has_transplant_medal(由动作→勋章组推导强制) 且 (isfullmoon|inmoonlight|HasOriginMedal)
        -- 本源融合勋章(origin_certificate)佩戴时赋予 has_origin_medal 标签 → 无需月圆即可种植
        conditionfn = function()
            return WorldUtil:IsFullMoon() or (ThePlayer and ThePlayer:HasTag("inmoonlight"))
                or (ThePlayer and ThePlayer:HasTag("has_origin_medal"))
        end,
        stringfn = function(item) return "种植 (" .. (item and item.name or "曼德拉") .. ")" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_BURY_GREENGEM",
        action = "GREENGEMPLANT",
        item = "greengem",
        targetfn = function(target) return target and target.prefab == "mound" and not target:HasTag("DIG_workable") end,
        stringfn = function(item) return "埋入 (" .. (item and item.name or "绿宝石") .. ")" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_TREE_LEVEL_UP",
        action = "MEDAL_FRUIT_TREE_LEVEL_UP",
        itemfn = GetMatchingScion,
        -- 收窄到嫁接树（砧木桩 / 可升级树），避免任意有效实体误命中
        targetfn = function(target) return target and (target.prefab == "medal_fruit_tree_stump" or target.TreeLevelUp ~= nil) end,
        stringfn = function(item) return "升级 (" .. (item and item.name or "接穗") .. ")" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_WORMWOOD_FLOWER",
        action = "WORMWOODFLOWERPLANT",
        itemfn = GetMedalIvy,
        targetfn = function(target) return target and target.prefab == "medal_buried_greengem" end,
        -- 源码 fn/testfn 仅判 TheWorld.state.isfullmoon（不含 inmoonlight，与曼德拉草/变蘑菇树不同）
        conditionfn = function() return WorldUtil:IsFullMoon() end,
        stringfn = function(item) return "缠绕 (" .. (item and item.name or "旋花藤") .. ")" end,
    },
    {
        config = "QUICK_ACTION_MEDAL_MAKE_COOLDOWN",
        action = "MAKECOOLDOWN",
        itemfn = GetCooldownableItem,
        -- 冷源判定走底层：不再硬编码冷源表。原写法复刻了能力勋章 testfn 的
        --   (blueflame and fire) or prefab=="staffcoldlight"
        -- 但冷星/极光 staffcoldlight 没有任何冷标签（冷热只体现在 heater 组件，客户端不可见），
        -- 只能按 prefab 判；而该组合的权威定义只存在于能力勋章注册的 testfn 里，
        -- 复刻会漂移、也会漏掉其它模组新增的冷源。
        -- 改为直接问游戏"该可冷却物品对该目标能否执行 MAKECOOLDOWN"
        -- （ActionUtil:AcceptsUseItemAction，复用已注册的 component action），
        -- 由游戏裁决，模组新增冷源自动适配。
        targetfn = function(target)
            local item = GetCooldownableItem()
            return item ~= nil and ActionUtil:AcceptsUseItemAction(item, target, "MAKECOOLDOWN")
        end,
        -- 源码 fn/testfn 要求 doer:HasTag("expertchef")。赋予该标签的勋章有三枚：
        --   level chef_certificate、final headchef_certificate，以及浴火勋章 bathingfire_certificate
        --   （MEDAL.bathingfire_certificate 的标签表含 expertchef，也能降温）。
        -- 原列表漏了浴火，导致"只有浴火"时闸门判定无降温来源 → 对冷源不注入"冷却"动作。
        -- 闸门精确要求"拥有三者之一"，由 AutoEquipMedal 戴上来满足标签（标签是佩戴结果，非前置，故不放 conditionfn）。
        group = { "chef_certificate", "headchef_certificate", "bathingfire_certificate" },
        stringfn = function(item) return "冷却 (" .. (item and item.name or "物品") .. ")" end,
    },
    {
        -- 书本阅读：切换智慧勋章(final)后阅读。只做物品栏分支（HUD 通道）。
        -- 物品栏书本 → 由 actionutil 的格子通道前置处理（PrepareBookRead 戴智慧勋章），点击仍走官方链路；
        --   必须钩 replica：物品栏右键是 InvSlot:UseItem → replica:UseItemFromInvTile，不经 PlayerController:OnControl。
        -- 地面书本 → 完全不接管：实测原版地面书只有左键拾取、右键为空（无阅读动作），
        --   此前日志里的 RMBaction=阅读 是本模组自己注入的，并非原版行为，故不再注入、与原版一致。
        -- inspect_only=true：本 def 不参与地面/场景目标的快速动作注入，仅供物品栏检查接管通道使用。
        -- 暗影秘典(waxwelljournal)等法术书被 IsBook 排除且阅读动作无标准 code，交游戏原生右键、不接管。
        action = "READ",
        targetfn = function(target) return target and ItemUtil:IsBook(target) end,
        group = { "wisdom_certificate" },
        invobject_target = true,  -- 目标可能是背包内书本 → 走 HUD 而非场景
        inspect_only = true,      -- 仅供物品栏检查接管通道，不参与地面/场景的快速动作注入
        stringfn = function() return "阅读" end,
    },
    {
        -- 弹弓装备：自动戴上童心勋章组后装备弹弓。与书本阅读同模式：前置型，不接管点击。
        -- 满足前置（拥有童心勋章）时改写右键为"装备"，点击时先戴勋章再走官方 EQUIP 链路。
        -- inspect_only=true：不参与地面/场景的快速动作注入，仅供物品栏检查接管通道使用。
        action = "EQUIP",
        targetfn = function(target) return target and ItemUtil:IsSlingshot(target) end,
        group = "childMedal",
        invobject_target = true,
        inspect_only = true,
        stringfn = function() return "装备" end,
    },
    {
        -- 月树采摘：本源内含植物勋章后采摘。原自动勋章 HandleMoonTreeHarvestTarget 已移除，统一由快速动作接管
        -- 注：空手右键月树（LOOKAT）由 GetRMBOverride 注入本动作；手持物时 GetActiveItem 闸门不触发，与升级同限制
        config = "QUICK_ACTION_MEDAL_TREE_HARVEST",
        action = "MEDALMOONTREEHARVEST",
        targetfn = function(target)
            return target and target:IsValid()
                and target:HasTag("moon_tree") and target:HasTag("medal_harvestable")
                and not target:HasOneOfTags("burnt", "stump")
        end,
        group = "plantMedal",
        origin = true,  -- 植物须在(已佩戴或可用的)本源内满足；非本源融合箱内的植物无法跨融合装备，不显示采摘
        with_harvest = true,  -- 走 automedal 的本源[植物+丰收]组合（丰收可选，无则仅植物、不影响采摘）
        stringfn = function() return "采摘" end,
    },
    {
        -- 吃调味料（本源主厨）：空手右键物品栏里的可食用调料 → 直接吃。
        -- 源模组的 MEDAL_EAT_SPICES（medal_actions.lua:604/2899）要求 HasOriginMedal("seasoningchef")：
        --   必须戴着**本源**且本源内含 final 主厨（普通融合箱内的主厨不算）→ 故 origin=true，
        --   闸门走 IsOriginSatisfied，装备由自动勋章模块裁决（本源就位后融合插入箱内）。
        -- 判定直接用源模组给调料打的 ediblespice 标签，不列调料清单，新增调料自动适配。
        --   不用 AcceptsComponentAction：该 testfn 走 HasOriginMedal，桩 doer 的 components 会回退
        --   真实玩家，"还没戴本源"时恒判否，反而把提示弄没了。
        config = "QUICK_ACTION_MEDAL_EAT_SPICES",
        action = "MEDAL_EAT_SPICES",
        -- item/itemfn 的返回值是"要使用的物品"，会原样交给 stringfn；
        --   只返回布尔会让 stringfn 对布尔取 .name 报错（动作表修饰整段失败、提示消失），故返回物品本身。
        itemfn = function(item) return IsEdibleSpice(item) and item or nil end,
        group = { "headchef_certificate" },
        origin = true,  -- 必须本源内含主厨，仅散装主厨不成立（HasOriginMedal 不满足）
        invobject_target = true,  -- 目标在物品栏 → 走 HUD 通道
        inspect_only = true,      -- 仅供物品栏通道使用，不参与地面/场景的快速动作注入
        stringfn = function(item) return "吃 (" .. (item and item.name or "调料") .. ")" end,
    },
    {
        -- 巨石枝采摘：本源内含植物勋章后采摘
        config = "QUICK_ACTION_MEDAL_TREE_HARVEST",
        action = "MEDALTREEROCKSHARVEST",
        targetfn = function(target)
            return target and target:IsValid()
                and target:HasTags("tree", "rock_tree")
        end,
        group = "plantMedal",
        origin = true,  -- 植物须在(已佩戴或可用的)本源内满足；非本源融合箱内的植物无法跨融合装备，不显示采摘
        with_harvest = true,  -- 走 automedal 的本源[植物+丰收]组合（丰收可选，无则仅植物、不影响采摘）
        stringfn = function() return "采摘" end,
    },
    {
        -- 研磨：手持可研磨食材 → 右键**物品栏**便携研磨器。
        -- 与"空手右键便携厨具=部署"天然互斥：官方按鼠标有无物品分别取
        --   GetUseItemActions(手持→本动作) / GetInventoryActions(空手→部署)，两条链路不相交。
        -- 食材来自鼠标而非库存，故走 activefn 分支（不用 item/itemfn）。
        -- "能否研磨"直接问游戏（AcceptsUseItemAction 复用已注册的 USEITEM component action，
        --   桩 doer 补上佩戴后才有的 seasoningchef），与 MAKECOOLDOWN 那条同套路：
        --   不复刻可研磨食材清单，其它模组新增的研磨物也能自动适配。
        -- 闸门只看"是否拥有 final 主厨"：研磨的 fn/testfn 要求 seasoningchef
        --   （medal_actions.lua:2359/3283），该标签仅 headchef_certificate 佩戴后赋予，
        --   level 主厨 chef_certificate 没有 → 不能省略 group 走动作→勋章组推导（会命中 cook/chef 档）。
        -- 已部署那台（prefab portableblender）不在此列：它走"手持物→场景目标"链路，
        --   由 automedal 的 HOLD_ITEM_TARGET_CONFIG 负责切主厨勋章。
        config = "QUICK_ACTION_MEDAL_GRINDING",
        action = "MEDAL_GRINDING",
        targetfn = function(target) return target ~= nil and target.prefab == "portableblender_item" end,
        activefn = function(active, target) return ActionUtil:AcceptsUseItemAction(active, target, "MEDAL_GRINDING") end,
        group = { "headchef_certificate" },
        invobject_target = true,  -- 目标在物品栏 → 走 HUD 通道
        inspect_only = true,      -- 仅供物品栏通道使用，不参与地面/场景的快速动作注入
        stringfn = function(item) return "研磨 (" .. (item and item.name or "食材") .. ")" end,
    },
    {
        -- 调味：手持调料 → 右键**物品栏**里的未调味料理（CHEFFLAVOUR）。
        -- 与研磨完全同路径：手持物 → 格子物品 → GetUseItemActions，同样由 MakeMedalActiveItemHandler
        --   生成处理器（提示与点击同源、点击前先戴勋章、动作交回官方链路）。
        -- 原 automedal 的"手持调料第一次右键切主厨、第二次才调味"两阶段逻辑已移除。
        -- 源模组的 CHEFFLAVOUR（medal_actions.lua:757/2935）要求 seasoningchef（仅 final 主厨）
        --   + inst 带 spice + target 是 preparedfood 且非 spicedfood → 判定直接问游戏，不硬编码。
        config = "QUICK_ACTION_MEDAL_CHEFFLAVOUR",
        action = "CHEFFLAVOUR",
        -- 轻量前置：本表每帧都可能被算，先用料理标签挡掉绝大多数无关目标
        targetfn = function(target)
            return target ~= nil and target:HasTag("preparedfood") and not target:HasTag("spicedfood")
        end,
        activefn = function(active, target) return ActionUtil:AcceptsUseItemAction(active, target, "CHEFFLAVOUR") end,
        group = { "headchef_certificate" },
        invobject_target = true,  -- 目标在物品栏 → 走 HUD 通道
        inspect_only = true,      -- 仅供物品栏通道使用，不参与地面/场景的快速动作注入
        stringfn = function(item) return "调味 (" .. (item and item.name or "调料") .. ")" end,
    },
}

-- 单条定义试算：满足全部前置则返回"先装备勋章再执行"的动作，否则 nil
local function TryMedalQuickAction(self, target, def, api, force_hud)
    if MOD_EQUIPMENT_CONTROL.CONFIG[def.config] == false then
        return nil
    end
    if def.conditionfn and not def.conditionfn() then
        return nil
    end
    -- 目标前置：targetfn 是**可选**的——历史 def 都靠它判定目标，但"吃调料"这类只认物品本身的
    -- def 用 itemfn（同样以 target 为入参取物）承担判定，此时不能再强制要求 targetfn，否则
    --   "attempt to call field 'targetfn' (a nil value)"（悬停提示每次都会崩）。
    if target == nil then
        return nil
    end
    if def.targetfn ~= nil and not def.targetfn(target) then
        return nil
    end
    -- 对应勋章组：显式 group 优先（组名字符串 或 精确 prefab 表），否则由动作→勋章组映射推导；无组信息则退化为不强制装备。
    -- 采摘等"本源内含植物"需求用 group="plantMedal" 且 origin=true：仅当植物可在本源内满足才显示
    -- （散装可融合入已佩戴本源，或已在某本源箱内）；非本源融合箱内的植物无法跨融合装备、视为不满足前置。
    local prefabs = (def.group ~= nil)
        and (type(def.group) == "table" and def.group or api.GetGroup(def.group))
        or api.GetMedalPrefabsForAction(def.action)
    -- 勋章闸门（三类互斥，注意不能写成 "def.origin and IsOriginSatisfied(..) or FindMedal(..)"，
    -- 该 and/or 写法在 origin=true 且 IsOriginSatisfied 为 false 时会兜底再调 FindMedal，而 FindMedal
    -- 的融合箱分支不要求是 M.origin 本源箱，能命中"非本源融合箱内的勋章"（无法跨融合装备），
    -- 从而绕过本源约束，对巨石枝/月树等本源类动作误注入"采摘"）：
    --  ① prefabs 为 nil：该动作本身不强制要求勋章（埋绿宝石 GREENGEMPLANT、旋花藤缠绕
    --     WORMWOODFLOWERPLANT：能力勋章的 fn 只校验手持物+目标形态），直接放行；
    --  ② origin=true：目标勋章必须"在本源内满足"（已佩戴本源且目标可融合入/已在箱内，
    --     或库存某本源箱含目标）→ 只以 IsOriginSatisfied 为准，不兜底 FindMedal；
    --  ③ 其余：库存/融合箱内有对应勋章即可（FindMedal）。
    local has_medal
    if prefabs == nil then
        has_medal = true
    elseif def.origin then
        has_medal = api.IsOriginSatisfied(prefabs)
    else
        has_medal = api.FindMedal(prefabs) ~= nil
    end
    if not has_medal then
        return nil  -- 库存无对应勋章 / 本源前置不满足，不显示
    end
    -- 使用物品：① activefn（鼠标上的物品，如研磨的食材）② item（固定 prefab）③ itemfn（动态取物）
    -- activefn 取到的 item 只用于动作名显示：HUD 官方链路里 invobject 由服务端从
    -- GetActiveItem() 自行取用，客户端发出的 RPC 只带动作码与格子物品。
    local item
    if def.activefn then
        item = InventoryUtil:GetActiveItem()
        if not (item and def.activefn(item, target)) then return nil end
    elseif def.item then
        item = GetItemFromInventory(def.item)
        if not item then return nil end
    elseif def.itemfn then
        item = def.itemfn(target)
        if not item then return nil end
    end
    -- 书本等"目标可能是背包物品"的 def（invobject_target=true）：目标被持有→走 HUD(UseItemFromInvTile)，
    -- 否则走场景(MedalSceneUse)。其余 def 始终走场景。
    -- force_hud：调用方已确定目标来自物品栏/容器格子（HUD 通道）时强制走 HUD。
    -- 不能只依赖 IsHeld()：客户端（ismastersim=false）上 inventoryitem 组件的状态不与服务端同步，
    -- IsHeld() 恒为 false（replica 的 IsHeld 内部同样走该组件），会把背包书本误判成场景目标
    -- → MedalSceneUse 发 RPC.RightClick → 服务端算出 LOOKAT → 表现为"装备了智慧但仍检查"。
    local is_hud = force_hud
        or (def.invobject_target and target.components.inventoryitem
            and target.components.inventoryitem:IsHeld())
    if ACTIONS[def.action] == nil then
        return nil
    end
    local act
    if is_hud then
        act = BufferedAction(self.inst, nil, ACTIONS[def.action], target)  -- target 作为 invobject
        act.target = nil
    else
        act = BufferedAction(self.inst, target, ACTIONS[def.action], item)
    end
    act.medal_prefabs = prefabs
    act.with_harvest = def.with_harvest
    act.origin_combo = def.origin_combo
    if def.stringfn then
        act.GetActionString = function() return def.stringfn(item) end
    end
    -- 无需勋章(prefabs 为 nil，如埋绿宝石 GREENGEMPLANT / 旋花藤缠绕 WORMWOODFLOWERPLANT)的动作
    -- 直接走普通快速场景动作路径(SceneUse)，不绕 MedalSceneUse 的勋章联动分支；
    -- 需要勋章的仍走 MedalSceneUse（或 HUDUse 背包物品路径）。
    act.modaction = is_hud and "HUDUse" or (prefabs == nil and "SceneUse" or "MedalSceneUse")
    return act
end

-- 按动作名精确查找某条勋章快速动作（避免 GetMedalQuickAction 返回首个命中导致的误匹配，如 tree_level_up 的 targetfn 是任意有效实体）
-- @param require_active boolean 可选。为 true 时只匹配"物品来自鼠标"的 def（def.activefn 非空），
--        供"手持物 → 格子物品"通道使用：同一动作若同时存在场景 def 与手持 def，不会取错。
local function GetMedalQuickActionByAction(self, target, action, force_hud, require_active)
    local api = GetAutoMedalAPI()
    if not api then return nil end
    for _, def in ipairs(MedalQuickActionDefs) do
        if def.action == action and (not require_active or def.activefn ~= nil) then
            local act = TryMedalQuickAction(self, target, def, api, force_hud)
            if act then return act end
        end
    end
    return nil
end

-- 扫描全部勋章快速动作，返回首个满足前置的（库存有勋章 + 目标形态 + 附加条件）
-- 跳过 inspect_only 的 def（如书本阅读）：那些仅在物品栏检查接管通道生效，
-- 不应被注入为地面/场景目标的右键快速动作——原版地面书右键为空，保持与原版一致。
local function GetMedalQuickAction(self, target)
    local api = GetAutoMedalAPI()
    if not api then return nil end
    for _, def in ipairs(MedalQuickActionDefs) do
        if not def.inspect_only then
            local act = TryMedalQuickAction(self, target, def, api)
            if act then return act end
        end
    end
    return nil
end

local QuickAction = Class(function(self, data)
    if data == nil then
        data = {}
    end

    self.toolaction = data.toolaction
    self.action    = data.action
    self.modaction  = data.modaction
    self.itemfn     = data.itemfn
    self.item       = data.item
    self.rmb        = data.rmb or false
    self.fn         = function() return false end
    self.stringfn   = data.stringfn
end)

local QuickActions =
{
    QUICK_ACTION_REPAIR_BOAT   = QuickAction({item = "boatpatch", modaction = "SceneUse"}),                                    -- 修复船只
    QUICK_ACTION_BEEFALO       = QuickAction({item = "razor", modaction = "SceneUse"}),                                        -- 野牛剃毛
    QUICK_ACTION_FEED_BIRD     = QuickAction({itemfn = GetBirdFood, modaction = "SceneUse"}),                                  -- 交易换取鸟蛋
    QUICK_ACTION_IMPRISON_BIRD = QuickAction({itemfn = GetBird, modaction = "SceneUse"}),                                      -- 囚禁鸟类
    QUICK_ACTION_ATRIUM_GATE   = QuickAction({item = "atrium_key", modaction = "SceneUse"}),                                   -- 插入远古大门钥匙
    QUICK_ACTION_KLAUS_SACK    = QuickAction({itemfn = GetKlausSackKey, modaction = "SceneUse"}),                              -- 解锁赃物袋
    QUICK_ACTION_EXTINGUISH    = QuickAction({itemfn = GetExtinguishItem, modaction = "Extinguish"}),                          -- 灭火
    QUICK_ACTION_BOTTLESSOUL   = QuickAction({item = "messagebottleempty", action = "BOTTLESSOUL", modaction = "SceneUse"}),   -- 装入瓶子
    QUICK_ACTION_DEVOURER      = QuickAction({itemfn = GetDevourerFood, action = "DEVOURER", modaction = "SceneUse"}),         -- 喂时空吞噬者
    QUICK_ACTION_WAKEUP_BIRD   = QuickAction({modaction = "WakeUp"}),                                                          -- 唤醒鸟类
    QUICK_ACTION_DIRTPILE      = QuickAction({modaction = "Track"}),                                                           -- 跟踪泥土
    QUICK_ACTION_BUILD_FOSSIL  = QuickAction({rmb = true, item = "fossil_piece", modaction = "BuildFossil"}),                  -- 构建化石
}
-- 修复船只
QuickActions.QUICK_ACTION_REPAIR_BOAT.fn = function(target)
    return target and target:HasTag("boat_leak")
end
-- 野牛剃毛
QuickActions.QUICK_ACTION_BEEFALO.fn = function(target)
    return target and target:HasTag("beefalo")
        and ItemUtil:IsSleeping(target)
        and target.AnimState:GetBuild() ~= "beefalo_shaved_build"
end
-- 交易换取鸟蛋
QuickActions.QUICK_ACTION_FEED_BIRD.fn = function(target)
    return target and target.prefab == "birdcage"
        and target:HasTag("trader")
        and not ItemUtil:IsSleeping(target)
end

QuickActions.QUICK_ACTION_FEED_BIRD.stringfn = function(item)
    return "喂食 (" .. GetDisplayName(item) .. ")"
end
-- 囚禁鸟类
QuickActions.QUICK_ACTION_IMPRISON_BIRD.fn = function(target)
    return target and target.prefab == "birdcage"
        and not target:HasTag("trader")
end

QuickActions.QUICK_ACTION_IMPRISON_BIRD.stringfn = function(item)
    return "囚禁 (" .. item.name .. ")"
end
-- 解锁赃物袋
QuickActions.QUICK_ACTION_KLAUS_SACK.fn = function(target)
    return target and target:HasTag("klaussacklock")
end
-- 插入远古大门
QuickActions.QUICK_ACTION_ATRIUM_GATE.fn = function(target)
    return target and target.prefab == "atrium_gate"
end
-- 唤醒鸟
QuickActions.QUICK_ACTION_WAKEUP_BIRD.fn = function(target)
    return target and target.prefab == "birdcage"
        and target:HasTag("trader")
        and ItemUtil:IsSleeping(target)
end

QuickActions.QUICK_ACTION_WAKEUP_BIRD.stringfn = function()
    return "唤醒"
end
-- 跟踪脚印
QuickActions.QUICK_ACTION_DIRTPILE.fn = function(target)
    return target and target:HasTag("dirtpile")
end

QuickActions.QUICK_ACTION_DIRTPILE.stringfn = function()
    return "追踪脚印"
end
-- 建造骨架
QuickActions.QUICK_ACTION_BUILD_FOSSIL.fn = function(target)
    return target and target.prefab == "fossil_stalker"
        and target:HasTag("workrepairable")
end

QuickActions.QUICK_ACTION_BUILD_FOSSIL.stringfn = function()
    return "建造"
end
-- [MOD]装入瓶子
QuickActions.QUICK_ACTION_BOTTLESSOUL.fn = function(target)
    return target and target:IsValid() and target.prefab == "krampus_soul"
end

QuickActions.QUICK_ACTION_BOTTLESSOUL.stringfn = function(item)
    return "装入 (" .. (item and item.name or "空瓶") .. ")"
end
-- [MOD]喂时空吞噬者
QuickActions.QUICK_ACTION_DEVOURER.fn = function(target)
    return target and target.prefab == "medal_spacetime_devourer"
end

QuickActions.QUICK_ACTION_DEVOURER.stringfn = function(item)
    return "喂 (" .. (item and item.name or "时空吞噬者") .. ")"
end
-- 熄灭火焰
QuickActions.QUICK_ACTION_EXTINGUISH.fn = function(target)
    return target and IsExtinguishable(target)
end

QuickActions.QUICK_ACTION_EXTINGUISH.stringfn = function(item)
    return "灭火 (" .. item.name .. ")"
end

-- @TODO Move this logic
for config in pairs(QuickActions) do
    if not MOD_EQUIPMENT_CONTROL.CONFIG[config] then
        QuickActions[config] = nil
    end
end

local function QuickActionFactory(self, target, quickAction)
    local item

    if quickAction.item then
        item = GetItemFromInventory(quickAction.item)

        if not item then
            return nil
        end
    elseif quickAction.itemfn then
        item = quickAction.itemfn(target)

        if not item then
            return nil
        end
    end

    local act

    if quickAction.action and ACTIONS[quickAction.action] then
        act = BufferedAction(self.inst, target, ACTIONS[quickAction.action], item)
    elseif item then
        if item:HasTag("_equippable") then
            act = self:GetEquippedItemActions(target, item, quickAction.rmb or item.prefab == "waterballoon")[1]
        else
            act = self:GetUseItemActions(target, item, quickAction.rmb)[1]
        end
    else
        act = self:GetSceneActions(target)[1]
    end

    if not act then
        return nil
    end

    local buffAction = BufferedAction(self.inst, target, act.action, item)

    if quickAction.stringfn then
        buffAction.GetActionString = function()
            return quickAction.stringfn(item)
        end
    end

    buffAction.modaction = quickAction.modaction

    return buffAction
end

local function GetQuickAction(self, target)
    -- 勋章联动快速动作优先：扫描勋章 + 前置条件，满足即显示，按下先装备对应勋章
    local medalAct = GetMedalQuickAction(self, target)
    if medalAct then
        return medalAct
    end
    for _, quickAction in pairs(QuickActions) do
        if quickAction.fn(target) then
            local ret = QuickActionFactory(self, target, quickAction)

            if ret then
                return ret
            end
        end
    end

    return nil
end

local function GetRMBOverride(self, position, target)
    if InventoryUtil:IsHeavyLifting() then
        return nil
    end

    if InventoryUtil:GetActiveItem() then
        return nil
    end

    if position == nil then
        if PlayerUtil:GetComponent("playercontroller") then
            local isaoetargeting = PlayerUtil:IsAOETargeting()
            if target == nil and not isaoetargeting then
                target = TheInput:GetWorldEntityUnderMouse()
            end
            position = isaoetargeting and PlayerUtil:GetAOETargetingPos() or TheInput:GetWorldPosition()
        end
    end

    if position then
        local cansee
        if target == nil then
            local x, y, z = position:Get()
            cansee = CanEntitySeePoint(self.inst, x, y, z)
        else
            cansee = target == self.inst or CanEntitySeeTarget(self.inst, target)
        end

        if cansee then
            local rmb_override = GetQuickAction(self, target)
            if rmb_override then
                return rmb_override
            end
        end
    end

    return nil
end

local ModActions = {}

function ModActions:SceneUse(act)
    if self.locomotor == nil then
        SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target, act.action.mod_name)
    else
        act.preview_cb = function()
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target, act.action.mod_name)
        end
    end

    self:DoAction(act)
end
-- 唤醒鸟
function ModActions:WakeUp(act)
    local position = TheInput:GetWorldPosition()

    if self.locomotor == nil then
        SendRPCToServer(RPC.LeftClick,act.action.code,position.x,position.z,act.target)
    else
        act.preview_cb = function()
            SendRPCToServer(RPC.LeftClick,act.action.code,position.x,position.z,act.target)
        end
    end

    local function callback(inst, data)
        OnGetBirdEvent(inst, data, act.target)
    end

    self.inst.components.eventtracker:AddEvent("gotnewitem","OnGetBirdEvent",callback)

    self:DoAction(act)
end

-- 按下移动键时
local function IsWalkButtonDown()
    return TheInput:IsControlPressed(CONTROL_MOVE_UP)
        or TheInput:IsControlPressed(CONTROL_MOVE_DOWN)
        or TheInput:IsControlPressed(CONTROL_MOVE_LEFT)
        or TheInput:IsControlPressed(CONTROL_MOVE_RIGHT)
end
-- 追踪脚印
function ModActions:Track(act)
    if IsWalkButtonDown() then
        return
    end

    KillThreadsWithID("TrackingThread")
    DoTracking()
end

function ModActions:ToolAction(act)
    if not InventoryUtil:EquipHasTag(act.action.id .. "_tool") then
        ConfigUtil:AutoEquip("QUICKACTIONS", act.invobject)
    end

    local rpc = act.action.rmb and RPC.RightClick or RPC.LeftClick
    local position = TheInput:GetWorldPosition()

    if self.locomotor == nil then
        SendRPCToServer(rpc, act.action.code, position.x, position.z, act.target, nil, nil, act.action.canforce)
    else
        act.preview_cb = function()
            SendRPCToServer(rpc, act.action.code, position.x, position.z, act.target)
        end
    end

    self:DoAction(act)
end
-- 建造化石
function ModActions:BuildFossil(act)
    if self.locomotor == nil then
        SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
    else
        act.preview_cb = function()
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
        end
    end

    local function callback(inst, data)
        OnBuildFossil(inst, data, act.target)
    end

    self.inst.components.eventtracker:AddEvent("stacksizechange","OnBuildFossil",callback)

    self:DoAction(act)
end
-- 熄灭火焰
function ModActions:Extinguish(act)
    if not act.invobject:HasTag("_equippable") then
        if self.locomotor == nil then
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
        else
            act.preview_cb = function()
                SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target)
            end
        end

        self:DoAction(act)
        return
    end

    if InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS) ~= act.invobject then
        ConfigUtil:AutoEquip("QUICKACTIONS", act.invobject)
    end

    local rpc = act.action.rmb and RPC.RightClick or RPC.LeftClick
    local position = TheInput:GetWorldPosition()

    self.inst:DoTaskInTime(FRAMES * 4, function()
        if self.locomotor == nil then
            SendRPCToServer(rpc, act.action.code, position.x, position.z, act.target, nil, nil, act.action.canforce)
        else
            act.preview_cb = function()
                SendRPCToServer(rpc, act.action.code, position.x, position.z, act.target, rpc == RPC.LeftClick)
            end
        end
        self:DoAction(act)
    end)
end

-- 勋章联动统一装备：普通动作戴主勋章组；组合类走本源联动。
-- 各行其道：戴着本源箱才走 EquipCombo 把整组换入箱内（箱内勋章的 onequipfn 随即生效）；
-- 没本源就没有联动，按组合首项（主勋章）普通装备——首项若在库存本源箱内，
-- AutoEquipMedal 会直接把那只箱戴上（FindMedal 的融合箱分支），顺带完成换佩戴箱。
-- 显示闸门仍只看植物能否在本源内满足（def 的 group/origin），丰收不参与前置判定。
local function EquipMedalsForAct(api, act)
    if api == nil or act.medal_prefabs == nil then return end
    if act.with_harvest or act.origin_combo then
        local combo = act.origin_combo or act.medal_prefabs
        -- has_origin_medal 只有本源箱的 onequipfn 会加，普通融合箱加了也没有
        if ThePlayer ~= nil and ThePlayer:HasTag("has_origin_medal") then
            api.EquipCombo(combo, act.with_harvest, true)
        elseif combo[1] ~= nil then
            api.AutoEquipMedal({ combo[1] })
        end
        return
    end
    api.AutoEquipMedal(act.medal_prefabs)
end

-- 勋章联动快速动作：先装备对应勋章组（若未佩戴），再按 SceneUse 执行动作
function ModActions:MedalSceneUse(act)
    local api = GetAutoMedalAPI()
    EquipMedalsForAct(api, act)
    -- 场景使用：有手持物（invobject）作用于场景实体 → ControllerUseItemOnSceneFromInvTile；
    -- 无手持物对场景实体（如阅读地面书）→ RPC.RightClick（与官方 OnRightClick 一致的参数顺序）。
    -- 注意：游戏不存在 RPC.ControllerUseItemOnScene（只有 ...FromInvTile / RightClick / ControllerActionButton），
    -- 原先发它会因 RPC 枚举为 nil 触发 networkclientrpc:1637 的 assert(RPC_HANDLERS[code] ~= nil) 崩溃。
    -- 背包物品使用不在此处理（见 HUDUse）。
    local function SendSceneUse()
        if act.invobject ~= nil then
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, act.action.code, act.invobject, act.target, act.action.mod_name)
        else
            local position = (act.target and act.target:GetPosition()) or TheInput:GetWorldPosition()
            SendRPCToServer(RPC.RightClick, act.action.code, position.x, position.z, act.target,
                nil, nil, nil, act.action.canforce, act.action.mod_name)
        end
    end
    if self.locomotor == nil then
        SendSceneUse()
    else
        act.preview_cb = function()
            SendSceneUse()
        end
    end
    self:DoAction(act)
end

-- 勋章联动快速动作（HUD/背包物品）：先装备对应勋章组，再按背包物品使用（UseItemFromInvTile）执行动作。
-- 用于物品栏书本等背包物品右键——背包物品使用走 UseItemFromInvTile（invobject=物品，target 通常 nil/自身），
-- 与场景实体使用（MedalSceneUse）区分开，避免对背包物品误发场景 RPC 导致 code=nil 断言崩溃。
function ModActions:HUDUse(act)
    local api = GetAutoMedalAPI()
    EquipMedalsForAct(api, act)
    -- 背包物品使用
    if self.locomotor == nil then
        SendRPCToServer(RPC.UseItemFromInvTile, act.action.code, act.invobject, act.target, act.action.mod_name)
    else
        act.preview_cb = function()
            SendRPCToServer(RPC.UseItemFromInvTile, act.action.code, act.invobject, act.target, act.action.mod_name)
        end
    end
    self:DoAction(act)
end

local function StartDarkSoulAuto(self, target)
    if not IsDarkSoulAutoEnabled() then return false end
    if not IsDarkSoul(target) then return false end
    -- 启动前强制复位：旧线程被 kill 时不会执行到末尾复位，残留标志会吞掉后续点击
    StopDarkSoulAuto()
    _dark_soul_auto_active = true
    StartThread(function()
        local skipped_first = false   -- 首轮由 handler 同步执行，线程跳过
        while true do
            -- pcall 只包纯判定（不挂起）；动作执行与等待放外面，
            -- 避免 Lua 5.1 "attempt to yield across C-call boundary" 让托管误退出。
            local ok, stop, rmb = pcall(function()
                -- 灵魂失效/不可见/已死亡 → 退出；死亡判定用官方 IsEntityDead
                -- （componentutil.lua:7），不再自己拼 components.health:IsDead()
                if not target:IsValid() or not target.entity:IsVisible()
                    or IsEntityDead(target) then
                    return true
                end
                -- 两轮之间玩家自主移动且未在动作中 → 打断
                if not self:IsBusy() and PlayerUtil:IsMoving() then
                    return true
                end
                -- 锁灵魂自身坐标，直到失效/不可见/不可达（GetRMBOverride 返回 nil 自动退出）
                local override = GetRMBOverride(self, target:GetPosition(), target)
                if override == nil or ModActions[override.modaction] == nil then
                    return true          -- 无可用动作（未爆魂且无血糖）：结束
                end
                return false, override
            end)
            if not ok or stop then break end
            if skipped_first then
                ModActions[rmb.modaction](self, rmb)       -- 污染/吸收各自的 SceneUse/MedalSceneUse
            else
                skipped_first = true
            end
            WaitDarkSoulActionDone(self, IsSoulBursting() and 3 or 6)
        end
        _dark_soul_auto_active = false
    end, DARK_SOUL_THREAD)
    return true
end

-- 勋章物品快速动作通用工厂：为指定 action + 物品检测函数生成前置处理器和动作表修饰器。
-- 模式：右键前自动戴对应勋章（前置型，不接管），并将目标动作提到 actions[1] 对齐悬停提示。
-- @param action   string  动作名（如 "READ"、"EQUIP"），对应 MedalQuickActionDefs 中的 action 字段；
--                传 nil 时为"仅切勋章"模式：不查 def、不修改动作表，只在前置中戴上 prefabs。
-- @param itemfn   function(item) -> bool  物品检测函数（如判定书本、弹弓的闭包）
--                 注意：ItemUtil 的方法多为**冒号定义**，不能直接传引用（self 会变成物品、
--                 真正的 item 参数变 nil → 恒返回 false），必须包一层闭包按冒号调用。
-- @param prefabs  table   可选。直接指定勋章 prefab 列表，跳过 def 查找，用于不需要改动作的物品（如铃铛）。
-- @param kinds    table   可选。允许的触发类型集合，默认 {use}。右键物品栏走 "use"（InvSlot:UseItem），
--                 检查键走 "inspect"（InspectItemFromInvTile）；融合仪式那类"右键即检查"的物品两者都要。
-- @return PrepareItem(item, kind), ItemActionsModifier(actions, item, owner)
local function MakeMedalItemHandler(action, itemfn, prefabs, kinds)
    local allowed = kinds or { use = true }
    local function GetMedalAct(item)
        local pc = ThePlayer and ThePlayer.components.playercontroller
        if pc == nil then return nil end
        if prefabs then return pc, { medal_prefabs = prefabs } end
        local medalAct = GetMedalQuickActionByAction(pc, item, action, true)
        if not (medalAct and medalAct.action and medalAct.action.code ~= nil) then return nil end
        return pc, medalAct
    end

    local function PrepareItem(item, kind)
        if not allowed[kind] then return false end
        if not (item and itemfn(item)) then return false end
        local pc, medalAct = GetMedalAct(item)
        if pc == nil then return false end
        local api = GetAutoMedalAPI()
        if api ~= nil and medalAct.medal_prefabs ~= nil then
            api.AutoEquipMedal(medalAct.medal_prefabs)
        end
        return false
    end

    local function ItemActionsModifier(actions, item, owner)
        if prefabs then return nil end
        if not (item and itemfn(item)) then return nil end
        local pc, medalAct = GetMedalAct(item)
        if pc == nil then return nil end
        owner = owner or ThePlayer
        local idx
        for i, a in ipairs(actions) do
            if a.action ~= nil and a.action.id == action then idx = i; break end
        end
        if idx ~= nil then
            if idx > 1 then
                table.insert(actions, 1, table.remove(actions, idx))
            end
        else
            table.insert(actions, 1, BufferedAction(owner, nil, ACTIONS[action], item))
        end
        -- 动作名统一取 def.stringfn：不覆盖的话提示仍是官方默认文本，def 的 stringfn 形同虚设
        --   （书本"阅读"、弹弓"装备"…）。铃铛那种仅切勋章的模式没有 medalAct.GetActionString，跳过。
        if medalAct.GetActionString ~= nil then
            actions[1].GetActionString = medalAct.GetActionString
        end
        return actions
    end

    return PrepareItem, ItemActionsModifier
end

-- 手持物 → 物品栏格子 的通用处理器工厂（与 MakeMedalItemHandler 对称，分管"鼠标有物品"形态）。
-- 与空手那条的关键差异：动作表是 **GetUseItemActions** 而非 GetInventoryActions——
--   官方按鼠标有无物品二选一（itemtile.lua:503 提示 / inventory_classified.lua:910 点击），
--   故这里配的是通道 C2（RegisterUseItemActionsModifier），两条链路天然不相交、无需互相让位。
-- 模式（与书本/弹弓一致，前置型、不接管点击）：
--   ① 动作表修饰：把 def 命中的动作顶到 [1]，提示与点击同源；
--   ② 点击前置：先戴 def 要求的勋章，再交回官方链路发 RPC——服务端会**重算** actions[1]
--      并校验动作码（inventory.lua:2295），只有标签先到位才可能算出同一动作；
--      装备 RPC 先于使用 RPC（同一客户端保序，主机本地同步），没戴上则静默不执行、不会崩。
-- 判定全部交给 def（action / targetfn / activefn / 勋章闸门），本工厂不含任何具体动作逻辑：
--   后续新增同类"手持物 → 格子物品"动作只需加一条 def，再调用本工厂生成一对处理器即可。
-- 构造用标准 USEITEM 语义：invobject=鼠标上的物品，target=格子里的物品
--   （与 HUDUse 相反：HUDUse 自行发 RPC 才把格子物品放 invobject；官方链路只取 act.action.code）。
-- @param action string 动作名（对应 MedalQuickActionDefs 中的 action 字段）
-- @return PrepareActiveItem(item, kind), ActiveItemActionsModifier(actions, target, useitem, right, owner)
local function MakeMedalActiveItemHandler(action)
    local function GetDefAct(target, owner)
        if ACTIONS[action] == nil then return nil end
        local pc = owner and owner.components and owner.components.playercontroller
        if pc == nil then return nil end
        return GetMedalQuickActionByAction(pc, target, action, true, true)
    end

    local function PrepareActiveItem(item, kind)
        if kind ~= "use" or item == nil then return false end
        local defAct = GetDefAct(item, ThePlayer)
        if defAct == nil then return false end
        EquipMedalsForAct(GetAutoMedalAPI(), defAct)
        return false  -- 前置型：不接管，动作仍走官方链路
    end

    local function ActiveItemActionsModifier(actions, target, useitem, right, owner)
        if not right or owner == nil or useitem == nil or target == nil then return nil end
        -- 轻量前置：本表每帧都可能被算，先挡掉非格子物品（格子里的物品必有 inventoryitem replica）
        if target.replica == nil or target.replica.inventoryitem == nil then return nil end

        local defAct = GetDefAct(target, owner)
        if defAct == nil or defAct.action == nil then return nil end

        for i, a in ipairs(actions) do
            if a.action == defAct.action then
                if i > 1 then
                    table.insert(actions, 1, table.remove(actions, i))
                end
                return actions
            end
        end

        local act = BufferedAction(owner, target, defAct.action, useitem)
        act.GetActionString = defAct.GetActionString
        table.insert(actions, 1, act)
        return actions
    end

    return PrepareActiveItem, ActiveItemActionsModifier
end

-- ItemUtil.IsBook / IsSlingshot 是**冒号定义**，不能直接传引用（self 会变成物品、item 参数变 nil，
--   判定恒 false）；必须包一层闭包按冒号调用（与 automedal 里 IsGoggle 的处理同理）。
local PrepareBookRead, BookReadActionsModifier = MakeMedalItemHandler("READ", function(item) return ItemUtil:IsBook(item) end)
local PrepareSlingshotEquip, SlingshotEquipActionsModifier = MakeMedalItemHandler("EQUIP", function(item) return ItemUtil:IsSlingshot(item) end)
-- 吃调味料：本源主厨就位后右键调料为"吃"（空手物品栏通道）
local PrepareEatSpices, EatSpicesActionsModifier = MakeMedalItemHandler("MEDAL_EAT_SPICES", IsEdibleSpice)
local PrepareBellRing = MakeMedalItemHandler(nil, function(item) return item and item:HasTag("bell") end, {"naughty_certificate"})
-- 空白/融合勋章 → 传承勋章（融合仪式）：无动作、仅切勋章。
-- 原由 automedal 的 HUD 通道（OnControl 转发）处理，已随该通道一并迁到这里。
local PrepareBlankOrFusion = MakeMedalItemHandler(
    nil, IsBlankOrFusion, { "inherit_certificate" }, { use = true, inspect = true })
-- 研磨：手持可研磨物 → 物品栏便携研磨器（走"手持物→格子物品"通用处理器）
local PrepareGrinding, GrindingActionsModifier = MakeMedalActiveItemHandler("MEDAL_GRINDING")
-- 调味：手持调料 → 物品栏未调味料理（同上，同一套通用处理器）
local PrepareChefFlavour, ChefFlavourActionsModifier = MakeMedalActiveItemHandler("CHEFFLAVOUR")

-- 吞噬系法杖（medal_eatfood）：物品栏右键/检查 → 与 MEDALSTAFFDEVOUR/CASTSPELL 规则同一套逻辑。
-- 各行其道：戴着本源箱走本源联动（植物+丰收换入箱内）；否则没有联动效果，
-- 走普通"动作→勋章"单勋章逻辑（只切丰收）。
local function PrepareDevourStaff(item, kind)
    if kind ~= "use" and kind ~= "inspect" then return false end
    if not (item and item.HasTag ~= nil and item:HasTag("medal_eatfood")) then return false end
    local api = GetAutoMedalAPI()
    if api == nil or api.EquipCombo == nil or api.AutoEquipMedal == nil then return false end
    -- has_origin_medal 只有本源箱的 onequipfn 会加，普通融合箱加了也没有
    if ThePlayer ~= nil and ThePlayer:HasTag("has_origin_medal") then
        api.EquipCombo({ api.GetFinalPrefab and api.GetFinalPrefab("plantMedal"), "harvest_certificate" }, nil, true)
    else
        local prefabs = api.GetMedalPrefabsForAction and api.GetMedalPrefabsForAction("MEDALSTAFFDEVOUR")
        api.AutoEquipMedal(prefabs or { "harvest_certificate" })
    end
    return false  -- 前置型：不接管，动作仍走官方链路
end

local function Init()
    local PlayerController = ThePlayer and ThePlayer.components.playercontroller
    local PlayerActionPicker = ThePlayer and ThePlayer.components.playeractionpicker

    if not PlayerController or not PlayerActionPicker then
        return
    end

    -- 幂等守卫：世界重载/换角色重复执行时不再叠加包裹，否则会层层嵌套调用
    if PlayerController._ec_quickactions_hooked then
        return
    end
    PlayerController._ec_quickactions_hooked = true

    -- 复用 actionutil 通用右键分发（实例级），修复原先 class 级 OnRightClick 被实例钩子遮蔽而失效的问题。
    -- 自定义 mod 动作已处理则返回 "stop"：整点吞掉原点击且阻断后续处理器（normal RMB 不触发）。

    -- 书本不再在此接管：原版地面书本右键本就是"阅读"（actionpicker 给出，原生即可完成）；
    -- 若是"检查"则说明当前不可读——两种情形都与原版保持一致，不再拦截替换。
    -- 书本接管只保留"物品栏"分支：由 automedal 的 OnControl 转发到 ModActions.TryHUDItemBook
    -- （物品栏右键走不到本处理器——actionutil 对 HUD 悬停按官方 OnRightClick 语义提前返回）。

    ActionUtil:RegisterRightClickHandler(PlayerController.inst, 0, function(self, act, down)
        if down and act then
            -- 黑暗灵魂：单击启动自动污染，末段(爆魂)自动切吸收。
            -- 不走 act.action.id 白名单（原生 act 是 WALKTO/LOOKAT，永远匹配不上 MEDALPOLLUTE），
            -- 改走 GetRMBOverride 取动作（内部按 主厨→污染 / 爆魂·无血糖→吸收 选，并覆盖本源/巧手切勋章）。
            -- 目标优先 act.target 回落鼠标实体；仅当 GetRMBOverride 给出动作才启动，否则放行原点击。
            local ds_target = (act and act.target) or TheInput:GetWorldEntityUnderMouse()
            if IsDarkSoulAutoEnabled() and IsDarkSoul(ds_target) then
                local rmb = GetRMBOverride(self, TheInput:GetWorldPosition(), ds_target)
                if rmb ~= nil then
                    -- 首轮同步执行（与关闭自动时单击同路径），线程跳过首轮
                    local fn0 = ModActions[rmb.modaction]
                    if fn0 ~= nil then fn0(self, rmb) end
                    StartDarkSoulAuto(self, ds_target)
                    return "stop"   -- 单次点击交给线程循环执行，避免重复触发
                end
            end
            -- （书本的地面右键已不接管，与原版一致；书本只做物品栏分支，见下方 HUD 通道注册）
            local modAction = ModActions[act.modaction]
            if modAction then
                modAction(self, act)
                return "stop"
            end
        end
        -- 上抬或非 mod 动作：原点击照常执行
    end)

    --
    -- PlayerActionPicker Overrides：空 RMB 注入快速动作
    -- 统一使用 actionutil.RegisterMouseActionModifier（与 autotool 机制一致），避免重复造轮子
    --

    local function QuickActionModifier(self, position, target, lmb, rmb)
        if ActionUtil:IsEmptyClickAction(rmb) then
            local rmb_override = GetRMBOverride(self, position, target)
            if rmb_override then
                return lmb, rmb_override
            end
        end
        return lmb, rmb
    end
    ActionUtil:RegisterMouseActionModifier(PlayerActionPicker.inst, QuickActionModifier)

    -- 物品栏/容器格子右键：收敛到 actionutil 的"格子使用/检查"通道
    -- （内部统一钩 replica 的 UseItemFromInvTile / InspectItemFromInvTile 并处理幂等/补丁链）。
    -- 书本只注册**前置型**处理器：戴上智慧勋章后返回 false，点击交回官方链路执行，
    -- 不在此处接管（接管会短路官方链路，且悬停提示要靠单独改表才能对齐）。
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareBookRead)

    -- 把书本的 READ 提到官方动作表首位（见 BookReadActionsModifier）：
    -- 悬停提示与点击都取这张表的 [1]，故一处修改同时对齐两者。
    -- 未注册时 GetInventoryActions 完全走原生，无开销。
    ActionUtil:RegisterInventoryActionsModifier(ThePlayer, 0, BookReadActionsModifier)

    -- 弹弓装备：与书本同模式，前置型处理器 + 动作表修饰器
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareSlingshotEquip)
    ActionUtil:RegisterInventoryActionsModifier(ThePlayer, 0, SlingshotEquipActionsModifier)
    -- 吃调味料（空手右键物品栏调料）
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareEatSpices)
    ActionUtil:RegisterInventoryActionsModifier(ThePlayer, 0, EatSpicesActionsModifier)

    -- 铃铛：只切勋章，不修改动作表
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareBellRing)

    -- 空白/融合勋章 → 传承勋章；吞噬系法杖 → 本源[植物+丰收]
    -- （原 automedal 的 HUD 悬停通道已移除，两条都走物品栏格子通道）
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareBlankOrFusion)
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareDevourStaff)

    -- 研磨：手持可研磨食材 → 右键物品栏便携研磨器。
    -- 与空手时"便携厨具=部署"分属两张官方动作表（GetUseItemActions / GetInventoryActions），
    -- 官方按鼠标有无物品二选一，故两条链路互不干扰、无需互相让位。
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareGrinding)
    ActionUtil:RegisterUseItemActionsModifier(ThePlayer, 0, GrindingActionsModifier)
    -- 调味：手持调料 → 右键物品栏未调味料理（同路径）
    ActionUtil:RegisterInventoryItemHandler(ThePlayer, 0, PrepareChefFlavour)
    ActionUtil:RegisterUseItemActionsModifier(ThePlayer, 0, ChefFlavourActionsModifier)
end

return Init