-- util/showmeutil.lua
-- Show Me / 中文 Show Me (2287303119) 数据源 service
-- 统一接口：IsAvailable / Fetch / Get / GetAll / GetField；Init() 注册网络监听（仅 mod 环境调用一次）。
-- 多个显示模块（damagetracker 等）共用同一份协议解析与缓存，避免重复维护。
--
-- 本文件必须 modimport 加载（见 modmain.lua），不要直接 require：
-- 文件内使用 AddPrefabPostInit 等 mod 专属 API，而 require 环境是游戏全局表、
-- strict.lua 下这些 mod 全局未声明，加载期即报 "is not declared"。
-- 以 mod 环境全局 ShowMeUtil 暴露，modmain 将其写入 package.loaded，
-- 其他模块仍可 require("util/showmeutil") 拿到同一实例。
--
-- v3: 通用解析（全字段 sym→key 动态映射）+ 请求队列（串行 + 1s 超时 + 去重）
--     GetAll() 返回服务端完整数据，各自动模块直接消费真实值，跳过本地猜测

ShowMeUtil = {}

--------------------------------------------------------------------------------
-- 队列系统（独立变量，_ec_ 前缀避免与第三方模组冲突）

local QUERY_TIMEOUT = 1.0
local _ec_query_queue = {}     -- { target, guid }
local _ec_inflight = nil
local _ec_inflight_task = nil

--------------------------------------------------------------------------------
-- 缓存 & 回调

-- cache[inst] = { raw = 原始hint, health = {value, max}, lines = { hp = {...}, armor = {...}, ... } }
local cache = {}
local initialized = false
ShowMeUtil._onDataArrived = nil  -- callback: fn(inst, hp) — 兼容旧接口

--------------------------------------------------------------------------------
-- Show Me 环境检测（懒加载，扫描 ModManager.mods 找 MY_DATA）

local _ec_showme_env = nil

local function _ec_getShowMeEnv()
    if _ec_showme_env then return _ec_showme_env end
    if not ModManager or not ModManager.mods then return nil end
    for _, m in pairs(ModManager.mods) do
        if m and rawget(m, "MY_DATA") and rawget(m, "MY_DATA").hp then
            _ec_showme_env = m
            return m
        end
    end
end

local function _ec_isChineseFormat()
    local env = _ec_getShowMeEnv()
    if not env then return nil end
    local sym = env.MY_DATA.hp.sym
    return sym and string.sub(sym, 1, 1) == "?"
end

--------------------------------------------------------------------------------
-- 动态字段映射（从 MY_DATA 懒加载，适配中文/原始双格式）

local _ec_sym_to_key = nil   -- 原始 Show Me:  单字节 sym → 字段名
local _ec_id_to_key  = nil   -- 中文 Show Me:  数字 id   → 字段名

local function _ec_buildMappings()
    if _ec_sym_to_key then return end
    local env = _ec_getShowMeEnv()
    if not env then return end
    _ec_sym_to_key = {}
    _ec_id_to_key  = {}
    for key, data in pairs(env.MY_DATA) do
        if type(data) == "table" then
            if data.sym then _ec_sym_to_key[data.sym] = key end
            if data.id  then _ec_id_to_key[data.id]   = key end
        end
    end
end

local function _ec_getSymToKey()
    _ec_buildMappings()
    return _ec_sym_to_key or {}
end

local function _ec_getIdToKey()
    _ec_buildMappings()
    return _ec_id_to_key or {}
end

--------------------------------------------------------------------------------
-- 队列机制

local function _ec_sendNext()
    if _ec_inflight or ThePlayer == nil then return end

    local query = table.remove(_ec_query_queue, 1)
    while query and (not query.target or not query.target:IsValid()) do
        query = table.remove(_ec_query_queue, 1)
    end
    if not query then return end

    _ec_inflight = query
    SendModRPCToServer(MOD_RPC.ShowMeSHint.Hint, query.guid, query.target)

    _ec_inflight_task = ThePlayer:DoTaskInTime(QUERY_TIMEOUT, function()
        _ec_inflight_task = nil
        _ec_inflight = nil
        _ec_sendNext()
    end)
end

local function _ec_finishInflight()
    if _ec_inflight_task then
        _ec_inflight_task:Cancel()
        _ec_inflight_task = nil
    end
    _ec_inflight = nil
    _ec_sendNext()
end

--------------------------------------------------------------------------------
-- 解码工具（与 Show Me 源生协议一致）

local function _ec_GetHintValue(hint)
    local splitter = string.find(hint, ';', 1, true)
    if splitter == nil then return nil end
    return hint:sub(splitter + 1)
end

local function _ec_GetHintGUID(hint)
    local splitter = string.find(hint, ';', 1, true)
    if splitter == nil then return nil end
    return tonumber(hint:sub(1, splitter - 1))
end

local function _ec_UnpackData(str, div)
    local pos, arr = 0, {}
    for st, sp in function() return string.find(str, div, pos, true) end do
        table.insert(arr, string.sub(str, pos, st - 1))
        pos = sp + 1
    end
    table.insert(arr, string.sub(str, pos))
    return arr
end

local function _ec_DecodeFirstSymbol(sym)
    local c = string.byte(sym)
    local idx
    if c >= 64 and c <= 126 then
        idx = c - 64
    elseif c >= 32 and c <= 62 then
        idx = c + 31
    elseif c >= 17 and c <= 31 then
        idx = c + 77
    else
        idx = 0
    end
    return idx
end

--------------------------------------------------------------------------------
-- 通用解析：全字段（hp / maxhp / armor / planar_defense / damage / speed / ...）
-- 动态 sym→key 映射，自动适配中文/原始双格式；返回结构化 info 表供各模块消费

