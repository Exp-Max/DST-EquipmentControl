local InventoryUtil = require "util/inventoryutil"
local ConfigUtil = require "util/configutil"
local ItemUtil      = require "util/itemutil"
local PlayerUtil    = require "util/playerutil"

--
-- Logic
--

local AutoEquipFns = {}

local function AddAutoEquip(trigger, fn, opts)
    opts = opts or {}
    local requires_target = (opts.requires_target ~= false)

    AutoEquipFns[#AutoEquipFns + 1] =
    {
        trigger = trigger,
        fn = fn,
        requires_target = requires_target,
    }
end

--
-- Helpers
--

-- 全局默认排除标签（所有标签触发器共用，可被单项配置覆盖）
local TARGET_EXCLUDE_DEFAULT = { "structure", "wall" }

-- 目标标签配置：include 命中任意一个即匹配，exclude 不配则使用默认排除
-- 新增生物类型只需在此表加一行配置 + 一行 AddAutoEquip
local TARGET_TAGS = {
    SHADOW = {
        include = { "shadow", "stalker", "shadowminion", "stalkerminion", "shadowchesspiece" },
    },
    INSECT = {
        include = { "insect", "spider", "hoodedwidow" },
    },
}

-- 通用标签匹配：target 命中 tags 列表中任意一个即返回 true
local function MatchAnyTag(target, tags)
    for _, tag in ipairs(tags) do
        if target:HasTag(tag) then
            return true
        end
    end
    return false
end

-- 从配置表生成标签触发器：自动处理 include/exclude + 全局武器开关
local function MakeTagTrigger(config_key)
    local cfg = TARGET_TAGS[config_key]
    local exclude = cfg.exclude or TARGET_EXCLUDE_DEFAULT
    return function(target)
        if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS then return false end
        if MatchAnyTag(target, exclude) then return false end
        return MatchAnyTag(target, cfg.include)
    end
end

-- 玻璃刀
local GlasscutterTrigger = MakeTagTrigger("SHADOW")

-- [MOD]永不妥协 - 电蚊拍
local BugzapperTrigger = MakeTagTrigger("INSECT")

-- [MOD]永不妥协 - 沃托克斯亲和触发器
local function WortoxAllegianceTrigger(target)
    -- 快速失败检查：全局自动装备开关未开启
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS then
        return false
    end

    -- 快速失败检查：玩家不存在或目标无效
    if not ThePlayer or not target then
        return false
    end

    -- 只对沃托克斯生效
    if ThePlayer.prefab ~= "wortox" then
        return false
    end

    -- 检查任一亲和技能是否激活（月相或暗影）
    local has_lunar = SkillTreeUtil:IsSkillActivated("wortox_allegiance_lunar")
    local has_shadow = SkillTreeUtil:IsSkillActivated("wortox_allegiance_shadow")

    if not has_lunar and not has_shadow then
        return false
    end

    -- 检测回响状态
    -- 注：finishportalhoptask 和 debuffable:HasDebuff 都是服务端专用，
    -- 客户端无法访问。客户端唯一可靠的方式是通过 player_classified
    -- 上的 freesoulhops netvar（该值在服务端 SetNetvar 时同步到客户端）。
    -- _freesoulhop_counter 通过客户端事件 freesoulhopschanged 更新，
    -- 作为备用方案。
    local classified = ThePlayer.player_classified
    local has_echo = (classified and classified.freesoulhops and classified.freesoulhops:value() > 0)
                    or (ThePlayer._freesoulhop_counter and ThePlayer._freesoulhop_counter > 0)
    if not has_echo then
        ThePlayer._wortox_triggered_entities = nil  -- 回响结束，清空每生物追踪
        return false
    end

    -- 目标检查：建筑/墙/死亡目标不可触发
    if target:HasTag("structure") or target:HasTag("wall") then
        return false
    end
    if IsEntityDead(target) then
        return false
    end

    if not InventoryUtil:Has("wortox_soul", 1) then
        return false
    end

    -- 每生物只切一次（暗影生物除外）
    if not MatchAnyTag(target, TARGET_TAGS.SHADOW.include) then
        local tracked = ThePlayer._wortox_triggered_entities
        if not tracked then
            ThePlayer._wortox_triggered_entities = { [target.GUID] = true }
        elseif tracked[target.GUID] then
            return false
        else
            tracked[target.GUID] = true
        end
    end

    return true
end

local function IsRangeWeaponEquipped()
    local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)

    if not equipped then
        return false
    end

    -- 火把类（queen_torch 等）：本质是近战火把，complexprojectile.ismeleeweapon=true，
    -- 投掷只是特技，不应算远程武器而阻断攻击切出预设武器（否则手持火把攻击时不会切预设武器）。
    if equipped:HasTag("torch") then
        return false
    end

    return ItemUtil:IsRangedWeapon(equipped)
end

