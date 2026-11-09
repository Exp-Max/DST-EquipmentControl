local Say = require("util/say")
local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local WorldUtil = require "util/worldutil"

local ConfigUtil = {}

function ConfigUtil:DoToggle(str, bool)
    bool = not bool
    Say(
        string.format(
            MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.TOGGLE_FORMAT,
            str,
            bool and MOD_EQUIPMENT_CONTROL.STRINGS.TOGGLE.ENABLED
            or MOD_EQUIPMENT_CONTROL.STRINGS.TOGGLE.DISABLED
        )
    )
    return bool
end

-- ==========================================
-- 自动装备统一入口
-- ==========================================
-- 安全等级：数字越小越优先，按"不装备的后果"排序
--   1 自动护甲：被 boss 攻击不穿大概率致死
--   2 自动光源：黑暗 5 秒鬼手 100 伤害
--   3 自动衣服：过冷/过热持续扣血、潮湿失温
--   4 自动手杖：仅加速跑图
-- 保命例外：无光环境下头部唯一光源不可被护甲覆盖（黑暗约每 5 秒 100 鬼手伤害），
--   该判定不参与等级比较，由 autohelm 的 CanEquipArmor 用官方 IsInLight() 在无光环境下硬保护。
-- 未列出的分类（武器/工具/护符/快速动作/部署/勋章/伍迪变形还原）按事件需要放行，
-- 只做通用校验，不参与等级仲裁。
local RANK = {
    ARMORHAT     = 1,
    ARMORBODY    = 1,
    LIGHT        = 2,
    CLOTHINGHAT  = 3,
    CLOTHINGBODY = 3,
    CANE         = 4,
}

-- 槽上已有物品归属：只识别持续型高等级装备；
-- 认不出的（武器/工具/勋章/手动装备）视为无主，不阻挡任何自动模块。
local function GetEquippedOwner(item)
    if not item then return nil end
    if ItemUtil:IsArmorHat(item) then return 1, "ARMORHAT" end
    if ItemUtil:IsArmorBody(item) then return 1, "ARMORBODY" end
    if ItemUtil:IsClothingHat(item) then return 3, "CLOTHINGHAT" end
    if ItemUtil:IsClothingBody(item) or item:HasTag("umbrella") then return 3, "CLOTHINGBODY" end
    return nil
end

-- 衣服是否会占手部：过冷/过热的衣物占 HEAD/BODY，不与手杖的 HANDS 冲突；
-- 只有下雨需要雨伞时，衣服才会与手杖抢同一个槽。
local function NeedsRainGear()
    return (WorldUtil:IsRaining() or WorldUtil:IsAcidRaining()) and not WorldUtil:IsLunarhailing()
end

-- 是否有更高等级的条件正在生效。
-- 每条约束都读 AUTO_EQUIP 开关：关掉对应功能，约束自动取消，低级模块不再被挡。
local function IsSuppressed(requester, slot)
    local rank = RANK[requester]
    if not rank then return false end
    local ae = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP

    -- 1) 战斗护甲：护甲开关开着且有威胁时，环境衣物让出"护甲实际占据的槽"给护甲/武器；
    --    多格装备栏下衣物/护甲各占独立槽则不冲突，故按槽位感知（见 InventoryUtil:GetEquippedSlotsOf），无默认兜底。
    if rank == 3 and (ae.ARMORHAT == true or ae.ARMORBODY == true) and PlayerUtil:CheckThreats()
       and InventoryUtil:GetEquippedSlotsOf(function(i) return ItemUtil:IsArmor(i) end)[slot] then
        return true
    end
    -- 2) 自动光源：非白天且该槽当前由光源占据时，衣物/手杖不覆盖（鬼手伤害）。
    --    纯即时判定：autolight 的三态模型会在外部光/天光已保护时卸下自身光源，
    --    所以"槽上还举着光源"本身就意味着当前靠它防鬼手，无需跨模块状态标记。
    --    也不能用 not IsInLight() 反推无光：光源装上后玩家被自己点亮，该条件会立刻失效。
    --    白天直接放行，避免玩家手动举火把时连自动手杖都被一起挡掉。
    --    与约束 1/3 一致，直接用 InventoryUtil 的装备栏检查做槽位感知；
    --    谓词判"是否属于整个 LIGHT 分类"（GetItemsFromCategory 已含临时光源）。
    if rank >= 3 and ae.LIGHT == true and not WorldUtil:IsDay() then
        local ac = PlayerUtil:GetComponent("actioncontroller")
        local lights = ac and ac:GetItemsFromCategory("LIGHT")
        if InventoryUtil:GetEquippedSlotsOf(function(item)
            return table.contains(lights, item)
        end)[slot] then
            return true
        end
    end
    -- 3) 自动衣服：下雨需要雨伞（占 HANDS）且衣服开关开着，手杖让位；
    --    按槽位感知：仅当手杖目标槽正被雨具占据时才让位（HANDS 始终共享，多格装备栏不改变）。
    if rank >= 4 and ae.CLOTHINGBODY == true and NeedsRainGear()
       and InventoryUtil:GetEquippedSlotsOf(function(i) return ItemUtil:IsRainGear(i) end)[slot] then
        return true
    end
    -- 4) 槽上已有更高等级装备：仅当该等级的条件仍成立时才算占用，
    --    否则雨停后残留的雨伞、战斗结束后残留的护甲会永久挡住手杖/衣物。
    local ownerRank, ownerSwitch = GetEquippedOwner(InventoryUtil:GetEquippedItem(slot))
    if ownerRank and ownerRank < rank and ae[ownerSwitch] == true then
        if ownerRank == 1 and PlayerUtil:CheckThreats() then return true end
        if ownerRank == 3 and NeedsRainGear() then return true end
    end
    return false
end

local AUTO_EQUIP_RULES = {}

function ConfigUtil:SetAutoEquipRule(requester, fn)
    AUTO_EQUIP_RULES[requester] = fn
end

-- requester 同时是 AUTO_EQUIP 分类开关名；无对应分类的模块传自己的标识，开关检查自动跳过。
-- avoidDuplicate 原样透传，保留各模块现有去重语义。
-- force=true 跳过等级仲裁与自定义规则，对应 autocloth 的"关护甲/战斗结束强制覆盖回衣物"。
function ConfigUtil:AutoEquip(requester, item, avoidDuplicate, force)
    if not item or not item:IsValid() then return false end
    if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[requester] == false then return false end

    -- slot 取物品实际装备槽（含自定义槽，经 replica 同步）：据此做槽位感知的等级仲裁（见 IsSuppressed）。
    local slot = ItemUtil:GetEquipSlot(item)
    if slot and not force then
        if IsSuppressed(requester, slot) then return false end
        local rule = AUTO_EQUIP_RULES[requester]
        if rule and not rule(slot, item) then return false end
    end
    return InventoryUtil:Equip(item, avoidDuplicate)
end

return ConfigUtil
