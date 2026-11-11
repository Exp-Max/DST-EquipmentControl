-- autocook.lua
-- 智能烹饪：数据层 + 烹饪锅打开钩子 + 一键制作执行。
--
-- 数据流：
--   1) census：主栏/背包/已打开容器（实时）+ 附近关闭容器（箱子记忆/ShowMe/Insight 估算）
--   2) planner：按食材 tag 本质折叠成 kind，分帧枚举出「必出」组合
--   3) 一键制作：从实时库存投料后点火，取物交给自动容器模块的右键取物
--
-- 面板本体在 scripts/widgets/autocookpanel.lua，接口保持
-- SetRecipeList / SetCraftableMap / SetPreviewCombos / SetPotCandidates / SetMedalFoodSet。

local cooking = require("cooking")
local InventoryUtil = require("util/inventoryutil")
local InsightUtil = require("util/insightutil")
local InventoryEventService = require("util/inventoryeventservice")
local ItemUtil = require("util/itemutil")
local AutocookPanel = require("widgets/autocookpanel")
local Planner = require("util/autocookplanner")

local CONFIG = MOD_EQUIPMENT_CONTROL.CONFIG

-- 棱镜「月炆宝炊」没有 stewer 标签：容器每 5 槽一行（前 4 槽食材、第 5 槽产物），
-- acceptsstacks 默认 true，配方按 portablecookpot 计算；inf 版为 20 槽（4 行）。
local SIMMERED_COOKERS = {
    simmeredmoonlight = true,
    simmeredmoonlight_pro = true,
    simmeredmoonlight_inf = true,
    simmeredmoonlight_pro_inf = true,
}

local COOKER_PREFABS = {
    cookpot = true,
    portablecookpot = true,
    archive_cookpot = true,
}

local DEFAULT_COOKER_SLOTS = 4
-- 与 autocontainer 的附近容器搜索半径一致
local CENSUS_RADIUS = 30
local SCAN_TTL = 4
local PLAN_BUDGET_MS = 5
local STREAM_PERIOD = 0.35
local REFRESH_DELAY = 0.2

local function IsSimmeredMoonlight(inst)
    return inst ~= nil and SIMMERED_COOKERS[inst.prefab] == true
end

-- ===========================================================================
-- 1. 锅具识别与归一化
-- ===========================================================================

local function GetCookerSlotCount(cooker_inst)
    local slots = InventoryUtil:GetSlotCount(cooker_inst)
    return slots > 0 and slots or DEFAULT_COOKER_SLOTS
end

-- 月炆宝炊容器是 5 槽（inf 版 20 槽），但每行只有前 4 槽是食材槽，
-- 第 5 槽是产物槽，组合求解必须按 4 个食材算。
local function GetIngredientSlotCount(cooker_inst)
    if IsSimmeredMoonlight(cooker_inst) then
        return DEFAULT_COOKER_SLOTS
    end
    return GetCookerSlotCount(cooker_inst)
end

-- 官方 cooking.recipes 按锅具分表，大厨菜只注册在 portablecookpot：
-- 严格按当前锅取名，不做「随便挑一个 cooker」兜底，普通锅才不会做大厨菜。
-- 月炆宝炊按棱镜真实路径 cooking.CalculateRecipe("portablecookpot", names) 归一。
local function GetRecipeCookerName(cooker_inst)
    if IsSimmeredMoonlight(cooker_inst) then
        return "portablecookpot"
    end
    local name = cooker_inst ~= nil and cooker_inst.prefab or nil
    if name == nil or cooking.recipes[name] == nil then
        return "cookpot"
    end
    return name
end

local function IsCooker(inst)
    if inst == nil then
        return false
    end
    -- 月炆宝炊只有 moonsimmered 组件，没有 stewer 标签
    if IsSimmeredMoonlight(inst) then
        return true
    end
    if COOKER_PREFABS[inst.prefab] then
        return true
    end
    -- 模组锅具通常沿用炖锅的 stewer 标签
    return inst:HasTag("stewer")
end

-- ===========================================================================
-- 2. 食谱目录（UI 展示全部食谱；可做判定由 planner 按当前锅具另算）
-- ===========================================================================

local RecipeDB = {
    ALL       = {},
    BY_PREFAB = {},
    BY_COOKER = {},
}

