local CacheService, Cache = {}, {}
local NegativeCache = {}

local function CacheItem(item)
    if not item then return end
    local c = {}
    local comps = item.components

    -- Weapon
    if comps.weapon then
        c.weapon = {
            damage = comps.weapon.damage,
            stimuli = comps.weapon.stimuli,
            can_ranged = comps.weapon:CanRangedAttack() or false,
        }
    end

    -- Planar damage
    if comps.planardamage then
        c.planar_damage = comps.planardamage:GetBaseDamage()
    end

    -- Armor
    if comps.armor then
        c.armor = {
            absorb_percent = comps.armor.absorb_percent,
            maxcondition = comps.armor.maxcondition,
        }
    end

    -- Planar defense
    if comps.planardefense then
        c.planar_defense = comps.planardefense:GetBaseDefense()
    end

    -- Edible
    if comps.edible then
        c.edible = {
            foodtype = comps.edible.foodtype,
            hungervalue = comps.edible.hungervalue,
            sanityvalue = comps.edible.sanityvalue,
            healthvalue = comps.edible.healthvalue,
            degrades_with_spoilage = comps.edible.degrades_with_spoilage,
        }
    end

    -- Healer
    if comps.healer then
        c.healer = { health = comps.healer.health }
    end

    -- Finite uses
    if comps.finiteuses then
        local consumption_per_use = 1
        for _, v in pairs(comps.finiteuses.consumption) do
            consumption_per_use = v
            break
        end
        c.finiteuses = {
            total = comps.finiteuses.total,
            consumption = comps.finiteuses.consumption,
            maxuses = comps.finiteuses.total / consumption_per_use,
        }
    end

    -- Fueled
    if comps.fueled then
        c.fueled = {
            maxfuel = comps.fueled.maxfuel,
            fueltype = comps.fueled.fueltype,
            no_sewing = comps.fueled.no_sewing,
        }
    end

    -- Equippable
    if comps.equippable then
        c.equippable = {
            dapperness = comps.equippable.dapperness or 0,
        }
    end

    -- Insulator
    if comps.insulator then
        c.insulator = {
            insulation = comps.insulator.insulation,
            insulatortype = comps.insulator.type,
        }
    end

    -- Waterproofer
    if comps.waterproofer then
        c.waterproofer = {
            effectiveness = comps.waterproofer:GetEffectiveness(),
        }
    end

    -- Perishable
    if comps.perishable then
        c.perishable = {
            perishtime = comps.perishable.perishtime,
        }
    end

    -- Tool
    if comps.tool then
        c.tool = {
            actions = comps.tool.actions,
        }
    end

    -- Container
    if comps.container then
        c.container = {
            numslots = comps.container.numslots,
        }
    end

    -- Set bonus
    if comps.setbonus then
        c.setbonus = {
            setname = comps.setbonus.setname,
        }
    end

    -- Medal repair common (entity-level table, not a component)
    if item.medal_repair_common then
        c.medal_repair_common = {}
        for prefab, value in pairs(item.medal_repair_common) do
            c.medal_repair_common[prefab] = value
        end
    end
    -- Medal repair immortal (entity-level table, not a component)
    if item.medal_repair_immortal then
        c.medal_repair_immortal = {}
        for prefab, value in pairs(item.medal_repair_immortal) do
            c.medal_repair_immortal[prefab] = value
        end
    end

    -- Pass-through: existence flags only (no component references)
    c.has = {}
    local pass_through = {
        "resistance", "projectile", "complexprojectile",
        "spellcaster", "terraformer", "repairable", "forgerepairable",
        "oar", "fishingrod", "oceanfishingrod", "hoe",
        "tradable",
    }
    for _, name in ipairs(pass_through) do
        if comps[name] then
            c.has[name] = true
        end
    end

    return c
end

local NotAllowed = {
    ["blueprint"] = true,
    ["terrarium"] = true,
}

local function AllowCache(item)
    return item
        and not NotAllowed[item.prefab]
end

function CacheService:GetCachedItem(item)
    if not AllowCache(item) then
        return nil
    end

    if Cache[item.prefab] then
        return Cache[item.prefab]
    end

    if NegativeCache[item.prefab] then
        return nil
    end

    MOD_EQUIPMENT_CONTROL.SPAWNING = true
    local sim = TheWorld and TheWorld.ismastersim
    if TheWorld then
        TheWorld.ismastersim = true
    end

    -- 整段包 pcall：CacheItem 抛错时也必须还原全局标志，否则后续判定会一直以为自己是服务端
    local ok, entry = pcall(function()
        local clone = SpawnPrefab(item.prefab)
        if clone == nil then return nil end
        local data = CacheItem(clone)
        pcall(clone.Remove, clone)
        return data
    end)

    if TheWorld then
        TheWorld.ismastersim = sim
    end
    MOD_EQUIPMENT_CONTROL.SPAWNING = false

    if ok and entry then
        Cache[item.prefab] = entry
    else
        NegativeCache[item.prefab] = true
    end

    return Cache[item.prefab]
end

return CacheService