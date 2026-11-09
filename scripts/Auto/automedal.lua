local InventoryUtil = require "util/inventoryutil"
local InventoryEventService = require "util/inventoryeventservice"
local PlayerUtil = require "util/playerutil"
local ItemUtil = require "util/itemutil"
local ActionUtil = require "util/actionutil"
local WorldUtil = require "util/worldutil"
local ConfigUtil = require "util/configutil"

-- =============================================
-- 自动勋章模块依赖的勋章模组（能力勋章 / Functional Medal）源码路径 d:\Steam\steamapps\workshop\content\322330\1909182187\（本机 mods 目录未安装此模组，其脚本位于 Steam 订阅目录下）
-- =============================================
-- 勋章常量配置表
-- =============================================
local MEDAL = {
    -- 伐木勋章
    chopMedal = {
        actions = { "CHOP" },
        small = { smallchop_certificate = {} },
        medium = { mediumchop_certificate = { "woodcutter" } },
        large = { largechop_certificate = { "woodcutter" } },
    },
    -- 挖矿勋章（清理月雹 REMOVELUNARBUILDUP：矿工勋章加快清理并获取经验）
    minerMedal = {
        actions = { "MINE", "REMOVELUNARBUILDUP" },
        small = { smallminer_certificate = {} },
        medium = { mediumminer_certificate = {} },
        large = { largeminer_certificate = {} },
    },
    -- 钓鱼勋章（仅动作驱动，不绑定鱼竿物品）
    fishingMedal = {
        actions = { "FISH", "OCEAN_FISHING_CAST", "OCEAN_FISHING_REEL" },
        small = { smallfishing_certificate = {} },
        medium = { mediumfishing_certificate = { "fast_kill_fish" } },
        large = { largefishing_certificate = { "fast_kill_fish", "has_largefishing_medal" } },
    },
    -- [采]丰收勋章
    HARVEST_ACTIONS = { "DIG", "NET", "SCYTHE", "MEDALSTAFFDEVOUR" },
    harvest_certificate = { "medal_fastpicker" },
    -- [淘气]淘气勋章
    naughty_certificate = { "naughtymedal" },
    -- [正义]正义勋章（动物目标专用，逮捕只对 krampus 有效故排除 arrest）
    justiceMedal = {
        arrest = { arrest_certificate = {} },
        final = { justice_certificate = { "addjustice" } },
    },
    -- ===== 冒险家 =====
    -- [威尔逊][MOD]炼金勋章
    alchemy_certificate = { "alchemyperson" },
    -- [薇洛]浴火勋章
    bathingfire_certificate = { "has_bathfire_medal", "pyromaniac", "bernieowner", "expertchef" },
    -- [沃尔夫冈][MOD]大力士勋章
    -- [温蒂]
    -- [WX-78]
    -- [薇克巴顿]智慧勋章
    wisdomMedal = {
        test = { wisdom_test_certificate = {} },
        final = { wisdom_certificate = { "bookbuilder", "wisdombuilder" } },
    },
    -- [伍迪]
    -- [韦斯]沉默勋章
    silence_certificate = { "mime", "balloonomancer" },
    -- [麦斯威尔]暗影魔法勋章
    shadowmagic_certificate = { "shadowmagic", "has_shadowmagic_medal" },
    -- [薇格弗德]女武神勋章
    valkyrieMedal = {
        examine = { valkyrie_examine_certificate = {} },
        test = { valkyrie_test_certificate = {} },
        final = { valkyrie_certificate = { "valkyrie" } },
    },
    -- [韦伯]蜘蛛勋章
    spiderMedal = {
        final = { spider_certificate = { "spiderwhisperer", "spider_upgradeuser" } },
    },
    -- [薇诺娜]巧手勋章
    HANDY_ACTIONS = { "BUILD", "UNWRAP", "UNWRAPGIFTFRUIT", "UNWRAPOVERSIZEDGIFTFRUIT" },
    handy_test_certificate = {},
    handy_certificate = { "handyperson", "basicengineer", "has_handy_medal" },
    -- [沃利]主厨勋章
    chefMedal = {
        actions = { "COOK", "CHEFFLAVOUR", "MEDAL_EAT_SPICES", "MEDALPOLLUTE", "MEDAL_GRINDING", "MAKECOOLDOWN" },
        test = { cook_certificate = {} },
        level = { chef_certificate = { "masterchef", "professionalchef", "expertchef" } },
        final = { headchef_certificate = { "masterchef", "professionalchef", "expertchef", "seasoningchef" } },
    },
    -- [沃拓克斯]噬魂勋章
    devoursoulMedal = {
        devour = { devour_soul_certificate = { "soulstealer", "medal_blinker" } },
        soul = { medium_devour_soul_certificate = { "soulstealer", "medal_blinker" } },
        void = { large_devour_soul_certificate = { "soulstealer", "medal_blinker", "medal_map_blinker" } },
    },
    -- [沃姆伍德]植物勋章
    plantMedal = {
        actions = { "PLANT", "PLANTSOIL", "TERRAFORM", "PUT_IN_THE_SEEDS",
            "GRAFTING_TREE", "MEDAL_FRUIT_TREE_LEVEL_UP", "MAKEMUSHTREE",
            "MAKEMANDRAKEPLANT", "MEDALMOONTREEHARVEST", "MEDALTREEROCKSHARVEST" },
        level = { plant_certificate = { "plantkin", "has_plant_medal" } },
        final = { transplant_certificate = { "plantkin", "has_plant_medal", "has_transplant_medal" } },
    },
    -- [沃特]鱼人勋章
    mermMedal = {
        final = { merm_certificate = { "merm_builder", "merm", "playermerm", "stronggrip", "mermfluent" } },
    },
    -- [沃尔特]童心勋章
    childMedal = {
        level = { childishness_certificate = { "pebblemaker", "slingshot_sharpshooter", "pinetreepioneer", "troublemaker", "has_childishness" } },
        final = { childlike_certificate = { "pebblemaker", "slingshot_sharpshooter", "pinetreepioneer", "troublemaker", "has_childishness", "senior_childishness" } },
    },
    -- [旺达]
    -- [芜猴]
    -- 友善勋章
    friendlyMedal = {
        level = { friendly_certificate = {} },
        final = { bosom_friend_certificate = {} },
    },
    -- [蜂王]蜂王勋章
    bee_king_certificate = { "is_bee_king", "insect" },
    -- [触手]触手勋章
    tentacle_certificate = { "tentaclemedal" },
    -- 传承勋章
    inherit_certificate = { "traditionalbearer1", "traditionalbearer2", "traditionalbearer3", "traditionalbearer4" },
    -- 羽绒勋章
    down_filled_coat_certificate = {},
    -- 蓝晶勋章
    blue_crystal_certificate = {},
    -- 踏水勋章
    treadwater_certificate = {},
    -- 复眼勋章
    ommateum_certificate = {},
    -- 空间/时空勋章（移动触发）
    speedMedal = {
        actions = { "WALKTO" },
        speed = { speed_certificate = {} },
        space = { space_certificate = { "space_medal" } },
        final = { space_time_certificate = { "space_medal", "spacetime_medal" } },
    },
    -- 空白勋章
    blank_certificate = {},
    -- 仿制勋章 prefab（印刻用空白模板）
    copy_blank_certificate = {},
    -- 融合勋章
    multivariate_certificate = { "multivariate_certificate" },
    medium_multivariate_certificate = { "multivariate_certificate" },
    large_multivariate_certificate = { "multivariate_certificate" },
    origin_certificate = { "multivariate_certificate", "has_origin_medal" },
    -- ===== 特殊配置 =====
    BATHINGFIRE_ARMORS = {
        armor_medal_obsidian   = true, -- 红晶甲
        armor_blue_crystal     = true, -- 蓝晶甲
        armor_medal_space_time = true, -- 时空晶甲
    },
}

local function IsMedalTagList(value)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do
        if type(key) ~= "number" then return false end
    end
    return true
end

local M = setmetatable({}, {
    __index = function(_, k)
        local full = k .. "_certificate"
        if MEDAL[full] then return full end
        return k
    end
})

local _craft_builder_pending = nil
-- 融合箱常驻勋章组：与融合箱同时佩戴一般不会卸下，箱满换出腾位时排除
local RESIDENT_GROUPTAGS = { "speedMedal", "devoursoulMedal" }
local medal_priority = {}
local medal_groups = {}
local prefab_to_grouptag = {}
local MEDAL_DEFS = nil  -- BuildMedalGroups 动态填充（require 勋章模组数据）

-- 从 MEDAL_DEFS 直接获取组内 isfinal 勋章 prefab
-- 注：MEDAL_DEFS 由 BuildMedalGroups() 在运行时填充，模块加载时 nil
local function GetFinalPrefab(grouptag)
    if not MEDAL_DEFS then
        return nil
    end
    for name, def in pairs(MEDAL_DEFS) do
        if (def.grouptag or name) == grouptag and def.isfinal then
            return name
        end
    end
    return nil
end

-- ============================================================
-- 动作→勋章组配置
-- ============================================================

-- 动作→勋章组grouptag映射（action_id → [grouptag/prefab, ...]）
-- 由 BuildActionGroupMap 从 MEDAL 表的 actions 字段动态构建
local ACTION_GROUPTAG_MAP = {}

-- 精细化动作→勋章映射已合并进 Init 内的 MEDAL_ACTION_RULES（R1：三套并行 → 一套）

-- 从 MEDAL.actions 构建 ACTION_GROUPTAG_MAP
-- 遍历 MEDAL 中所有含 actions 字段的组，以及 HARVEST_ACTIONS 特殊配置
local function BuildActionGroupMap()
    if next(ACTION_GROUPTAG_MAP) ~= nil then return end
    for grouptag, group in pairs(MEDAL) do
        if type(group) == "table" and group.actions then
            for _, action_id in ipairs(group.actions) do
                if not ACTION_GROUPTAG_MAP[action_id] then
                    ACTION_GROUPTAG_MAP[action_id] = {}
                end
                table.insert(ACTION_GROUPTAG_MAP[action_id], grouptag)
            end
        end
    end
    -- 丰收勋章：非 group 勋章，动态 prefab 名（M），动作列表存于 MEDAL.HARVEST_ACTIONS
    local harvest_pf = M.harvest
    if harvest_pf and MEDAL.HARVEST_ACTIONS then
        for _, action_id in ipairs(MEDAL.HARVEST_ACTIONS) do
            if not ACTION_GROUPTAG_MAP[action_id] then
                ACTION_GROUPTAG_MAP[action_id] = {}
            end
            table.insert(ACTION_GROUPTAG_MAP[action_id], harvest_pf)
        end
    end
end
-- =============================================
-- 跨组优先级规则:当多个勋章组同时匹配时，用规则决定最终选择
-- =============================================
local PRIORITY_RULES = {}
-- =============================================
-- 融合勋章内容缓存 {[GUID] = {prefab = true, ...}}
-- =============================================
local _fusion_cache = {}
local _fusion_listener_initialized = false
local _fusion_bound_classified = nil  -- 换人/迁洞会生成新的 player_classified，需重绑

local function _SendItemInfoRequest(item)
    if not item or not item.GUID then return false end
    local rpc = GLOBAL.MOD_RPC
        and GLOBAL.MOD_RPC["Functional_medal"]
        and GLOBAL.MOD_RPC["Functional_medal"]["Showinfo"]
    if not rpc then
        return false
    end
    GLOBAL.SendModRPCToServer(rpc, item.GUID, item)
    return true
end

-- 取融合箱内容（异步，结果由 medal_infodirty 回填）。去重按时间窗口，丢包后能自动重发。
local function _RequestFusionInfo(item)
    if not item or not item.GUID then return end
    if _fusion_cache[item.GUID] ~= nil then return end
    local last = _fusion_cache._pending and _fusion_cache._pending[item.GUID]
    if last ~= nil and GetTime() - last < 0.5 then return end

    if _SendItemInfoRequest(item) then
        if _fusion_cache._pending == nil then _fusion_cache._pending = {} end
        _fusion_cache._pending[item.GUID] = GetTime()
    end
end

-- DisplayName → prefab 反向映射（从 STRINGS.NAMES 构建）
local _name_to_prefab = nil
local function _GetNameToPrefabMap()
    if _name_to_prefab then return _name_to_prefab end
    _name_to_prefab = {}
    local names = GLOBAL.STRINGS.NAMES
    if names then
        for k, v in pairs(names) do
            if type(k) == "string" and type(v) == "string" and v ~= "" then
                _name_to_prefab[v] = string.lower(k)
            end
        end
    end
    return _name_to_prefab
end

-- 监听 medal_infodirty 事件，解析 medal_info 并更新缓存
local function _InitFusionCacheListener()
    local classified = ThePlayer ~= nil and ThePlayer.player_classified or nil
    if classified == nil then return end
    -- 认实例而非布尔标记：换了 classified 必须重绑，否则回包永远收不到
    if _fusion_listener_initialized and _fusion_bound_classified == classified then
        return
    end
    _fusion_bound_classified = classified
    _fusion_listener_initialized = true
    classified:ListenForEvent("medal_infodirty", function(inst)
        local info = inst.medal_info
        if not info or info == "" then
            return
        end
        -- 格式: "guid;DisplayName1|DisplayName2|*"
        local semicolon = string.find(info, ";", 1, true)
        if not semicolon then
            return
        end
        local guid = tonumber(string.sub(info, 1, semicolon - 1))
        if not guid then
            return
        end
        -- 清除 pending 标记（无论内容是否为空）
        if _fusion_cache._pending then
            _fusion_cache._pending[guid] = nil
        end
        local contents = string.sub(info, semicolon + 1)
        if contents == "" then
            _fusion_cache[guid] = {}
            return
        end
        -- 显示名含换行（"勋章1|\n勋章2|*"），需去首尾空白再反查 prefab
        local name_to_prefab = _GetNameToPrefabMap()
        local prefabs = {}
        for raw in string.gmatch(contents, "[^|]+") do
            local name = string.match(raw, "^%s*(.-)%s*$")
            if name and name ~= "" and name ~= "*" then
                local prefab = name_to_prefab[name]
                if prefab then
                    prefabs[prefab] = true
                end
            end
        end
        _fusion_cache[guid] = prefabs
    end)
