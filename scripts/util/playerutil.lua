-- 玩家工具模块 - 第一时间获取角色身上的组件和标签，提供给自动勋章使用
-- 设计：Class 模式、TryInit 惰性初始化、换人自动重置、回调系统。
-- 不依赖硬编码映射，Init 时（勋章尚未装备）全量捕获角色固有标签和组件，天然适配模组角色。
--
-- 状态查询严格遵循 player_common.lua 官方写法：components → player_classified → default 三层模式。
-- 事件处理遵循 player_common.lua / player_classified.lua 官方写法：命名函数 + ListenForEvent。
--
-- 事件来源：player_common.lua、player_common_extensions.lua、player_classified.lua、playercontroller.lua

local ItemUtil = require "util/itemutil"
local InventoryUtil = require "util/inventoryutil"
local WorldUtil = require "util/worldutil"

-- 威胁检测范围（带 _combat 且攻击目标为 ThePlayer 的实体）
local THREAT_RANGE = 30
-- 官方客户端找攻击目标用的排除标签（scripts/components/playercontroller.lua:1782）：
-- 物品栏/容器内的生物由 EntityScript:RemoveFromScene() 打上 INLIMBO 离开场景，
-- 但仍带 _combat，且 replica.combat 的目标可能残留为玩家，不能再算作正在攻击的威胁。
local THREAT_CANT_TAGS = { "INLIMBO" }
-- 官方玩家 LightWatcher:SetLightThresh(.075)（scripts/prefabs/player_common.lua:2446）：
-- 低于该阈值即处于黑暗、会被鬼手攻击；用于校验"举着的光源是否真的在发光"。
local LIGHT_THRESH = 0.075
-- 举着同一盏光源时，合成照度相对基线的增量只能来自外部光/天光增强。
local EXTERNAL_LIGHT_DELTA = 0.1

local fns = {}

-- =============================================
-- Class 构造
-- =============================================

local PlayerUtil = Class(function(self)
    self.initialized = false
    self.character_prefab = nil
    self._inherent_tags = {}
    self._components = {}
    self._on_initialized_callbacks = {}
    self._event_callbacks = {}
    self._bound_player = nil
    self._client_fake_lights = nil
    self._light_baseline_item = nil
    self._light_baseline = nil
end)

-- =============================================
-- 内部工具（fns 表，遵循 player_common.lua 模式）
-- =============================================

fns.FireEventCallbacks = function(self, event, data, player)
    local cbs = self._event_callbacks and self._event_callbacks[event]
    if not cbs then return end
    for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb, data, player)
        if not ok then
            print("PlayerUtil: 回调异常 " .. tostring(err))
        end
    end
end

fns.FireInitCallbacks = function(self)
    local cbs = self._on_initialized_callbacks
    if not cbs then return end
    for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb)
        if not ok then
            print("PlayerUtil: 初始化回调异常 " .. tostring(err))
        end
    end
end

-- 状态查询统一入口：无本地玩家时返回各查询的兜底值，避免每个公开方法重复判空。
-- fn 以 ThePlayer 为首参，其余参数原样透传（如 IsAtEdge 的 dir_x/dir_z）。
fns.Query = function(fn, fallback, ...)
    if not ThePlayer then return fallback end
    return fn(ThePlayer, ...)
end

-- 玩家控制器查询统一入口：组件不存在或无该方法时返回兜底值，其余参数原样透传。
-- 只用于纯查询；DoAction 等动作执行与实例级 hook 仍由业务层保留。
fns.QueryController = function(method, fallback, ...)
    local pc = ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller
    if pc == nil or type(pc[method]) ~= "function" then return fallback end
    return pc[method](pc, ...)
end

-- =============================================
-- 客户端本地假光（夜视作弊）识别
-- 只用官方结构判据，不写死亮度/半径：裸 CreateEntity() 建的灯没有 Network
-- （entityscript.lua:174 的 Entity:AddNetwork 才创建它）、没有 prefab，
-- 且由 entity:SetParent 直接挂在玩家下（GetParent() 返回 EntityScript，
-- 见 entityscript.lua:1807-1808，不能拿它和 player.entity 比较）。
-- 官方手持光源的火焰光同样是非网络子实体，但必带 FX / playerlight 标签
-- （torchfire_common.lua:4,25、lighterfire_common.lua:4-5），据此排除真实光源。
-- 这类灯只进本机光照网格：服务端 grue 仍按黑暗判定，故本地 LightWatcher 的
-- "有光"读数不可信；发现不轮询：事件标脏后延到下一帧扫一次，平时只验缓存。
-- =============================================

fns.IsClientLocalLight = function(ent, player)
    if ent == nil or ent == player or ent.Light == nil or ent.Network ~= nil or ent.prefab ~= nil then
        return false
    end
    if ent:HasTag("FX") or ent:HasTag("playerlight") then
        return false
    end
    if ent.entity == nil or player.entity == nil then
        return false
    end
    local parent = ent.entity:GetParent()
    return parent == player or parent == player.entity
end

fns.FindClientFakeLights = function(player)
    local lights = {}
    if player == nil or player.entity == nil then
        return lights
    end
    for _, ent in pairs(Ents) do
        if ent:IsValid() and fns.IsClientLocalLight(ent, player) then
            lights[#lights + 1] = ent
        end
    end
    return lights
end

fns.RefreshClientFakeLights = function(player)
    if player == nil or player ~= ThePlayer then return end
    PlayerUtil._client_fake_lights = fns.FindClientFakeLights(player)
end

-- 夜视模组通常先推 nightvision 事件、之后才创建/点亮灯实体；而举着光源时玩家
-- 本来就在光里，也不会有 enterlight 边沿。事件里立即扫只会扫到"灯还不存在"的空表。
-- 因此事件只标脏，并把扫描排到下一帧（DoTaskInTime 回调首参就是所属实体）。
fns.ScheduleClientFakeLightRefresh = function(inst)
    PlayerUtil._client_fake_lights = nil
    if inst ~= nil and inst:IsValid() then
        inst:DoTaskInTime(0, fns.RefreshClientFakeLights)
    end
end

-- =============================================
-- 事件处理函数（命名函数，遵循 player_common.lua 模式）
-- =============================================

fns.OnClientLightChanged = function(inst)
    fns.ScheduleClientFakeLightRefresh(inst)
end

fns.OnPlayerActivated = function(inst, data)
    fns.ScheduleClientFakeLightRefresh(inst)
    fns.FireEventCallbacks(PlayerUtil, "playeractivated", data, inst)
end

fns.OnPlayerDeactivated = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "playerdeactivated", data, inst)
end

fns.OnBecameGhost = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "ms_becameghost", data, inst)
end

fns.OnRespawnedFromGhost = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "ms_respawnedfromghost", data, inst)
end

fns.OnSeamlessPlayerSwap = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "seamlessplayerswap", data, inst)
end

fns.OnFinishSeamlessPlayerSwap = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "finishseamlessplayerswap", data, inst)
end

fns.OnEquip = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "equip", data, inst)
end

fns.OnUnequip = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "unequip", data, inst)
end

fns.OnStartFreezing = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "startfreezing", data, inst)
end

fns.OnStopFreezing = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "stopfreezing", data, inst)
end

fns.OnStartOverheating = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "startoverheating", data, inst)
end

fns.OnStopOverheating = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "stopoverheating", data, inst)
end

fns.OnStartFireDamage = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "startfiredamage", data, inst)
end

fns.OnStopFireDamage = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "stopfiredamage", data, inst)
end

