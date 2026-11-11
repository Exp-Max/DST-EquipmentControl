local WorldUtil = {}

--------------------------------------------------
-- 内部状态
--------------------------------------------------
local _listeners = {}
local _watchers = {}
local _id_counter = 0

--------------------------------------------------
-- 基础事件监听（带 source 参数正确传递）
--------------------------------------------------

-- 来源：官方：TheWorld:ListenForEvent + 本地监听表
function WorldUtil:ListenWorldEvent(event, fn, source)
    if not (TheWorld and TheWorld:IsValid()) then return nil end
    _id_counter = _id_counter + 1
    local id = _id_counter
    _listeners[id] = { event = event, fn = fn, source = source }
    TheWorld:ListenForEvent(event, fn, source)
    return id
end

-- 来源：官方：TheWorld:RemoveEventCallback
function WorldUtil:RemoveWorldListener(id)
    if not id or not _listeners[id] then return end
    local l = _listeners[id]
    if TheWorld and TheWorld:IsValid() and l then
        TheWorld:RemoveEventCallback(l.event, l.fn, l.source)
    end
    _listeners[id] = nil
end

-- 来源：官方：TheWorld:RemoveEventCallback
function WorldUtil:RemoveAllWorldListeners()
    for id, l in pairs(_listeners) do
        if TheWorld and TheWorld:IsValid() and l then
            TheWorld:RemoveEventCallback(l.event, l.fn, l.source)
        end
    end
    _listeners = {}
    _watchers = {}
end

--------------------------------------------------
-- 玩家激活事件
--------------------------------------------------

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnPlayerActivated(fn)
    return self:ListenWorldEvent("playeractivated", fn, TheWorld)
end

--------------------------------------------------
-- WorldState 变量监听（官方 WatchWorldState 包装）
--------------------------------------------------

-- 来源：官方：TheWorld:WatchWorldState（components/worldstate.lua）
function WorldUtil:WatchState(var, fn, source)
    if not (TheWorld and TheWorld:IsValid() and TheWorld.components.worldstate) then
        return nil
    end
    _id_counter = _id_counter + 1
    local id = _id_counter
    local wrapped = function(inst, value) fn(value) end
    _watchers[id] = { var = var, fn = wrapped, source = source }
    TheWorld:WatchWorldState(var, wrapped, source)
    if TheWorld.state[var] ~= nil then
        fn(TheWorld.state[var])
    end
    return id
end

-- 来源：官方：TheWorld:StopWatchingWorldState
function WorldUtil:StopWatchingState(id)
    if not id or not _watchers[id] then return end
    local w = _watchers[id]
    if TheWorld and TheWorld:IsValid() and TheWorld.components.worldstate and w then
        TheWorld:StopWatchingWorldState(w.var, w.fn, w.source)
    end
    _watchers[id] = nil
end

--------------------------------------------------
-- 世界状态安全访问
--------------------------------------------------

-- 来源：官方：TheWorld.state 代理表（components/worldstate.lua）
function WorldUtil:GetState(key)
    if not TheWorld or not TheWorld:IsValid() then return nil end
    return TheWorld.state and TheWorld.state[key]
end

-- 来源：官方：TheWorld.state 代理表（components/worldstate.lua）
function WorldUtil:HasState(key)
    if not TheWorld or not TheWorld:IsValid() then return false end
    return TheWorld.state and TheWorld.state[key] ~= nil
end

--------------------------------------------------
-- 时钟
--------------------------------------------------

-- 来源：官方：TheWorld.state.cycles
function WorldUtil:GetCycles()
    return self:GetState("cycles") or 0
end

-- 来源：官方：TheWorld.state.time
function WorldUtil:GetTime()
    return self:GetState("time") or 0
end

-- 来源：官方：TheWorld.state.phase
function WorldUtil:GetPhase()
    return self:GetState("phase") or "day"
end