local function CollectAllRecipes()
    if #RecipeDB.ALL > 0 then
        return
    end

    RecipeDB.ALL = {}
    RecipeDB.BY_PREFAB = {}

    local cookers_to_collect = {"cookpot", "portablecookpot"}

    local function IsModCooker(name)
        return name ~= "cookpot"
            and name ~= "portablecookpot"
            and name ~= "portablespicer"
            and name ~= "portableblender"
    end

    for cooker_name in pairs(cooking.recipes) do
        if IsModCooker(cooker_name) then
            table.insert(cookers_to_collect, cooker_name)
        end
    end

    for _, cooker_name in ipairs(cookers_to_collect) do
        local recipes = cooking.recipes[cooker_name]
        if recipes ~= nil then
            for prefab, recipe_def in pairs(recipes) do
                if recipe_def.test ~= nil
                    and (recipe_def.weight or 1) > 0
                    and not recipe_def.no_cookbook then
                    local data = RecipeDB.BY_PREFAB[prefab]
                    if data == nil then
                        data = {
                            prefab     = prefab,
                            name       = STRINGS.NAMES[string.upper(prefab)] or prefab,
                            health     = recipe_def.health or 0,
                            hunger     = recipe_def.hunger or 0,
                            sanity     = recipe_def.sanity or 0,
                            cooktime   = recipe_def.cooktime,
                            priority   = recipe_def.priority or 0,
                            foodtype   = recipe_def.foodtype or FOODTYPE.GENERIC,
                            recipe_def = recipe_def,
                            craftable  = false,
                            cookers    = {},
                        }
                        RecipeDB.BY_PREFAB[prefab] = data
                        table.insert(RecipeDB.ALL, data)
                    end
                    data.cookers[cooker_name] = true
                end
            end
        end
    end

    table.sort(RecipeDB.ALL, function(a, b)
        if a.priority == b.priority then
            return a.name < b.name
        end
        return a.priority > b.priority
    end)

    -- 官方 cooking.lua：普通菜注册到 cookpot/portablecookpot/archive_cookpot，
    -- 大厨菜(preparedfoods_warly)只注册到 portablecookpot。按锅具分目录后，
    -- 普通锅的网格里就不会出现永远做不出来的大厨料理。
    RecipeDB.BY_COOKER = {}
    for _, data in ipairs(RecipeDB.ALL) do
        for cooker_name in pairs(data.cookers) do
            local list = RecipeDB.BY_COOKER[cooker_name]
            if list == nil then
                list = {}
                RecipeDB.BY_COOKER[cooker_name] = list
            end
            table.insert(list, data)
        end
    end
end

-- 面板与可做判定共用「当前锅具真实注册过」的配方目录
local function GetRecipesForCooker(cooker_inst)
    CollectAllRecipes()
    local cooker_name = GetRecipeCookerName(cooker_inst)
    local list = RecipeDB.BY_COOKER[cooker_name]
    if list == nil then
        list = RecipeDB.BY_COOKER.cookpot or {}
    end
    return list
end

-- ===========================================================================
-- 3. census：实时库存 + 附近关闭容器估算
-- ===========================================================================

local function AddCensusItem(census, prefab, count, source)
    if prefab == nil or not ItemUtil:IsCookingIngredient(prefab) or count <= 0 then
        return
    end
    census.counts[prefab] = (census.counts[prefab] or 0) + count
    if source.live == true then
        census.live_counts[prefab] = (census.live_counts[prefab] or 0) + count
    end

    source.count = count
    local list = census.sources[prefab]
    if list == nil then
        list = {}
        census.sources[prefab] = list
    end
    table.insert(list, source)
end

-- 实时槽位：主物品栏 / 背包 / 已打开容器，排除当前使用的锅
local function AddLiveSources(census, cooker_inst)
    local inv = InventoryUtil:GetInventory()
    if inv == nil then
        return
    end

    local function AddSlots(replica, container_inst)
        if replica == nil then
            return
        end
        local items = replica:GetItems()
        if items == nil then
            return
        end
        for slot, item in pairs(items) do
            if item ~= nil and item ~= cooker_inst then
                local count = 1
                if item.replica ~= nil and item.replica.stackable ~= nil then
                    count = item.replica.stackable:StackSize() or 1
                end
                AddCensusItem(census, item.prefab, count, {
                    slot      = slot,
                    container = container_inst,
                    live      = true,
                })
            end
        end
    end

    AddSlots(inv, nil)

    local overflow = InventoryUtil:GetOverflowContainer()
    if overflow ~= nil and overflow.inst ~= cooker_inst then
        AddSlots(overflow, overflow.inst)
    end

    for _, replica in ipairs(InventoryUtil:GetOpenContainers()) do
        local container_inst = replica ~= nil and replica.inst or nil
        if container_inst ~= nil and container_inst ~= cooker_inst then
            AddSlots(replica, container_inst)
        end
    end
