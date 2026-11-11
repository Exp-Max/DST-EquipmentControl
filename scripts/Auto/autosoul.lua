-- 自动灵魂（沃拓克斯 / 灵魂能力者）
-- 移植自 Exp_Max/scripts/Players/wortox.lua；原模块只保留「检查灵魂 → 开关自动倒走」。
-- 由 modmain.lua 以 modimport 加载（本文件使用 AddPlayerPostInit / AddPrefabPostInit）。
-- 纯客户端：背包、技能、容器一律走 replica；动作一律发 RPC 给服务端。
--
-- 功能：
--   1. 自动存罐 / 防爆魂（灵魂超出上限时转进灵魂罐）
--   2. 检查灵魂罐 → 开关自动刷分身（清除 nosouljar 标签）
--   3. 中键灵魂跳跃 + 三准星（鼠标 / 落点 / epic 目标途径点）
--   4. 悬停灵魂显示治疗范围圈
--   5. 过载前转移灵魂、追踪飞来的灵魂；好孩子倾向按飞来数提前存罐留出阈值
--
-- 官方依据：scripts/entityscript.lua:1435 GetDistanceSqToPoint(x,y,z)；
--           scripts/components/inventory_replica.lua:522 InspectItemFromInvTile(item)；
--           scripts/prefabs/inventory_classified.lua:166 GetItems 按槽位索引保留空洞；
--           scripts/prefabs/wortox.lua:313 CheckForOverload（naughty 才有过载缓冲）；
--           scripts/prefabs/wortox.lua:251 RecalculateInclination 注释 "Server and Client ran."，
--                 客户端同样把结果写进 inst.wortox_inclination（由 SkillTreeUtil 统一读取）；
--           scripts/prefabs/skilltree_wortox.lua:95 CalculateInclination 未倾斜时返回 nil（默认倾向）；
--           scripts/prefabs/wortox_soul_common.lua:107 每个 wortox_soul_spawn 对应 1 个灵魂。
-- 工具层：库存/物品/技能树统一走 EC 的 InventoryUtil / ItemUtil / SkillTreeUtil（全局单例）。
--         EC util 没有「最近实体、距离钳制、准星、地面圈、悬停取物」能力，
--         这些按 EC 其它 Auto 模块的惯例保留在模块内（见各段注释）。

local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local Say = require "util/say"

-- =============================================
-- 核心判定
-- =============================================

-- 倾向统一走 SkillTreeUtil:GetInclination()：工具层封装官方字段，业务层既不直读实体字段，
-- 也不再用 CountTag/IsSkillActivated 二次推算同一套官方算法。

-- 灵魂罐是技能树物品，必须激活 wortox_souljar_1 才能使用。
-- 走 EC 全局 SkillTreeUtil：内部同样调官方 skilltreeupdater:IsActivated，兼容 extraskillcheck 拦截。
local function CanUseSoulJar()
    return SkillTreeUtil:IsSkillActivated("wortox_souljar_1")
end

-- 官方只有 wortox_souljar 一种罐子，没有「破损罐」形态（wortox.lua:318 也是只判此 prefab）
local function IsJar(item)
    return item and item.prefab == "wortox_souljar"
end

-- 找第一个未满罐子：官方 wortox_souljar.lua:63-66 把容器填充度写进 finiteuses，
-- 所以 ItemUtil:GetPercentUsed 读到的就是已装灵魂百分比（0-100）。
-- 只查主物品栏并按槽升序：后续 STORE RPC 需要罐子位于物品栏格子；
-- 不用 InventoryUtil:FindItem，官方实现还会查手持物与背包（inventory_classified.lua:391-396）。
-- 返回 jar, 已装百分比；找不到返回 nil, 0。
local function FindUnfilledJar()
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        local item = InventoryUtil:GetItemInSlot(slot)
        if IsJar(item) then
            local pct = ItemUtil:GetPercentUsed(item)
            if pct < 100 then return item, pct end
        end
    end
    return nil, 0
