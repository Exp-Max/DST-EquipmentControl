-- util/insightutil.lua
-- Insight (2189004162, DST 联机版) 数据源 service
-- 机制（已对照联机版源码确认）：
--   * 客户端对实体调用 ThePlayer.replica.insight:RequestInformation(inst) 把它加入 Insight 的请求队列，
--     Insight 内部周期批量 SendModRPCToServer 发给服务器。
--   * 服务器回传该实体结构化信息后，写入 ThePlayer.replica.insight.entity_data[inst]（已解压表）。
--   * 血量字段：entity_data[inst].special_data.health = { health = 当前值, max_health = 最大值 }
--     （来源：scripts/descriptors/health.lua 的 GetData 返回 { health=currenthealth, max_health=maxhealth }）
-- 与 Show Me 不同，Insight 给的是数值表而非压缩字符串，无需解码，直接读表即可。

local InsightUtil = {}

InsightUtil._onDataArrived = nil  -- callback: fn(inst, hp) — 服务器回传血量后立即调起，用于消除轮询滞后

local FETCH_RATELIMIT = 0.5
local last_fetched = {}
local _subscribed = {}     -- 已请求 Fetch 的实体
local _player_listener_added = false
local _insight_decompress = nil

-- Insight 客户端 replica 是否存在（仅在服务器装了 Insight 时，客户端才有此 replica）
function InsightUtil.IsAvailable()
    return ThePlayer ~= nil
        and ThePlayer.replica ~= nil
        and ThePlayer.replica.insight ~= nil
end

-- 动态扫描 ModManager.mods 查找 Insight 模组环境（含 decompress 函数）
-- 不硬编码 mod ID，自适应任意 Insight 版本 / 命名
local function _findInsightEnv()
    if not ModManager or not ModManager.mods then return nil end
    for _, env in pairs(ModManager.mods) do
        if type(env) == "table" and type(env.decompress) == "function" then
            return env
        end
    end
    return nil
end

-- Insight 服务器回包事件监听：推送到 ThePlayer，需解码后分发到各目标实体
local function OnInsightEntityInformation(_, event_data)
    if InsightUtil._onDataArrived == nil then return end
    -- 获取 Insight 的解压函数（延迟懒加载，自动发现 Insight 模组环境）
    if _insight_decompress == nil then
        local insight_env = _findInsightEnv()
        if insight_env then
            _insight_decompress = insight_env.decompress
        else
            return
        end
    end

    local ok, items = pcall(_insight_decompress, event_data.data)
    if not ok or not items then return end

    for i = 1, #items do
        local item = items[i]
        local guid = tonumber(item.GUID)
        local ent = Ents[guid]
        if ent and _subscribed[ent] then
            local hp = InsightUtil.Get(ent)
            if hp then
                InsightUtil._onDataArrived(ent, hp)
            end
        end
    end
end

-- 请求该实体信息（触发 Insight 向服务器批量请求），带限流
function InsightUtil.Fetch(inst)
    if inst == nil or not InsightUtil.IsAvailable() then return end
    if last_fetched[inst] ~= nil and GetTime() - last_fetched[inst] < FETCH_RATELIMIT then return end
    if last_fetched[inst] == nil then
        inst:ListenForEvent("onremove", function(_)
            last_fetched[inst] = nil
            _subscribed[inst] = nil
        end)
    end
    ThePlayer.replica.insight:RequestInformation(inst)
    last_fetched[inst] = GetTime()
    _subscribed[inst] = true

    -- 在 ThePlayer 上注册全局 Insight 回传监听（仅一次）
    if not _player_listener_added then
        _player_listener_added = true
        ThePlayer:ListenForEvent("insight_entity_information", OnInsightEntityInformation)
    end
end

-- 从 Insight 缓存读取某实体数据；无数据（未请求/未回传）返回 nil
-- → entity_data[inst] 原始表（已解压的 Lua table）
function InsightUtil.GetAll(inst)
    if not InsightUtil.IsAvailable() then return nil end
    return ThePlayer.replica.insight.entity_data[inst]
end

-- 按字段名读取 special_data（如 "health" → { health=100, max_health=200 }）
function InsightUtil.GetField(inst, field)
    local ed = InsightUtil.GetAll(inst)
    if ed and ed.special_data then
        return ed.special_data[field]
    end
end

-- 容器内容检查：Insight 是否追踪到该实体含有指定 prefab。
-- 直接调用 Insight mod 客户端 replica 的 ContainerHas；未装 Insight 或不可用则返回 false。
-- prefab 可为字符串或带 .prefab 的实体。
function InsightUtil.ContainerHas(inst, prefab)
    if not InsightUtil.IsAvailable() or inst == nil or prefab == nil then return false end
    local insight = ThePlayer.replica.insight
    if insight == nil then return false end
    local key = type(prefab) == "table" and prefab.prefab or prefab
    return insight:ContainerHas(inst, key, false) or false
end

-- 读取缓存血量（兼容旧接口） → { value = 当前, max = 最大 }
function InsightUtil.Get(inst)
    if not InsightUtil.IsAvailable() then return nil end

    local ed = ThePlayer.replica.insight.entity_data[inst]
    if ed == nil then
        return nil
    end

    local sd = ed.special_data
    local h = sd and sd.health
    if h == nil then
        return nil
    end

    -- 兼容多种字段命名（不同 Insight 版本）
    local value = tonumber(h.health or h.current or h.hp or h.value or h.currenthealth or h.current_health)
    local max   = tonumber(h.max_health or h.max or h.maxhp or h.maxhealth or h.max_health_na)

    -- 兜底：解析 ed.information 字符串（旧版 Insight HTML 颜色格式，如 Exp_Max 所用）
    if value == nil or max == nil then
        local info = ed.information
        if type(info) == "string" then
            local cur, mx = info:match("<color=HEALTH>([%d%.]+)</color> / <color=HEALTH>([%d%.]+)</color>")
            if cur == nil then
                cur, mx = info:match("<<color=HEALTH>([%d%.]+)</color> / <color=HEALTH>([%d%.]+)</color>>")
            end
            if cur ~= nil then
                value = tonumber(cur)
                max = tonumber(mx)
            end
        end
    end

    if value == nil or max == nil then
        return nil
    end

    return { value = value, max = max }
end

return InsightUtil