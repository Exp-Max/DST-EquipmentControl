--============================================================================
-- 动态配置层：替代 modinfo 的 GetModConfigData，供 HUD 内实时开关并持久化
--
-- 唯一权威：MOD_EQUIPMENT_CONTROL.CONFIG（key => value），读写都走这里。
-- 存盘时机：改动只写内存（不落盘），由 modmain 在 playerdeactivated（退出世界 /
--          断开连接 / 洞穴迁移）时统一 Config:Save() 一次。改配置本就不频繁，
--          无需每次写盘，也无需防抖。
--
-- 读取语义：stored 里没有的 key 回落到 CONFIG_DEFAULTS。
--  ⚠ 回落判断必须写成 `if v == nil then return 默认 end`，
--    不能写 `return v ~= nil and v or 默认` —— 后者在 v == false 时会返回默认值，
--    导致「默认开启、用户关掉」的项存了 false 却读回 true（关不掉）。
--============================================================================

local FileSystem = require "util/filesystem"

local CONFIG_FILE = "equipment_control_cfg"

local Config = { FILE = CONFIG_FILE }

-------------------------------------------------------------------------------
-- 滤镜 key 清单（唯一来源）
-- filterremover 用它初始化 FILTER_STATE；confighud 的 FILTER_RAW 只补 UI 文案。
-- 默认全部 true（进入游戏即消除所有画面滤镜/覆盖层）。
-------------------------------------------------------------------------------
Config.FILTER_KEYS = {
    -- 色彩立方总开关：关掉即 index 0/1/2 三层色块整体失效（季节/黄昏/夜晚/满月/
    -- 洞穴梦魇/低理智灰屏一并消失）。默认 false = 保留原版画面基调。
    "FILTER_COLOURCUBE",
    -- 低理智灰屏（insane 色块的 index 1 lerp + 理智扭曲），不含暗角（那是 VIGNETTE）
    "FILTER_INSANITY_CC",
    -- 季节 / 时段 / 满月 / 洞穴：按色块文件名逐个替换，可只关夏季或只关黄昏。
    -- 与 COLOURCUBE（整条管线一刀切）的区别：这个是「换掉某几张色块」，那个是「色块整体失效」。
    -- 默认 false = 保留原版季节色调。
    "FILTER_SEASON_AUTUMN", "FILTER_SEASON_WINTER", "FILTER_SEASON_SPRING", "FILTER_SEASON_SUMMER",
    "FILTER_PHASE_DUSK", "FILTER_PHASE_NIGHT", "FILTER_FULLMOON", "FILTER_CAVE_NIGHTMARE",
    -- 非常规色块：幽灵视野、停电全黑、洞穴真菌区与天坑区
    -- （海狸视野色块 beaver_vision_cc 并入已有的 FILTER_BEAVER，那个开关同时管 widget 与色块）
    "FILTER_GHOST", "FILTER_BLACKOUT", "FILTER_CAVE_FUNGUS", "FILTER_CAVE_SINKHOLE",
    "FILTER_NIGHTVISION_CC", "FILTER_LUNACY", "FILTER_DISTORTION", "FILTER_BLOOM",
    "FILTER_BLOOD", "FILTER_ICE", "FILTER_FIRE", "FILTER_HEAT", "FILTER_FUME",
    "FILTER_BEEFBLOOD", "FILTER_LEAFCANOPY", "FILTER_NUTRIENTS", "FILTER_GOGGLE",
    "FILTER_MINDCONTROL", "FILTER_SANDSTORM", "FILTER_MOONSTORM", "FILTER_MIASMA",
    "FILTER_WAGPUNK", "FILTER_WAGLENS", "FILTER_NIGHTVISION", "FILTER_INSPECTACLES",
    "FILTER_ROSEGLASSES", "FILTER_DRONEZAP", "FILTER_INSANITY_VIGNETTE",
    "FILTER_VIGNETTE", "FILTER_BEAVER", "FILTER_INK", "FILTER_FLARE",
    "FILTER_SPACETIME_MIST",
}


