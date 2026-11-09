-- 导入依赖模块
local ItemUtil = require "util/itemutil"  -- 物品功能工具类
local PopupNumber = require "widgets/popupnumber"
local InventoryUtil = require "util/inventoryutil"  -- 库存功能工具类

-- 真实数据源 service（Show Me / Insight）；攻击检测时取真实血量，无则回退本地预测
local ShowMeUtil = require("util/showmeutil")
local InsightUtil = require("util/insightutil")
ShowMeUtil.Init()  -- 确保 network listener 已注册（frontend 阶段会被跳过）
-- 配置：HUD 实时开关（CONFIG）；总开关控制是否显示血条、子开关控制本地预测兜底
local CONFIG = (MOD_EQUIPMENT_CONTROL ~= nil and MOD_EQUIPMENT_CONTROL.CONFIG) or {}

-- 统一的跳字函数（colour 可选，默认纯红）
local function ShowStatPopup(value, pos, colour)
    local popup = ThePlayer.HUD.popupstats_root:AddChild(PopupNumber(
        ThePlayer,
        value,
        48,                              -- 放大字号
        pos,
        40,                              -- lifetime
        colour or {1, 0.1, 0.1, 1},      -- 默认纯红，传入 nil 时走默认
        false
    ))  -- 使用 PopupNumber 默认 NEWFONT_OUTLINE，字号 48 已经够大够粗
end

-- 创建弱引用表用于存储生物的生命值追踪数据
local HealthTracker = setmetatable({}, {__mode = "k"})

-- 获取克劳斯(Klaus)的生命值（特殊处理）
local function GetKlausHealth(target)
    local radius = target:GetPhysicsRadius(0)

    -- 根据物理半径判断克劳斯状态
    if string.format("%.1f", radius) == "1.7" then
        return TUNING.KLAUS_HEALTH * (TUNING.KLAUS_ENRAGE_SCALE * TUNING.KLAUS_ENRAGE_SCALE * TUNING.KLAUS_ENRAGE_SCALE)
    end

    -- 根据是否解除锁链返回不同生命值
    return target._unchained:value() and 5000 or 10000
end

-- 暗影棋子缩放配置（根据物理半径判断等级）
local ChessPieceScaling =
{
    shadow_rook   = {"1.6", "1.9", "2.6"},   -- 暗影战车
    shadow_knight = {"0.3", "0.4", "0.6"},   -- 暗影骑士
    shadow_bishop = {"0.3", "0.5", "0.7"},   -- 暗影主教
}

-- 获取暗影棋子的生命值
local function GetShadowPiecesHealth(target)
    local radius = string.format("%.1f", target:GetPhysicsRadius(0))

    -- 根据物理半径匹配对应的生命值等级
    for i = 1, #ChessPieceScaling[target.prefab] do
        if radius == ChessPieceScaling[target.prefab][i] then
            return TUNING[target.prefab:upper()].HEALTH[i]
        end
    end

    return 0
end

-- 蜘蛛巢穴动画配置（不同等级的动画映射）
local SpiderdenAnims =
{
    [1] =  -- 一级蜘蛛巢
    {
        hit = "cocoon_small_hit",
        idle = "cocoon_small",
        init = "grow_sac_to_small",
        freeze = "frozen_small",
        thaw = "frozen_loop_pst_small",
    },
    [2] =  -- 二级蜘蛛巢
    {
        hit = "cocoon_medium_hit",
        idle = "cocoon_medium",
        init = "grow_small_to_medium",
        freeze = "frozen_medium",
        thaw = "frozen_loop_pst_medium",
    },
    [3] =  -- 三级蜘蛛巢
    {
        hit = "cocoon_large_hit",
        idle = "cocoon_large",
        init = "grow_medium_to_large",
        freeze = "frozen_large",
        thaw = "frozen_loop_pst_large",
    },
}

-- 获取蜘蛛巢穴的等级（通过当前动画判断）
local function GetSpiderdenLevel(target)
    for size, anims in pairs (SpiderdenAnims) do
        for _, anim in pairs(anims) do
            if target.AnimState:IsCurrentAnimation(anim) then
                return size
            end
        end
    end

    return 1  -- 默认一级
end

-- 获取蜘蛛巢穴的生命值
local function GetSpiderdenHealth(target)
    return TUNING.SPIDERDEN_HEALTH[GetSpiderdenLevel(target)]
end

-- 获取石虾(Rocky)的生命值（根据缩放比例计算）
local function GetRockyHealth(target)
    return math.floor(TUNING.ROCKY_HEALTH * target.Transform:GetScale())