local function _ec_parseAll(raw)
    local isChinese = _ec_isChineseFormat()
    if isChinese == nil then return nil end

    local value = _ec_GetHintValue(raw)
    if not value then return nil end

    local info = { raw = raw, health = nil, lines = {} }

    -- 条目以 \2 分隔（Chinese Show Me 格式；原始 Show Me 同协议）
    local entries = _ec_UnpackData(value, "\2")

    local sym_to_key = _ec_getSymToKey()
    local id_to_key  = _ec_getIdToKey()

    for _, v in ipairs(entries) do
        if v ~= "" then
            local key, params
            if isChinese then
                local id = tonumber(string.match(v, "^%?(%d+):"))
                local colon_pos = string.find(v, ":", 1, true)
                local param_str = colon_pos and v:sub(colon_pos + 1) or ""
                key = id_to_key[id]
                params = _ec_UnpackData(param_str, ",")
            else
                local sym = v:sub(1, 1)
                key = sym_to_key[sym] or sym
                params = _ec_UnpackData(v:sub(2), ",")
            end
            if key then
                for i, p in ipairs(params) do
                    params[i] = tonumber(p) or p
                end
                info.lines[key] = params
            end
        end
    end

    -- 提取血量标准化字段（兼容旧 Get / _onDataArrived 接口）
    if info.lines.hp then
        info.health = { value = info.lines.hp[1], max = info.lines.hp[2] }
    end

    return info
end

--------------------------------------------------------------------------------
-- 鼠标悬停实体检测（用于防止 Request 推送覆盖 Show Me 自身的 hint）

local function _ec_GetHoveredEntity()
    local hovered = TheInput:GetHUDEntityUnderMouse()
    if hovered ~= nil then
        hovered = hovered.widget ~= nil and hovered.widget.parent ~= nil and hovered.widget.parent.item
    else
        hovered = TheInput:GetWorldEntityUnderMouse()
    end
    return hovered
end

--------------------------------------------------------------------------------
-- 对外接口

function ShowMeUtil.IsAvailable()
    return MOD_RPC ~= nil
        and MOD_RPC.ShowMeSHint ~= nil
        and MOD_RPC.ShowMeSHint.Hint ~= nil
end

-- 请求该实体全部数据（入队串行发送 + 1s 超时 + 去重）
function ShowMeUtil.Fetch(inst)
    if not inst or not inst:IsValid() or not ShowMeUtil.IsAvailable() then return end

    -- 去重：正在飞行中的请求
    if _ec_inflight and _ec_inflight.target == inst then return end

    -- 去重：已在队列中
    for _, q in ipairs(_ec_query_queue) do
        if q.target == inst then return end
    end

    -- 实体销毁时清理
    inst:ListenForEvent("onremove", function()
        cache[inst] = nil
    end)

    table.insert(_ec_query_queue, { target = inst, guid = inst.GUID })
    _ec_sendNext()
end

-- 读取缓存血量（兼容旧接口） → { value = 当前, max = 最大 }
function ShowMeUtil.Get(inst)
    local info = cache[inst]
    return info and info.health
end

-- 读取全部服务端数据 → { raw, health, lines = { hp, maxhp, armor, planar_defense, damage, ... } }
function ShowMeUtil.GetAll(inst)
    return cache[inst]
end

-- 按字段名读取 → { value1, value2, ... } （如 "armor" → { 0.8, ... }）
function ShowMeUtil.GetField(inst, key)
    local info = cache[inst]
    if info and info.lines then
        return info.lines[key]
    end
end

-- 容器内容检查：实体是否被 Show Me 标记为含有指定 prefab。
-- Show Me 模组在实体上直接挂 ShowMe_chest_table（按 prefab 名索引），此处只读这张表，
-- 不依赖本工具解析的血量缓存。prefab 可为字符串或带 .prefab 的实体。
function ShowMeUtil.ContainerHas(inst, prefab)
    if inst == nil or prefab == nil then return false end
    local t = inst.ShowMe_chest_table
    if t == nil then return false end
    local key = type(prefab) == "table" and prefab.prefab or prefab
    return t[key] ~= nil
end

--------------------------------------------------------------------------------
-- Init：注册网络监听（仅 mod 环境调用一次；写入 cache，供所有模块共享）

function ShowMeUtil.Init()
    if initialized or not ShowMeUtil.IsAvailable() then return end
    initialized = true

    -- 预热映射表
    _ec_buildMappings()

    local function AttachListener(prefab)
        local old_hint
        prefab:ListenForEvent("showme_hint_dirty2", function(player_classified)
            local raw = player_classified.net_showme_hint2
                and player_classified.net_showme_hint2:value()
            if type(raw) ~= "string" then return end
            local guid = _ec_GetHintGUID(raw)

            local inst = Ents[guid]

            -- 匹配队列请求 → 释放 inflight 锁
            if _ec_inflight and guid == _ec_inflight.guid then
                _ec_finishInflight()
            end

            -- 防止我们的 Request 推送覆盖 Show Me 自身悬停提示
            local hovered = _ec_GetHoveredEntity()
            if hovered and hovered.GUID ~= guid and old_hint then
                player_classified.showme_hint2 = old_hint
            else
                old_hint = raw
            end

            if inst then
                local info = _ec_parseAll(raw)
                if info then
                    cache[inst] = info
                    if ShowMeUtil._onDataArrived and info.health then
                        ShowMeUtil._onDataArrived(inst, info.health)
                    end
                end
            end
        end)
    end

    AddPrefabPostInit("player_classified", AttachListener)

    local classified = ThePlayer and ThePlayer.player_classified
    if classified then
        AttachListener(classified)
    end
end

return ShowMeUtil