-------------------------------------------------------------------------------
-- 自动装备分类开关默认值（key = 物品栏按钮条的分类名，见 widgets/buttons.lua）
-- ⚠ 未列出的分类（如 STAFF）没有自动装备开关：CONFIG 返回 nil，
--   itembutton 的中键分支靠 `state ~= nil` 判断为「不可切换」，保持原行为。
-------------------------------------------------------------------------------
local AUTO_EQUIP_DEFAULTS = {
    CANE         = true,
    LIGHT        = true,
    WEAPONS      = true,
    AXE          = true,
    PICKAXE      = true,
    SHOVEL       = true,
    HAMMER       = false,
    BUGNET       = true,
    FOOD         = true,   -- 自动进食
    ARMORHAT     = true,   -- 自动头部护甲
    ARMORBODY    = true,   -- 自动身体护甲
    CLOTHINGHAT  = true,   -- 自动头部衣物
    CLOTHINGBODY = true,   -- 自动身体衣物
    AMULET       = true,   -- 自动护符
}

-------------------------------------------------------------------------------
-- 其余配置项的默认值
-------------------------------------------------------------------------------
local CONFIG_DEFAULTS = {
    -- 鼠标穿透
    FORCE_INSPECT_PLAYERS       = false,
    FLYING_BIRDS_MOUSETHROUGH   = true,
    YELLOWSTAFF_MOUSETHROUGH    = true,
    ORANGESTAFF_MOUSETHROUGH    = true,

    -- 拾取过滤
    PRIOTIZE_VALUABLE_ITEMS     = true,
    IGNORE_KNOWN_BLUEPRINT      = true,
    PICKUP_IGNORE_FERNS         = true,
    PICKUP_IGNORE_SUCCULENTS    = true,
    PICKUP_IGNORE_MARSH_BUSH    = true,
    MEAT_PRIORITIZATION_MODE    = "DISABLED",
    ACTIONS_BLOCK               = true,

    -- 传送
    TELEPOOF_DISABLED           = false,
    TELEPOOF_HOVER              = false,
    TELEPOOF_DOUBLECLICK        = 0.5,
    TELEPOOF_WORTOX             = true,

    -- 快捷动作
    QUICK_ACTION_BEEFALO              = true,
    QUICK_ACTION_KLAUS_SACK           = true,
    QUICK_ACTION_REPAIR_BOAT          = true,
    QUICK_ACTION_BUILD_FOSSIL         = true,
    QUICK_ACTION_ATRIUM_GATE          = true,
    QUICK_ACTION_DIRTPILE             = true,
    QUICK_ACTION_FEED_BIRD            = true,
    QUICK_ACTION_WAKEUP_BIRD          = true,
    QUICK_ACTION_IMPRISON_BIRD        = true,
    QUICK_ACTION_BOTTLESSOUL          = true,
    QUICK_ACTION_DEVOURER             = true,
    QUICK_ACTION_EXTINGUISH           = true,
    QUICK_ACTION_MEDAL_POLLUTE        = true,
    QUICK_ACTION_MEDAL_PLANT_MANDRAKE = true,
    QUICK_ACTION_MEDAL_BURY_GREENGEM  = true,
    QUICK_ACTION_MEDAL_TREE_LEVEL_UP  = true,
    QUICK_ACTION_MEDAL_WORMWOOD_FLOWER = true,
    QUICK_ACTION_MEDAL_MAKE_COOLDOWN  = true,
    QUICK_ACTION_MEDAL_GRINDING       = true,
    QUICK_ACTION_MEDAL_CHEFFLAVOUR    = true,
    QUICK_ACTION_MEDAL_EAT_SPICES     = true,
    QUICK_ACTION_MEDAL_SOUL_ABSORB    = true,
    QUICK_ACTION_MEDAL_SOUL_AUTO      = true,

    -- 几何对齐（复用官方轴对齐系统；核心目的：让官方建造网格对齐到分割线/网格线交点）
    GRIDALIGN_ENABLED      = true,   -- 总开关：关掉则全部回退官方原生行为
    GRIDALIGN_VERTEX       = true,   -- 对齐到网格顶点（分割线交点）；除基础1x1外都生效（含16x16小网格），仅1x1退回瓦片中心
    GRIDALIGN_BOAT         = true,   -- 船下水显示网格（官方用 boatbuilder 标签排除了轴对齐）
    -- 注：地皮 / 墙体 / 船用护舷等有自己的吸附规则（一次一格 / 落整数米 / 贴船边），
    --     不适用网格，故不提供开关，统一跳过。
    GRIDALIGN_GRID16       = false,  -- 往官方网格档位表插入 16x16（0.25 单位/格），参与官方切换
    GRIDALIGN_HIDEPLACER   = true,   -- 隐藏建造虚影（老牌 GP 的 HIDEPLACER）
    GRIDALIGN_HIDEPERCENT  = false,  -- 隐藏鼠标上物品的耐久
    GRIDALIGN_HIDEQUANTITY = false,  -- 隐藏鼠标上物品的数量
    GRIDALIGN_DROP         = true,   -- 丢弃对齐（落点吸附到瓦片中心；网格视觉由真实地皮分界线提供）
    GRIDALIGN_DEPLOY       = true,   -- 部署对齐
    GRIDALIGN_BUILD        = true,   -- 建造对齐
    GRIDALIGN_TRANSPARENCY = false,  -- 半透明网格（开关：启用半透明后 alpha 取 GRIDALIGN_ALPHA 的值）
    GRIDALIGN_ALPHA        = 0.6,    -- 网格透明度（0.0~1.0；仅 GRIDALIGN_TRANSPARENCY 开启时生效）

    -- 血条（EC 自研 modhealthbar 实体血条 + Show Me/Insight 真实血量数据源）
    HEALTHBAR_ENABLED   = true,   -- 总开关：关掉则完全不显示怪物血条
    DAMAGE_ESTIMATION   = true,   -- 本地伤害预测：关掉则仅显示真实数据源血量，无真实数据则不显示

    AUTOCOOK_ENABLED    = true,   -- 智能烹饪：打开烹饪锅时显示食谱面板，支持搜索/筛选/自动投料

    -- 箱子记忆：无需打开箱子即可查看内容，支持历史浏览和物品高亮
    CHEST_MEMORY_ENABLED            = true,   -- 总开关
    CHEST_MEMORY_DISPLAY_TYPE       = "all",  -- 显示模式：all(全部) / single(悬停) / hidden(隐藏)

    -- 巨石躲避：岩石树(Boulderbough)即将砸下巨石时自动走开
    BOULDER_DODGE           = true,   -- 巨石躲避总开关
    DODGE_MARGIN            = 1.0,    -- 躲避余量（在巨石伤害范围之外额外保持的距离）
    DODGE_MANUAL_OVERRIDE   = true,   -- 手动移动覆盖：按住方向键时允许玩家手动移动
    DODGE_USE_CANE          = false,  -- 自动切手杖加速：躲避时自动装备手杖/橙宝石法杖
    DODGE_CHOPS_OVERRIDE    = 0,      -- 砍倒刀数：手动指定砍倒岩石树需要的刀数，0=自动学习
}