-- 来源：官方：TheWorld.state.isday
function WorldUtil:IsDay()
    return self:GetState("isday") or false
end

-- 来源：官方：TheWorld.state.isdusk
function WorldUtil:IsDusk()
    return self:GetState("isdusk") or false
end

-- 来源：官方：TheWorld.state.isnight
function WorldUtil:IsNight()
    return self:GetState("isnight") or false
end

-- 来源：官方：TheWorld.state.isfullmoon
function WorldUtil:IsFullMoon()
    return self:GetState("isfullmoon") or false
end

-- 来源：官方：TheWorld.state.isnewmoon
function WorldUtil:IsNewMoon()
    return self:GetState("isnewmoon") or false
end

-- 来源：官方：TheWorld.state.moonphase
function WorldUtil:GetMoonPhase()
    return self:GetState("moonphase") or "new"
end

-- 来源：模组自实现：本地状态/回调管理，基于官方 TheWorld 与 WorldState
function WorldUtil:GetDayFraction()
    return self:GetCycles() + self:GetTime() + 1
end

--------------------------------------------------
-- 洞穴时钟
--------------------------------------------------

-- 来源：官方：TheWorld:HasTag(...)
function WorldUtil:IsCave()
    return TheWorld and TheWorld:IsValid() and TheWorld:HasTag("cave")
end

-- 来源：官方：TheWorld.state.cavephase
function WorldUtil:GetCavePhase()
    return self:GetState("cavephase") or "day"
end

-- 来源：官方：TheWorld.state.iscaveday
function WorldUtil:IsCaveDay()
    return self:GetState("iscaveday") or false
end

-- 来源：官方：TheWorld.state.iscavenight
function WorldUtil:IsCaveNight()
    return self:GetState("iscavenight") or false
end

-- 来源：官方：TheWorld.state.iscavefullmoon
function WorldUtil:IsCaveFullMoon()
    return self:GetState("iscavefullmoon") or false
end

--------------------------------------------------
-- 噩梦
--------------------------------------------------

-- 来源：官方：TheWorld.state.nightmarephase
function WorldUtil:GetNightmarePhase()
    return self:GetState("nightmarephase") or "none"
end

-- 来源：官方：TheWorld.state.isnightmarecalm
function WorldUtil:IsNightmareCalm()
    return self:GetState("isnightmarecalm") or false
end

-- 来源：官方：TheWorld.state.isnightmarewarn
function WorldUtil:IsNightmareWarn()
    return self:GetState("isnightmarewarn") or false
end

-- 来源：官方：TheWorld.state.isnightmarewild
function WorldUtil:IsNightmareWild()
    return self:GetState("isnightmarewild") or false
end

--------------------------------------------------
-- 季节
--------------------------------------------------

-- 来源：官方：TheWorld.state.season
function WorldUtil:GetSeason()
    return self:GetState("season") or "autumn"
end

-- 来源：官方：TheWorld.state.isautumn
function WorldUtil:IsAutumn()
    return self:GetState("isautumn") or false
end

-- 来源：官方：TheWorld.state.iswinter
function WorldUtil:IsWinter()
    return self:GetState("iswinter") or false
end

-- 来源：官方：TheWorld.state.isspring
function WorldUtil:IsSpring()
    return self:GetState("isspring") or false
end

-- 来源：官方：TheWorld.state.issummer
function WorldUtil:IsSummer()
    return self:GetState("issummer") or false
end

-- 来源：官方：TheWorld.state.seasonprogress
function WorldUtil:GetSeasonProgress()
    return self:GetState("seasonprogress") or 0
end

-- 来源：官方：TheWorld.state.elapseddaysinseason
function WorldUtil:GetElapsedDaysInSeason()
    return self:GetState("elapseddaysinseason") or 0
end

-- 来源：官方：TheWorld.state.remainingdaysinseason
function WorldUtil:GetRemainingDaysInSeason()
    return self:GetState("remainingdaysinseason") or 0
