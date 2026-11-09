-- 物品追踪器组件 - 管理MOD中的自动物品追踪和装备管理功能
-- 提供武器自动重装备、护甲自动切换、自动卸下等智能功能
-- 职责边界：本组件负责"何时触发"（追踪器挂载、库存扫描、容器感知、监听管理、UI 刷新）；
-- "怎么维护"（补燃料/修复/喂食的策略、RPC 确认、失败重试）在 Auto/autorepair.lua。

-- 导入依赖模块
local InventoryUtil = require "util/inventoryutil"
local ItemUtil      = require "util/itemutil"
local PlayerUtil    = require "util/playerutil"
local WorldUtil     = require "util/worldutil"
local Say           = require "util/say"
local InventoryEventService = require "util/inventoryeventservice"
local Autorepair    = require("Auto/autorepair")

-- ==========================================
-- 配置参数
-- ==========================================

local AutoEquipEnum =
{
    BEST = 2,
    SAME = 1,
}

local AUTO_RE_EQUIP_WEAPON = AutoEquipEnum.BEST

-- ==========================================
-- 追踪器系统
-- ==========================================

local Trackers         = {}
local TrackerFunctions = {}

-- ==========================================
-- 辅助函数
-- ==========================================

local function GetItemFromCategory(category)
    local ac = PlayerUtil:GetComponent("actioncontroller")
    return ac and ac:GetItemFromCategory(category)
end

-- ==========================================
-- 武器/护甲自动重装备
-- ==========================================

local function AutoReEquip(item)
    if not item then return end

    if AUTO_RE_EQUIP_WEAPON == AutoEquipEnum.BEST and ItemUtil:IsMeleeWeapon(item) then
        item = GetItemFromCategory("WEAPONS")
        InventoryUtil:Equip(item)
    else
        local bestItem = nil
        local bestUsed = -1
        for _, invItem in pairs(InventoryUtil:GetPlayerInventory(true, nil, true)) do
            if invItem.prefab == item.prefab then
                local used = ItemUtil:GetPercentUsed(invItem)
                if used > bestUsed then
                    bestUsed = used
                    bestItem = invItem
                end
            end
        end
        if bestItem then
            InventoryUtil:Equip(bestItem)
        end
    end
end

local function AutoReEquipArmor(item)
    if InventoryUtil:Has(item.prefab, 1) then return end
    item = GetItemFromCategory("ARMOUR")
    if item then
        item:DoTaskInTime(FRAMES * 10, function()
            InventoryUtil:Equip(item)
        end)
    end
end

-- ==========================================
-- 自动卸下
-- ==========================================

local AutoUnequipTasks = {}
local UNEQUIP_DELAY = FRAMES * 10

local function CancelAutoUnequip(item, silent)
    local t = AutoUnequipTasks[item]
    if not t then return end
    t.task:Cancel()
    if t.onremove then
        item:RemoveEventCallback("onremove", t.onremove)
    end
    AutoUnequipTasks[item] = nil
    if not silent then Say(string.format(t.message, item.name)) end
end

local function AutoUnequipPeriodicTask(item, eslot)
    if ItemUtil:GetPercentUsed(item) > ItemUtil:GetFiniteUses(item) then
        CancelAutoUnequip(item, true)
        return
    end

    -- 刚发出维护 RPC，等服务端同步耐久再判断
    if Autorepair:IsMaintenancePending(item) then return end

    if InventoryUtil:GetEquippedItem(eslot) ~= item then
        CancelAutoUnequip(item)
        return
    end

    local t = AutoUnequipTasks[item]
    if not t then return end
    if GetTime() - t.start > UNEQUIP_DELAY then
        CancelAutoUnequip(item)
        return
    end

    if not InventoryUtil:IsPlayerFree() then return end

    local activeItem = InventoryUtil:GetActiveItem()
    if activeItem then
        if activeItem ~= item then
            if InventoryUtil:HasFreeSlot() then
                InventoryUtil:Unequip(item)
                CancelAutoUnequip(item)
            else
                t.message = MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_UNEQUIP_ITEM.DROP
                InventoryUtil:ReturnActiveItem()
            end
        end
    else
        if not InventoryUtil:HasFreeSlot() then
            InventoryUtil:TakeActiveItemFromEquipSlot(eslot)
        else
            InventoryUtil:Unequip(item)
        end
        CancelAutoUnequip(item)
    end