end

local function GetSoulCount(player)
    if not player then return 0 end
    -- 官方 Has 返回 (是否足够, 实际数量)；amount=0 时取第二返回值
    local _, count = InventoryUtil:Has("wortox_soul", 0, false)
    return count or 0
end

local function GetJarCount(player)
    if not player then return 0 end
    local jars = 0
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        if IsJar(InventoryUtil:GetItemInSlot(slot)) then jars = jars + 1 end
    end
    local active = InventoryUtil:GetActiveItem()
    if active and IsJar(active) then jars = jars + 1 end
    return jars
end

-- 灵魂上限（官方 TUNING + 技能树加成）
local function GetMaxSouls(player)
    local max = TUNING.WORTOX_MAX_SOULS
    if SkillTreeUtil:IsSkillActivated("wortox_souljar_2") then
        max = max + GetJarCount(player) * TUNING.SKILLS.WORTOX.FILLED_SOULJAR_SOULCAP_INCREASE_PER
    end
    return max
end

-- 正在飞向本地玩家的灵魂（wortox_soul_spawn）。客户端没有同步的投射目标，
-- 只能按官方吸取范围猜最近 soulstealer；好孩子/默认倾向落袋即判过载，
-- 自动存罐要按这个数量提前腾出等量的背包位置。
local incoming_souls = {}
local function GetIncomingSoulCount()
    for soul in pairs(incoming_souls) do
        if not soul:IsValid() then incoming_souls[soul] = nil end
    end
    local count = 0
    for _ in pairs(incoming_souls) do count = count + 1 end
    return count
end

-- =============================================
-- 自动存罐（默认启用，爆魂是沃托克斯自身机制，无罐技能时跳过）
-- =============================================

local auto_store_task = nil
local is_opening_jar = false

local function CheckAndStoreSouls(player)
    if not PlayerUtil:HasTag(player, "soulstealer") or is_opening_jar then return end
    -- 坏孩子倾向不自动存罐（nil / 默认视为好孩子）
    if SkillTreeUtil:GetInclination(player) == "naughty" then return end
    -- 无罐技能 → 跳过（非 wortox 没有爆魂机制，无需处理）
    if not CanUseSoulJar() then return end

    local soulnum = GetSoulCount(player)
    local maxnum = GetMaxSouls(player)
    -- nice / 默认倾向没有过载缓冲，灵魂落袋即爆魂（wortox.lua:328-345）。
    -- 先按「正在飞来的灵魂数」压低目标值，提前把等量位置腾进罐子。
    local target = math.max(0, maxnum - GetIncomingSoulCount())
    if soulnum <= target then return end

    local should_store = soulnum - target
    local inv = InventoryUtil:GetInventory()
    if not inv then return end

    local soul_jar, jar_used = FindUnfilledJar()
    if not soul_jar then return end

    -- 找灵魂
    local soul_item, soul_slot = nil, nil
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        local item = InventoryUtil:GetItemInSlot(slot)
        if item and item.prefab == "wortox_soul" then
            soul_item, soul_slot = item, slot
            break
        end
    end
    if not soul_item then return end

    is_opening_jar = true
    local jar_space = math.ceil(((100 - jar_used) / 100) * TUNING.STACK_SIZE_SMALLITEM)
    local store_amount = math.min(jar_space, should_store)

    local active = InventoryUtil:GetActiveItem()
    if active then
        SendRPCToServer(RPC.SwapActiveItemWithSlot, soul_slot, nil)
        SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.STORE.code, soul_jar, nil, nil)
        SendRPCToServer(RPC.SwapActiveItemWithSlot, soul_slot, nil)
    else
        -- 主物品栏空槽（原 INV_util:FindEmptySlot 的等价：只看主物品栏，不占用背包）
        local pos = InventoryUtil:FindEmptySlot(inv)
        if pos then
            SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, soul_slot, nil, store_amount)
            SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.STORE.code, soul_jar, nil, nil)
            SendRPCToServer(RPC.PutAllOfActiveItemInSlot, pos)
        else
            SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, soul_slot, nil, store_amount)
            SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.STORE.code, soul_jar, nil, nil)
            SendRPCToServer(RPC.PutAllOfActiveItemInSlot, soul_slot, nil)
        end
    end

    if should_store - store_amount > 0 then
        player:DoTaskInTime(0.5, function()
            is_opening_jar = false
            CheckAndStoreSouls(player)
        end)
    else
        player:DoTaskInTime(1, function() is_opening_jar = false end)
    end
