-- autocookplanner.lua
-- 智能烹饪数据层：按「食材本质」规划可做料理。
--
-- 官方 recipe.test(cooker, names, tags) 只认具名食材计数与 tag 加权和，
-- 所以先探测每条配方的 name read-set，把具名食材单独保留，其余按 tag 签名
-- 折叠成 ingredient KINDS；枚举 kind 多重集，一次扫描得出整锅真正产物。
-- 枚举分帧执行、按库存签名缓存，被上限挤掉的 kind 用 coverage pass 补漏。
--
-- 本文件不碰实体、UI、RPC，只接受 census，输出结果集。

local cooking = require("cooking")
local ItemUtil = require("util/itemutil")

local P = {
    cooker_name = nil,
    slots       = 4,
    sig_kinds   = nil,
    kinds       = nil,
    spare       = nil,
    results     = nil,
}

local MAX_PROBE_ITERATIONS = 120
local DTAG = 0.25
local MAX_KINDS = 32
local MIN_CLASS_KINDS = math.floor(MAX_KINDS / 4)
local RESULT_CACHE_MAX = 3
local CLOCK_EVERY = 64
local MAX_MULTISETS_PER_SLICE = 256
local MAX_PAD_VARIANTS = 6
local MAX_PREFIXES = 12
local FILL_LIMIT = 16

-- 烹饪书里被隐藏但仍会抢产物的配方：不记录成可做，但参与「是否随机」判定
local SKIP_RECIPES = {
    wetgoop = true, wetgoop2 = true, goopydrink = true, spoiled_drink = true,
}
-- cooking.lua 的 prefab->ingredient 别名表是 local，这里镜像官方三条例外
local ALIASES = {
    cookedsmallmeat   = "smallmeat_cooked",
    cookedmonstermeat = "monstermeat_cooked",
    cookedmeat        = "meat_cooked",
}

-- 预设食谱取材档位：数值越小越优先被消耗（把优质食材留着）。
-- 用户指定顺序：树枝/骨片等不可食用 > 冰 > 怪物肉(非榴莲) > 石果/海带/蔬菜度
--              > 大肉小肉 > 浆果/香蕉。
-- 只按官方 cooking.ingredients 的 tag 数值判档，不写死 prefab 名单。
local TIER_BIAS = {
    inedible = -10,
    frozen   = -8,
    monster  = -6,
    veggie   = -3,
    meat     = 2,
    fruit    = 6,
}

local function Alias(prefab)
    return ALIASES[prefab] or prefab
end

local function IngredientTags(prefab)
    local data = cooking.ingredients[Alias(prefab)]
    return data ~= nil and (data.tags or {}) or nil
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    return keys
end

local function ShallowCopy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function TagSignature(tags)
    local parts = {}
    for _, k in ipairs(SortedKeys(tags)) do
        table.insert(parts, k .. "=" .. tostring(tags[k]))
    end
    return table.concat(parts, ",")
end

function P.KeysSignature(t)
    return table.concat(SortedKeys(t), "|")
end

local RealMs = (type(os) == "table" and type(os.clock) == "function")
    and function() return os.clock() * 1000 end
    or function() return GetTimeReal() end

---------------------------------------------------------------------------
-- 配方表：严格按当前锅具取，不混表、不兜底
---------------------------------------------------------------------------

local sorted_cache = {}
local readset_cache = {}
local requirements_cache = {}

function P.GetRecipes(cooker_name)
    return cooking.recipes[cooker_name] or {}
end

function P.CooksRecipe(cooker_name, recipe_name)
    return P.GetRecipes(cooker_name)[recipe_name] ~= nil
end

-- priority 降序 + 名字稳定排序：内层扫描一旦固定获胜优先级即可提前 break
function P.GetSortedRecipes(cooker_name)
    local cached = sorted_cache[cooker_name]
    if cached ~= nil then
        return cached
    end

    local out = {}
    for name, recipe in pairs(P.GetRecipes(cooker_name)) do
        if type(recipe.test) == "function" then
            table.insert(out, {
                name     = name,
                test     = recipe.test,
                priority = recipe.priority or 0,
            })
        end
    end
    table.sort(out, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.name < b.name
    end)

    sorted_cache[cooker_name] = out
    return out
end

