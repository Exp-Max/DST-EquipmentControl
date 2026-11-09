-- 自动维护模块：统一的燃料补充 / 修复 / 喂食修复 + RPC 确认 + 失败重试
-- 从 itemtracker 抽离，独立处理所有可维护物品的"卸下→维护→重装备"闭环。
--
-- 职责边界（本模块只做维护域）：
--   输入：一个需要维护的物品 → 选策略（refuel/repair/feed）→ 发 RPC → 核对生效 → 失败重试
--   输出：PushEvent("ec_fuel_added")，供 autoamulet/autoweapon 等触发重装备
-- 不在本模块内：触发时机（容器打开/库存扫描）、事件监听管理、UI 刷新
--   —— 这些属于 itemtracker 的追踪职责，本模块不反向依赖它。

local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local Say = require "util/say"

-- ==========================================
-- 配置
-- ==========================================

-- 自动维护排除列表（不自动补充这些物品的燃料/耐久）
local AutoRefuelBlacklist =
{
    strawhat = true,
    earmuffshat = true,
    fashiongoggles = true,
}

-- 维护 RPC 确认配置
local FUEL_CONFIRM_TIMEOUT = 2.0
local FUEL_SEND_MAX_FAILS  = 3
local FUEL_SLOW_INTERVAL   = 10.0

-- 维护 RPC 发出后的"等待服务端同步"窗口：
-- 窗口内不重复发起同一物品的维护（抢占竞态），由 IsMaintenancePending 对外暴露
local FUEL_SYNC_WINDOW    = 1.0

-- ==========================================
-- 状态
-- ==========================================

-- 弱键表：物品被移除后可被 GC 回收
local FuelCooldownTimers = setmetatable({}, { __mode = "k" })
local FuelPending        = setmetatable({}, { __mode = "k" })
local RetryTasks         = {}
local RetryState         = {}

-- ==========================================
-- 燃料/修复 RPC
-- ==========================================

-- @return "sent"=已发出待确认, "wait"=未发出（冷却中 / 燃料不可达 / 无可用动作）
local function AddFuel(item, fuel, action)
    local now = GetTime()
    if now - (FuelCooldownTimers[item] or 0) < FUEL_SYNC_WINDOW then return "wait" end
    if not InventoryUtil:CanUseInPlace(fuel) then
        return "wait"
    end
    if InventoryUtil:UseItemOnItem(item, fuel, action or ACTIONS.ADDFUEL) then
        FuelCooldownTimers[item] = now
        FuelPending[item] =
        {
            percent  = ItemUtil:GetPercentUsed(item),
            fuel     = fuel,
            deadline = now + FUEL_CONFIRM_TIMEOUT,
        }
        return "sent"
    end
    return "wait"
end

-- 核对已发出的补充是否真的生效
local function CheckFuelPending(item)
    local p = FuelPending[item]
    if not p then return nil end

    if not item:IsValid() then
        FuelPending[item] = nil
        return true
    end

    if ItemUtil:GetPercentUsed(item) > p.percent + 0.001
        or (p.fuel ~= nil and not p.fuel:IsValid()) then
        FuelPending[item] = nil
        return true
    end

    if GetTime() >= p.deadline then
        FuelPending[item] = nil
        FuelCooldownTimers[item] = nil
        return false
    end

    return "pending"
end

-- ==========================================
-- 维护策略
-- ==========================================

local function RunMaintenanceStrategy(item, actionName)
    if not item:IsValid() then return nil end
    if not (item.replica.inventoryitem and item.replica.inventoryitem:IsGrandOwner(ThePlayer)) then return nil end
    if AutoRefuelBlacklist[item.prefab] then return nil end
    local threshold = (actionName == "repair" or actionName == "feed")
        and ItemUtil:GetMaintenanceThreshold(item)
        or ItemUtil:GetFiniteUses(item)
    if ItemUtil:GetPercentUsed(item) > threshold then return nil end

    local strategy = ItemUtil.MaintenanceStrategies[actionName]
    if not strategy then return nil end

    local result, repairAction = strategy(ItemUtil, item)

    -- 无修复材料 → 直接 wait，不关心玩家是否忙（没有材料没法修，也不该提示"被打断"）
    if result == nil then return "wait" end

    -- 有修复材料但玩家正在忙 → 才是真正的"被打断"
    if not InventoryUtil:IsPlayerFree() then return true end

    if actionName == "refuel" then
        if AddFuel(item, result, nil) == "sent" then
            return "sent"
        end
        return "wait"
    end

    if actionName == "repair" or actionName == "feed" then
        if AddFuel(item, result, repairAction) == "sent" then
            return "sent"
        end
        return "wait"
    end

    return nil
end

local function RefuelStrategy(item)
    return RunMaintenanceStrategy(item, "refuel")
end

local function RepairStrategy(item)
    return RunMaintenanceStrategy(item, "repair")
end

local function FeedStrategy(item)
    return RunMaintenanceStrategy(item, "feed")
end

-- ==========================================
-- 重试任务管理
-- ==========================================

local function CancelRetryTask(item)
    if RetryTasks[item] then
        RetryTasks[item]:Cancel()
        RetryTasks[item] = nil
    end
    RetryState[item] = nil
    FuelCooldownTimers[item] = nil
    FuelPending[item] = nil
    item:RemoveEventCallback("onremove", CancelRetryTask)