end

-- =============================================
-- 自动刷分身（开罐清除 nosouljar 标签）
-- =============================================

local auto_fix_jar = false
local auto_fix_task = nil

local function FixNosouljarSouls(player)
    if not auto_fix_jar or not InventoryUtil:GetInventory() then return end
    if not CanUseSoulJar() then return end

    -- 找带 nosouljar 标签的灵魂
    local has_tagged = false
    local soul_jar = nil
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        local item = InventoryUtil:GetItemInSlot(slot)
        if item then
            if item.prefab == "wortox_soul" and ItemUtil:HasTag(item, "nosouljar") then
                has_tagged = true
            elseif IsJar(item) and not soul_jar then
                soul_jar = item
            end
        end
    end
    if not has_tagged or not soul_jar then return end

    -- 罐子已打开则跳过
    if player.HUD and player.HUD.controls and player.HUD.controls.containers then
        for k, _ in pairs(player.HUD.controls.containers) do
            if IsJar(k) then return end
        end
    end

    SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.RUMMAGE.code, soul_jar)
    player:DoTaskInTime(0, function()
        if player and player:IsValid() then
            local pos = player:GetPosition()
            if pos then SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, pos.x, pos.z) end
        end
    end)
end

local function ToggleAutoFixJar(player)
    auto_fix_jar = not auto_fix_jar
    local prompts = MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS
    local msg = auto_fix_jar and prompts.AUTO_SOUL_FIX_JAR_ON or prompts.AUTO_SOUL_FIX_JAR_OFF
    print("[EC][AutoSoul] " .. msg)
    Say(msg)
    if auto_fix_jar then
        auto_fix_task = player:DoPeriodicTask(0.5, function() FixNosouljarSouls(player) end)
    else
        if auto_fix_task then auto_fix_task:Cancel(); auto_fix_task = nil end
    end
end

-- =============================================
-- 检查背包格子：灵魂罐 → 开关自动刷分身
-- 说明：沿用品类方法补丁链（不用 ActionUtil 实例通道），
--       才能与 Exp_Max 保留的「检查灵魂 → 自动倒走」补丁、EC quickactions 的
--       实例钩子按顺序共存；后加载的补丁先判，不匹配就交回上一层。
-- =============================================

local Inventory = require "components/inventory_replica"
local oldInspectItemFromInvTile = Inventory.InspectItemFromInvTile
function Inventory:InspectItemFromInvTile(item, ...)
    if item and ThePlayer and PlayerUtil:HasTag(ThePlayer, "soulstealer")
        and ItemUtil:HasTag(item, "souljar") and CanUseSoulJar() then
        ToggleAutoFixJar(ThePlayer)
        return
    end
    return oldInspectItemFromInvTile(self, item, ...)
end

-- =============================================
-- 中键灵魂跳跃 + 双光标
-- =============================================

local LEAP_CONFIG = {
    MAX_LEAP_DISTANCE = 36,
    UPDATE_INTERVAL = 0.1,
    MOUSE_SCALE = 1,
    LANDING_SCALE = 1,
    EPIC_SCALE = 1.8,
    SORT_ORDER = 4,
}