fns.OnChangeFireDamage = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "changefiredamage", data, inst)
end

fns.OnStartLunarBurn = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "startlunarburn", data, inst)
end

fns.OnStopLunarBurn = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "stoplunarburn", data, inst)
end

fns.OnStartStarving = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "startstarving", data, inst)
end

fns.OnStopStarving = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "stopstarving", data, inst)
end

fns.OnHealthDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "healthdelta", data, inst)
end

fns.OnHungerDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "hungerdelta", data, inst)
end

fns.OnSanityDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "sanitydelta", data, inst)
end

fns.OnAttacked = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "attacked", data, inst)
end

-- 角色特有状态 delta 事件（由 player_classified 推送，非适用角色不会触发）
fns.OnWerenessDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "werenessdelta", data, inst)
end

fns.OnMightinessDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "mightinessdelta", data, inst)
end

fns.OnInspirationDelta = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "inspirationdelta", data, inst)
end

fns.OnShieldDirty = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "shielddelta", data, inst)
end

-- stormlevel / miasmalevel：分别追踪沙尘暴/时空风暴和暗影瘴气
fns._storm_state = false
fns.OnStormLevelChanged = function(inst, data)
    local in_storm = fns.IsInStorm(inst)
    if in_storm ~= fns._storm_state then
        fns._storm_state = in_storm
        fns.FireEventCallbacks(PlayerUtil, in_storm and "startstorm" or "stopstorm", data, inst)
    end
end

fns._miasma_state = false
fns.OnMiasmaChanged = function(inst, data)
    local in_miasma = fns.IsInMiasma(inst)
    if in_miasma ~= fns._miasma_state then
        fns._miasma_state = in_miasma
        fns.FireEventCallbacks(PlayerUtil, in_miasma and "startmiasma" or "stopmiasma", data, inst)
    end
end

-- pethealthbar 组件事件（仅 Wendy 有该组件，非 Wendy 角色不会触发）
-- 参考 components/pethealthbar.lua:20-22 clientpethealthdirty 推送 { percent = ... }
fns.OnClientPetHealthDirty = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "clientpethealthdirty", data, inst)
end

fns.OnClientPetMaxHealthDirty = function(inst, data)
    fns.FireEventCallbacks(PlayerUtil, "clientpetmaxhealthdirty", data, inst)
end

-- =============================================
-- 事件绑定/解绑（逐个注册命名函数，遵循 player_common.lua 模式）
-- =============================================

fns.RegisterPlayerEvents = function(player)
    player:ListenForEvent("playeractivated", fns.OnPlayerActivated)
    player:ListenForEvent("playerdeactivated", fns.OnPlayerDeactivated)
    -- 假光出现/消失、夜视状态切换时重新发现一次；enterlight 是 LightWatcher 引擎事件，
    -- nightvision 覆盖"玩家本来就在光里、没有明暗边沿"的情况。
    player:ListenForEvent("enterlight", fns.OnClientLightChanged)
    player:ListenForEvent("enterdark", fns.OnClientLightChanged)
    player:ListenForEvent("nightvision", fns.OnClientLightChanged)
    player:ListenForEvent("ms_becameghost", fns.OnBecameGhost)
    player:ListenForEvent("ms_respawnedfromghost", fns.OnRespawnedFromGhost)
    player:ListenForEvent("seamlessplayerswap", fns.OnSeamlessPlayerSwap)
    player:ListenForEvent("finishseamlessplayerswap", fns.OnFinishSeamlessPlayerSwap)
    player:ListenForEvent("equip", fns.OnEquip)
    player:ListenForEvent("unequip", fns.OnUnequip)
    player:ListenForEvent("startfreezing", fns.OnStartFreezing)
    player:ListenForEvent("stopfreezing", fns.OnStopFreezing)
    player:ListenForEvent("startoverheating", fns.OnStartOverheating)
    player:ListenForEvent("stopoverheating", fns.OnStopOverheating)
    player:ListenForEvent("startfiredamage", fns.OnStartFireDamage)
    player:ListenForEvent("stopfiredamage", fns.OnStopFireDamage)
    player:ListenForEvent("changefiredamage", fns.OnChangeFireDamage)
    player:ListenForEvent("startlunarburn", fns.OnStartLunarBurn)
    player:ListenForEvent("stoplunarburn", fns.OnStopLunarBurn)
    player:ListenForEvent("startstarving", fns.OnStartStarving)
    player:ListenForEvent("stopstarving", fns.OnStopStarving)
    player:ListenForEvent("healthdelta", fns.OnHealthDelta)
    player:ListenForEvent("hungerdelta", fns.OnHungerDelta)
    player:ListenForEvent("sanitydelta", fns.OnSanityDelta)
    player:ListenForEvent("attacked", fns.OnAttacked)
    player:ListenForEvent("werenessdelta", fns.OnWerenessDelta)
    player:ListenForEvent("mightinessdelta", fns.OnMightinessDelta)
    player:ListenForEvent("inspirationdelta", fns.OnInspirationDelta)
    player:ListenForEvent("stormlevel", fns.OnStormLevelChanged)
    player:ListenForEvent("miasmalevel", fns.OnMiasmaChanged)
    player:ListenForEvent("clientpethealthdirty", fns.OnClientPetHealthDirty)
    player:ListenForEvent("clientpetmaxhealthdirty", fns.OnClientPetMaxHealthDirty)

    if player.wx78_classified then
        player.wx78_classified:ListenForEvent("shielddirty", fns.OnShieldDirty)
    end
end

fns.UnregisterPlayerEvents = function(player)
    player:RemoveEventCallback("playeractivated", fns.OnPlayerActivated)
    player:RemoveEventCallback("playerdeactivated", fns.OnPlayerDeactivated)
    player:RemoveEventCallback("enterlight", fns.OnClientLightChanged)
    player:RemoveEventCallback("enterdark", fns.OnClientLightChanged)
    player:RemoveEventCallback("nightvision", fns.OnClientLightChanged)
    player:RemoveEventCallback("ms_becameghost", fns.OnBecameGhost)
    player:RemoveEventCallback("ms_respawnedfromghost", fns.OnRespawnedFromGhost)
    player:RemoveEventCallback("seamlessplayerswap", fns.OnSeamlessPlayerSwap)
    player:RemoveEventCallback("finishseamlessplayerswap", fns.OnFinishSeamlessPlayerSwap)
    player:RemoveEventCallback("equip", fns.OnEquip)
    player:RemoveEventCallback("unequip", fns.OnUnequip)
    player:RemoveEventCallback("startfreezing", fns.OnStartFreezing)
    player:RemoveEventCallback("stopfreezing", fns.OnStopFreezing)
    player:RemoveEventCallback("startoverheating", fns.OnStartOverheating)
    player:RemoveEventCallback("stopoverheating", fns.OnStopOverheating)
    player:RemoveEventCallback("startfiredamage", fns.OnStartFireDamage)
    player:RemoveEventCallback("stopfiredamage", fns.OnStopFireDamage)
    player:RemoveEventCallback("changefiredamage", fns.OnChangeFireDamage)
    player:RemoveEventCallback("startlunarburn", fns.OnStartLunarBurn)
    player:RemoveEventCallback("stoplunarburn", fns.OnStopLunarBurn)
    player:RemoveEventCallback("startstarving", fns.OnStartStarving)
    player:RemoveEventCallback("stopstarving", fns.OnStopStarving)
    player:RemoveEventCallback("healthdelta", fns.OnHealthDelta)
    player:RemoveEventCallback("hungerdelta", fns.OnHungerDelta)
    player:RemoveEventCallback("sanitydelta", fns.OnSanityDelta)
    player:RemoveEventCallback("attacked", fns.OnAttacked)
    player:RemoveEventCallback("werenessdelta", fns.OnWerenessDelta)
    player:RemoveEventCallback("mightinessdelta", fns.OnMightinessDelta)
    player:RemoveEventCallback("inspirationdelta", fns.OnInspirationDelta)
    player:RemoveEventCallback("stormlevel", fns.OnStormLevelChanged)
    player:RemoveEventCallback("miasmalevel", fns.OnMiasmaChanged)
    player:RemoveEventCallback("clientpethealthdirty", fns.OnClientPetHealthDirty)
    player:RemoveEventCallback("clientpetmaxhealthdirty", fns.OnClientPetMaxHealthDirty)

    if player.wx78_classified then
        player.wx78_classified:RemoveEventCallback("shielddirty", fns.OnShieldDirty)
    end