end

-- 来源：官方：TheWorld.state.key + TUNING.* 派生
function WorldUtil:GetSeasonLength(season_name)
    local key = (season_name or self:GetSeason()) .. "length"
    return self:GetState(key) or TUNING[string.upper(season_name or "autumn") .. "_LENGTH"] or 20
end

--------------------------------------------------
-- 温度（世界环境温度 TheWorld.state.temperature；玩家体温见 PlayerUtil:GetTemperature）
--------------------------------------------------

-- 来源：官方：TheWorld.state.temperature（components/worldstate.lua:134）
function WorldUtil:GetTemperature()
    return self:GetState("temperature") or TUNING.STARTING_TEMP
end

-- 来源：模组自实现：按官方 TUNING.OVERHEAT_TEMP 判断世界温度过热
function WorldUtil:IsOverheatTemperature()
    local temp = self:GetTemperature()
    return temp ~= nil and temp >= TUNING.OVERHEAT_TEMP
end

-- 来源：模组自实现：按官方 freezing 基准 0 判断世界温度过冷
function WorldUtil:IsFreezingTemperature()
    local temp = self:GetTemperature()
    return temp ~= nil and temp <= 0
end

--------------------------------------------------
-- 降水 / 雨
--------------------------------------------------

-- 来源：官方：TheWorld.state.precipitation
function WorldUtil:GetPrecipitation()
    return self:GetState("precipitation") or "none"
end

-- 来源：官方：TheWorld.state.precipitationrate
function WorldUtil:GetPrecipitationRate()
    return self:GetState("precipitationrate") or 0
end

-- 来源：官方：TheWorld.state.israining
function WorldUtil:IsRaining()
    return self:GetState("israining") or false
end

-- 来源：官方：TheWorld.state.issnowing
function WorldUtil:IsSnowing()
    return self:GetState("issnowing") or false
end

-- 来源：官方：TheWorld.state.issnowcovered
function WorldUtil:IsSnowCovered()
    return self:GetState("issnowcovered") or false
end

-- 来源：官方：TheWorld.state.snowlevel
function WorldUtil:GetSnowLevel()
    return self:GetState("snowlevel") or 0
end

-- 来源：官方：TheWorld.state.islunarhailing
function WorldUtil:IsLunarhailing()
    return self:GetState("islunarhailing") or false
end

-- 来源：官方：TheWorld.state.isacidraining
function WorldUtil:IsAcidRaining()
    return self:GetState("isacidraining") or false
end

--------------------------------------------------
-- 湿度（世界湿度 TheWorld.state.*）
--------------------------------------------------

-- 来源：官方：TheWorld.state.moisture（components/worldstate.lua）
function WorldUtil:GetMoisture()
    return self:GetState("moisture") or 0
end

-- 来源：官方：TheWorld.state.moistureceil（components/worldstate.lua）
function WorldUtil:GetMoistureCeil()
    return self:GetState("moistureceil") or 0
end

-- 来源：官方：TheWorld.state.wetness
function WorldUtil:GetWetness()
    return self:GetState("wetness") or 0
end

-- 来源：官方：TheWorld.state.iswet
function WorldUtil:IsWet()
    return self:GetState("iswet") or false
end

