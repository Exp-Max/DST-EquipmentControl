local Inventory_Replica = require "components/inventory_replica"
local InventoryUtil = require "util/inventoryutil"
local PriorityUtil = require "util/priorityutil"
local SortUtil = require "util/sortutil"
local Say = require("util/say")
local KeybindService = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE

local Settings =
{
    "CONTAINER_SORT",
    "OVERRIDE_SLOT1_SORT",
}

local Sorter = Class(function(self, inst)
    self.inst = inst

    -- Thread
    self.sortingthread = nil

    -- Debug
    self.debug = false
    self.debug_level = 2
    self.debug_item_priority = false

    -- Memory
    self.blacklist = {}

    -- Sorter
    self.sorting = false
    self.offsetslots = 0

    -- Network
    self.timeout = 15
    -- 单次尝试内已含"连发 + 回退两段式"两条路径，故重试次数从 5 降到 3（失败时更少空等）
    self.attemps = 3
    -- 鼠标残留清理的等待上限（tick）；独立于 timeout，避免清理本身拖慢整理
    self.cursor_timeout = 8
    -- 排序开始时玩家手上原有的物品（清理时跳过，不抢玩家的东西）
    self._initial_active = nil
end)

function Sorter:DebugPrint(level, str, ...)
    if self.debug then
        if level and level >= self.debug_level then
            print(string.format(string.rep("-", 14) .. "| " .. str, ...))
        elseif level == nil then
            print(string.format("[Sorter] " .. str, ...))
        end
    end
end

local function SetSettings()
    for i = 1, #Settings do
        Settings[Settings[i]] = GetModConfigData(Settings[i], MOD_EQUIPMENT_CONTROL.MODNAME)
        Settings[i] = nil
    end
end
SetSettings()

function Sorter:GetSetting(setting)
    return Settings[setting]
end

function Sorter:ChangeContainer()
    if Settings.CONTAINER_SORT ~= 1 then
        Settings.CONTAINER_SORT = Settings.CONTAINER_SORT - 1
    else
        Settings.CONTAINER_SORT = 3
    end
end

function Sorter:AwaitNetworkSlot(item, slot)
    local timeout = 0

    if SortUtil:ForceItemIntoSlot(item, slot) then
        repeat
            if not SortUtil:MatchGUID(InventoryUtil:GetActiveItem(), item) then
                return true
            end
            Sleep(0)
            timeout = timeout + 1
        until timeout > self.timeout
    end

    return false
end

function Sorter:AwaitNetworkActiveItem(item)
    local timeout = 0

    if SortUtil:ForceItemIntoActiveItem(item) then
        repeat
            if SortUtil:MatchGUID(InventoryUtil:GetActiveItem(), item) then
                return true
            end
            Sleep(0)
            timeout = timeout + 1
        until timeout > self.timeout
    end

    return false
end

local function AwaitNetworkActiveItemChange(self)
    local timeout = 0

    repeat
        if InventoryUtil:GetActiveItem() == nil then
            return true
        end
        Sleep(0)
        timeout = timeout + 1
    until timeout > self.timeout

    return false
end