end

-- =============================================
-- 状态查询函数（严格遵循 player_common.lua 官方写法）
-- =============================================

-- 参考 player_common.lua:217-225
fns.IsFreezing = function(inst)
    if inst.components.temperature ~= nil then
        return inst.components.temperature:IsFreezing()
    elseif inst.player_classified ~= nil then
        return inst.player_classified.currenttemperature < 0
    else
        return false
    end
end

-- 参考 player_common.lua:227-233
fns.IsOverheating = function(inst)
    if inst.components.temperature ~= nil then
        return inst.components.temperature:IsOverheating()
    elseif inst.player_classified ~= nil then
        return inst.player_classified.currenttemperature > TUNING.OVERHEAT_TEMP
    else
        return false
    end
end

-- 参考 player_common.lua:234-242
fns.GetMoisture = function(inst)
    if inst.components.moisture ~= nil then
        return inst.components.moisture:GetMoisture()
    elseif inst.player_classified ~= nil then
        return inst.player_classified.moisture:value()
    else
        return 0
    end
end

-- 官方 components/moisture.lua:171-172 GetMoisturePercent = moisture / maxmoisture。
-- 玩家潮湿比例与世界潮湿（TheWorld.state.wetness）是两套数据：客机读两个 netvar。
fns.GetMoisturePercent = function(inst)
    if inst.components.moisture ~= nil then
        return inst.components.moisture:GetMoisturePercent()
    elseif inst.player_classified ~= nil then
        local classified = inst.player_classified
        local maxmoisture = classified.maxmoisture and classified.maxmoisture:value() or 0
        local moisture = classified.moisture and classified.moisture:value() or 0
        return maxmoisture > 0 and moisture / maxmoisture or 0
    else
        return 0
    end
end

-- 参考 player_common.lua:204-210
fns.GetTemperature = function(inst)
    if inst.components.temperature ~= nil then
        return inst.components.temperature:GetCurrent()
    elseif inst.player_classified ~= nil then
        return inst.player_classified.currenttemperature
    else
        return TUNING.STARTING_TEMP or 35
    end
end

-- 参考 player_classified.lua:390-406 (wereness 在非 Woodie 角色上恒为 0)
fns.GetWereness = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currentwereness:value() * 0.01
    end
    return 0
end

-- 参考 player_classified.lua:462-471 (mightiness 在非 Wolfgang 角色上恒为 0)
fns.GetMightiness = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currentmightiness:value() * 0.01
    end
    return 0
end

-- 是否处于巨力形态（mighty）：游戏用 mightiness_mighty 标签精确标记巨力态，
-- 非 Wolfgang 角色永不带此标签。重甲不减移速即依赖此态。
fns.IsMighty_ = function(inst)
    return inst ~= nil and inst:HasTag("mightiness_mighty")
end

-- 参考 player_classified.lua:414 (inspiration 在非 Wigfrid 角色上恒为 0)
fns.GetInspiration = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currentinspiration:value() * 0.01
    end
    return 0
end

-- 参考 wx78.lua (WX-78 护盾，仅 WX-78 有 wx78_classified)
fns.GetShield = function(inst)
    if inst.wx78_classified ~= nil then
        return inst.wx78_classified.currentshield:value()
    end
    return 0
end

fns.GetMaxShield = function(inst)
    if inst.wx78_classified ~= nil then
        return inst.wx78_classified.maxshield:value()
    end
    return 0
end

-- 参考 components/pethealthbar.lua（仅 Wendy 有此组件）
-- GetSymbol() ~= 0 表示宠物已链接；非 Wendy 角色 components.pethealthbar 为 nil
fns.HasPet = function(inst)
    return inst.components.pethealthbar ~= nil
        and inst.components.pethealthbar:GetSymbol() ~= 0
end

fns.GetPetHealthPct = function(inst)
    if inst.components.pethealthbar ~= nil then
        return inst.components.pethealthbar:GetPercent()
    end
    return 0
end

fns.GetPetMaxHealth = function(inst)
    if inst.components.pethealthbar ~= nil then
        return inst.components.pethealthbar:GetMaxHealth()
    end
    return 0
end

-- 参考 upgrademoduleowner 组件（WX-78 电路能量）
fns.GetEnergyLevel = function(inst)
    if inst.GetEnergyLevel ~= nil then
        return inst:GetEnergyLevel()
    elseif inst.components.upgrademoduleowner ~= nil then
        return inst.components.upgrademoduleowner:GetEnergy()
    else
        return 0
    end
end

fns.GetMaxEnergy = function(inst)
    if inst.GetMaxEnergy ~= nil then
        return inst:GetMaxEnergy()
    elseif inst.components.upgrademoduleowner ~= nil then
        return inst.components.upgrademoduleowner:GetMaxEnergy()
    else
        return 0
    end
end

-- 参考 player_common.lua:883-884
fns.IsGhost = function(inst)
    return (inst.player_classified ~= nil and inst.player_classified.isghostmode:value()) or
        (inst.player_classified == nil and inst:HasTag("playerghost"))
end

-- 参考 player_classified.lua: 核心三属性净值（health/hunger/sanity）
fns.GetHealth = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currenthealth:value()
    end
    return 0
end

fns.GetMaxHealth = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.maxhealth:value()
    end
    return 0
end

-- 老龄角色（旺达等）血量显示缩放：replica 存缩放后值，取 display 值需反向缩放
fns.GetHealthForDisplay = function(inst)
    local v = fns.GetHealth(inst)
    if inst and inst:HasTag("oldager") then
        local scale = TUNING.OLDAGE_HEALTH_SCALE
        if scale and scale > 0 then
            v = v / scale
        end
    end
    return v
end

fns.GetMaxHealthForDisplay = function(inst)
    local v = fns.GetMaxHealth(inst)
    if inst and inst:HasTag("oldager") then
        local scale = TUNING.OLDAGE_HEALTH_SCALE
        if scale and scale > 0 then
            v = v / scale
        end
    end
    return v
end

fns.GetHealthPenaltyPct = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.healthpenalty:value() / 200
    end
    return 0
end

fns.GetHunger = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currenthunger:value()
    end
    return 0
end

fns.GetMaxHunger = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.maxhunger:value()
    end
    return 0
end

fns.GetSanity = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.currentsanity:value()
    end
    return 0
end

fns.GetMaxSanity = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.maxsanity:value()
    end
    return 0
end

fns.GetSanityPenaltyPct = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.sanitypenalty:value() / 200
    end
    return 0
