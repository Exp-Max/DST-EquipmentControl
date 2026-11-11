-- Equipment Control - Item Functions
-- 文件: scripts/util/itemutil.lua

local CacheService = require "util/cacheservice"
local InventoryUtil = require "util/inventoryutil"

local ItemUtil = {}

ItemUtil.FuelBlacklist = {
    fireflies = true,
    horrorfuel = true,
    durian = true,
    durian_cooked = true,
}

local function FindMatchingItem(matchFn)
    -- 基础扫描：主物品栏 + 背包 + 装备（不含打开的容器）
    for _, invItem in pairs(InventoryUtil:GetPlayerInventory(true, nil, false)) do
        if matchFn(invItem) then
            return invItem
        end
    end
    -- 开启"从打开容器取物"时，追加已打开容器（箱子/冰箱等）扫描
    if MOD_EQUIPMENT_CONTROL.AUTO_FROM_OPEN_CONTAINERS then
        for _, invItem in ipairs(InventoryUtil:GetOpenContainerItems()) do
            if matchFn(invItem) then
                return invItem
            end
        end
    end
    return nil
end

local ExclusiveOwners = {
    spear_wathgrithr_lightning_charged = "wathgrithr",
    pocketwatch_weapon                 = "wanda",
    wortox_nabbag                      = "wortox",
}

local function IsRestrictedFromPlayer(prefab, player_prefab)
    if not prefab or not player_prefab then return false end
    for base_prefab, owner in pairs(ExclusiveOwners) do
        if prefab:find(base_prefab, 1, true) == 1 then
            return player_prefab ~= owner
        end
    end
    return false
end

local function IsLightningSpearPrefab(prefab)
    return prefab and prefab:find("spear_wathgrithr_lightning_charged", 1, true) == 1
end

function ItemUtil:GetCachedItem(item)
    return CacheService:GetCachedItem(item)
end

function ItemUtil:GetEquipSlot(item)
    return item and item.replica.equippable and item.replica.equippable:EquipSlot()
end

function ItemUtil:GetClassified(item)
    return item and item.replica.inventoryitem and item.replica.inventoryitem.classified
end

-- 物品实体的标签查询（玩家实体标签走 PlayerUtil:HasTag）
function ItemUtil:HasTag(item, tag)
    return item ~= nil and item:HasTag(tag)
end

function ItemUtil:GetPerish(item)
    local classified = self:GetClassified(item)
    return classified and classified.perish:value() / 62 or 0
end

function ItemUtil:GetPercentUsed(item)
    local classified = self:GetClassified(item)
    return classified and classified.percentused:value() or 0
end

-- ===== FUEL / REPAIR CLASSIFICATION =====

