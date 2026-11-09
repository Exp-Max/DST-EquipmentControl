local InventoryUtil = require "util/inventoryutil"

local SortUtil = {}

local function AddToInventoryTable(t, slot, item, overflow)
    t[slot + (overflow or 0)] = item
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetNumSlots + 模组自实现统一槽位编号
function SortUtil:GetInventorySlots()
    local inventory = InventoryUtil:GetInventory()
    return inventory
        and InventoryUtil:GetNumSlots()
        or 0
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetBackpack + 模组自实现统一槽位编号
function SortUtil:GetBackpackItems()
    local inventory = InventoryUtil:GetInventory()
    local items = {}

    if inventory and InventoryUtil:GetBackpack() then
        local overflow = InventoryUtil:GetNumSlots()
        for slot, item in pairs(InventoryUtil:GetBackpackItems()) do
            AddToInventoryTable(items, slot, item, overflow)
        end
    end

    return items
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetInventoryItems + 模组自实现统一槽位编号
function SortUtil:GetPlayerInventory(noBackpack)
    local inventory = InventoryUtil:GetInventory()
    local playerInventory = {}

    if inventory then
        local items = InventoryUtil:GetInventoryItems()
        for slot, item in pairs(items) do
            AddToInventoryTable(playerInventory, slot, item)
        end

        if not noBackpack and InventoryUtil:GetBackpack() then
            local overflow = InventoryUtil:GetNumSlots()
            for slot, item in pairs(InventoryUtil:GetBackpackItems()) do
                AddToInventoryTable(playerInventory, slot, item, overflow)
            end
        end
    end

    return playerInventory
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetNumSlots + 模组自实现统一槽位编号
function SortUtil:FindFreeInventorySlot(item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local invSlots = InventoryUtil:GetNumSlots()
        for i = 1, invSlots do
            if not inventory:GetItemInSlot(i) then
                return i
            end
        end

        local backpack = InventoryUtil:GetBackpack()
        if backpack then
            for i = 1, InventoryUtil:GetSlotCount(backpack) do
                if not backpack:GetItemInSlot(i) then
                    return invSlots + i
                end
            end
        end
    end

    return nil
end

-- 来源：官方：item.replica.stackable 存在性判断
function SortUtil:IsStackable(item)
    return item
        and item.replica.stackable
end

-- 来源：模组自实现：官方实体 GUID 比较
function SortUtil:MatchGUID(a, b)
    return a and b
        and a.GUID == b.GUID
end

local function FindItemInPlayerInventory(self, searchItem)
    local items = self:GetPlayerInventory()

    for _, item in pairs(items) do
        if self:MatchGUID(searchItem, item) then
            return item
        end
    end

    return false
end

local function GetItemInSlot(slot)
    local inventory = InventoryUtil:GetInventory()
    if inventory then
        return inventory:GetItemInSlot(slot)
    end

    local classified = InventoryUtil:GetClassified()
    if classified then
        return classified:GetItemInSlot(slot)
    end

    return nil
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetNumSlots + 模组自实现统一槽位编号
function SortUtil:IsSlotOccupied(slot)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        if slot > InventoryUtil:GetNumSlots() then
            slot = slot - InventoryUtil:GetNumSlots()
            local backpack = InventoryUtil:GetBackpack()
            return backpack and backpack:GetItemInSlot(slot)
        else
            return GetItemInSlot(slot)
        end
    end

    return nil
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetBackpack + 模组自实现统一槽位编号
function SortUtil:GetBackpackEnt()
    local inventory = InventoryUtil:GetInventory()
    return inventory
        and InventoryUtil:GetBackpack()
        and InventoryUtil:GetBackpack().inst
end

local function MoveHandToSlot(self, inventory, slot)
    local container = slot > InventoryUtil:GetNumSlots() and self:GetBackpackEnt() or nil
    local slotOccupied = self:IsSlotOccupied(slot)
    if container then
        slot = slot - InventoryUtil:GetNumSlots()
    end
    local code = slotOccupied and RPC.SwapActiveItemWithSlot
                    or RPC.PutAllOfActiveItemInSlot

    SendRPCToServer(code, slot, container)
end

-- 来源：官方 RPC：SwapActiveItemWithSlot/PutAllOfActiveItemInSlot（经 MoveHandToSlot）+ 模组自实现统一槽位编号
function SortUtil:ForceItemIntoSlot(item, slot)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        if self:MatchGUID(self:IsSlotOccupied(slot), item) then
            return true
        end

        if self:MatchGUID(InventoryUtil:GetActiveItem(), item) then
            MoveHandToSlot(self, inventory, slot)
            return true
        end
    end

    return false
end

local function MoveSlotIntoHand(self, inventory, slot)
    local activeItem = inventory:GetActiveItem()
    local code = activeItem and RPC.SwapActiveItemWithSlot
                    or RPC.TakeActiveItemFromAllOfSlot
    local container = slot > InventoryUtil:GetNumSlots() and self:GetBackpackEnt() or nil
    if container then
        slot = slot - InventoryUtil:GetNumSlots()
    end

    SendRPCToServer(code, slot, container)
end

local function GetCorrespondingSlot(self, item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local items = InventoryUtil:GetInventoryItems()

        for slot, invItem in pairs(items) do
            if self:MatchGUID(invItem, item) then
                return slot
            end
        end

        if InventoryUtil:GetBackpack() then
            local overflow = InventoryUtil:GetNumSlots()

            for slot, backpackItem in pairs(InventoryUtil:GetBackpackItems()) do
                if self:MatchGUID(backpackItem, item) then
                    return slot + overflow
                end
            end
        end
    end
end

-- 来源：官方（经 InventoryUtil 镜像层）：GetInventory,GetNumSlots + 模组自实现统一槽位编号
function SortUtil:GetTotalInventorySlots()
    local inventory = InventoryUtil:GetInventory()
    local numSlots = 0

    if inventory then
        numSlots = numSlots + InventoryUtil:GetNumSlots()

        local backpack = InventoryUtil:GetBackpack()
        if backpack then
            numSlots = numSlots + InventoryUtil:GetSlotCount(backpack)
        end
    end

    return numSlots
end

-- 来源：官方 RPC：TakeActiveItemFromAllOfSlot/SwapActiveItemWithSlot（经 MoveSlotIntoHand）+ 模组自实现统一槽位编号
function SortUtil:ForceItemIntoActiveItem(item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        if self:MatchGUID(InventoryUtil:GetActiveItem(), item) then
            return true
        end

        local inventoryItem = FindItemInPlayerInventory(self, item)
        local slot = GetCorrespondingSlot(self, inventoryItem)

        if inventoryItem then
            MoveSlotIntoHand(self, inventory, slot)
            return true
        end
    end

    return false
end

-- 来源：官方：item.replica.stackable:StackSize()
function SortUtil:GetStackSize(item)
    return self:IsStackable(item)
        and item.replica.stackable:StackSize()
        or 0
end

-- 来源：官方：item.replica.stackable:MaxSize()
function SortUtil:GetStackMaxSize(item)
    return self:IsStackable(item)
        and item.replica.stackable:MaxSize()
        or 0
end

-- 来源：模组自实现：GetStackMaxSize - GetStackSize 派生
function SortUtil:GetFreeStackSize(item)
    return self:GetStackMaxSize(item) - self:GetStackSize(item)
end

-- 来源：模组自实现：遍历统一槽位表，按官方实体 GUID 定位
function SortUtil:GetSlotFromItem(item)
    local inventory = InventoryUtil:GetInventory()

    if inventory then
        local items = self:GetPlayerInventory()
        for i, v in pairs(items) do
            if self:MatchGUID(item, v) then
                return i
            end
        end
    end

    return nil
end

--
-- Container functions are duplicates for now need to redo the sorter to make every function compatible
--

-- 来源：官方：container_replica:GetNumSlots()（经 InventoryUtil:GetSlotCount）+ 模组自实现找空槽
function SortUtil:FindFreeContainerSlot(item, container)
    for slot = 1, self:GetSlotsFromContainer(container) do
        if not self:IsSlotOccupiedContainer(slot, container) then
            return slot
        end
    end

    return nil
end

-- 来源：官方：container_replica:IsFull()（容器专用）
function SortUtil:IsFullContainer(container)
    return container
        and container.replica.container
        and container.replica.container:IsFull()
end

-- 官方：container_replica:GetItems()（容器专用；主物品栏请用 InventoryUtil:GetInventoryItems）
function SortUtil:GetItemsFromContainer(container)
    return container
        and container.replica.container
        and container.replica.container:GetItems()
        or {}
end

-- 官方（经 InventoryUtil 镜像层）：container_replica:GetNumSlots()，0 表示数据不可用
function SortUtil:GetSlotsFromContainer(container)
    return InventoryUtil:GetSlotCount(container)
end

-- 来源：模组自实现：遍历 container_replica:GetItems()，按官方实体 GUID 定位
function SortUtil:GetSlotFromItemContainer(searchItem, container)
    for slot, item in pairs(self:GetItemsFromContainer(container)) do
        if self:MatchGUID(item, searchItem) then
            return slot
        end
    end

    return nil
end

local function FindItemInContainer(self, container, searchItem)
    for slot, item in pairs(self:GetItemsFromContainer(container)) do
        if self:MatchGUID(searchItem, item) then
            return item, slot
        end
    end

    return false
end

local function MoveSlotIntoHandContainer(container, slot)
    local activeItem = InventoryUtil:GetActiveItem()
    local code = activeItem and RPC.SwapActiveItemWithSlot
                    or RPC.TakeActiveItemFromAllOfSlot
    SendRPCToServer(code, slot, container)
end

-- 来源：官方 RPC：TakeActiveItemFromAllOfSlot/SwapActiveItemWithSlot（容器版）+ 模组自实现 GUID 判断
function SortUtil:ForceItemIntoActiveItemContainer(item, container)
    if container and container.replica.container then
        if self:MatchGUID(InventoryUtil:GetActiveItem(), item) then
            return true
        end

        local containerItem, slot = FindItemInContainer(self, container, item)

        if containerItem then
            MoveSlotIntoHandContainer(container, slot)
            return true
        end
    end

    return false
end

-- 来源：官方：container_replica:GetItemInSlot(slot)（容器专用）
function SortUtil:IsSlotOccupiedContainer(slot, container)
    return container
        and container.replica.container
        and container.replica.container:GetItemInSlot(slot)
end

local function MoveHandToSlotContainer(self, slot, container)
    local slotOccupied = self:IsSlotOccupiedContainer(slot, container)
    local code = slotOccupied and RPC.SwapActiveItemWithSlot
                    or RPC.PutAllOfActiveItemInSlot

    SendRPCToServer(code, slot, container)
end

-- 来源：官方 inventory_replica:GetOpenContainers()（保留官方 {[entity]=true} 集合；
--       未改用 InventoryUtil:GetOpenContainers()，后者已过滤背包并返回 replica 数组）
function SortUtil:GetOpenContainers()
    local inventory = InventoryUtil:GetInventory()
    return inventory
        and inventory:GetOpenContainers()
        or {}
end

-- 来源：官方 RPC：PutAllOfActiveItemInSlot/SwapActiveItemWithSlot（容器版）+ 模组自实现 GUID 判断
function SortUtil:ForceItemIntoSlotContainer(item, slot, container)
    if container and container.replica.container then
        if self:MatchGUID(self:IsSlotOccupiedContainer(slot), item) then
            return true
        end

        if self:MatchGUID(InventoryUtil:GetActiveItem(), item) then
            MoveHandToSlotContainer(self, slot, container)
            return true
        end
    end

    return false
end

return SortUtil