function Sorter:StackableToActiveItem(item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local activeItem = InventoryUtil:GetActiveItem()
        if activeItem and activeItem.prefab == item.prefab and not SortUtil:MatchGUID(item, activeItem) then
            if not InventoryUtil:HasFreeSlot() then
                SendRPCToServer(RPC.ReturnActiveItem)
                if not AwaitNetworkActiveItemChange(self) then
                    return false
                end
            else
                local slot = SortUtil:FindFreeInventorySlot(activeItem)
                if not self:AwaitNetworkSlot(activeItem, slot) then
                    return false
                end
            end
        end

        return self:AwaitNetworkActiveItem(item)
    end

    return false
end

function Sorter:AwaitNetworkStacking(item, slot)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local numSlots = InventoryUtil:GetNumSlots()
        local container = slot > numSlots and SortUtil:GetBackpackEnt() or nil
        local itemInSlot = SortUtil:IsSlotOccupied(slot)
        if container then
            slot = slot % numSlots
        end
        local slotStackSize = SortUtil:GetStackSize(itemInSlot)
        local handStackSize = SortUtil:GetStackSize(InventoryUtil:GetActiveItem())
        local stackDelta = SortUtil:GetFreeStackSize(itemInSlot) - handStackSize

        SendRPCToServer(RPC.AddAllOfActiveItemToSlot, slot, container)
        local timeout = 0
        repeat
            if InventoryUtil:GetActiveItem() == nil
            or stackDelta < 0 and slotStackSize ~= SortUtil:GetStackSize(itemInSlot)
            then
                return true
            end
            Sleep(0)
            timeout = timeout + 1
        until timeout > self.timeout
    end

    return false
end

local function GetItemStacks(t, prefab)
    local itemStacks = {}

    for i = 1, #t do
        if t[i].item.prefab == prefab then
            itemStacks[#itemStacks + 1] = t[i].item
        end
    end

    return itemStacks
end

local function GetStackableSlot(item, slot)
    local totalSlots = SortUtil:GetTotalInventorySlots()
    local itemInSlot

    for i = slot, totalSlots do
        itemInSlot = SortUtil:IsSlotOccupied(i)
        if not itemInSlot or itemInSlot.prefab ~= item.prefab or SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            return i
        end
    end

    return nil
end

local function AddStack(self, item, slot)
    if not self:StackableToActiveItem(item) then
        return false
    end

    local totalSlots = SortUtil:GetTotalInventorySlots()
    for i = slot, totalSlots do
        local itemInSlot = SortUtil:IsSlotOccupied(i)
        if not itemInSlot or itemInSlot.prefab ~= item.prefab then
            return self:AwaitNetworkSlot(item, i)
        elseif SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            self:AwaitNetworkStacking(item, i)
            local activeItem = InventoryUtil:GetActiveItem()
            if activeItem == nil then
                return true
            elseif activeItem.prefab ~= item.prefab then
                return false
            end
        end
    end

    return false
end

local function ShouldSortItem(item, slot)
    local totalSlots = SortUtil:GetTotalInventorySlots()
    local itemInSlot

    for i = slot, totalSlots do
        itemInSlot = SortUtil:IsSlotOccupied(i)
        if SortUtil:MatchGUID(itemInSlot, item) then
            return false
        elseif not itemInSlot
        or itemInSlot.prefab ~= item.prefab
        or SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            return true
        end
    end

    return false
end

function Sorter:DoStacking(t, item, slot)
    local itemStacks = GetItemStacks(t, item.prefab)
    local stackableSlot = slot

    for _, item in pairs(itemStacks) do
        if ShouldSortItem(item, slot) then
            stackableSlot = GetStackableSlot(item, stackableSlot)
            if not stackableSlot then
                return false
            end
            if not AddStack(self, item, stackableSlot) then
                return false
            end
        end
    end

    return true
end

function Sorter:MoveStackable(t, item, slot)
    return self:DoStacking(t, item, slot)
end

local function IsMovePossible(item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local activeItem = InventoryUtil:GetActiveItem()
        if SortUtil:MatchGUID(item, activeItem) then
            return true
        end
        for _, invItem in pairs(SortUtil:GetPlayerInventory()) do
            if SortUtil:MatchGUID(item, invItem) then
                return true
            end
        end
    end

    return false
end

function Sorter:Move(item, slot)
    return self:AwaitNetworkActiveItem(item) and self:AwaitNetworkSlot(item, slot)
end

function Sorter:MoveToSlot(t, item, slot)
    local succes = false

    if SortUtil:IsStackable(item) then
        self:DebugPrint(nil, "Stacking of %s started at slot [%s]", item.prefab, slot)
        for i = 1, self.attemps do
            if IsMovePossible(item) then
                if self:MoveStackable(t, item, slot) then
                    self.blacklist[item.prefab] = true
                    succes = true
                    break
                end
                self:DebugPrint(2, "%s unsuccesful attempt.",  i, item.prefab)
                Sleep(FRAMES)
            end
        end
    else
        self:DebugPrint(nil, "Regular move %s to slot [%s]", item.prefab, slot)
        if slot ~= SortUtil:GetSlotFromItem(item) then
            for i = 1, self.attemps do
                if IsMovePossible(item) then
                    if self:Move(item, slot) then
                        succes = true
                        break
                    end
                    self:DebugPrint(2, "%s unsuccesful attempt.",  i, item.prefab)
                Sleep(FRAMES)
                end
            end
        else
            self:DebugPrint(1, "Skipping... %s.", item.prefab)
            succes = true
        end
    end

    return succes
end

local function DoPreStacking(t, item)
    local stackTab = {}
    local currentStack = 0
    local maxStack = SortUtil:GetStackMaxSize(item)
    table.insert(stackTab, item)
    for _, prioObject in pairs(t) do
        if prioObject.item.prefab == item.prefab then
            local stackSize = SortUtil:GetStackSize(prioObject.item)
            currentStack = currentStack + stackSize
            if currentStack > maxStack then
                currentStack = currentStack - maxStack
                table.insert(stackTab, prioObject.item)
            end
        end
    end
    return stackTab
end

local function DoPreSorting(t)
    local newInventory = {}
    local shadowBlacklist = {}

    for _, prioObject in pairs(t) do
        if not shadowBlacklist[prioObject.item.prefab] then
            if SortUtil:IsStackable(prioObject.item) then
                shadowBlacklist[prioObject.item.prefab] = true
                for _, v in pairs(DoPreStacking(t, prioObject.item)) do
                    table.insert(newInventory, v)
                end
            else
                table.insert(newInventory, prioObject.item)
            end
        end
    end

    return newInventory
end

local function GetPrioritizedSorts(self, t)
    local totalInvSlots = SortUtil:GetInventorySlots()
    local replacers = {}

    for i, v in pairs(t) do
        if i > totalInvSlots and PriorityUtil:CanOnlyGoInPocket(v) then
            table.insert(replacers, v)
        end
    end

    if Settings.OVERRIDE_SLOT1_SORT then
        for _, v in pairs(t) do
            if Settings.OVERRIDE_SLOT1_SORT == v.prefab then
               table.insert(replacers, v)
            end
        end
    end

    return replacers
end

local function IsNotReplacer(t, item)
    for i = 1, #t do
        if SortUtil:MatchGUID(t[i], item) then
            return false
        end
    end
    return true
end

local function StripPrioritizedSorts(t, replacers)
    local correctedInv = {}

    for x = 1, #t do
        if IsNotReplacer(replacers, t[x]) then
            table.insert(correctedInv, t[x])
        end
    end

    return correctedInv
end

local function GetSortedInventory(self, t)
    local sortedInventory = DoPreSorting(t)
    local prioritizedSorts = GetPrioritizedSorts(self, sortedInventory)

    if #prioritizedSorts > 0 then
        sortedInventory = StripPrioritizedSorts(sortedInventory, prioritizedSorts)
        for i = 1, #prioritizedSorts do
            table.insert(sortedInventory, 1, prioritizedSorts[i])
        end
    end

    return sortedInventory
end

function Sorter:Sort(t)
    local sortedInventory = GetSortedInventory(self, t or {})

    for i = 1, #sortedInventory do
        if PriorityUtil:CanOnlyGoInPocket(sortedInventory[i]) then
            self:MoveToSlot(t, sortedInventory[i], i)
        end
    end

    for i = 1, #sortedInventory do
        local item = sortedInventory[i]
        if not self.blacklist[item.prefab] then
            if not self:MoveToSlot(t, item, i + self.offsetslots) then
                self:DebugPrint(2, "Sorting has failed at slot [%s] sorting item %s.",  i, item.prefab)
                break
            end
        end
    end

    self:Stop()
end

-- 瞬发整理：把背包内可装备物 swap 到主物品栏（与物品栏内非装备物互换），
-- 只留原材料/杂物在背包。借鉴 Exp_Max 瞬发整理——不依赖空槽、连续发 RPC 不等待。
-- 用于：整理前归位背包装备（"以后也都这么整理"），以及自动护甲顶背包前保护。
function Sorter:InstantSortEquippable()
    local inv = InventoryUtil:GetInventory()
    local backpack = InventoryUtil:GetBackpack()
    if not inv or not backpack then
        return
    end

    -- 前置：手持必须为空。SwapContainerSlots 的第 1 步（Take）在手持非空时是 no-op，
    -- 后面两步却照发，会把玩家手上的东西换进物品栏 → 物品错位。这里直接放弃本轮归位。
    if InventoryUtil:GetActiveItem() ~= nil then
        self:DebugPrint(nil, "InstantSortEquippable skipped: cursor occupied.")
        return
    end

    local backpackEnt = backpack.inst
    local invItems = InventoryUtil:GetInventoryItems()
    local bpItems = InventoryUtil:GetBackpackItems()
    local numSlots = InventoryUtil:GetNumSlots()
    local rpc = 0

    for bslot, bitem in pairs(bpItems) do
        if PriorityUtil:IsEquippable(bitem) then
            -- 找一个物品栏内的非装备槽，与之 swap（不依赖空槽）
            for islot = 1, numSlots do
                local iitem = invItems[islot]
                if iitem and not PriorityUtil:IsEquippable(iitem) then
                    -- 背包内可装备物 ↔ 物品栏非装备物 瞬发换位（复用通用容器间 swap，dstContainer=nil 即主物品栏）
                    if not InventoryUtil:SwapContainerSlots(backpackEnt, bslot, nil, islot) then
                        -- 中途被占（玩家自己拿起了东西）：停止发后续 RPC；
                        -- 这里不做光标清理——手上的东西是玩家自己的，不能替他放回。
                        self:DebugPrint(nil, "InstantSortEquippable aborted: cursor occupied.")
                        return
                    end
                    rpc = rpc + 3
                    if rpc > 18 then Sleep(0); rpc = 0 end
                    invItems[islot] = bitem
                    bpItems[bslot] = iitem
                    break
                end
            end
        end
    end

    -- 三连是"连发不等待"的，任一步被服务端拒绝都会留下光标残留 → 补一次短确认，
    -- 否则紧接着的 Sort 每一步 Take 都会因手持非空而 no-op，整轮整理全废。
    self:ClearCursor(3)
end

-- 鼠标残留清理：把"排序遗留"在鼠标上的物品放回库存。
-- 直接发官方 RPC.ReturnActiveItem，不走副本方法——排序期间 DisableUserInput() 会把
-- inventory.ReturnActiveItem 换成空函数，且它不区分是不是玩家自己的东西。
-- 排序开始时玩家自己拿着的那个（_initial_active）不清理，避免抢走玩家手上的物品。
-- 协程内会等服务端同步确认；非协程上下文（无 Sleep）只用延时兜底。
function Sorter:ClearCursor(settle_ticks)
    if InventoryUtil:GetActiveItem() == nil and settle_ticks == nil then return end
    if SortUtil:MatchGUID(InventoryUtil:GetActiveItem(), self._initial_active) then
        return
    end

    local inst = self.inst or ThePlayer
    if coroutine.running() == nil or inst == nil then
        -- 非协程（禁止 Sleep）或没有可用实体：延时兜底，只发一次归位 RPC
        if inst ~= nil then
            inst:DoTaskInTime(0.15, function()
                local active = InventoryUtil:GetActiveItem()
                if active ~= nil and not SortUtil:MatchGUID(active, self._initial_active) then
                    SendRPCToServer(RPC.ReturnActiveItem)
                end
            end)
        end
        return
    end

    -- 刚连发完 RPC 时客户端副本状态滞后，立即判断会误以为"没有残留"；
    -- 调用方可传 settle_ticks 先等几拍让服务端结果同步过来。
    if settle_ticks ~= nil then
        local settle = 0
        while settle < settle_ticks do
            Sleep(0)
            settle = settle + 1
        end
    end

    local timeout = 0
    while InventoryUtil:GetActiveItem() ~= nil and timeout < self.cursor_timeout do
        Sleep(0)
        timeout = timeout + 1
    end

    if InventoryUtil:GetActiveItem() ~= nil then
        self:DebugPrint(nil, "Residual cursor item, returning to inventory.")
        SendRPCToServer(RPC.ReturnActiveItem)
        timeout = 0
        while InventoryUtil:GetActiveItem() ~= nil and timeout < self.cursor_timeout do
            Sleep(0)
            timeout = timeout + 1
        end
    end
end

function Sorter:Stop()
    if self.sortingthread then
        if self.sortingthread.SetList then
            self.sortingthread:SetList(nil)
        end
        self.sortingthread = nil
    end
    self.blacklist = {}
    self.offsetslots = 0
    local inventory = InventoryUtil:GetInventory()
    if inventory then
        -- 必须先恢复被 DisableUserInput 屏蔽掉的 ReturnActiveItem，再做残留清理
        inventory.ReturnActiveItem = Inventory_Replica.ReturnActiveItem
    end
    -- 整理是"取到手持 → 放回"的两段式，任何一步超时/被拒都会把物品留在鼠标上：
    -- 收尾统一清理一次，避免玩家手上莫名多一个物品。
    self:ClearCursor()
    self._initial_active = nil
    self._sort_start = nil
    self.sorting = false
    self:DebugPrint(nil, "Sorting stopped.")
end

local function DisableUserInput()
    local inventory = InventoryUtil:GetInventory()
    if inventory then
        inventory.ReturnActiveItem = function() end
    end
end

local function DebugPrintPriorities(self, t)
    if self.debug_item_priority then
        for i = 1, #t do
            print("[Prio] " .. t[i].priority, t[i].item)
        end
    end
end

-- 排序范围：inventory=仅物品栏 / backpack=仅背包 / all=物品栏+背包
-- 不传则沿用 modinfo 的 CONTAINER_SORT 设置（热键兼容）
function Sorter:Start(mode)
    -- 自愈：上一次排序若因异常没走到 Stop()，self.sorting 会一直是 true，
    -- 之后所有整理都被这个判断挡掉，表现就是"点了没反应"。
    if self.sorting and self._sort_start ~= nil and (GetTime() - self._sort_start) > 30 then
        self:DebugPrint(nil, "Previous sorting was stuck, force stop.")
        self:Stop()
    end
    if self.sorting then
        return
    end

    self.sorting = true
    self._sort_start = GetTime()
    self:DebugPrint(nil, "Sorting of inventory started.")
    DisableUserInput()
    -- 记录排序开始时玩家手上的物品：收尾清理要跳过它，不抢玩家手里的东西
    self._initial_active = InventoryUtil:GetActiveItem()

    local priorityTable = {}
    local which = mode

    if which == nil then
        -- 沿用设置：3=完整背包 / 2=物品栏 / 1=背包
        which = Settings.CONTAINER_SORT == 1 and "backpack"
            or Settings.CONTAINER_SORT == 2 and "inventory"
            or "all"
    end

    if which == "backpack" then
        priorityTable = PriorityUtil:CreatePriorityTable(SortUtil:GetBackpackItems())
        self.offsetslots = self.offsetslots + SortUtil:GetInventorySlots()
    elseif which == "inventory" then
        priorityTable = PriorityUtil:CreatePriorityTable(SortUtil:GetPlayerInventory(true))
    else
        priorityTable = PriorityUtil:CreatePriorityTable(SortUtil:GetPlayerInventory())
    end

    DebugPrintPriorities(self, priorityTable)

    self.sortingthread = self.inst:StartThread(function()
        local ok, err = pcall(function()
            self:InstantSortEquippable()  -- 瞬发归位背包装备到物品栏
            self:Sort(priorityTable)
        end)
        if not ok then
            -- 异常也必须收尾：否则 ReturnActiveItem 会一直被 DisableUserInput 屏蔽
            self:DebugPrint(nil, "Sorting aborted: %s", tostring(err))
            self:Stop()
        end
    end)
end

function Sorter:AwaitNetworkSlotContainer(item, slot, container)
    local timeout = 0

    if SortUtil:ForceItemIntoSlotContainer(item, slot, container) then
        repeat
            if not SortUtil:MatchGUID(InventoryUtil:GetActiveItem(), item) then
                return true
            end
            Sleep(0)
            timeout = timeout + 1
        until timeout > self.timeout
    end

    return false
end

function Sorter:AwaitNetworkActiveItemContainer(item, container)
    local timeout = 0

    if SortUtil:ForceItemIntoActiveItemContainer(item, container) then
        repeat
            if SortUtil:MatchGUID(InventoryUtil:GetActiveItem(), item) then
                return true
            end
            Sleep(0)
            timeout = timeout + 1
        until timeout > self.timeout
    end

    return false
end

function Sorter:MoveItemToSlotContainer(item, slot, container)
    return self:AwaitNetworkActiveItemContainer(item, container) and self:AwaitNetworkSlotContainer(item, slot, container)
end

-- 容器内精确换位（三连连发 + 只等一次）
-- 客户端发出的 RPC 可靠有序、服务端按序执行，所以"取 src → 放/换 dst → 原 dst 物回 src"
-- 三连可以一次发完，只需等一次确认；相比原来的 取(等)→放(等) 省掉一整趟网络往返。
-- 另一个收益：三连末尾手持必定归零。原实现在目标槽被占时走 SwapActiveItemWithSlot，
-- 会把目标槽原物留在鼠标上，那正是"整理完手上莫名多一个物品"的来源。
-- @return: ok, src_slot（src_slot 用于调用方增量维护槽位快照）
function Sorter:SwapWithinContainer(item, slot, container)
    if container == nil then return false end

    local src_slot = SortUtil:GetSlotFromItemContainer(item, container)
    if src_slot == nil then return false end
    if src_slot == slot then return true, src_slot end

    local occupied = SortUtil:IsSlotOccupiedContainer(slot, container)
    if not InventoryUtil:SwapContainerSlots(container, src_slot, container, slot, occupied and "swap" or "put") then
        -- 手持被占：继续发会把玩家手上的东西换进箱子，直接放弃本步
        return false
    end

    local timeout = 0
    repeat
        if SortUtil:MatchGUID(SortUtil:IsSlotOccupiedContainer(slot, container), item)
            and InventoryUtil:GetActiveItem() == nil
        then
            return true, src_slot
        end
        Sleep(0)
        timeout = timeout + 1
    until timeout > self.timeout

    return false
end

local function IsMovePossibleContainer(item, container)
    if SortUtil:MatchGUID(item, InventoryUtil:GetActiveItem()) then
        return true
    end

    for _, containerItem in pairs(SortUtil:GetItemsFromContainer(container)) do
        if SortUtil:MatchGUID(item, containerItem) then
            return true
        end
    end

    return false
end

function Sorter:StackableToActiveItemContainer(item, container)
    local activeItem = InventoryUtil:GetActiveItem()

    if activeItem and activeItem.prefab == item.prefab and not SortUtil:MatchGUID(item, activeItem) then
        if SortUtil:IsFullContainer(container) then
            SendRPCToServer(RPC.ReturnActiveItem)
            if not AwaitNetworkActiveItemChange(self) then
                return false
            end
        else
            local slot = SortUtil:FindFreeContainerSlot(activeItem, container)
            if not self:AwaitNetworkSlotContainer(activeItem, slot, container) then
                return false
            end
        end
    end

    return self:AwaitNetworkActiveItemContainer(item, container)
end

function Sorter:AwaitNetworkStackingContainer(item, slot, container)
    local itemInSlot = SortUtil:IsSlotOccupiedContainer(slot, container)
    local slotStackSize = SortUtil:GetStackSize(itemInSlot)
    local handStackSize = SortUtil:GetStackSize(InventoryUtil:GetActiveItem())
    local stackDelta = SortUtil:GetFreeStackSize(itemInSlot) - handStackSize

    SendRPCToServer(RPC.AddAllOfActiveItemToSlot, slot, container)
    local timeout = 0
    repeat
        if InventoryUtil:GetActiveItem() == nil
        or stackDelta < 0 and slotStackSize ~= SortUtil:GetStackSize(itemInSlot)
        then
            return true
        end
        Sleep(0)
        timeout = timeout + 1
    until timeout > self.timeout

    return false
end


local function AddStackContainer(self, item, slot, container)
    if not self:StackableToActiveItemContainer(item, container) then
        return false
    end

    local totalSlots = SortUtil:GetSlotsFromContainer(container)
    for i = slot, totalSlots do
        local itemInSlot = SortUtil:IsSlotOccupiedContainer(i, container)
        if not itemInSlot or itemInSlot.prefab ~= item.prefab then
            return self:AwaitNetworkSlotContainer(item, i, container)
        elseif SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            self:AwaitNetworkStackingContainer(item, i, container)
            local activeItem = InventoryUtil:GetActiveItem()
            if activeItem == nil then
                return true
            elseif activeItem.prefab ~= item.prefab then
                return false
            end
        end
    end

    return false
end

local function ShouldSortItemContainer(item, slot, container)
    local totalSlots = SortUtil:GetSlotsFromContainer(container)
    local itemInSlot

    for i = slot, totalSlots do
        itemInSlot = SortUtil:IsSlotOccupiedContainer(i, container)
        if SortUtil:MatchGUID(itemInSlot, item) then
            return false
        elseif not itemInSlot
        or itemInSlot.prefab ~= item.prefab
        or SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            return true
        end
    end

    return false
end

local function GetStackableSlotContainer(item, slot, container)
    local totalSlots = SortUtil:GetSlotsFromContainer(container)
    local itemInSlot

    for i = slot, totalSlots do
        itemInSlot = SortUtil:IsSlotOccupiedContainer(i, container)
        if not itemInSlot or itemInSlot.prefab ~= item.prefab or SortUtil:GetFreeStackSize(itemInSlot) > 0 then
            return i
        end
    end

    return nil
end

function Sorter:DoStackingContainer(t, item, slot, container)
    local itemStacks = GetItemStacks(t, item.prefab)
    local stackableSlot = slot

    for _, item in pairs(itemStacks) do
        if ShouldSortItemContainer(item, slot, container) then
            stackableSlot = GetStackableSlotContainer(item, stackableSlot, container)
            if not stackableSlot then
                return false
            end
            if not AddStackContainer(self, item, stackableSlot, container) then
                return false
            end
        end
    end

    return true
end

function Sorter:MoveStackableContainer(t, item, slot, container)
    return self:DoStackingContainer(t, item, slot, container)
end

function Sorter:MoveToSlotContainer(t, item, slot, container)
    local succes = false

    if SortUtil:IsStackable(item) then
        self:DebugPrint(nil, "Stacking of %s started at slot [%s]", item.prefab, slot)
        for i = 1, self.attemps do
	        if IsMovePossibleContainer(item, container) then
	            if self:MoveStackableContainer(t, item, slot, container) then
	            	self.blacklist[item.prefab] = true
	                succes = true
	                break
	            end
	        end
	    end
    else
        self:DebugPrint(nil, "Regular move %s to slot [%s]", item.prefab, slot)
        if slot ~= SortUtil:GetSlotFromItemContainer(item, container) then
        	for i = 1, self.attemps do
	            if IsMovePossibleContainer(item, container) then
	                -- 先走连发路径（一次等待）；失败再回退原来的两段式（各等一次）
	                if self:SwapWithinContainer(item, slot, container) then
	                    succes = true
	                    break
	                end
	                if self:MoveItemToSlotContainer(item, slot, container) then
	                    succes = true
	                    break
	                end
	            end
	        end
        else
            self:DebugPrint(1, "Skipping... %s.", item.prefab)
            succes = true
        end
    end

    return succes
end

local function GetSortedContainer(self, t)
    return DoPreSorting(t)
end

function Sorter:SortChest(t, container)
    -- 空容器/异常数据会传进 nil，pairs(nil) 直接崩，这里兜底成空表
    local sortedContainer = GetSortedContainer(self, t or {})

    -- 槽位快照：slot_of[guid]=当前槽、guid_at[槽]=guid。
    -- 原实现每处理一个物品都要全容器遍历来算"当前在第几槽"（O(n²)），箱子越大越慢；
    -- 这里建一次表，"是否已在目标槽"变成 O(1)，换位后增量更新即可。
    local slot_of, guid_at = {}, {}
    for slot, it in pairs(SortUtil:GetItemsFromContainer(container)) do
        if it ~= nil and it.GUID ~= nil then
            slot_of[it.GUID] = slot
            guid_at[slot] = it.GUID
        end
    end

    for i = 1, #sortedContainer do
        local item = sortedContainer[i]
        if not self.blacklist[item.prefab] then
            if slot_of[item.GUID] == i then
                self:DebugPrint(1, "Skipping... %s.", item.prefab)
            else
                -- 优先连发路径（一次网络往返），失败再回退原来的两段式
                local ok, src_slot = self:SwapWithinContainer(item, i, container)
                if ok then
                    if src_slot ~= nil and src_slot ~= i then
                        local victim = guid_at[i]
                        slot_of[item.GUID] = i
                        guid_at[i] = item.GUID
                        if victim ~= nil then
                            -- 目标槽原物被换到 src 槽
                            slot_of[victim] = src_slot
                            guid_at[src_slot] = victim
                        else
                            -- put 模式：src 槽已空
                            guid_at[src_slot] = nil
                        end
                    end
                elseif not self:MoveToSlotContainer(t, item, i, container) then
                    self:DebugPrint(2, "Sorting of [%s] has failed.", container.prefab)
                    break
                else
                    slot_of[item.GUID] = i
                end
            end
        end
    end

    self:Stop()
end

-- 建筑容器（箱子/冰箱/锅等世界容器）：没有 inventoryitem 副本 == 不可拾取 == 不是玩家携带的容器。
-- 背包/糖果袋/打包裹都有 inventoryitem 副本，会被排除——那些由"排序背包/物品栏/全部"负责。
local function IsStructureContainer(ent)
    if ent == nil or not ent:IsValid() or ent.replica == nil then
        return false
    end
    if ent.replica.inventoryitem ~= nil then
        return false
    end
    if ent:HasTag("backpack") then
        return false
    end
    return ent.replica.container ~= nil
end

function Sorter:StartChest()
    -- 自愈：同 Start()，避免上一次异常留下的 sorting=true 让整理永久失效
    if self.sorting and self._sort_start ~= nil and (GetTime() - self._sort_start) > 30 then
        self:DebugPrint(nil, "Previous chest sorting was stuck, force stop.")
        self:Stop()
    end
    if self.sorting then
        return
    end

    -- 先找容器再置 sorting：旧实现先置位再找，找不到时既不启动线程也不复位，
    -- self.sorting 会永久为 true —— 这正是"点了箱子排序没反应"的根因。
    local target = nil
    for container in pairs(SortUtil:GetOpenContainers()) do
        if IsStructureContainer(container) then
            target = container
            break
        end
    end

    if target == nil then
        self:DebugPrint(nil, "There is no open structure container to sort.")
        Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORT_OPEN_CONTAINER)
        return
    end

    self.sorting = true
    self._sort_start = GetTime()
    self:DebugPrint(nil, "Sorting of containers started.")

    DisableUserInput()
    -- 记录开始时玩家手上的物品：收尾清理要跳过它，不抢玩家手里的东西
    self._initial_active = InventoryUtil:GetActiveItem()

    local container = target
    self:DebugPrint(nil, "Now sorting %s.", container.prefab)
    local priorityTable = PriorityUtil:CreatePriorityTable(
                            SortUtil:GetItemsFromContainer(container)
                          )
    DebugPrintPriorities(self, priorityTable)
    self.sortingthread = self.inst:StartThread(function()
        local ok, err = pcall(function()
            self:SortChest(priorityTable, container)
        end)
        if not ok then
            -- 异常也必须收尾：否则 ReturnActiveItem 会一直被 DisableUserInput 屏蔽
            self:DebugPrint(nil, "Chest sorting aborted: %s", tostring(err))
            self:Stop()
        end
    end)
end

local Containers =
{
    "backpack",
    "only inventory",
    "inventory",
}

local function GetSorter()
    return ThePlayer ~= nil and ThePlayer.components ~= nil and ThePlayer.components.sorter or nil
end

-- 排序：HUD"排序"分类下的四个子按钮与热键共用同一批处理器
-- 不传 mode 时（旧热键）沿用 modinfo 的 CONTAINER_SORT 档位
KeybindService:AddKey("SORT_INVENTORY", function()
    local sorter = GetSorter()
    if not sorter then return end
    Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORTING_INVENTORY)
    sorter:Start("inventory")
end)

KeybindService:AddKey("SORT_BACKPACK", function()
    local sorter = GetSorter()
    if not sorter then return end
    Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORTING_BACKPACK)
    sorter:Start("backpack")
end)

KeybindService:AddKey("SORT_ALL", function()
    local sorter = GetSorter()
    if not sorter then return end
    Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORTING_ALL)
    sorter:Start("all")
end)

KeybindService:AddKey("SORT_CHEST", function()
    local sorter = GetSorter()
    if not sorter then return end
    Say(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORTING_CHEST)
    sorter:StartChest()
end)

KeybindService:AddKey("TOGGLE_SORTING_CONTAINER", function()
    ThePlayer.components.sorter:ChangeContainer()
    Say(
        string.format(
            MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.SORTING_CONTAINER,
            Containers[ThePlayer.components.sorter:GetSetting("CONTAINER_SORT")]
        )
    )
end)

-- 暴露当前排序容器，供 confighud 的"切换排序容器"按钮显示当前档位
MOD_EQUIPMENT_CONTROL.GetSortingContainer = function()
    if not (ThePlayer and ThePlayer.components and ThePlayer.components.sorter) then return nil end
    local idx = ThePlayer.components.sorter:GetSetting("CONTAINER_SORT")
    return ({ [1] = "背包", [2] = "仅背包", [3] = "物品栏" })[idx] or Containers[idx]
end

return Sorter