end

-- 特殊生物生命值计算函数映射表
local FuncHealth =
{
    klaus = GetKlausHealth,           -- 克劳斯
    shadow_rook = GetShadowPiecesHealth,   -- 暗影战车
    shadow_knight = GetShadowPiecesHealth, -- 暗影骑士
    shadow_bishop = GetShadowPiecesHealth, -- 暗影主教
    spiderden = GetSpiderdenHealth,   -- 蜘蛛巢穴
    rocky = GetRockyHealth,           -- 石虾
}

-- 标签到生命值的映射表
local TagToHealth =
{
    werepig   = TUNING.WEREPIG_HEALTH,   -- 猪人
    bird      = TUNING.BIRD_HEALTH,      -- 鸟
    warg      = TUNING.WARG_HEALTH,      -- 座狼
    leif      = TUNING.LEIF_HEALTH,      -- 树精守卫
    rook      = TUNING.ROOK_HEALTH,      -- 战车
    knight    = TUNING.KNIGHT_HEALTH,    -- 骑士
    bishop    = TUNING.BISHOP_HEALTH,    -- 主教
    hound     = TUNING.HOUND_HEALTH,     -- 猎犬
    koalefant = TUNING.KOALEFANT_HEALTH, -- 考拉象
}

-- 静态生命值配置表（直接指定数值）
local StaticHealth =
{
    -- 常量值
    beehive         = 200,  -- 蜂巢
    wasphive        = 250,  -- 黄蜂巢
    slurtlehole     = 350,  -- 蜗牛窝
    houndmound      = 300,  -- 猎犬丘
    mandrake_active = 20,   -- 曼德拉草（活跃）
    birchnutdrake   = 50,   -- 桦树果龙
    lureplant       = 300,  -- 食人花

    -- 调谐配置值
    mermking               = TUNING.MERM_KING_HEALTH,        -- 鱼人王
    mermguard              = TUNING.MERM_GUARD_HEALTH,       -- 鱼人守卫
    lightninggoat          = TUNING.LIGHTNING_GOAT_HEALTH,   -- 闪电羊
    nightmarebeak          = TUNING.TERRORBEAK_HEALTH,       -- 噩梦鸟嘴
    crawlingnightmare      = TUNING.CRAWLINGHORROR_HEALTH,   -- 爬行噩梦
    killerbee              = TUNING.BEE_HEALTH,              -- 杀人蜂
    pigman                 = TUNING.PIG_HEALTH,              -- 猪人
    catcoon                = TUNING.CATCOON_LIFE,            -- 猫熊
    grassgekko             = TUNING.GRASSGEKKO_LIFE,         -- 草壁虎
    spider_dropper         = TUNING.SPIDER_WARRIOR_HEALTH,   -- 蜘蛛战士
    wobster_sheller_land   = TUNING.WOBSTER.HEALTH,          -- 龙虾（陆地）
    wobster_moonglass_land = TUNING.WOBSTER.HEALTH,          -- 月玻璃龙虾（陆地）
    deer_red               = TUNING.DEER_GEMMED_HEALTH,      -- 红宝石鹿
    deer_blue              = TUNING.DEER_GEMMED_HEALTH,      -- 蓝宝石鹿
}

-- 不兼容生物列表（这些生物不支持生命值条显示）
local InCompatible =
{
    butterfly = true,  -- 蝴蝶
    crabking = true,   -- 蟹王
}

-- 根据标签获取生命值
local function GetTagHealth(inst)
    for tag, health in pairs(TagToHealth) do
        if inst:HasTag(tag) then
            return health
        end
    end

    return nil
end

-- 获取生物的最大生命值（优先级：特殊函数 > 标签 > 静态配置 > 调谐配置 > replica > 默认0）
local function GetMaxHealth(inst)
    local result = FuncHealth[inst.prefab] and FuncHealth[inst.prefab](inst)
        or GetTagHealth(inst)
        or StaticHealth[inst.prefab]
    if result then
        return result
    end

    local tuneKey = inst.prefab:upper() .. "_HEALTH"
    if type(TUNING[tuneKey]) == "number" then
        return TUNING[tuneKey]
    end

    return (inst.replica and inst.replica.health and inst.replica.health:Max()) or 0
end

-- 计算毒菌蟾蜍的链接等级
local function CalculateLevel(links)
    return (links < 1 and 0)
        or (links < 5 and 1)
        or (links < 8 and 2)
        or 3
end

-- 毒菌蟾蜍吸收值缓存（避免每帧攻击时重复 FindEntities）
local ToadstoolAbsorbCache = {}

