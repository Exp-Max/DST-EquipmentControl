-- 巨石躲避：岩石树(Boulderbough)即将砸下巨石时自动走开躲避
-- 移植自 Boulder Dodger (workshop-3767257007)，适配 EC 架构
--
-- 核心机制：
--   1. 客户端砍伐追踪：统计每棵树被砍次数，自学习每种斧子需要几刀砍倒
--   2. 双路危险检测：实况坠落动画 + 预测（砍伐致命刀后1秒算危险）
--   3. 多角度闪避寻路：12个角度从威胁放射状搜索安全点
--   4. 可选：自动切手杖/橙宝石法杖加速

local CONFIG = MOD_EQUIPMENT_CONTROL.CONFIG
local InventoryUtil = require("util/inventoryutil")
local PlayerUtil = require "util/playerutil"

-- ==========================================
-- 配置
-- ==========================================

local SCAN_RADIUS = 10
local ROCK_TREE_TAGS = { "rock_tree" }
local WALK_REISSUE = 3 * FRAMES
local PREDICT_EXPIRE = 1.0

-- 坠落危险动画（所有 stage × 所有 fall 状态 × 燃烧变种）
local DANGER_ANIMS = {}
local CHOP_ANIMS = {}
for _, stage in ipairs({ "short", "normal", "tall" }) do
    for _, base in ipairs({ "fall_pre", "fall_miss", "fall_bounce" }) do
        table.insert(DANGER_ANIMS, base .. "_" .. stage)
        table.insert(DANGER_ANIMS, base .. "_burnt_" .. stage)
    end
    table.insert(CHOP_ANIMS, "chop_" .. stage)
end

-- ==========================================
-- 砍伐追踪（弱键表，实体移除后 GC 回收）
-- ==========================================

local tracked = setmetatable({}, { __mode = "k" })
local predicted = setmetatable({}, { __mode = "k" })
local learned = {}
local swing = { active = false, prev_t = nil, fired = false, tree = nil, count = 0 }

local function GetToolPrefab(player)
    local item = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
    return item and item.prefab or nil
end

local function Learn(tool, total)
    local l = learned[tool]
    if l == nil then
        l = {}
        learned[tool] = l
    end
    if l.last == total then
        l.trusted = total
    end
    l.last = total
end

local function GetChopsToFell(player)
    local override = CONFIG.DODGE_CHOPS_OVERRIDE or 0
    if override > 0 then return override end
    local tool = GetToolPrefab(player)
    local l = tool and learned[tool] or nil
    return l and l.trusted or nil
end

-- ==========================================
-- 危险检测
-- ==========================================

local function IsFalling(ent)
    if ent.AnimState == nil then return false end
    -- 冻结动画（时间超过长度）是客户端陈旧状态，不是真的坠落
    if ent.AnimState:GetCurrentAnimationTime() > ent.AnimState:GetCurrentAnimationLength() + 0.5 then
        return false
    end
    for _, anim in ipairs(DANGER_ANIMS) do
        if ent.AnimState:IsCurrentAnimation(anim) then
            return true
        end
    end
    return false
end

local function IsChopAnim(ent)
    for _, anim in ipairs(CHOP_ANIMS) do
        if ent.AnimState:IsCurrentAnimation(anim) then
            return true
        end
    end
    return false
end

local function IsDangerous(ent, now)
    if IsFalling(ent) then return true end
    local expire = predicted[ent]
    return expire and expire > now
end

-- ==========================================
-- 砍伐追踪 & 预测闪避
-- ==========================================

local function UpdateChopTracking(player, ent)
    local st = tracked[ent]
    if st == nil then
        st = { count = 0 }
        tracked[ent] = st
    end
    if IsChopAnim(ent) then
        local t = ent.AnimState:GetCurrentAnimationTime()
        if not st.was_chop or (st.prev_t and t < st.prev_t) then
            st.count = st.count + 1
            st.tool = GetToolPrefab(player)
        end
        st.prev_t = t
        st.was_chop = true
    else
        st.prev_t = nil
        st.was_chop = false
    end
    if not st.fell and IsFalling(ent) then
        st.fell = true
        if st.count > 0 and st.tool then
            Learn(st.tool, st.count + 1)
        end
    end
    return st
end

