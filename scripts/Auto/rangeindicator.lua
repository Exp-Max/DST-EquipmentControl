--
-- 范围显示模块
-- 鼠标悬停/放置建筑时显示各建筑的范围圈
-- 移植自 Workshop 3441224634 (Cookpot Range Indicator) + 3170953574 (范围显示)
--

if GetModConfigData("RANGEINDICATOR_ENABLED") == false then
    return
end

local COOKPOT_FOOTPRINT = 1
local ICEBOX_FOOTPRINT = 0.75

local ICEBOX_PLACEMENT_RADIUS = 3 + COOKPOT_FOOTPRINT + COOKPOT_FOOTPRINT + 0
local COOKPOT_PLACEMENT_RADIUS = 3 + ICEBOX_FOOTPRINT + ICEBOX_FOOTPRINT + 0

local PLACER_SCALE = 1.5

-- ====== 范围圈创建工具（复刻 范围显示 mod 3170953574） ======
local function CreateHelperRadiusCircle(inst, radius, r, g, b, light)
    local C = CreateEntity()

    C.entity:SetCanSleep(false)
    C.persists = false

    C.entity:AddTransform()
    C.entity:AddAnimState()

    C:AddTag("CLASSIFIED")
    C:AddTag("NOCLICK")
    C:AddTag("placer")

    local scale = math.sqrt(radius * 300 / (1896 - 22))

    C.AnimState:SetAddColour(r, g, b, 0)
    C.Transform:SetScale(scale, scale, scale)

    if light then
        C.AnimState:SetLightOverride(1)
    end

    C.AnimState:SetBank("firefighter_placement")
    C.AnimState:SetBuild("firefighter_placement")
    C.AnimState:PlayAnimation("idle")
    C.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    C.AnimState:SetLayer(LAYER_BACKGROUND)
    C.AnimState:SetSortOrder(3)

    C.entity:SetParent(inst.entity)

    return C
end

-- ====== 通用 OnEnableHelper（placer 自身范围圈） ======
local function MakeOnEnableHelper(create_fn)
    return function(inst, enabled)
        if enabled then
            if inst.helper == nil then
                inst.helper = create_fn(inst)
            end
        elseif inst.helper ~= nil then
            inst.helper:Remove()
            inst.helper = nil
        end
    end
end

-- ====== 为 placer 添加 deployhelper 组件 ======
local function AddDeployHelperToPlacer(prefab_name, create_fn)
    AddPrefabPostInit(prefab_name, function(inst)
        if GLOBAL.TheNet:IsDedicated() then
            return
        end
        if not inst.components.deployhelper then
            inst:AddComponent("deployhelper")
        end
        inst.components.deployhelper.onenablehelper = MakeOnEnableHelper(create_fn)
    end)
end

-- ====== 冰柜/烹饪锅/盐箱 placer 范围圈 ======
AddDeployHelperToPlacer("icebox_placer", function(inst)
    return CreateHelperRadiusCircle(inst, ICEBOX_PLACEMENT_RADIUS, 0, 1, 1, false)
end)

AddDeployHelperToPlacer("saltbox_placer", function(inst)
    return CreateHelperRadiusCircle(inst, ICEBOX_PLACEMENT_RADIUS, 0, 1, 1, false)
end)

AddDeployHelperToPlacer("cookpot_placer", function(inst)
    return CreateHelperRadiusCircle(inst, COOKPOT_PLACEMENT_RADIUS, 1, 1, 0, false)
end)

-- ====== 避雷针 placer 范围圈（防雷半径 = 40） ======
AddDeployHelperToPlacer("lightning_rod_placer", function(inst)
    return CreateHelperRadiusCircle(inst, 40, 1, 1, 0, false)
end)

-- ====== 蘑菇灯 placer 范围圈 ======
AddDeployHelperToPlacer("mushroom_light_placer", function(inst)
    return CreateHelperRadiusCircle(inst, 5.5, 192/255, 192/255, 192/255, true)
end)

AddDeployHelperToPlacer("mushroom_light2_placer", function(inst)
    return CreateHelperRadiusCircle(inst, 5.5, 169/255, 169/255, 169/255, true)
end)