end

fns.IsSanityLunacy = function(inst)
    return inst.replica.sanity ~= nil
        and inst.replica.sanity:GetSanityMode() == SANITY_MODE_LUNACY
end

-- 参考 player_classified.lua:304-306
fns.IsTakingFireDamage = function(inst)
    if inst.components.health ~= nil and inst.components.health.takingfiredamage then
        return true
    elseif inst.player_classified ~= nil then
        return inst.player_classified.istakingfiredamage:value()
    else
        return false
    end
end

-- 参考 player_common.lua:266-270
fns.IsInMiasma = function(inst)
    return inst.player_classified ~= nil and inst.player_classified.isinmiasma:value()
end

-- 参考 player_common.lua:261-264
fns.GetStormLevel = function(inst)
    if inst.player_classified ~= nil then
        return inst.player_classified.stormlevel:value() / 7
    end
    return 0
end

-- 参考 player_common.lua 的 GetStormLevel 逻辑
fns.IsInStorm = function(inst)
    return inst.player_classified ~= nil
        and inst.player_classified.stormlevel:value() / 7 >= TUNING.SANDSTORM_FULL_LEVEL
end

-- 参考 player_common.lua:272-277
fns.IsInAnyStormOrCloud = function(inst)
    return inst.player_classified ~= nil
        and (inst.player_classified.stormlevel:value() / 7 >= TUNING.SANDSTORM_FULL_LEVEL or
            inst.player_classified.isinmiasma:value())
end

-- 参考 player_common.lua:285-287
fns.IsChannelCasting = function(inst)
    return inst.player_classified ~= nil
        and (inst.player_classified.ischannelcasting:value() or
            inst.player_classified.ischannelcastingitem:value())
end

-- 参考 player_common.lua:281-283
fns.IsCarefulWalking = function(inst)
    return inst.player_classified ~= nil and inst.player_classified.iscarefulwalking:value()
end

-- 参考 player_common.lua:180
fns.IsRiding_ = function(inst)
    if inst.replica ~= nil and inst.replica.rider ~= nil then
        return inst.replica.rider:IsRiding()
    elseif inst.components ~= nil and inst.components.rider ~= nil then
        return inst.components.rider:IsRiding()
    else
        return false
    end
end

-- 玩家是否正在移动（WASD/鼠标行走）。
-- 注意：LocoMotor 本身**没有** IsMoving 方法（那是 BoatDrifter 的），故不能调 loco:IsMoving()；
-- 官方 locomotor 的 OnUpdate 用 self.inst.sg:HasStateTag("moving") 判定 is_moving（见 locomotor.lua:1629），
-- 这里沿用同一判据。再叠加 locomotor.wantstomoveforward 作兜底（按下移动键即置 true，动作锁定期间为 false）。
-- 动作执行期间玩家被锁定(busy)不会进入 moving 状态，故在两轮动作之间轮询即可区分
-- "玩家主动走开"与"动作自身的自动寻路"，用作持续型自动动作的打断判据。
fns.IsMoving_ = function(inst)
    if inst == nil then return false end
    if inst.sg ~= nil and inst.sg:HasStateTag("moving") then
        return true
    end
    if inst.components ~= nil and inst.components.locomotor ~= nil then
        return inst.components.locomotor.wantstomoveforward == true
    end
    return false
end

-- 玩家是否正在奔跑（walk/run 的 stategraph 用 "running" 标签区分，locomotor.lua:1630 同此判据）。
fns.IsRunning_ = function(inst)
    if inst == nil then return false end
    if inst.sg ~= nil and inst.sg:HasStateTag("running") then
        return true
    end
    if inst.components ~= nil and inst.components.locomotor ~= nil then
        return inst.components.locomotor.wantstorun == true
    end
    return false
end

-- 玩家是否正在前往某目标（locomotor.dest 非空：GoToPoint/GoToEntity 设置，
-- 即"自动寻路走向某实体/坐标"而非自由走位）。可用于区分"动作自带的走向目标"与"玩家自主走开"。
fns.HasDestination_ = function(inst)
    if inst == nil or inst.components == nil then return false end
    local loco = inst.components.locomotor
    return loco ~= nil and loco:HasDestination()
end

-- 玩家是否想向前移动（按下移动键即置位，比 sg 标签早 1 帧生效；动作锁定期间为 false）。
fns.WantsToMoveForward_ = function(inst)
    if inst == nil or inst.components == nil then return false end
    local loco = inst.components.locomotor
    return loco ~= nil and loco.WantsToMoveForward ~= nil and loco:WantsToMoveForward()
end

-- 玩家是否想奔跑（按下奔跑键/设置 should_run 即置位）。
fns.WantsToRun_ = function(inst)
    if inst == nil or inst.components == nil then return false end
    local loco = inst.components.locomotor
    return loco ~= nil and loco.WantsToRun ~= nil and loco:WantsToRun()
end

-- 玩家实际行走速度（locomotor 按角色 walk 基数 × 速度乘子；比 GetSpeed 的硬编码跑速更准）。
fns.GetWalkSpeed_ = function(inst)
    if inst == nil or inst.components == nil then return 0 end
    local loco = inst.components.locomotor
    return loco ~= nil and loco.GetWalkSpeed ~= nil and loco:GetWalkSpeed() or 0
end

-- 玩家实际奔跑速度（locomotor 按角色 run 基数 × 速度乘子）。
fns.GetRunSpeed_ = function(inst)
    if inst == nil or inst.components == nil then return 0 end
    local loco = inst.components.locomotor
    return loco ~= nil and loco.GetRunSpeed ~= nil and loco:GetRunSpeed() or 0
end

-- 玩家已持续移动时长（秒）；未移动时为 0。可用于"长时间行走/卡住"检测。
fns.GetTimeMoving_ = function(inst)
    if inst == nil or inst.components == nil then return 0 end
    local loco = inst.components.locomotor
    return loco ~= nil and loco.GetTimeMoving ~= nil and loco:GetTimeMoving() or 0
end

-- 玩家在某个方向上的平台边缘（船/礁石等水上场景）：dir_x/dir_z 为方向单位向量。
-- 自动取当前平台(TheWorld 平台)与玩家坐标；非水上/无平台时返回 false。
fns.IsAtEdge_ = function(inst, dir_x, dir_z)
    if inst == nil or inst.components == nil or inst.Transform == nil then return false end
    local loco = inst.components.locomotor
    if loco == nil or loco.IsAtEdge == nil then return false end
    local platform = (inst.GetCurrentPlatform ~= nil) and inst:GetCurrentPlatform() or nil
    local map = TheWorld ~= nil and TheWorld.Map or nil
    local x, _, z = inst.Transform:GetWorldPosition()
    return loco:IsAtEdge(platform, map, x, z, dir_x, dir_z)
end

-- 坐骑实体：未骑乘返回 nil（rider 组件/副本的 GetMount 与 IsRiding 同源）
fns.GetMount_ = function(inst)
    if inst.replica ~= nil and inst.replica.rider ~= nil then
        return inst.replica.rider:GetMount()
    elseif inst.components ~= nil and inst.components.rider ~= nil then
        return inst.components.rider:GetMount()
    end
    return nil
end

-- 鞍具实体：未骑乘/无鞍返回 nil（与 GetMount_ 同源的 rider 副本）
fns.GetSaddle_ = function(inst)
    local rider = inst ~= nil and inst.replica ~= nil and inst.replica.rider or nil
    return rider ~= nil and rider:GetSaddle() or nil
