local Widget = require "widgets/widget"
local Image = require "widgets/image"
local ItemButton = require "widgets/itembutton"
local InventoryEventService = require "util/inventoryeventservice"

local ContainerWidget = require "widgets/containerwidget"
if ContainerWidget then
    local OldContainerWidgetClose = ContainerWidget.Close
    function ContainerWidget:Close(...)
        if self.isopen then
            OldContainerWidgetClose(self, ...)
            if ThePlayer then
                ThePlayer:PushEvent("container_closed")
            end
        end
    end
end

local CATEGORY_PRIORITY = {

    "CANE",       -- 手杖
    "LIGHT",      -- 光源
    "WEAPONS",    -- 武器
    "ARMORHAT",   -- 头部护甲
    "ARMORBODY",  -- 身体护甲

    "AXE",        -- 斧头
    "PICKAXE",    -- 镐
    "SHOVEL",     -- 铲
    "HAMMER",     -- 锤
    "BUGNET",     -- 捕虫网

    -- "WATERINGCAN",-- 浇水壶
    -- "HOE",        -- 园艺锄
    -- "PITCHFORK",  -- 干草叉
    "CLOTHINGHAT",-- 头部衣物
    "CLOTHINGBODY",-- 身体衣物
    "FOOD",       -- 食物
    "STAFF",      -- 法杖
    "AMULET",     -- 护符
    -- "HEALING",    -- 治疗
    -- "BACKPACK",   -- 背包
}

local function IsPlatformHopping(inst)
    return (inst
        and inst.sg ~= nil
        and inst.sg:HasStateTag("jumping"))
        or (inst
        and inst.AnimState
        and (inst.AnimState:IsCurrentAnimation("boat_jump_pre")
            or inst.AnimState:IsCurrentAnimation("boat_jump_loop")))
end

local Buttons = Class(Widget, function(self, owner, inventorybar)
    Widget._ctor(self, "Buttons")

    self.owner = owner
    self.buttons = {}
    self._refreshtask = nil

    local function DebouncedRefresh(buttons)
        if buttons._refreshtask == nil then
            buttons._refreshtask = buttons.inst:DoTaskInTime(0, function()
                buttons._refreshtask = nil
                buttons:Refresh()
            end)
        end
    end

    local E = InventoryEventService.EVENT
    local refresh = function() DebouncedRefresh(self) end
    for _, evt in ipairs({ E.ITEM_ADDED, E.ITEM_REMOVED, E.ACTIVE_CHANGED, E.INVENTORY_REFRESH, E.CONTAINER_OPENED }) do
        InventoryEventService:On(evt, refresh, self.owner)
    end

    self.inst:ListenForEvent("playeractivated", function()
        self.inst:DoTaskInTime(0, function() self:Refresh() end)
    end, self.owner)

    -- 以下监听同样走防抖：一次 Refresh 要跑 15 个分类的全量扫描，
    -- 上下船/关容器/湿度变化时直接刷新会在多帧内反复触发
    self.inst:ListenForEvent("got_on_platform", function() DebouncedRefresh(self) end, self.owner)

    self.inst:ListenForEvent("got_off_platform", function()
        self.inst:StartThread(function()
            while IsPlatformHopping(self.owner) do
                Sleep(0)
            end
            if self.owner and self.owner:IsValid() then
                DebouncedRefresh(self)
            end
        end)
    end, self.owner)

    self.inst:ListenForEvent("wetdirty", function() DebouncedRefresh(self) end, TheWorld.net)

    self.inst:ListenForEvent("container_closed", function() DebouncedRefresh(self) end, self.owner)

    self.inventorybar = inventorybar

    self:Build()
    self:UpdateAutoEquipIndicator()
end)

function Buttons:Build()
    local index = 0
    for _, category in ipairs(CATEGORY_PRIORITY) do
        index = index + 1
        self.buttons[index] = self:AddChild(ItemButton("inv_slot_spoiled.tex", self.owner, category))
    end
end

function Buttons:UpdateAutoEquipIndicator()
    for _, button in pairs(self.buttons) do
        local category = button:GetCategory()
        local isGreen = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[category]
        button:SetAutoEquipEnabled(isGreen)
    end
end

function Buttons:Refresh()
    self:UpdateAutoEquipIndicator()
    if self.owner and self.owner.components.actioncontroller then
        self.owner.components.actioncontroller:BeginRefresh()

        for _, button in pairs(self.buttons) do
            local item = self.owner.components.actioncontroller:GetItemFromCategory(button:GetCategory())
            button:SetItem(item)
        end

        self.owner.components.actioncontroller:EndRefresh()
    end
    self:UpdatePositions()
end

function Buttons:UpdatePositions()
    local inventorybar = self.inventorybar
    if not inventorybar then return end

    local slotIdx = 1
    local MAX_SLOTS = 15
    for _, slot in ipairs(inventorybar.inv) do
        if slotIdx <= MAX_SLOTS and self.buttons[slotIdx] then
            local _, sizeY = slot.bgimage:GetSize()
            local slotX = slot:GetPosition().x
            local toprowY = inventorybar.toprow:GetPosition().y
            self.buttons[slotIdx]:SetPosition(slotX, toprowY + (sizeY * 1.5))
            self.buttons[slotIdx]:SetDefaultPosition()
            self.buttons[slotIdx]:Show()
            slotIdx = slotIdx + 1
        end
    end

    for i = slotIdx, #self.buttons do
        self.buttons[i]:Hide()
    end
end

return Buttons