local function FindNearestTrackedTree(player, ents)
    local best, bestdistsq
    for _, ent in ipairs(ents) do
        if ent:IsValid() and not IsFalling(ent) and tracked[ent] then
            local distsq = player:GetDistanceSqToInst(ent)
            if distsq < 9 and (bestdistsq == nil or distsq < bestdistsq) then
                best, bestdistsq = ent, distsq
            end
        end
    end
    return best
end

-- 砍伐动画第5帧判定为致命一刀（服务器已提交工作），预测1秒后坠落
local function CheckPredictiveFlee(player, ents, now)
    local anim = player.AnimState
    local ischop = anim:IsCurrentAnimation("chop_loop") or anim:IsCurrentAnimation("woodie_chop_loop")
    if not ischop then
        swing.active = false
        swing.prev_t = nil
        return
    end

    local t = anim:GetCurrentAnimationTime()
    if not swing.active or (swing.prev_t and t < swing.prev_t) then
        swing.active = true
        swing.fired = false
        swing.tree = FindNearestTrackedTree(player, ents)
        swing.count = swing.tree and tracked[swing.tree].count or 0
    end
    swing.prev_t = t

    if swing.fired or not swing.tree or not swing.tree:IsValid() then return end
    if t >= 5 * FRAMES then
        swing.fired = true
        local total = GetChopsToFell(player)
        if total and swing.count >= total - 1 then
            predicted[swing.tree] = now + PREDICT_EXPIRE
        end
    end
end

-- ==========================================
-- 闪避寻路
-- ==========================================

local function GetSafeDist(ent, player)
    local tree_rock = TUNING.TREE_ROCK or { ROCK1_AOE_RADIUS = 3, ROCK2_AOE_RADIUS = 4 }
    local radius = ent.prefab == "tree_rock1"
        and tree_rock.ROCK1_AOE_RADIUS
        or tree_rock.ROCK2_AOE_RADIUS
    local margin = CONFIG.DODGE_MARGIN or 1.0
    return radius + player:GetPhysicsRadius(0.5) + margin
end

local ANGLE_OFFSETS = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 }

local function IsPointSafe(pt, player, dangers)
    if not TheWorld.Map:IsPassableAtPoint(pt.x, 0, pt.z) then return false end
    for _, ent in ipairs(dangers) do
        local safe = GetSafeDist(ent, player)
        if ent:GetDistanceSqToPoint(pt.x, 0, pt.z) < safe * safe then
            return false
        end
    end
    return true
end

local function FindDodgePoint(player, threat, dangers)
    local px, _, pz = player.Transform:GetWorldPosition()
    local tx, _, tz = threat.Transform:GetWorldPosition()
    local dist = GetSafeDist(threat, player) + 0.5

    local base_angle
    if px == tx and pz == tz then
        base_angle = math.random() * 2 * math.pi
    else
        base_angle = math.atan2(pz - tz, px - tx)
    end

    local fallback
    for _, offset in ipairs(ANGLE_OFFSETS) do
        local angle = base_angle + offset * DEGREES
        local pt = Point(tx + math.cos(angle) * dist, 0, tz + math.sin(angle) * dist)
        fallback = fallback or pt
        if IsPointSafe(pt, player, dangers) then
            return pt
        end
    end
    return fallback
end

-- ==========================================
-- 行走 & ActionQueue 兼容
-- ==========================================

local last_walk_time = 0

local function WalkTo(player, pt)
    local now = GetTime()
    if now - last_walk_time < WALK_REISSUE then return end
    last_walk_time = now

    local pc = player.components.playercontroller
    if pc == nil then return end

    if pc.locomotor then
        local act = BufferedAction(player, nil, ACTIONS.WALKTO, nil, pt)
        act.preview_cb = function()
            SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, pt.x, pt.z)
        end
        pc:DoAction(act)
    else
        SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, pt.x, pt.z)
    end
end

-- ==========================================
-- 手杖自动装备（可选，利用 EC 已有体系）
-- ==========================================

local SPEED_ITEMS = { cane = true, orangestaff = true }
local dodge_equip = { active = false, prev_item = nil, hold_until = 0 }

local function TryEquipSpeedItem(player)
    if not CONFIG.DODGE_USE_CANE or dodge_equip.active or player:HasTag("wereplayer") then
        return
    end
    if not InventoryUtil:GetInventory() then return end

    local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
    if equipped and SPEED_ITEMS[equipped.prefab] then return end

    local body = InventoryUtil:GetEquippedItem(EQUIPSLOTS.BODY)
    local backpack = body and body.replica.container or nil
    for _, inv in ipairs(backpack and { inventory, backpack } or { inventory }) do
        for _, item in pairs(inv:GetItems()) do
            if item and SPEED_ITEMS[item.prefab] then
                dodge_equip.active = true
                dodge_equip.prev_item = equipped
                inventory:UseItemFromInvTile(item)
                return
            end
        end
    end