end

local function StartAutoUnequipTask(item)
    if not AutoUnequipTasks[item] then
        local t =
        {
            start   = GetTime(),
            message = MOD_EQUIPMENT_CONTROL.STRINGS.AUTO_UNEQUIP_ITEM.UNEQUIP,
        }
        t.task = item:DoPeriodicTask(1, AutoUnequipPeriodicTask, 0, ItemUtil:GetEquipSlot(item))
        t.onremove = function() CancelAutoUnequip(item, true) end
        item:ListenForEvent("onremove", t.onremove)
        AutoUnequipTasks[item] = t
    end
end

local function AutoUnEquip(item)
    item = item.entity:GetParent()
    if not item or not ItemUtil:ShouldAutoUnequip(item) then return end
    StartAutoUnequipTask(item)
end

-- ==========================================
-- 骨头盔甲自动切换
-- ==========================================

local function AutoSwitchSkeletonArmor(item)
    item = item.entity:GetParent()
    if not item then return end

    item.LAST_USED = GetTime()

    local armors = {}
    for _, invItem in pairs(InventoryUtil:GetPlayerInventory(true, nil, true)) do
        if invItem.prefab == item.prefab and not invItem:HasTag("fueldepleted") then
            armors[#armors + 1] = invItem
        end
    end

    local function GetDelta(armor)
        return GetTime() - (armor.LAST_USED or 0)
    end

    local bestArmor = nil
    for _, armor in pairs(armors) do
        if armor.LAST_USED then
            if not bestArmor or (GetDelta(armor) > GetDelta(bestArmor)) then
                bestArmor = armor
            end
        else
            bestArmor = armor
            break
        end
    end

    if bestArmor then
        InventoryUtil:Equip(bestArmor)
    end
end

-- ==========================================
-- 刷新按钮
-- ==========================================

local function RefreshButtons(item)
    local buttons = ThePlayer and ThePlayer.HUD and ThePlayer.HUD.controls.inv.buttons
    if buttons then buttons:Refresh(item) end
end

-- ==========================================
-- 维护触发：库存扫描 / 非装备物品监听管理 / 容器感知
-- ==========================================
-- 从 Auto/autorepair 迁回：这些是"何时扫描、何时挂监听"的追踪职责。
-- 维护动作本身（发 RPC / 确认 / 重试）仍由 Autorepair:Refuel/Repair/Feed 执行。

-- 遍历玩家当前可见的全部物品（主库存 + 背包/溢出容器 + 已开容器 + 装备）
-- 参数含义（对齐迁移前的逐段手写循环，勿随意改动）：
--   noActiveItem=true  —— 排除手持物品。主物品栏 GetItems 本就不含手持物品
--   includeContainers=true —— 含"已打开的箱子/冰箱/切斯特"内容，兑现容器感知的语义
-- 背包即溢出容器（InventoryUtil:GetBackpack == GetOverflowContainer），
-- 由 GetBackpackItems 覆盖，故原先额外的 GetOverflowContainer 遍历是冗余的
local function ForEachInventoryItem(fn)
    for _, item in pairs(InventoryUtil:GetPlayerInventory(true, true, true)) do
        if item ~= nil and item.replica ~= nil and item.replica.inventoryitem ~= nil then
            fn(item, item.replica.inventoryitem.classified)
        end
    end
end

-- 非装备物品 percentuseddirty 监听管理
local function SetupNonTrackedListener(classified)
    if not classified._ec_non_tracked_listener then
        -- 保存回调引用，TeardownNonTrackedListener 需要传入同一个函数才能解绑
        local fn = function()
            Autorepair:OnInventoryDirty(classified)
        end
        classified._ec_non_tracked_listener = fn
        classified:ListenForEvent("percentuseddirty", fn)
    end
end

local function TeardownNonTrackedListener(classified)
    local fn = classified._ec_non_tracked_listener
    if fn then
        classified._ec_non_tracked_listener = nil
        classified:RemoveEventCallback("percentuseddirty", fn)
    end
end

-- 检查给定物品是否需要维护（不检查背包/容器内容）
local function ItemNeedsMaintenance(item)
    if not item or not item:IsValid() then return false end
    local profile = ItemUtil:GetMaintenanceProfile(item)
    if profile.kind == "none" then return false end
    local percent = ItemUtil:GetPercentUsed(item)
    if profile.canRefuel and percent <= ItemUtil:GetFiniteUses(item) then
        return true
    end
    if profile.canRepair and percent <= ItemUtil:GetMaintenanceThreshold(item) then
        return true
    end
    if profile.canFeed and percent <= ItemUtil:GetMaintenanceThreshold(item) then
        return true
    end
    return false
end

-- 容器打开时：对已追踪装备和库存内物品触发维护
local function OnContainerOpened()
    if not ThePlayer or not ThePlayer.components.itemtracker then return end
    local IT = ThePlayer.components.itemtracker

    -- 已追踪的装备（正穿在身上的）
    if IT.GetMaintenanceCandidates then
        for _, item in ipairs(IT:GetMaintenanceCandidates()) do
            if ItemNeedsMaintenance(item) then
                local classified = item.replica and item.replica.inventoryitem
                    and item.replica.inventoryitem.classified
                if classified then
                    local profile = ItemUtil:GetMaintenanceProfile(item)
                    if profile.canRefuel then Autorepair:Refuel(classified) end
                    if profile.canRepair then Autorepair:Repair(classified) end
                    if profile.canFeed then Autorepair:Feed(classified) end
                end
            end
        end
    end

    -- 背包/主物品栏中尚未被追踪的非装备物品
    ForEachInventoryItem(function(item, classified)
        if classified and not classified._ec_tracked
            and ItemUtil:IsMaintenanceRelated(item) then
            Autorepair:OnInventoryDirty(classified)
        end
    end)
end

-- 容器打开时的维护触发由 ItemTracker 构造函数内注册
-- （不可用 AddSimPostInit：本文件在 playeractivated 时才随 AddComponent 载入，
--   而 ModManager:SimPostInit 早已执行完毕，那时注册的回调再也不会被调用）

-- ==========================================
-- 追踪器谓词（薄封装，供 AddTracker 触发条件匹配）
-- ==========================================

local function IsHambat(item) return item.prefab == "hambat" end
local function IsArmor(item) return ItemUtil:IsArmor(item) end
local function IsWeapon(item) return item:HasTag("weapon") end
local function IsBoneArmor(item) return item.prefab == "armorskeleton" end
local function IsFuelable(item) return ItemUtil:IsFuelable(item) end
local function IsRepairable(item) return ItemUtil:IsRepairable(item) end
local function IsFeedable(item) return ItemUtil:IsFeedable(item) end

-- ==========================================
-- 追踪器系统（增删/挂载）
-- ==========================================

local function AddTracker(triggerFn, event, eventFn, classified, init)
    TrackerFunctions[#TrackerFunctions + 1] =
    {
        trigger    = triggerFn,
        event      = event,
        eventFn    = eventFn,
        classified = classified,
        init       = init,
    }
end

local function DetachTrackers(eslot)
    if Trackers[eslot] then
        for i = 1, #Trackers[eslot] do
            local location = Trackers[eslot][i].eventLocation
            location:RemoveEventCallback(
                Trackers[eslot][i].tracker.event,
                Trackers[eslot][i].tracker.eventFn
            )
            location._ec_tracked = nil
            Trackers[eslot][i] = nil
        end
    end
end

local function AttachTrackers(item, eslot)
    if not item.replica.equippable then return end
    eslot = eslot or item.replica.equippable:EquipSlot()

    if Trackers[eslot] then
        DetachTrackers(eslot)
    else
        Trackers[eslot] = {}
    end

    for i = 1, #TrackerFunctions do
        if TrackerFunctions[i].trigger(item) then
            local location = TrackerFunctions[i].classified
                and item.replica.inventoryitem.classified or item

            location:ListenForEvent(
                TrackerFunctions[i].event,
                TrackerFunctions[i].eventFn
            )
            location._ec_tracked = true

            Trackers[eslot][#Trackers[eslot] + 1] =
            {
                item          = item,
                eventLocation = location,
                tracker       = TrackerFunctions[i],
            }

            if TrackerFunctions[i].init then
                TrackerFunctions[i].init(location)
            end
        end
    end
end

-- ==========================================
-- 背包 Hook
-- ==========================================

local HookedBackpack = {}
local BackpackEvents = { "itemlose" }

local function HookBackpack(item)
    if item:HasTag("backpack") and item.replica.equippable then
        for _, event in pairs(BackpackEvents) do
            item:ListenForEvent(event, RefreshButtons)
        end
        local eslot = item.replica.equippable:EquipSlot()
        HookedBackpack[eslot] = item
    end
end

local function UnhookBackpack(eslot)
    if HookedBackpack[eslot] then
        for _, event in pairs(BackpackEvents) do
            HookedBackpack[eslot]:RemoveEventCallback(event, RefreshButtons)
        end
        HookedBackpack[eslot] = nil
    end
end

-- ==========================================
-- 装备/卸下 任务队列
-- ==========================================

local RunOnEquip   = { AttachTrackers }
local RunOnUnequip = { DetachTrackers }

RunOnEquip[#RunOnEquip + 1]   = HookBackpack
RunOnUnequip[#RunOnUnequip + 1] = UnhookBackpack

if WorldUtil:IsMasterSim() then
    BackpackEvents[#BackpackEvents + 1] = "itemget"
    RunOnEquip[#RunOnEquip + 1]         = RefreshButtons
    RunOnUnequip[#RunOnUnequip + 1]     = RefreshButtons
end

-- ==========================================
-- 世界停用清理
-- ==========================================

local function OnDeactivateWorld()
    for eslot in pairs(Trackers) do
        DetachTrackers(eslot)
    end
end

-- ==========================================
-- ItemTracker 组件
-- ==========================================

local ItemTracker = Class(function(self, inst)
    self.inst = inst

    InventoryEventService:On(InventoryEventService.EVENT.EQUIPPED, function(data)
        for _, fn in pairs(RunOnEquip) do
            fn(data.item, data.eslot)
        end
        if data and data.item and data.item.replica and data.item.replica.inventoryitem then
            local classified = data.item.replica.inventoryitem.classified
            if classified and ItemUtil:IsMaintenanceRelated(data.item) then
                Autorepair:OnInventoryDirty(classified)
            end
        end
    end, self.inst)

    InventoryEventService:On(InventoryEventService.EVENT.UNEQUIPPED, function(data)
        for _, fn in pairs(RunOnUnequip) do
            fn(data.eslot)
        end
    end, self.inst)

    -- 新物品进入库存：检查已追踪装备修复 + 非装备物品燃料/修补
    InventoryEventService:On(InventoryEventService.EVENT.ITEM_ADDED, function(data)
        for _, trackers in pairs(Trackers) do
            for _, tracker in ipairs(trackers) do
                if IsRepairable(tracker.item) then
                    Autorepair:Repair(tracker.eventLocation)
                end
                if IsFeedable(tracker.item) then
                    Autorepair:Feed(tracker.eventLocation)
                end
            end
        end
        if data and data.item and data.item.replica and data.item.replica.inventoryitem then
            local classified = data.item.replica.inventoryitem.classified
            if classified and ItemUtil:IsMaintenanceRelated(data.item) then
                Autorepair:OnInventoryDirty(classified)
                SetupNonTrackedListener(classified)
            end
        end
    end, self.inst)

    -- 物品移出库存时清理 percentuseddirty 监听
    InventoryEventService:On(InventoryEventService.EVENT.ITEM_REMOVED, function(data)
        if data and data.item and data.item.replica and data.item.replica.inventoryitem then
            local classified = data.item.replica.inventoryitem.classified
            if classified then
                TeardownNonTrackedListener(classified)
            end
        end
    end, self.inst)

    -- 打开容器时：对已追踪装备和库存/容器内物品触发维护
    InventoryEventService:On(InventoryEventService.EVENT.CONTAINER_OPENED, function()
        OnContainerOpened()
    end, self.inst)

    -- 幽灵模式变化
    self.inst.player_classified:ListenForEvent("isghostmodedirty", function()
        for _, eslot in pairs(Trackers) do
            for _, fn in pairs(RunOnUnequip) do
                fn(eslot)
            end
        end
    end)

    self.inst:ListenForEvent("deactivateworld", OnDeactivateWorld, TheWorld)

    -- -- 追踪器注册
    AddTracker(IsWeapon, "onremove", AutoReEquip)
    AddTracker(IsArmor, "onremove", AutoReEquipArmor)

    -- 自动添加燃料
    AddTracker(IsFuelable, "percentuseddirty",
        function(c) Autorepair:Refuel(c) end, true,
        function(c) Autorepair:Refuel(c) end)

    -- 自动修复（修复后若耐久归零，按钮需重画以反映损坏状态）
    AddTracker(IsRepairable, "percentuseddirty",
        function(c)
            Autorepair:Repair(c)
            if c.percentused and c.percentused:value() <= 0 then
                local item = c.entity and c.entity:GetParent()
                if item then RefreshButtons(item) end
            end
        end, true,
        function(c) Autorepair:Repair(c) end)

    -- 自动喂食修复
    AddTracker(IsFeedable, "percentuseddirty",
        function(c) Autorepair:Feed(c) end, true,
        function(c) Autorepair:Feed(c) end)

    -- 自动卸下可补充燃料/可修复/喂食修复装备
    AddTracker(function(item) return IsFuelable(item) or IsRepairable(item) or IsFeedable(item) end,
        "percentuseddirty", AutoUnEquip, true, AutoUnEquip)

    AddTracker(IsBoneArmor, "percentuseddirty", AutoSwitchSkeletonArmor, true)

    -- 燃料耗尽时重画按钮（原 Autorepair:OnFuelDepleted，纯 UI 关注点，迁回此处）
    AddTracker(IsFuelable, "percentuseddirty",
        function(c)
            local item = c.entity and c.entity:GetParent()
            if item and item:HasTag("fueldepleted") then RefreshButtons(item) end
        end, true)
    AddTracker(IsHambat, "perishdirty", RefreshButtons, true)

    -- 初始化：对已装备物品执行装备函数
    for _, item in pairs(InventoryUtil:GetEquips()) do
        for _, fn in pairs(RunOnEquip) do
            fn(item)
        end
    end

    -- 启动时扫描全量库存，挂载非装备物品燃料/修补监听
    self.inst:DoTaskInTime(1, function()
        if not InventoryUtil:GetInventory() then return end
        ForEachInventoryItem(function(item, classified)
            if classified and ItemUtil:IsMaintenanceRelated(item) then
                Autorepair:OnInventoryDirty(classified)
                SetupNonTrackedListener(classified)
            end
        end)
    end)
end)

-- ==========================================
-- 外部接口
-- ==========================================

-- autoweapon 等模块的谓词引用
ItemTracker.IsFuelable = IsFuelable
ItemTracker.IsRepairable = IsRepairable
ItemTracker.IsFeedable = IsFeedable

-- 供模块内的容器感知回调使用：获取当前所有有维护需求的已追踪物品
function ItemTracker:GetMaintenanceCandidates()
    local candidates = {}
    for _, trackers in pairs(Trackers) do
        for _, t in ipairs(trackers) do
            if t.item and t.item:IsValid()
                and (IsFuelable(t.item) or IsRepairable(t.item) or IsFeedable(t.item)) then
                candidates[#candidates + 1] = t.item
            end
        end
    end
    return candidates
end

return ItemTracker