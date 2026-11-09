local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local Say = require "util/say"
local ConfigUtil = require "util/configutil"

local UpdateRateInFrames = 10

-- ==========================================
-- Helpers
-- ==========================================

-- ItemUtil 的分类函数是冒号定义，直接传 ItemUtil.IsAmulet 会恒返回 false。
-- 同时 DetectEquipSlot 以 tostring(predicate) 做缓存 key，必须是稳定闭包，
-- 传临时匿名函数会让缓存永远不命中且不断膨胀。
local function IsAmulet(item)
    return ItemUtil:IsAmulet(item)
end

-- 护符槽是否可用：通过物品自身查目标槽，不依赖硬编码槽位名
local function IsAmuletSlotAvailable()
    local slot = InventoryUtil:DetectEquipSlot(IsAmulet)
    if not slot then
        -- 背包中无护符 → 以原版 BODY 为准
        slot = EQUIPSLOTS.BODY
    end
    -- 多格装备栏适配：背包与目标护符槽“同槽”（原版 BODY）时才保留背包、不覆盖；
    -- 背包独立到别的槽（如 BACK）则可共存，正常装备护符。统一用 ItemUtil:BackpackConflictWithSlot。
    if ItemUtil:BackpackConflictWithSlot(slot) then
        return false
    end
    local equipped = InventoryUtil:GetEquippedItemBySlot(slot)
    if not equipped then
        return true
    end
    -- 已装备护符 → 护符之间可互相切换
    if ItemUtil:IsAmulet(equipped) then
        return true
    end
    -- 让步：不覆盖 autohelm(护甲) / autocloth(衣物)（背包已由上面的通用判定处理）
    return false
end

-- ==========================================
-- GREEN: Top-level DoRecipeClick hook
-- 参考创意工坊 3627945193，在模组加载时立即 hook，
-- 不依赖 ThePlayer，通过 owner 参数检测装备
-- ==========================================
require "widgets/widgetutil"

local function IsGreenEquippedOnOwner(owner)
    if not owner then return false end
    -- 客户端：走工具层读取装备（官方 GetEquips 客户端分支即 classified:GetEquips）
    for _, item in pairs(InventoryUtil:GetEquips()) do
        if item.prefab == "greenamulet" then
            return true
        end
    end
    -- 服务端/本地：遍历所有装备槽，不依赖硬编码槽位名
    if owner.components and owner.components.inventory then
        for _, item in pairs(owner.components.inventory.equipslots) do
            if item and item.prefab == "greenamulet" then
                return true
            end
        end
    end
    return false
end

local function GetRecipeDisplayName(recipe)
    if not recipe or not recipe.name then
        return "???"
    end
    local names = GLOBAL.STRINGS.NAMES
    local key = string.upper(recipe.name)
    if names and names[key] then
        return names[key]
    end
    return recipe.name
end

local _DoRecipeClick = GLOBAL.DoRecipeClick
GLOBAL.DoRecipeClick = function(owner, recipe, skin, ...)
    if ThePlayer and TheInput
       and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.AMULET
       and IsGreenEquippedOnOwner(owner)
       and not TheInput:IsControlPressed(CONTROL_FORCE_STACK) then
        local name = GetRecipeDisplayName(recipe)
        Say("按住CTRL制作" .. name)
        return true
    end
    return _DoRecipeClick(owner, recipe, skin, ...)
end

-- ==========================================
-- BLUE: Overheating -> equip chilly amulet
-- ==========================================
local function ProcessBlue()
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.AMULET then
        return
    end
    if not PlayerUtil:IsOverheating() then
        return
    end
    if not IsAmuletSlotAvailable() then
        return
    end
    if InventoryUtil:HasEquipped(function(item)
        return ItemUtil:IsAmulet(item) and ItemUtil:HasComponent(item, "insulator")
    end) then
        return
    end

    local blue = InventoryUtil:FindItemAnywhere(function(item)
        return ItemUtil:IsAmulet(item) and ItemUtil:HasComponent(item, "insulator")
    end)
    -- 排除已损坏/无法维持的护符：否则装备失败或装后被卸下会反复触发切换（复用 ItemUtil 通用判定）
    if blue and (ItemUtil:IsBroken(blue) or ItemUtil:ShouldAutoUnequip(blue)) then
        blue = nil
    end
    if blue then
        ConfigUtil:AutoEquip("AMULET", blue, true)
    end
end

-- ==========================================
-- YELLOW: Movement -> equip magiluminescence
-- ==========================================
local function ShouldEquipYellow()
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.AMULET then
        return false
    end
    if not IsAmuletSlotAvailable() then
        return false
    end
    if InventoryUtil:HasEquipped(function(item)
        return ItemUtil:IsAmulet(item) and ItemUtil:GetWalkspeedMult(item) > 1
    end) then
        return false
    end

    local yellow = InventoryUtil:FindItemAnywhere(function(item)
        return ItemUtil:IsAmulet(item) and ItemUtil:GetWalkspeedMult(item) > 1
    end)
    return yellow ~= nil
        and not (ItemUtil:IsBroken(yellow) or ItemUtil:ShouldAutoUnequip(yellow))
end

local function EquipYellow()
    local yellow = InventoryUtil:FindItemAnywhere(function(item)
        return ItemUtil:IsAmulet(item) and ItemUtil:GetWalkspeedMult(item) > 1
    end)
    -- 排除已损坏/无法维持的护符：复用 ItemUtil 通用判定，避免没耐久仍不断切换
    if yellow and not (ItemUtil:IsBroken(yellow) or ItemUtil:ShouldAutoUnequip(yellow)) then
        ConfigUtil:AutoEquip("AMULET", yellow, true)
    end
end

-- ==========================================
-- INIT (blue + yellow, need ThePlayer)
-- ==========================================
local _init_done = false

local function Init()
    if _init_done then return end
    _init_done = true

    if not ThePlayer then
        _init_done = false
        return
    end

    local PlayerController = ThePlayer.components.playercontroller
    if not PlayerController then
        return
    end

    -- 补燃料成功后立即重新装备（事件驱动，无需轮询）
    ThePlayer:ListenForEvent("ec_fuel_added", function(inst, data)
        if data and data.item and ItemUtil:IsAmulet(data.item) then
            ItemUtil:TryReEquipFuelable(data.item)
        end
    end)

    -- Overheating periodic check (blue amulet)
    StartThread(function()
        while ThePlayer do
            ProcessBlue()
            Sleep(UpdateRateInFrames * FRAMES)
        end
    end, "AutoAmuletBlueThread")

    -- Movement hook (yellow amulet)
    local _OnControl = PlayerController.OnControl
    function PlayerController:OnControl(control, down)
        if down then
            if control == CONTROL_MOVE_UP or control == CONTROL_MOVE_DOWN
                or control == CONTROL_MOVE_LEFT or control == CONTROL_MOVE_RIGHT then
                if ShouldEquipYellow() then
                    EquipYellow()
                end
            end
        end
        return _OnControl(self, control, down)
    end
end

-- 等待世界初始化 → 监听玩家激活 → ThePlayer 可用的时机
AddSimPostInit(function()
    if TheWorld then
        TheWorld:ListenForEvent("playeractivated", function(_, player)
            if player == ThePlayer then
                Init()
            end
        end, TheWorld)
    end
end)