end

local scan_cache = nil

local function FindNearbyContainers(cooker_inst)
    local center = (cooker_inst ~= nil and cooker_inst:IsValid()) and cooker_inst or ThePlayer
    if center == nil then
        return {}
    end
    local x, y, z = center.Transform:GetWorldPosition()
    local now = GetTime()
    if scan_cache ~= nil and scan_cache.center == center
        and scan_cache.radius == CENSUS_RADIUS
        and (now - scan_cache.t) < SCAN_TTL
        and math.abs(scan_cache.x - x) < 0.1
        and math.abs(scan_cache.z - z) < 0.1 then
        return scan_cache.ents
    end

    -- 以锅为中心：基地储物在锅附近，不在玩家脚下
    local ents = TheSim:FindEntities(x, y, z, CENSUS_RADIUS, nil,
        {"INLIMBO", "FX", "NOCLICK"})
    scan_cache = { center = center, radius = CENSUS_RADIUS, t = now, x = x, z = z, ents = ents }
    return ents
end

local function IsScannableStorage(ent, cooker_inst)
    if ent == nil or not ent:IsValid() or ent == cooker_inst then
        return false
    end
    if ent.replica == nil or ent.replica.container == nil then
        return false
    end
    -- 已打开容器已按实时读数统计，不再重复计入估算
    if InventoryUtil:IsContainerOpenedBy(ent) then
        return false
    end
    -- 可移动容器按坐标记忆会失效；锅具、掉落背包、可装备物不是储物
    if ent:HasTag("chester")
        or ent:HasTag("stewer")
        or IsSimmeredMoonlight(ent)
        or ent.replica.inventoryitem ~= nil
        or ent.replica.equippable ~= nil then
        return false
    end
    return true
end

-- 关闭容器客户端拿不到实时槽位（container_classified 只在打开期间同步），
-- 优先级：Insight 精确计数 > EC 箱子记忆快照 > ShowMe 存在性。
local function AddEstimatedSources(census, cooker_inst)
    local CM = MOD_EQUIPMENT_CONTROL.CM
    local insight_ready = InsightUtil.IsAvailable()

    for _, ent in ipairs(FindNearbyContainers(cooker_inst)) do
        if IsScannableStorage(ent, cooker_inst) then
            local exact = nil
            local presence = nil
            local memory = nil

            -- Insight：网络下发的真实 stacksize，关闭容器里最可信
            if insight_ready then
                local info = InsightUtil.GetAll(ent)
                local cont = info ~= nil and type(info.special_data) == "table"
                    and info.special_data.container or nil
                if cont ~= nil and type(cont.contents) == "table" then
                    exact = {}
                    for _, v in ipairs(cont.contents) do
                        if v.prefab ~= nil then
                            exact[v.prefab] = (exact[v.prefab] or 0)
                                + (tonumber(v.stacksize) or 1)
                        end
                    end
                    if next(exact) == nil then
                        exact = nil
                    end
                end
            end

            -- ShowMe：只有「有哪些 prefab」，数量按 1 计
            if ent.ShowMe_chest_table ~= nil then
                presence = {}
                for prefab in pairs(ent.ShowMe_chest_table) do
                    presence[prefab] = 1
                end
                if next(presence) == nil then
                    presence = nil
                end
            end

            -- EC 箱子记忆：开箱→关箱快照，带 stacksize；槽位不作为投料依据
            if CONFIG.CHEST_MEMORY_ENABLED ~= false and CM ~= nil and CM.chest ~= nil then
                local widget = CM.chest[ent]
                if widget ~= nil and widget.GetItems ~= nil then
                    memory = {}
                    for _, info in pairs(widget:GetItems() or {}) do
                        if info ~= nil and info.prefab ~= nil then
                            memory[info.prefab] = (memory[info.prefab] or 0)
                                + (tonumber(info.stacksize) or 1)
                        end
                    end
                    if next(memory) == nil then
                        memory = nil
                    end
                end
            end

            -- 一个容器只取一个来源，避免重复计数
            local counts = exact or memory or presence
            if counts ~= nil then
                for prefab, count in pairs(counts) do
                    AddCensusItem(census, prefab, count, {
                        slot      = nil,
                        container = ent,
                        live      = false,
                    })
                    if counts ~= exact then
                        census.approx[prefab] = true
                    end
                end
            end
        end
    end
end