-- ====== 龙蝇火炉 placer 范围圈 ======
AddDeployHelperToPlacer("dragonflyfurnace_placer", function(inst)
    return CreateHelperRadiusCircle(inst, 10, 139/255, 0, 0, false)
end)

-- ====== 眼球塔 placer 范围圈 ======
AddDeployHelperToPlacer("eyeturret_item_placer", function(inst)
    return CreateHelperRadiusCircle(inst, 15, 1, 165/255, 0, false)
end)

-- ====== 夹夹绞盘 placer 范围圈 + 沉底物品水面高亮 ======
local WINCH_DETECT_RANGE = 5
local WINCH_CLAW_RANGE = 2.5

AddDeployHelperToPlacer("winch_placer", function(inst)
    local ring = CreateHelperRadiusCircle(inst, WINCH_CLAW_RANGE, 0/255, 51/255, 128/255, false)

    -- 沉底物品扫描系统
    inst._winch_rings = {}

    local function ClearRings()
        for _, r in pairs(inst._winch_rings) do
            if r:IsValid() then
                r:Remove()
            end
        end
        inst._winch_rings = {}
    end

    local function ScanSunkenItems()
        if not inst:IsValid() then
            ClearRings()
            return
        end

        local player = GLOBAL.ThePlayer
        if not player or not player:IsValid() then
            ClearRings()
            return
        end

        if player:GetCurrentPlatform() == nil then
            ClearRings()
            return
        end

        local wx, _, wz = inst.Transform:GetWorldPosition()
        -- 半径直接用实际检测距离（原来固定 30，随后又按 WINCH_DETECT_RANGE 过滤一遍）
        local sunken_items = GLOBAL.TheSim:FindEntities(wx, 0, wz, WINCH_DETECT_RANGE, { "underwater_salvageable" })

        local current = {}
        for _, v in ipairs(sunken_items) do
            local vx, _, vz = v.Transform:GetWorldPosition()
            if GLOBAL.distsq(wx, wz, vx, vz) <= WINCH_DETECT_RANGE * WINCH_DETECT_RANGE then
                current[v] = GLOBAL.distsq(wx, wz, vx, vz) <= WINCH_CLAW_RANGE * WINCH_CLAW_RANGE
            end
        end

        for entity, r in pairs(inst._winch_rings) do
            if not current[entity] then
                if r:IsValid() then
                    r:Remove()
                end
                inst._winch_rings[entity] = nil
            end
        end

        for entity, in_range in pairs(current) do
            local r = inst._winch_rings[entity]
            if r == nil or not r:IsValid() then
                r = CreateHelperRadiusCircle(entity, WINCH_CLAW_RANGE, 0, 0, 0, false)
                local ex, ey, ez = entity.Transform:GetWorldPosition()
                r.entity:SetParent(entity.entity)
                r.Transform:SetPosition(0, -ey, 0)
                inst._winch_rings[entity] = r
            end

            if in_range then
                r.AnimState:SetAddColour(.25, .75, .25, 0)
            else
                r.AnimState:SetAddColour(.75, .25, .25, 0)
            end
        end
    end

    inst._scan_task = inst:DoPeriodicTask(0.5, ScanSunkenItems)

    local old_OnRemoveEntity = inst.OnRemoveEntity
    inst.OnRemoveEntity = function(...)
        if inst._scan_task then
            inst._scan_task:Cancel()
            inst._scan_task = nil
        end
        ClearRings()
        if old_OnRemoveEntity then
            old_OnRemoveEntity(...)
        end
    end

    return ring
end)

-- 注：灭火器(firesuppressor)、投石机(winona_catapult)、脚手架(support_pillar)
--     游戏本体 placer 已自带范围圈，无需额外添加