-- 获取毒菌蟾蜍的伤害吸收值（根据周围蘑菇芽数量，0.5 秒缓存）
local function GetToadstoolAbsorb(target)
    local now = GetTime()
    local cache = ToadstoolAbsorbCache[target]
    if cache and now - cache.time < 0.5 then
        return cache.value
    end

    local x, y, z = target.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, 30, {"mushroomsprout"})
    local level = CalculateLevel(#ents)
    local value = target.prefab == "toadstool" and TUNING.TOADSTOOL_ABSORPTION_LVL[level]
        or TUNING.TOADSTOOL_DARK_ABSORPTION_LVL[level]

    ToadstoolAbsorbCache[target] = { time = now, value = value }
    return value
end

-- 获取玩家伤害吸收值（PVP模式）
local function GetPlayerAbsorb(target)
    return TUNING.PVP_DAMAGE_MOD
end

-- 伤害吸收配置表
local DamageAbsorption =
{
    anims =  -- 吸收伤害的动画状态
    {
        "hide",        -- 隐藏
        "hide_loop",   -- 隐藏循环
    },
    prefabs =  -- 特定生物的吸收配置
    {
        spider_hider = TUNING.SPIDER_HIDER_SHELL_ABSORB,  -- 隐藏蜘蛛
        slurtle = TUNING.SLURTLE_SHELL_ABSORB,            -- 蜗牛
        snurtle = TUNING.SLURTLE_SHELL_ABSORB,            -- 蜗牛壳
        rocky = TUNING.ROCKY_ABSORB,                      -- 石虾
        toadstool = GetToadstoolAbsorb,                   -- 毒菌蟾蜍
        toadstool_dark = GetToadstoolAbsorb,              -- 暗影毒菌蟾蜍
    },
    tags =  -- 标签对应的吸收配置
    {
        player = GetPlayerAbsorb,  -- 玩家
    }
}

-- 获取生物的基础吸收值
local function GetAbsorbtion(target)
    for tag, absorb in pairs(DamageAbsorption.tags) do
        if target:HasTag(tag) then
            return absorb
        end
    end

    return DamageAbsorption.prefabs[target.prefab]
end

-- 获取伤害吸收系数（0-1之间）
local function GetDamageAbsorption(target)
    local absorb = 1  -- 默认无吸收

    local absorbtion = GetAbsorbtion(target)
    if absorbtion then
        if type(absorbtion) == "function" then
            -- 函数类型吸收值（如毒菌蟾蜍）
            absorb = math.clamp(1 - absorbtion(target), 0, 1)
        else
            -- 数值类型吸收值（检查是否处于吸收动画状态）
            for _, anim in pairs(DamageAbsorption.anims) do
                if target.AnimState:IsCurrentAnimation(anim) then
                    absorb = math.clamp(1 - absorbtion, 0, 1)
                    break
                end
            end
        end
    end

    return absorb
end

-- 获取玩家伤害倍率（角色特殊能力）
local function GetDamageMultiplier(player)
    -- Wolfgang: 通过 mightiness 的 externaldamagemultipliers 实现（参考 mightiness.lua）
    if player.prefab == "wolfgang" then
        local WolfBuild = player.AnimState and player.AnimState:GetBuild() or ""
        if string.find(WolfBuild, "mighty") then
            return TUNING.WOLFGANG_ATTACKMULT_MIGHTY_MAX
        elseif string.find(WolfBuild, "skinny") then
            return TUNING.WOLFGANG_ATTACKMULT_WIMPY_MAX
        end
        return TUNING.WOLFGANG_ATTACKMULT_NORMAL
    end

    -- Wanda: 通过年龄状态的 damagemultiplier 实现（参考 wanda.lua）
    if player.prefab == "wanda" then
        local WandaBuild = player.AnimState and player.AnimState:GetBuild() or ""
        local weapon = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
        local isShadow = weapon and weapon:HasTag("shadow_item")

        if string.find(WandaBuild, "old") then
            return isShadow and TUNING.WANDA_SHADOW_DAMAGE_OLD or TUNING.WANDA_REGULAR_DAMAGE_OLD
        elseif string.find(WandaBuild, "young") then
            return isShadow and TUNING.WANDA_SHADOW_DAMAGE_YOUNG or TUNING.WANDA_REGULAR_DAMAGE_YOUNG
        end
        return isShadow and TUNING.WANDA_SHADOW_DAMAGE_NORMAL or TUNING.WANDA_REGULAR_DAMAGE_NORMAL
    end

    -- 其他角色：通过 combat.damagemultiplier 实现，直接查 TUNING 表
    -- 覆盖 Wendy(0.75)、Wes(0.75)、Wigfrid(1.25) 等所有角色
    return TUNING[player.prefab:upper() .. "_DAMAGE_MULT"] or 1
end

-- 检查海狸是否对目标有额外伤害加成
local function BeaverBonusDamage(target)
    return target:HasTag("tree")  -- 树木
        or target:HasTag("beaverchewable")  -- 可啃咬物品
end

-- 获取徒手伤害值
local function GetUnArmedDamage(target)
    -- 变形状态处理
    if ThePlayer:HasTag("werehuman") then
        if ThePlayer:HasTag("beaver") then
            -- 海狸状态：基础伤害 + 树木额外伤害
            return TUNING.BEAVER_DAMAGE + (BeaverBonusDamage(target) and TUNING.BEAVER_WOOD_DAMAGE or 0)
        elseif ThePlayer:HasTag("weremoose") then
            -- 麋鹿状态：固定麋鹿伤害
            return TUNING.WEREMOOSE_DAMAGE
        end
    end

    -- 默认徒手伤害
    return TUNING.UNARMED_DAMAGE
end

-- 最近伤害记录（用于动画状态缓存）
local MostRecentDamage = 0

-- 获取武器伤害值
local function GetWeaponDamage(target)
    -- 如果玩家正在执行"item_in"动画，返回最近记录的伤害值
    if ThePlayer.AnimState:IsCurrentAnimation("item_in") then
        return MostRecentDamage
    end

    -- 获取玩家手中装备的武器
    local weapon = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)

    -- 如果没有装备武器，返回徒手伤害
    if not weapon then
        return GetUnArmedDamage(target)
    end

    -- 通过ItemUtil工具类获取武器对目标的伤害值
    MostRecentDamage = ItemUtil:GetDamage(weapon, target)

    return MostRecentDamage