end

-- 有效移动速度乘子（重甲不减移速相关）
-- 计算：玩家外部速度乘子 × 骑乘鞍具移速 × 各已装备物品 GetWalkSpeedMult
-- 沃尔夫冈巨力形态（mightiness_mighty）下，<1 的乘子视为 1（重甲不减移速）
-- 逻辑参考 基础运行库 m_utils / 自动走位躲避 的 GetSpeed；单件乘子复用 ItemUtil:GetWalkspeedMult
fns.GetWalkSpeedMult_ = function(inst)
    if inst == nil or inst.replica == nil then
        return 1
    end
    local classified = inst.player_classified
    local mult = (classified ~= nil and classified.externalspeedmultiplier ~= nil)
        and classified.externalspeedmultiplier:value() or 1

    local inventory = inst.replica.inventory
    if inventory ~= nil then
        if fns.IsRiding_(inst) then
            -- 骑乘时只看鞍具移速，玩家身上装备的 walkspeedmult 不起作用
            local saddle = fns.GetSaddle_(inst)
            local m = saddle ~= nil and ItemUtil:GetWalkspeedMult(saddle) or 0
            if m ~= 0 then
                mult = mult * m
            end
        else
            -- 巨力形态：重甲 / 减速装备不降低移速
            local is_mighty = fns.IsMighty_(inst)
            for _, equip in pairs(inventory:GetEquips() or {}) do
                local m = ItemUtil:GetWalkspeedMult(equip)
                if m ~= 0 then
                    if is_mighty and m < 1 then
                        m = 1
                    end
                    mult = mult * m
                end
            end
        end
    end

    return mult
end

-- 参考 player_classified.lua:346-347
fns.IsStarving = function(inst)
    if inst.components.hunger ~= nil then
        return inst.components.hunger:IsStarving()
    elseif inst.player_classified ~= nil then
        return inst.player_classified.currenthunger:value() / inst.player_classified.maxhunger:value() <= 0
    else
        return false
    end
end

-- 参考 player_common.lua IsNearDanger 中 sanity:IsSane 的用法
fns.IsInsane = function(inst)
    if inst.replica ~= nil and inst.replica.sanity ~= nil then
        return inst.replica.sanity:IsInsanityMode()
    elseif inst.components ~= nil and inst.components.sanity ~= nil then
        return inst.components.sanity:IsInsane()
    else
        return false
    end
end

-- 参考 player_common.lua 的 HasTag 模式
fns.IsTransforming = function(inst)
    return inst:HasTag("wereplayer")
end

fns.IsReviving = function(inst)
    return inst:HasTag("reviving")
end

-- 是否在光亮环境（EntityScript:IsInLight()，C 端方法；grue 鬼手伤害判定同款）。
-- 黑暗中无光源会被鬼手持续扣血，故无光环境下头部唯一光源不可被护甲覆盖。
fns.IsInLight_ = function(inst)
    if inst == nil then return false end
    return inst:IsInLight()
end

-- =============================================
-- SG / Anim 原始数据获取（基于官方 stategraph.lua SGTagsToEntTags:501-520）
-- =============================================

fns.GetCurrentState = function(inst)
    if inst.sg ~= nil and inst.sg.currentstate ~= nil then
        return inst.sg.currentstate.name
    end
    return nil
end

-- 获取待执行的 buffered action（动作名 + 目标）
fns.GetBufferedAction = function(inst)
    return inst:GetBufferedAction()
end

-- =============================================
-- 初始化 / 重置
-- =============================================

function PlayerUtil:Reset()
    self.initialized = false
    self.character_prefab = nil
    self._inherent_tags = {}
    self._components = {}
    self._client_fake_lights = nil
    self._light_baseline_item = nil
    self._light_baseline = nil
    if self._bound_player then
        fns.UnregisterPlayerEvents(self._bound_player)
    end
    self._bound_player = nil
end

function PlayerUtil:TryInit()
    if self.initialized then
        if not ThePlayer or ThePlayer.prefab ~= self.character_prefab then
            self:Reset()
        else
            return true
        end
    end
    if not ThePlayer or not ThePlayer.prefab then
        return false
    end
    self:_DoInit(ThePlayer)
    return true
end

function PlayerUtil:Init(player)
    if not player then return end
    if self.initialized and self.character_prefab == player.prefab then
        return
    end
    self:_DoInit(player)
end

function PlayerUtil:_DoInit(player)
    self.character_prefab = player.prefab

    -- 通过 GetDebugString() 解析 Tags 行获取所有固有标签
    -- DST 实体没有 GetTags() 方法，但 GetDebugString() 返回的调试字符串包含 Tags: 行
    self._inherent_tags = {}
    if player.GetDebugString then
        local ds = player:GetDebugString()
        if type(ds) == "string" then
            local tags_str = ds:match("Tags:(.-)\n")
            if tags_str then
                for _, tag in ipairs(tags_str:split(" ")) do
                    if tag ~= "" and tag ~= "FROMNUM" then
                        self._inherent_tags[tag] = true
                    end
                end
            end
        end
    end

    self._components = {}
    if player.components then
        for name, comp in pairs(player.components) do
            if comp then
                self._components[name] = comp
            end
        end
    end

    self.initialized = true

    if self._bound_player then
        fns.UnregisterPlayerEvents(self._bound_player)
    end
    self._bound_player = player
    -- 装上"移动/攻击键打断连续动作"的钩子（幂等）
    self:_InstallInterruptHook(player)
    fns.RegisterPlayerEvents(player)

    fns.FireInitCallbacks(self)
end

-- =============================================
-- 回调注册（对外 API）
-- =============================================

function PlayerUtil:OnInitialized(fn)
    table.insert(self._on_initialized_callbacks, fn)
    if self.initialized then
        fn()
    end
end

function PlayerUtil:On(event, fn)
    if type(event) ~= "string" or type(fn) ~= "function" then return end
    self._event_callbacks = self._event_callbacks or {}
    self._event_callbacks[event] = self._event_callbacks[event] or {}
    table.insert(self._event_callbacks[event], fn)
    self:TryInit()
end

-- 玩家停用（退出世界 / 断开连接 / 洞穴迁移）时触发一次。
-- 官方 DeactivatePlayer（prefabs/player_common.lua）在这几种情况都会推 playerdeactivated，
-- 并且它自己就在那里调 SerializeUserSession 存客户端本地数据 —— 是模组落盘最合适的时机。
-- 回调签名 fn(data, player)。
function PlayerUtil:OnDeactivated(fn)
    if type(fn) ~= "function" then return end
    return self:On("playerdeactivated", fn)
end

function PlayerUtil:Off(event, fn)
    if not self._event_callbacks or not self._event_callbacks[event] then return end
    if fn then
        for i, cb in ipairs(self._event_callbacks[event]) do
            if cb == fn then
                table.remove(self._event_callbacks[event], i)
                return
            end
        end
    else
        self._event_callbacks[event] = nil
    end
end

-- =============================================
-- 玩家实体获取
-- =============================================

function PlayerUtil:GetPlayer()
    self:TryInit()
    return ThePlayer
end

-- 玩家自身 rider / combat 副本：补齐工具层入口，业务层不再直连 ThePlayer.replica
function PlayerUtil:GetSaddle()
    return fns.Query(fns.GetSaddle_, nil)
end

function PlayerUtil:GetCombat()
    return ThePlayer and ThePlayer.replica and ThePlayer.replica.combat