-- 修饰键沿用 Exp_Max 原默认 KEY_LALT；按住后锁定 epic 目标，中键跳到 epic 后方落点
local LEAP_MODIFIER_KEY = KEY_LALT

local LEAP_COLOR = {
    MOUSE  = {0.2, 1, 0.2, 1},
    LANDING = {1, 0.2, 0.2, 1},
    EPIC   = {1, 0.8, 0.2, 1},
}

local function UpdateReticule(player, key, position, scale, color)
    if not player or not position then return end
    local marker = player[key]
    if not marker or not marker:IsValid() then
        marker = SpawnPrefab("reticule")
        if not marker then return end
        marker.persists = false
        marker.AnimState:PlayAnimation("idle", true)
        marker.AnimState:SetLightOverride(1)
        marker.Transform:SetScale(scale, scale, scale)
        marker.AnimState:SetSortOrder(LEAP_CONFIG.SORT_ORDER)
        if marker.AnimState.SetBloomEffectHandle then
            marker.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
        end
        player[key] = marker
    end
    marker.Transform:SetPosition(position.x, 0, position.z)
    marker.AnimState:SetMultColour(unpack(color))
end

local function HideReticule(player, key)
    if not player then return end
    local marker = player[key]
    if marker and marker:IsValid() then
        marker:Remove()
        player[key] = nil
    end
end

local function HideAllReticules(player)
    HideReticule(player, "_ec_autosoul_leap_mouse")
    HideReticule(player, "_ec_autosoul_leap_landing")
    HideReticule(player, "_ec_autosoul_leap_epic")
end

local function FindEpicTarget(player, range)
    local pp = player:GetPosition()
    local nearest, nearest_sq = nil, range * range
    local entities = TheSim:FindEntities(pp.x, 0, pp.z, range, {"epic"})
    for _, ent in ipairs(entities) do
        if ent:IsValid() then
            local sq = ent:GetDistanceSqToPoint(pp)
            if sq < nearest_sq then nearest_sq, nearest = sq, ent end
        end
    end
    return nearest
end

-- 获取当前 epic 目标：锁定目标优先，无效则清锁并回退搜索
local function GetEpicTarget(player)
    local locked = player._ec_autosoul_epic_locked
    if locked and locked:IsValid() then
        return locked
    end
    player._ec_autosoul_epic_locked = nil
    return FindEpicTarget(player, LEAP_CONFIG.MAX_LEAP_DISTANCE)
end

-- 钳制目标点到最大跳跃距离
local function ClampLeapTarget(p1, p2, max_dist)
    local dx, dz = p2.x - p1.x, p2.z - p1.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist <= 0 then return Vector3(p1.x, 0, p1.z) end
    if dist > max_dist then
        return Vector3(p1.x + max_dist * dx / dist, 0, p1.z + max_dist * dz / dist)
    end
    return Vector3(p2.x, 0, p2.z)
end

-- 计算 epic 落点：玩家→epic 延长线，过 epic 再走相同距离
local function CalcEpicLanding(pp, ep, max_dist)
    local edx, edz = ep.x - pp.x, ep.z - pp.z
    local edist = math.sqrt(edx * edx + edz * edz)
    if edist <= 0 then return nil end
    local total = math.min(edist * 2, max_dist)
    return Vector3(pp.x + total * edx / edist, 0, pp.z + total * edz / edist)
end