end

-- 获取武器的位面伤害值
local function GetPlanarDamage()
    local weapon = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
    if weapon then
        local cached = ItemUtil:GetCachedItem(weapon)
        if cached and cached.planar_damage then
            return cached.planar_damage
        end
    end
    return 0
end

-- 获取当前激活的套装名称（需头+身装备同一套装且套装已激活）
local function GetActiveSetBonus()
    local head = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HEAD)
    local body = InventoryUtil:GetEquippedItem(EQUIPSLOTS.BODY)
    if head and body then
        local headCached = ItemUtil:GetCachedItem(head)
        local bodyCached = ItemUtil:GetCachedItem(body)
        if headCached and bodyCached
            and headCached.setbonus
            and bodyCached.setbonus
            and headCached.setbonus.setname == bodyCached.setbonus.setname then
            return headCached.setbonus.setname
        end
    end
    return nil
end

-- 获取套装增伤倍率
local function GetSetBonusDamageMult(setBonus)
    if setBonus == "lunarplant" then
        return TUNING.WEAPONS_LUNARPLANT_SETBONUS_DAMAGE_MULT
    elseif setBonus == "voidcloth" then
        return TUNING.WEAPONS_VOIDCLOTH_SETBONUS_DAMAGE_MULT
    end
    return 1
end

-- 获取套装位面增伤
local function GetSetBonusPlanarDamage(setBonus)
    if setBonus == "lunarplant" then
        return TUNING.WEAPONS_LUNARPLANT_SETBONUS_PLANAR_DAMAGE
    elseif setBonus == "voidcloth" then
        return TUNING.WEAPONS_VOIDCLOTH_SETBONUS_PLANAR_DAMAGE
    end
    return 0
end

-- 骑乘牛伤害数据
local BeefDamage = {
    ["2036185713"] = 50,  -- 战牛
    ["3151475706"] = 25,  -- 行牛
    ["139624129"]  = 20,  -- 肥牛
}

-- 位面实体列表（应用位面伤害公式）
local PlanarEList = {
    ["lunarthrall_plant"] = true,
    ["lunarthrall_plant_vine"] = true,
    ["lunarthrall_plant_vine_end"] = true,
    ["lunar_grazer"] = true,
    ["fused_shadeling"] = true,
    ["ruin_shadeling"] = true,
    ["shadowthrall_hands"] = true,
    ["shadowthrall_horns"] = true,
    ["shadowthrall_wings"] = true,
    ["mutatedbearger"] = true,
    ["mutateddeerclops"] = true,
    ["mutatedwarg"] = true,
    ["lunarfrog"] = true,
}

