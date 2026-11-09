local InventoryUtil = require "util/inventoryutil"
local WorldUtil = require "util/worldutil"
local ConfigUtil = require "util/configutil"

local TransformationUnEquips = {}

local function Equip(inst)
    if inst.weremode:value() == 0 then
        inst:DoTaskInTime(FRAMES * 23, function()
            for _, transformItem in ipairs(TransformationUnEquips) do
                ConfigUtil:AutoEquip("WOODIE_REGEAR", transformItem)
            end
            TransformationUnEquips = {}
        end)
    end
end

local function UnEquip()
    if not InventoryUtil:IsBusyClassified() then
        local equips = {}
        for _, item in pairs(InventoryUtil:GetEquips()) do
            if not item:HasTag("backpack") then
                equips[#equips + 1] = item
            end
        end
        for i = #equips, 1, -1 do
            if InventoryUtil:HasFreeSlot() then
                InventoryUtil:Unequip(equips[i])
                TransformationUnEquips[#TransformationUnEquips + 1] = equips[i]
            end
        end
    end
end

local function Init()
    if not ThePlayer or not ThePlayer:HasTag("werehuman") then
        return
    end

    local InventoryReplica = InventoryUtil:GetInventory()

    if not InventoryReplica then
        return
    end

    local OldUseItemFromInvTile = InventoryReplica.UseItemFromInvTile
    InventoryReplica.UseItemFromInvTile = function(self, item)
        if item and item:HasTag("wereitem") then
            UnEquip()
        end

        OldUseItemFromInvTile(self, item)
    end

    if WorldUtil:IsForestWorld() then
        if SkillTreeUtil:IsSkillActivated("woodie_allegiance_lunar") then
            return
        end

        WorldUtil:OnPhaseChanged(function(inst, phase)
            if WorldUtil:IsFullMoon() and phase == "dusk" then
                local timeUntilPhase = inst.net.components.clock:GetTimeUntilPhase("night")
                ThePlayer:DoTaskInTime(timeUntilPhase - FRAMES, function()
                    if WorldUtil:IsFullMoon() then
                        UnEquip()
                    end
                end)
            end
        end)
    end

    ThePlayer:ListenForEvent("weremodedirty", function(inst)
        Equip(inst)
    end)
end

return Init