local function BuildCensus(cooker_inst)
    local census = { counts = {}, live_counts = {}, approx = {}, sources = {} }
    -- 实时源先入列表：一键制作优先取可直接访问的物品
    AddLiveSources(census, cooker_inst)
    AddEstimatedSources(census, cooker_inst)
    census.sig_kinds = Planner.KeysSignature(census.counts)

    -- 只含角色物品栏 + 所有打开容器：这一档才可一键制作；
    -- 全量 census 用来判断「附近容器有材料」。
    census.live = {
        counts = census.live_counts,
        approx = {},
    }

    return census
end

---------------------------------------------------------------------------
-- 「已发现配方」：详情区下方的曾用组合（官方 CookbookData:AddRecipe 已排序、
-- 去掉 _cooked 后缀）。既是一键烹饪的首选，也是 planner 漏算时的兜底。
---------------------------------------------------------------------------

local function ComboKey(items)
    local copy = {}
    for i, prefab in ipairs(items) do
        copy[i] = prefab
    end
    table.sort(copy)
    return table.concat(copy, ",")
end

local function GetKnownCombos(prefab, cooker_name, slots, census)
    local known = TheCookbook ~= nil and TheCookbook.preparedfoods ~= nil
        and TheCookbook.preparedfoods[prefab] or nil
    if known == nil or known.recipes == nil then
        return {}
    end

    local out, seen = {}, {}
    for _, items in ipairs(known.recipes) do
        if #items == slots then
            local need = {}
            local enough = true
            for _, item in ipairs(items) do
                need[item] = (need[item] or 0) + 1
            end
            for item, count in pairs(need) do
                if (census.counts[item] or 0) < count then
                    enough = false
                    break
                end
            end
            -- 最终仍以官方 recipe.test 终判「必出」，不信任历史记录本身
            if enough and Planner.TestCombo(cooker_name, prefab, items) then
                local key = ComboKey(items)
                if not seen[key] then
                    seen[key] = true
                    table.insert(out, items)
                end
            end
        end
    end
    return out
end

-- ===========================================================================
-- 4. 面板生命周期
-- ===========================================================================

local active_panel = nil
local active_cooker = nil
local active_census = nil
local active_recipes = {}   -- 当前锅具的食谱目录
local refresh_task = nil
local events_registered = false
local stream_timer = 0
local last_pot_key = nil

-- 预填充暂存：点击食谱后暂存食材组合，点击 Cook 才真正搬运
local pending_combo = nil       -- 当前选中的搬运动作列表
local pending_combos = nil      -- 所有组合的搬运动作列表 {{entries}, ...}

-- 快速重复（合并自 Exp_Max 的「自动做饭」）：记住上次点火时锅里的食材，
-- 锅空且按住 Ctrl 时自动补齐同一组合再点火。
local last_cook_combo = nil     -- 上次点火的食材 prefab 数组
local fast_repeat_task = nil    -- 0.1s 延时任务，防 validfn 每帧重复调度

-- 勋章模组烹饪勋章的「已记录料理」：服务端 foodlist 同步到玩家实体
-- net_string medal_food_list（逗号分隔，装备时同步、卸下清空）。
-- 未启用勋章模组或当前无数据时返回空集合，仅用于面板标记，不做负面推断。
local function ReadMedalFoodList()
    local food_set = {}
    local food_list = ThePlayer ~= nil and ThePlayer.medal_food_list or nil
    if food_list == nil then
        return food_set
    end

    local foodstr = food_list:value()
    if foodstr == nil or foodstr == "" then
        return food_set
    end

    for _, prefab in ipairs(string.split(foodstr, ",")) do
        if prefab ~= "" then
            food_set[prefab] = true
        end
    end

    return food_set
end

local function RefreshMedalFoodList()
    if active_panel == nil or not active_panel.inst:IsValid() then
        return
    end

    active_panel:SetMedalFoodSet(ReadMedalFoodList())
end

-- 通道 2：读当前锅的食材槽，反向算「这一锅会做出什么」。
-- 客户端只有打开期间才有 replica 槽位；月炆宝炊每行前 4 槽是食材、第 5 槽是产物，
-- 只取第一个有食材的行，避免把 4 行食材混成一锅。
local function ReadPotIngredients(cooker_inst)
    if cooker_inst == nil or not cooker_inst:IsValid() then
        return nil
    end
    local rep = cooker_inst.replica ~= nil and cooker_inst.replica.container or nil
    local items = rep ~= nil and rep:GetItems() or nil
    if items == nil then
        return nil
    end

    local function Collect(slots)
        local prefabs = {}
        for _, slot in ipairs(slots) do
            local item = items[slot]
            if item ~= nil and item.prefab ~= nil then
                table.insert(prefabs, item.prefab)
            end
        end
        if #prefabs == 0 then
            return nil
        end
        table.sort(prefabs)
        return prefabs
    end

    if IsSimmeredMoonlight(cooker_inst) then
        for base = 1, GetCookerSlotCount(cooker_inst), 5 do
            local row = Collect({ base, base + 1, base + 2, base + 3 })
            if row ~= nil then
                return row
            end
        end
        return nil
    end

    local slots = {}
    for slot in pairs(items) do
        table.insert(slots, slot)
    end
    return Collect(slots)