-- 滤镜与自动装备的默认值并入同一张默认表（避免清单散落多处）
for _, k in ipairs(Config.FILTER_KEYS) do
    CONFIG_DEFAULTS[k] = true
end
-- 例外：色彩立方是「画面基调」而非特效，默认保留原版（关掉会连季节氛围一起没），
-- 由用户在 HUD 里自行开启。季节/时段色块同理。
CONFIG_DEFAULTS.FILTER_COLOURCUBE = false
for _, k in ipairs({
    "FILTER_SEASON_AUTUMN", "FILTER_SEASON_WINTER", "FILTER_SEASON_SPRING", "FILTER_SEASON_SUMMER",
    "FILTER_PHASE_DUSK", "FILTER_PHASE_NIGHT", "FILTER_FULLMOON", "FILTER_CAVE_NIGHTMARE",
    "FILTER_GHOST", "FILTER_BLACKOUT", "FILTER_CAVE_FUNGUS", "FILTER_CAVE_SINKHOLE",
}) do
    CONFIG_DEFAULTS[k] = false
end
for category, enabled in pairs(AUTO_EQUIP_DEFAULTS) do
    CONFIG_DEFAULTS["AUTO_EQUIP_" .. category] = enabled
end

local stored = {}
local dirty  = false
-- 配置存盘走异步读取（本地 unsafedata/ 或 TheSim 持久化）：启动早期同步 GetPersistentString 尚未就绪，
-- 用回调把读回的值并入 stored（不覆盖已改动的键）。模块在 Init 阶段才读 CONFIG，彼时存盘已就绪。
FileSystem:LoadTableFromFile(CONFIG_FILE, function(tbl)
    local loaded = 0
    for k, v in pairs(tbl) do
        if stored[k] == nil then
            stored[k] = v
            loaded = loaded + 1
        end
    end
    print("[EC:Config] Load callback: merged " .. tostring(loaded) .. " keys into stored")
end)