end

local function RestoreEquip(player)
    if not dodge_equip.active then return end
    dodge_equip.active = false
    dodge_equip.hold_until = GetTime() + 0.5

    local prev = dodge_equip.prev_item
    dodge_equip.prev_item = nil
    if prev and prev:IsValid() and InventoryUtil:GetInventory() then
        InventoryUtil:UseItemFromInvTile(prev)
    end
end

-- ==========================================
-- ActionQueue 保持
-- ==========================================

local function AnyFallingNear(player)
    local now = GetTime()
    local x, y, z = player.Transform:GetWorldPosition()
    for _, ent in ipairs(TheSim:FindEntities(x, y, z, SCAN_RADIUS, ROCK_TREE_TAGS)) do
        if ent:IsValid() and IsDangerous(ent, now) then
            return true
        end
    end
    return false
end

local function HoldWhileDodging(player)
    local deadline = GetTime() + 5
    while player:IsValid() and GetTime() < deadline
        and (AnyFallingNear(player) or dodge_equip.active or GetTime() < dodge_equip.hold_until) do
        Sleep(FRAMES)
    end
end

local function WrapActionQueuer(player)
    local aq = player.components.actionqueuer
    if aq == nil or aq._ec_boulderdodge_wrapped then return end
    aq._ec_boulderdodge_wrapped = true

    local OldSendActionAndWait = aq.SendActionAndWait
    aq.SendActionAndWait = function(self, ...)
        HoldWhileDodging(player)
        return OldSendActionAndWait(self, ...)
    end

    local OldGetClosestTarget = aq.GetClosestTarget
    aq.GetClosestTarget = function(self, ...)
        HoldWhileDodging(player)
        return OldGetClosestTarget(self, ...)
    end
end

-- ==========================================
-- 主 tick
-- ==========================================

local function IsHoldingMovementKey(pc)
    return CONFIG.DODGE_MANUAL_OVERRIDE
        and pc
        and PlayerUtil:IsAnyOfControlsPressed(
            CONTROL_MOVE_UP, CONTROL_MOVE_DOWN, CONTROL_MOVE_LEFT, CONTROL_MOVE_RIGHT)
end

local function DodgeTick(player)
    if not player:IsValid() or player:HasTag("playerghost") then return end

    WrapActionQueuer(player)

    local now = GetTime()
    local x, y, z = player.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, SCAN_RADIUS, ROCK_TREE_TAGS)

    for _, ent in ipairs(ents) do
        if ent:IsValid() then
            UpdateChopTracking(player, ent)
        end
    end
    CheckPredictiveFlee(player, ents, now)

    local dangers = {}
    for _, ent in ipairs(ents) do
        if ent:IsValid() and IsDangerous(ent, now) then
            table.insert(dangers, ent)
        end
    end
    if #dangers == 0 then
        RestoreEquip(player)
        return
    end

    local threat, mindistsq
    for _, ent in ipairs(dangers) do
        local safe = GetSafeDist(ent, player)
        local distsq = ent:GetDistanceSqToPoint(x, y, z)
        if distsq < safe * safe and (mindistsq == nil or distsq < mindistsq) then
            threat, mindistsq = ent, distsq
        end
    end
    if threat == nil or IsHoldingMovementKey(PlayerUtil:GetComponent("playercontroller")) then
        return
    end

    TryEquipSpeedItem(player)

    local pt = FindDodgePoint(player, threat, dangers)
    if pt then
        WalkTo(player, pt)
    end
end

-- ==========================================
-- 初始化 & 生命周期
-- ==========================================

local function OnPlayerActivated(player)
    if player ~= ThePlayer or player._ec_boulderdodge_task then return end
    WrapActionQueuer(player)
    player._ec_boulderdodge_task = player:DoPeriodicTask(FRAMES, function()
        if not CONFIG.BOULDER_DODGE then return end
        DodgeTick(player)
    end)
end

AddPlayerPostInit(function(player)
    player:DoTaskInTime(0, OnPlayerActivated)
end)