end

-- 逐槽遍历容器（replica / components 通用）。槽位索引数组有 nil 空洞，必须按槽位数遍历。
-- fn(slot_item, slot) 返回非 nil 即中断并返回该值
local function ForEachContainerSlot(container, fn)
    if container == nil then return nil end
    local num = InventoryUtil:GetSlotCount(container)
    if num <= 0 then return nil end
    for slot = 1, num do
        local ret = fn(container:GetItemInSlot(slot), slot)
        if ret ~= nil then return ret end
    end
    return nil
end

-- 读融合箱内容：① 容器实时读 → ② 缓存 → ③ 都没有则发一次 RPC 并返回 nil（内容未知）
-- prefabs 为 nil 时返回全部 prefab 集合，否则返回命中的那个 prefab
local function ReadFusionContents(item, prefabs)
    if not item or not item.GUID then
        return nil
    end

    _InitFusionCacheListener()

    local cached = nil

    -- ① 容器实时读（佩戴中的融合箱常开）
    if item.replica and item.replica.container then
        local container = item.replica.container
        -- 槽位数为 0 = 数据不可用，不能当"空箱"写缓存（否则该箱再也发不出 RPC）
        if InventoryUtil:IsContainerOpened(container)
            and InventoryUtil:GetSlotCount(container) > 0 then
            cached = {}
            ForEachContainerSlot(container, function(slot_item)
                if slot_item and slot_item.prefab then
                    cached[slot_item.prefab] = true
                end
            end)
            _fusion_cache[item.GUID] = cached
        end
    end

    -- ② 缓存
    if not cached then
        cached = _fusion_cache[item.GUID]
    end

    -- ③ 取数据（异步）
    if not cached then
        _RequestFusionInfo(item)
        return nil
    end

    if _fusion_cache._pending then
        _fusion_cache._pending[item.GUID] = nil
    end

    if prefabs then
        for _, pf in ipairs(prefabs) do
            if cached[pf] then
                return pf
            end
        end
        return nil
    else
        return cached
    end
end
-- 融合勋章判定：勋章模组给 4 个融合勋章（含本源）统一的实体标签
-- （multivariate_certificate.lua:158，SetPristine 前 AddTag）
-- 不用 classified 容器判定——medal_box 等存储箱也有 classified，会误判
local function IsFusionBox(item)
    return item ~= nil and item.HasTag ~= nil and item:HasTag("multivariate_certificate")
end

-- 给所有内容未知的融合箱补发一次 RPC（只取数据，不参与裁决）
local function PrimeFusionInfo()
    for _, it in pairs(InventoryUtil:GetPlayerInventory(true, false, true)) do
        if IsFusionBox(it) then
            _RequestFusionInfo(it)
        end
    end
end

-- 从融合勋章内部查找指定prefab的物品实体引用
-- 通过实体树直接访问，无需 classified 同步
local function FindItemInFusion(item, prefab)
    if not item or not prefab then return nil end

    local function match(slot_item)
        if slot_item and slot_item.prefab == prefab then return slot_item end
    end

    -- 路径1: replica.container（佩戴中的融合箱 opener+classified 已同步）
    local found = item.replica and ForEachContainerSlot(item.replica.container, match)
    if found then return found end

    -- 路径2: 主世界模式直接读 components.container
    if WorldUtil:IsMasterSim() and item.components then
        found = ForEachContainerSlot(item.components.container, match)
        if found then return found end
    end

    -- 缓存只有 prefab 名、没有实体引用，不按 prefab 去背包猜（会命中箱外同名勋章）。
    -- 需要布尔结论走 IsPrefabInFusion。
    return nil
end

-- 融合箱内是否含指定 prefab（布尔结论；缓存可用即可判定，无需实体引用）
local function IsPrefabInFusion(box, prefab)
    if not box or not prefab then return false end
    if not IsFusionBox(box) then return false end
    local contents = ReadFusionContents(box)
    return contents ~= nil and contents[prefab] == true or false
end

-- =============================================
-- 仿制勋章识别（参考 3638564451）
-- =============================================

local function GetEffectivePrefab(item)
    if not item then return nil end
    local prefab = item.prefab
    if prefab == M.copy_blank then
        local name = nil
        if item.blankmedalchangename then
            name = item.blankmedalchangename:value()
        end
        if (not name or name == M.copy_blank) and item.medalname then
            name = item.medalname
        end
        if name and name ~= M.copy_blank then
            local ampersand_pos = string.find(name, "&")
            if ampersand_pos then
                return string.sub(name, 1, ampersand_pos - 1)
            end
            return name
        end
    end
    return prefab
end

-- 统一优先级裁决（合并 medal_priority 档位与 PRIORITY_RULES 跨组主导两套逻辑）
-- 先按跨组主导规则解决不同组冲突；同组（或无组信息）时再按档位数值选出最优
-- 返回 true 表示 prefabA 优先级高于 prefabB
local function IsBetterMedal(prefabA, prefabB)
    if prefabA == prefabB then return false end
    local ga = prefab_to_grouptag[prefabA]
    local gb = prefab_to_grouptag[prefabB]
    -- 不同组：仅由跨组主导规则裁决；无规则则不分优劣（保持原可替换行为）
    if ga and gb and ga ~= gb then
        local rules = PRIORITY_RULES
        if rules[prefabA] and rules[prefabA][prefabB] then return true end
        if rules[prefabB] and rules[prefabB][prefabA] then return false end
        return false
    end
    -- 同组（或无组信息）：按档位数值 isfinal3 > 无耐久2 > 有耐久1 > 0
    local pa = medal_priority[prefabA] or 0
    local pb = medal_priority[prefabB] or 0
    return pa > pb
end

-- 从 MEDAL 表群组条目提取 prefab（medal_groups 不可用时兜底）
-- MEDAL 群组结构: { category = { prefab = taglist }, ... }（固定一层嵌套）
local function _CollectMedalPrefabs(entry)
    local result = {}
    local seen = {}
    for _, sub in pairs(entry) do
        if type(sub) == "table" then
            for prefab in pairs(sub) do
                if type(prefab) == "string" and prefab:find("_certificate") and not seen[prefab] then
                    seen[prefab] = true
                    table.insert(result, prefab)
                end
            end
        end
    end
    return result
end

-- 从grouptag获取prefab列表
local function GetGroup(grouptag)
    if type(grouptag) == "table" then
        local result = {}
        for _, gt in ipairs(grouptag) do
            if medal_groups[gt] then
                for _, prefab in ipairs(medal_groups[gt]) do
                    table.insert(result, prefab)
                end
            end
        end
        return result
    end
    return medal_groups[grouptag] or _CollectMedalPrefabs(MEDAL[grouptag] or {})
end

