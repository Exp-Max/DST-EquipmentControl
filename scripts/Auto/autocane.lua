local InventoryUtil = require "util/inventoryutil"
local ActionUtil = require "util/actionutil"
local PlayerUtil = require "util/playerutil"
local ConfigUtil = require "util/configutil"

local function CanWalkTo(action, doer, bufferedaction)
    if not action or action.instant then
        return false
    end

    local maxAllowedDistance = 3.0
    local actionDistance = action.distance or 0

    local extraDistance = action.extra_arrive_dist or 0
    if type(extraDistance) == "function" then
        extraDistance = 0
    end

    return (actionDistance + extraDistance) <= maxAllowedDistance
end

local function IsCompatibleLeftClickAction()
    local pc = ThePlayer and ThePlayer.components.playercontroller
    if not pc or not pc.GetLeftMouseAction then
        return true
    end

    local buffaction = pc:GetLeftMouseAction()
    if not buffaction then
        return true
    end

    return CanWalkTo(buffaction.action, ThePlayer, buffaction)
end

local function ValidateCaneClick()
    return IsCompatibleLeftClickAction()
        and TheInput:GetHUDEntityUnderMouse() == nil
end

local function ShouldEquipCane()
    local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
    if not equipped then
        return true
    end

    local controller = PlayerUtil:GetComponent("actioncontroller")
    if not controller then
        return true
    end

    -- 只对手持物品与快捷键手杖栏物品是否一致负责，不一致就切
    local presetCane = controller:GetItemFromCategory("CANE")
    return presetCane and equipped.prefab ~= presetCane.prefab
end

local function CanEquipCane()
    -- 骑乘时游戏本体 locomotor 使用坐骑速度(ServerRunSpeed/ClientRunSpeed 返回
    -- mount.components.locomotor.runspeed)，玩家的 walkspeedmult 不起作用，
    -- 手杖加速完全无效，因此不做切换。
    if PlayerUtil:IsRiding() then
        return false
    end

    return MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CANE
        and not InventoryUtil:IsHeavyLifting()
        and ShouldEquipCane()
end

local function EquipCane()
    local ac = PlayerUtil:GetComponent("actioncontroller")
    if not ac then
        return
    end

    local cane = ac:GetItemFromCategory("CANE")

    if cane then
        ConfigUtil:AutoEquip("CANE", cane, true)
    end
end
-- 走A相关
local function OnEquipItem(inst, data)
    if data and data.type and string.find(data.type, 'walk') and CanEquipCane() then
        EquipCane()
    end
end

local function Init()
    local PlayerController = ThePlayer and ThePlayer.components.playercontroller

    if not PlayerController then
        return
    end

    -- 监听行走时的EquipItem事件，避免重复创建监听器
    ThePlayer:ListenForEvent("EquipItem", OnEquipItem)

    -- 钩子 OnControl：按键按下时触发，非每帧调用
    local _OnControl = PlayerController.OnControl
    function PlayerController:OnControl(control, down)
        if down then
            if control == CONTROL_PRIMARY then
                local lmb = self:GetLeftMouseAction()
                if ActionUtil:IsEmptyClickAction(lmb) and CanEquipCane() then
                    EquipCane()
                end
            elseif control == CONTROL_MOVE_UP or control == CONTROL_MOVE_DOWN
                or control == CONTROL_MOVE_LEFT or control == CONTROL_MOVE_RIGHT then
                if CanEquipCane() then
                    EquipCane()
                end
            end
        end
        return _OnControl(self, control, down)
    end
end

return Init