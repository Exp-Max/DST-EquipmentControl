local MOD_EQUIPMENT_CONTROL = GLOBAL.MOD_EQUIPMENT_CONTROL
local KeybindService = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE
local TheInput = GLOBAL.TheInput
local FileSystem = require "util/filesystem"
local Say = require "util/say"
local ItemUtil = require "util/itemutil"
local TintService = require "util/tintservice"

--
-- Config
--

local Filter_File = "mod_equipment_control_attack_filter.txt"

--
-- Logic
--

local AttackFilters = {}

local function IsAttackFiltered(combat_replica, guy)
    for prefab, fn in pairs(AttackFilters) do
        if fn(guy, prefab, combat_replica) then
            return true
        end
    end

    return false
end

local CustomFilters = {}

local function AddCustomFilter(prefab, fn)
    CustomFilters[prefab] = fn
end

local function DefaultFilter(guy, prefab)
    return guy.prefab == prefab
end

local function GetFilter(prefab)
    return CustomFilters[prefab] or DefaultFilter
end

local function LoadFilter(onLoaded)
    FileSystem:LoadTableFromFile(Filter_File, function(filterList)
        for i = 1, #filterList do
            AttackFilters[filterList[i]] = GetFilter(filterList[i])
        end
        if onLoaded then
            onLoaded()
        end
    end)
end

local function SaveFilter()
    local t = {}

    for prefab in pairs(AttackFilters) do
        t[#t + 1] = prefab
    end

    FileSystem:SaveTableToFile(Filter_File, t)
end

local GroupTags =
{
    wall = true,
    bird = true,
}

local function GetUserID(player)
    return player.userid or player.prefab
end

local TagFuncs =
{
    player = GetUserID
}

local function GetPrefabGroup(ent)
    for tag, fn in pairs(TagFuncs) do
        if ent:HasTag(tag) then
            return fn(ent)
        end
    end

    for tag in pairs(GroupTags) do
        if ent:HasTag(tag) then
            return tag
        end
    end

    return ent.prefab
end

local function AddToFilter(ent)
    local prefab = GetPrefabGroup(ent)

    if not AttackFilters[prefab] then
        AttackFilters[prefab] = GetFilter(prefab)
    else
        AttackFilters[prefab] = nil
    end

    SaveFilter()

    return AttackFilters[prefab]
end

--
-- Helpers
--

--
-- Custom filters
--

AddCustomFilter("wall", function(guy)
    return guy:HasTag("wall")
end)

AddCustomFilter("bird", function(guy)
    return guy:HasTag("bird")
        and not (ItemUtil:IsFrozen(guy) or ItemUtil:IsSleeping(guy))
end)

local attack_filter_inited = false

local function Init(_, player)
    if player ~= GLOBAL.ThePlayer then
        return
    end

    LoadFilter(function()
        for _, ent in pairs(GLOBAL.Ents) do
            if AttackFilters[ent.prefab] then
                TintService:AddColor(ent)
            end
        end
    end)

    if attack_filter_inited then
        return
    end
    attack_filter_inited = true
end

-- 使用 AddComponentPostInit 钩子 combat replica 的 IsAlly
-- inst:HasTag("player") 替代 inst ~= GLOBAL.ThePlayer：ThePlayer 在 PostInit 时可能尚未赋值
AddComponentPostInit("combat", function(self, inst)
    if not inst:HasTag("player") then
        return
    end

    local OldIsAlly = self.IsAlly
    function self:IsAlly(guy, ...)
        return IsAttackFiltered(self, guy)
            or OldIsAlly(self, guy, ...)
    end
end)

local function OnWorldPostInit(inst)
    inst:ListenForEvent("playeractivated", Init, GLOBAL.TheWorld)
end
AddPrefabPostInit("world", OnWorldPostInit)

AddPrefabPostInitAny(TintService:MakeTintIfFiltered(function(inst)
    -- 过滤集合为空时短路（AddPrefabPostInitAny 对每个生成的实体都会回调）
    return next(AttackFilters) ~= nil
        and inst ~= nil
        and inst.prefab ~= nil
        and AttackFilters[inst.prefab] ~= nil
end))

--
-- Keybinds
--

KeybindService:AddKey("ATTACK_FILTER", function()
    local ent = TheInput:GetWorldEntityUnderMouse()

    if ent and ent.replica.health then
        local isAdded = AddToFilter(ent)

        TintService:TintAllByPrefab(ent.prefab, isAdded and true or false)

        Say(
            string.format(
                isAdded
                and MOD_EQUIPMENT_CONTROL.STRINGS.ATTACK_FILTER.ADD
                or MOD_EQUIPMENT_CONTROL.STRINGS.ATTACK_FILTER.REMOVE,
                ent.name
            )
        )
    end
end)