end

local function RefreshPotCandidates(force)
    if active_panel == nil or active_cooker == nil then
        return
    end

    local cooker_name = GetRecipeCookerName(active_cooker)
    local prefabs = ReadPotIngredients(active_cooker)
    local slots = GetIngredientSlotCount(active_cooker)
    local key = cooker_name .. "\0" .. tostring(slots) .. "\0"
        .. (prefabs ~= nil and table.concat(prefabs, "|") or "")
    if not force and key == last_pot_key then
        return
    end
    last_pot_key = key

    -- 未填满：排除已填食材已违反上限的配方，其余列为可能；填满：按官方优先级精确判定
    local candidates = prefabs ~= nil
        and Planner.GetPotPossibleRecipes(cooker_name, prefabs, slots) or nil
    -- 反向结果标到左侧食谱网格，详情区只保留预填食材
    active_panel:SetPotCandidates(candidates)
end

local function RefreshCraftableMap()
    if active_panel == nil or active_cooker == nil or active_census == nil then
        return
    end

    local cooker_name = GetRecipeCookerName(active_cooker)
    local slots = GetIngredientSlotCount(active_cooker)

    -- 全量（含附近关闭容器估算）：判断「附近有材料」
    local full_map = Planner.GetCraftableMap(active_recipes, active_census)
    -- 实时（角色物品栏 + 所有打开容器）：只有这一档才能一键制作
    local live_map = Planner.GetCraftableMap(active_recipes, active_census.live)

    -- planner 漏算兜底：当前选中配方若有可用「已发现配方」组合，补进 live_map，
    -- 让网格档位与预览一致（例如 bananapop 的 cave_banana+ice+twigs+twigs）。
    local sel = active_panel.selected
    if sel ~= nil and live_map[sel.prefab] ~= true
        and #GetKnownCombos(sel.prefab, cooker_name, slots, active_census.live) > 0 then
        live_map[sel.prefab] = true
        full_map[sel.prefab] = true
    end

    for _, recipe in ipairs(active_recipes) do
        recipe.autocook_nearby = full_map[recipe.prefab] == true
            and live_map[recipe.prefab] ~= true
    end

    active_panel:SetCraftableMap(live_map)
    RefreshPotCandidates()
end

local function StartComputeIfNeeded(cooker_inst, force)
    if active_census == nil then
        return
    end
    local cooker_name = GetRecipeCookerName(cooker_inst)
    local slots = GetIngredientSlotCount(cooker_inst)
    if force
        or Planner.cooker_name ~= cooker_name
        or Planner.slots ~= slots
        or Planner.sig_kinds ~= active_census.sig_kinds then
        Planner.StartCompute(cooker_name, slots, active_census)
        stream_timer = 0
    end
    if not Planner.IsComputing() then
        RefreshCraftableMap()
    end
end

-- 枚举分帧推进，局部结果每 STREAM_PERIOD 秒刷新一次面板
local function PumpPlanner(dt)
    if not Planner.IsComputing() then
        return
    end
    local done = Planner.Step(PLAN_BUDGET_MS)
    stream_timer = stream_timer - (dt or 0)
    if done or stream_timer <= 0 then
        stream_timer = STREAM_PERIOD
        RefreshCraftableMap()
    end
end

local function ScheduleCraftableRefresh()
    if active_panel == nil or active_cooker == nil then
        return
    end
    if refresh_task ~= nil then
        refresh_task:Cancel()
        refresh_task = nil
    end
    refresh_task = ThePlayer:DoTaskInTime(REFRESH_DELAY, function()
        refresh_task = nil
        if active_panel == nil or active_cooker == nil or not active_panel:IsVisible() then
            return
        end
        active_census = BuildCensus(active_cooker)
        StartComputeIfNeeded(active_cooker, false)
        RefreshPotCandidates()
        -- 右键取物后库存变化：用新 census 重新物化当前预览，
        -- 灰色食谱一旦变成可做，Cook 就能直接投料，不必再点一次食谱。
        if active_panel.selected ~= nil and active_panel.preview_combos ~= nil
            and active_panel.on_fill ~= nil then
            active_panel.on_fill(active_panel, active_panel.selected)
        end
    end)