-- 位面实体伤害公式：√(4d+64)-8)×4
local function ApplyPlanarFormula(damage)
    return (math.sqrt(damage * 4 + 64) - 8) * 4
end

-- 计算实际造成的物理伤害（武器伤害 × 玩家伤害倍率 × 套装增伤 × 目标伤害吸收）
local function GetRegularDamageDealt(target)
    local baseDamage
    if PlayerUtil:IsRiding() then
        local Beef = PlayerUtil:GetMount()
        if Beef then
            local a, _ = Beef.AnimState:GetSymbolOverride("beefalo_mouthmouth")
            local mouthId = a and tostring(a)
            baseDamage = BeefDamage[mouthId] or (Beef:HasTag("domesticated") and 34 or 34)
            local Saddle = PlayerUtil:GetSaddle()
            if Saddle then
                local bonus = TUNING[Saddle.prefab:upper() .. "_BONUS_DAMAGE"]
                if bonus then
                    baseDamage = baseDamage + bonus
                end
            end
        else
            baseDamage = TUNING.UNARMED_DAMAGE
        end
    else
        baseDamage = GetWeaponDamage(target) * GetDamageMultiplier(ThePlayer)
        local setBonus = GetActiveSetBonus()
        baseDamage = baseDamage * GetSetBonusDamageMult(setBonus)
    end

    -- 阿比盖尔易伤加成
    if target.AbiDbuff then
        if ThePlayer.prefab == "wendy" then
            baseDamage = baseDamage * TUNING.ABIGAIL_VEX_GHOSTLYFRIEND_DAMAGE_MOD
        end
        baseDamage = baseDamage * TUNING.ABIGAIL_VEX_DAMAGE_MOD
    end

    -- 吸收率
    baseDamage = baseDamage * GetDamageAbsorption(target)

    -- 位面实体公式
    if target.prefab and PlanarEList[target.prefab] then
        baseDamage = ApplyPlanarFormula(baseDamage)
    end

    return baseDamage
end

-- 计算实际造成的位面伤害（武器位面 + 套装位面，不受护甲吸收影响）
local function GetPlanarDamageDealt()
    if PlayerUtil:IsRiding() then
        local Saddle = PlayerUtil:GetSaddle()
        if Saddle and Saddle.prefab == "saddle_shadow" then
            return TUNING.SADDLE_SHADOW_PLANAR_DAMAGE
        end
        return 0
    end
    local setBonus = GetActiveSetBonus()
    return GetPlanarDamage() + GetSetBonusPlanarDamage(setBonus)
end

-- 计算实际造成的总伤害值
local function GetDamageDealt(target)
    local regularDamage = GetRegularDamageDealt(target)
    local planarDamage = GetPlanarDamageDealt()
    return regularDamage + planarDamage
end

-- 获取生命值条显示的最大生命值
local function GetHealthBarMaxHealth(target)
    return target
        and target.components.modhealthbar
        and target.components.modhealthbar:GetMaxHealth()
        or 0
end

-- 设置新的最大生命值到生命值条组件（优先取服务端真实数据，无则回退本地推算）
local function SetNewMaxHealth(target)
    if target and target.components.modhealthbar then
        local maxHealth = nil
        -- 优先：Show Me / Insight 真实最大血量
        local realhp = ShowMeUtil.Get(target) or InsightUtil.Get(target)
        if realhp and realhp.max and realhp.max > 0 then
            maxHealth = realhp.max
        end
        if not maxHealth then
            maxHealth = GetMaxHealth(target)
        end
        target.components.modhealthbar:SetMaxHealth(maxHealth)

    end
end

-- 获取生命值条的垂直偏移量（统一脚底）
local function GetHealthBarOffset(target)
    return 0
end

-- 位面伤害颜色
local DAMAGE_COLOUR_RED    = {1, 0, 0, 1}             -- 普通物理伤害：纯红大字
local PLANAR_COLOUR_LUNAR  = {0.392, 0.784, 1, 1}   -- 月亮位面：淡蓝
local PLANAR_COLOUR_SHADOW = {0.5, 0, 0.5, 1}       -- 暗影位面：紫黑

-- 根据武器标签获取伤害跳字颜色（仅非骑乘，骑乘由调用处直接取色）
local function GetDamageColour()
    local weapon = InventoryUtil:GetEquippedItem(EQUIPSLOTS.HANDS)
    if weapon then
        if weapon:HasTag("shadow_item") then
            return PLANAR_COLOUR_SHADOW
        end
        local cached = ItemUtil:GetCachedItem(weapon)
        if cached and cached.planar_damage then
            return PLANAR_COLOUR_LUNAR
        end
    end
    return PLANAR_COLOUR_LUNAR