local function UpdateLeapReticules(player)
    local mousepos = TheInput:GetWorldPosition()
    if not mousepos then return end

    local pp = player:GetPosition()
    local max_dist = LEAP_CONFIG.MAX_LEAP_DISTANCE

    local clamped = ClampLeapTarget(pp, mousepos, max_dist)
    UpdateReticule(player, "_ec_autosoul_leap_mouse", clamped, LEAP_CONFIG.MOUSE_SCALE, LEAP_COLOR.MOUSE)

    local epic = GetEpicTarget(player)
    if epic then
        local ep = epic:GetPosition()
        UpdateReticule(player, "_ec_autosoul_leap_epic", Vector3(ep.x, 0, ep.z), LEAP_CONFIG.EPIC_SCALE, LEAP_COLOR.EPIC)
        local landing = CalcEpicLanding(pp, ep, max_dist)
        if landing then
            UpdateReticule(player, "_ec_autosoul_leap_landing", landing, LEAP_CONFIG.LANDING_SCALE, LEAP_COLOR.LANDING)
        end
    else
        HideReticule(player, "_ec_autosoul_leap_epic")
        local dx, dz = mousepos.x - pp.x, mousepos.z - pp.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist > 0 then
            UpdateReticule(player, "_ec_autosoul_leap_landing",
                Vector3(pp.x + max_dist * dx / dist, 0, pp.z + max_dist * dz / dist),
                LEAP_CONFIG.LANDING_SCALE, LEAP_COLOR.LANDING)
        end
    end
end

local function ExecuteLeap(player, use_epic)
    local pp = player:GetPosition()

    if use_epic then
        local epic = GetEpicTarget(player)
        if epic then
            local landing = CalcEpicLanding(pp, epic:GetPosition(), LEAP_CONFIG.MAX_LEAP_DISTANCE)
            if landing then
                SendRPCToServer(RPC.LeftClick, ACTIONS.BLINK.code, landing.x, landing.z)
            end
            return
        end
    end

    local mousepos = TheInput:GetWorldPosition()
    if not mousepos then return end
    local target = ClampLeapTarget(pp, mousepos, LEAP_CONFIG.MAX_LEAP_DISTANCE)
    SendRPCToServer(RPC.LeftClick, ACTIONS.BLINK.code, target.x, target.z)
end

-- =============================================
-- 治疗范围显示
-- =============================================

local healing_indicator = nil
local is_range_visible = false

local function GetHealingRange()
    local base = TUNING.WORTOX_SOULHEAL_RANGE
    if SkillTreeUtil:IsSkillActivated("wortox_soulprotector_1") then
        base = base + TUNING.SKILLS.WORTOX.WORTOX_SOULPROTECTOR_1_RANGE
        if SkillTreeUtil:IsSkillActivated("wortox_soulprotector_2") then
            base = base + TUNING.SKILLS.WORTOX.WORTOX_SOULPROTECTOR_2_RANGE
        end
    end
    return base
end

local function ShowHealingIndicator(player)
    -- 无被动治疗技能 → 不显示范围圈
    if not SkillTreeUtil:IsSkillActivated("wortox_soulprotector_1")
        and not SkillTreeUtil:IsSkillActivated("wortox_liftedspirits_1") then return end
    if healing_indicator then healing_indicator:Remove() end
    healing_indicator = nil

    local inst = CreateEntity()
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.entity:SetCanSleep(false)
    inst.persists = false
    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    local range = GetHealingRange() * 4
    local TEXTURE_SIZE = 1900
    local scale = math.sqrt(range * 300 / TEXTURE_SIZE)

    inst.AnimState:SetBank("firefighter_placement")
    inst.AnimState:SetBuild("firefighter_placement")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    inst.AnimState:SetSortOrder(3)
    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
    inst.AnimState:SetMultColour(0.2, 1, 0.2, 0.4)
    inst.AnimState:SetAddColour(0, 0.2, 0, 0.2)
    inst.Transform:SetScale(scale, scale, scale)
    inst.entity:SetParent(player.entity)

    healing_indicator = inst
    healing_indicator:Show()
    is_range_visible = true
end

local function HideHealingIndicator()
    is_range_visible = false
    if healing_indicator and healing_indicator:IsValid() then
        healing_indicator:Hide()
    end
end