end

-- 玩家 talker 是官方 common 段添加的本地组件（player_common.lua:2487），客户端可读。
-- Say 钩子挂在组件实例上，必须取当下实体的实时组件：GetComponent 优先返回 Init 快照，
-- 同 prefab 换实体（跨世界迁移）时 TryInit 不会 Reset，快照仍指向旧组件。
function PlayerUtil:GetTalker()
    return ThePlayer and ThePlayer.components and ThePlayer.components.talker
end

-- playercontroller 纯查询（动作执行 DoAction 与实例级 hook 不走这里）
function PlayerUtil:IsAOETargeting()
    return fns.QueryController("IsAOETargeting", false)
end

function PlayerUtil:GetAOETargetingPos()
    return fns.QueryController("GetAOETargetingPos", nil)
end

function PlayerUtil:IsControlPressed(control)
    return fns.QueryController("IsControlPressed", false, control)
end

function PlayerUtil:IsAnyOfControlsPressed(...)
    return fns.QueryController("IsAnyOfControlsPressed", false, ...)
end

function PlayerUtil:CanLocomote()
    return fns.QueryController("CanLocomote", false)
end

-- =============================================
-- 状态查询（组件方法，委托给 fns 中的函数）
-- =============================================

function PlayerUtil:IsFreezing()
    return fns.Query(fns.IsFreezing, false)
end

function PlayerUtil:IsOverheating()
    return fns.Query(fns.IsOverheating, false)
end

function PlayerUtil:IsTakingFireDamage()
    return fns.Query(fns.IsTakingFireDamage, false)
end

function PlayerUtil:IsGhost()
    return fns.Query(fns.IsGhost, false)
end

function PlayerUtil:IsStarving()
    return fns.Query(fns.IsStarving, false)
end

function PlayerUtil:IsInsane()
    return fns.Query(fns.IsInsane, false)
end

function PlayerUtil:GetMoisture()
    return fns.Query(fns.GetMoisture, 0)
end

function PlayerUtil:GetMoisturePercent()
    return fns.Query(fns.GetMoisturePercent, 0)
end

function PlayerUtil:IsWet()
    return self:GetMoisture() > 0
end

function PlayerUtil:IsRiding()
    return fns.Query(fns.IsRiding_, false)
end

-- 玩家是否正在移动（WASD/鼠标行走）；用做持续型自动动作的打断判据。
function PlayerUtil:IsMoving()
    return fns.Query(fns.IsMoving_, false)
end

-- 玩家是否正在奔跑。
function PlayerUtil:IsRunning()
    return fns.Query(fns.IsRunning_, false)
end

-- 玩家是否正在前往某目标（自动寻路中，非自由走位）。
function PlayerUtil:HasDestination()
    return fns.Query(fns.HasDestination_, false)
end

-- 玩家是否想向前移动（意图位，比 sg 标签早 1 帧）。
function PlayerUtil:WantsToMoveForward()
    return fns.Query(fns.WantsToMoveForward_, false)
end

-- 玩家是否想奔跑。
function PlayerUtil:WantsToRun()
    return fns.Query(fns.WantsToRun_, false)
end

-- 玩家实际行走速度（按角色 walk 基数 × 速度乘子）。
function PlayerUtil:GetWalkSpeed()
    return fns.Query(fns.GetWalkSpeed_, 0)
end

-- 玩家实际奔跑速度（按角色 run 基数 × 速度乘子；比 GetSpeed 的硬编码跑速更准）。
function PlayerUtil:GetRunSpeed()
    return fns.Query(fns.GetRunSpeed_, 0)
end

-- 玩家已持续移动时长（秒）；未移动时为 0。
function PlayerUtil:GetTimeMoving()
    return fns.Query(fns.GetTimeMoving_, 0)
end

-- 玩家在某方向上的平台边缘（水上场景）；dir_x/dir_z 为方向单位向量。
function PlayerUtil:IsAtEdge(dir_x, dir_z)
    return fns.Query(fns.IsAtEdge_, false, dir_x, dir_z)
end

-- 坐骑实体；未骑乘返回 nil
function PlayerUtil:GetMount()
    return fns.Query(fns.GetMount_, nil)
end

-- 是否骑在成年（大）Woby 上：沃尔特的 Woby 长大后可在坐骑上使用远程武器
-- prefab 见官方 scripts/prefabs/wobybig.lua
function PlayerUtil:IsRidingBigWoby()
    local mount = self:GetMount()
    return mount ~= nil and mount.prefab == "wobybig"
end

function PlayerUtil:IsChannelCasting()
    return fns.Query(fns.IsChannelCasting, false)
end

function PlayerUtil:IsCarefulWalking()
    return fns.Query(fns.IsCarefulWalking, false)
end

function PlayerUtil:IsTransforming()
    return fns.Query(fns.IsTransforming, false)
end

function PlayerUtil:IsReviving()
    return fns.Query(fns.IsReviving, false)
end

-- =============================================
-- 角色特有状态查询（公开 API）
-- =============================================

function PlayerUtil:GetHealth()
    return fns.Query(fns.GetHealthForDisplay, 0)
end

function PlayerUtil:GetMaxHealth()
    return fns.Query(fns.GetMaxHealthForDisplay, 0)
end

function PlayerUtil:GetHealthPenaltyPct()
    return fns.Query(fns.GetHealthPenaltyPct, 0)
end

function PlayerUtil:GetHunger()
    return fns.Query(fns.GetHunger, 0)
end

function PlayerUtil:GetMaxHunger()
    return fns.Query(fns.GetMaxHunger, 0)
end

function PlayerUtil:GetSanity()
    return fns.Query(fns.GetSanity, 0)
end

function PlayerUtil:GetMaxSanity()
    return fns.Query(fns.GetMaxSanity, 0)
end

function PlayerUtil:GetSanityPenaltyPct()
    return fns.Query(fns.GetSanityPenaltyPct, 0)
end

function PlayerUtil:IsSanityLunacy()
    return fns.Query(fns.IsSanityLunacy, false)
end

function PlayerUtil:GetTemperature()
    return fns.Query(fns.GetTemperature, TUNING.STARTING_TEMP or 35)
end

function PlayerUtil:GetWereness()
    return fns.Query(fns.GetWereness, 0)
end

function PlayerUtil:GetMightiness()
    return fns.Query(fns.GetMightiness, 0)
end

-- 是否处于沃尔夫冈巨力形态（重甲不减移速）
function PlayerUtil:IsMighty()
    return fns.Query(fns.IsMighty_, false)
end

function PlayerUtil:GetInspiration()
    return fns.Query(fns.GetInspiration, 0)
end

function PlayerUtil:GetShield()
    return fns.Query(fns.GetShield, 0)
end

function PlayerUtil:GetMaxShield()
    return fns.Query(fns.GetMaxShield, 0)
end

function PlayerUtil:HasPet()
    return fns.Query(fns.HasPet, false)
end

function PlayerUtil:GetPetHealthPct()
    return fns.Query(fns.GetPetHealthPct, 0)
end

function PlayerUtil:GetPetMaxHealth()
    return fns.Query(fns.GetPetMaxHealth, 0)
end

function PlayerUtil:GetEnergyLevel()
    return fns.Query(fns.GetEnergyLevel, 0)
end

function PlayerUtil:GetMaxEnergy()
    return fns.Query(fns.GetMaxEnergy, 0)
end

-- =============================================
-- SG / Anim 原始数据获取（公开 API）
-- =============================================