--------------------------------------------------
-- 事件快捷方法
--------------------------------------------------

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnClockTick(fn, source)
    return self:ListenWorldEvent("clocktick", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnPhaseChanged(fn, source)
    return self:ListenWorldEvent("phasechanged", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnCyclesChanged(fn, source)
    return self:ListenWorldEvent("cycleschanged", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnMoonPhaseChanged(fn, source)
    return self:ListenWorldEvent("moonphasechanged2", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnSeasonTick(fn, source)
    return self:ListenWorldEvent("seasontick", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnTemperatureTick(fn, source)
    return self:ListenWorldEvent("temperaturetick", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnWeatherTick(fn, source)
    return self:ListenWorldEvent("weathertick", fn, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnPrecipitationChanged(fn, source)
    return self:ListenWorldEvent("precipitationchanged", fn, source)
end

--------------------------------------------------
-- 高级: WatchState 快捷方法（用官方 API 避免轮询）
--------------------------------------------------

-- 来源：官方：TheWorld:WatchWorldState（经 WorldUtil:WatchState）
function WorldUtil:OnRainStart(fn, source)
    return self:WatchState("israining", function(israining)
        if israining then fn() end
    end, source)
end

-- 来源：官方：TheWorld:WatchWorldState（经 WorldUtil:WatchState）
function WorldUtil:OnRainStop(fn, source)
    return self:WatchState("israining", function(israining)
        if not israining then fn() end
    end, source)
end

-- 来源：官方：TheWorld:WatchWorldState（经 WorldUtil:WatchState）
function WorldUtil:OnIsRainingChanged(fn, source)
    return self:WatchState("israining", function(israining)
        fn(israining)
    end, source)
end

-- 来源：官方：TheWorld:WatchWorldState（经 WorldUtil:WatchState）
function WorldUtil:OnSeasonChanged(fn, source)
    return self:WatchState("season", function(season)
        fn(season)
    end, source)
end

-- 来源：官方：TheWorld:ListenForEvent（经 WorldUtil:ListenWorldEvent）
function WorldUtil:OnSnowCoveredChanged(fn, source)
    return self:ListenWorldEvent("snowcoveredchanged", fn, source)
end

--------------------------------------------------
-- 工具方法
--------------------------------------------------

-- 来源：模组自实现：本地状态/回调管理，基于官方 TheWorld 与 WorldState
function WorldUtil:IsValid()
    return TheWorld ~= nil and TheWorld:IsValid()
end

-- 来源：官方：TheWorld:HasTag(...)
function WorldUtil:IsCaveWorld()
    return self:IsValid() and TheWorld:HasTag("cave")
end

-- 来源：模组自实现：本地状态/回调管理，基于官方 TheWorld 与 WorldState
function WorldUtil:GetWorldSeed()
    if not self:IsValid() then return nil end
    local seed = TheWorld.meta and TheWorld.meta.seed
    if seed == nil then return nil end
    return self:IsCaveWorld() and seed .. "_caves" or seed
end

-- 来源：官方：TheWorld:HasTag(...)
function WorldUtil:IsForestWorld()
    return self:IsValid() and TheWorld:HasTag("forest")
end

-- 来源：官方：TheWorld.ismastersim
function WorldUtil:IsMasterSim()
    return self:IsValid() and TheWorld.ismastersim
end

-- 坐标存档用的世界 id：用集群 master session id 区分不同存档槽（跨存档不互通）；
-- 再追加 _surface / _cave 区分地表与地下，确保同一世界地表与洞穴坐标各自独立存档、互不串档。
-- （地表与洞穴共享同一个 master session id，若不追加分片标记会落在同一 worldid 下互相覆盖。）
-- 读取走 TheWorld.net 上的 shardstate 网络组件：该组件随网络实体 SetPristine 在客户端同样创建，
-- 其 master session id 以 net_string 复制到客户端，因此纯客户端模组也能可靠读到；
-- 若网络组件尚未就绪（极端时序），则回退到 TheWorld.meta.session_identifier（客户端同样可用）。
-- 来源：官方：TheWorld.meta.session_identifier
function WorldUtil:GetWorldId()
    if not self:IsValid() then return nil end
    local net = TheWorld.net
    local sid
    local shardstate = net and net.components and net.components.shardstate
    if shardstate ~= nil then
        sid = shardstate:GetMasterSessionId()
    end
    if not sid then
        sid = TheWorld.meta and TheWorld.meta.session_identifier
    end
    if not sid then return nil end
    return sid .. (self:IsCaveWorld() and "_cave" or "_surface")
end

return WorldUtil