end

local function RegisterInventoryEvents()
    if events_registered or ThePlayer == nil then
        return
    end
    events_registered = true

    local E = InventoryEventService.EVENT
    for _, event in ipairs({
        E.ITEM_ADDED,
        E.ITEM_REMOVED,
        E.STACK_CHANGED,
        E.ACTIVE_CHANGED,
        E.INVENTORY_REFRESH,
        E.CONTAINER_OPENED,
        E.CONTAINER_CLOSED,
    }) do
        InventoryEventService:On(event, ScheduleCraftableRefresh, ThePlayer)
    end

    ThePlayer:ListenForEvent("medal_food_listdirty", RefreshMedalFoodList)
end

-- ===========================================================================
-- 快速重复（合并自 Exp_Max 的「自动做饭」）
-- 与面板的一键投料共用同一个 Cook 按钮 hook 和同一套投料 RPC，
-- 避免两套 buttoninfo 包装互相覆盖。
-- ===========================================================================

-- 把 planner 物化出来的 prefab 组合，按 census 的实时来源定位成投料条目。
-- 估算来源只用于「可做」显示，不参与一键投料：取物由自动容器模块的右键取物完成。
local function BuildComboEntries(combo_prefabs, census)
    local entries = {}
    local used = {}
    for _, prefab in ipairs(combo_prefabs) do
        local list = census.sources[prefab] or {}
        local found = nil
        for i, src in ipairs(list) do
            if src.live == true then
                local bucket = used[prefab]
                local consumed = bucket ~= nil and (bucket[i] or 0) or 0
                if consumed < (src.count or 1) then
                    if bucket == nil then
                        bucket = {}
                        used[prefab] = bucket
                    end
                    bucket[i] = consumed + 1
                    found = src
                    break
                end
            end
        end
        if found == nil then
            return nil
        end
        table.insert(entries, {
            prefab    = prefab,
            slot      = found.slot,
            container = found.container,
        })
    end
    return entries
end

local function ComboPrefabs(combo)
    local out = {}
    for _, entry in ipairs(combo) do
        if entry.prefab ~= nil then
            table.insert(out, entry.prefab)
        end
    end
    return #out > 0 and out or nil
end

-- 原生点 COOK 时锅里已填的食材，按槽序读成连续数组
local function ReadPotCombo(inst)
    local rep = inst ~= nil and inst.replica ~= nil and inst.replica.container or nil
    if rep == nil or rep.GetItems == nil then
        return nil
    end
    local items = rep:GetItems()
    if items == nil then
        return nil
    end
    local slots = {}
    for slot in pairs(items) do
        if type(slot) == "number" then
            table.insert(slots, slot)
        end
    end
    table.sort(slots)
    local combo = {}
    for _, slot in ipairs(slots) do
        local item = items[slot]
        if item ~= nil and item.prefab ~= nil then
            table.insert(combo, item.prefab)
        end
    end
    return #combo > 0 and combo or nil
end

local function CanFastRepeat(inst)
    if last_cook_combo == nil or #last_cook_combo == 0 then
        return false
    end
    local rep = inst ~= nil and inst.replica ~= nil and inst.replica.container or nil
    if rep == nil or rep.IsEmpty == nil or not rep:IsEmpty() then
        return false
    end
    return TheInput ~= nil and TheInput:IsKeyDown(KEY_CTRL) == true
end

-- 投料 + 点火：面板一键烹饪与快速重复共用，避免两处各写一遍 RPC 序列
local function FireCook(inst, combo)
    if active_panel ~= nil and active_panel.inst:IsValid() then
        active_panel:SetPreviewCombos(nil)
    end

    local cont_rep = inst.replica ~= nil and inst.replica.container or nil
    local accepts_stacks = nil
    if cont_rep ~= nil then
        local ok, val = pcall(cont_rep.AcceptsStacks, cont_rep)
        accepts_stacks = ok and val or nil
    end
    local is_stacking = accepts_stacks == true

    for i, entry in ipairs(combo) do
        if is_stacking then
            if entry.container == nil then
                SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, entry.slot, nil, 1)
            else
                SendRPCToServer(RPC.TakeActiveItemFromCountOfSlot, entry.slot, entry.container, 1)
            end
            SendRPCToServer(RPC.SwapActiveItemWithSlot, i, inst)
        else
            if entry.container == nil then
                SendRPCToServer(RPC.MoveInvItemFromCountOfSlot, entry.slot, inst, 1)
            else
                SendRPCToServer(RPC.MoveItemFromCountOfSlot, entry.slot, entry.container, inst, 1)
            end
        end
    end
    SendRPCToServer(RPC.DoWidgetButtonAction,
        ACTIONS.COOK.code, inst, ACTIONS.COOK.mod_name)