-------------------------------------------------------------------------------
-- 读写
-------------------------------------------------------------------------------
function Config:Get(key)
    local v = stored[key]
    if v == nil then
        return CONFIG_DEFAULTS[key]
    end
    return v
end

function Config:Set(key, value)
    if stored[key] == value then return end
    print("[EC:Config] Set key=" .. tostring(key) .. " value=" .. tostring(value))
    stored[key] = value
    dirty = true
    Config:Save(true)
end

-- 由 modmain 在 playerdeactivated 时调用；force = true 可无视 dirty 强制落盘
function Config:Save(force)
    if not (dirty or force) then return end
    print("[EC:Config] Save force=" .. tostring(force) .. " dirty=" .. tostring(dirty))
    FileSystem:SaveTableToFile(CONFIG_FILE, stored)
    dirty = false
end

-------------------------------------------------------------------------------
-- 对外挂载
-------------------------------------------------------------------------------
local MEC = MOD_EQUIPMENT_CONTROL
if MEC == nil then
    -- modmain 会在写 GLOBAL.MOD_EQUIPMENT_CONTROL 之后才 require 本文件，
    -- 走到这里说明加载顺序被改坏了，直接报错好过静默失效。
    error("[Equipment Control] util/config 需在 GLOBAL.MOD_EQUIPMENT_CONTROL 赋值之后加载")
    return Config
end

-- 主配置表：直接读写即可（CONFIG.KEY = v / CONFIG.KEY）
MEC.CONFIG = setmetatable({}, {
    __index = function(_, k)
        return Config:Get(k)
    end,
    __newindex = function(_, k, v)
        Config:Set(k, v)
    end,
})

-- 即时落盘：HUD 切换配置后调用，避免仅依赖 playerdeactivated 时机（异常退出/切世界遗漏）
MEC.ConfigSave = function() Config:Save(true) end

-- 自动装备开关：读写转发到 CONFIG 的 AUTO_EQUIP_<分类>，
-- 使 widgets/itembutton 的中键切换与各 Auto 模块的读取自动获得持久化，调用方无需改动。
MEC.AUTO_EQUIP = setmetatable({}, {
    __index = function(_, category)
        return Config:Get("AUTO_EQUIP_" .. tostring(category))
    end,
    __newindex = function(_, category, value)
        Config:Set("AUTO_EQUIP_" .. tostring(category), value)
    end,
})

return Config