function PlayerUtil:GetCurrentSGState()
    return fns.Query(fns.GetCurrentState, nil)
end

function PlayerUtil:GetBufferedAction()
    return fns.Query(fns.GetBufferedAction, nil)
end

-- =============================================
-- 环境检测
-- =============================================

function PlayerUtil:IsInStorm()
    return fns.Query(fns.IsInStorm, false)
end

function PlayerUtil:IsInMiasma()
    return fns.Query(fns.IsInMiasma, false)
end

function PlayerUtil:IsInAnyStormOrCloud()
    return fns.Query(fns.IsInAnyStormOrCloud, false)
end

-- 是否有"只照亮本机"的假光正在发光。缓存里只放结构命中的实体，
-- 平时只验 IsValid / Light:IsEnabled；缓存未建立或被 Reset 清空时才补扫一次，
-- 之后仍靠事件边沿刷新，不在自动装备循环里轮询全 Ents。
function PlayerUtil:HasClientFakeLight()
    if self._client_fake_lights == nil then
        fns.RefreshClientFakeLights(ThePlayer)
    end
    local lights = self._client_fake_lights
    if lights == nil then return false end
    for _, ent in ipairs(lights) do
        if ent:IsValid() and ent.Light ~= nil and ent.Light:IsEnabled() then
            return true
        end
    end
    return false
end

-- ItemUtil 的分类方法是冒号定义（带 self），传给 FindEquipped 必须包一层命名闭包，
-- 不能用 ItemUtil.IsLightSource 直接传引用；命名闭包也让谓词缓存 key 稳定。
local function IsLightSourceItem(item)
    return ItemUtil:IsLightSource(item)
end

-- 是否还需要自身光源保护（防鬼手）。autolight 的补装与 configutil 的 LIGHT 抑制
-- 共用这一份判定、这一份基线，避免两个模块各自采样导致结论相反、灯被反复装/换。
-- configutil 只调函数、不持有状态；基线是 PlayerUtil 实例字段，随 Reset/换人清空。
-- 依据官方：player_common.lua:2446 光照阈值、grue.lua:57 夜视免疫、
--           wisecracker.lua:557 GetTimeInDark() >= .5 的黑暗状态机。
function PlayerUtil:NeedsLightProtection()
    if not ThePlayer or not ThePlayer.LightWatcher then
        return false
    end
    if WorldUtil:IsDay() then
        return false
    end
    -- 夜视与官方 grue 的 nightvision 免疫一致；playervision 在 player_common.lua:2493
    -- 的 common 段添加（SetPristine 之前），纯客户端可读；读不到时保守当无夜视。
    local pv = self:GetComponent("playervision")
    if pv ~= nil and pv.HasNightVision ~= nil and pv:HasNightVision() then
        return false
    end
    -- 客户端本地假光只进本机光照网格，服务端 grue 仍按黑暗判定：一律按需要保护处理。
    if self:HasClientFakeLight() then
        return true
    end

    local held = InventoryUtil:FindEquipped(IsLightSourceItem)
    if not held then
        -- 非标准光源（无燃料 tag，如启迪之冠）：与 configutil 规则 2 同口径，
        -- 从 LIGHT 分类候选（含用户临时加入分类的物品）里找当前已装备的那一件。
        -- 否则会被当成"没举灯"走 GetTimeInDark 单开关，戴着发光头冠时自己点亮自己，
        -- 判定立刻翻成"不需保护"，帽子覆盖头冠、头冠又被补装，形成反复切换。
        local ac = self:GetComponent("actioncontroller")
        local lights = ac and ac:GetItemsFromCategory("LIGHT")
        if lights then
            for _, item in pairs(InventoryUtil:GetEquips()) do
                if table.contains(lights, item) then
                    held = item
                    break
                end
            end
        end
    end
    if not held then
        -- 灯已被其它装备换下：基线随之失效，避免重新装上时沿用旧基线反复让位
        self._light_baseline_item, self._light_baseline = nil, nil
        -- 没举灯：官方 LightWatcher 黑暗状态机直接给出外部光是否足够
        return ThePlayer.LightWatcher:GetTimeInDark() > 0
    end
    -- 举着灯却不亮/已耗尽：需要补装，且清掉旧灯的基线
    if held:HasTag("fueldepleted") or not ThePlayer:IsLightGreaterThan(LIGHT_THRESH) then
        self._light_baseline_item, self._light_baseline = nil, nil
        return true
    end
    -- 基线只在"换了一盏灯"时采样一次，避免逐帧漂移
    if held ~= self._light_baseline_item then
        self._light_baseline_item = held
        self._light_baseline = ThePlayer.LightWatcher:GetLightValue()
    end
    if ThePlayer.LightWatcher:GetLightValue() - self._light_baseline > EXTERNAL_LIGHT_DELTA then
        return false
    end
    return true
end

-- 是否在光亮环境（黑暗中鬼手持续扣血）。封装 EntityScript:IsInLight()。
-- 有本地假光时保守返回"无光"：服务端 grue 看不到这盏灯，
-- 按有光处理会让 autohelm / autocloth 顶掉头部唯一真实光源。
function PlayerUtil:IsInLight()
    if self:HasClientFakeLight() then
        return false
    end
    return fns.Query(fns.IsInLight_, false)
end

-- =============================================
-- 威胁检测（原 threatutil，供 autohelm / autocloth 复用）
-- 是否有正在攻击本体的威胁（带 _combat 且攻击目标为 ThePlayer 的实体）。
-- 避免两套自动装备在 HEAD/BODY 槽反复争夺。
-- 只认场景内的实体：物品栏/容器里的生物已离场景，不能让护甲一直穿着。
-- =============================================

function PlayerUtil:CheckThreats()
    if not ThePlayer or not ThePlayer.Transform then
        return false
    end
    local x, y, z = ThePlayer.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, THREAT_RANGE, { "_combat" }, THREAT_CANT_TAGS)
    for i = 1, #ents do
        local ent = ents[i]
        -- 官方 Combat:IsValidTarget（scripts/components/combat_replica.lua:291）的客户端判据
        if ent:IsValid() and ent.entity:IsVisible()
                and ent.replica and ent.replica.combat then
            if ent.replica.combat:GetTarget() == ThePlayer and not ItemUtil:IsSleeping(ent) then
                return true
            end
        end
    end
    return false
end

-- =============================================
-- 移动速度（重甲不减移速）
-- =============================================

-- 玩家有效移动速度乘子（基数 1：>1 加速，<1 减速，=1 无影响）
-- 已计入：外部速度乘子、骑乘鞍具、各已装备物品 walkspeedmult；
-- 沃尔夫冈巨力形态（mightiness_mighty）下重甲 / 减速装备不降低移速。
function PlayerUtil:GetWalkSpeedMult()
    return fns.Query(fns.GetWalkSpeedMult_, 1)
end

-- 玩家实际移动速度（乘子 × 跑速基数 TUNING.WILSON_RUN_SPEED = 6）
function PlayerUtil:GetSpeed()
    if not ThePlayer then return (TUNING.WILSON_RUN_SPEED) end
    return fns.GetWalkSpeedMult_(ThePlayer) * (TUNING.WILSON_RUN_SPEED)
end
-- =============================================

-- 获取客户端玩家当前所在地皮类型编号（GROUND.xxx 常量）
-- 海洋地皮范围 GROUND.OCEAN_START(201) ~ GROUND.OCEAN_END(247)
-- 返回 nil 表示无玩家或无法获取
function PlayerUtil:GetGroundType()
    if not ThePlayer or not TheWorld or not TheWorld.Map then return nil end
    local x, y, z = ThePlayer.Transform:GetWorldPosition()
    return TheWorld.Map:GetTileAtPoint(x, y, z)