-- ====== 建筑 deployhelper（冰柜/烹饪锅/盐箱 互相显示范围） ======
-- 复刻 Cookpot Range Indicator (3441224634) 的 deployhelper 方式
local function CreateDeployHelperRing(inst, range, helper_footprint, r, g, b)
    local ring = CreateEntity()

    ring.entity:SetCanSleep(false)
    ring.persists = false

    ring.entity:AddTransform()
    ring.entity:AddAnimState()

    ring:AddTag("CLASSIFIED")
    ring:AddTag("NOCLICK")
    ring:AddTag("placer")

    ring.AnimState:SetBank("winona_battery_placement")
    ring.AnimState:SetBuild("winona_battery_placement")
    ring.AnimState:PlayAnimation("idle_small")
    ring.AnimState:SetLightOverride(1)
    ring.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    ring.AnimState:SetLayer(LAYER_BACKGROUND)
    ring.AnimState:SetSortOrder(1)

    local scale = PLACER_SCALE * helper_footprint / GLOBAL.TUNING.WINONA_ENGINEERING_FOOTPRINT
    ring.AnimState:SetScale(scale, scale)

    ring.entity:SetParent(inst.entity)

    local function OnUpdatePlacerHelper()
        if not ring.placerinst:IsValid() then
            ring.components.updatelooper:RemoveOnUpdateFn(OnUpdatePlacerHelper)
            ring.AnimState:SetAddColour(0, 0, 0, 0)
        else
            local x, y, z = inst.Transform:GetWorldPosition()
            local px, py, pz = ring.placerinst.Transform:GetWorldPosition()
            if GLOBAL.distsq(x, z, px, pz) <= range * range
                and GLOBAL.TheWorld.Map:GetPlatformAtPoint(x, z)
                    == GLOBAL.TheWorld.Map:GetPlatformAtPoint(px, pz) then
                ring.AnimState:SetAddColour(ring.placerinst.AnimState:GetAddColour())
            else
                ring.AnimState:SetAddColour(0, 0, 0, 0)
            end
        end
    end

    ring:AddComponent("updatelooper")
    ring.components.updatelooper:AddOnUpdateFn(OnUpdatePlacerHelper)
    ring.placerinst = nil

    return ring, OnUpdatePlacerHelper
end

local function MakeBuildingOnEnableHelper(range, helper_footprint, r, g, b)
    return function(inst, enabled, recipename, placerinst)
        if enabled then
            if inst.helper == nil and not inst:HasTag("burnt") then
                local ring, updatefn = CreateDeployHelperRing(inst, range, helper_footprint, r, g, b)
                ring.placerinst = placerinst
                updatefn(ring)
                inst.helper = ring
            end
        elseif inst.helper ~= nil then
            inst.helper:Remove()
            inst.helper = nil
        end
    end
end

local function AddBuildingDeployHelper(prefab_name, recipes, range, helper_footprint, r, g, b)
    AddPrefabPostInit(prefab_name, function(inst)
        if not GLOBAL.TheNet:IsDedicated() then
            inst:AddComponent("deployhelper")
            for _, recipe in ipairs(recipes) do
                inst.components.deployhelper:AddRecipeFilter(recipe)
            end
            inst.components.deployhelper.onenablehelper = MakeBuildingOnEnableHelper(range, helper_footprint, r, g, b)
        end
    end)
end

AddBuildingDeployHelper("icebox", { "cookpot" },
    COOKPOT_PLACEMENT_RADIUS - ICEBOX_FOOTPRINT, ICEBOX_FOOTPRINT, 0, 1, 1)
AddBuildingDeployHelper("saltbox", { "cookpot" },
    COOKPOT_PLACEMENT_RADIUS - ICEBOX_FOOTPRINT, ICEBOX_FOOTPRINT, 0, 1, 1)
AddBuildingDeployHelper("cookpot", { "icebox", "saltbox" },
    ICEBOX_PLACEMENT_RADIUS - COOKPOT_FOOTPRINT, COOKPOT_FOOTPRINT, 1, 1, 0)