local function GetMedalsByPlayerTag(tag)
    local prefabs = {}
    local seen = {}
    local function visit(node)
        for prefab, tags in pairs(node) do
            if IsMedalTagList(tags) then
                if table.contains(tags, tag) and not seen[prefab] then
                    seen[prefab] = true
                    prefabs[#prefabs + 1] = prefab
                end
            elseif type(tags) == "table" then
                visit(tags)
            end
        end
    end
    visit(MEDAL)
    return #prefabs > 0 and prefabs or nil
end

-- =============================================
-- 工具函数
-- =============================================
local function MedalExcluded(item)
    return ItemUtil:IsBroken(item) or ItemUtil:ShouldAutoUnequip(item)
end

local function GetEquippedMedal()
    return InventoryUtil:GetEquippedItemBySlot(EQUIPSLOTS.MEDAL)
end

-- 物品自身 prefab（含刻印变体归一）是否命中目标列表
local function MatchesAny(item, prefabs)
    if not item then return false end
    local effective = GetEffectivePrefab(item)
    for _, pf in ipairs(prefabs) do
        if effective == pf or item.prefab == pf then
            return true
        end
    end
    return false
end

local function FindMedal(prefabs, no_fusion, real_only)
    if #prefabs == 0 then return nil end
    local items = InventoryUtil:GetPlayerInventory(true, false, true)
    local equipped_medal = GetEquippedMedal()
    local equipped_guid = equipped_medal and equipped_medal.GUID
    local single_prefab = (#prefabs == 1) and prefabs[1] or nil

    -- 先处理已佩戴中的融合勋章：目标在其中时直接装备该融合箱，避免单勋章被误判为未命中。
    -- 必须按 prefabs 显式确认目标确在箱内（ReadFusionContents 带 prefabs 时返回命中项），
    -- 否则 no_fusion=nil 档（女武神/速度）会误把融合箱当源物，生成"把佩戴箱自己换进自己槽"的无效 plan
    if equipped_medal and IsFusionBox(equipped_medal) and not no_fusion
        and ReadFusionContents(equipped_medal, prefabs) then
        return equipped_medal
    end

    -- 单勋章优先：直接装备单勋章，只有在融合勋章内时才直接装备所在融合勋章
    if single_prefab then
        local item = InventoryUtil:FindItemAnywhere(function(item)
            if equipped_guid and item.GUID == equipped_guid then return false end
            if not ItemUtil:IsMedal(item) then return false end
            if MedalExcluded(item) then return false end
            if real_only and item.prefab == M.copy_blank then return false end
            local eff = GetEffectivePrefab(item)
            return eff == single_prefab or item.prefab == single_prefab
        end)
        if item then

            return item
        end
    end

    -- 融合勋章：目标勋章在融合箱内则装备对应融合箱
    -- （新规：多融合箱场景目标在融合内优先装备箱；只有目标是单勋章才 WEARMEDAL 佩戴）
    -- no_fusion=true 时跳过（攻击链补位/本源联动只认零散单勋章）
    -- RPC 频率安全：_RequestFusionInfo 有 pending 防重，每个箱最多一次 Showinfo 请求
    if not no_fusion then
        local box_item = InventoryUtil:FindItemAnywhere(function(item)
            if equipped_guid and item.GUID == equipped_guid then return false end
            return IsFusionBox(item) and ReadFusionContents(item, prefabs)
        end)
        if box_item then
            return box_item
        end
    end

    -- 第二轮：独立的单勋章（直接 prefab 匹配）
    -- 收集所有匹配项，按 priority 选最优（isfinal=3 > 无耐久=2 > 有耐久=1 > 未定义=0）
    local best_item = nil
    local best_priority = -1
    for _, item in pairs(items) do
        if not (equipped_guid and item.GUID == equipped_guid) then
            if ItemUtil:IsMedal(item) and not MedalExcluded(item) then
                -- real_only：练级匹配只认正品，刻印变体不可升级不构成练级目标
                if not (real_only and item.prefab == M.copy_blank) then
                    if MatchesAny(item, prefabs) then
                        local pri = medal_priority[GetEffectivePrefab(item)] or medal_priority[item.prefab] or 0
                        -- 刻印变体不可升级：永远低于所有正品（0~3 档全部让位，正品存在时正品优先），
                        -- 仅无正品时作为功能兜底；变体之间仍保留档位顺序（最终体变体 > 无耐久变体 > 有耐久变体）
                        if item.prefab == M.copy_blank then
                            pri = pri - 2.5
                        end
                        if pri > best_priority then
                            best_priority = pri
                            best_item = item
                        end
                    end
                end
            end
        end
    end
    if best_item then
        return best_item
    end

    return nil
end

-- 检查物品是否当前已装备在勋章槽位（通过GUID比较，避免对象引用身份问题）
local function IsSameAsEquippedMedal(item)
    if not item or not item.GUID then return false end
    local equipped = GetEquippedMedal()
    if not equipped then return false end
    return item.GUID == equipped.GUID
end

-- =============================================
-- 统一装备方法（勋章 + 手部共用）
-- 返回：true=已装备/已就绪，nil=无匹配（盒内等容器勋章可直接佩戴，无需取回）
-- =============================================

-- 融合箱常驻勋章 prefab 集合（懒构建，BuildMedalGroups 之后首次调用）
local _resident_prefabs = nil
local function GetResidentPrefabs()
    if _resident_prefabs == nil then
        _resident_prefabs = {}
        for _, gt in ipairs(RESIDENT_GROUPTAGS) do
            for _, pf in ipairs(GetGroup(gt)) do
                _resident_prefabs[pf] = true
            end
        end
    end
    return _resident_prefabs
end
-- =============================================
-- 攻击链相关勋章集合（换出腾位时排除——战斗时不可换出战斗勋章）
-- 含分组勋章与独立攻击勋章；皮肤/刻印变体经 GetEffectivePrefab 归一后同样命中
local _attack_prefabs = nil
local function GetAttackPrefabSet()
    if _attack_prefabs == nil then
        _attack_prefabs = {}
        local function add_group(gt)
            for _, pf in ipairs(GetGroup(gt)) do
                _attack_prefabs[pf] = true
            end
        end
        add_group("valkyrieMedal")
        add_group("justiceMedal")
        add_group("devoursoulMedal")
        add_group("speedMedal")
        _attack_prefabs[M.bee_king] = true
        _attack_prefabs[M.shadowmagic] = true
        _attack_prefabs[M.tentacle] = true
        _attack_prefabs[M.valkyrie_test] = true
        _attack_prefabs[M.bathingfire] = true
        _attack_prefabs[M.silence] = true
    end
    return _attack_prefabs
end

-- 计算上下文动态优先级提升集合（供 PickRemovableContent 使用）
-- 按"上下文相关勋章→elevated(100)"统一优先级，取代分散的 target_set/elevated_set 冗余逻辑
-- @param is_attack: true=攻击链上下文（attack_prefabs 加入 elevated）
-- @return elevated_set
local function _ComputeContextElevation(is_attack)
    local elevated = {}

    -- 工作动画期间：当前工作勋章动态优先级最高
    local prev_action = ActionUtil:GetLastActionId()
    if not is_attack and prev_action and ThePlayer and ThePlayer.sg
        and (ThePlayer.sg:HasStateTag("working") or ThePlayer.sg:HasStateTag("fishing")
            or ThePlayer.sg:HasStateTag("doing") or ThePlayer.sg:HasStateTag("busy")) then
        local grouptags = ACTION_GROUPTAG_MAP[prev_action]
        if grouptags then
            for _, gt in ipairs(grouptags) do
                local group = medal_groups[gt] or medal_groups[prefab_to_grouptag[gt]]
                if group then
                    for _, pf in ipairs(group) do
                        elevated[pf] = true
                    end
                else
                    elevated[gt] = true
                end
            end
        end
    end

    -- 攻击链上下文：攻击勋章加入 elevated
    if is_attack then
        for pf in pairs(GetAttackPrefabSet()) do
            elevated[pf] = true
        end
    end

    return elevated
end

-- 判断勋章是否为可换出内容：非常驻（速度/噬魂）、非硬保护集
local function IsRemovableContent(slot_item, target_set)
    if not slot_item or not slot_item.prefab then return false end
    if GetResidentPrefabs()[slot_item.prefab] then return false end
    local eff = GetEffectivePrefab(slot_item)
    if GetResidentPrefabs()[eff] then return false end  -- 刻印变体按有效 prefab 判常驻
    -- 海上守护：踏水勋章不得被任何勋章从融合箱换出
    if PlayerUtil:IsOnOcean(false) and slot_item.prefab == M.treadwater then
        return false
    end
    return not target_set[slot_item.prefab] and not target_set[eff]
end

-- 战斗勋章换出档位（懒构建，BuildMedalGroups 之后首次调用）：
-- 战斗勋章换出档位：数值越大越后换出，档位与攻击链顺序相反
-- 前置条件不满足 → 降为非战斗勋章（优先被换出），避免无效占用融合箱槽位
-- 速度/噬魂为常驻勋章（RESIDENT_GROUPTAGS），由 IsRemovableContent 保护，不参与档位排序
local _combat_evict_rank = nil
local function GetCombatEvictRank(pf)
    if _combat_evict_rank == nil then
        _combat_evict_rank = {}
        local rank = 0
        local function add(name, is_group)
            rank = rank + 1
            _combat_evict_rank[name] = rank
            if is_group then
                for _, p in ipairs(GetGroup(name)) do
                    _combat_evict_rank[p] = rank
                end
            end
        end
        add("justiceMedal", true)  -- 1: 功能选择低优先级（boss负面抵抗/掉落物）
        add(M.tentacle, false)     -- 2: 期望值伤害低（依赖目标移速）
        add(M.bathingfire, false)  -- 3: 需本源+晶甲，前置不满足降非战斗
        add(M.shadowmagic, false)  -- 4: 需方尖锏，前置不满足降非战斗
        add(M.bee_king, false)     -- 5: 纯战斗直接加伤害
        add(M.silence, false)      -- 6: 需本源，累积伤害不可丢
        add("valkyrieMedal", true) -- 7: 伤害+免伤+吸血，最后换出
    end
    local rank = _combat_evict_rank[pf]
    if not rank then return nil end

    -- 前置条件不满足 → 降为非战斗勋章（不返回 rank，PickRemovableContent 走 medal_priority 0~3 优先换出）
    local bathingfire_pf = M.bathingfire
    local shadowmagic_pf = M.shadowmagic
    local silence_pf = M.silence
    if pf == bathingfire_pf then
        if not ThePlayer or not ThePlayer:HasTag("has_origin_medal") then return nil end
        local body = InventoryUtil:FindEquipped(function(item)
            return item and MEDAL.BATHINGFIRE_ARMORS[item.prefab]
        end)
        if not body then return nil end
    elseif pf == shadowmagic_pf then
        if not InventoryUtil:HasEquipped(function(item)
            -- 方尖锏：shadowlevel 也被暗影魔法勋章自身携带，叠加 weapon 才区分得开
            return item and item:HasTag("shadowlevel") and item:HasTag("weapon")
        end) then return nil end
    elseif pf == silence_pf then
        if not ThePlayer or not ThePlayer:HasOriginMedal("mime") then return nil end
    end
    return rank
end

-- 从已佩戴融合箱中挑选可换出勋章：非战斗勋章按 medal_priority 低→高换出；
-- 无非战斗勋章可换时，战斗勋章按攻击链档位低→高换出（速度兜底最先，女武神最后）
-- 常驻勋章（速度/噬魂）不换；联动目标不换
-- target_prefabs: 硬保护集（不可换出）；elevated_prefabs: 动态优先级提升至 100（最高，仅当无其他选择时才换出）
-- 返回 item, slot（找不到返回 nil）
-- occupied: 可选集合（批量预算时传入），标记已被批量计划占用的槽位，这些槽不能再选作 victim 源
local function PickRemovableContent(box, target_prefabs, elevated_prefabs, occupied)
    if not box or not IsFusionBox(box) then return nil end
    -- 仅已装备融合箱 classified 已同步，可读取内容实体
    local container = box.replica and box.replica.container
    if not container then return nil end

    local target_set = {}
    -- 兼容数组与键控集合两种传入形式（ipairs 只认数组部分，键控集合会被漏掉）
    for _, pf in pairs(target_prefabs or {}) do
        target_set[pf] = true
    end
    local elevated_set = {}
    for _, pf in pairs(elevated_prefabs or {}) do
        elevated_set[pf] = true
    end

    local best_item = nil
    local best_slot = nil
    local best_priority = math.huge
    ForEachContainerSlot(container, function(slot_item, slot)
        if occupied and occupied[slot] then return end
        if not IsRemovableContent(slot_item, target_set) then return end
        local eff = GetEffectivePrefab(slot_item)
        -- 动态优先级：elevated 勋章优先级最高（100），其次战斗勋章(11-19)，最后非战斗(0-3)
        local pri
        if elevated_set[eff] or elevated_set[slot_item.prefab] then
            pri = 100
        else
            local combat_rank = GetCombatEvictRank(eff)
            pri = combat_rank and (10 + combat_rank)
                or medal_priority[eff] or medal_priority[slot_item.prefab] or 0
        end
        -- 同优先级按容器 slot 倒序替换（高 slot 先被换出，工作勋章通常在最后一格）
        if pri < best_priority or (pri == best_priority and slot > (best_slot or 0)) then
            best_priority = pri
            best_item = slot_item
            best_slot = slot
        end
    end)
    return best_item, best_slot
end

-- =============================================
-- 直换链路：目标勋章取上鼠标 → 换入本源槽位 → 被换出勋章物归原位
-- 裸 RPC 同帧连发（绕过 classified 封装层 busy 门，与 sort.lua 快速移动逻辑同款），
-- 0.15s 后一次终检对账；交换不需要空槽，无需先摘除腾位
-- =============================================

-- 查找容器第一个空槽。occupied: 可选集合（批量预算时传入），标记已被批量计划占用的槽位
local function FindEmptySlotInContainer(container_replica, occupied)
    return ForEachContainerSlot(container_replica, function(slot_item, slot)
        if slot_item == nil and not (occupied and occupied[slot]) then
            return slot
        end
    end)
end

-- 目标同组勋章是否已在箱内（contents 为 ReadFusionContents 的 prefab 键控集合）
-- itemtestfn 为容器级检查（medal_ui.lua）：not (item.grouptag and container.inst:HasTag(item.grouptag))，
-- 同组在箱则 swap 会被服端拒绝，必须走 WEARMEDAL 同组替换
local function HasSameGroupInContents(contents, pf)
    local group = prefab_to_grouptag[pf]
    if not group then return false end
    for other_pf in pairs(contents or {}) do
        if other_pf ~= pf and prefab_to_grouptag[other_pf] == group then
            return true
        end
    end
    return false
end

-- 直换单勋章入本源（连发）：
--   目标取上鼠标 → Swap/Put 入本源槽位 → 被换出勋章放回目标源槽
--   0.15s 后一次终检对账：RPC 走可靠有序通道按序执行，服端处理器全部原子拒绝
--   （itemtestfn/空槽/光标占用整条 no-op），失败自愈为"无事发生"或光标残留，终检清理兜底
-- origin：本源勋章 replica；target：目标单勋章；dst_slot：本源目标槽位；victim：槽位原住民（空槽 nil）
-- 完成后清本源融合缓存：swap 不触发 medal_infodirty，下次读取从 replica 容器直接重建
-- on_done(ok)：ok=false 换入未生效（已尽力清理鼠标，调用方回退 WEARMEDAL）
local function SwapMedalIntoTargetBox(origin, target, dst_slot, victim, on_done, check)
    if not InventoryUtil:GetInventory() then
        if on_done then on_done(false) end
        return
    end

    local src_replica, src_slot, src_kind = InventoryUtil:FindItemContainer(target)
    if not src_replica or not src_slot then

        if on_done then on_done(false) end
        return
    end
    if InventoryUtil:GetActiveItem() ~= nil then
        -- 鼠标被占用（手持物品时无法走 cursor 三连 RPC 路径），回退为 WEARMEDAL
        -- （走统一工具函数：单世界 PushAction、客机 RPC，模组动作自动带 mod_name）
        InventoryUtil:SendEquipAction(ACTIONS.WEARMEDAL, target, "workshop-1909182187")
        if on_done then on_done(true) end
        return
    end
    local origin_container = origin.replica and origin.replica.container
    if not origin_container then

        if on_done then on_done(false) end
        return
    end



    -- 连发：复用通用容器间 swap 底层（物品栏源传 nil，RPC 默认发往玩家本体，与 sort.lua 同款）
    local src_entity = src_kind == "container" and src_replica.inst or nil
    InventoryUtil:SwapContainerSlots(src_entity, src_slot, origin_container.inst, dst_slot, victim and "swap" or "put")

    if check == false then
        -- 批量模式：跳过单枚终检，由调用方在批量末尾统一终检/对账（加速连续换入，避免极快动作下来不及）
        if on_done then on_done(true) end
        return
    end

    -- 终检对账：0.15s 后副本已同步服端真实状态，一次性核对并清理
    ThePlayer:DoTaskInTime(0.15, function()
        local items = origin_container:GetItems()
        local slot_item = items and items[dst_slot] or nil
        local cursor = InventoryUtil:GetActiveItem()
        if slot_item and slot_item.GUID == target.GUID and cursor == nil then
            -- 本源融合缓存作废：swap 不触发 medal_infodirty，下次读取直接重建
            if _fusion_cache and origin.GUID then
                _fusion_cache[origin.GUID] = nil
            end
            if on_done then on_done(true) end
        else
            -- 失败多为自愈式"无事发生"（原子拒绝）；少数情况光标残留（终段 Put 被拒），放回目标源槽清理。
            -- 只清理这枚勋章自己：0.15s 内玩家可能已拿起别的东西，不能无脑塞回 src 槽。
            if cursor ~= nil and target.GUID ~= nil and cursor.GUID == target.GUID then
                SendRPCToServer(RPC.PutAllOfActiveItemInSlot, src_slot, src_entity)
            end
            if on_done then on_done(false) end
        end
    end)
end

-- 批量直换：plans 是预算好的点对点连线 [{src_entity, src_slot, dst_slot, swapMode}]
-- 一次性连发所有 swap RPC（每枚三连自包含、鼠标在每枚末尾归位），最后 0.15s 统一终检+清鼠标
-- 调用方负责预算连线（读一次内容，分配 src/dst/victim，标记 occupied），保证 src/dst 互不冲突
-- _swap_flush_now：true 时跳过"下一帧分帧发送"、当场同步发出。
--   只有制作/建造路径需要：它紧接着就发制作 RPC，分帧会把 swap 排到制作之后，
--   服端先执行制作、巧手还没进箱（攻击链等路径保持分帧，避免 RPC 限流）。
local _swap_flush_now = false
local function BatchSwapMedalsIntoTargetBox(target, plans, on_done)
    if not InventoryUtil:GetInventory() then
        if on_done then on_done(false) end
        return
    end
    if InventoryUtil:GetActiveItem() ~= nil then
        -- 鼠标占用：批量三连路径不可用，整批失败（调用方逐枚 WEARMEDAL 回退）
        if on_done then on_done(false) end
        return
    end
    local target_container = target.replica and target.replica.container
    if not target_container then
        if on_done then on_done(false) end
        return
    end
    local function send_range(first, last)
        for i = first, last do
            local p = plans[i]
            InventoryUtil:SwapContainerSlots(p.src_entity, p.src_slot, target_container.inst, p.dst_slot, p.swapMode)
        end
    end

    local function finalize()
        ThePlayer:DoTaskInTime(0.15, function()
            local cursor = InventoryUtil:GetActiveItem()
            if cursor ~= nil then
                -- 异常光标残留：只清理"本次批量遗留"的那枚——按 GUID 在 plans 里找到它自己的
                -- 源槽放回。绝不能无脑塞进 plans[1] 的槽：0.15s 内玩家可能已经自己拿起了
                -- 别的东西，那会把玩家手上的物品塞进勋章盒（且多枚残留时会放错槽）。
                for i = 1, #plans do
                    local p = plans[i]
                    if p.item ~= nil and p.item.GUID ~= nil and p.item.GUID == cursor.GUID then
                        SendRPCToServer(RPC.PutAllOfActiveItemInSlot, p.src_slot, p.src_entity)
                        break
                    end
                end
            end
            if _fusion_cache and target.GUID then
                _fusion_cache[target.GUID] = nil
            end
            if on_done then on_done(true) end
        end)
    end

    if _swap_flush_now then
        send_range(1, #plans)
        finalize()
        return
    end

    -- 分帧发送：本函数由 OnControl 同步调用，处于非协程上下文，禁止调用 Sleep
    -- （会崩：GetCurrentScheduler() 返回 nil，schedule.isstatic 索引失败）。
    -- 改用 DoTaskInTime(0) 每帧限量发送，既让出时间片、又满足客户端 RPC 限流(20/tick)，避免溢出断连。
    local CHUNK = 5  -- 每帧 5 枚 → 15 RPC/帧，留余量
    local idx = 1
    local function send_chunk()
        local last = math.min(idx + CHUNK - 1, #plans)
        send_range(idx, last)
        idx = last + 1
        if idx <= #plans then
            ThePlayer:DoTaskInTime(0, send_chunk)
        else
            finalize()
        end
    end
    send_chunk()
end

-- =============================================
-- 把零散攻击勋章直换入佩戴中的融合箱
-- 统一优先级：通过 _ComputeContextElevation(true) 获得上下文 elevated 集
-- 返回 true=已在内/已换入；false=无法换入
local function SwapMedalIntoEquippedBox(prefabs)
    local equipped = GetEquippedMedal()
    if not (equipped and IsFusionBox(equipped)) then return false end
    local container = equipped.replica and equipped.replica.container
    if not container then return false end

    local actual = ReadFusionContents(equipped)
    if actual then
        for _, pf in ipairs(prefabs) do
            if actual[pf] then return true end  -- 已在内：就绪
        end
        for _, pf in ipairs(prefabs) do
            if HasSameGroupInContents(actual, pf) then
                return false  -- 箱内已有同组勋章：换入会被服端 itemtestfn 拒绝
            end
        end
    end

    -- 鼠标占用时不发起新直换（换入中/其它操作进行中），避免清理鼠标干扰在途链路
    if InventoryUtil:GetActiveItem() ~= nil then return false end

    local target = FindMedal(prefabs, true)
    if not target then return false end

    local dst_slot = FindEmptySlotInContainer(container)
    local victim = nil
    if not dst_slot then
        -- 统一优先级：攻击勋章 + 植物丰收组合 elevated(100)，非战斗勋章(0-3)优先换出
        local elevated = _ComputeContextElevation(true)
        victim, dst_slot = PickRemovableContent(equipped, {}, elevated)
        if not victim or not dst_slot then return false end
    end


    SwapMedalIntoTargetBox(equipped, target, dst_slot, victim, nil)
    return true
end

-- 目标勋章是否已生效：直接佩戴（含印刻还原），或已装在佩戴中的融合箱内（内容级生效）
-- prefabs: 候选 prefab 列表（同组不同档位）
-- equipped: 可选，外部已取到的勋章槽物品，避免重复取槽（该槽有 9 处调用点）
-- 融合箱内容未知（RPC 待响应）时保守返回 false
-- 被 AutoEquipItem 调用，故定义于其前（local function 顺序）
local function IsMedalActive(prefabs, equipped)
    equipped = equipped or GetEquippedMedal()
    if not equipped then return false end
    if IsFusionBox(equipped) then
        local contents = ReadFusionContents(equipped)
        if not contents then return false end  -- 内容未知（RPC 待响应）：保守视为未就绪
        for _, pf in ipairs(prefabs) do
            if pf and contents[pf] then return true end
        end
        return false
    end
    return MatchesAny(equipped, prefabs)
end

local function AutoEquipItem(prefabs, slot, no_fusion)
    if type(prefabs) == "string" then prefabs = {prefabs} end
    if #prefabs == 0 then return nil end

    -- 切勋章时补取一次（只取数据）：读取路径常被 no_fusion 等分支跳过，箱子会一直等不到请求
    if slot == EQUIPSLOTS.MEDAL then
        PrimeFusionInfo()
    end
    -- 海上守卫：仅"真在水中无船且无踏水保护"时阻断切换。
    -- 在船上（海洋地皮、有平台）或踏水行走（足下为海、踏水勋章生效）时放行——否则：
    --   1) 船上采海带(bullkelp_plant)被误判为海洋而完全无法切手杖/勋章；
    --   2) 踏水行走时融合箱含踏水本可正常切换其它勋章（丰收等），被一刀切阻断，
    --      与"融合含踏水不整箱锁定、箱内其它勋章按优先级正常切换"预设不符。
    -- 踏水保护 = 单踏水佩戴 或 佩戴融合箱含踏水（踏水生效则不会落水，可安全切换其它槽位/勋章）。
    if PlayerUtil:IsOnOcean(true) then
        local med = GetEquippedMedal()
        local tw_safe = med and (med.prefab == M.treadwater or IsPrefabInFusion(med, M.treadwater))
        if not tw_safe then return nil end
    end

    local item
    local equipped = InventoryUtil:GetEquippedItemBySlot(slot)

    if slot == EQUIPSLOTS.MEDAL then
        item = FindMedal(prefabs, no_fusion)
        -- FindMedal 已含打开容器（含勋章盒）：盒内勋章可直接佩戴，无需取回背包
        if not item then
            return nil
        end
        if IsSameAsEquippedMedal(item) then return true end
        -- 刻印变体不可升级：候选为刻印变体时不替换当前装备——
        -- 同变体已装备（避免两刻印变体互相振荡），或正品已装备且命中列表（正品优于刻印变体）
        if equipped and item.prefab == M.copy_blank then
            local eq_eff = GetEffectivePrefab(equipped)
            if eq_eff == GetEffectivePrefab(item) then return true end
            if equipped.prefab ~= M.copy_blank and MatchesAny(equipped, prefabs) then
                return true
            end
        end
        if equipped then
            -- 海上守护：踏水勋章优先级最高。单踏水不可被任何勋章换下（落水）；
            --   融合含踏水不做整箱锁定——融合箱留槽位、箱内其他勋章仍按优先级正常切换（走下方 insert 路径），
            --   仅由 IsRemovableContent 保证箱内踏水不作换出 victim，整体替换由下方 Equip 前守卫拦截。
            if PlayerUtil:IsOnOcean(false) then
                local wants_treadwater = false
                for _, p in ipairs(prefabs) do
                    if p == M.treadwater then wants_treadwater = true; break end
                end
                if not wants_treadwater and equipped.prefab == M.treadwater then
                    return true
                end
            end
            local eq_eff = GetEffectivePrefab(equipped)
            local cand_eff = GetEffectivePrefab(item)
            if IsBetterMedal(eq_eff, cand_eff) then return true end
        end
    else
        if equipped then
            for _, pf in ipairs(prefabs) do
                if equipped.prefab == pf then return true end
            end
        end
        local items = InventoryUtil:GetPlayerInventory(true, false, true)
        if not items then return nil end
        for _, inv_item in pairs(items) do
            for _, pf in ipairs(prefabs) do
                if inv_item.prefab == pf then
                    item = inv_item
                    break
                end
            end
            if item then break end
        end
        if not item then
            return nil
        end
    end

    -- 手部上下文保存：食人花手杖装备前保存当前手持物
    if slot == EQUIPSLOTS.HANDS and item.prefab == "lureplant_rod" then
        InventoryUtil:SaveEquipContext(EQUIPSLOTS.HANDS)
    end

    -- 融合→单勋章：优先智能换入（空槽 WEARMEDAL；箱满按优先级替换无关勋章）
    -- 避免顶掉当前有用的勋章（如钓鱼时温控勋章顶掉钓鱼勋章）
    -- 目标已在箱内 → 已生效，无需重复佩戴
    if slot == EQUIPSLOTS.MEDAL and equipped and IsFusionBox(equipped) and not IsFusionBox(item) then
        local eff = GetEffectivePrefab(item)
        -- FindItemInFusion 取箱内实体，IsPrefabInFusion 用缓存补布尔结论
        local already_inside = IsMedalActive({ item.prefab, eff }, equipped)
            or FindItemInFusion(equipped, item.prefab) ~= nil
            or IsPrefabInFusion(equipped, item.prefab)
        if not already_inside then
            local container = equipped.replica and equipped.replica.container
            local empty_slot = container and FindEmptySlotInContainer(container)
            if empty_slot then
                -- 有空槽：直接 WEARMEDAL 放入

                InventoryUtil:SendEquipAction(ACTIONS.WEARMEDAL, item, "workshop-1909182187")
            else
                -- 箱满：统一优先级策略
                -- 基础优先级：非战斗 0-3 → 战斗 11-19（档位低者先换出）
                -- 动态提升：上下文相关勋章 elevated(100)，仅无其他选择时换出
                -- 同优先级按容器 slot 倒序替换（高 slot 先被换出）
                -- 常驻勋章（速度/噬魂）由 IsRemovableContent 保护，永不会换出
                local elevated = _ComputeContextElevation(false)
                local victim, victim_slot = PickRemovableContent(equipped, {}, elevated)
                if victim and victim_slot then
                    SwapMedalIntoTargetBox(equipped, item, victim_slot, victim, nil)
                else
                    -- 无可换出内容：退回 WEARMEDAL（勋章模组自行处理顶替）
                    InventoryUtil:SendEquipAction(ACTIONS.WEARMEDAL, item, "workshop-1909182187")
                end
            end
        end
        return true
    end

    -- 海上守护：融合箱含踏水时，不可被整体替换为不含踏水的勋章/融合箱（否则踏水下槽→落水）
    --   箱内其他勋章的切换走上方 insert 路径，不受影响
    if slot == EQUIPSLOTS.MEDAL and PlayerUtil:IsOnOcean(false)
       and IsPrefabInFusion(equipped, M.treadwater) then
        local item_keeps_tw = item.prefab == M.treadwater
            or IsPrefabInFusion(item, M.treadwater)
        if not item_keeps_tw then
            return true
        end
    end

    ConfigUtil:AutoEquip("MEDAL", item)
    return true
end

-- 勋章装备（薄封装 AutoEquipItem 到勋章槽）
local function AutoEquipMedal(prefabs, no_fusion)
    return AutoEquipItem(prefabs, EQUIPSLOTS.MEDAL, no_fusion)
end

-- 食人花手杖（手部装备，独立于勋章槽位；多处动作共用）
local LUREPLANT_ROD = { "lureplant_rod" }
local function AutoEquipLureplantRod()
    return AutoEquipItem(LUREPLANT_ROD, EQUIPSLOTS.HANDS)
end

-- 通用本源组合换入：把 prefabs 全部塞进**已佩戴的融合箱**（不再为每种组合单开方法）。
-- 为什么叫"本源组合"：这类增益靠 HasOriginMedal(tag) 判定（medal_hook.lua:871，先要求
--   has_origin_medal 即戴着本源，再判箱内勋章标签），例如月树/巨石枝采摘。
--   注意箱内勋章的 onequipfn 在装备箱时就会逐个执行（multivariate_certificate.lua:88），
--   所以普通融合箱内的丰收同样能喂出 quickpickmedal（法杖吞噬），只是没有 has_origin_medal。
-- 只负责"有箱"这一半：未佩戴融合箱时返回 false 且不做任何操作——无箱时联动不成立
--   （勋章槽只有一个，组合不可能同时生效），戴哪一枚由调用方按当前动作的需求决定。
-- 函数体移至文件末尾 StepAttackTiers 之后（避免前向引用局部函数）



-- 本源联动前置判定：prefabs 是否可在本源(origin 融合箱)内满足，用于采摘等"本源内含某勋章"类动作的前置显示。
-- 满足：① 本源已佩戴且(目标散装可融合入 或 已在箱内)；② 库存某 origin 融合箱含有目标(可切换佩戴该箱)。
-- 若目标仅存在于非本源融合箱内，无法跨融合装备 → 返回 false（视为不满足前置，不显示动作）。
local function IsOriginSatisfied(prefabs)
    if type(prefabs) == "string" then prefabs = {prefabs} end
    if #prefabs == 0 then return false end
    local equipped = GetEquippedMedal()
    if equipped and equipped.prefab == M.origin and IsFusionBox(equipped) then
        -- 本源已佩戴：散装目标可融合入；或目标已在箱内
        if FindMedal(prefabs, true) then return true end
        if ReadFusionContents(equipped, prefabs) then return true end
        return false
    end
    -- 本源未佩戴：仅当某 origin 融合箱含有目标（可切换佩戴该箱）才算满足
    local items = InventoryUtil:GetPlayerInventory(true, false, true)
    for _, it in pairs(items) do
        if it.prefab == M.origin and IsFusionBox(it) then
            if ReadFusionContents(it, prefabs) then return true end
        end
    end
    return false
end

-- =============================================
-- 自动勋章 ↔ 快速动作联动：向快速动作模块导出复用接口
-- （动作→勋章组映射、装备/查找勋章），避免两个模块重复维护勋章数据
-- =============================================
-- 导出自动勋章 ↔ 快速动作复用接口（动作→勋章组映射、装备/查找勋章），避免两个模块重复维护勋章数据
local _mec = rawget(_G, "MOD_EQUIPMENT_CONTROL")

-- 动作 → 所需勋章组的全部 prefab（与 BuildActionGroupMap 同源：MEDAL.actions 字段）
-- 普通"动作触发切单勋章"就查这张表：动作要哪枚勋章、戴不戴由 AutoEquipMedal 裁决
local function GetMedalPrefabsForAction(action_id)
    BuildActionGroupMap()
    local groups = ACTION_GROUPTAG_MAP[action_id]
    if not groups then return nil end
    local prefabs = {}
    for _, grouptag in ipairs(groups) do
        local g = GetGroup(grouptag)
        if g then
            for _, pf in ipairs(g) do
                prefabs[#prefabs + 1] = pf
            end
        end
    end
    return #prefabs > 0 and prefabs or nil
end

if _mec then
    _mec.automedal_api = {
        AutoEquipMedal = AutoEquipMedal,
        FindMedal = FindMedal,
        GetGroup = GetGroup,
        -- 按"能力标签"派生勋章（如 masterchef/seasoningchef/expertchef）；
        --   与 GetGroup（整组，含不带该标签的基础档）不同，要求动作真能做成就必须用它。
        GetMedalsByPlayerTag = GetMedalsByPlayerTag,
        GetMedalPrefabsForAction = GetMedalPrefabsForAction,
        IsOriginSatisfied = IsOriginSatisfied,
        GetFinalPrefab = GetFinalPrefab,
    }
end

-- 制作菜单采用两次点击：第一次只切换/准备 builder_tag 勋章，第二次才制作。
-- 返回 true 表示本次点击已被消费，制作菜单保持打开。

local function PrepareBuilderTagRecipe(owner, recipe)
    if not owner or not recipe or not recipe.builder_tag then
        return false
    end

    local tag = recipe.builder_tag
    local pending = _craft_builder_pending
    if pending and pending.owner == owner and pending.recipe_name == recipe.name then
        if owner:HasTag(tag) then
            return false
        end
    else
        _craft_builder_pending = {
            owner = owner,
            recipe_name = recipe.name,
            builder_tag = tag,
        }
    end

    local equipped = false
    local prefabs = GetMedalsByPlayerTag(tag)
    if prefabs then
        equipped = AutoEquipMedal(prefabs)
    end
    return equipped or false
end

local function InstallCraftingDetailsHook()
    if GLOBAL.MOD_EQUIPMENT_CONTROL._automedal_crafting_details_hook then
        return
    end

    AddClassPostConstruct("widgets/redux/craftingmenu_details", function(details)
        local original = details.PopulateRecipeDetailPanel
        details.PopulateRecipeDetailPanel = function(self, data, skin_name)
            local recipe = data and data.recipe
            if recipe and TheFrontEnd and TheFrontEnd.crafting_navigation_mode then
                PrepareBuilderTagRecipe(self.owner, recipe)
            end
            return original(self, data, skin_name)
        end
    end)
    GLOBAL.MOD_EQUIPMENT_CONTROL._automedal_crafting_details_hook = true
end

InstallCraftingDetailsHook()

-- 练级极简化（R6）：组内从低到高装备最低档可用勋章（满级体 isfinal 不练级）；
-- 无低档可练（已满级/无低档）则回退整组（含 isfinal 高效采集）。
-- 替代原 HasGroupMaxed + GetLevelingPrefabs 的"排除 isfinal"聪明逻辑。
local function GetLevelingPrefabs(grouptag)
    local group = GetGroup(grouptag)
    local lowest, lowest_pr = nil, 99
    for _, pf in ipairs(group) do
        local pr = medal_priority[pf] or 0
        if pr < 3 and FindMedal({pf}, nil, true) and pr < lowest_pr then
            lowest, lowest_pr = pf, pr
        end
    end
    if lowest then return {lowest} end
    return group
end

-- 组是否已满级：拥有 isfinal 且可找到（刻印变体不计入）
local function IsGroupMaxed(grouptag)
    local fp = GetFinalPrefab(grouptag)
    return fp and FindMedal({fp}, nil, true) or false
end

-- 逮捕勋章目标 prefab 查询表（静态，避免 table.contains + 内联表每次创建新表）
local ARREST_TARGET_PREFABS = { krampus = true, medal_naughty_krampus = true }

-- =============================================
-- 攻击勋章链（缺失顺位继承）
-- 女武神 > 正义 > 噬魂 > 蜂王 > 暗影魔法(手持方尖锏) > 浴火(仅本源has_origin_medal) >> 触手 >> 沉默 >> 速度组兜底
--   - 佩戴融合箱：逐档连续换入（StepAttackTiers 异步链），每档换出优先级最低的非攻击勋章，
--     战斗时把非战斗勋章逐枚换出直至无档可换，本源组合不被打散；
--     无零散候选时该档落下一档；回退直接佩戴成功则终止整链
--   - 未佩戴融合箱：该档存在即装备并终止；不存在（或候选缺失）自动落到下一档
--   - 浴火/沉默：已就绪判定（本源已佩戴+任一晶甲 / 本源含沉默）→ 攻击加成已生效，终止
--   - 多融合箱：仅第 1 档允许匹配融合箱（女武神所在融合箱即攻击勋章），
--     其余档只从零散单勋章补位（不管其他融合箱内候选）
-- =============================================

-- 攻击链档位装备入口：佩戴中融合箱优先直换入箱（保住本源组合），否则直接佩戴
-- 直换连发进行中（~0.15s 链）静默视为本档已处理；0.5s 防抖覆盖连发全程，
-- 并防 GetAttackTarget+HandleAction 双触发竞争（避免叠加多轮直换）
-- 返回 true=该档已就绪/已执行（链终止），false=无候选（落下一档）
local _attack_swap_time = nil

local function EquipAttackMedal(prefabs, no_fusion)
    if _attack_swap_time ~= nil and GetTime() - _attack_swap_time < 0.5 then
        return true
    end
    if IsMedalActive(prefabs) then
        return true
    end
    if SwapMedalIntoEquippedBox(prefabs) then
        _attack_swap_time = GetTime()
        return true
    end
    -- 关键修正：不要在“已佩戴融合勋章”时提前拦住攻击勋章的正常装备流程。
    -- 工具类勋章的通用路径已经验证能正确处理：
    --  1) 单勋章直接装备
    --  2) 已装备融合勋章内存在目标勋章时直接装备所在融合勋章
    --  3) 未在箱内时，走 AutoEquipMedal -> WEARMEDAL 直接放入或顶替
    -- 这条分支必须和工具类一致，不能在融合箱场景下强行 return false。
    local ok = AutoEquipMedal(prefabs, no_fusion)
    return ok and true or false