end

-- 更新生命值条显示
local function UpdateHealthbar(target)
    -- 读取权威数据源（Insight 优先，战斗期间更活跃）
    local insightHp = InsightUtil.Get(target)
    local showmeHp = ShowMeUtil.Get(target)
    local realhp = insightHp or showmeHp
    local realSrc = insightHp and "insight" or (showmeHp and "showme" or nil)
    local hasAuth = realhp and realhp.value and realhp.max and realhp.max > 0

    -- ====== 跳字（伤害数字） ======
    -- 权威跳字由 _onDataArrived 回调处理：攻击帧 _ec_pre_real_hp 未消费，等待服务器数据到达后用真实差值跳字
    -- 兜底：无 Insight/ShowMe 数据时走本地估算跳字
    if not hasAuth then
        local regularDamage = GetRegularDamageDealt(target)
        local planarDamage = GetPlanarDamageDealt()
        if regularDamage > 0 then
            ShowStatPopup(math.floor(regularDamage), target:GetPosition(), DAMAGE_COLOUR_RED)
        end
        if planarDamage > 0 then
            local colour = PlayerUtil:IsRiding() and PLANAR_COLOUR_SHADOW or GetDamageColour()
            ShowStatPopup(math.floor(planarDamage), target:GetPosition(), colour)
        end
    end

    target._has_real_hp_data = false

    -- 本地伤害预测开关：关闭时不显示血条
    if not CONFIG.DAMAGE_ESTIMATION then
        target._ec_predicted_hp = nil
        return
    end

    -- ====== 血条更新 ======
    if not target.components.modhealthbar then
        target:AddComponent("modhealthbar")
        SetNewMaxHealth(target)
        local offset = GetHealthBarOffset(target)
        target.components.modhealthbar:SetPosition(Vector3(0, offset, 0))
    end

    if hasAuth then
        -- 权威路径：纯服务端数据
        local realDmg = math.max(0, realhp.max - realhp.value)
        HealthTracker[target] = realDmg
        target.components.modhealthbar:SetMaxHealth(realhp.max)
        target.components.modhealthbar:SetHealthValue(realhp.value / realhp.max, realhp.value, realhp.max)
        target._has_real_hp_data = true
        target._ec_predicted_hp = nil

    else
        -- 预测路径：无权威数据，本地估算兜底
        local totalDamage = GetDamageDealt(target) or 0
        local maxHealth = GetHealthBarMaxHealth(target)
        if maxHealth <= 0 then
            maxHealth = GetMaxHealth(target)
        end
        local prevDamage = HealthTracker[target] or 0
        HealthTracker[target] = prevDamage + totalDamage
        local percent = (maxHealth - HealthTracker[target]) / maxHealth

        target.components.modhealthbar:SetValue(percent, HealthTracker[target], maxHealth)
        target._ec_predicted_hp = { value = math.max(0, maxHealth - HealthTracker[target]), max = maxHealth }

    end
end

-- ========== 攻击检测系统（逐帧关键帧检测）==========

-- 攻击动画 → 伤害触发帧（从 2316507379 移植）
local AttackList = {
    ["spearjab"] = 2,
    ["atk"] = 3,
    ["pocketwatch_atk"] = 3,
    ["dart_pre"] = 3,
    ["toolpunch"] = 3,
    ["slingshot_pre"] = 3,
    ["throw"] = 3,
    ["whip"] = 5,
    ["punch"] = 9,
    ["punch_a"] = 9,
    ["punch_b"] = 9,
    ["punch_c"] = 9,
    ["moose_slam"] = 9,
}

-- 攻击前摇动画（仅显示血条，不触发伤害）
local TriggerList = {
    "atk_pre",
    "whip_pre",
    "pocketwatch_atk_pre",
    "pocketwatch_atk_pre_2",
    "spearjab_pre",
}

-- 动画去重检测（避免同一动画重复触发）
-- 注意：使用 _ec_ 前缀变量避免与 HealthBar Client 等第三方模组冲突
local function CheckAnim(inst, State, Anime)
    if State:IsCurrentAnimation(Anime) then
        if inst._ec_prev_anim ~= Anime or State:GetCurrentAnimationTime() < (inst._ec_prev_anim_time or 0) then
            inst._ec_prev_anim_time = State:GetCurrentAnimationTime()
            inst._ec_prev_anim = Anime
            inst._ec_recorded_anim = true
            return true
        else
            inst._ec_prev_anim_time = State:GetCurrentAnimationTime()
            inst._ec_prev_anim = Anime
            inst._ec_recorded_anim = true
            return false
        end
    else
        return false
    end