local function IsStaffWeaponEquipped()
    local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)

    if not equipped then
        return false
    end

    if equipped.prefab == "orangestaff" then
        return false
    end

    -- 光源（如带 spellcaster 标签的可施法光源）不算法杖，不阻断攻击切出预设武器。
    -- 说明：IsStaff 按 prefab 含 "staff" 或 spellcaster 标签判定，会误伤"可施法的光源"；
    -- 而 itemutil:GetEquipCat 已将光源优先归 light 类，且 LIGHT 类别同样用 IsLightSource 识别，
    -- 因此在此显式排除光源（与 orangestaff 特例同理，且和 mod 自身识别光源的标准一致）。
    if ItemUtil:IsLightSource(equipped) then
        return false
    end

    return ItemUtil:IsStaff(equipped)
end

-- local function IsRiding()
--     if ThePlayer.components.rider:IsRiding()
--         and ThePlayer:HasTag("rider")
--         and ThePlayer.replica.rider ~= nil
--         and ThePlayer.replica.rider:GetMount() ~= nil then
-- end

local function WeaponTrigger(target)
    return MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS
        -- and not IsRiding()
        and not IsRangeWeaponEquipped()
        and not IsStaffWeaponEquipped()
        and not target:HasTag("butterfly")
end

local function GetPrefabFromInventory(prefab)
    local bestItem = nil
    local bestUsed = -1

    for _, invItem in pairs(InventoryUtil:GetPlayerInventory(true, nil, true)) do
        if invItem.prefab == prefab and not ItemUtil:IsBroken(invItem) then
            local used = ItemUtil:GetPercentUsed(invItem)
            if used > bestUsed then
                bestUsed = used
                bestItem = invItem
            end
        end
    end

    return bestItem
end

-- 基础武器装备函数（必须放在其他装备函数之前）
local function EquipWeapon(target)
    local ac = PlayerUtil:GetComponent("actioncontroller")
    if not ac then
        return false
    end

    local weapon = ac:GetAutoEquipCategoryItem(target)

    -- 游戏返回的“最佳”武器可能带 broken 标签（锻造装备 0 耐久）：完全不可用，排除出候选列表不装备
    if weapon and ItemUtil:IsBroken(weapon) then
        return false
    end

    -- 武器可加燃料但燃料耗尽时会触发 ShouldAutoUnequip，此时不应装备（否则会立即被卸下）
    if weapon and ItemUtil:ShouldAutoUnequip(weapon) then
        return false
    end

    return ConfigUtil:AutoEquip("WEAPONS", weapon, true)
end

-- 玻璃刀装备
local function EquipGlasscutter(target)
    local weapon = GetPrefabFromInventory("glasscutter")

    if not weapon then
        return EquipWeapon(target)
    end

    return ConfigUtil:AutoEquip("WEAPONS", weapon, true)
end

-- [MOD]永不妥协 - 电蚊拍装备函数
local function EquipBugzapper(target)
    local weapon = GetPrefabFromInventory("bugzapper")

    if not weapon then
        return EquipWeapon(target)
    end

    return ConfigUtil:AutoEquip("WEAPONS", weapon, true)
end

-- [MOD]永不妥协 - 沃托克斯亲和武器装备函数
-- 根据激活的亲和技能自动选择月相或暗影武器
local function EquipWortoxAllegianceWeapon(target)
    -- 检查激活的亲和技能
    local has_lunar = SkillTreeUtil:IsSkillActivated("wortox_allegiance_lunar")
    local has_shadow = SkillTreeUtil:IsSkillActivated("wortox_allegiance_shadow")

    -- 武器优先级列表（月相优先，暗影次之）
    local weapons = {}

    -- 添加月相武器
    if has_lunar then
        table.insert(weapons, "glasscutter")       -- 玻璃刀
        table.insert(weapons, "sword_lunarplant")  -- 亮茄剑
        table.insert(weapons, "moonglassaxe")      -- 玻璃斧
        table.insert(weapons, "pickaxe_lunarplant")-- 亮茄镐
    end

    -- 添加暗影武器
    if has_shadow then
        table.insert(weapons, "voidcloth_scythe") -- 虚空布镰刀
    end

    -- 按优先级查找武器
    for _, prefab in ipairs(weapons) do
        local weapon = GetPrefabFromInventory(prefab)
        if weapon then
            return ConfigUtil:AutoEquip("WEAPONS", weapon, true)
        end
    end

    -- 如果没有亲和武器，装备普通武器
    return EquipWeapon(target)
end

local function EquipRanged()
    local ac = PlayerUtil:GetComponent("actioncontroller")
    if not ac then return false end
    local ranged = ac:GetItemFromCategory("WEAPONS")
    -- 候选武器可能带 broken 标签（锻造装备 0 耐久）：完全不可用，排除出候选列表不装备
    if ranged and not ItemUtil:IsBroken(ranged) then
        return ConfigUtil:AutoEquip("WEAPONS", ranged, true)
    end
    return false
end

local function WobyRangedTrigger(_)
    local ac = PlayerUtil:GetComponent("actioncontroller")
    local target = ac and ac:GetItemFromCategory("WEAPONS")
    local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
    return MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS
        and PlayerUtil:IsRidingBigWoby()
        and target ~= equipped
end

--
-- Auto equips
--

