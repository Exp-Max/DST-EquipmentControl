local ItemUtil = require "util/itemutil"

local PriorityUtil = {}

local Settings =
{
    "ARMOR_SORT_PRIORITY",
    "LIGHT_SORT_PRIORITY",
    "STAFF_SORT_PRIORITY",
    "EQUIPMENT_SORT_PRIORITY",
    "FOOD_SORT_PRIORITY",
    "RESOURCE_SORT_PRIORITY",
    "TOOL_SORT_PRIORITY",
}

local function SetSettings()
    for i = #Settings, 1, -1 do
        local key = Settings[i]
        Settings[key] = GetModConfigData(key, MOD_EQUIPMENT_CONTROL.MODNAME)
        Settings[i] = nil
    end
end
SetSettings()

local function IsEquippable(item)
    return item
        and item.replica.equippable
end

local function IsEdible(item)
    return ItemUtil:CanEat(item)
end

local function GetBaseHealthValue(item)
    local cachedItem = ItemUtil:GetCachedItem(item)
    local mult = ItemUtil:GetFoodMultiplier()
    return cachedItem
        and cachedItem.edible
        and math.ceil(cachedItem.edible.healthvalue * mult)
end

local function GetBaseHungerValue(item)
    if item:HasTag("soul") and ThePlayer and ThePlayer:HasTag("souleater") then
        return TUNING.CALORIES_MEDSMALL
    end

    local mult = ItemUtil:GetFoodMultiplier()
    local cachedItem = ItemUtil:GetCachedItem(item)
    return cachedItem
        and cachedItem.edible
        and math.ceil(cachedItem.edible.hungervalue * mult)
end

local cachedPriority = {}
local sortedPrefabNames = nil

-- 官方无稳定的 prefab 序号 API：pairs(Prefabs) 的顺序依赖加载顺序，
-- 这里按名字典序一次性生成确定性排名，仅用作极小权重的同级 tie-break。
local function GetNamePriority(prefab)
    if cachedPriority[prefab] ~= nil then return cachedPriority[prefab] end
    if sortedPrefabNames == nil then
        sortedPrefabNames = {}
        for name in pairs(Prefabs) do
            sortedPrefabNames[#sortedPrefabNames + 1] = name
        end
        table.sort(sortedPrefabNames)
    end
    for i, name in ipairs(sortedPrefabNames) do
        if name == prefab then
            cachedPriority[prefab] = i
            return i
        end
    end
    return 0
end

local Resources =
{
    -- Gems
    "opalpreciousgem",
    "greengem",
    "yellowgem",
    "orangegem",
    "purplegem",
    "bluegem",
    "redgem",

    -- Basic
    "twigs",
    "cutgrass",
    "log",

    -- Ore
    "goldnugget",
    "rocks",
    "flint",
    "nitre",

    -- Refined
    "rope",
    "cutstone",
    "boards",
}

local function GetPriorityRank(v)
    return v * .00001
end

local function GetResourceValue(item)
    local val = 0

    for i = #Resources, 1, -1 do
        val = val + 1
        if item.prefab == Resources[i] then
            return val * .001
        end
    end

    return 0
end

local function IsResource(item)
	for i = 1, #Resources do
		if item.prefab == Resources[i] then
			return true
		end
	end

    return false
end

local function IsTool(item)
    if item:HasTag("tool") then
        return true
    end
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.has and cached.has.terraformer then
        return true
    end
    return false
end

function PriorityUtil:CanOnlyGoInPocket(item)
    return item and item.replica.inventoryitem:CanOnlyGoInPocket()
end

-- 是否为可装备物品（护甲/武器/工具/光源/法杖/护符等）。
-- 归类原则：可装备物优先留在主物品栏（顶背包时不被丢），
-- 原材料/杂物/食物（不可装备）可留在背包。供整理归类与顶背包保护共用。
function PriorityUtil:IsEquippable(item)
    return IsEquippable(item)
end

-- @TODO Refactoring
local function GetPriority(item)
    local priority = 0

    if IsEquippable(item) then
        if IsTool(item) then
            priority = priority + Settings.TOOL_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetPercentUsed(item) * .0000001)
        elseif ItemUtil:IsLightSource(item) then
            priority = priority + Settings.LIGHT_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetMaxFuel(item) + ItemUtil:GetPercentUsed(item) * .0000001)
        elseif ItemUtil:IsStaff(item) then
            priority = priority + Settings.STAFF_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetPercentUsed(item) * .0000001)
        elseif ItemUtil:IsArmor(item) then
            priority = priority + Settings.ARMOR_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetArmor(item) + ItemUtil:GetPercentUsed(item))
            if item.prefab:find("hat") then
                priority = priority + .25
            end
        elseif ItemUtil:IsMeleeWeapon(item) then
            priority = priority + Settings.EQUIPMENT_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetDamage(item, nil, true) + GetPriorityRank(ItemUtil:GetPercentUsed(item)))
        else
            priority = priority + Settings.EQUIPMENT_SORT_PRIORITY
            priority = priority + GetPriorityRank(ItemUtil:GetPercentUsed(item))
        end
    elseif IsEdible(item) then
        priority = priority + Settings.FOOD_SORT_PRIORITY
        if GetBaseHealthValue(item) then
            priority = priority + GetPriorityRank(GetBaseHealthValue(item))
        end
        if GetBaseHungerValue(item) then
            priority = priority + GetPriorityRank(GetBaseHungerValue(item))
        end
    elseif IsResource(item) then
        priority = priority + Settings.RESOURCE_SORT_PRIORITY
        priority = priority + GetResourceValue(item)
    end

    priority = priority + (GetNamePriority(item.prefab) * .00000000001) + (GetPriorityRank(item.GUID) * .00000000001)

    return priority
end

function PriorityUtil:CreatePriorityTable(items)
    local ret = {}

    for _, item in pairs(items) do
        ret[#ret +1] =
        {
            item = item,
            priority = GetPriority(item)
        }
    end

    table.sort(ret, function(a, b)
        return a.priority > b.priority
    end)

    return ret
end

return PriorityUtil