end

-- 检查目标是否可攻击
local function CanHit(Kombat, Target)
    if Target ~= nil and Target:IsValid() and not Target:HasTag("INLIMBO") then
        local weapon = Kombat:GetWeapon()
        if Kombat:CanExtinguishTarget(Target, weapon)
            or Kombat:CanLightTarget(Target, weapon)
            or (Target.replica.combat ~= nil and Target.replica.combat:CanBeAttacked(Kombat.inst)) then
            local range = Target:GetPhysicsRadius(0) + Kombat:GetAttackRangeWithWeapon()
            return distsq(Target:GetPosition(), Kombat.inst:GetPosition()) <= range * range
        end
    end
    return false
end

-- 空间扫描查找攻击目标
-- 玩家角色的 replica.combat:GetTarget() 在客户端不可靠（玩家攻击走 BufferedAction 而非 SetTarget）
-- 仿照 HitAndRun 的 GetClosestTarget + playercontroller:GetAttackTarget() 的逻辑：
-- 优先 classified.lastcombattarget（节省空间扫描），其次用 FindEntities 扫附近 _combat 实体
local function FindAttackTarget(player)
    local combat = PlayerUtil:GetCombat()
    if not combat then return nil end
    local attackrange = combat:GetAttackRangeWithWeapon()
    local reach = player:GetPhysicsRadius(0) + attackrange + 2

    -- 优先：上次战斗目标（classified.lastcombattarget），省一次空间扫描
    if combat.classified and combat.classified.lastcombattarget then
        local last = combat.classified.lastcombattarget:value()
        if last and last:IsValid()
            and not last:HasTag("INLIMBO")
            and last.replica.combat
            and last.replica.combat:CanBeAttacked(player)
            and player:GetDistanceSqToInst(last) <= reach * reach then
            return last
        end
    end

    -- 兜底：空间扫描
    local x, y, z = player.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, reach, { "_combat" }, { "player", "INLIMBO", "companion" })

    local nearest = nil
    local nearest_dist = math.huge
    for _, v in ipairs(ents) do
        if v.replica and v.replica.combat and v.replica.combat:CanBeAttacked(player) then
            local dsq = player:GetDistanceSqToInst(v)
            if dsq < nearest_dist then
                nearest_dist = dsq
                nearest = v
            end
        end
    end

    return nearest
end

-- 逐帧动画检测主函数
local function AnimationRecordMain(player_main)
    -- 总开关（HUD 实时控制）：关闭则完全不显示怪物血条
    if not CONFIG.HEALTHBAR_ENABLED then
        return
    end
    -- 每 30 帧清理一次无效追踪器（弱引用表已有 GC 自动回收，手动清理降频减少开销）
    player_main._cleanup_timer = (player_main._cleanup_timer or 0) + 1
    if player_main._cleanup_timer >= 30 then
        player_main._cleanup_timer = 0
        for target, _ in pairs(HealthTracker) do
            if not target:IsValid() then
                HealthTracker[target] = nil
            end
        end
    end

    player_main._ec_recorded_anim = false

    -- 前摇动画：空间扫描找目标，显示血条
    for i, animate in ipairs(TriggerList) do
        if CheckAnim(player_main, player_main.AnimState, animate) then
            local target = FindAttackTarget(player_main)
            if target and not InCompatible[target.prefab] then
                player_main._attack_target = target
                -- 攻击前摇即请求真实血量（命中时数据更可能已回传）
                ShowMeUtil.Fetch(target)
                if InsightUtil.IsAvailable() then InsightUtil.Fetch(target) end
                if not target.components.modhealthbar then
                    target:AddComponent("modhealthbar")
                    SetNewMaxHealth(target)
                    target.components.modhealthbar:SetPosition(Vector3(0, GetHealthBarOffset(target), 0))
                end
                if not HealthTracker[target] then
                    HealthTracker[target] = 0
                end
            end
            return
        end
    end

    -- 攻击动画：空间扫描找目标，命中帧触发伤害
    for animate, frameCount in pairs(AttackList) do
        if CheckAnim(player_main, player_main.AnimState, animate) then
            local target = FindAttackTarget(player_main)
            if target and not InCompatible[target.prefab] then
                player_main._attack_target = target
                -- 攻击命中：请求真实血量 + 缓存命中前血量用于真实跳字
                ShowMeUtil.Fetch(target)
                if InsightUtil.IsAvailable() then InsightUtil.Fetch(target) end
                local preHp = InsightUtil.Get(target) or ShowMeUtil.Get(target)
                if preHp then
                    target._ec_pre_real_hp = preHp.value
                    print("[EC-POPUP] _ec_pre_real_hp SET prefab=" .. tostring(target.prefab)
                        .. " preHp.value=" .. tostring(preHp.value)
                        .. " src=" .. tostring(InsightUtil.Get(target) and "insight" or (ShowMeUtil.Get(target) and "showme" or "???")))
                else
                    print("[EC-POPUP] _ec_pre_real_hp NOT SET prefab=" .. tostring(target.prefab)
                        .. " (no cached data at attack start)")
                end
                player_main._ec_started_attack = true
                if not target.components.modhealthbar then
                    target:AddComponent("modhealthbar")
                    SetNewMaxHealth(target)
                    target.components.modhealthbar:SetPosition(Vector3(0, GetHealthBarOffset(target), 0))
                end
                if not HealthTracker[target] then
                    HealthTracker[target] = 0
                end
            end
            return
        else
            if player_main.AnimState:IsCurrentAnimation(animate) then
                if player_main.AnimState:GetCurrentAnimationTime() > FRAMES * frameCount then
                    local target = player_main._attack_target
                    local canHit = CanHit(PlayerUtil:GetCombat(), target)
                    if player_main._ec_started_attack
                        and target
                        and not InCompatible[target.prefab]
                        and canHit then
                        UpdateHealthbar(target)
                        player_main._ec_started_attack = false
                    end
                end
            end
        end
    end

    -- 动画结束重置
    if not player_main._ec_recorded_anim then
        player_main._ec_prev_anim_time = 0
        player_main._ec_prev_anim = ""
        player_main._ec_started_attack = false
        player_main._attack_target = nil
    end