-- EC util 没有导出的「取悬停物品」能力（showmeutil 的同款函数是 local，
-- autocontainer 也各写一份），这里按本模块的单一用途保留最小实现。
local function IsMouseOverSoul()
    local target = TheInput:GetHUDEntityUnderMouse()
    if target then
        target = target.widget and target.widget.parent and target.widget.parent.item
    else
        target = TheInput:GetWorldEntityUnderMouse()
    end
    return target and target.prefab == "wortox_soul"
end

-- =============================================
-- 过载前转移灵魂到罐子
-- =============================================

local function PutExtraSoulToJar(player)
    if not CanUseSoulJar() then return end
    local max = GetMaxSouls(player)
    local current = GetSoulCount(player)
    if current <= max then return end

    local excess = current - max
    if not InventoryUtil:GetInventory() then return end

    local jar = FindUnfilledJar()

    -- 找灵魂
    local soul_slot = nil
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        local item = InventoryUtil:GetItemInSlot(slot)
        if item and item.prefab == "wortox_soul" then soul_slot = slot; break end
    end

    if soul_slot and jar then
        SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, soul_slot, nil, excess)
        SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.STORE.code, jar)
        SendRPCToServer(RPC.PutAllOfActiveItemInSlot, soul_slot, nil)
    end
end

-- =============================================
-- 防爆魂：坏孩子倾向的过载缓冲期转移灵魂
-- =============================================

local function GetTotalSoulCount(player)
    local count = GetSoulCount(player)
    -- 坏孩子倾向不计算飞来灵魂（最后 0.5 秒存魂），其它倾向计入
    if SkillTreeUtil:GetInclination(player) ~= "naughty" then
        count = count + GetIncomingSoulCount()
    end
    local active = InventoryUtil:GetActiveItem()
    if active and active.prefab == "wortox_soul" then
        count = count + InventoryUtil:GetStackSize(active)
    end
    return count
end

local function DoNaughtySoulStore(player)
    if not player or not player:IsValid() then return end
    player._ec_autosoul_soul_store_scheduled = nil

    if is_opening_jar then
        player:DoTaskInTime(0.5, function() DoNaughtySoulStore(player) end)
        return
    end

    local max = GetMaxSouls(player)
    local total = GetTotalSoulCount(player)
    if total <= max then return end

    -- 无罐技能 → 跳过（非 wortox 没有爆魂机制）
    if not CanUseSoulJar() then return end

    local excess = total - max
    if not InventoryUtil:GetInventory() then return end

    local jar, jar_used = FindUnfilledJar()
    if not jar then return end

    -- 找灵魂
    local soul_slot = nil
    for slot = 1, InventoryUtil:GetNumSlots() or 0 do
        local item = InventoryUtil:GetItemInSlot(slot)
        if item and item.prefab == "wortox_soul" then soul_slot = slot; break end
    end
    if not soul_slot then return end

    local jar_space = math.ceil(((100 - jar_used) / 100) * TUNING.STACK_SIZE_SMALLITEM)
    local store_amount = math.min(jar_space, excess)
    SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, soul_slot, nil, store_amount)
    SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.STORE.code, jar, nil, nil)
    SendRPCToServer(RPC.PutAllOfActiveItemInSlot, soul_slot, nil)

    player:DoTaskInTime(0.5, function()
        if GetTotalSoulCount(player) > GetMaxSouls(player) then
            DoNaughtySoulStore(player)
        end
    end)
end

-- =============================================
-- 主初始化
-- =============================================