-- ====== 疙瘩树（高出平均值的树干/大树干）树冠范围 deployhelper ======
local function CreateCanopyDeployHelperRing(inst, canopy_range, r, g, b)
    local ring = CreateHelperRadiusCircle(inst, canopy_range, r, g, b, false)
    ring.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    ring.AnimState:SetSortOrder(3)

    local function OnUpdatePlacerHelper()
        if not ring.placerinst:IsValid() then
            ring.components.updatelooper:RemoveOnUpdateFn(OnUpdatePlacerHelper)
            ring.AnimState:SetAddColour(0, 0, 0, 0)
        else
            local x, y, z = inst.Transform:GetWorldPosition()
            local px, py, pz = ring.placerinst.Transform:GetWorldPosition()
            if GLOBAL.distsq(x, z, px, pz) <= canopy_range * canopy_range
                and GLOBAL.TheWorld.Map:GetPlatformAtPoint(x, z)
                    == GLOBAL.TheWorld.Map:GetPlatformAtPoint(px, pz) then
                ring.AnimState:SetAddColour(ring.placerinst.AnimState:GetAddColour())
            else
                ring.AnimState:SetAddColour(0, 0, 0, 0)
            end
        end
    end

    ring:AddComponent("updatelooper")
    ring.components.updatelooper:AddOnUpdateFn(OnUpdatePlacerHelper)
    ring.placerinst = nil

    return ring, OnUpdatePlacerHelper
end

local function MakeCanopyOnEnableHelper(canopy_range, r, g, b)
    return function(inst, enabled, recipename, placerinst)
        if enabled then
            if inst.helper == nil and not inst:HasTag("burnt") then
                local ring, updatefn = CreateCanopyDeployHelperRing(inst, canopy_range, r, g, b)
                ring.placerinst = placerinst
                updatefn(ring)
                inst.helper = ring
            end
        elseif inst.helper ~= nil then
            inst.helper:Remove()
            inst.helper = nil
        end
    end
end

local function AddCanopyDeployHelper(prefab_name, canopy_range, r, g, b)
    AddPrefabPostInit(prefab_name, function(inst)
        if not GLOBAL.TheNet:IsDedicated() then
            inst:AddComponent("deployhelper")
            inst.components.deployhelper.onenablehelper = MakeCanopyOnEnableHelper(canopy_range, r, g, b)
        end
    end)
end

AddCanopyDeployHelper("oceantree_pillar", GLOBAL.TUNING.SHADE_CANOPY_RANGE_SMALL, 0, 1, 0)
AddCanopyDeployHelper("watertree_pillar", GLOBAL.TUNING.SHADE_CANOPY_RANGE, 50/255, 205/255, 50/255)

-- ====== 攻击范围指示器 ======
-- 在玩家脚下绘制武器攻击范围圈，跟随武器切换动态更新
if GetModConfigData("RANGEINDICATOR_ATTACK_RANGE") ~= false then
    AddPlayerPostInit(function(player)
        if GLOBAL.TheNet:IsDedicated() then return end

        player:DoTaskInTime(0, function()
            if player ~= GLOBAL.ThePlayer then return end

            local attack_ring = nil
            local last_range = 0

            local function UpdateAttackRing()
                if not GLOBAL.ThePlayer:IsValid()
                    or GLOBAL.ThePlayer:HasTag("playerghost") then
                    if attack_ring then
                        attack_ring:Remove()
                        attack_ring = nil
                        last_range = 0
                    end
                    return
                end

                local combat = PlayerUtil:GetCombat()
                local weapon = combat and combat:GetWeapon()
                local range = combat and combat:GetAttackRangeWithWeapon() or 0

                -- 仅手持武器时显示（空手攻击范围 ~2 无显示意义）
                if weapon and range > 0 then
                    if range ~= last_range then
                        if attack_ring then
                            attack_ring:Remove()
                        end
                        attack_ring = CreateHelperRadiusCircle(player, range, 1, 0.4, 0.1, false)
                        attack_ring.AnimState:SetSortOrder(2)
                        last_range = range
                    end
                else
                    if attack_ring then
                        attack_ring:Remove()
                        attack_ring = nil
                        last_range = 0
                    end
                end
            end

            local task = player:DoPeriodicTask(0.3, UpdateAttackRing)

            local old_OnRemoveEntity = player.OnRemoveEntity
            player.OnRemoveEntity = function(...)
                if task then
                    task:Cancel()
                    task = nil
                end
                if attack_ring then
                    attack_ring:Remove()
                    attack_ring = nil
                end
                if old_OnRemoveEntity then
                    old_OnRemoveEntity(...)
                end
            end

            UpdateAttackRing()
        end)
    end)
end