-- 注：WortoxAllegianceTrigger 必须在 GlasscutterTrigger 之前，
-- 以确保灵魂回响状态下的亲和武器（月相/暗影）优先于通用玻璃刀触发。
-- 对于月相亲和沃托克斯，EquipWortoxAllegianceWeapon 会优先查找玻璃刀；
-- 对于暗影亲和沃托克斯，则会使用虚空布镰刀，避免错误装备月相武器。
AddAutoEquip(WortoxAllegianceTrigger, EquipWortoxAllegianceWeapon)
AddAutoEquip(GlasscutterTrigger, EquipGlasscutter)
AddAutoEquip(BugzapperTrigger, EquipBugzapper)
AddAutoEquip(WeaponTrigger, EquipWeapon)
AddAutoEquip(WobyRangedTrigger, EquipRanged, { requires_target = false })

-- 调试：触发器名称映射（仅用于日志）
local TRIGGER_NAMES = {
    [WortoxAllegianceTrigger] = "Wortox",
    [GlasscutterTrigger]      = "Glasscutter",
    [BugzapperTrigger]        = "Bugzapper",
    [WeaponTrigger]           = "Weapon",
    [WobyRangedTrigger]       = "Woby",
}

local function Init()
    local PlayerController = ThePlayer and ThePlayer.components.playercontroller

    if not PlayerController then
        return
    end

    -- 事件驱动：补燃料成功时尝试自动重新装备该武器
    ThePlayer:ListenForEvent("ec_fuel_added", function(inst, data)
        if data and data.item and ItemUtil:IsWeapon(data.item) then
            ItemUtil:TryReEquipFuelable(data.item)
        end
    end)

    local PlayerControllerDoAttackButton = PlayerController.DoAttackButton
    function PlayerController:DoAttackButton(retarget)
        local force_attack = TheInput:IsControlPressed(CONTROL_FORCE_ATTACK)

        -- 无需目标的自动切换（如大沃比骑乘远程武器）
        for i = 1, #AutoEquipFns do
            local rule = AutoEquipFns[i]
            if rule.requires_target == false and rule.trigger(nil) then
                rule.fn(nil)
                break
            end
        end

        -- 扩展索敌范围：游戏本体 GetAttackTarget 通过 GetAttackRangeWithWeapon()
        -- 获取索敌距离，该值取决于当前手持物品。手持短距离物品时 attackrange 仅有
        -- 基础值~2，directwalking 模式下 reach≈2.1，中远距离目标搜不到。
        -- 这里临时将 combat._attackrange 扩大到远程武器级别(16)，使搜索半径
        -- 覆盖弹弓视距外，确保任意距离的敌人都能被搜到并触发自动切换。
        --
        -- 强制攻击时取消只搜敌对(_combat标签)生物的限制：
        -- GetAttackTarget 内部空间查询仅搜 _combat 实体（蝴蝶/兔子等无此标签），
        -- 强制攻击(CTRL+F/CTRL+左键)表示玩家明确意图攻击当前指向目标，
        -- 此时若原版索敌返回 nil，补一次不限定 _combat 标签的搜索。
        local target = nil
        if retarget == nil and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS then
            local combat = PlayerUtil:GetCombat()
            local saved_range = combat._attackrange:value()
            combat._attackrange:set(math.max(saved_range, 16))
            target = self:GetAttackTarget(force_attack, retarget, retarget ~= nil)
            combat._attackrange:set(saved_range)

            if target == nil and force_attack then
                local x, y, z = self.inst.Transform:GetWorldPosition()
                local search_range = math.max(saved_range, 16) + 11 + self.inst:GetPhysicsRadius(0)
                local ents = TheSim:FindEntities(x, y, z, search_range, nil,
                    {"INLIMBO", "playerghost", "flight", "notarget", "noattack", "invisible"})
                local nearest_dist = math.huge
                for _, ent in ipairs(ents) do
                    if ent.entity:IsVisible()
                        and ent.replica.combat ~= nil
                        and ent.replica.combat:CanBeAttacked(self.inst)
                    then
                        local dsq = self.inst:GetDistanceSqToInst(ent)
                        if dsq < nearest_dist then
                            nearest_dist = dsq
                            target = ent
                        end
                    end
                end
            end
        else
            target = self:GetAttackTarget(force_attack, retarget, retarget ~= nil)
        end

        -- 目标触发型自动切换：根据目标特性选择最优武器（玻璃刀→暗影、电蚊拍→虫类等）
        -- 法杖/远程武器不切换：装备法杖攻击时保持法杖，不自动换成其他武器
        if target and not IsStaffWeaponEquipped() then
            for i = 1, #AutoEquipFns do
                local rule = AutoEquipFns[i]
                if rule.requires_target ~= false and rule.trigger(target) then

                    rule.fn(target)
                    break
                end
            end
        end

        -- 战斗登记交给 configutil 统一调度（不再给 autolight 分发标记）：
        -- 战斗期间 LIGHT 装备请求会被 IsSuppressed 挡住，黑暗宣告可解除。
        ConfigUtil:NoteAttack()

        PlayerControllerDoAttackButton(self, retarget)
    end
end

return Init