end

local function ScheduleFastRepeat(inst, btn)
    if fast_repeat_task ~= nil or ThePlayer == nil then
        return
    end
    fast_repeat_task = ThePlayer:DoTaskInTime(0.1, function()
        fast_repeat_task = nil
        if inst ~= nil and inst:IsValid() and CanFastRepeat(inst) then
            btn.fn(inst, ThePlayer)
        end
    end)
end

local function SetupCookButtonHook(container_widget)
    local rep = container_widget.container ~= nil
        and container_widget.container.replica ~= nil
        and container_widget.container.replica.container
    if rep == nil then
        return
    end

    local widget_data = rep:GetWidget()
    if widget_data == nil or widget_data.buttoninfo == nil then
        return
    end

    -- 不同锅具的 buttoninfo 是不同表（官方锅共享、红晶锅/月炆宝炊各自独立），
    -- 按表幂等挂一次，避免反复包装形成调用链。
    local btn = widget_data.buttoninfo
    if btn._ec_autocook_hooked then
        return
    end
    btn._ec_autocook_hooked = true

    -- 包装 validfn：按住 Ctrl 的快速重复优先，否则有暂存组合时让按钮可点击
    local orig_validfn = btn.validfn
    btn.validfn = function(inst)
        if CanFastRepeat(inst) then
            ScheduleFastRepeat(inst, btn)
            return true
        end
        if pending_combo ~= nil and #pending_combo > 0 then
            return true
        end
        if orig_validfn ~= nil then
            return orig_validfn(inst)
        end
        return false
    end

    -- 包装 fn：按住 Ctrl 只做上一道组合 > 面板暂存组合（仅空锅）> 原生 COOK。
    -- 面板会在开锅/刷新档位时自动写入 pending_combo，若让它抢先，Ctrl 重复出来的
    -- 就是「当前面板选中食谱」而不是上一道；锅里已有食材时也必须按锅内实际食材记录。
    local orig_fn = btn.fn
    btn.fn = function(inst, doer)
        if CanFastRepeat(inst) then
            local entries = BuildComboEntries(last_cook_combo, BuildCensus(inst))
            if entries ~= nil and #entries > 0 then
                FireCook(inst, entries)
            end
            return
        end

        local pot_combo = ReadPotCombo(inst)
        if pot_combo == nil and pending_combo ~= nil and #pending_combo > 0 then
            local combo = pending_combo
            pending_combo = nil
            pending_combos = nil
            last_cook_combo = ComboPrefabs(combo) or last_cook_combo
            FireCook(inst, combo)
            return
        end

        -- 原生点 COOK：记住锅里已填的食材，供下一次快速重复
        if pot_combo ~= nil then
            last_cook_combo = pot_combo
        end
        if orig_fn ~= nil then
            orig_fn(inst, doer)
        end
    end
end

local function EnsurePanel(container_widget)
    if active_panel ~= nil and active_panel.inst:IsValid() then
        return active_panel
    end

    if ThePlayer == nil or ThePlayer.HUD == nil then
        return nil
    end

    local parent_root = nil
    if container_widget ~= nil then
        parent_root = container_widget:GetParent()
    end
    if parent_root == nil then
        parent_root = ThePlayer.HUD
    end

    active_panel = parent_root:AddChild(AutocookPanel(ThePlayer))
    active_panel:SetScale(1.0)
    active_panel:Hide()

    RegisterInventoryEvents()

    return active_panel
end