function ItemUtil:GetFuelTypes(item)
    local ret = {}

    for _, tag in pairs(FUELTYPE) do
        if item:HasTag(tag .. "_fueled") then
            ret[#ret + 1] = { cat = "fuel", tag = tag }
        end
    end

    if item:HasTag("needssewing") then
        ret[#ret + 1] = { cat = "sewing" }
    end

    if item:HasTag("broken") then
        for _, v in pairs(FORGEMATERIALS) do
            if item:HasTag("forgerepairable_" .. v) then
                ret[#ret + 1] = { cat = "forge", material = v }
            end
        end
    end

    for _, v in pairs(MATERIALS) do
        if item:HasTag("repairable_" .. v) then
            ret[#ret + 1] = { cat = "repair", material = v }
        end
    end

    local medal_repair = self:GetMedalRepairCommon(item)
    if medal_repair then
        local sorted = {}
        for prefab, value in pairs(medal_repair) do
            sorted[#sorted + 1] = { prefab = prefab, value = value }
        end
        table.sort(sorted, function(a, b) return a.value > b.value end)
        for _, entry in ipairs(sorted) do
            ret[#ret + 1] = { cat = "medal", prefab = entry.prefab }
        end
    end

    return ret
end

function ItemUtil:GetFuelOnlyTypes(item)
    local ret = {}
    for _, tag in pairs(FUELTYPE) do
        if item:HasTag(tag .. "_fueled") then
            ret[#ret + 1] = { cat = "fuel", tag = tag }
        end
    end
    return ret
end

function ItemUtil:GetRepairTypes(item)
    local ret = {}
    if item:HasTag("needssewing") then
        ret[#ret + 1] = { cat = "sewing" }
    end
    if item:HasTag("broken") then
        for _, v in pairs(FORGEMATERIALS) do
            if item:HasTag("forgerepairable_" .. v) then
                ret[#ret + 1] = { cat = "forge", material = v }
            end
        end
    end
    for _, v in pairs(MATERIALS) do
        if item:HasTag("repairable_" .. v) then
            ret[#ret + 1] = { cat = "repair", material = v }
        end
    end
    local medal_repair = self:GetMedalRepairCommon(item)
    if medal_repair then
        local sorted = {}
        for prefab, value in pairs(medal_repair) do
            sorted[#sorted + 1] = { prefab = prefab, value = value }
        end
        table.sort(sorted, function(a, b) return a.value > b.value end)
        for _, entry in ipairs(sorted) do
            ret[#ret + 1] = { cat = "medal", prefab = entry.prefab }
        end
    end
    return ret
end

function ItemUtil:GetRepairOnlyTypes(item)
    return self:GetRepairTypes(item)
end

function ItemUtil:GetFuelItem(fuelTypes)
    local fuel = FindMatchingItem(function(item)
        if ItemUtil.FuelBlacklist[item.prefab] then return false end
        for _, ft in ipairs(fuelTypes) do
            if ft.cat == "fuel" and item:HasTag(ft.tag .. "_fuel") then
                return true
            end
        end
        return false
    end)
    return fuel
end

function ItemUtil:GetRepairItem(repairTypes)
    local byCat = {}
    for _, ft in ipairs(repairTypes) do
        byCat[ft.cat] = true
    end

    local repairItem = nil
    if byCat.medal then
        for _, ft in ipairs(repairTypes) do
            if ft.cat == "medal" and not ItemUtil.FuelBlacklist[ft.prefab] then
                repairItem = FindMatchingItem(function(item)
                    if ItemUtil.FuelBlacklist[item.prefab] then return false end
                    return item.prefab == ft.prefab
                end)
                if repairItem then break end
            end
        end
    end

    if not repairItem then
        repairItem = FindMatchingItem(function(item)
            if ItemUtil.FuelBlacklist[item.prefab] then return false end
            if byCat.sewing and item:HasActionComponent("sewing") then return true end
            if byCat.forge then
                for _, ft in ipairs(repairTypes) do
                    if ft.cat == "forge" and item:HasTag("forgerepair_" .. ft.material) then
                        return true
                    end
                end
            end
            if byCat.repair then
                for _, ft in ipairs(repairTypes) do
                    if ft.cat == "repair" and item:HasTag("repairer") then
                        if item:HasTag("health_" .. ft.material)
                            or item:HasTag("finiteuses_" .. ft.material) then
                            return true
                        end
                    end
                end
            end
            return false
        end)
    end

    if repairItem then
        if byCat.sewing then return repairItem, ACTIONS.SEW
        elseif byCat.medal and ACTIONS.REPAIRCOMMON then return repairItem, ACTIONS.REPAIRCOMMON
        elseif byCat.forge or byCat.repair then return repairItem, ACTIONS.REPAIR
        end
    end
    return nil, nil
end

-- ===== FEED REPAIR =====

function ItemUtil:GetFeedTypes(item)
    if not (item:HasTag("fedbyall") or item:HasTag("handfed")) then
        return {}
    end
    local cached = self:GetCachedItem(item)
    if cached and cached.eater then
        return { { cat = "feed" } }
    end
    return {}
end

function ItemUtil:GetFeedOnlyTypes(item)
    return self:GetFeedTypes(item)
end

function ItemUtil:GetFeedItem(feedTypes)
    if not feedTypes or #feedTypes == 0 then return nil, nil end
    local food = FindMatchingItem(function(item)
        if ItemUtil.FuelBlacklist[item.prefab] then return false end
        local cached = ItemUtil:GetCachedItem(item)
        return cached and cached.edible ~= nil
    end)
    if food then
        return food, ACTIONS.EAT
    end
    return nil, nil
end

function ItemUtil:IsFeedable(item)
    if not item then return false end
    if not (item:HasTag("fedbyall") or item:HasTag("handfed")) then return false end
    local cached = self:GetCachedItem(item)
    if not (cached and cached.eater) then return false end
    if item.replica and item.replica.armor then return true end
    if item:HasTag("armor") then return true end
    return false
end

-- ===== FOOD =====

-- 角色 prefab 只用于索引官方 TUNING 的 <PREFAB>_FOOD_MULT 命名规则（tuning.lua:4540），
-- 不用于任何能力判定；能力一律走官方网络同步标签。
local function GetFoodTraitCharacter()
    return ThePlayer and ThePlayer.prefab
end

-- components/edible.lua:99/125 的 ignore_spoilage 等价于官方 ignoresspoilage 标签
-- （eater.lua:113-115；客户端 componentactions.lua:1167/1193 也读它）。
local function IsSpoilingFood(cachedItem, val)
    return not (ThePlayer and ThePlayer:HasTag("ignoresspoilage"))
        and cachedItem.edible.degrades_with_spoilage
        and val > 0
end

local FOODSTATES = { FRESH = 1, STALE = 2, SPOILED = 3 }

local function GetFoodState(item)
    return item:HasTag("stale") and FOODSTATES.STALE
        or item:HasTag("spoiled") and FOODSTATES.SPOILED
        or FOODSTATES.FRESH
end

-- 腐败倍率一律取官方 TUNING：默认 STALE/SPOILED_FOOD_*；
-- wickerbottom.lua:75-76 覆盖 eater.stale_hunger/stale_health，客机按角色标签取专属前缀。
local function GetSpoilagePrefix()
    return ThePlayer and ThePlayer:HasTag("bookbuilder") and "WICKERBOTTOM_" or ""
end

local function ApplySpoilage(val, cachedItem, item, attr)
    if not IsSpoilingFood(cachedItem, val) then
        return val
    end
    local prefix = GetSpoilagePrefix()
    local foodState = GetFoodState(item)
    if foodState == FOODSTATES.STALE then
        return val * (TUNING[prefix .. "STALE_FOOD_" .. attr] or TUNING["STALE_FOOD_" .. attr])
    elseif foodState == FOODSTATES.SPOILED then
        return val * (TUNING[prefix .. "SPOILED_FOOD_" .. attr] or TUNING["SPOILED_FOOD_" .. attr])
    end
    return val
end

function ItemUtil:GetFoodMultiplier()
    local prefab = GetFoodTraitCharacter()
    if not prefab then return 1 end
    return TUNING[prefab:upper() .. "_FOOD_MULT"] or 1
end

function ItemUtil:GetHunger(item)
    if item:HasTag("soul") and ThePlayer and ThePlayer:HasTag("souleater") then
        return TUNING.CALORIES_MEDSMALL
    end
    local cachedItem = self:GetCachedItem(item)
    if not (cachedItem and cachedItem.edible) then
        return 0
    end
    local hunger = ApplySpoilage(cachedItem.edible.hungervalue, cachedItem, item, "HUNGER")
    return math.ceil(hunger * self:GetFoodMultiplier())
end

function ItemUtil:GetHealth(item)
    local cachedItem = self:GetCachedItem(item)
    if cachedItem and cachedItem.healer then
        return cachedItem.healer.health
    end
    if not (cachedItem and cachedItem.edible) then
        return 0
    end
    -- 官方 wormwood.lua:800 SetAbsorptionModifiers(0,1,1)：食物不回血
    if ThePlayer and ThePlayer:HasTag("plantkin") then return 0 end
    local health = ApplySpoilage(cachedItem.edible.healthvalue, cachedItem, item, "HEALTH")
    return math.ceil(health * self:GetFoodMultiplier())
end

local function HasFoodType(item, foodtypes)
    if not foodtypes then return false end
    for _, v in ipairs(foodtypes) do
        local tags = type(v) == "table" and v.types or { v }
        for _, tag in ipairs(tags) do
            if item:HasTag("edible_" .. tag) then
                return true
            end
        end
    end
    return false
end

-- 与官方客户端 EAT 动作收集同款（componentactions.lua:2672-2688）：
-- FOODGROUP 用 <name>_eater + edible_<type>，FOODTYPE 用 <type>_eater + edible_<type>。
local function CheckDietTags(item, categories)
    if type(categories) ~= "table" then
        return false, false
    end
    for _, v in pairs(categories) do
        local tag = type(v) == "table" and v.name or v
        -- 分类项非字符串会触发 tag.."_eater" 拼接抛错，使整类食物判定崩溃，故一并挡掉
        if type(tag) == "string" and ThePlayer and ThePlayer:HasTag(tag .. "_eater") then
            return true, HasFoodType(item, { v })
        end
    end
    return false, false
end

function ItemUtil:CanEat(item)
    if not ThePlayer then return false end
    if ThePlayer:HasTag("souleater") and item:HasTag("soul") then
        return true
    end

    local hasDietTag, canEatByDiet = CheckDietTags(item, FOODGROUP)
    if not canEatByDiet then
        local hasTag2, canEat2 = CheckDietTags(item, FOODTYPE)
        hasDietTag, canEatByDiet = hasDietTag or hasTag2, canEat2
    end

    if not hasDietTag then
        local cachedItem = self:GetCachedItem(item)
        if not (cachedItem and cachedItem.edible) then
            return false
        end
        canEatByDiet = true
    end

    if not canEatByDiet then
        return false
    end

    if item.prefab == "winter_food4" then
        return false
    end

    if ThePlayer:HasTag("nospoiledfood") then
        if self:IsPerishSpoiled(item) then
            return false
        end
    end

    return true
end

function ItemUtil:IsHealingItem(item)
    local cachedItem = self:GetCachedItem(item)
    return cachedItem and cachedItem.healer
end

function ItemUtil:GetUses(item)
    local cachedItem = self:GetCachedItem(item)
    if not cachedItem then return 0 end
    if not cachedItem.finiteuses then return math.huge end

    local total = cachedItem.finiteuses.total or 0
    local uses = total

    if cachedItem.tool then
        local _, effectiveness = next(cachedItem.tool.actions)
        if effectiveness and type(effectiveness) == "number" then
            uses = uses + effectiveness
        end
    end

    local _, consumption = next(cachedItem.finiteuses.consumption)
    if consumption and type(consumption) == "number" then
        uses = uses - consumption
    end

    return uses
end

function ItemUtil:GetWalkspeedMult(item)
    if item and item.replica and item.replica.inventoryitem then
        return item.replica.inventoryitem:GetWalkSpeedMult()
    end
    return 0
end

-- ===== DAMAGE =====

local function GetHambatDamage(self, item)
    local damage = TUNING.HAMBAT_DAMAGE * self:GetPerish(item)
    return Remap(damage, 0, TUNING.HAMBAT_DAMAGE,
        TUNING.HAMBAT_MIN_DAMAGE_MODIFIER * TUNING.HAMBAT_DAMAGE,
        TUNING.HAMBAT_DAMAGE)
end

local function ApplyStimuli(self, item, damage, target)
    if not target then return damage end
    local cachedItem = self:GetCachedItem(item)
    if cachedItem and cachedItem.weapon
        and cachedItem.weapon.stimuli == "electric" then
        damage = damage * (TUNING.ELECTRIC_DAMAGE_MULT
            + (target:GetIsWet() and TUNING.ELECTRIC_WET_DAMAGE_MULT or 0))
    end
    return damage
end

local BadPrefabs = { lilina_wrath = 68 }

function ItemUtil:GetDamage(item, target, noStimuli)
    if item.prefab == "hambat" then
        return GetHambatDamage(self, item)
    end
    local cachedItem = self:GetCachedItem(item)
    if not (cachedItem and cachedItem.weapon) then return 0 end
    if BadPrefabs[item.prefab] then return BadPrefabs[item.prefab] end
    local damage = self:GetWeaponDamage(cachedItem, item)
        + (cachedItem.planar_damage or 0)
    return noStimuli and damage or ApplyStimuli(self, item, damage, target)
end

function ItemUtil:GetWeaponDamage(cachedItem, item)
    if not cachedItem or not cachedItem.weapon then return 0 end
    local damage = cachedItem.weapon.damage
    if type(damage) == "function" then
        local ok, val = pcall(damage, item, ThePlayer, ThePlayer)
        damage = (ok and type(val) == "number" and val) or 0
    elseif type(damage) ~= "number" then
        damage = 0
    end
    return damage
end

function ItemUtil:GetArmor(item)
    local cachedItem = self:GetCachedItem(item)
    if not cachedItem then return 0 end
    if cachedItem.armor then
        local percent = self:GetPercentUsed(item) / 100
        return cachedItem.armor.maxcondition * percent
    elseif cachedItem.has and cachedItem.has.resistance then
        return 9999
    end
    return 0
end

function ItemUtil:GetAttackRange(item)
    if item and item.replica and item.replica.inventoryitem then
        return item.replica.inventoryitem:AttackRange()
    end
    return 0
end

-- 注意：返回的是"该开始维护的耐久百分比阈值"（0~100），不是次数，名字是历史遗留
-- 没有 finiteuses 的物品（纯 fueled）一律返回 3，即只剩 3% 才动手
function ItemUtil:GetFiniteUses(item)
    local cachedItem = self:GetCachedItem(item)
    if not (cachedItem and cachedItem.finiteuses) then return 3 end
    local percent = self:GetPercentUsed(item) / 100
    local usesleft = percent * cachedItem.finiteuses.maxuses
    if usesleft <= 0 then return 3 end
    if math.floor(usesleft) >= ItemUtil.RepairUsesLeft + 1 then return 0 end
    return math.ceil(100 / usesleft)
end

-- 耐久按"次"跳变的物品：总次数从 TUNING 读，按"剩余次数"判断修补时机
-- TUNING 没有统一的 prefab→次数 约定（全表只有 HEATROCK_NUMUSES / FUMAROLETOOL_NUMUSES
-- 两个 *_NUMUSES 键），只能显式登记键名；未登记的物品继续走百分比阈值
ItemUtil.StepUsesTuningKey =
{
    heatrock = "HEATROCK_NUMUSES",   -- 暖石：8 次，每次 12.5%
}

-- 剩余几次时开始修补：1 = 用掉最后一次前才修（最省缝纫包），2 更安全（身上没缝纫包时不易丢）
ItemUtil.RepairUsesLeft = 1

-- 跳变型耐久的剩余使用次数；非跳变型耐久返回 nil
-- 与 GetUses（排序优先权值）、GetFiniteUses（百分比阈值）不是一回事，勿混用
function ItemUtil:GetStepUsesLeft(item)
    if not item then return nil end
    local key = ItemUtil.StepUsesTuningKey[item.prefab]
    local numuses = key and TUNING[key]
    if not numuses or numuses <= 0 then return nil end
    return self:GetPercentUsed(item) / 100 * numuses
end

-- 维护阈值（百分比 0~100）：percent <= 阈值 时该动手
-- 跳变型耐久（暖石 12.5% 一跳）必须按"次数"换算：
-- 它的档位是 100/88/75/63/50/38/25/13 → 0(移除)，永远落不进原来的 3% 窗口
function ItemUtil:GetMaintenanceThreshold(item)
    local usesleft = self:GetStepUsesLeft(item)
    if usesleft == nil then
        return self:GetFiniteUses(item)
    end
    local numuses = TUNING[ItemUtil.StepUsesTuningKey[item.prefab]]
    -- 用 ceil：netvar 是四舍五入值（12.5% → 13），ceil 保证阈值不低于该档位
    return math.ceil(ItemUtil.RepairUsesLeft / numuses * 100)
end

function ItemUtil:GetMaxFuel(item)
    local cachedItem = self:GetCachedItem(item)
    return cachedItem and cachedItem.fueled
        and cachedItem.fueled.maxfuel or 0
end

-- ===== TOOLS =====

function ItemUtil:IsAxe(item)
    if not item then return false end
    return item:HasTag("CHOP_tool") or self:HasToolAction(item, "CHOP")
end

function ItemUtil:IsPickaxe(item)
    if not item then return false end
    return item:HasTag("MINE_tool") or self:HasToolAction(item, "MINE")
end

function ItemUtil:IsShovel(item)
    if not item then return false end
    return item:HasTag("DIG_tool") or self:HasToolAction(item, "DIG")
end

function ItemUtil:IsHammer(item)
    if not item then return false end
    return item:HasTag("HAMMER_tool") or self:HasToolAction(item, "HAMMER")
end

function ItemUtil:IsPitchfork(item)
    if not item then return false end
    return item:HasTag("terraform") or self:HasToolAction(item, "TERRAFORM")
end

function ItemUtil:IsHoe(item)
    if not item then return false end
    return item:HasTag("hoe") or self:HasComponent(item, "hoe")
end

function ItemUtil:IsBugnet(item)
    if not item then return false end
    return item:HasTag("bugnet") or self:HasToolAction(item, "NET")
end

function ItemUtil:IsScythe(item)
    if not item then return false end
    return item:HasTag("SCYTHE_tool") or self:HasToolAction(item, "SCYTHE")
end

function ItemUtil:IsCane(item)
    if not item then return false end
    if self:GetEquipSlot(item) ~= EQUIPSLOTS.HANDS then return false end
    if item:HasTag("dumbbell") and ThePlayer and ThePlayer.prefab == "wolfgang" then
        return true
    end
    local is_lightning_spear = IsLightningSpearPrefab(item.prefab)
    local is_wigfrid = ThePlayer and ThePlayer.prefab == "wathgrithr"
    return self:GetWalkspeedMult(item) > 1 and (is_wigfrid or not is_lightning_spear)
end

function ItemUtil:IsOar(item)
    return item and (item:HasTag("oar") or self:HasComponent(item, "oar"))
end

function ItemUtil:IsFishingrod(item)
    return item and (item:HasTag("fishingrod") or self:HasComponent(item, "oceanfishingrod"))
end

function ItemUtil:IsWateringcan(item)
    return item and item:HasTag("wateringcan")
end

function ItemUtil:IsBrush(item)
    return item and (item.prefab == "brush" or item:HasTag("brush"))
end

function ItemUtil:IsGestaltCage(item)
    return item and (item.prefab == "gestalt_cage" or item:HasTag("gestalt_cage"))
end

function ItemUtil:IsTool(item)
    if not item then return false end
    return self:IsAxe(item)
        or self:IsPickaxe(item)
        or self:IsShovel(item)
        or self:IsHammer(item)
        or self:IsPitchfork(item)
        or self:IsHoe(item)
        or self:IsBugnet(item)
        or self:IsScythe(item)
        or self:IsOar(item)
        or self:IsFishingrod(item)
        or self:IsWateringcan(item)
        or self:IsBrush(item)
        or self:IsGestaltCage(item)
        or (self:IsCane(item) and not self:IsStaff(item))
end

function ItemUtil:GetEquipmentKind(item)
    if not item then return "unknown" end
    if self:IsTool(item) then return "tool" end
    if self:IsLightSource(item) then return "light" end
    if self:IsWeapon(item) then return "weapon" end
    if self:IsArmor(item) then return "armor" end
    if self:IsCloth(item) then return "cloth" end
    if self:IsBackpack(item) then return "backpack" end
    if self:IsMedal(item) then return "medal" end
    if self:IsStaff(item) then return "staff" end
    return "other"
end

function ItemUtil:IsEquipment(item)
    return self:GetEquipmentKind(item) ~= "other" and self:GetEquipmentKind(item) ~= "unknown"
end

-- ===== LIGHT =====

function ItemUtil:IsLightSource(item)
    return not item:HasTag("fueldepleted")
        and (
            item:HasTag(FUELTYPE.CAVE .. "_fueled")
            or item:HasTag(FUELTYPE.LIGHTER .. "_fueled")
            or item:HasTag(FUELTYPE.WORMLIGHT .. "_fueled")
            or item:HasTag("redlantern")
            or item:HasTag("lighter")
        )
end

-- ===== WEAPONS =====

function ItemUtil:IsProjectile(item)
    local cachedItem = self:GetCachedItem(item)
    return cachedItem and (cachedItem.has.projectile
        or cachedItem.has.complexprojectile)
end

function ItemUtil:IsWeapon(item)
    if not item then return false end

    local prefab = item.prefab
    local cachedItem = self:GetCachedItem(item)

    -- 通用排除：哑铃 / 已损坏 / 禁用拳击
    if item:HasTag("dumbbell") or item:HasTag("broken") or item:HasTag("nopunch") then
        return false
    end

    if not (cachedItem and cachedItem.weapon) then
        -- 无缓存武器数据：标签 + replica 启发式判定
        local could_be_weapon = item:HasTag("weapon")
            or (item.replica.inventoryitem ~= nil
                and item.replica.inventoryitem:IsWeapon())
            or (item.replica.equippable ~= nil
                and item.replica.equippable:EquipSlot() == EQUIPSLOTS.HANDS)

        if not could_be_weapon then return false end
    else
        -- 有缓存武器数据：精确伤害判定
        if prefab == "wortox_nabbag" then
            return ThePlayer and ThePlayer.prefab == "wortox"
        end

        if cachedItem.weapon.can_ranged then
            return false
        end

        local damage = self:GetWeaponDamage(cachedItem, item)
            + (cachedItem.planar_damage or 0)
        if damage <= 27 then return false end
    end

    if IsRestrictedFromPlayer(prefab, ThePlayer and ThePlayer.prefab) then
        return false
    end

    return true
end

function ItemUtil:IsMeleeWeapon(item)
    if not self:IsWeapon(item) then return false end
    return not (self:IsLightSource(item)
        or self:IsTerraformer(item)
        or self:IsProjectile(item)
        or self:IsStaff(item))
end

function ItemUtil:IsRangedWeapon(item)
    return self:IsProjectile(item)
end

-- ===== ARMOUR =====

function ItemUtil:IsArmor(item)
    return self:GetArmor(item) > 0
end

function ItemUtil:IsArmorHat(item)
    if not item then return false end
    return self:IsArmor(item) and self:GetEquipSlot(item) == EQUIPSLOTS.HEAD
end

function ItemUtil:IsArmorBody(item)
    if not item then return false end
    return self:IsArmor(item) and self:GetEquipSlot(item) == EQUIPSLOTS.BODY
end

-- ===== CLOTHING =====

-- 检查物品是否为护目镜（有 goggles 标签）
-- 沙漠护目镜、天体护目镜、亮茄头盔、南瓜头等
function ItemUtil:IsGoggle(item)
    if not item then return false end
    return item:HasTag("goggles")
end

-- 获取物品的理智回复值（dapperness），0 表示不回复
-- 贝雷帽、熊皮背心、高礼帽、花环等
function ItemUtil:GetDapperness(item)
    if not item then return 0 end
    local c = CacheService:GetCachedItem(item)
    if c and c.equippable then
        return c.equippable.dapperness or 0
    end
    return 0
end

function ItemUtil:IsCloth(item)
    if not item then return false end
    if not self:HasComponent(item, "equippable") then
        return false
    end
    if not (self:HasComponent(item, "finiteuses") or self:HasComponent(item, "fueled") or self:HasComponent(item, "perishable")) then
        return false
    end
    if not (self:HasComponent(item, "insulator")
            or self:HasComponent(item, "waterproofer")
            or item:HasTag("waterproofer")) then
        return false
    end
    return true
end

function ItemUtil:IsClothingHat(item)
    if not item then return false end
    return self:IsCloth(item) and self:GetEquipSlot(item) == EQUIPSLOTS.HEAD
end

function ItemUtil:IsClothingBody(item)
    if not item then return false end
    -- 布料物品中非头帽(HEAD)非手部(HANDS)的才算身体衣物；
    -- 手部绝缘物（如薇洛专属伯尼，槽位 HANDS、restrictedtag="bernieowner"）只算手部装备，不能误当身体衣服自动换上。
    -- 用"排除头/手"而非写死 BODY，兼容多格装备栏（身体衣物可能落在自定义槽位，见 InventoryUtil:DetectEquipSlot）。
    return self:IsCloth(item)
        and not self:IsClothingHat(item)
        and self:GetEquipSlot(item) ~= EQUIPSLOTS.HANDS
end

-- 获取物品的防水值（waterproofer 组件或缓存），客户端用缓存（components 为 nil）。
-- 与 autocloth 共用的雨具判定基础；0 表示不防水。
function ItemUtil:GetWaterproofValue(item)
    if not item then return 0 end
    if item.components and item.components.waterproofer then
        return item.components.waterproofer:GetEffectiveness() or 1
    end
    local c = CacheService:GetCachedItem(item)
    if c and c.waterproofer then
        return c.waterproofer.effectiveness or 1
    end
    return 0
end

-- 雨具（手持雨伞或身体雨衣）：有 waterproofer 组件即视为可防雨，按防水值统一比较，不区分槽位/单独类别。
-- 与 autocloth 共用；取槽位走 ItemUtil:GetEquipSlot（replica），客户端 components 为 nil 也安全。
function ItemUtil:IsRainGear(item)
    if not item then return false end
    local slot = self:GetEquipSlot(item)
    if slot ~= EQUIPSLOTS.BODY and slot ~= EQUIPSLOTS.HANDS then return false end
    return self:GetWaterproofValue(item) > 0
end

-- ===== CONTAINER =====

function ItemUtil:IsBackpack(item)
    if not item then return false end
    if self:HasComponent(item, "finiteuses") or self:HasComponent(item, "perishable") then
        return false
    end
    if EQUIPSLOTS and EQUIPSLOTS.BACK and self:GetEquipSlot(item) == EQUIPSLOTS.BACK then
        return true
    end
    if item:HasTag("backpack") then return true end
    if self:HasComponent(item, "container") then
        return self:GetEquipSlot(item) == EQUIPSLOTS.BODY
    end
    return false
end

-- ===== 多格装备栏通用适配 =====
-- 判定把某物品装到其目标装备槽是否会顶掉背包。
-- 核心原则：仅当背包与目标物品"共用同一装备槽"时才冲突。
--   原版：背包占 BODY 槽（overflow），与身体衣物/护甲/护符冲突 → 不装备以保背包；
--   多格栏：背包被独立到别的槽（如 EQUIPSLOTS.BACK），与身体物品共存 → 正常装备。
-- 所有自动装备模块（衣物/护甲/护符…）统一调用此处，避免各模块各自写背包守卫、逻辑漂移。

-- 给定目标槽位，背包是否正占用它（占用则装备该槽物品会顶掉背包）
function ItemUtil:BackpackConflictWithSlot(target_slot)
    if not target_slot then return false end
    local backpack = InventoryUtil:FindEquipped(function(item)
        return ItemUtil:IsBackpack(item)
    end)
    if not backpack then return false end
    return self:GetEquipSlot(backpack) == target_slot
end

-- 把 item 装到其目标槽是否会顶掉背包（item 缺省按 BODY 槽处理）
function ItemUtil:WouldDisplaceBackpack(item)
    local slot = item and self:GetEquipSlot(item) or EQUIPSLOTS.BODY
    return self:BackpackConflictWithSlot(slot)
end

-- ===== MAGIC =====

function ItemUtil:IsStaff(item)
    if not item then return false end
    return (item.prefab and item.prefab:find("staff") ~= nil)
        or item:HasTag("spellcaster")
end

function ItemUtil:IsAmulet(item)
    if not item then return false end
    return item.prefab and item.prefab:find("amulet") ~= nil
end

-- ===== MEDAL =====

function ItemUtil:IsMedal(item)
    if not item then return false end
    return item:HasTag("medal")
        or item:HasTag("multivariate_certificate")
        or (EQUIPSLOTS and EQUIPSLOTS.MEDAL and self:GetEquipSlot(item) == EQUIPSLOTS.MEDAL)
end

-- ===== OTHER =====

function ItemUtil:IsForgeRepairable(item)
    if not item then return false end
    for _, v in pairs(FORGEMATERIALS) do
        if item:HasTag("forgerepairable_" .. v) then return true end
    end
    return false
end

-- 勋章不朽/可修补类：耐久归0不消失，直接打坏后由勋章自身的修复/重铸流程处理，不应被自动卸下/换下。
-- 与 base-game 锻造类（亮茄/虚空套装，MakeForgeRepairable + 对应修复套件）同理。
-- 判定（详见勋章模组 1909182187）：
--   * isimmortal 标签 = "耐久归0不消失"的真实标记，由 medal_immortal 组件升级（level>0）时 AddTag，
--     且 onfinished 仅对带此标签的装备做"不移除"处理（medal_globalfn.lua）。
--   * medal_repair_common = 通用"可补充耐久"修补列表；medal_repair_immortal = 不朽专属修补列表。
--   后两者仅表示"可修补"，语义不同于真正的 isimmortal 不朽，但都应排除自动卸下（卸下无意义）。
-- 勋章装备修复：medal_repair_common 字段（server-side，未同步到客户端）缺省时回退到本地缓存。
-- 作为 ItemUtil 方法，供 GetRepairTypes 等调用点以 self:GetMedalRepairCommon(item) 使用。
function ItemUtil:GetMedalRepairCommon(item)
    if item.medal_repair_common then return item.medal_repair_common end
    local c = self:GetCachedItem(item)
    return c and c.medal_repair_common or nil
end

local function HasMedalRepairCommon(self, item)
    return self:GetMedalRepairCommon(item) ~= nil
end

local function HasMedalRepairImmortal(self, item)
    if item.medal_repair_immortal then return item.medal_repair_immortal end
    local c = self:GetCachedItem(item)
    return c and c.medal_repair_immortal or nil
end

function ItemUtil:IsMedalUndying(item)
    if item == nil then return false end
    if item:HasTag("isimmortal") then return true end
    return HasMedalRepairCommon(self, item) or HasMedalRepairImmortal(self, item)
end

function ItemUtil:IsRepairable(item)
    if self:IsForgeRepairable(item) then return true end
    for _, v in pairs(MATERIALS) do
        if item:HasTag("repairable_" .. v) then return true end
    end
    if item:HasTag("needssewing") then return true end

    local cachedItem = self:GetCachedItem(item)
    if item.prefab == "molehat" then return true end
    if HasMedalRepairCommon(self, item) then return true end
    if self:IsMedal(item) and self:HasComponent(item, "finiteuses") and HasMedalRepairCommon(self, item) then return true end
    if cachedItem then
        if cachedItem.fueled
            and not cachedItem.fueled.no_sewing
            and cachedItem.fueled.fueltype ~= FUELTYPE.BURNABLE then
            return true
        end
        if cachedItem.has.forgerepairable
            or cachedItem.has.repairable then
            return true
        end
    end
    return false
end

-- 检查物品是否已耗尽耐久不可自动装备
-- 勋章：只拦截可修补勋章（medal_repair_common），不可修补放行；正义勋章特殊放行
-- 通用：<=3% 的"提前判损"只用于有自动维护路径（可修补）的物品，以便换下修补；
--       不可修补/不可补燃料的物品（如不可修补武器）一直可用到真正 broken 标签(0%)，3% 不应拦截
--       ——否则会出现"按钮里显示、但攻击无法自动装备"的错位（见 autoweapon 的 IsBroken 过滤）。
function ItemUtil:IsBroken(item)
    if not item then return false end
    -- 锻造/打坏类装备：耐久归零被打上 broken 标签，完全不可用，直接视为损坏排除出候选列表
    if item:HasTag("broken") then return true end
    if not self:HasComponent(item, "finiteuses") then return false end
    if self:GetPercentUsed(item) > 3 then return false end
    if self:IsMedal(item) then
        if item.prefab == "justice_certificate" then return false end
        if not HasMedalRepairCommon(self, item) then return false end
        return true
    end
    -- 不可修补（无自动维护路径）的物品：3% 仍可用，用到真正 broken 才排除，不在 3% 误拦
    if not self:CanAutoRepair(item) then
        return false
    end
    return true
end

function ItemUtil:IsFuelable(item)
    if not item then return false end
    for _, tag in pairs(FUELTYPE) do
        if item:HasTag(tag .. "_fueled") then
            return true
        end
    end
    return false
end

function ItemUtil:GetMaintenanceKind(item)
    if not item then return "none" end
    local hasFuel = self:IsFuelable(item)
    local hasRepair = self:IsRepairable(item)
    local hasFeed = self:IsFeedable(item)
    if hasFuel and hasRepair then
        return "both"
    elseif hasFuel then
        return "refuel"
    elseif hasRepair then
        return "repair"
    elseif hasFeed then
        return "feed"
    end
    return "none"
end

function ItemUtil:GetMaintenanceProfile(item)
    if not item then
        return {
            kind = "none",
            canRefuel = false,
            canRepair = false,
            canFeed = false,
            fuelTypes = {},
            repairTypes = {},
            feedTypes = {},
        }
    end

    local fuelTypes = self:GetFuelOnlyTypes(item)
    local repairTypes = self:GetRepairOnlyTypes(item)
    local feedTypes = self:GetFeedTypes(item)
    local profile = {
        kind = self:GetMaintenanceKind(item),
        canRefuel = self:IsFuelable(item) and #fuelTypes > 0,
        canRepair = self:IsRepairable(item) and #repairTypes > 0,
        canFeed = self:IsFeedable(item) and #feedTypes > 0,
        fuelTypes = fuelTypes,
        repairTypes = repairTypes,
        feedTypes = feedTypes,
    }
    return profile
end

function ItemUtil:CanAutoRefuel(item)
    return self:IsFuelable(item) and #self:GetFuelOnlyTypes(item) > 0
end

function ItemUtil:CanAutoRepair(item)
    return self:IsRepairable(item) and #self:GetRepairOnlyTypes(item) > 0
end

-- 物品是否属于「维护域」：光源/可修复，或本身是燃料/锻造修复材料/修复材料
-- 供库存扫描预筛使用——先按此谓词过滤，避免对无关物品逐个走 GetMaintenanceProfile
-- （原为 autorepair 内部的 IsFuelOrRepairRelated，收编至此：纯谓词、无状态、无事件）
-- @return: item 为 nil 时返回 true（调用方在事件回调里可能拿不到 item，此时不做预筛、交由下游判定）
function ItemUtil:IsMaintenanceRelated(item)
    if not item then return true end
    if self:IsLightSource(item) or self:IsRepairable(item) then
        return true
    end
    for _, tag in pairs(FUELTYPE) do
        if item:HasTag(tag .. "_fuel") then return true end
    end
    for _, v in pairs(FORGEMATERIALS) do
        if item:HasTag("forgerepair_" .. v) then return true end
    end
    for _, v in pairs(MATERIALS) do
        if item:HasTag("repairer") then return true end
    end
    return false
end

ItemUtil.MaintenanceStrategies = {
    refuel = function(self, item)
        local profile = self:GetMaintenanceProfile(item)
        if not profile.canRefuel then
            return nil
        end
        return self:GetFuelItem(profile.fuelTypes)
    end,
    repair = function(self, item)
        local profile = self:GetMaintenanceProfile(item)
        if not profile.canRepair then
            return nil
        end
        return self:GetRepairItem(profile.repairTypes)
    end,
    feed = function(self, item)
        local profile = self:GetMaintenanceProfile(item)
        if not profile.canFeed then
            return nil
        end
        return self:GetFeedItem(profile.feedTypes)
    end,
}

function ItemUtil:ResolveMaintenanceStrategy(item)
    local profile = self:GetMaintenanceProfile(item)
    local actions = {}
    if profile.canRefuel then
        actions[#actions + 1] = "refuel"
    end
    if profile.canRepair then
        actions[#actions + 1] = "repair"
    end
    if profile.canFeed then
        actions[#actions + 1] = "feed"
    end
    return actions
end

function ItemUtil:ShouldAutoUnequip(item)
    if not item then
        return false
    end

    if self:GetPercentUsed(item) > self:GetFiniteUses(item) then
        return false
    end

    if self:IsForgeRepairable(item) or self:IsMedalUndying(item) then
        return false
    end

    local profile = self:GetMaintenanceProfile(item)
    if profile.kind == "none" then
        return false
    end

    if profile.canRefuel and self:GetFuelItem(profile.fuelTypes) then
        return false
    end

    if profile.canRepair then
        if self:GetRepairItem(profile.repairTypes) then
            return false
        end
        for _, rt in ipairs(profile.repairTypes) do
            if rt.cat == "forge" then
                return false
            end
        end
    end

    if profile.canFeed then
        local food, _ = self:GetFeedItem(profile.feedTypes)
        if food then
            return false
        end
    end

    return true
end

-- 通用：补燃料/修复成功后尝试自动重新装备物品
-- 各自动模块（武器/护符/护甲等）统一通过此入口完成"卸下→补燃料→重装备"闭环
-- @param item 刚补完燃料或修复完成的物品
-- @return true=已装备, false=未装备（槽位被占用/物品不可用/配置未开启）
function ItemUtil:TryReEquipFuelable(item)
    if not item or not item:IsValid() then return false end
    if self:IsBroken(item) or self:ShouldAutoUnequip(item) then return false end

    local eslot = self:GetEquipSlot(item)
    if not eslot then return false end

    local InventoryUtil = require "util/inventoryutil"
    if InventoryUtil:GetEquippedItem(eslot) then return false end

    return InventoryUtil:Equip(item, true)
end

function ItemUtil:IsTerraformer(item)
    return false
end

function ItemUtil:HasComponent(item, component_name)
    local cachedItem = self:GetCachedItem(item)
    if cachedItem then
        if cachedItem[component_name] then return true end
        if cachedItem.has and cachedItem.has[component_name] then return true end
        return false
    end
    return item.components and item.components[component_name] ~= nil
end

function ItemUtil:HasToolAction(item, action_id)
    local cachedItem = self:GetCachedItem(item)
    return cachedItem and cachedItem.tool
        and cachedItem.tool.actions[action_id] ~= nil
end

function ItemUtil:IsDeployable(item, owner)
    local inventoryitem = item and item.replica and item.replica.inventoryitem
    owner = owner or ThePlayer
    return inventoryitem ~= nil
        and owner ~= nil
        and inventoryitem:IsDeployable(owner)
end

-- 部署限制标签：可部署物品中"必须由具备某标签的角色才能部署"的那类。
--   handyperson → 薇诺娜工程物（发电机/聚光灯/投石机等）：巧手勋章佩戴后赋予该标签
--   masterchef  → 便携厨具（烹饪锅/香料站/研磨器）：厨师勋章组佩戴后赋予该标签
-- 客户端可用：读的是 replica 的 classified 网络变量，不依赖服务端组件。
--
-- 关键：deployrestrictedtag 是 **net_hash**（inventoryitem_classified.lua:204）。
--   net_hash 写入时可以用字符串（自动转 hash），但**读出来永远是 hash 数字**
--   （netvars.lua 文档：net_hash ... only returns the hash value when read）。
--   所以 :value() 拿到的是数字，拿它 == "handyperson" 恒为 false——
--   这曾让薇诺娜工程物/便携厨具在本模组里完全识别不出来（quickdeploy 与 automedal 同坑）。
-- 好消息：HasTag 接受 hash——官方 inventoryitem_replica.lua:292 正是把
--   deployrestrictedtag:value() 直接喂给 deployer:HasTag(restrictedtag)。
--   故"玩家是否已具备该标签"直接传 hash 即可，无需还原成字符串。
-- 返回限制标签的 hash（可直接喂 HasTag）；非受限部署物返回 nil（含官方的 0 哨兵）。
function ItemUtil:GetDeployRestrictedTag(item)
    local classified = self:GetClassified(item)
    if classified == nil or classified.deployrestrictedtag == nil then
        return nil
    end
    local tag = classified.deployrestrictedtag:value()
    -- 官方以 0 表示"无限制"（inventoryitem_replica.lua:324 set(restrictedtag or 0)）
    if tag == nil or tag == 0 or tag == "" then
        return nil
    end
    return tag
end

-- 标签名 → net_hash 数值：把本模组关心的标签名与 GetDeployRestrictedTag 的结果做比较。
-- 只有在"需要按标签名分派勋章组"时才要这层转换；判定玩家是否具备标签不需要（见上）。
-- 惰性计算 + 记忆化：smallhash 是引擎提供的全局，加载期未必可取，首次用到时再算。
--
-- 取法必须用 rawget(_G, ...)，不能读 GLOBAL：
--   本文件是 require 加载的，跑在**游戏全局环境**（带 strict.lua，读未声明的全局变量会直接报错），
--   而 GLOBAL 是 mod 环境独有的字段，那里根本没有——裸读会报
--   "variable 'GLOBAL' is not declared"。游戏全局（smallhash / SendRPCToServer /
--   MOD_EQUIPMENT_CONTROL 等）才能裸读，见本文件对 MOD_EQUIPMENT_CONTROL 的使用。
--   用 rawget 还能绕开 strict 的 __index，即便 smallhash 缺失也只是取到 nil 而非崩溃。
local restricted_tag_hashes = {}
local smallhash_warned = false

-- 定位引擎全局 smallhash。全程用 rawget，绝不裸读未声明的全局（会撞 strict.lua 报错）。
-- 两种环境形态都要覆盖：
--   ① _G 就是游戏全局表 → 直接 rawget(_G, "smallhash")
--   ② _G 是 mod 环境（只挂 __index 回退到游戏全局）→ smallhash 不在它自己表上，
--      真正的全局表在它的 GLOBAL 字段里，故再查 rawget(_G, "GLOBAL")
local function FindSmallHash()
    local g = type(_G) == "table" and _G or nil
    if g == nil then return nil end
    local f = rawget(g, "smallhash")
    if type(f) == "function" then return f end
    local G = rawget(g, "GLOBAL")
    if type(G) == "table" then
        f = rawget(G, "smallhash")
        if type(f) == "function" then return f end
    end
    return nil
end

local function TagHash(tag_name)
    local v = restricted_tag_hashes[tag_name]
    if v == nil then
        local smallhash = FindSmallHash()
        if smallhash == nil then
            -- 取不到就静默停用本判定（避免刷屏，只提示一次）
            if not smallhash_warned then
                smallhash_warned = true
                print("[Equipment Control] 警告：取不到 smallhash，部署限制标签判定不可用")
            end
            return nil
        end
        v = smallhash(tag_name) or false
        restricted_tag_hashes[tag_name] = v
    end
    return v ~= false and v or nil
end

--- 物品是否被限定为"仅具备 tag_name 标签者可部署"
--- @param item EntityScript
--- @param tag_name string 标签名（如 "handyperson" / "masterchef"）
function ItemUtil:IsDeployRestrictedTo(item, tag_name)
    local tag = self:GetDeployRestrictedTag(item)
    local want = TagHash(tag_name)
    return tag ~= nil and want ~= nil and tag == want
end

function ItemUtil:IsPerishSpoiled(item)
    return self:GetPerish(item) == 0
end

local MEDAL_BOOK_PREFABS = {
    closed_book = true,
    immortal_book = true,
    monster_book = true,
    unsolved_book = true,
    trapreset_book = true,
    autotrap_book = true,
    medal_plant_book = true,
}

function ItemUtil:IsBook(item)
    if not item then return false end
    -- 排除 closed_book(合上的书)、cookbook(烹饪书)、waxwelljournal(暗影秘典/麦斯威尔秘典)：
    -- 暗影秘典是法术书（召唤暗影仆从），非智慧阅读，且其阅读动作为自定义、无标准 action.code，
    -- 若被当作普通书接管发标准 RPC 会 code=nil 崩溃，故从书本判定中排除、交游戏原生右键。
    if item.prefab == "closed_book" or item.prefab == "cookbook" or item.prefab == "waxwelljournal" then return false end
    return item:HasTag("book") or item.components.book ~= nil or MEDAL_BOOK_PREFABS[item.prefab]
end

function ItemUtil:IsSlingshot(item)
    if not item then return false end
    -- 放宽到"弹弓类"而非只认原生弹弓：带上 slingshot 标签，或 prefab 以 slingshot 开头，
    --   这样"不妥协"等模组改版/新增的弹弓也能被童心勋章快速动作接管。
    -- 排除弹药（slingshotammo_*）：装备弹药不需要童心勋章，纳入只会造成多余的勋章切换。
    if item:HasTag("slingshot") then return true end
    local prefab = item.prefab
    if type(prefab) ~= "string" then return false end
    return prefab:sub(1, 9) == "slingshot" and prefab:sub(1, 13) ~= "slingshotammo"
end

function ItemUtil:IsSleeping(inst)
    return inst.AnimState
        and (inst.AnimState:IsCurrentAnimation("sleep_pre")
            or inst.AnimState:IsCurrentAnimation("sleep_loop")
            or inst.AnimState:IsCurrentAnimation("sleep_pst"))
end

function ItemUtil:IsFrozen(inst)
    return inst.AnimState
        and (inst.AnimState:IsCurrentAnimation("frozen")
            or inst.AnimState:IsCurrentAnimation("frozen_loop_pst"))
end

-- =============================================
-- 同类归并（morph）：把"同类但 prefab 不同"的物品视为同一类
-- ---------------------------------------------
-- 用途：批量转移 / 连续丢弃 / 排序分组等"匹配同类物品"的口径。
--   例如开启后 Shift+双击一颗红宝石会带走所有宝石，而不是只带走红宝石。
-- 实现参考 Lazy Controls 的 main/morph_checker.lua（按 prefab 清单分组 + 每类开关）。
-- 这里统一收到 ItemUtil，并用**惰性建表**：首次使用时才构建，避免加载期
-- require 官方 prefab 文件（weed_defs / winter_ornaments 等）的时序问题。
-- 开关：配置 SAME_KIND_MERGE（默认开启，同类物品按归并组匹配；关闭则退化为按 prefab 精确匹配）。
--
-- 【版本更新韧性：三层判定，按可靠性从高到低】
--   1) 官方专一 tag（MORPH_TAGS）：Klei 新增同类物品会自动带上官方 tag，
--      清单零维护。已逐个核对 tag 在官方源码中的"出现文件数"，只收专一的。
--   2) 游戏数据表派生：VEGGIES / NUM_TRINKETS / NUM_HALLOWEEN* / NUM_WINTERFOOD /
--      weed_defs —— 版本新增蔬菜/小玩具/挂饰会自动纳入。
--   3) 静态 prefab 清单（MORPH_PRESETS）：仅用于"没有安全共用 tag"的组。
--      这些组若改用 tag 会误并（见下面各组注释，如 wet 会并进一切湿物）；
--      清单漏掉新物品的最坏后果只是"没被归并"，不会误并，属安全降级。
-- =============================================

-- 静态分组（不依赖游戏常量的部分）
-- 注意：以下只保留"没有安全共用 tag"的组；能靠官方 tag 判定的已移到下面的 MORPH_TAGS。
--
-- 【重要】归并组同时服务两类场景，**不要因为"不是物品栏物品"就删掉某些组**：
--   ① 物品栏：批量转移 / 连续丢弃时的"同类匹配"；
--   ② 世界实体：适配排队论类模组（Action Queue Reborn，workshop 2873533916）——
--      框选/樱桃拾取时用"同类"把周围同款实体一起选中（同类树、石笋、雕像、孢子…）。
--      Lazy Controls 的 morph_checker 在 aq_changes.lua 里正是这样用的
--      （IsRightItem(ent.prefab, self.last_click.prefab)，ent 为世界实体）；
--      本模组 automedal.lua 也已做排队论的 DoAction / RPC 层适配。
--   所以 spores / trees / ancient_statues / boat_fragments / stalagmite 这几组
--   虽然不进物品栏，但对排队论选实体是必需的，必须保留。
local MORPH_PRESETS = {
    spores = { "spore_tall", "spore_medium", "spore_small" },
    recipe_papers = { "blueprint", "sketch", "tacklesketch" },  -- 三者 tag 各不相同，无共用
    trees = { "evergreen", "evergreen_sparse", "deciduoustree", "twiggytree" },  -- "tree" 出现于 20 个文件，过泛
    -- chessjunk1/2/3 已改由 MORPH_TAGS 的 "chess" tag 覆盖，此处不再列清单
    -- "statue" 会并进大理石雕像/格罗姆雕像等 12 类，过泛 → 用清单
    ancient_statues = { "ruins_statue_head", "ruins_statue_head_nogem",
                        "ruins_statue_mage", "ruins_statue_mage_nogem" },
    -- 船碎片只有 "wet"（并进一切湿物）→ 用清单
    boat_fragments = { "boatfragment03", "boatfragment04", "boatfragment05" },
    -- 石笋只有 "boulder"（并进岩石等 11 类）→ 用清单
    stalagmite = { "stalagmite", "stalagmite_full", "stalagmite_med", "stalagmite_low" },
    stalagmite_tall = { "stalagmite_tall", "stalagmite_tall_full",
                        "stalagmite_tall_med", "stalagmite_tall_low" },
}

-- 官方共用 tag：两物都带同一 tag 即归为同类（tag 由官方维护，新物品自动跟进，清单零维护）。
--   gem                gem.lua 里循环给各色宝石打（含未来的 preciousgem）→ 新宝石自动跟进
--   deerantler         deer_antler.lua → 鹿角 1/2/3
--   singingshell       singingshell.lua → 共鸣贝壳 octave3/4/5
--   gargoyle           gargoyles.lua → 各类月光石像
--   weed               weed_plants.lua → 各种杂草
--   halloween_ornament halloween_ornaments.lua → 万圣节挂饰
--   halloweencandy     halloweencandy.lua → 万圣节糖果
--   wintersfeastfood   wintersfeastfood.lua → 冬季盛宴食物
--   chess              chessjunk + bishop/knight/rook（地面发条残骸 + 地下遗迹棋子，
--                      范围偏宽、跨地面/地下，但用户接受：优先用官方 tag，避免硬编码 prefab）
--   winter_ornament    winter_ornaments.lua → 冬季挂饰（含节日彩灯；需排除冬季食物，见下）
--
-- 关于"过并"的风险：真正在箱子里的物品量有限，"并多了"的实际影响远小于理论物品全集，
-- 故上面这些相对宽的方案可接受。
--
-- 已评估后**不采用**的 tag：cattoy(65 文件，几乎涵盖所有小杂物)、molebait(32，所有矿石)、
--   tree(20，都是世界实体)、lightbattery(6，灯泡/萤光虫/光蟹/光蝇彼此毫无关系)、
--   wet(15)、boulder(11)、statue(12)、shell(2，是蜗牛壳护甲不是共鸣贝壳)
local MORPH_TAGS = {
    "gem", "deerantler", "singingshell", "gargoyle", "weed",
    "halloween_ornament", "halloweencandy", "wintersfeastfood",
    "chess", "winter_ornament",
}

-- 用"排除 tag"收窄某些组：带排除 tag 的物品不参与该组归并。
-- winter_ornament 里混进了冬季盛宴食物（它们也带 winter_ornament），
-- 排除 wintersfeastfood 之后剩下的才是纯挂饰。
local MORPH_TAG_EXCLUDES = {
    winter_ornament = "wintersfeastfood",
}

-- 注：官方也把 hermit_pearl（寄居蟹珍珠）标了 "gem"（宝石插座用途），
-- 严格说它不属于"各色宝石"；但它是**世界唯一**物品，实际不会与宝石同时大量出现，
-- 属边缘效应，不做排除（保持代码简单）。

local _morph_table = nil   -- prefab -> group_id

local function MorphRange(base, from, to)
    local t = {}
    for i = from, to do t[#t + 1] = base .. i end
    return t
end

local function MorphAddGroup(id, list)
    for _, prefab in ipairs(list) do
        _morph_table[prefab] = id
    end
end

local function BuildMorphTable()
    _morph_table = {}
    local id = 0
    local function next_id() id = id + 1 return id end

    for _, list in pairs(MORPH_PRESETS) do
        MorphAddGroup(next_id(), list)
    end

    -- 动态分组：依赖游戏常量/表，取不到就跳过（不影响其它分组）
    if NUM_TRINKETS ~= nil then
        local trinkets = MorphRange("trinket_", 1, NUM_TRINKETS)
        trinkets[#trinkets + 1] = "antliontrinket"
        MorphAddGroup(next_id(), trinkets)
        _morph_table["trinket_6"] = nil  -- Frazzled Wires 不并入（同 Lazy）
    end
    if NUM_HALLOWEEN_ORNAMENTS ~= nil then
        MorphAddGroup(next_id(), MorphRange("halloween_ornament_", 1, NUM_HALLOWEEN_ORNAMENTS))
    end
    if NUM_HALLOWEENCANDY ~= nil then
        MorphAddGroup(next_id(), MorphRange("halloweencandy_", 1, NUM_HALLOWEENCANDY))
    end
    if NUM_WINTERFOOD ~= nil then
        MorphAddGroup(next_id(), MorphRange("winter_food", 1, NUM_WINTERFOOD))
    end

    -- 种子 / 种下的菜 / 巨大蔬菜：由 VEGGIES 表推导
    if VEGGIES ~= nil then
        local seeds, plants, giants = { "seeds" }, { "farm_plant_randomseed" }, {}
        for name in pairs(VEGGIES) do
            seeds[#seeds + 1] = name .. "_seeds"
            plants[#plants + 1] = "farm_plant_" .. name
            giants[#giants + 1] = name .. "_oversized"
        end
        MorphAddGroup(next_id(), seeds)
        MorphAddGroup(next_id(), plants)
        MorphAddGroup(next_id(), giants)
    end

    -- 杂草：由 weed_defs 推导（pcall 保护，取不到不影响其它分组）
    local ok, weed_defs = pcall(require, "prefabs/weed_defs")
    if ok and type(weed_defs) == "table" and weed_defs.WEED_DEFS then
        local weeds = {}
        for k in pairs(weed_defs.WEED_DEFS) do weeds[#weeds + 1] = k end
        MorphAddGroup(next_id(), weeds)
    end

    return _morph_table
end

-- 取 prefab（兼容传物品实例或 prefab 字符串）
local function MorphPrefabOf(x)
    return type(x) == "table" and x.prefab or x
end

-- 归并开关：配置 SAME_KIND_MERGE
function ItemUtil:IsSameKindMergeEnabled()
    if MOD_EQUIPMENT_CONTROL ~= nil and MOD_EQUIPMENT_CONTROL.MODNAME ~= nil then
        return GetModConfigData("SAME_KIND_MERGE", MOD_EQUIPMENT_CONTROL.MODNAME) and true or false
    end
    return GetModConfigData("SAME_KIND_MERGE") and true or false
end

-- 物品所属归并组（不属于任何组返回 nil）
function ItemUtil:GetMorphGroup(item_or_prefab)
    if _morph_table == nil then BuildMorphTable() end
    local prefab = MorphPrefabOf(item_or_prefab)
    return prefab ~= nil and _morph_table[prefab] or nil
end

-- 两个物品是否视为"同一类"：同一 prefab 恒为 true；
-- 归并组相同则需在 SAME_KIND_MERGE 开启时才算同类
function ItemUtil:IsSameKind(a, b)
    local pa, pb = MorphPrefabOf(a), MorphPrefabOf(b)
    if pa == nil or pb == nil then return false end
    if pa == pb then return true end
    if not self:IsSameKindMergeEnabled() then return false end

    -- 1) 官方专一 tag（对物品实例判定；若传的是 prefab 字符串则走下面的清单）
    if type(a) == "table" and type(b) == "table" then
        for _, tag in ipairs(MORPH_TAGS) do
            if a:HasTag(tag) and b:HasTag(tag) then
                -- 该组若配了排除 tag，任一带排除 tag 则不并入本组
                local ex = MORPH_TAG_EXCLUDES[tag]
                if ex == nil or not (a:HasTag(ex) or b:HasTag(ex)) then
                    return true
                end
            end
        end
    end

    -- 2) prefab 归并组：静态清单 + 由游戏数据表派生
    if _morph_table == nil then BuildMorphTable() end
    local ga, gb = _morph_table[pa], _morph_table[pb]
    return (ga ~= nil and ga == gb) or false
end

-- ===========================================================================
-- ===== COOKING INGREDIENTS =====
-- ===========================================================================
-- 官方 cooking.ingredients / cooking.recipes 是权威数据源，且会被模组通过
-- AddIngredientValues / AddCookerRecipe 动态改写（甚至直接覆盖 recipe.test）。
-- 这里只放查询与分类函数，不复制一份官方数据表，避免与启用模组失配。

local cooking = require("cooking")

-- cooking.lua 的 prefab->ingredient 别名表是 local，这里镜像官方三条例外
ItemUtil.COOKING_ALIASES = {
    cookedsmallmeat   = "smallmeat_cooked",
    cookedmonstermeat = "monstermeat_cooked",
    cookedmeat        = "meat_cooked",
}

function ItemUtil:AliasIngredient(prefab)
    return ItemUtil.COOKING_ALIASES[prefab] or prefab
end

function ItemUtil:IsCookingIngredient(prefab)
    return prefab ~= nil
        and cooking.ingredients[self:AliasIngredient(prefab)] ~= nil
end

function ItemUtil:GetIngredientTags(prefab)
    local data = cooking.ingredients[self:AliasIngredient(prefab)]
    return data ~= nil and (data.tags or {}) or nil
end

-- 食材度统一接口：按 tag 名读数值，不持有任何档位条例。
-- 数据源始终是官方 cooking.ingredients，工坊 mod 通过全局 AddIngredientValues
-- 注册的食材 / 自定义 tag 会自动进来；tag 不存在返回 0，调用方可直接做数值比较。
function ItemUtil:GetIngredientTagValue(prefab, tag, tags)
    if prefab == nil or tag == nil then
        return 0
    end
    tags = tags or self:GetIngredientTags(prefab)
    return tags ~= nil and (tags[tag] or 0) or 0
end

local function IngredientTagSignature(tags)
    local keys = {}
    for k in pairs(tags) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, k .. "=" .. tostring(tags[k]))
    end
    return table.concat(parts, ",")
end

-- 「食材本质」：tag 权重表相同即对 recipe.test 不可区分。
-- 调用方需自行排除被 test 按名字读取的具名食材。
function ItemUtil:GetIngredientTagSignature(prefab)
    local tags = self:GetIngredientTags(prefab)
    return tags ~= nil and IngredientTagSignature(tags) or nil
end

function ItemUtil:IsSameIngredientKind(a, b)
    local sa, sb = self:GetIngredientTagSignature(a), self:GetIngredientTagSignature(b)
    return sa ~= nil and sa == sb
end

return ItemUtil