end

-- 检查玩家是否处于指定地皮类型（单类型或多类型表）
function PlayerUtil:IsOnGroundType(tile_types)
    if not ThePlayer then return false end
    local tile = self:GetGroundType()
    if not tile then return false end
    if type(tile_types) == "table" then
        for _, tt in ipairs(tile_types) do
            if tile == tt then return true end
        end
        return false
    end
    return tile == tile_types
end

-- 检查玩家是否处于海洋地皮
-- allow_boats 默认 true：站在船/平台上时视为陆地返回 false
-- allow_boats = false：忽略船，只检测足下地皮
function PlayerUtil:IsOnOcean(allow_boats)
    if not ThePlayer then return false end
    if allow_boats ~= false and ThePlayer:GetCurrentPlatform() then
        return false
    end
    local tile = self:GetGroundType()
    if not tile then return false end
    return TileGroupManager:IsOceanTile(tile)
end

-- 检查玩家是否处于陆地（船上视为陆地）
function PlayerUtil:IsOnLand()
    if not ThePlayer then return false end
    if ThePlayer:GetCurrentPlatform() then
        return true
    end
    local tile = self:GetGroundType()
    if not tile then return false end
    return TileGroupManager:IsLandTile(tile)
end

-- =============================================
-- 基础查询
-- =============================================

function PlayerUtil:GetPrefab()
    self:TryInit()
    return self.character_prefab
end

function PlayerUtil:IsReady()
    return self.initialized
end

-- =============================================
-- 标签查询
-- =============================================

--- 玩家实体的标签查询（只用于玩家实体；物品标签走 ItemUtil:HasTag）
function PlayerUtil:HasTag(player, tag)
    return player ~= nil and player:HasTag(tag)
end

function PlayerUtil:GetInherentTags()
    self:TryInit()
    return self._inherent_tags or {}
end

function PlayerUtil:HasInherentTag(tag)
    self:TryInit()
    if self._inherent_tags and self._inherent_tags[tag] then
        return true
    end
    return false
end

function PlayerUtil:HasBuilderTagFromMedal(builder_tag, equipped_medal)
    if not equipped_medal then
        return false
    end
    local player = self:GetPlayer()
    if not player or not player:HasTag(builder_tag) then
        return false
    end
    return not self:HasInherentTag(builder_tag)
end

-- =============================================
-- 组件查询
-- =============================================

function PlayerUtil:HasComponent(name)
    self:TryInit()
    return self._components and self._components[name] ~= nil
end

-- 快照取不到时回源实时组件（Init 早于后挂的 AddComponent）；HasComponent/GetComponentNames 仍只看快照。
function PlayerUtil:GetComponent(name)
    self:TryInit()
    return (self._components and self._components[name])
        or (ThePlayer and ThePlayer.components and ThePlayer.components[name])
end

function PlayerUtil:GetComponentNames()
    self:TryInit()
    local names = {}
    if self._components then
        for name, _ in pairs(self._components) do
            names[name] = true
        end
    end
    return names
end

-- =============================================
-- 快照输出
-- =============================================

function PlayerUtil:GetSnapshot()
    self:TryInit()
    local tags = {}
    for tag in pairs(self._inherent_tags) do
        table.insert(tags, tag)
    end
    table.sort(tags)

    local comps = {}
    for name in pairs(self._components) do
        table.insert(comps, name)
    end
    table.sort(comps)

    return {
        character = self.character_prefab,
        ready = self.initialized,
        inherent_tags = tags,
        tag_count = #tags,
        components = comps,
        component_count = #comps,
    }
end

function PlayerUtil:Dump()
    local snap = self:GetSnapshot()
    print("========================================")
    print("PlayerUtil 快照")
    print("  角色: " .. tostring(snap.character))
    print("  就绪: " .. tostring(snap.ready))
    print("  固有标签 (" .. snap.tag_count .. "): " .. table.concat(snap.inherent_tags, ", "))
    print("  组件 (" .. snap.component_count .. "): " .. table.concat(snap.components, ", "))
    print("========================================")
end

-- =============================================
-- 工作线程打断中心（注册制，对外 API）
-- ---------------------------------------------
-- 背景：模组内由玩家主动触发的连续动作（连续丢弃等）用 StartThread 循环执行，
-- 没有打断手段就会出现"停不下来"。移植 Lazy Controls 的 repeat_drop 时漏掉了它的
-- Util.AddCommonInterruptFn 打断中心，属移植不全，这里补上并统一收在 PlayerUtil。
--
-- 用法：需要被打断的模块自行 AddInterruptFn(自己的 Stop 函数)；
--       玩家按移动键 / 攻击键时统一调用所有注册的 Stop。
-- 注意：只给"玩家主动触发的连续动作"注册；被动循环（autolight/autoamulet/autohelm 等）
--       不应被移动打断，故用注册制而非全局一刀切。
-- 关于"点击非 HUD 区域"：它本质是下发移动指令，但走的是 playercontroller 的
--       PRIMARY/SECONDARY 而非移动键，所以在同一个钩子里一并纳入；
--       鼠标停在 HUD 上时不打断，否则点击物品栏会打断自己刚发起的动作。
-- =============================================

local _interrupt_fns = {}

function PlayerUtil:AddInterruptFn(fn)
    if type(fn) ~= "function" then return end
    for _, f in ipairs(_interrupt_fns) do
        if f == fn then return end
    end
    _interrupt_fns[#_interrupt_fns + 1] = fn
end

function PlayerUtil:RemoveInterruptFn(fn)
    for i = #_interrupt_fns, 1, -1 do
        if _interrupt_fns[i] == fn then
            table.remove(_interrupt_fns, i)
        end
    end
end

-- 打断所有已注册的连续动作（control 仅便于调试/扩展，Stop 函数可不接收）
function PlayerUtil:InterruptAll(control)
    for _, fn in ipairs(_interrupt_fns) do
        fn(control)
    end
end

-- 给本地玩家的 playercontroller 装打断钩子（幂等；随 _DoInit 调用）
-- 控制表在运行时构建：避免 CONTROL_* 在文件加载期尚未就绪导致 "table index is nil"
function PlayerUtil:_InstallInterruptHook(player)
    local pc = player and player.components and player.components.playercontroller
    if pc == nil or pc._eq_interrupt then return end
    pc._eq_interrupt = true

    local interrupt_controls = {
        [CONTROL_MOVE_UP] = true,
        [CONTROL_MOVE_DOWN] = true,
        [CONTROL_MOVE_LEFT] = true,
        [CONTROL_MOVE_RIGHT] = true,
        [CONTROL_ATTACK] = true,
    }
    -- 鼠标左右键：仅在鼠标不在 HUD 上时打断（点空地=移动指令）
    local interrupt_mouse = {
        [CONTROL_PRIMARY] = true,
        [CONTROL_SECONDARY] = true,
    }

    local old = pc.OnControl
    pc.OnControl = function(self, control, down, ...)
        if down and (
                interrupt_controls[control]
                or (interrupt_mouse[control] and TheInput ~= nil
                    and not TheInput:GetHUDEntityUnderMouse())
            ) then
            PlayerUtil:InterruptAll(control)
        end
        return old(self, control, down, ...)
    end
end

return PlayerUtil