local function InitSoulstealerFeatures(player)
    -- 进入游戏时清掉残留
    incoming_souls = {}

    -- 自动存罐
    player:DoTaskInTime(0.5, function()
        if player:IsValid() then
            auto_store_task = player:DoPeriodicTask(0.5, function() CheckAndStoreSouls(player) end)
        end
    end)

    -- 中键跳跃 + 治疗范围
    player:DoTaskInTime(0.5, function()
        if not player:IsValid() then return end

        -- 跳跃光标更新（HUD 上有实体或输入焦点时隐藏准星，拦截冲刺）
        player._ec_autosoul_leap_task = player:DoPeriodicTask(LEAP_CONFIG.UPDATE_INTERVAL, function()
            if not player:IsValid() then
                player._ec_autosoul_leap_task:Cancel()
                player._ec_autosoul_leap_task = nil
                HideAllReticules(player)
                return
            end
            if GetSoulCount(player) > 0
                and not TheInput:GetHUDEntityUnderMouse()
                and not (player.HUD and player.HUD:HasInputFocus()) then
                UpdateLeapReticules(player)
            else
                HideAllReticules(player)
            end
        end)

        -- 修饰键按下 → 锁定当前最近 epic 目标，松开 → 解锁
        TheInput:AddKeyDownHandler(LEAP_MODIFIER_KEY, function()
            if GetSoulCount(player) > 0 and not player._ec_autosoul_epic_locked then
                local epic = FindEpicTarget(player, LEAP_CONFIG.MAX_LEAP_DISTANCE)
                if epic then
                    player._ec_autosoul_epic_locked = epic
                end
            end
        end)
        TheInput:AddKeyUpHandler(LEAP_MODIFIER_KEY, function()
            player._ec_autosoul_epic_locked = nil
        end)

        TheInput:AddMouseButtonHandler(function(button, down, x, y)
            if not down then return false end
            if button == MOUSEBUTTON_MIDDLE and GetSoulCount(player) > 0
                and not TheInput:GetHUDEntityUnderMouse() then
                local use_epic = TheInput:IsKeyDown(LEAP_MODIFIER_KEY)
                ExecuteLeap(player, use_epic)
                if auto_fix_jar then FixNosouljarSouls(player) end
                return true
            end
            return false
        end)

        player:ListenForEvent("onremove", function()
            if player._ec_autosoul_leap_task then
                player._ec_autosoul_leap_task:Cancel()
                player._ec_autosoul_leap_task = nil
            end
            HideAllReticules(player)
        end)
    end)

    -- 治疗范围更新
    player:DoPeriodicTask(0, function()
        if IsMouseOverSoul() then
            ShowHealingIndicator(player)
        else
            HideHealingIndicator()
        end
    end)

    -- 技能激活/停用时重建治疗圈。
    -- 保留玩家实体事件：SkillTreeUtil 的回调列表在换人 Reset 时清空且依赖 TryInit，
    -- 监听实体事件不依赖工具初始化状态。
    local function OnSkillChanged()
        if is_range_visible then
            if healing_indicator then healing_indicator:Remove() end
            healing_indicator = nil
            ShowHealingIndicator(player)
        end
    end
    player:ListenForEvent("onactivateskill_client", OnSkillChanged)
    player:ListenForEvent("ondeactivateskill_client", OnSkillChanged)

    -- 清理
    player:ListenForEvent("onremove", function()
        if auto_store_task then auto_store_task:Cancel(); auto_store_task = nil end
        if auto_fix_task then auto_fix_task:Cancel(); auto_fix_task = nil end
        auto_fix_jar = false
        is_opening_jar = false
        incoming_souls = {}
    end)
end

-- 初始化走 EC 的 AutoInits：modmain.lua 在 OnPlayerActivated 里调用，那时 ThePlayer 已赋值。
-- 原 AddPlayerPostInit + DoTaskInTime(0) 常早于 ThePlayer 赋值，整个模块会静默不初始化。
local function Init()
    local player = ThePlayer
    if player == nil then return end

    if not player._ec_autosoul_equip_hooked then
        player._ec_autosoul_equip_hooked = true
        -- 灵魂能力可能来自装备勋章，晚于进世界才获得
        player:ListenForEvent("equip", function(inst, data)
            if player == ThePlayer and not player._ec_autosoul_init
                and PlayerUtil:HasTag(player, "soulstealer") then
                player._ec_autosoul_init = true
                InitSoulstealerFeatures(player)
            end
        end)
    end

    if not player._ec_autosoul_init and PlayerUtil:HasTag(player, "soulstealer") then
        player._ec_autosoul_init = true
        InitSoulstealerFeatures(player)
    end
