local Widget = require("widgets/widget")
local Image = require("widgets/image")
local ItemButtonTile = require "widgets/itembuttontile"
local InventoryUtil = require "util/inventoryutil"

local HUD_ATLAS = "images/hud.xml"

local ItemButton = Class(Widget, function(self, bgim, owner, category)
    Widget._ctor(self, "ItemButton")
    self.owner = owner

    self.bgimage = self:AddChild(Image(HUD_ATLAS, bgim))
    self.category = category
    self.tile = nil
    self.item = nil

    self.highlight_scale = 1.2
    self.base_scale = 1

    self:SetTile(ItemButtonTile(self.category))

    end)

function ItemButton:SetDefaultPosition()
    self.default_position = self:GetPosition()
end

function ItemButton:GetCategory()
    return self.category
end

function ItemButton:SetAutoEquipEnabled(enabled)
    if enabled then
        self.bgimage:SetTint(0.3, 1, 0.3, 1)  -- 绿色 = 开启
    else
        self.bgimage:SetTint(1, 0.3, 0.3, 1)  -- 红色 = 关闭
    end
end

function ItemButton:Highlight()
    if not self.big then
        self:ScaleTo(self.base_scale, self.highlight_scale, .125)
        self.big = true
    end
end

function ItemButton:DeHighlight()
    if self.big then
        if not self.highlight then
            self:ScaleTo(self.highlight_scale, self.base_scale, .25)
        end
        self.big = false
    end
end

function ItemButton:OnGainFocus()
    self:Highlight()
end

function ItemButton:OnLoseFocus()
    self:DeHighlight()
    if self.default_position then
        self:SetPosition(self.default_position)
    end
end

function ItemButton:OnMouseButton(button, down)
    if not self.owner or not self.owner:IsValid() then
        return
    end
    if not self.owner.components.actioncontroller then
        return
    end

    if button == MOUSEBUTTON_LEFT then
        if down then
            self:SetPosition(self:GetPosition() + Vector3(0,-3,0))
            local activeItem = InventoryUtil:GetActiveItem()
            if activeItem then
                local ac = self.owner.components.actioncontroller
                local tempSet = ac._temp_items[self.category]
                -- 手持物品已在临时集合中 → 移除；否则 → 添加
                if tempSet and tempSet[activeItem.prefab] then
                    ac:RemoveTempItem(self.category, activeItem)
                else
                    ac:AddTempItem(self.category, activeItem)
                end
            elseif self.item then
                self.owner.components.actioncontroller:UseItem(self.item)
            end
        elseif self.default_position then
            self:SetPosition(self.default_position)
        end
    elseif button == MOUSEBUTTON_RIGHT and down then
        if self.item then
            self:CycleItem()
        end
    elseif button == MOUSEBUTTON_MIDDLE and down then
        local state = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[self.category]
        if state ~= nil then
            MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[self.category] = not state
            if self.owner then
                self.owner:PushEvent("refreshinventory")
                -- 通知各自动模块（如 autocloth）开关已变更，需立即重新评估
                self.owner:PushEvent("autoequeiptoggled", { category = self.category })
            end
        end
    end
end

function ItemButton:SetTile(tile)
    if self.tile ~= tile then
        if self.tile ~= nil then
            self.tile = self.tile:Kill()
        end
        if tile ~= nil then
            self.tile = self:AddChild(tile)
        end
    end
end

function ItemButton:SetItem(item)
    if self.tile ~= nil then
        self.item = item
        self.tile:SetImage(item)
    end
end

function ItemButton:CycleItem()
    local ac = self.owner.components.actioncontroller
    -- 强制实时库存与优先级结果：避免 Refresh 窗口内命中旧缓存（_cached_inventory / _priority_cache），
    -- 导致刚做好的第二份料理不在候选列表、右键切不过去（原版无此缓存故一直正常）。
    ac._cached_inventory = nil
    ac._priority_cache = {}
    local items = ac:GetItemsFromCategory(self.category)
    if not items or #items <= 1 then
        return
    end

    -- 基于已保存的偏好（真正的选择）定位下一个，而非 self.item（按钮上当前显示/已装备的武器）；
    -- 否则右键连续切换（中间未触发战斗）时 self.item 停留在旧武器，导致只在相邻两把间来回切。
    local currentPrefab = ac:GetUserPrefab(self.category) or (self.item and self.item.prefab)
    local nextItem = items[1]

    for i, item in ipairs(items) do
        if item.prefab == currentPrefab then
            nextItem = items[i % #items + 1]
            break
        end
    end

    self:SetItem(nextItem)
    ac:SavePreferredItem(self.category, nextItem.prefab)
end

return ItemButton