end

-- 攻击链连续换入（佩戴融合箱时）：逐档把攻击勋章换入箱内，每档换出优先级最低的非攻击勋章，
-- 战斗时把非战斗勋章逐枚换出直至无档可换；档位已就绪则跳过继续（把剩余非战斗勋章也换出去）
-- tiers 项：{ prefabs=..., no_fusion=..., skip=跳过判定（真则落下一档）, stop=被动就绪判定（真则终止整链） }
local _attack_chain_running = false

-- 攻击链批量换入（佩戴融合箱时）：预算所有档的连线（模拟 stop/skip/ready），一次性连发+统一终检
-- 战斗时把非战斗勋章逐枚换出直至无档可换；档位已就绪则跳过继续（把剩余非战斗勋章也换出去）
-- 通用批量换入链：预算所有档连线（模拟 stop/skip/ready），一次性连发+统一终检
-- target_set：不可换出的保护勋章集合（攻击链 {}，本源组合 combo_set）
-- is_attack：true=攻击上下文（_ComputeContextElevation(true)），false=非攻击（本源组合）
local function StepAttackTiers(tiers, target_set, is_attack)
    local equipped = GetEquippedMedal()
    if not (equipped and IsFusionBox(equipped)) then
        _attack_chain_running = false
        return
    end
    local container = equipped.replica and equipped.replica.container
    if not container then
        _attack_chain_running = false
        return
    end
    local actual = ReadFusionContents(equipped)
    local occupied = {}
    if actual then for slot in pairs(actual) do occupied[slot] = true end end

    -- 预算连线：逐档模拟 stop/skip/ready，分配 src/dst/victim（标记 occupied 防同槽冲突）
    local plans = {}
    local elevated = _ComputeContextElevation(is_attack ~= false)
    for _, t in ipairs(tiers) do
        if t.stop then
            if t.stop() then break end
        elseif t.skip and t.skip() then
            -- 跳过本档
        elseif IsMedalActive(t.prefabs) then
            -- 已就绪：继续下一档（把剩余非战斗勋章也换出去）
        elseif actual and HasSameGroupInContents(actual, t.prefabs[1]) then
            -- 同组冲突：落下一档（不换入）
        else
            local target = FindMedal(t.prefabs, t.no_fusion)
            if target then
                local dst_slot = FindEmptySlotInContainer(container, occupied)
                local victim = nil
                if not dst_slot then
                    victim, dst_slot = PickRemovableContent(equipped, target_set or {}, elevated, occupied)
                end
                if dst_slot then
                    local src_replica, src_slot, src_kind = InventoryUtil:FindItemContainer(target)
                    if src_replica and src_slot then
                        local src_entity = src_kind == "container" and src_replica.inst or nil
                        plans[#plans + 1] = { src_entity = src_entity, src_slot = src_slot, dst_slot = dst_slot, swapMode = victim and "swap" or "put", item = target }
                        occupied[dst_slot] = true
                    end
                end
            end
        end
    end

    _attack_chain_running = false
    if #plans == 0 then return end
    _attack_swap_time = GetTime()
    BatchSwapMedalsIntoTargetBox(equipped, plans, function() end)
end

local function StartAttackTierChain(tiers)
    if _attack_chain_running then return end
    if _attack_swap_time ~= nil and GetTime() - _attack_swap_time < 0.1 then return end
    _attack_chain_running = true
    StepAttackTiers(tiers)
end

-- 联动换入：把指定勋章列表换入当前佩戴的融合箱内。
-- origin_only=true 时仅本源融合箱生效（has_origin_medal 守卫），无本源直接返回。
-- protect_prefabs：可选，硬保护集（如本次配方的前置勋章），不得被换出。
-- has_origin_medal 只有 origin_certificate 的 onequipfn 会加（multivariate_certificate.lua:82），
-- 普通融合箱加了也没有；它也是源模组 HasOriginMedal 的前提（medal_hook.lua:871）
local function EquipCombo(prefabs, with_harvest, origin_only, protect_prefabs)
    if origin_only and (ThePlayer == nil or not ThePlayer:HasTag("has_origin_medal")) then return end

    -- 过滤 nil（GetFinalPrefab 可能拿不到终档）
    local list = {}
    for _, pf in ipairs(prefabs or {}) do
        if pf ~= nil then list[#list + 1] = pf end
    end
    if with_harvest then list[#list + 1] = M.harvest end
    if #list == 0 then return end

    local tiers = {}
    for _, pf in ipairs(list) do
        tiers[#tiers + 1] = { prefabs = { pf }, no_fusion = true }
    end
    StepAttackTiers(tiers, protect_prefabs)
end

-- 巧手制作勋章：训练优先（考验 → 完全体），无考验时切换完全体
-- 佩戴融合箱时不再"保持现状"：把巧手换入箱内（箱内已有则跳过），
--   使制作/建造同时吃到前置勋章标签与巧手加成/练级。
-- protect_prefabs：本次配方的前置勋章（builder_tag 对应），巧手换入时作为保护集，
--   绝不能被 PickRemovableContent 当成牺牲品换出（否则前置标签丢失、制作失败）。
local function AutoEquipHandyCraftMedal(recipe, protect_prefabs)
    local handy_test = M.handy_test
    local equipped = GetEquippedMedal()

    -- 前置勋章列表中含完全体巧手 → 该配方必须由完全体提供标签（考验勋章没有 has_handy_medal）
    local need_final = false
    for _, pf in ipairs(protect_prefabs or {}) do
        if pf == M.handy then
            need_final = true
            break
        end
    end

    if equipped and GetEffectivePrefab(equipped) == handy_test then
        return true  -- 考验勋章已装备，保持练级
    end

    -- 融合箱已装备：换入箱内而非整箱替换（已在内则不重复）
    if equipped and IsFusionBox(equipped) then
        local contents = ReadFusionContents(equipped)
        if contents then
            if need_final then
                if contents[M.handy] then return true end
            elseif contents[handy_test] or contents[M.handy] then
                return true
            end
        end
        -- 前置需要完全体标签时只能用完全体；否则练级优先考验勋章
        local prefab = M.handy
        if not need_final and FindMedal({ handy_test }) then
            prefab = handy_test
        end
        EquipCombo({ prefab }, nil, nil, protect_prefabs)
        return true
    end

    if FindMedal({handy_test}) then
        return AutoEquipMedal({handy_test})
    else
        return AutoEquipMedal({M.handy})
    end
end

if _mec then
    _mec.automedal_api.EquipCombo = EquipCombo
end

-- 攻击链档位单一权威表：融合路径(StartAttackTierChain)与非融合(单勋章)路径共用
-- 顺序即优先级：女武神 > 正义 > 噬魂 > 蜂王 > 暗影魔法(持方尖锏) > 浴火(本源+晶甲) > 触手 > 沉默 > 速度兜底
--   skip：满足则落下一档；stop：满足则终止整链（被动就绪）
--   fusion_only：仅佩戴融合箱时参与（非融合单勋章路径跳过，保留原行为：浴火/沉默不主动装备）
local ATTACK_TIERS = {
    { prefabs = GetGroup("valkyrieMedal") },
    { prefabs = GetGroup("justiceMedal"), no_fusion = true },
    { prefabs = GetGroup("devoursoulMedal"), no_fusion = true },
    { prefabs = { M.bee_king }, no_fusion = true },
    -- 暗影魔法勋章（手持方尖锏时佩戴，含皮肤）
    { prefabs = { M.shadowmagic }, no_fusion = true,
      skip = function()
          return InventoryUtil:FindEquipped(function(i)
              return i and i:HasTag("shadowlevel") and i:HasTag("weapon")
          end) == nil
      end },
    -- 浴火：仅装备本源(has_origin_medal) + 穿晶甲时纳入战斗序列（仅融合箱路径）
    { prefabs = { M.bathingfire }, no_fusion = true, fusion_only = true,
      skip = function()
          if not ThePlayer:HasTag("has_origin_medal") then return true end
          local body = InventoryUtil:FindEquipped(function(i) return i and MEDAL.BATHINGFIRE_ARMORS[i.prefab] end)
          return not body
      end },
    -- 触手勋章（仅按优先级，无目标过滤）
    { prefabs = { M.tentacle }, no_fusion = true },
    -- 沉默：需本源前置，主动换入以累积伤害（不满足跳过，避免非本源无效换入）（仅融合箱路径）
    { prefabs = { M.silence }, no_fusion = true, fusion_only = true,
      skip = function() return not ThePlayer:HasOriginMedal("mime") end },
    -- 浴火已就绪判定：仅本源含浴火 + 穿晶甲 → 终止（仅融合箱路径）
    { fusion_only = true,
      stop = function()
          if ThePlayer:HasTag("has_origin_medal") and ThePlayer:HasOriginMedal("has_bathfire_medal") then
              local body = InventoryUtil:FindEquipped(function(i) return i and MEDAL.BATHINGFIRE_ARMORS[i.prefab] end)
              return body ~= nil
          end
          return false
      end },
    -- 沉默：本源含沉默 → 伤害累积已生效，终止（不切任何勋章）
    { prefabs = { M.silence }, no_fusion = true,
      stop = function() return ThePlayer:HasOriginMedal("mime") or false end },
    -- 速度组兜底
    { prefabs = GetGroup("speedMedal"), no_fusion = true },
}

local function HandleAttackChain(target, medal_slot)
    local equipped = InventoryUtil:GetEquippedItem(medal_slot)
    if equipped and IsFusionBox(equipped) then
        StartAttackTierChain(ATTACK_TIERS)
        return
    end
    -- 非融合（单勋章）路径：逐档装备，跳融合专属档(fusion_only)以保留原行为
    for _, t in ipairs(ATTACK_TIERS) do
        if not t.fusion_only then
            if t.stop and t.stop() then return end
            if not (t.skip and t.skip()) then
                if EquipAttackMedal(t.prefabs, t.no_fusion) then return end
            end
        end
    end
end

-- 根据攻击目标自动切换勋章（共享逻辑：HandleAction + GetAttackTarget 共用）
local function HandleAttackTarget(target, medal_slot)
    if not target or not target:IsValid() then return end
    if ARREST_TARGET_PREFABS[target.prefab] then
        -- 单勋章情况下打两种坎普斯只装备逮捕/正义（获取掉落物）：
        -- 佩戴融合勋章时不整体切换（箱内逮捕/正义击杀时经勋章模组自动生效），
        -- 查找也排除融合勋章（不因坎普斯把整个融合箱拖出来装备）
        local equipped = InventoryUtil:GetEquippedItem(medal_slot)
        if equipped and IsFusionBox(equipped) then
            -- 佩戴融合箱：不整体切换（箱内正义击杀时经勋章模组自动生效），
            -- 箱内缺正义时把零散正义换入箱内
            EquipAttackMedal(GetGroup("justiceMedal"), true)
        else
            AutoEquipMedal(GetGroup("justiceMedal"), true)
        end
    else
        HandleAttackChain(target, medal_slot)
    end
end

-- =============================================
-- 从MEDAL_DEFS动态构建勋章分组
-- =============================================

local function BuildMedalGroups()
    if next(medal_groups) ~= nil then return end  -- 已构建则跳过
    local ok, medal_defs_module = pcall(require, "medal_defs/functional_medal_defs")
    if not ok or not medal_defs_module then
        return
    end
    MEDAL_DEFS = medal_defs_module.MEDAL_DEFS
    if not MEDAL_DEFS then
        return
    end
    for name, def in pairs(MEDAL_DEFS) do
        local grouptag = def.grouptag or name
        if not medal_groups[grouptag] then
            medal_groups[grouptag] = {}
        end
        table.insert(medal_groups[grouptag], name)
        prefab_to_grouptag[name] = grouptag
        -- 优先级：isfinal(3) > 无耐久(2) > 有耐久(1)
        if def.isfinal then
            medal_priority[name] = 3
        elseif not def.maxuses then
            medal_priority[name] = 2
        else
            medal_priority[name] = 1
        end
    end

    -- =============================================
    -- 动态构建 PRIORITY_RULES（按 MEDAL_DEFS 组展开为 prefab→prefab 映射）
    -- =============================================

    -- 将组规则展开为 prefab→prefab 映射
    -- @skip_final: true=排除 isfinal 勋章（满级后允许切换到目标勋章）
    local function _buildGroupRule(src_tag, target_prefab, skip_final)
        local g = medal_groups[src_tag]
        if not g then return end
        for _, p in ipairs(g) do
            if not skip_final or medal_priority[p] ~= 3 then
                PRIORITY_RULES[p] = { [target_prefab] = true }
            end
        end
    end

    -- chefMedal: cook/chef > harvest（headchef[isfinal]不覆盖，允许满级切丰收）
    _buildGroupRule("chefMedal", M.harvest, true)
    -- plantMedal: plant/transplant > harvest（植物组全勋章覆盖丰收，含 isfinal transplant）
    _buildGroupRule("plantMedal", M.harvest, false)

end

-- 可采集目标判定（排除动物/昆虫避免捕虫网冲突）
local function IsHarvestableTarget(target)
    return target
        and not (target:HasTag("animal") or target:HasTag("insect"))
        and (target:HasTag("pickable") or target:HasTag("crop")
            or target:HasTags({"structure", "_container", "stewer"})
            or target.prefab == "waterplant" or target.prefab == "lureplant")
end

-- =============================================
-- 本源联动（采摘 / 吞噬）
-- 有融合箱 → EquipCombo 把组合换入箱内（本源下植物开月树/巨石枝、丰收开吞噬）；
-- 无箱 → 联动不成立，由调用方按当前动作单戴（法杖只戴丰收，植物在无本源时对它零贡献）。
-- 触发点：MEDALSTAFFDEVOUR / CASTSPELL 规则、quickactions 的物品栏前置与组合装备。
-- =============================================




-- 采集类动作共用：组内有可用勋章才切，返回是否命中（供调用方写回退链）
local function TryEquipGroup(grouptag)
    local prefabs = GetGroup(grouptag)
    if FindMedal(prefabs) then
        AutoEquipMedal(prefabs)
        return true
    end
    return false
end

-- [采]丰收 - PICK动作
local function HandlePickAction(buffaction)
    local target = buffaction and buffaction.target
    if not target then
        return
    end

    -- 排除规则（参考 3638564451）：腐烂的农作物不触发勋章切换
    if target:HasTag("farm_plant_killjoy") then
        return
    end

    -- 食人花手杖：手部装备，独立于勋章槽位，不影响下方勋章切换
    if IsHarvestableTarget(target) or target:HasTag("thorny") or target:HasTag("farm_plant") then
        AutoEquipLureplantRod()
    end

    -- 带刺植物（仙人掌、玫瑰等）：免伤来自植物勋章的 bramble_resistant，
    -- 组内另一枚虫木勋章没有该标签，故指定组内的 final 而非整组
    if target:HasTag("thorny") then
        local transplant = GetFinalPrefab("plantMedal")
        if transplant and FindMedal({transplant}) then
            AutoEquipMedal(transplant)
        end
        return
    end

    -- 巨型作物：植物勋章满级则优先丰收勋章，否则仅切虫木勋章练级
    if target:HasTag("farm_plant")
        and target.AnimState
        and target.AnimState:IsCurrentAnimation("crop_oversized") then
        if not IsGroupMaxed("plantMedal") then
            if not TryEquipGroup("plantMedal") and FindMedal({M.harvest}) then
                AutoEquipMedal(M.harvest)
            end
        end
        return
    end

    -- 普通采摘 → 丰收勋章
    if FindMedal({M.harvest}) then
        AutoEquipMedal(M.harvest)
    end
end

-- [采]丰收 / [沃利]烹饪 - HARVEST动作
local function HandleHarvestAction(buffaction)
    local target = buffaction and buffaction.target
    if not target then return end

    -- 食人花手杖：手部装备，独立于勋章槽位
    AutoEquipLureplantRod()

    -- [沃利]烹饪建筑收获 → 厨师勋章练级，满级则切丰收快速收获
    -- 跨系列优先级守卫（IsBetterMedal）自动处理：
    if target:HasTags({"structure", "_container", "stewer"}) then
        if IsGroupMaxed("chefMedal") then
            AutoEquipMedal(M.harvest)
        else
            AutoEquipMedal(GetGroup("chefMedal"))
        end
        return
    end

    -- [沃姆伍德]水上植物 → 植物勋章（官方自带 waterplant 标签，见 prefabs/waterplant.lua:384）
    if target:HasTag("waterplant") then
        AutoEquipMedal(GetGroup("plantMedal"))
        return
    end

    -- [采]丰收 - 通用 HARVEST 兜底：可采集/作物目标 → 植物勋章练级
    if (target:HasTag("pickable") or target:HasTag("crop"))
        and not IsGroupMaxed("plantMedal") then
        TryEquipGroup("plantMedal")
    end
end

-- =============================================
-- 主初始化
-- =============================================

local IsMasterSim = false

-- 同一次制作会被两条钩子各调一次（客机）：
--   ① builder_replica:MakeRecipeFromMenu/AtPoint —— 点击时同步
--   ② SendRPCToServer 里的 MakeRecipe* —— 随后 RemoteMakeRecipe* 真正发 RPC 时
-- 两条都保留（② 兜住模组直接发 RPC 的路径），但同一次制作只处理一次：
-- 两批 swap 都基于"尚未回传"的同一份箱内容快照各自预算受害者，
-- 第二批会把第一批刚换入的巧手当成牺牲品顶出去，制作时箱内反而没有巧手。
local CRAFT_HANDLE_DEDUPE = 0.5
local _craft_handled_name = nil
local _craft_handled_time = 0

local function _HandleCraftRecipe(recipe)
    local recipe_name = recipe and recipe.name
    local now = GetTime()
    if recipe_name ~= nil
        and recipe_name == _craft_handled_name
        and now - _craft_handled_time < CRAFT_HANDLE_DEDUPE then
        return
    end
    _craft_handled_name, _craft_handled_time = recipe_name, now

    -- 配方页点击时 PrepareBuilderTagRecipe 已按 builder_tag 切好前置勋章。
    -- 制作时不再按玩家标签重判一次：勋章换入融合箱后标签要等服端回传才生效，
    -- 这个窗口里重判会认为"前置未满足"而再切一遍（第二次切换的来源）。
    -- 只要点过配方页，就以前置勋章为保护集，直接补巧手。
    local prepared = _craft_builder_pending ~= nil
        and _craft_builder_pending.recipe_name == recipe_name
    _craft_builder_pending = nil

    -- 制作紧接着就会发制作 RPC：swap 必须当场同步发出，才能在服端排在制作之前
    -- （分帧发送会晚一帧，服端先落制作、巧手还没进箱）。
    _swap_flush_now = true

    local builder_tag = recipe and recipe.builder_tag
    local prefabs = builder_tag and GetMedalsByPlayerTag(builder_tag) or nil
    local equipped = GetEquippedMedal()

    if builder_tag and prefabs then
        -- 未经配方页（模组直接发 RPC 等）时仍按标签兜底补装；
        -- 单勋章直接换 / 融合箱内插章。
        if not prepared
            and not (equipped ~= nil and PlayerUtil:HasBuilderTagFromMedal(builder_tag, equipped)) then
            AutoEquipMedal(prefabs)
            equipped = GetEquippedMedal()
        end
        -- 融合箱：前置勋章与巧手共存。巧手换入时以前置勋章为保护集，
        -- 避免"补巧手把刚换入的前置勋章顶出箱子"→ 标签丢失、制作失败。
        -- 单勋章：槽位只有一个，前置优先，不再切巧手。
        if equipped and IsFusionBox(equipped) then
            AutoEquipHandyCraftMedal(recipe, prefabs)
        end
    else
        AutoEquipHandyCraftMedal(recipe)
    end

    _swap_flush_now = false
end

local function _ApplyBuilderRecipeHooks(br)
    local old_menu = br.MakeRecipeFromMenu
    local old_point = br.MakeRecipeAtPoint
    br.MakeRecipeFromMenu = function(self, recipe, skin)
        _HandleCraftRecipe(recipe)
        return old_menu(self, recipe, skin)
    end
    br.MakeRecipeAtPoint = function(self, recipe, pt, rot, skin)
        _HandleCraftRecipe(recipe)
        return old_point(self, recipe, pt, rot, skin)
    end
end

-- 便携厨具（烹饪锅/香料站/研磨器）规则生成：RUMMAGE/STORE/OPEN_CRAFTING 同构
-- 便携厨具打开/存入要求 doer:HasTag("masterchef")(CanOpenCharacterSpecificContainer)，
-- 故按该标签派生勋章集合（仅大厨/主厨），不能用整组 GetGroup("chefMedal")
-- （整组含不带 masterchef 的 test 档 cook_certificate，戴上照样打不开）。
-- 常规烹饪锅(cookpot)只带 stewer 不含 mastercookware，打开不要求 masterchef，
-- 可用整组 GetGroup("chefMedal")（含 test 档）。
-- 已部署物带 mastercookware/stewer；物品形态靠 restrictedtag="masterchef"（仅 OPEN_CRAFTING）
local function MasterChefCookwareRule(use_invobject, check_deploy_tag)
    return function(b)
        local t = b.target or (use_invobject and b.invobject)
        if t == nil then return end
        if t:HasTag("mastercookware") then
            AutoEquipMedal(GetMedalsByPlayerTag("masterchef"))
        elseif t:HasTag("stewer") then
            AutoEquipMedal(GetGroup("chefMedal"))
        elseif check_deploy_tag and ItemUtil:IsDeployRestrictedTo(t, "masterchef") then
            AutoEquipMedal(GetMedalsByPlayerTag("masterchef"))
        end
    end
end

-- 吞噬系法杖规则生成：MEDALSTAFFDEVOUR(喂食补充) 与 CASTSPELL(范围施法) 同一套逻辑。
-- 三条路各行其道：
--   · 戴着本源箱 → 走本源联动，植物+丰收一起换入箱内（植物开月树/巨石枝，丰收开吞噬）；
--   · 目标是带刺植物(thorny)或水上植物(waterplant)且佩戴了融合箱 → 植物+丰收联动（无需本源）；
--   · 否则 → 没有联动效果，走普通"动作→勋章"单勋章逻辑（只切丰收）。
local function DevourStaffRule()
    return function(b)
        local staff = b and (b.invobject or InventoryUtil:GetActiveItem())
        if staff == nil or staff.HasTag == nil or not staff:HasTag("medal_eatfood") then return end
        local equipped = GetEquippedMedal()
        local target = b and b.target
        if equipped ~= nil and equipped.prefab == M.origin then
            EquipCombo({ GetFinalPrefab("plantMedal"), M.harvest }, nil, true)
        elseif target ~= nil and (target:HasTag("thorny") or target:HasTag("waterplant")) and IsFusionBox(equipped) then
            EquipCombo({ GetFinalPrefab("plantMedal"), M.harvest })
        else
            local prefabs = GetMedalPrefabsForAction("MEDALSTAFFDEVOUR")
            if prefabs then AutoEquipMedal(prefabs) end
        end
    end
end

-- 统一动作→勋章规则表：键为 action_id，每项为一组 rule(buffaction, slot) 依次执行。
-- 只按"动作"分派（不按目标）：打开走主厨、清理走矿工，天然不冲突。
local MEDAL_ACTION_RULES = {
    -- 强制冷却：降温要求 expertchef，只能戴真正赋予该标签的勋章。
    -- 上面的 grouptag 默认分支走 GetLevelingPrefabs("chefMedal")（挑"玩家拥有的最低档"），
    -- 而 test 档 cook_certificate 没有 expertchef（无降温能力），戴上会被服务端拒绝 → 这里覆盖。
    MAKECOOLDOWN = {
        function(b)
            AutoEquipMedal(GetMedalsByPlayerTag("expertchef"))
        end,
    },
    CHEFFLAVOUR = {
        function(b)
            local final_chef = GetFinalPrefab("chefMedal")
            if final_chef then AutoEquipMedal({final_chef}) end
        end,
    },
    -- 研磨：要求 seasoningchef，只能戴真正赋予该标签的勋章（final 主厨）。
    -- 上面的 grouptag 默认分支走 GetLevelingPrefabs("chefMedal")（挑"玩家拥有的最低档"），
    --   会戴成烹饪档（cook/chef，无研磨能力），还会把快速动作刚戴好的主厨顶掉 → 这里覆盖。
    --   手持物对物品栏/已部署研磨器都会走到本动作，两条路径共用这一规则。
    MEDAL_GRINDING = {
        function(b)
            -- 必须判空：AutoEquipMedal(nil) 会在 AutoEquipItem 的 #prefabs 处报错。
            -- 没有 seasoningchef 来源（只有烹饪档）时保持不动，不再切到无能力的勋章。
            local prefabs = GetMedalsByPlayerTag("seasoningchef")
            if prefabs then AutoEquipMedal(prefabs) end
        end,
    },
    PICK = { function(b, s) HandlePickAction(b) end },
    HARVEST = { function(b, s) HandleHarvestAction(b) end },
    TAKEITEM = {
        function(b, s)
            if b.target and b.target.prefab == "lureplant" then
                AutoEquipLureplantRod()
            end
        end,
        function(b)
            local t = b.target
            if t and (t:HasTag("inventoryitemholder_take")
                    or t:HasTag("takeshelfitem")
                    or (t.components ~= nil and t.components.shelf ~= nil)) then
                AutoEquipMedal({M.harvest})
            end
        end,
    },
    MEDALSTAFFDEVOUR = { DevourStaffRule() },
    CASTSPELL = { DevourStaffRule() },
    ATTACK = { function(b, s) HandleAttackTarget(b.target, s) end },
    PLAY = {
        function(b)
            if b.invobject and b.invobject:HasTag("bell") then
                AutoEquipMedal(M.naughty)
            end
        end,
    },
    TOUCHWISDOMTEST = {
        function(b)
            if b.invobject and b.invobject.prefab == "wisdom_test_certificate" then
                local hand = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
                if hand and hand.prefab == "xinhua_dictionary" then return end
                for _, item in pairs(InventoryUtil:GetInventoryItems()) do
                    if item.prefab == "xinhua_dictionary" then
                        ACTIONS.EQUIP.fn({ doer = ThePlayer, invobject = item })
                        break
                    end
                end
            end
        end,
    },
    DIG = {
        function(b)
            local t = b.target
            if t and t:HasTag("stump") then AutoEquipMedal(GetGroup("chopMedal")) end
        end,
    },
    DEPLOY = {
        function(b)
            -- Winona 工程物：官方给可部署物设的 deployable.restrictedtag="handyperson"
            -- 走 IsDeployRestrictedTo：deployrestrictedtag 是 net_hash，读出来是数字哈希
            if ItemUtil:IsDeployRestrictedTo(b.invobject, "handyperson") then
                local hc = GetFinalPrefab("handy_certificate")
                if hc then AutoEquipMedal({hc}) end
            end
        end,
        function(b)
            local inv = b.invobject
            if inv and inv:HasTag("deployedfarmplant") then
                AutoEquipMedal(GetGroup("plantMedal"))
            end
        end,
        function(b)
            -- 便携厨具部署要求 doer:HasTag("masterchef")，故按该标签派生勋章集合
            -- （仅大厨/主厨），不能用整组 GetGroup("chefMedal")（含不带 masterchef 的 test 档）
            if ItemUtil:IsDeployRestrictedTo(b.invobject, "masterchef") then
                AutoEquipMedal(GetMedalsByPlayerTag("masterchef"))
            end
        end,
    },
    -- 打开/存入便携厨具：RUMMAGE(开容器) 与 STORE(放入容器) 都会走 CanOpenCharacterSpecificContainer。
    -- 便携厨具同时带 mastercookware 与 stewer（portablecookpot/portablespicer/portableblender）。
    -- 二者是"打开/存入"动作，与清理(MINE/REMOVELUNARBUILDUP)无关，不会和 minerMedal 互切。
    RUMMAGE = { MasterChefCookwareRule(true, false) },
    STORE = { MasterChefCookwareRule(false, false) },
    OPEN_CRAFTING = { MasterChefCookwareRule(false, true) },
}

local function HandleAction(buffaction)
    if not ActionUtil:IsValidBufferedAction(buffaction) then
        return
    end
    -- 快速动作（medal_prefabs + modaction）已由 quickactions.lua 的 MedalSceneUse
    -- 负责勋章切换，此处跳过避免重复触发 SwapMedalIntoTargetBox
    if ActionUtil:IsQuickAction(buffaction) then
        return
    end
    local action_id = ActionUtil:GetActionId(buffaction)

    if not ActionUtil:ShouldProcessAction(action_id) then
        return
    end

    -- 1. grouptag 驱动（MEDAL.actions 构建）+ handy 直接动作
    --    **与规则表互斥**：规则表里的动作是"按能力装备"（要能干活的那一档，如研磨要
    --    seasoningchef／冷却要 expertchef），grouptag 分支是"练级"（挑玩家拥有的最低档）。
    --    二者目标相反，串行执行会先切到最低档、再由规则表改回，产生抖动与一堆补救守卫。
    --    故规则表里有声明的动作直接跳过练级分支，只走它自己的能力规则。
    local grouptags = (MEDAL_ACTION_RULES[action_id] == nil) and ACTION_GROUPTAG_MAP[action_id] or nil
    if grouptags then
        for _, grouptag in ipairs(grouptags) do
            if grouptag == "plantMedal" then
                if not buffaction.invobject and action_id ~= "GRAFTING_TREE" then
                elseif action_id == "GRAFTING_TREE" and not IsGroupMaxed("plantMedal") then
                else
                    AutoEquipMedal(GetGroup(grouptag))
                end
            elseif grouptag == "speedMedal" then
                if not GLOBAL.TheInput:IsControlPressed(GLOBAL.CONTROL_ATTACK) then
                    AutoEquipMedal(GetGroup(grouptag))
                end
            else
                AutoEquipMedal(GetLevelingPrefabs(grouptag))
            end
        end
    elseif table.contains(MEDAL.HANDY_ACTIONS, action_id) then
        AutoEquipHandyCraftMedal()
    end

    -- 2. 统一动作规则表（R1：合并原 SPECIFIC_ACTION_HANDLERS + ACTION_TARGETS + 内联特例）
    local rules = MEDAL_ACTION_RULES[action_id]
    if rules then
        for _, rule in ipairs(rules) do
            rule(buffaction, EQUIPSLOTS.MEDAL)
        end
    end
end

-- 通用函数：鼠标拿活跃物品时，搜索世界坐标附近的实体，匹配则切勋章
local function TrySwitchForNearbyTarget(lmb, matchfn, medals, worldfn)
    -- 世界级检测（地皮类型等非实体匹配）
    if worldfn then
        local world_pos = TheInput:GetWorldPosition()
        if world_pos and worldfn(world_pos) then
            AutoEquipMedal(medals)
            return true
        end
    end
    -- 实体匹配：官方 API 获取鼠标像素正下方的实体
    if matchfn then
        local mouseover = TheInput:GetWorldEntityUnderMouse()
        if mouseover and mouseover:IsValid() and matchfn(mouseover) then
            AutoEquipMedal(medals)
            return true
        end
        -- fallback: lmb.target（点击目标，兜底极端情况）
        if lmb and lmb.target and lmb.target:IsValid() and matchfn(lmb.target) then
            AutoEquipMedal(medals)
            return true
        end
    end
    return false
end

-- 降温/部署一律按能力标签(expertchef/masterchef)派生，不要用整组 GetGroup("chefMedal")：
-- 它含 test 档 cook_certificate，既不降温也部署不了便携厨具。

-- 空白/融合勋章检测：装备传承勋章后拿取空白/融合勋章右键或悬停另一空白/融合勋章时切传承
local function IsBlankOrFusion(item)
    if not item then return false end
    local p = item.prefab
    return p == M.blank
        or p == M.copy_blank
        or IsFusionBox(item)
end

-- 地面实体匹配：鼠标下的实体是空白或融合勋章
local function IsBlankOrFusionEntity(ent)
    return ent and ent:IsValid() and IsBlankOrFusion(ent)
end

-- 手持物品 → 世界目标 勋章切换配置（OnControl PRIMARY 左键点击世界目标时遍历）

-- 惰性求值：本表在模块加载期构建，而勋章权威数据（MEDAL_DEFS）要到玩家加载后
-- BuildMedalGroups() 才就绪。medals 写成函数则在真正悬停/点击（玩家已加载）时才取值：
-- 以运行时求值为准，取不到再用本文件 MEDAL 常量表兜底。
local function ResolveConfigMedals(cfg)
    local medals = cfg.medals
    if type(medals) == "function" then
        medals = medals()
    end
    if type(medals) == "string" then
        medals = { medals }
    end
    return medals or {}
end

local HOLD_ITEM_TARGET_CONFIG = {
    -- 可研磨物品 → 研磨器 → 主厨勋章（仅 isfinal 有 seasoningchef 标签）
    -- 便携厨具里只有研磨器不带 stewer（烹饪锅/香料站都有），无需点名 prefab
    -- 只管**已部署**那台（prefab portableblender，带 mastercookware）：物品栏形态
    --   portableblender_item 没有该标签，由 quickactions 的研磨快速动作接管。
    --
    -- 必须惰性求值：若在加载期直接写 {GetFinalPrefab("chefMedal")}，
    -- 那时 BuildMedalGroups 还没跑、MEDAL_DEFS 仍为 nil，GetFinalPrefab 返回 nil，
    -- `{ nil }` 等于空表 → AutoEquipItem 的 `#prefabs == 0` 直接 no-op，
    -- 表现为"悬停/点击已部署研磨器都不切主厨勋章"。
    -- 运行时以 GetFinalPrefab（模组权威数据）为准，拿不到再退回本地 MEDAL 常量表。
    {
        testfn = function(active) return TUNING_MEDAL and TUNING_MEDAL.MEDAL_GRINDING_RECIPES and TUNING_MEDAL.MEDAL_GRINDING_RECIPES[active.prefab] end,
        matchfn = function(ent) return ent:HasTag("mastercookware") and not ent:HasTag("stewer") end,
        medals = function()
            local final = GetFinalPrefab("chefMedal")
            return final ~= nil and { final } or GetMedalsByPlayerTag("seasoningchef")
        end,
    },
    -- [沃姆伍德]手持种子/农场植物 → 耕地地皮 → 植物勋章
    {
        testfn = function(active) return active:HasTag("deployedfarmplant") or (active.replica and active.replica.farmplantable) end,
        matchfn = function(ent) return false end,
        worldfn = function(pos) return TheWorld.Map:GetTileAtPoint(pos.x, 0, pos.z) == GROUND.FARMING_SOIL end,
        medals = GetGroup("plantMedal"),
    },
    -- 手持空白/融合勋章 → 地面空白/融合勋章实体 → 切换传承勋章（融合仪式）
    {
        testfn = IsBlankOrFusion,
        matchfn = IsBlankOrFusionEntity,
        medals = M.inherit,
    },
}

-- 右键物品栏拿起物品 → 预切勋章配置（OnRightClick rmb nil 时遍历）
-- 注：原"可研磨物品 → 预切主厨"已移除，改由 quickactions 的研磨快速动作在真正研磨时才切
--   （本表的触发点是世界右键、且通道 A 在悬停 HUD 时提前返回，本来也覆盖不到物品栏研磨器）。
local ACTIVE_ITEM_MEDAL_CONFIG = {
    -- 可降温物品 → 预切厨师勋章组（FindMedal自动优先isfinal主厨）
    {
        testfn = function(active) return active:HasTag("cooldownable") end,
        medals = GetMedalsByPlayerTag("expertchef"),
    },
    -- 拿取曼德拉草/种子 → 预切植物勋章
    {
        testfn = function(active) return active.prefab == "mandrake" or active.prefab == "mandrake_seeds" end,
        medals = GetGroup("plantMedal"),
    },
    -- 拿取空白/融合勋章 → 预切传承勋章（为融合操作做准备）
    {
        testfn = IsBlankOrFusion,
        medals = M.inherit,
    },
}

local hover_task = nil
local hover_is_active = false
local hover_worn_medal = nil  -- 悬停时佩戴进融合容器的勋章（移开时用TAKEOFFMEDAL摘除）

local function StopHoverTask(norevert)
    if hover_task then
        hover_task:Cancel()
        hover_task = nil
    end
    if not norevert and hover_is_active then
        -- 摘除悬停时佩戴进融合容器的勋章
        local worn = hover_worn_medal
        hover_worn_medal = nil
        if worn and ThePlayer then
            InventoryUtil:SendEquipAction(ACTIONS.TAKEOFFMEDAL, worn, "workshop-1909182187")
        end
        InventoryUtil:RestoreEquipContext(EQUIPSLOTS.MEDAL)
    end
    hover_is_active = false
end

-- 8. 风暴/瘴气：进入时装备复眼勋章，离开时回退原勋章
local _hazard_active = false
-- ItemUtil.IsGoggle 是冒号定义，直接传引用会恒返回 false，必须包闭包
local function IsGoggleEquipped()
    return InventoryUtil:FindEquipped(function(item) return ItemUtil:IsGoggle(item) end) ~= nil
end
local function EnterHazard()
    if IsGoggleEquipped() then return end  -- autocloth 已穿戴护目镜 → 无需复眼勋章
    if not _hazard_active then
        InventoryUtil:SaveEquipContext(EQUIPSLOTS.MEDAL)
        _hazard_active = true
    end
    AutoEquipMedal({M.ommateum})
end
local function LeaveHazard(_, player)
    if _hazard_active and not PlayerUtil:IsInStorm(player) and not PlayerUtil:IsInMiasma(player) then
        InventoryUtil:RestoreEquipContext(EQUIPSLOTS.MEDAL)
        _hazard_active = false
    end
end

local RPC_ID_TO_RECIPE = {}
local function GetRecipeByRpcId(rpc_id)
    if RPC_ID_TO_RECIPE[rpc_id] ~= nil then
        return RPC_ID_TO_RECIPE[rpc_id] or nil
    end
    for _, v in pairs(GLOBAL.AllRecipes) do
        if v.rpc_id then
            if RPC_ID_TO_RECIPE[v.rpc_id] == nil then
                RPC_ID_TO_RECIPE[v.rpc_id] = v
            end
            if v.rpc_id == rpc_id then
                return v
            end
        end
    end
    RPC_ID_TO_RECIPE[rpc_id] = false  -- 非真实配方，记住避免重复扫描
    return nil
end

local function Init(PlayerController, inst)
    if not inst then return end
    if not GLOBAL.TUNING.FUNCTIONAL_MEDAL_IS_OPEN then
        return
    end
    if inst._equipment_control_automedal_initialized then
        return
    end
    inst._equipment_control_automedal_initialized = true

    -- 初始化 PlayerUtil：缓存角色固有标签、组件等（此时勋章尚未装备）
    PlayerUtil:Init(inst)

    -- 悬停状态为模块级：换人/重载后旧任务与佩戴记录已失效，重置
    StopHoverTask(true)
    hover_is_active = false
    hover_worn_medal = nil
    _hazard_active = false

    -- 单世界判定：主机无洞穴时 ismastersim 为 true（参考 autocontainer.lua）
    IsMasterSim = WorldUtil:IsMasterSim()

    -- 单世界支持：builder_replica 在 ismastersim 时直接调用 component 而非 SendRPCToServer，
    -- 因此需要钩子 builder_replica 来拦截制作/建造动作以切换巧手勋章

    -- 单世界用组件，多世界用复制件
    if IsMasterSim then
        local builder = inst.components.builder
        if builder then
            _ApplyBuilderRecipeHooks(builder)
        end
    else
        local builder_replica = inst.replica.builder
        if builder_replica then
            _ApplyBuilderRecipeHooks(builder_replica)
        end
    end

    -- 让 WEARMEDAL/TAKEOFFMEDAL 走 ControllerUseItemOnSelfFromInvTile（仅单世界，多世界走 SendRPCToServer）
    -- 覆写理由（绕开官方 busy 门 + 动作收集）与实现都收在工具函数里，这里只声明要哪些动作
    if IsMasterSim then
        InventoryUtil:InstallUseItemOnSelfHook(inst.components.inventory, {
            GLOBAL.ACTIONS.WEARMEDAL, GLOBAL.ACTIONS.TAKEOFFMEDAL,
        })
    end

    -- 动态构建勋章分组
    BuildMedalGroups()

    -- 构建动作→勋章组映射
    BuildActionGroupMap()

    -- 进世界/重载后库存在激活时才同步完：这里先取一次，避免首次裁决才临时发 RPC（必然 miss）
    PlayerUtil:On("playeractivated", PrimeFusionInfo)

    if not PlayerController then return end


    -- 1. 钩子 OnControl：鼠标点击触发勋章切换
    -- OnControl 在 OnLeftClick/OnRightClick 之前执行，可抢先处理勋章切换。
    -- 同时处理 CONTROL_PRIMARY（左键）和 CONTROL_SECONDARY（右键），统一入口。
    -- 迁移到 actionutil 的「控制前钩子」通道（RegisterControlHandler，通道 I）：
    --   排队论(2873533916)用实例级 OnControl 在按住队列键时直接 return，把整条 OnControl 后半段吃掉，
    --   因此任何"包装 pc.OnControl"的做法（不管是类级还是更早的实例级）都会被它遮蔽
    --   —— 这正是"点击切勋章失效"的根因。通道 I 骑在输入事件总线上，注册时机早于
    --   playercontroller 自己 Activate() 时才注册的监听器，必定先跑且不可能被遮蔽。
    --   代价：通道 I 只能"抢跑"，不能否决后续处理；原实现本来也只是抢跑（末尾总会调 _OnControl）。
    -- skip_doaction：OnControl 已切勋章时，阻止后续 DoAction 钩子重复调用 HandleAction 覆盖勋章
    local skip_doaction = false
    ActionUtil:RegisterControlHandler(inst, 0, function(self, control, down)
        if not down then return end

        if control == CONTROL_PRIMARY then
            if self:IsAOETargeting() then return end
            local lmb = self:GetLeftMouseAction()

            -- 必须放在 HandleAction 之前，确保特殊目标勋章优先于速度勋章
            local active = InventoryUtil:GetActiveItem()
            local skip_handle = false
            if active then
                for _, cfg in ipairs(HOLD_ITEM_TARGET_CONFIG) do
                    if cfg.testfn(active) then
                        skip_handle = TrySwitchForNearbyTarget(lmb, cfg.matchfn, ResolveConfigMedals(cfg), cfg.worldfn)
                        if skip_handle then break end
                    end
                end
            end

            -- 命中特殊目标且切了勋章：跳过 HandleAction，避免速度勋章把厨师勋章切回去
            if skip_handle then
                skip_doaction = true
                StopHoverTask(true)  -- 停止悬停检测，但不切回（勋章已切到目标），由已有的 HandleAction 逻辑处理切回
            else
                -- 点击即提交：hover 已预切勋章时（hover_is_active），停止 hover_task 且不切回。
                -- 否则角色走向远处目标途中，摄像机/角色移动使鼠标相对目标偏移，
                -- hover tick 会误判 is_target=false 而在动作执行前提前切回勋章。
                -- 勋章保留，交由后续动作逻辑（HandleAction / newactiveitem）按现成记忆逻辑管理。
                if hover_is_active then
                    StopHoverTask(true)
                end
                HandleAction(lmb)
            end
        elseif control == CONTROL_SECONDARY then
            -- AOE瞄准检测：奔雷矛突刺/法杖范围施法等右键进入AOE瞄准模式时，
            -- 游戏将rmb置nil（CASTAOE由AOE系统处理），此时回退到lmb可能误触发
            -- PICK→植物勋章等错误切换。与PRIMARY分支一致，跳过勋章处理。
            if self:IsAOETargeting() then return end
            local act, source = ActionUtil:GetEffectiveClickAction(self)
            if act then
                HandleAction(act)
            else
                local active = InventoryUtil:GetActiveItem()
                if active then
                    -- lmb/rmb 都为 nil 时，回退到活跃物品（如吞噬法杖右键范围施法首次使用）
                    -- 构造合成 buffaction 让 HandleAction 的 CASTSPELL 分支处理
                    HandleAction({ action = { id = "CASTSPELL" }, invobject = active, target = nil })
                end
            end
        elseif control == CONTROL_MOVE_UP or control == CONTROL_MOVE_DOWN
            or control == CONTROL_MOVE_LEFT or control == CONTROL_MOVE_RIGHT then
            HandleAction({ action = { id = "WALKTO" } })
        end
    end)


    -- 1.2 钩子 OnRightClick：右键点击触发勋章切换
    -- 使用实例级钩子（而非原型级），确保与其他 AddClassPostConstruct 实例钩子独立共存
    local pc = inst.components.playercontroller
    if pc then
        -- 1.2 右键点击触发勋章切换：逻辑迁至 actionutil 通用分发（RegisterRightClickHandler）
        -- handler 内 self=playercontroller，rmb=右键 BufferedAction；"consume" 短路（已切到某勋章时跳过 HUD 循环）
        ActionUtil:RegisterRightClickHandler(inst, 0, function(self, rmb)
            if not ActionUtil:IsEmptyClickAction(rmb) then
                HandleAction(rmb)
            else
                local active = InventoryUtil:GetActiveItem()
                local switched = false
                if active then
                    for _, cfg in ipairs(ACTIVE_ITEM_MEDAL_CONFIG) do
                        if cfg.testfn(active) then
                            AutoEquipMedal(cfg.medals)
                            switched = true
                            break
                        end
                    end
                end
                if not switched then
                    HandleAction(self:GetLeftMouseAction())
                end
            end

        end)

        -- 1.3 钩子 DoAction（实例级）：拦截所有动作执行，包括排队论(ActionQueue)的 DoAction 调用
        -- 排队论(2873533916)在 actionqueuer:SendAction 中直接调用 playercontroller:DoAction(act)，
        -- 不经过 OnControl/OnRightClick/PushAction，因此必须钩子实例级 DoAction
        -- 使用实例级钩子而非类级，避免多玩家链式调用，且与其他实例钩子保持一致性
        local _DoAction = pc.DoAction
        pc.DoAction = function(self, buffaction, ...)
            if ActionUtil:IsValidBufferedAction(buffaction) and not skip_doaction then
                HandleAction(buffaction)
            end
            skip_doaction = false
            return _DoAction(self, buffaction, ...)
        end
    end

    -- 1.5 钩子 DoActionButton：空格键触发勋章切换
    local _DoActionButton = PlayerController.DoActionButton
    function PlayerController:DoActionButton(...)
        local buffaction = self:GetActionButtonAction()
        HandleAction(buffaction)
        return _DoActionButton(self, ...)
    end

    -- 1.65 钩子 SendRPCToServer：拦截建造/制作 RPC + 拆礼物 RPC
    -- 参考勋章辅助(3643215504)的 RPC 拦截方案，builder.MakeRecipeFromMenu 钩子不可靠
    -- 排队论(2873533916)的 LeftClick/RightClick RPC 勋章切换已迁至 actionutil（RegisterClickRPCHandler）
    ActionUtil:RegisterClickRPCHandler(function(action_id, target)
        HandleAction({ action = { id = action_id }, target = target })
    end)
    local _SendRPCToServer = GLOBAL.SendRPCToServer
    function GLOBAL.SendRPCToServer(rpc, ...)
        if rpc == GLOBAL.RPC.UseItemFromInvTile then
            local args = {...}
            local unwrap_action = GLOBAL.ACTIONS.UNWRAPGIFTFRUIT
            if unwrap_action and args[1] == unwrap_action.code then
                HandleAction({ action = unwrap_action, invobject = args[2] })
            end
        end
        if rpc == GLOBAL.RPC.MakeRecipeFromMenu or rpc == GLOBAL.RPC.MakeRecipeAtPoint then
            local args = {...}
            local recipe = GetRecipeByRpcId(args[1])
            -- 非真实配方(横板技能施法等模组伪造的MakeRecipe RPC)不切巧手勋章
            if not recipe then
                return _SendRPCToServer(rpc, ...)
            end
            _HandleCraftRecipe(recipe)
        end
        return _SendRPCToServer(rpc, ...)
    end

    -- 2. [薇格弗德]钩子 GetAttackTarget：标记动物，根据目标类型切换勋章
    local _GetAttackTarget = PlayerController.GetAttackTarget
    function PlayerController:GetAttackTarget(...)
        local ent = _GetAttackTarget(self, ...)
        HandleAttackTarget(ent, EQUIPSLOTS.MEDAL)
        return ent
    end

    -- 3. 手持物品 → 鼠标悬停目标 → 预切勋章，移开/放下 → 切回
    -- 覆盖 HOLD_ITEM_TARGET_CONFIG 全部条目：研磨物→研磨站、种子→耕地、空白/融合→地面空白/融合
    -- 点击触发动作后停止 hover_task，不再管理切回，由已有的 HandleAction 逻辑处理
    -- 三条 testfn 互斥（可研磨调料 / 农场植物种子 / 空白融合勋章），取第一条命中的即可
    InventoryEventService:On(InventoryEventService.EVENT.ACTIVE_CHANGED, function()
        local item = InventoryUtil:GetActiveItem()
        if not item then StopHoverTask() return end

        local cfg = nil
        for _, c in ipairs(HOLD_ITEM_TARGET_CONFIG) do
            if c.testfn(item) then cfg = c break end
        end
        if not cfg then StopHoverTask() return end
        if hover_task then return end

        hover_is_active = false
        hover_task = inst:DoPeriodicTask(3 * FRAMES, function()
            local active = ThePlayer and InventoryUtil:GetActiveItem()
            if not active or not cfg.testfn(active) then StopHoverTask() return end

            -- 悬停检测：地皮类走世界坐标，实体类走鼠标下实体（由 cfg 决定用哪个）
            local is_target = false
            if cfg.worldfn then
                local pos = TheInput:GetWorldPosition()
                is_target = pos ~= nil and cfg.worldfn(pos)
            elseif cfg.matchfn then
                local ent = TheInput:GetWorldEntityUnderMouse()
                is_target = ent ~= nil and ent:IsValid() and cfg.matchfn(ent)
            end

            if is_target and not hover_is_active then
                -- 换入：AutoEquipItem 的融合插入分支与攻击链同一套优先级策略
                -- （空槽直接放；箱满按 _ComputeContextElevation + PickRemovableContent 挑受害者）
                local medals = ResolveConfigMedals(cfg)
                InventoryUtil:SaveEquipContext(EQUIPSLOTS.MEDAL)
                AutoEquipMedal(medals)
                -- 记下箱内那枚，移开时摘除
                local equipped = InventoryUtil:GetEquippedItem(EQUIPSLOTS.MEDAL)
                for _, mp in ipairs(medals) do
                    local found = FindItemInFusion(equipped, mp)
                    if found then hover_worn_medal = found break end
                end
                hover_is_active = true
            elseif not is_target and hover_is_active then
                -- 换出：摘除悬停时戴上的那枚 + 恢复原装备上下文
                local worn = hover_worn_medal
                hover_worn_medal = nil
                if worn then
                    InventoryUtil:SendEquipAction(ACTIONS.TAKEOFFMEDAL, worn, "workshop-1909182187")
                end
                InventoryUtil:RestoreEquipContext(EQUIPSLOTS.MEDAL)
                hover_is_active = false
            end
        end)
    end)
    -- 7. 温度触发：AutoEquipMedal 内部已有已装备/融合箱检测
    PlayerUtil:On("startfreezing", function(data, player)
        AutoEquipMedal({M.down_filled_coat})
    end)
    PlayerUtil:On("startoverheating", function(data, player)
        AutoEquipMedal({M.blue_crystal})
    end)
    -- 8. 风暴/瘴气触发：进入时装备复眼勋章，离开时回退原勋章
    PlayerUtil:On("startstorm", EnterHazard)
    PlayerUtil:On("startmiasma", EnterHazard)
    PlayerUtil:On("stopstorm", LeaveHazard)
    PlayerUtil:On("stopmiasma", LeaveHazard)
    -- 9. 烧伤触发：受到火焰伤害时自动装备浴火勋章
    PlayerUtil:On("startfiredamage", function(data, player)
        AutoEquipMedal({M.bathingfire})
    end)
end

AddComponentPostInit("playercontroller", Init)