end
table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, Init)

-- 过载前转移灵魂（坏孩子倾向的 10 秒缓冲窗口）
-- 客户端常拿不到服务端 SetParent 的 parent（官方 wortox.lua:1096 也做了 nil 兜底），
-- 改由本地玩家判定；PutExtraSoulToJar 内部有「灵魂数 > 上限」闸门，不会误存。
-- 计时挂在玩家实体上，避免特效提前移除导致任务被取消。
AddPrefabPostInit("wortox_overloading_fx", function(inst)
    inst:DoTaskInTime(0, function()
        if not PlayerUtil:HasTag(ThePlayer, "soulstealer") then return end
        ThePlayer:DoTaskInTime(TUNING.SKILLS.WORTOX.NAUGHTY_OVERLOAD_STOP_TIME - 0.5, function()
            PutExtraSoulToJar(ThePlayer)
        end)
    end)
end)

-- 检测飞来灵魂：客户端没有官方同步的投射目标，按官方吸取范围猜最近 soulstealer。
-- 一旦确认归属立即登记 + 预存罐；确认后取消每帧检测，避免空转。
AddPrefabPostInit("wortox_soul_spawn", function(inst)
    inst:DoTaskInTime(0, function()
        -- 服务端 range_small + 技能加成，客户端取最大范围保守判定
        local range = TUNING.WORTOX_SOULSTEALER_RANGE + TUNING.SKILLS.WORTOX.SOULSTEALER_RANGE_BONUS

        local function TryRegisterIncomingSoul()
            if not inst:IsValid() or inst._soul_target_confirmed then return end
            local x, _, z = inst.Transform:GetWorldPosition()
            local nearest, nearest_sq = nil, range * range
            for _, p in ipairs(AllPlayers or {}) do
                if p and p:IsValid() and p.entity:IsVisible() and PlayerUtil:HasTag(p, "soulstealer")
                    and not (PlayerUtil:HasTag(p, "playerghost") or (p.replica.health and p.replica.health:IsDead())) then
                    local sq = p:GetDistanceSqToPoint(x, 0, z)
                    if sq and sq < nearest_sq then nearest_sq, nearest = sq, p end
                end
            end
            if nearest ~= ThePlayer then return end

            inst._soul_target_confirmed = true
            incoming_souls[inst] = true
            -- 好孩子/默认倾向落袋即爆魂，不能等 0.5s 的周期任务：立即按新阈值预存罐。
            -- CheckAndStoreSouls 内部会自行跳过 naughty 倾向。
            CheckAndStoreSouls(ThePlayer)
            -- 坏孩子倾向有官方过载缓冲，仍走缓冲期末的转移
            if SkillTreeUtil:GetInclination() == "naughty"
                and not ThePlayer._ec_autosoul_soul_store_scheduled then
                ThePlayer._ec_autosoul_soul_store_scheduled = true
                ThePlayer:DoTaskInTime(TUNING.SKILLS.WORTOX.NAUGHTY_OVERLOAD_STOP_TIME - 0.5, function()
                    DoNaughtySoulStore(ThePlayer)
                end)
            end
            if inst._detection_task then
                inst._detection_task:Cancel()
                inst._detection_task = nil
            end
        end

        -- 生成后立刻尝试一次（原来 initialdelay=1 秒，常错过飞行窗口）
        TryRegisterIncomingSoul()
        if not inst._soul_target_confirmed then
            inst._detection_task = inst:DoPeriodicTask(FRAMES, TryRegisterIncomingSoul)
        end

        inst:ListenForEvent("onremove", function()
            incoming_souls[inst] = nil
            if inst._detection_task then inst._detection_task:Cancel(); inst._detection_task = nil end
        end)
    end)
end)