end

local function HandlePendingResult(item, itemName)
    local p = FuelPending[item]
    if p == nil then return false end

    local pending = CheckFuelPending(item)
    if pending == true then return false end
    if pending == "pending" then
        return true
    end

    local rs = RetryState[item]
    if not rs then return false end
    if rs.slowUntil and GetTime() < rs.slowUntil then
        return true
    end

    rs.sendFails = rs.sendFails + 1
    if rs.sendFails >= FUEL_SEND_MAX_FAILS then
        rs.sendFails = 0
        rs.slowUntil = GetTime() + FUEL_SLOW_INTERVAL
        return true
    end
    Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.RETRY, itemName, rs.sendFails))
    return false
end

local function RegisterRetryTask(item, tryFn)
    if RetryTasks[item] then
        local retry = tryFn()
        if retry == false then
            CancelRetryTask(item)
            ThePlayer:PushEvent("ec_fuel_added", { item = item })
        end
        return
    end

    local itemName = item.name or item.prefab

    local retry = tryFn()
    if retry == nil then
        return
    end
    local saidRepairing = false
    if retry == "sent" then
        Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.REPAIRING, itemName))
        saidRepairing = true
    elseif retry == false then
        Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.REPAIRING, itemName))
        ThePlayer:PushEvent("ec_fuel_added", { item = item })
        return
    end

    RetryState[item] =
    {
        attempt       = 0,
        waitStart     = nil,
        wasInterrupted = false,
        itemName      = itemName,
        sendFails     = 0,
        slowUntil     = nil,
        saidRepairing = saidRepairing,
    }

    RetryTasks[item] = item:DoPeriodicTask(1, function()
        if HandlePendingResult(item, itemName) then
            return
        end

        local rs = RetryState[item]
        if not rs then return end
        if rs.slowUntil and GetTime() < rs.slowUntil then return end

        local retry = tryFn()
        if retry == nil then
            CancelRetryTask(item)
            return
        end
        if retry == false then
            Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.REPAIRING, itemName))
            CancelRetryTask(item)
            ThePlayer:PushEvent("ec_fuel_added", { item = item })
            return
        end
        if retry == "sent" then
            rs.wasInterrupted = false
            rs.waitStart = nil
            if not rs.saidRepairing then
                rs.saidRepairing = true
                Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.REPAIRING, itemName))
            end
            return
        end

        if retry == "wait" then
            rs.wasInterrupted = false
            if not rs.waitStart then
                rs.waitStart = GetTime()
                rs.attempt = rs.attempt + 1
            elseif GetTime() - rs.waitStart >= 5 then
                rs.waitStart = nil
            end
            return
        end

        if not InventoryUtil:IsPlayerFree() then
            if not rs.wasInterrupted then
                rs.wasInterrupted = true
                rs.waitStart = nil
                Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_REPAIR_ITEM.INTERRUPTED, itemName))
            end
            return
        end

        rs.wasInterrupted = false
        if not rs.waitStart then
            rs.waitStart = GetTime()
            rs.attempt = rs.attempt + 1
        elseif GetTime() - rs.waitStart >= 5 then
            rs.waitStart = nil
        end
    end)
    item:ListenForEvent("onremove", CancelRetryTask)
end

-- ==========================================
-- 公共 API
-- ==========================================

local Autorepair = {}

function Autorepair:Refuel(classified)
    local item = classified.entity:GetParent()
    if not item then return end
    RegisterRetryTask(item, function() return RefuelStrategy(item) end)
end

function Autorepair:Repair(classified)
    local item = classified.entity:GetParent()
    if not item then return end
    RegisterRetryTask(item, function() return RepairStrategy(item) end)
end

function Autorepair:Feed(classified)
    local item = classified.entity:GetParent()
    if not item then return end
    RegisterRetryTask(item, function() return FeedStrategy(item) end)
end

-- 全局库存物品维护入口：非装备物品在 percentuseddirty 时由此发起维护
function Autorepair:OnInventoryDirty(classified)
    local player = ThePlayer
    if not (player and player.components.itemtracker) then return end
    if classified._ec_tracked then return end
    local item = classified.entity:GetParent()
    if not item then return end
    if not (item.replica.inventoryitem and item.replica.inventoryitem:IsGrandOwner(player)) then return end
    local percent = ItemUtil:GetPercentUsed(item)
    if (ItemUtil:IsLightSource(item) or item:HasTag("fueldepleted") or ItemUtil:IsFuelable(item))
        and percent <= ItemUtil:GetFiniteUses(item) then
        self:Refuel(classified)
    end
    if ItemUtil:IsRepairable(item) and percent <= ItemUtil:GetMaintenanceThreshold(item) then
        self:Repair(classified)
    end
    if ItemUtil:IsFeedable(item) and percent <= ItemUtil:GetMaintenanceThreshold(item) then
        self:Feed(classified)
    end
end

-- 该物品是否刚发出维护 RPC、仍在等服务端同步
-- 供 itemtracker 的 AutoUnequipPeriodicTask 判断：此时耐久尚未刷新，不应据此决策
-- （原为 itemtracker 直接读本模块的私有 FuelCooldownTimers 表）
-- @return: 布尔值
function Autorepair:IsMaintenancePending(item)
    return GetTime() - (FuelCooldownTimers[item] or 0) < FUEL_SYNC_WINDOW
end

return Autorepair