local function OpenAutocookPanel(cooker_inst, container_widget)
    if CONFIG.AUTOCOOK_ENABLED == false then
        return
    end

    local panel = EnsurePanel(container_widget)
    if panel == nil then
        return
    end

    active_cooker = cooker_inst
    active_recipes = GetRecipesForCooker(cooker_inst)

    panel.on_fill = function(panel_widget, recipe)
        if active_cooker == nil or active_census == nil then
            pending_combo = nil
            pending_combos = nil
            panel_widget:SetPreviewCombos(nil)
            return
        end

        local cooker_name = GetRecipeCookerName(active_cooker)
        local slots = GetIngredientSlotCount(active_cooker)
        -- 详情区下方「已发现配方」：实时库存够、且 recipe.test 终判必出的曾用组合
        local known_live = GetKnownCombos(recipe.prefab, cooker_name, slots, active_census.live)

        local tier = recipe.craftable == true and "craftable"
            or (recipe.autocook_nearby == true and "nearby" or "none")
        -- planner 漏算（如 bananapop 的具名食材被截断）时，曾用组合仍能一键烹饪
        if tier == "none" and #known_live > 0 then
            tier = "craftable"
        end

        -- 无材料配方不取组合：清掉上一条配方残留的预览与投料条目
        if tier == "none" then
            pending_combo = nil
            pending_combos = nil
            panel_widget:SetPreviewCombos(nil)
            return
        end

        -- 可一键烹饪只认实时库存；「附近有材料」用全量 census 只做查看预览（右键取物）
        local census = tier == "craftable" and active_census.live or active_census
        local known_combos = tier == "craftable" and known_live
            or GetKnownCombos(recipe.prefab, cooker_name, slots, census)

        -- 曾用配方排最前，其余按 planner 的组合成本序，按食材多重集去重
        local all_combos, seen_combos = {}, {}
        local function PushCombo(items)
            if items == nil then
                return
            end
            local key = ComboKey(items)
            if not seen_combos[key] then
                seen_combos[key] = true
                table.insert(all_combos, items)
            end
        end
        for _, items in ipairs(known_combos) do PushCombo(items) end
        local planner_combos = Planner.GetFills(recipe.prefab, census)
        if planner_combos ~= nil then
            for _, items in ipairs(planner_combos) do PushCombo(items) end
        end

        local shown, entries_list = {}, {}
        for _, combo_prefabs in ipairs(all_combos) do
            local entries = BuildComboEntries(combo_prefabs, active_census)
            -- craftable 档只保留真能投料的组合；nearby 档保留全部组合供右键取物，
            -- 但对应位置标 false，绝不进 pending_combo。
            if entries ~= nil or tier ~= "craftable" then
                table.insert(shown, combo_prefabs)
                table.insert(entries_list, entries or false)
            end
        end

        if #shown == 0 then
            pending_combo = nil
            pending_combos = nil
            panel_widget:SetPreviewCombos(nil)
            return
        end

        if tier == "craftable" then
            pending_combos = entries_list
            pending_combo = entries_list[1]
        else
            pending_combos = nil
            pending_combo = nil
        end
        panel_widget:SetPreviewCombos(shown, tier == "craftable")

        if pending_combo ~= nil and container_widget ~= nil and container_widget.button ~= nil then
            container_widget.button:Enable()
        end
    end

    panel.on_switch_combo = function(panel_widget, index)
        local entries = pending_combos ~= nil and pending_combos[index] or nil
        pending_combo = (type(entries) == "table") and entries or nil
    end

    panel.on_update = PumpPlanner
    panel.on_retrieve = function(panel_widget, prefab)
        local CM = MOD_EQUIPMENT_CONTROL.CM
        if CM ~= nil and CM.FindAndRetrieve ~= nil then
            CM.FindAndRetrieve(prefab, 1)
        end
    end

    if container_widget ~= nil then
        local cx, cy = container_widget:GetPosition():Get()
        panel:SetPosition(cx - 250, cy)
    end

    active_census = BuildCensus(cooker_inst)
    panel:SetRecipeList(active_recipes)
    StartComputeIfNeeded(cooker_inst, true)
    RefreshPotCandidates(true)
    RefreshMedalFoodList()
    panel:Show()
    panel:StartUpdating()

    -- 挂钩 Cook 按钮
    SetupCookButtonHook(container_widget)
end

-- ===========================================================================
-- 5. 入口 Hook
-- ===========================================================================

AddClassPostConstruct("widgets/containerwidget", function(container_widget)
    local OldOpen = container_widget.Open
    local OldClose = container_widget.Close

    function container_widget:Open(container_inst, ...)
        OldOpen(self, container_inst, ...)

        if IsCooker(container_inst) then
            OpenAutocookPanel(container_inst, self)
        end
    end

    function container_widget:Close(...)
        local closing_container = self.container
        local ret = OldClose(self, ...)

        if closing_container ~= nil and closing_container == active_cooker then
            active_cooker = nil
            active_census = nil
            last_pot_key = nil
            pending_combo = nil
            pending_combos = nil
            if refresh_task ~= nil then
                refresh_task:Cancel()
                refresh_task = nil
            end
            if fast_repeat_task ~= nil then
                fast_repeat_task:Cancel()
                fast_repeat_task = nil
            end
            if active_panel ~= nil and active_panel.inst:IsValid() then
                active_panel:StopUpdating()
                active_panel:SetPreviewCombos(nil)
                active_panel:SetPotCandidates(nil)
                active_panel:Hide()
            end
        end

        return ret
    end
end)