end

-- 确保 modhealthbar 组件存在（仅用于 NPC 目标血条）
local function EnsureHealthbar(inst)
    if not inst.components.modhealthbar then
        inst:AddComponent("modhealthbar")
    end
    return inst.components.modhealthbar
end

-- DamageTracker 类定义（仅处理怪物血条和攻击动画检测）
local DamageTracker = Class(function(self, inst)
    self.inst = inst

    -- 逐帧动画检测（替代 performaction 事件，精确到关键帧）
    inst._ec_prev_anim_time = 0
    inst._ec_prev_anim = ""
    inst._ec_recorded_anim = false
    inst._ec_started_attack = false
    -- 每帧检测（匹配走A等高频打断场景，HealthBar Client 同样每帧）
    inst:DoPeriodicTask(FRAMES, AnimationRecordMain)

    -- ShowMe 数据到达时实时校正血条 + 权威跳字（覆盖本地预测值）
    ShowMeUtil._onDataArrived = function(target, hp)
        if target and target:IsValid() and target.components.modhealthbar then
            -- 权威跳字：攻击帧记录的 _ec_pre_real_hp 在此消费，与服务器新数据做差值
            if target._ec_pre_real_hp then
                local realDelta = target._ec_pre_real_hp - hp.value
                target._ec_pre_real_hp = nil
                if realDelta > 0 then
                    ShowStatPopup(math.floor(realDelta), target:GetPosition(), DAMAGE_COLOUR_RED)
                end
            end

            target.components.modhealthbar:SetHealthValue(hp.value / hp.max, hp.value, hp.max)
            target._has_real_hp_data = true
            target._ec_predicted_hp = nil
            local syncDamage = math.max(0, hp.max - hp.value)
            HealthTracker[target] = syncDamage

        end
    end

    -- Insight 数据到达时同样校正血条 + 权威跳字（与 ShowMe 统一处理）
    InsightUtil._onDataArrived = function(target, hp)
        if target and target:IsValid() and target.components.modhealthbar then
            -- 权威跳字：攻击帧记录的 _ec_pre_real_hp 在此消费，与服务器新数据做差值
            if target._ec_pre_real_hp then
                local realDelta = target._ec_pre_real_hp - hp.value
                target._ec_pre_real_hp = nil
                if realDelta > 0 then
                    ShowStatPopup(math.floor(realDelta), target:GetPosition(), DAMAGE_COLOUR_RED)
                end
            end

            target.components.modhealthbar:SetHealthValue(hp.value / hp.max, hp.value, hp.max)
            target._has_real_hp_data = true
            target._ec_predicted_hp = nil
            local syncDamage = math.max(0, hp.max - hp.value)
            HealthTracker[target] = syncDamage

        end
    end
end)

return DamageTracker