-- 代理表记录 test 读过的 name 字段；每次把最后读到的字段 +1 逼闭包走更深分支
local function ProbeReadSet(recipe, cooker_name)
    local names_read = {}
    local tags_read = {}
    local ok_any = false
    local names, tags = {}, {}
    local access_log = {}

    local names_proxy = setmetatable({}, {
        __index = function(_, field)
            if type(field) == "string" then
                names_read[field] = true
                table.insert(access_log, { kind = "name", field = field })
            end
            return names[field]
        end,
    })
    local tags_proxy = setmetatable({}, {
        __index = function(_, field)
            if type(field) == "string" then
                tags_read[field] = true
                table.insert(access_log, { kind = "tag", field = field })
            end
            return tags[field]
        end,
    })

    for _ = 1, MAX_PROBE_ITERATIONS do
        for i = #access_log, 1, -1 do
            access_log[i] = nil
        end
        local ok, result = pcall(recipe.test, cooker_name, names_proxy, tags_proxy)
        if ok and result then
            ok_any = true
            break
        end

        local last = access_log[#access_log]
        if last == nil then
            break
        end

        if not ok and string.find(tostring(result), "arith", 1, true) then
            local fixed = false
            for i = 1, #access_log do
                local a = access_log[i]
                local t = a.kind == "name" and names or tags
                if t[a.field] == nil then
                    t[a.field] = 0
                    fixed = true
                    break
                end
            end
            if not fixed then
                break
            end
        elseif last.kind == "name" then
            names[last.field] = (names[last.field] or 0) + 1
            if names[last.field] > 4 then
                break
            end
        else
            tags[last.field] = (tags[last.field] or 0) + 0.5
            if tags[last.field] > 8 then
                break
            end
        end
    end

    return names_read, ok_any, tags_read
end

-- { per_recipe = {[name] = {读过的名字}}, per_recipe_tags = {读过的 tag}, union = {...} }
function P.GetReadSets(cooker_name)
    local cached = readset_cache[cooker_name]
    if cached ~= nil then
        return cached
    end

    local out = { per_recipe = {}, per_recipe_tags = {}, union = {} }
    for name, recipe in pairs(P.GetRecipes(cooker_name)) do
        local reads, _, tags_read = ProbeReadSet(recipe, cooker_name)
        out.per_recipe[name] = reads
        out.per_recipe_tags[name] = tags_read
        for field in pairs(reads) do
            out.union[field] = true
        end
    end

    readset_cache[cooker_name] = out
    return out
end

-- 1 通过 / 0 不通过 / -1 比较错 / -2 算术错 / -3 其它
local function PTest(test, cooker_name, names, tags)
    local ok, res = pcall(test, cooker_name, names, tags)
    if ok then
        return res and 1 or 0
    end
    res = tostring(res)
    if string.find(res, "compare", 1, true) then
        return -1
    end
    if string.find(res, "arith", 1, true) then
        return -2
    end
    return -3
end

-- 找出一组能让 test 通过的 (names, tags) 赋值
local function FindPassingAssignment(recipe, cooker_name)
    local names, tags = {}, {}
    local access_log = {}

    local names_proxy = setmetatable({}, {
        __index = function(_, field)
            if type(field) == "string" then
                table.insert(access_log, { kind = "name", field = field })
            end
            return names[field]
        end,
    })
    local tags_proxy = setmetatable({}, {
        __index = function(_, field)
            if type(field) == "string" then
                table.insert(access_log, { kind = "tag", field = field })
            end
            return tags[field]
        end,
    })

    for _ = 1, MAX_PROBE_ITERATIONS do
        for i = #access_log, 1, -1 do
            access_log[i] = nil
        end
        local ok, result = pcall(recipe.test, cooker_name, names_proxy, tags_proxy)
        if ok and result then
            return names, tags
        end

        local last = access_log[#access_log]
        if last == nil then
            return nil
        end
        if not ok and string.find(tostring(result), "arith", 1, true) then
            local fixed = false
            for i = 1, #access_log do
                local a = access_log[i]
                local t = a.kind == "name" and names or tags
                if t[a.field] == nil then
                    t[a.field] = 0
                    fixed = true
                    break
                end
            end
            if not fixed then
                return nil
            end
        elseif last.kind == "name" then
            names[last.field] = (names[last.field] or 0) + 1
            if names[last.field] > 4 then
                return nil
            end
        else
            tags[last.field] = (tags[last.field] or 0) + DTAG
            if tags[last.field] > 8 then
                return nil
            end
        end
    end
    return nil
end

-- 把一组通过赋值缩到最小需求
local function Minimize(recipe, cooker_name, names, tags)
    local minnames, mintags = {}, {}
    for name, amount in pairs(names) do
        if amount > 0 then
            minnames[name] = amount
        end
    end
    for tag, amount in pairs(tags) do
        if amount > 0 then
            mintags[tag] = amount
        end
    end

    for name, amount in pairs(minnames) do
        names[name] = nil
        if PTest(recipe.test, cooker_name, names, tags) == 1 then
            minnames[name] = nil
        else
            names[name] = amount - 1
            if PTest(recipe.test, cooker_name, names, tags) ~= 1 then
                names[name] = amount
            else
                names[name] = 1
                while names[name] <= 4 and PTest(recipe.test, cooker_name, names, tags) ~= 1 do
                    names[name] = names[name] + 1
                end
                minnames[name] = names[name]
            end
        end
    end

    for tag, amount in pairs(mintags) do
        tags[tag] = nil
        if PTest(recipe.test, cooker_name, names, tags) == 1 then
            mintags[tag] = nil
        else
            tags[tag] = amount - DTAG
            if PTest(recipe.test, cooker_name, names, tags) ~= 1 then
                tags[tag] = amount
            else
                tags[tag] = DTAG
                while tags[tag] < 8 and PTest(recipe.test, cooker_name, names, tags) ~= 1 do
                    tags[tag] = tags[tag] + DTAG
                end
                mintags[tag] = tags[tag]
            end
        end
    end

    return { minnames = minnames, mintags = mintags }
end

-- { [recipe_name] = { minnames = {名字=个数}, mintags = {tag=总量} } }
function P.GetRequirements(cooker_name)
    local cached = requirements_cache[cooker_name]
    if cached ~= nil then
        return cached
    end

    local out = {}
    for name, recipe in pairs(P.GetRecipes(cooker_name)) do
        local req = { minnames = {}, mintags = {} }
        if type(recipe.test) == "function" then
            local names, tags = FindPassingAssignment(recipe, cooker_name)
            if names ~= nil then
                local ok, mined = pcall(Minimize, recipe, cooker_name, names, tags)
                if ok and mined ~= nil then
                    req = mined
                end
            end
        end
        out[name] = req
    end

    requirements_cache[cooker_name] = out
    return out
end

---------------------------------------------------------------------------
-- kind 构造：具名食材单独成 kind，其余按 tag 签名合并
---------------------------------------------------------------------------

-- 预设食谱取材条例：判定归调用方，统一走 ItemUtil:GetIngredientTagValue
-- 读食材度（可读模组注册的自定义 tag）。用区间而非写死官方数值，
-- 工坊 mod 的非标准值（如 veggie=.75）也能落档。
local STONE_FRUIT_PREFIX = "rock_avocado_fruit_ripe"

local function TierBias(prefab, tags)
    local function get(tag)
        return ItemUtil:GetIngredientTagValue(prefab, tag, tags)
    end
    -- 不可食用（树枝/骨片/噩梦燃料等）最该先消耗
    if get("inedible") > 0 then
        return TIER_BIAS.inedible
    end
    if get("frozen") > 0 then
        return TIER_BIAS.frozen
    end
    -- 榴莲是 fruit+monster 但 meat=0，不能算「怪物肉」
    if get("monster") > 0 and get("meat") > 0 and get("fruit") <= 0 then
        return TIER_BIAS.monster
    end
    local veggie = get("veggie")
    if veggie > 0 then
        -- 同档内再细分：0.5 菜度（海带）> 石果 > 其它 1 菜度蔬菜
        if veggie < 1 then
            return TIER_BIAS.veggie - 0.5
        end
        if string.sub(prefab, 1, #STONE_FRUIT_PREFIX) == STONE_FRUIT_PREFIX then
            return TIER_BIAS.veggie - 0.25
        end
        return TIER_BIAS.veggie
    end
    if get("meat") > 0 then
        return TIER_BIAS.meat
    end
    if get("fruit") > 0 then
        return TIER_BIAS.fruit
    end
    return 0
end

local function PrefabCost(prefab, count, named)
    local tags = IngredientTags(prefab) or {}
    local cost = TierBias(prefab, tags)
    -- 噩梦燃料等虽然带 inedible，但属于珍贵魔法材料，不能当最廉价 filler 消耗
    if tags.magic then
        cost = cost + 4
    elseif tags.decoration then
        cost = cost + 1
    end
    cost = cost - math.min(count or 1, 40) / 40
    if named then
        cost = cost + 2
    end
    return cost
end

local function BuildKinds(counts, readsets)
    local named, classes = {}, {}

    for prefab, count in pairs(counts) do
        local ing_name = Alias(prefab)
        local tags = IngredientTags(prefab)
        if tags ~= nil then
            if readsets.union[ing_name] then
                local kind = named[ing_name]
                if kind == nil then
                    kind = {
                        ing_name = ing_name, key = ing_name, tags = tags,
                        members = {}, avail = 0, named = true,
                    }
                    named[ing_name] = kind
                end
                table.insert(kind.members, prefab)
                kind.avail = kind.avail + count
            else
                local sig = TagSignature(tags)
                local kind = classes[sig]
                if kind == nil then
                    kind = {
                        ing_name = ing_name, key = sig, tags = tags,
                        members = {}, avail = 0, named = false,
                    }
                    classes[sig] = kind
                end
                table.insert(kind.members, prefab)
                kind.avail = kind.avail + count
            end
        end
    end

    local named_list, class_list = {}, {}
    for _, kind in pairs(named) do
        table.insert(named_list, kind)
    end
    for _, kind in pairs(classes) do
        table.insert(class_list, kind)
    end

    local function ByAvail(a, b)
        if a.avail ~= b.avail then
            return a.avail > b.avail
        end
        return a.key < b.key
    end
    table.sort(class_list, ByAvail)
    table.sort(named_list, ByAvail)

    -- 具名食材被 recipe.test 按名字直接读取，折叠或截断都会让整条配方永远算不出：
    -- bananapop 读 names.cave_banana / names.twigs，两者库存低（2 / 11）时按 avail
    -- 排序会被挤进 spare，主枚举再也凑不出「香蕉+冰+树枝+树枝」。
    -- 因此具名 kind 优先保住，class kind 只做保底 + 按库存补位。
    local kinds, reserved = {}, {}
    local named_room = math.min(#named_list, MAX_KINDS - MIN_CLASS_KINDS)
    for i = 1, named_room do
        local kind = named_list[i]
        table.insert(kinds, kind)
        reserved[kind] = true
    end

    -- 常见 tag 载体保底，避免上限把高频填充物挤光
    for i = 1, math.min(#class_list, MIN_CLASS_KINDS) do
        local kind = class_list[i]
        table.insert(kinds, kind)
        reserved[kind] = true
    end

    local rest = {}
    for _, list in ipairs({ named_list, class_list }) do
        for _, kind in ipairs(list) do
            if not reserved[kind] then
                table.insert(rest, kind)
            end
        end
    end
    table.sort(rest, ByAvail)
    local room = math.min(#rest, MAX_KINDS - #kinds)
    for i = 1, room do
        table.insert(kinds, rest[i])
    end

    -- 被上限挤掉的 kind 不参与枚举，但 coverage pass / 槽位菜单仍可用
    local spare = {}
    for i = room + 1, #rest do
        table.insert(spare, rest[i])
    end

    for _, list in ipairs({ kinds, spare }) do
        for _, kind in ipairs(list) do
            table.sort(kind.members, function(a, b)
                local ca = PrefabCost(a, counts[a], kind.named)
                local cb = PrefabCost(b, counts[b], kind.named)
                if ca ~= cb then
                    return ca < cb
                end
                return a < b
            end)
            kind.cost = PrefabCost(kind.members[1], kind.avail, kind.named)
        end
    end

    return kinds, spare
end

---------------------------------------------------------------------------
-- 一次扫描得出整锅产物（复刻官方 GetCandidateRecipes 的优先级语义）
---------------------------------------------------------------------------

local protected_cache = setmetatable({}, { __mode = "k" })
local use_protected = setmetatable({}, { __mode = "k" })

local function ProtectedRecipes(recipes)
    local out = protected_cache[recipes]
    if out ~= nil then
        return out
    end
    out = {}
    for i = 1, #recipes do
        local r = recipes[i]
        out[i] = {
            name     = r.name,
            priority = r.priority,
            test     = function(cooker_name, names, tags)
                local ok, passed = pcall(r.test, cooker_name, names, tags)
                return ok and passed
            end,
        }
    end
    protected_cache[recipes] = out
    return out
end

local function ScanRecipes(recipes, cooker_name, names, tags)
    local best_priority = nil
    local winners = nil
    for i = 1, #recipes do
        local r = recipes[i]
        if best_priority ~= nil and r.priority < best_priority then
            break
        end
        if r.test(cooker_name, names, tags) then
            if winners == nil then
                best_priority = r.priority
                winners = { r.name }
            else
                table.insert(winners, r.name)
            end
        end
    end
    return winners
end

-- 整次扫描只包一次 pcall；只有真有配方抛错才退化为逐配方 pcall
local function EvaluateFill(recipes, cooker_name, names, tags)
    if not use_protected[recipes] then
        local ok, winners = pcall(ScanRecipes, recipes, cooker_name, names, tags)
        if ok then
            return winners
        end
        use_protected[recipes] = true
    end
    return ScanRecipes(ProtectedRecipes(recipes), cooker_name, names, tags)
end

---------------------------------------------------------------------------
-- 结果缓存 / 枚举状态
---------------------------------------------------------------------------

local result_cache = {}
local enum_state = nil
local cover_state = nil
local finalize_state = nil
local enum_key = nil

local function CacheKey(cooker_name, slots, sig_kinds)
    return tostring(cooker_name) .. "\0" .. tostring(slots) .. "\0" .. tostring(sig_kinds)
end

local function CacheGet(key)
    for i, e in ipairs(result_cache) do
        if e.key == key then
            if i > 1 then
                table.remove(result_cache, i)
                table.insert(result_cache, 1, e)
            end
            return e
        end
    end
    return nil
end

local function CachePut(key, data)
    table.insert(result_cache, 1, data)
    while #result_cache > RESULT_CACHE_MAX do
        table.remove(result_cache)
    end
end

local function RecordFill(recipe_name, fill, deterministic)
    local entry = P.results[recipe_name]
    if entry == nil then
        entry = { fills = {}, random_fills = {} }
        P.results[recipe_name] = entry
    end
    local list = deterministic and entry.fills or entry.random_fills
    table.insert(list, fill)
end

local function ByCost(x, y)
    return x.cost < y.cost
end

-- kind_idx 升序，等同类连成一段，可直接按段长判断可行性
local function FillFeasible(kind_idx, avail)
    local prev, run = nil, 0
    for i = 1, #kind_idx do
        local idx = kind_idx[i]
        if idx == prev then
            run = run + 1
        else
            prev, run = idx, 1
        end
        if (avail[idx] or 0) < run then
            return false
        end
    end
    return true
end

local function AddKind(kinds, names, tags, idx)
    local kind = kinds[idx]
    local nm = kind.ing_name
    names[nm] = (names[nm] or 0) + 1
    for tag, v in pairs(kind.tags) do
        tags[tag] = (tags[tag] or 0) + v
    end
end

local function MultOk(kinds, idx, slots)
    local run = 1
    for q = 2, slots do
        if idx[q] == idx[q - 1] then
            run = run + 1
        else
            if run > kinds[idx[q - 1]].avail then
                return false
            end
            run = 1
        end
    end
    return run <= kinds[idx[slots]].avail
end

---------------------------------------------------------------------------
-- coverage pass：上限挤掉的稀缺具名食材，用最小需求定向补一条 fill
---------------------------------------------------------------------------

local function PickedTags(pool, picked)
    local totals = {}
    for _, idx in ipairs(picked) do
        for tag, v in pairs(pool[idx].tags) do
            totals[tag] = (totals[tag] or 0) + v
        end
    end
    return totals
end

-- minnames 只是某一组通过赋值，对 "x or x_cooked" 可能挖到没持有的那一半，
-- 所以用 per_recipe 读集里的每个名字当 anchor 各试 1~3 个副本
local function CoverPrefixes(st, recipe_name, req)
    local out = { {} }

    local forced, ok = {}, true
    for name, need in pairs(req.minnames or {}) do
        local idx = st.by_name[name]
        if idx == nil or st.pool[idx].avail < need then
            ok = false
            break
        end
        for _ = 1, need do
            table.insert(forced, idx)
        end
    end
    if ok and #forced > 0 and #forced <= P.slots then
        table.insert(out, forced)
    end

    local anchors = {}
    for name in pairs(st.readsets.per_recipe[recipe_name] or {}) do
        local idx = st.by_name[name]
        if idx ~= nil then
            table.insert(anchors, idx)
        end
    end
    table.sort(anchors)

    -- 多个具名食材同时被读取的配方（bananapop: cave_banana + twigs），
    -- 单 anchor 的 1~3 副本前缀凑不齐，补一条「每个 anchor 各 1 个」的组合前缀。
    if #anchors > 1 and #anchors <= P.slots and #out < MAX_PREFIXES then
        local combo = {}
        for _, idx in ipairs(anchors) do
            table.insert(combo, idx)
        end
        table.insert(out, combo)
    end

    for _, idx in ipairs(anchors) do
        for k = 1, math.min(3, st.pool[idx].avail) do
            if #out >= MAX_PREFIXES then
                return out
            end
            local pre = {}
            for _ = 1, k do
                table.insert(pre, idx)
            end
            table.insert(out, pre)
        end
    end
    return out
end

-- 种子 + 每个还缺的 tag 挑最便宜载体补齐
local function CoverBase(pool, req, prefix)
    local picked, used = {}, {}

    local function take(idx)
        if #picked >= P.slots or (used[idx] or 0) >= pool[idx].avail then
            return false
        end
        table.insert(picked, idx)
        used[idx] = (used[idx] or 0) + 1
        return true
    end

    for _, idx in ipairs(prefix) do
        if not take(idx) then
            return nil
        end
    end

    for _ = 1, P.slots do
        if #picked >= P.slots then
            break
        end
        local totals = PickedTags(pool, picked)
        local want = nil
        for tag, need in pairs(req.mintags or {}) do
            if (totals[tag] or 0) < need then
                want = tag
                break
            end
        end
        if want == nil then
            break
        end
        local best = nil
        for i, kind in ipairs(pool) do
            if (kind.tags[want] or 0) > 0 and (used[i] or 0) < kind.avail
                and (best == nil or kind.cost < pool[best].cost) then
                best = i
            end
        end
        if best == nil or not take(best) then
            return nil
        end
    end

    return picked, used
end

local function TryCover(st, recipe_name)
    local req = st.requirements[recipe_name]
    if req == nil then
        return nil
    end

    for _, prefix in ipairs(CoverPrefixes(st, recipe_name, req)) do
        local base, used = CoverBase(st.pool, req, prefix)
        if base ~= nil then
            local pads, seen = {}, {}
            for _, idx in ipairs(base) do
                if not seen[idx] then
                    seen[idx] = true
                    table.insert(pads, idx)
                end
            end
            for i = 1, #st.pool do
                if #pads >= MAX_PAD_VARIANTS then
                    break
                end
                if not seen[i] then
                    seen[i] = true
                    table.insert(pads, i)
                end
            end

            for _, pad in ipairs(pads) do
                local picked = ShallowCopy(base)
                local spent = ShallowCopy(used)
                while #picked < P.slots and (spent[pad] or 0) < st.pool[pad].avail do
                    table.insert(picked, pad)
                    spent[pad] = (spent[pad] or 0) + 1
                end
                if #picked == P.slots then
                    local names, tags = {}, {}
                    for _, idx in ipairs(picked) do
                        AddKind(st.pool, names, tags, idx)
                    end
                    local winners = EvaluateFill(st.recipes, P.cooker_name, names, tags)
                    if winners ~= nil then
                        for _, w in ipairs(winners) do
                            if w == recipe_name then
                                return picked, #winners == 1
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function BeginCover()
    local recipes = P.GetSortedRecipes(P.cooker_name)
    local queue = {}
    for _, r in ipairs(recipes) do
        if P.results[r.name] == nil and not SKIP_RECIPES[r.name] then
            table.insert(queue, r.name)
        end
    end
    if #queue == 0 then
        return nil
    end

    local pool = {}
    for _, kind in ipairs(P.kinds) do
        table.insert(pool, kind)
    end
    for _, kind in ipairs(P.spare or {}) do
        table.insert(pool, kind)
    end
    local by_name = {}
    for i, kind in ipairs(pool) do
        if kind.named and by_name[kind.ing_name] == nil then
            by_name[kind.ing_name] = i
        end
    end
    local index = {}
    for i, kind in ipairs(P.kinds) do
        index[kind] = i
    end

    return {
        queue = queue, i = 1, found = 0,
        pool = pool, by_name = by_name, index = index,
        recipes = recipes,
        requirements = P.GetRequirements(P.cooker_name),
        readsets = P.GetReadSets(P.cooker_name),
    }
end

local function EnterFinalize()
    local queue = {}
    for _, entry in pairs(P.results) do
        table.insert(queue, entry)
    end
    finalize_state = { queue = queue, i = 1 }
end

local function StepFinalize(budget_ms)
    local st = finalize_state
    if st == nil then
        return true
    end
    local deadline = RealMs() + (budget_ms or 3)
    while st.i <= #st.queue do
        local entry = st.queue[st.i]
        st.i = st.i + 1
        table.sort(entry.fills, ByCost)
        table.sort(entry.random_fills, ByCost)
        if RealMs() >= deadline then
            return false
        end
    end
    finalize_state = nil
    -- 排序没做完绝不写缓存，避免复用半排序结果
    if enum_key ~= nil then
        CachePut(enum_key, {
            key         = enum_key,
            cooker_name = P.cooker_name,
            slots       = P.slots,
            kinds       = P.kinds,
            spare       = P.spare,
            results     = P.results,
        })
        enum_key = nil
    end
    return true
end

local function StepCover(budget_ms)
    local st = cover_state
    local deadline = RealMs() + (budget_ms or 3)
    while st.i <= #st.queue do
        local recipe_name = st.queue[st.i]
        st.i = st.i + 1
        local picked, deterministic = TryCover(st, recipe_name)
        if picked ~= nil then
            local kind_idx = {}
            for _, pidx in ipairs(picked) do
                local kind = st.pool[pidx]
                local at = st.index[kind]
                if at == nil then
                    table.insert(P.kinds, kind)
                    at = #P.kinds
                    st.index[kind] = at
                end
                table.insert(kind_idx, at)
            end
            table.sort(kind_idx)
            local cost = 0
            for _, at in ipairs(kind_idx) do
                cost = cost + P.kinds[at].cost
            end
            RecordFill(recipe_name, { kind_idx = kind_idx, cost = cost }, deterministic)
            st.found = st.found + 1
        end
        if RealMs() >= deadline then
            return false
        end
    end

    -- 被收编的 kind 已从 spare 移除，避免槽位菜单里出现两次
    local enumerated = {}
    for _, kind in ipairs(P.kinds) do
        enumerated[kind] = true
    end
    local rest = {}
    for _, kind in ipairs(P.spare or {}) do
        if not enumerated[kind] then
            table.insert(rest, kind)
        end
    end
    P.spare = rest

    cover_state = nil
    EnterFinalize()
    return false
end

---------------------------------------------------------------------------
-- 对外：启动计算 / 分帧推进
---------------------------------------------------------------------------

function P.StartCompute(cooker_name, slots, census)
    local key = CacheKey(cooker_name, slots, census.sig_kinds)
    local hit = CacheGet(key)
    P.cooker_name = cooker_name
    P.slots = slots
    P.sig_kinds = census.sig_kinds

    if hit ~= nil then
        P.kinds = hit.kinds
        P.spare = hit.spare or {}
        P.results = hit.results
        enum_state, cover_state, finalize_state, enum_key = nil, nil, nil, nil
        return
    end

    local readsets = P.GetReadSets(cooker_name)
    P.kinds, P.spare = BuildKinds(census.counts, readsets)
    P.results = {}
    enum_key = key

    local idx = {}
    for q = 1, slots do
        idx[q] = 1
    end
    idx[slots] = 0
    enum_state = { idx = idx, n = #P.kinds, total_done = 0 }
    cover_state = nil
    finalize_state = nil
    if #P.kinds == 0 then
        enum_state = nil
    end
end

function P.IsComputing()
    return enum_state ~= nil or cover_state ~= nil or finalize_state ~= nil
end

-- 枚举 → 补漏 → 排序，全部按帧预算推进；返回 true 表示本轮彻底算完
function P.Step(budget_ms)
    if enum_state == nil then
        if cover_state ~= nil then
            return StepCover(budget_ms)
        end
        return StepFinalize(budget_ms)
    end

    local st = enum_state
    local kinds = P.kinds
    local idx = st.idx
    local slots = #idx
    local recipes = P.GetSortedRecipes(P.cooker_name)
    local names, tags = {}, {}
    local deadline = RealMs() + (budget_ms or 3)
    -- 配方越多单次 EvaluateFill 越贵，越频繁读时钟，避免单帧超预算
    local clock_every = math.max(1, math.min(CLOCK_EVERY, math.floor(2048 / (#recipes + 1))))
    local until_clock = clock_every
    local sliced = 0
    st.slices = (st.slices or 0) + 1

    while true do
        until_clock = until_clock - 1
        if until_clock <= 0 then
            until_clock = clock_every
            if RealMs() >= deadline then
                return false
            end
        end

        local p = slots
        idx[p] = idx[p] + 1
        while idx[p] > st.n do
            p = p - 1
            if p == 0 then
                enum_state = nil
                cover_state = BeginCover()
                if cover_state == nil then
                    EnterFinalize()
                end
                return false
            end
            idx[p] = idx[p] + 1
        end
        for q = p + 1, slots do
            idx[q] = idx[p]
        end

        if MultOk(kinds, idx, slots) then
            for k in pairs(names) do
                names[k] = nil
            end
            for k in pairs(tags) do
                tags[k] = nil
            end
            for q = 1, slots do
                AddKind(kinds, names, tags, idx[q])
            end

            local winners = EvaluateFill(recipes, P.cooker_name, names, tags)
            if winners ~= nil then
                local deterministic = #winners == 1
                local keep = false
                for i = 1, #winners do
                    if not SKIP_RECIPES[winners[i]] then
                        keep = true
                        break
                    end
                end
                if keep then
                    local kind_idx, cost = {}, 0
                    for q = 1, slots do
                        kind_idx[q] = idx[q]
                        cost = cost + kinds[idx[q]].cost
                    end
                    local fill = { kind_idx = kind_idx, cost = cost }
                    for i = 1, #winners do
                        local recipe_name = winners[i]
                        if not SKIP_RECIPES[recipe_name] then
                            RecordFill(recipe_name, fill, deterministic)
                        end
                    end
                end
            end
            st.total_done = st.total_done + 1
            sliced = sliced + 1
            if sliced >= MAX_MULTISETS_PER_SLICE then
                return false
            end
        end
    end
end

---------------------------------------------------------------------------
-- 对外：按最新 census 出「必出可做」与具体投料组合
---------------------------------------------------------------------------

local function KindAvail(census, exact_only)
    local avail = {}
    for i, kind in ipairs(P.kinds or {}) do
        local total = 0
        for _, prefab in ipairs(kind.members) do
            if not (exact_only and census.approx[prefab]) then
                total = total + (census.counts[prefab] or 0)
            end
        end
        avail[i] = total
    end
    return avail
end

local function AllocateFill(fill, prefab_avail)
    local chosen = {}
    for _, idx in ipairs(fill.kind_idx) do
        local kind = P.kinds[idx]
        if kind == nil then
            return nil
        end
        local picked = nil
        for _, prefab in ipairs(kind.members) do
            if (prefab_avail[prefab] or 0) > 0 then
                picked = prefab
                break
            end
        end
        if picked == nil then
            return nil
        end
        prefab_avail[picked] = prefab_avail[picked] - 1
        table.insert(chosen, picked)
    end
    return chosen
end

local function FeasibleFills(entry, avail)
    local out = {}
    for _, fill in ipairs(entry.fills) do
        if FillFeasible(fill.kind_idx, avail) then
            table.insert(out, fill)
        end
    end
    return out
end

-- 一键制作只认必出：当前锅具能做 + 存在 deterministic fill + 库存够。
-- 顺带在 recipe 上写 approx 标记，供面板提示「依赖估算库存」。
function P.GetCraftableMap(recipe_list, census)
    local map = {}
    if P.results == nil or P.kinds == nil then
        return map
    end

    local base_avail = KindAvail(census, false)
    local exact_avail = KindAvail(census, true)

    for _, recipe in ipairs(recipe_list) do
        recipe.autocook_approx = false
        local entry = P.results[recipe.prefab]
        if entry ~= nil and #entry.fills > 0
            and P.CooksRecipe(P.cooker_name, recipe.prefab) then
            local feasible = FeasibleFills(entry, ShallowCopy(base_avail))
            if #feasible > 0 then
                map[recipe.prefab] = true

                local spent = {}
                for _, idx in ipairs(feasible[1].kind_idx) do
                    spent[idx] = (spent[idx] or 0) + 1
                end
                for idx, used in pairs(spent) do
                    if used > (exact_avail[idx] or 0) then
                        recipe.autocook_approx = true
                        break
                    end
                end
            end
        end
    end
    return map
end

-- 只返回必出组合（最多 FILL_LIMIT 条），物化成真实 prefab 列表。
function P.GetFills(recipe_name, census)
    if P.results == nil or P.kinds == nil then
        return nil
    end
    -- 与 GetCraftableMap 同口径：当前锅具不做这道菜时不能取组合
    if not P.CooksRecipe(P.cooker_name, recipe_name) then
        return nil
    end
    local entry = P.results[recipe_name]
    if entry == nil or #entry.fills == 0 then
        return nil
    end

    local avail = KindAvail(census, false)
    local combos, seen = {}, {}
    for _, fill in ipairs(FeasibleFills(entry, avail)) do
        local prefabs = AllocateFill(fill, ShallowCopy(census.counts))
        if prefabs ~= nil then
            local sorted = ShallowCopy(prefabs)
            table.sort(sorted)
            local key = table.concat(sorted, ",")
            if not seen[key] then
                seen[key] = true
                table.insert(combos, prefabs)
                if #combos >= FILL_LIMIT then
                    break
                end
            end
        end
    end
    return #combos > 0 and combos or nil
end

-- 通道 2：手动往锅里填食材后，反向算出「这一锅会做出什么」。
-- 与正向枚举共用同一套 priority 语义（ScanRecipes 提前 break），
-- 因此「必出 / 随机」的判定与一键制作完全一致。
function P.GetPotCandidates(cooker_name, prefabs)
    if prefabs == nil or #prefabs == 0 then
        return nil
    end

    -- prefabs 是整锅所有食材槽（含未在 cooking.ingredients 注册的物品），
    -- 与官方 GetIngredientValues 一致：names 全计、tags 只累加已注册食材。
    local names, tags = {}, {}
    for _, prefab in ipairs(prefabs) do
        local ing_name = ItemUtil:AliasIngredient(prefab)
        names[ing_name] = (names[ing_name] or 0) + 1
        local t = ItemUtil:GetIngredientTags(prefab)
        if t ~= nil then
            for tag, v in pairs(t) do
                tags[tag] = (tags[tag] or 0) + v
            end
        end
    end

    local winners = EvaluateFill(P.GetSortedRecipes(cooker_name), cooker_name, names, tags)
    if winners == nil then
        return nil
    end
    return { names = winners, deterministic = #winners == 1 }
end

---------------------------------------------------------------------------
-- 通道 2（未填满）：参考 Craft Pot(727774324) 的 KnownFoods/FoodCrafting。
-- 锅没填满时不猜补齐组合，只用 recipe.test 判断已填食材是否已经违反配方
-- 的上限（reqsmismatch）；没违反的全部列为「补齐后可能」。锅填满时才按
-- 官方最高优先级收敛到真正会出的产物（readytocook）。
---------------------------------------------------------------------------

local possible_cache = {}
local base_cache = {}

local function AddIngValue(prefab, names, tags)
    local ing = Alias(prefab)
    names[ing] = (names[ing] or 0) + 1
    local t = IngredientTags(prefab)
    if t ~= nil then
        for tag, v in pairs(t) do
            tags[tag] = (tags[tag] or 0) + v
        end
    end
end

-- 外部候选组合（「已发现配方」）的终判：与正向枚举共用同一套 priority 语义，
-- 只有目标料理是唯一胜者才算「必出」，随机候选不算。
function P.TestCombo(cooker_name, recipe_name, prefabs)
    if prefabs == nil or #prefabs == 0
        or not P.CooksRecipe(cooker_name, recipe_name) then
        return false
    end
    local names, tags = {}, {}
    for _, prefab in ipairs(prefabs) do
        AddIngValue(prefab, names, tags)
    end
    local winners = EvaluateFill(P.GetSortedRecipes(cooker_name), cooker_name, names, tags)
    if winners == nil or #winners ~= 1 then
        return false
    end
    return winners[1] == recipe_name
end

-- 该配方的「最小通过赋值」：读集字段全补 0，再叠上反推出来的最低需求。
-- 还原不出一组通过赋值时返回 nil，调用方保守放行（宁可多列也不漏列）。
local function BaseAssignment(recipe_name, test, cooker_name, req, readsets)
    local cached = base_cache[cooker_name]
    if cached == nil then
        cached = {}
        base_cache[cooker_name] = cached
    end
    local hit = cached[recipe_name]
    if hit == false then
        return nil
    end
    if hit ~= nil then
        return hit.names, hit.tags
    end

    local names, tags = {}, {}
    for n in pairs(readsets.per_recipe[recipe_name] or {}) do names[n] = 0 end
    for t in pairs(readsets.per_recipe_tags[recipe_name] or {}) do tags[t] = 0 end
    for n, v in pairs(req.minnames or {}) do names[n] = v end
    for t, v in pairs(req.mintags or {}) do tags[t] = v end

    if PTest(test, cooker_name, names, tags) ~= 1 then
        cached[recipe_name] = false
        return nil
    end
    cached[recipe_name] = { names = names, tags = tags }
    return names, tags
end

-- Craft Pot 的 _TestMax：把已填食材的每个 names/tags 值单独顶到基准赋值上，
-- 只要有一个字段让 test 不再可能通过，这个配方就已经做不出来了。
local function ReqMismatch(test, cooker_name, base_names, base_tags, names, tags)
    for n, amt in pairs(names) do
        local cur = base_names[n]
        if cur ~= nil and amt > cur then
            local probe = ShallowCopy(base_names)
            probe[n] = amt
            if PTest(test, cooker_name, probe, base_tags) ~= 1 then
                return true
            end
        end
    end
    for t, amt in pairs(tags) do
        local cur = base_tags[t]
        if cur ~= nil and amt > cur then
            local probe = ShallowCopy(base_tags)
            probe[t] = amt
            if PTest(test, cooker_name, base_names, probe) ~= 1 then
                return true
            end
        end
    end
    return false
end

function P.GetPotPossibleRecipes(cooker_name, prefabs, slots)
    if prefabs == nil or #prefabs == 0 then
        return nil
    end

    -- 已经填满：按官方优先级精确判定这一锅会出什么
    if #prefabs >= slots then
        return P.GetPotCandidates(cooker_name, prefabs)
    end

    local key = cooker_name .. "\0" .. tostring(slots) .. "\0"
        .. table.concat(prefabs, "|")
    local cached = possible_cache[key]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local names, tags = {}, {}
    for _, p in ipairs(prefabs) do AddIngValue(p, names, tags) end
    local reqs = P.GetRequirements(cooker_name)
    local readsets = P.GetReadSets(cooker_name)

    local winners = {}
    for _, r in ipairs(P.GetSortedRecipes(cooker_name)) do
        if not SKIP_RECIPES[r.name] then
            local base_names, base_tags = BaseAssignment(
                r.name, r.test, cooker_name, reqs[r.name] or {}, readsets)
            if base_names == nil
                or not ReqMismatch(r.test, cooker_name, base_names, base_tags, names, tags) then
                table.insert(winners, r.name)
            end
        end
    end

    local result = nil
    if #winners > 0 then
        result = { names = winners, deterministic = false, partial = true }
    end

    possible_cache[key] = result or false
    local n = 0
    for _ in pairs(possible_cache) do n = n + 1 end
    if n > 8 then
        possible_cache = {}
    end
    return result
end

return P
