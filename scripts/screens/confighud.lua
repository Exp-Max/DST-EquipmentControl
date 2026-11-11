--============================================================================
-- 类原生右侧贴边抽屉 ConfigHUD（原 FeatureDrawerHUD，改名 confighud；直接挂 controls 并重算坐标，右贴边停靠，展开从屏幕右侧滑入）
-- 展开后露出：标题 → 横隔线 → 分类栏（功能） → 横隔件 → 选中功能的子配置。
-- 点分类格切换/收起其专属子配置（同一时间只开一个）。
-- 原 F 键绑定已从 modinfo 解绑（默认 NONE），功能只通过本 HUD 触发。
--
-- 布局全部照抄官方制作菜单，不再凭手感拼：
--   外框     = CraftingMenuWidget:MakeFrame(500, 600)        craftingmenu_widget.lua:553-620
--   分类栏   = CraftingMenuWidget:MakeFilterPanel(width)     craftingmenu_widget.lua:815-910
--   配方栏   = CraftingMenuWidget:MakeRecipeList(width, h)   craftingmenu_widget.lua:920-1140
--   容器模板 = TEMPLATES.ScrollingGrid                        widgets/redux/templates.lua:1961
--   选中态   = filterslot_frame_select.tex 贴图（官方 SelectFilter，craftingmenu_widget.lua:716-719）
--              ⚠ 不用官方 ImageButton:Select()：那会让按钮不可再点击，见 _HighlightTiles 注释
--
-- 说明：filterslot_frame.tex 在 atlas 里的 uv 跨度其实是 68px，但 Klei 自己写的是 button_size/64。
-- 这里照抄 38/64，几何才与官方逐像素一致。
--============================================================================

local Widget = require "widgets/widget"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local Grid = require "widgets/grid"
local Text = require "widgets/text"
local TEMPLATES = require "widgets/redux/templates"

--============================================================================
-- 动态配置：统一由 util/config.lua 提供（modmain 最先加载）
--   MOD_EQUIPMENT_CONTROL.CONFIG.KEY           读写配置项，自动持久化
--   MOD_EQUIPMENT_CONTROL.IsFilterRemoved(key) 滤镜消除（filterremover，同样走 CONFIG）
--   MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[分类]      自动装备开关（转发到 CONFIG 的代理表）
-- 默认值清单、滤镜 key 清单都在 util/config.lua，本文件只负责 UI。
--============================================================================

local CRAFTING_ATLAS = "images/crafting_menu.xml"
local UI_ATLAS       = "images/ui.xml"

-------------------------------------------------------------------------------
-- 焦点跳转工具：与官方 CraftingMenuWidget:DoFocusHookups 同款
-------------------------------------------------------------------------------
local function GetClosestWidget(list, active_widget, dir_x, dir_y)
    local closest, closest_score = nil, nil
    if active_widget ~= nil then
        local x, y = active_widget.inst.UITransform:GetWorldPosition()
        for _, v in ipairs(list) do
            if v ~= active_widget and v:IsVisible() and v:IsEnabled() and (v.IsFullyInView == nil or v:IsFullyInView()) then
                local vx, vy = v.inst.UITransform:GetWorldPosition()
                local local_dir_x, local_dir_y = vx - x, vy - y
                if VecUtil_Dot(local_dir_x, local_dir_y, dir_x, dir_y) > 0 then
                    local score = local_dir_x * local_dir_x + local_dir_y * local_dir_y
                    if not closest or score < closest_score then
                        closest = v
                        closest_score = score
                    end
                end
            end
        end
    end
    return closest, closest_score
end

-------------------------------------------------------------------------------
-- 外框（官方 craftingmenu_hud.lua: local HEIGHT = 600；craftingmenu_widget.lua: MakeFrame(500, height)）
-------------------------------------------------------------------------------
local FRAME_W, FRAME_H = 500, 600
local TOPBAR_W   = 534           -- 官方 top/bottom 固定 ScaleToSize(534, 38)，不随面板宽变
local SIDE_INSET = 8             -- 官方 left/right: SetPosition(∓(width/2 + 8), 1)
local SIDE_W     = 26            -- 官方 ScaleToSize(∓26, ∓(height - 20))
local SIDE_EDGE  = SIDE_INSET + SIDE_W / 2        -- 面板最外缘相对中心 = 271
local LINE_R, LINE_G, LINE_B, LINE_A = 97/255, 73/255, 46/255, 1   -- 官方 BROWN（constants.lua:2301）

-------------------------------------------------------------------------------
-- 分类栏（官方 MakeFilterPanel）
-------------------------------------------------------------------------------
local BTN_SIZE    = 38           -- button_size
local BTN_SPACE   = 43           -- grid_button_space = button_size + 5（行距 = 列距）
local PANEL_PAD   = 40           -- 官方 width = width - 40
local PANEL_W     = FRAME_W - PANEL_PAD
local BTN_COLS    = math.floor(PANEL_W / (BTN_SIZE + 1))          -- 官方 grid_buttons_wide，本项目 = 11
local GRID_LEFT   = -BTN_SPACE * BTN_COLS / 2 + BTN_SPACE / 2     -- 官方 grid_left
local CAT_TOP_Y   = -2           -- 官方首行 y
local CAT_DIV_Y   = -26          -- 官方：y = y - button_size/2 - 5
local CAT_DIV_H   = 4            -- 官方 line_height
local CAT_GRID_Y  = -55          -- 官方：y = y - line_height - 8 - 17
local CAT_TAIL    = 6            -- 官方：y = y - grid_button_space*num_rows - 6
local CAT_ICON    = 54           -- 官方 filter_img:ScaleToSize(54, 54)

-------------------------------------------------------------------------------
-- 子配置栏（官方 MakeRecipeList）
-------------------------------------------------------------------------------
local CELL         = 60          -- cell_size
local CELL_SPACING = 6           -- row_spacing
local CELL_PITCH   = CELL + CELL_SPACING      -- 官方 widget_width/height = 60 + 6 = 66
local CELL_SCALE   = 0.475       -- 官方 w:SetScale(0.475)
local CELL_ICON    = 94          -- 官方 item_img:ScaleToSize(94, 94)
local SUB_COLS     = 7           -- 官方 num_columns
local SUB_ROWS     = 5           -- 官方 num_visible_rows = 3；本面板 600 高且无配方详情区，取 5 填满
local PEEK         = 0.5         -- 官方 peek_percent
local SB_OFFSET    = 7           -- 官方 scrollbar_offset
local SB_HOFFSET   = -50         -- 官方 scrollbar_height_offset

-------------------------------------------------------------------------------
-- 右侧贴边停靠
-------------------------------------------------------------------------------
local TAB_OUTER  = 30            -- 收起态：把手中心距屏幕右缘内缩（crafting_tab 256×0.4 半宽≈51）
local OPENED_X   = FRAME_W / 2 + SIDE_EDGE + FRAME_W / 2 + 10   -- 展开态 root 左移量：面板外缘正好落在屏幕右缘

--------------------------------------------------------------------------------
-- 滤镜消除子项（实时开关，由 filterremover 的 FILTER_STATE 驱动）。key = FILTER_XXX
-- 官方配方格没有常驻文字标签，名称走悬停文字；图标缺省回落到所属功能的图标。
--------------------------------------------------------------------------------
-- { key, 中文名, 图标 }：顺序与 util/config.lua 的 FILTER_KEYS 保持一致
-- 图标写法与 widgets/itembuttontile.lua 一致：prefab 名走官方 GetInventoryItemAtlas；
-- 少数不在物品图集里的（季节图标在 customisation.xml）写成 { atlas, tex } 直接指定。
-- 全部 prefab 已对着官方 images.zip 的图集逐个核对过，缺图会直接报错、便于定位。
local FILTER_RAW = {
    { "FILTER_COLOURCUBE",        "色彩立方(总开关)", "purplegem" },
    { "FILTER_INSANITY_CC",       "低理智灰屏",       "nightmarefuel" },
    { "FILTER_SEASON_AUTUMN",     "秋季色块",         { "images/customisation.xml", "autumn.tex" } },
    { "FILTER_SEASON_WINTER",     "冬季色块",         { "images/customisation.xml", "winter.tex" } },
    { "FILTER_SEASON_SPRING",     "春季色块",         { "images/customisation.xml", "spring.tex" } },
    { "FILTER_SEASON_SUMMER",     "夏季色块",         { "images/customisation.xml", "summer.tex" } },
    { "FILTER_PHASE_DUSK",        "黄昏色块",         "fireflies" },
    { "FILTER_PHASE_NIGHT",       "夜晚色块",         "nightlight" },
    { "FILTER_FULLMOON",          "满月紫月",         { "images/inventoryimages2.xml", "moonrockseed.tex" } },
    { "FILTER_CAVE_NIGHTMARE",    "洞穴梦魇色块",     "nightmare_timepiece" },
    { "FILTER_CAVE_FUNGUS",       "洞穴真菌色块",     "green_cap" },
    { "FILTER_CAVE_SINKHOLE",     "洞穴天坑色块",     "molehat" },
    { "FILTER_GHOST",             "幽灵色块",         "amulet" },
    { "FILTER_BLACKOUT",          "停电全黑",         "lantern" },
    { "FILTER_NIGHTVISION_CC",    "夜视色彩(LUT)",    "molehat" },
    { "FILTER_LUNACY",            "月癫效果",         { "images/inventoryimages1.xml", "alterguardianhat.tex" } },
    { "FILTER_DISTORTION",        "扭曲",             "redgem" },
    { "FILTER_BLOOM",             "泛光",             "lightbulb" },
    { "FILTER_BLOOD",             "血溅",             "hambat" },
    { "FILTER_ICE",               "冰冻",             "ice" },
    { "FILTER_FIRE",              "火焰",             "firestaff" },
    { "FILTER_HEAT",              "热浪",             "heatrock" },
    { "FILTER_FUME",              "毒气",             "spoiled_food" },
    { "FILTER_BEEFBLOOD",         "牛血",             "beefalowool" },
    { "FILTER_LEAFCANOPY",        "树冠阴影",         "pinecone" },
    { "FILTER_NUTRIENTS",         "养分",             "poop" },
    { "FILTER_GOGGLE",            "护目镜",           "goggleshat" },
    { "FILTER_MINDCONTROL",       "精神控制",         "armor_sanity" },
    { "FILTER_SANDSTORM",         "沙暴",             "deserthat" },
    { "FILTER_MOONSTORM",         "月风暴",           "moonrocknugget" },
    { "FILTER_MIASMA",            "瘴气",             "horrorfuel" },
    { "FILTER_WAGPUNK",           "瓦格朋克",         "gears" },
    { "FILTER_WAGLENS",           "废料单镜",         "scrap_monoclehat" },
    { "FILTER_NIGHTVISION",       "夜视果实",         { "images/inventoryimages1.xml", "ancientfruit_nightvision.tex" } },
    { "FILTER_INSPECTACLES",      "检视镜",           "inspectacleshat" },
    { "FILTER_ROSEGLASSES",       "玫瑰眼镜",         "roseglasseshat" },
    { "FILTER_DRONEZAP",          "无人机电击",       "transistor" },
    { "FILTER_INSANITY_VIGNETTE", "疯狂暗角",         "nightsword" },
    { "FILTER_VIGNETTE",          "暗角",             "umbrella" },
    { "FILTER_BEAVER",            "海狸化",           "log" },
    { "FILTER_INK",               "墨汁",             "papyrus" },
    { "FILTER_FLARE",             "耀斑",             "firecrackers" },
    { "FILTER_SPACETIME_MIST",   "时空迷雾",         "nightmarefuel" },
}
local FILTER_REMOVER_ITEMS = {}
for _, v in ipairs(FILTER_RAW) do
    local key = v[1]
    table.insert(FILTER_REMOVER_ITEMS, {
        key = key,
        label = v[2],
        icon = v[3],           -- 各项自己的图标，缺省才回落到所属功能的图标
        type = "toggle",
        filter_key = key,                  -- 真实滤镜 key，由 IsFilterRemoved/SetFilterRemoved 实时控制
        get_state = function()
            return MOD_EQUIPMENT_CONTROL.IsFilterRemoved(key)
        end,
    })
end


--------------------------------------------------------------------------------
-- 抽屉里列出的功能（原 F1-F9 + K）。conf 对应 KeybindService 注册的键。
--   icon      必填：分类格图标（制造栏筛选格同款 54×54）
--   get_state 可选：返回布尔 => 显示为开/关 toggle 子项
--   sub       可选：子配置项列表；缺省按 get_state / 占位自动生成
-- sub 项结构：
--   { type="action", label, trigger=true }        -> 点击经 KeybindService:Trigger(conf) 执行
--   label 也可为函数 -> 每次刷新格子时重新求值，用于「当前模式」这类动态文本
--   { type="action", label, conf="XXX" }          -> 同上，但用子项自己的 conf（一个分类多个动作时用）
--   { type="toggle", label, get_state=true }      -> 点击经 KeybindService:Trigger 切换（读 feature.get_state 反映）
--   { type="toggle", label, filter_key=KEY }      -> 滤镜消除子项，实时切换 filterremover 的 FILTER_STATE[KEY]
--   { icon = "xxx" }                              -> 可选，覆盖该子项的图标；缺省回落到所属 feature.icon
--   type="info" 的纯说明项不再进网格（官方配方格没有常驻文字），文字请在 feature.hint 里给
--------------------------------------------------------------------------------
local FEATURES = {
    { conf = "PICKUP_FILTER", label = "拾取过滤", icon = "backpack",
        hint = "悬停目标后点此，加入/移出过滤",
        sub = { { type = "action", label = "加入/移出悬停目标", trigger = true } } },
    { conf = "ATTACK_FILTER", label = "攻击过滤", icon = "spear",
        hint = "悬停目标后点此，加入/移出过滤",
        sub = { { type = "action", label = "加入/移出悬停目标", trigger = true } } },
    -- 排序：物品栏 / 背包 / 全部 / 箱子 合成一个分类，四个子按钮各自带 conf
    -- （默认 conf 只是分类的"主按钮"，真正点击走子项自己的 conf）
    { conf = "SORT_INVENTORY", label = "排序", icon = "treasurechest",
        hint = "整理物品栏 / 背包 / 全部 / 箱子（箱子需先打开）",
        sub = {
            { type = "action", label = "排序物品栏", conf = "SORT_INVENTORY", icon = "treasurechest", trigger = true },
            { type = "action", label = "排序背包",   conf = "SORT_BACKPACK",  icon = "backpack",     trigger = true },
            { type = "action", label = "排序全部",   conf = "SORT_ALL",       icon = "chest",        trigger = true },
            { type = "action", label = "排序箱子",   conf = "SORT_CHEST",     icon = "icebox",       trigger = true },
        } },
    { conf = "MAP_WHEEL", label = "坐标轮盘", icon = "mapscroll",
        hint = "打开坐标轮盘",
        sub = { { type = "action", label = "打开坐标轮盘", trigger = true } } },
    { conf = "MEAT_PRIORITIZATION_MODE", label = "肉类优先", icon = "meat",
        get_state = function() return MOD_EQUIPMENT_CONTROL.GetMeatMode and MOD_EQUIPMENT_CONTROL.GetMeatMode() end,
        hint = "开关肉类优先",
        sub = { { type = "toggle", label = "启用肉类优先", get_state = true } } },
    { conf = "DROPKEY", label = "放下灯笼", icon = "lantern",
        hint = "放下手中的灯笼",
        sub = { { type = "action", label = "放下灯笼", trigger = true } } },
    { conf = "FILTER_REMOVER", label = "滤镜消除", icon = "purplegem",
        hint = "逐项开关画面滤镜",
        sub = FILTER_REMOVER_ITEMS },

    --==========================================================================
    -- 模块配置开关：替代 modinfo，支持游戏内实时开关并持久化
    --==========================================================================
    { conf = "HEALTHBAR", label = "血条显示", icon = "meat",
        hint = "怪物血条：EC 自研实体血条，真实血量来自 Show Me / 中文 Show Me / Insight",
        sub = {
            { type = "toggle", label = "血条总开关", config_key = "HEALTHBAR_ENABLED" },
            { type = "toggle", label = "本地伤害预测", config_key = "DAMAGE_ESTIMATION" },
        } },
    { conf = "MOUSE_THROUGH", label = "鼠标穿透", icon = "orangestaff",
        hint = "配置鼠标穿透选项",
        sub = {
            { type = "toggle", label = "鸟类鼠标穿透", config_key = "FLYING_BIRDS_MOUSETHROUGH" },
            { type = "toggle", label = "强制查看玩家", config_key = "FORCE_INSPECT_PLAYERS" },
            { type = "toggle", label = "唤星法杖穿透", config_key = "YELLOWSTAFF_MOUSETHROUGH" },
            { type = "toggle", label = "懒人法杖穿透", config_key = "ORANGESTAFF_MOUSETHROUGH" },
        } },
    { conf = "PICKUP_OPTIONS", label = "拾取选项", icon = "cutgrass",
        hint = "配置拾取过滤选项",
        sub = {
            { type = "toggle", label = "优先贵重物品", config_key = "PRIOTIZE_VALUABLE_ITEMS" },
            { type = "toggle", label = "忽略已知蓝图", config_key = "IGNORE_KNOWN_BLUEPRINT" },
            { type = "toggle", label = "忽略蕨类", config_key = "PICKUP_IGNORE_FERNS" },
            { type = "toggle", label = "忽略多肉", config_key = "PICKUP_IGNORE_SUCCULENTS" },
            { type = "toggle", label = "忽略沼泽灌木", config_key = "PICKUP_IGNORE_MARSH_BUSH" },
            { type = "toggle", label = "动作屏蔽", config_key = "ACTIONS_BLOCK" },
        } },
    { conf = "TELEPOOF_OPTIONS", label = "传送选项", icon = "purplegem",
        hint = "配置传送特效选项",
        sub = {
            -- on_toggle：这三项都影响 STRINGS.ACTIONS.BLINK 的悬停文本（"传送 (Disabled)" / 剩余点击数），
            -- 由 telepoof 统一渲染。不刷新的话提示会停留在旧状态（原先的开关键位入口已刷新，HUD 入口漏了）。
            { type = "toggle", label = "默认禁用传送", config_key = "TELEPOOF_DISABLED",
                on_toggle = function() MOD_EQUIPMENT_CONTROL.RefreshTelepoofDisplay() end },
            { type = "toggle", label = "隐藏悬浮提示", config_key = "TELEPOOF_HOVER" },
            { type = "toggle", label = "沃拓克斯跳跃", config_key = "TELEPOOF_WORTOX",
                on_toggle = function() MOD_EQUIPMENT_CONTROL.RefreshTelepoofDisplay() end },
        } },
    { conf = "QUICK_ACTIONS", label = "快捷动作", icon = "axe",
        hint = "配置快捷动作选项",
        sub = {
            { type = "toggle", label = "剃牛毛",         config_key = "QUICK_ACTION_BEEFALO" },
            { type = "toggle", label = "熄火",           config_key = "QUICK_ACTION_EXTINGUISH" },
            { type = "toggle", label = "喂鸟",           config_key = "QUICK_ACTION_FEED_BIRD" },
            { type = "toggle", label = "唤醒鸟",         config_key = "QUICK_ACTION_WAKEUP_BIRD" },
            { type = "toggle", label = "囚禁鸟",         config_key = "QUICK_ACTION_IMPRISON_BIRD" },
            { type = "toggle", label = "装瓶",           config_key = "QUICK_ACTION_BOTTLESSOUL" },
            { type = "toggle", label = "建造化石",       config_key = "QUICK_ACTION_BUILD_FOSSIL" },
            { type = "toggle", label = "解锁赃物袋",     config_key = "QUICK_ACTION_KLAUS_SACK" },
            { type = "toggle", label = "远古钥匙",       config_key = "QUICK_ACTION_ATRIUM_GATE" },
            { type = "toggle", label = "修船",           config_key = "QUICK_ACTION_REPAIR_BOAT" },
            { type = "toggle", label = "追踪脚印",       config_key = "QUICK_ACTION_DIRTPILE" },
            { type = "toggle", label = "吞噬者",         config_key = "QUICK_ACTION_DEVOURER" },
            { type = "toggle", label = "污染血糖",       config_key = "QUICK_ACTION_MEDAL_POLLUTE" },
            { type = "toggle", label = "种曼德拉",       config_key = "QUICK_ACTION_MEDAL_PLANT_MANDRAKE" },
            { type = "toggle", label = "埋绿宝石",       config_key = "QUICK_ACTION_MEDAL_BURY_GREENGEM" },
            { type = "toggle", label = "嫁接升级",       config_key = "QUICK_ACTION_MEDAL_TREE_LEVEL_UP" },
            { type = "toggle", label = "旋花藤",         config_key = "QUICK_ACTION_MEDAL_WORMWOOD_FLOWER" },
            { type = "toggle", label = "强制冷却",       config_key = "QUICK_ACTION_MEDAL_MAKE_COOLDOWN" },
            { type = "toggle", label = "研磨",           config_key = "QUICK_ACTION_MEDAL_GRINDING" },
            { type = "toggle", label = "调味",           config_key = "QUICK_ACTION_MEDAL_CHEFFLAVOUR" },
            { type = "toggle", label = "吃调味料",       config_key = "QUICK_ACTION_MEDAL_EAT_SPICES" },
            { type = "toggle", label = "吸收黑暗灵魂",   config_key = "QUICK_ACTION_MEDAL_SOUL_ABSORB" },
            { type = "toggle", label = "黑暗灵魂自动",   config_key = "QUICK_ACTION_MEDAL_SOUL_AUTO" },
        } },

    --==========================================================================
    -- 几何对齐：复用官方轴对齐系统；顶点模式让网格显示在网格线（顶点）上
    -- 需在游戏原版设置开启「建筑对齐」才会生效（placer 才有 axisalignedhelpers）
    -- 间距档位统一走官方自带的「切换对齐网格」键，不按物品细分
    --==========================================================================
    { conf = "GRIDALIGN", label = "几何对齐", icon = "turf_woodfloor",
        hint = "让建筑对齐网格显示在网格线（顶点）上；原版设置需开启「建筑对齐」\n间距档位用官方「切换对齐网格」键切换",
        sub = (function()
            -- 懒引用：confighud 先于 Auto/gridalign 加载，此处只能在点击时取
            local function refresh()
                if MOD_EQUIPMENT_CONTROL.RefreshGridAlign then
                    MOD_EQUIPMENT_CONTROL.RefreshGridAlign()
                end
            end
            return {
                { type = "toggle", label = "总开关",       config_key = "GRIDALIGN_ENABLED", on_toggle = refresh },
                { type = "toggle", label = "对齐网格顶点", config_key = "GRIDALIGN_VERTEX", on_toggle = refresh },
                { type = "toggle", label = "16x16 小网格", config_key = "GRIDALIGN_GRID16", on_toggle = refresh },
                { type = "toggle", label = "船下水显示网格", config_key = "GRIDALIGN_BOAT" },
                { type = "toggle", label = "建造对齐",     config_key = "GRIDALIGN_BUILD",  on_toggle = refresh },
                { type = "toggle", label = "部署对齐",     config_key = "GRIDALIGN_DEPLOY", on_toggle = refresh },
                { type = "toggle", label = "丢弃对齐",     config_key = "GRIDALIGN_DROP",   on_toggle = refresh },
                { type = "toggle", label = "隐藏建造虚影", config_key = "GRIDALIGN_HIDEPLACER" },
                { type = "toggle", label = "隐藏物品耐久", config_key = "GRIDALIGN_HIDEPERCENT" },
                { type = "toggle", label = "隐藏物品数量", config_key = "GRIDALIGN_HIDEQUANTITY" },
                { type = "toggle", label = "半透明网格",   config_key = "GRIDALIGN_TRANSPARENCY" },
                { type = "slider", label = "透明度",       config_key = "GRIDALIGN_TRANSPARENCY",
                  value_key = "GRIDALIGN_ALPHA", min = 0.1, max = 1.0, step = 0.05 },
            }
        end)() },

    --==========================================================================
    -- 巨石躲避：岩石树即将砸下巨石时自动走开躲避
    --==========================================================================
    { conf = "BOULDER_DODGE", label = "巨石躲避", icon = "rocks",
        hint = "岩石树即将砸下巨石时自动走开躲避",
        sub = {
            { type = "toggle", label = "巨石躲避总开关", config_key = "BOULDER_DODGE" },
            { type = "slider", label = "躲避余量", value_key = "DODGE_MARGIN",
                min = 0, max = 3, step = 0.5,
                label_format = function(v) return string.format("%.1f", v) end },
            { type = "toggle", label = "手动移动覆盖", config_key = "DODGE_MANUAL_OVERRIDE" },
            { type = "toggle", label = "自动切手杖加速", config_key = "DODGE_USE_CANE" },
            { type = "slider", label = "砍倒刀数(0=自动)", value_key = "DODGE_CHOPS_OVERRIDE",
                min = 0, max = 20, step = 1,
                label_format = function(v) return v == 0 and MOD_EQUIPMENT_CONTROL.STRINGS.CONFIG.DODGE_AUTO or tostring(v) end },
        } },
    { conf = "CHEST_MEMORY", label = "箱子记忆", icon = "treasurechest",
        hint = "无需打开即可查看箱内物品；支持历史浏览和物品高亮",
        sub = {
            { type = "toggle", label = "箱子记忆总开关", config_key = "CHEST_MEMORY_ENABLED",
                on_toggle = function()
                    MOD_EQUIPMENT_CONTROL.SetChestMemoryEnabled(
                        MOD_EQUIPMENT_CONTROL.CONFIG.CHEST_MEMORY_ENABLED)
                end },
            { type = "action", label = function()
                local strings = MOD_EQUIPMENT_CONTROL.STRINGS
                local mode = MOD_EQUIPMENT_CONTROL.CONFIG.CHEST_MEMORY_DISPLAY_TYPE or "all"
                return string.format(strings.PROMPTS.CHEST_MEMORY_DISPLAY_BUTTON,
                    strings.CHEST_MEMORY_DISPLAY[string.upper(mode)] or mode)
            end, icon = "treasurechest",
                fn = function() MOD_EQUIPMENT_CONTROL.CycleChestMemoryDisplay() end },
        } },
}

local ConfigHUD = Class(Widget, function(self, owner, is_left_aligned, dock)
    Widget._ctor(self, "ConfigHUD")

    self.owner = owner
    -- dock: nil => 挂锚点(用局部原点，右贴边)；"center" => 直接挂 controls 且居中；"right" => 直接挂 controls 且右贴边
    self.dock = dock
    self.centered = dock == "center"
    self.screen_right = dock == "right"
    local is_left = (not self.centered and not self.screen_right) and (is_left_aligned ~= false)

    local y_offset = IsSplitScreen() and -50 or 0
    self.root = self:AddChild(Widget("ConfigHUD_Root"))

    -- 镜头缩放防护标记：鼠标悬停在本面板上时，modmain 的 ZoomIn/ZoomOut 拦截器
    -- 会变空操作，滚轮改由面板内滑条/网格接管（鼠标离开面板则恢复正常缩放）。
    self._ec_zoom_capture = true

    if self.centered then
        -- 居中：root 不平移，靠 self 整体定位到屏幕中心像素；tab 作为面板右上角把手
        self.closed_pos = Vector3(0, 0, 0)
        self.opened_pos = Vector3(0, 0, 0)
        self.root:SetPosition(0, 0, 0)
        self.tabbar = self.root:AddChild(Widget("ConfigHUD_TabBar"))
        self.tabbar:SetScale(1)
        self.tabbar:SetPosition(0, 0)
        self.tab_button = self.tabbar:AddChild(ImageButton(CRAFTING_ATLAS, "crafting_tab.tex", "crafting_tab.tex", nil, nil, nil, {1,1}, {0,0}))
        self.tab_button:SetPosition(FRAME_W / 2 + 18, FRAME_H / 2 + 18)
        self.tab_button:SetNormalScale(0.4, 0.4)
        self.tab_button:SetFocusScale(0.45, 0.45)
        self.body = self.root:AddChild(Widget("ConfigHUD_Body"))
        self.body:SetPosition(0, 0)
    else
        -- 右贴边（screen_right / 旧锚点模式通用）：self 原点=屏幕右缘中点（right_root 为 ANCHOR_RIGHT+ANCHOR_MIDDLE）。
        -- 真·官方旅行：把手与面板同属 root（一个滑动容器），一起平移；
        --   关时把手在右缘、面板推到屏幕外；开时面板外缘贴右缘、把手落在其内侧（左侧）边缘，二者始终成一整体移动。
        self.closed_pos = Vector3(-TAB_OUTER, 0, 0) -- 关：把手(局部 0)内缩 TAB_OUTER；面板在屏幕外且 body:Hide()
        self.opened_pos = Vector3(-OPENED_X, 0, 0)  -- 开：root 左移 OPENED_X，面板外缘正好落在屏幕右缘
        self.root:SetPosition(self.closed_pos:Get())

        -- 面板：外缘贴屏幕右缘；把手在其内侧（左侧）边缘
        self.body = self.root:AddChild(Widget("ConfigHUD_Body"))
        self.body:SetPosition(FRAME_W / 2 + 10, 0)  -- 局部：面板中心在把手右侧，左缘与把手重叠拼接

        -- 把手（与面板同属 root，随面板一起平移；关在屏幕内缘、开在面板内缘）
        self.tabbar = self.root:AddChild(Widget("ConfigHUD_TabBar"))
        self.tabbar:SetScale(1)
        self.tabbar:SetPosition(0, 0)               -- root 局部原点：关时(closed_pos)落在屏幕内，开时(opened_pos)在面板内缘
        self.tab_button = self.tabbar:AddChild(ImageButton(CRAFTING_ATLAS, "crafting_tab.tex", "crafting_tab.tex", nil, nil, nil, {1,1}, {0,0}))
        self.tab_button:SetPosition(0, 0)
        self.tab_button:SetNormalScale(-0.4, 0.4)   -- 左右镜像翻转（把手在面板左侧、nub 朝左指向面板）
        self.tab_button:SetFocusScale(-0.45, 0.45)
    end

    ---------------------------------------------------------------------------
    -- 悬停滤镜的静态预览图：用覆盖层美术铺满全屏、垫在 HUD 底层；不放独立 UI，
    -- 也不实时驱动后处理（避免 HWEffect.cpp 崩溃）。按钮仍在中层可见可点。
    -- 真正的 Image 在首次 PreviewFilter 时挂到 playerhud 根（屏幕正中、位于 controls 之下），
    -- 用 SCALEMODE_FILLSCREEN 居中铺满并 MoveToBack，避开本 HUD 挂在 right_root 上被偏移/缩放的影响。
    ---------------------------------------------------------------------------
    self.preview_img = nil

    self.collapsed = true
    self.tab_button:SetOnClick(function()
        self:Toggle()
    end)
    self.tab_button:SetHoverText("功能配置（点击展开/收起）", { offset_y = 50 })

    ---------------------------------------------------------------------------
    -- 面板拼接：完全照官方 CraftingMenuWidget:MakeFrame（craftingmenu_widget.lua:553-584）
    ---------------------------------------------------------------------------
    self.fill = self.body:AddChild(Image(CRAFTING_ATLAS, "backing.tex"))
    self.fill:ScaleToSize(FRAME_W + 10, FRAME_H + 18)
    self.fill:SetTint(1, 1, 1, 0.5)

    self.side_left = self.body:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.side_left:SetPosition(-FRAME_W / 2 - SIDE_INSET, 1)
    self.side_left:ScaleToSize(-SIDE_W, -(FRAME_H - 20))

    self.side_right = self.body:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.side_right:SetPosition(FRAME_W / 2 + SIDE_INSET, 1)
    self.side_right:ScaleToSize(SIDE_W, FRAME_H - 20)
    self.side_right:SetClickable(false)

    self.frame_top = self.body:AddChild(Image(CRAFTING_ATLAS, "top.tex"))
    self.frame_top:SetPosition(0, FRAME_H / 2 + 10)
    self.frame_top:ScaleToSize(TOPBAR_W, 38)
    self.frame_top:SetClickable(false)

    self.frame_bottom = self.body:AddChild(Image(CRAFTING_ATLAS, "bottom.tex"))
    self.frame_bottom:SetPosition(0, -FRAME_H / 2 - 8)
    self.frame_bottom:ScaleToSize(TOPBAR_W, 38)
    self.frame_bottom:SetClickable(false)

    self._tiles = {}                         -- feature => { button = ImageButton, w = 缩放壳 }

    ---------------------------------------------------------------------------
    -- 分类栏：完全照官方 MakeFilterPanel 的锚法与间距（面板原点在顶部，内部 y 向下递减）
    ---------------------------------------------------------------------------
    self.catpanel = self.body:AddChild(Widget("ConfigHUD_CatPanel"))
    self.catpanel:SetPosition(0, FRAME_H / 2 - 20)   -- 官方 self.filter_panel:SetPosition(0, height/2 - 20)

    -- 标题：占据官方首行按钮行的位置
    self.title = self.catpanel:AddChild(Text(CHATFONT, 22, "功能配置"))
    self.title:SetPosition(0, CAT_TOP_Y)
    self.title:SetColour(0.95, 0.86, 0.62, 1)

    -- 面板内横隔线：官方用 images/ui.xml 的 line_horizontal_white.tex + unpack(BROWN)
    local cat_div = self.catpanel:AddChild(Image(UI_ATLAS, "line_horizontal_white.tex"))
    cat_div:SetPosition(0, CAT_DIV_Y - CAT_DIV_H / 2)
    cat_div:ScaleToSize(PANEL_W, CAT_DIV_H)
    cat_div:SetTint(LINE_R, LINE_G, LINE_B, LINE_A)
    cat_div:SetClickable(false)
    cat_div:MoveToBack()

    local cat_grid = self.catpanel:AddChild(Grid())
    cat_grid:SetLooping(false, false)
    local cat_widgets = {}
    for i, feature in ipairs(FEATURES) do
        local w = Widget("filter_" .. i)
        w:SetScale(BTN_SIZE / 64)                -- 官方 w:SetScale(button_size/64)

        local button = w:AddChild(ImageButton(CRAFTING_ATLAS, "filterslot_frame.tex", "filterslot_frame_highlight.tex", nil, nil, "filterslot_frame_select.tex"))
        button.scale_on_focus = false
        button.move_on_click = false

        local tex = tostring(feature.icon or "") .. ".tex"
        local atlas = GetInventoryItemAtlas(tex)   -- 无回退：缺图直接报错，便于定位
        local img = button:AddChild(Image(atlas, tex))
        img:ScaleToSize(CAT_ICON, CAT_ICON)
        img:SetClickable(false)
        img:MoveToBack()

        w.focus_forward = button               -- 焦点从 Grid→wrapper 转发到内部按钮
        button:SetOnClick(function()
            self:ToggleFeature(feature)
        end)
        w:SetHoverText(feature.label .. (feature.hint and ("：" .. feature.hint) or ""), { offset_y = 30 })

        self._tiles[feature] = { button = button, w = w }
        table.insert(cat_widgets, w)
    end
    cat_grid:FillGrid(BTN_COLS, BTN_SPACE, BTN_SPACE, cat_widgets)
    cat_grid:SetPosition(GRID_LEFT, CAT_GRID_Y)
    self.cat_grid = cat_grid
    self.cat_widgets = cat_widgets

    -- 官方 panel_height = 55 + grid_button_space * num_rows + 6
    local cat_h = -CAT_GRID_Y + BTN_SPACE * cat_grid.num_rows + CAT_TAIL
    self.cat_h = cat_h

    ---------------------------------------------------------------------------
    -- 分类栏与子配置之间的拼接件：官方 itemlist_split
    ---------------------------------------------------------------------------
    local split1 = self.body:AddChild(Image(CRAFTING_ATLAS, "horizontal_bar.tex"))
    split1:SetPosition(0, FRAME_H / 2 - cat_h)
    split1:ScaleToSize(502, 15)
    split1:SetClickable(false)

    ---------------------------------------------------------------------------
    -- 子配置面板：官方 MakeRecipeList 的几何（60 格 / 66 总距 / 7 列 / peek 0.5）
    ---------------------------------------------------------------------------
    self.subpanel = self.body:AddChild(Widget("ConfigHUD_SubPanel"))   -- 原点与 body 重合
    self.active_feature = nil

    local scissor_h = CELL_PITCH * SUB_ROWS + CELL_PITCH * PEEK
    local grid_y    = FRAME_H / 2 - cat_h - scissor_h / 2
    self.sub_grid_y = grid_y
    self.sub_grid_h = scissor_h

    local split2 = self.body:AddChild(Image(CRAFTING_ATLAS, "horizontal_bar.tex"))
    split2:SetPosition(0, FRAME_H / 2 - cat_h - scissor_h - 2)
    split2:ScaleToSize(502, 15)
    split2:SetClickable(false)

    -- 底部说明区：官方 details_root 的位置，放当前选中功能的名称与提示
    self.detail_label = self.body:AddChild(Text(CHATFONT, 24, ""))
    self.detail_label:SetPosition(0, FRAME_H / 2 - cat_h - scissor_h - 40)
    self.detail_label:SetColour(0.95, 0.86, 0.62, 1)

    self.detail_hint = self.body:AddChild(Text(CHATFONT, 18, ""))
    self.detail_hint:SetPosition(0, FRAME_H / 2 - cat_h - scissor_h - 68)
    self.detail_hint:SetColour(0.82, 0.78, 0.68, 1)
    self.detail_hint:SetRegionSize(FRAME_W - 60, 60)
    self.detail_hint:SetHAlign(ANCHOR_MIDDLE)

    -- 初始为收起：直接定位，不播动画也不发声（Open/Close 只用于运行时切换）
    self.is_open = false
    self.collapsed = true
    self.body:Hide()          -- 收起时彻底隐藏面板，避免常驻巨面板
    self:MoveToFront()        -- 提到 controls 最前，避免被其他 HUD（背包/制作栏）遮挡

    if self.centered then
        -- centered 模式（极少用）：自行按屏幕尺寸/缩放定位，并在变化时重定位
        self:Reposition()
        self:StartUpdating()
    else
        -- right 模式：self 挂在 right_root（原点=屏幕右中、自带HUD缩放），落位即贴边，无需逐帧重定位
        self:Reposition()
    end
end)

-- 点击分类格：展开/收起其子配置面板
function ConfigHUD:ToggleFeature(feature)
    if self.active_feature == feature then
        self.active_feature = nil
    else
        self:ShowSubPanel(feature)
        self:MoveToFront()     -- 展开子配置时置顶，避免被其他 UI 遮挡
    end
    self:_HighlightTiles()
end

-- 高亮当前展开的主配置 tile：换用官方 filterslot_frame_select.tex 贴图。
--
-- 注意：不能用官方的 ImageButton:Select()。Button:IsFocusedState() = focus and enabled and not selected，
-- 一旦 Select() 该按钮就再也不能被点击/聚焦（button.lua:225、imagebutton.lua:115），
-- 而本 HUD 需要「再点一次活跃分类格收回子配置」。所以只套用官方贴图，不进入 Selected 状态：
-- 直接改 image_normal，OnLoseFocus 恢复时拿到的就是选择态贴图（imagebutton.lua:151）。
function ConfigHUD:_HighlightTiles()
    if not self._tiles then return end
    for f, t in pairs(self._tiles) do
        local tex = (f == self.active_feature) and "filterslot_frame_select.tex" or "filterslot_frame.tex"
        t.button.image_normal = tex
        if not t.button:IsFocusedState() then
            t.button.image:SetTexture(CRAFTING_ATLAS, tex)
        end
    end
end

-------------------------------------------------------------------------------
-- 悬停静态预览：只显示该滤镜覆盖层美术的静态代表图，不实时驱动后处理。
-- 没有对应静态图的滤镜（色彩立方 / 扭曲 / 泛光等）直接跳过，悬停无预览。
-------------------------------------------------------------------------------
function ConfigHUD:PreviewFilter(key)
    local p = MOD_EQUIPMENT_CONTROL.FILTER_PREVIEW[key]
    if p == nil then return end
    if self.preview_img == nil then
        -- 挂到 playerhud 根（屏幕正中、位于 controls 之下）：避开本 HUD 挂在 right_root
        -- 上的偏移/缩放，让 SCALEMODE_FILLSCREEN 能按屏幕正中居中铺满；MoveToBack 垫在面板底层。
        -- 不能在 _ctor 里做，因为那时父链还没建立（AddChild 在构造之后才执行）。
        local phroot = self:GetParent() and self:GetParent():GetParent() or self
        self.preview_img = phroot:AddChild(Image("images/fx.xml", "ice_over.tex"))
        -- 全屏铺底三件套（照官方 playerhud.lua 的 moonstormdust / serverpause_underlay）：
        -- FILLSCREEN 负责缩放到铺满，MIDDLE 锚点负责钉在父节点（playerhud 屏幕居中根）正中。
        -- 只设 ScaleMode 不设锚点会停在父节点局部原点（被 right_root 偏移）→ 跑到左下角。
        self.preview_img:SetScaleMode(SCALEMODE_FILLSCREEN)
        self.preview_img:SetHAnchor(ANCHOR_MIDDLE)
        self.preview_img:SetVAnchor(ANCHOR_MIDDLE)
        self.preview_img:SetClickable(false)
        self.preview_img:MoveToBack()      -- 垫在面板/按钮之下
        self.preview_img:Hide()
    end
    self.preview_img:SetTexture(p.atlas, p.tex)
    self.preview_img:Show()
end

function ConfigHUD:HideFilterPreview()
    if self.preview_img ~= nil then self.preview_img:Hide() end
end

-- 构建并显示某功能的子配置网格（官方 MakeRecipeList 写法：TEMPLATES.ScrollingGrid + 复用格子）
function ConfigHUD:ShowSubPanel(feature)
    self.subpanel:KillAllChildren()
    self.subpanel:Show()
    self.active_feature = feature

    self.detail_label:SetString(feature.label or "")
    self.detail_hint:SetString(feature.hint or "")

    local sub = feature.sub
        or (feature.get_state and { { type = "toggle", label = "启用状态", get_state = true } })
        or {}

    -- 转成配方格数据；type == "info" 的纯说明项不进网格（官方配方格没有常驻文字）
    --
    -- ⚠ 开关状态必须存**取值函数**而不是布尔快照：点击后的原地刷新走 grid:RefreshView()，
    -- 它只用同一张 data 表重新调用 apply_fn（truescrolllist.lua:452），
    -- 存布尔的话刷完还是旧值，只有整表重建（切分类/重开 HUD）才看得到变化。
    local items = {}
    local sliders = {}   -- slider 类型不进网格，统一在网格下方渲染
    for _, it in ipairs(sub) do
        if it.type ~= "info" and it.type ~= "slider" then
            local ic = it.icon or feature.icon
            local atlas, tex
            if type(ic) == "table" then
                atlas, tex = ic[1], ic[2]     -- 不在物品图集里的，直接指定图集
            else
                tex = tostring(ic) .. ".tex"
                atlas = GetInventoryItemAtlas(tex)   -- 官方查图集，缺图直接报错，便于定位
            end

            local get_on = nil
            if it.type == "toggle" then
                if it.filter_key then
                    get_on = function()
                        return MOD_EQUIPMENT_CONTROL.IsFilterRemoved(it.filter_key)
                    end
                elseif it.config_key then
                    get_on = function()
                        return MOD_EQUIPMENT_CONTROL.CONFIG[it.config_key]
                    end
                elseif it.get_state then
                    get_on = function()
                        return feature.get_state and feature.get_state()
                    end
                end
            end

            local onclick = nil
            if it.type == "action" then
                -- 优先使用直接 fn 回调，否则通过 KeybindService 触发
                if it.fn then
                    onclick = it.fn
                else
                    onclick = function()
                        MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE:Trigger(it.conf or feature.conf)
                    end
                end
            elseif it.type == "toggle" then
                onclick = function()
                    if it.filter_key then
                        MOD_EQUIPMENT_CONTROL.SetFilterRemoved(it.filter_key, not MOD_EQUIPMENT_CONTROL.IsFilterRemoved(it.filter_key))
                    elseif it.config_key then
                        MOD_EQUIPMENT_CONTROL.CONFIG[it.config_key] = not MOD_EQUIPMENT_CONTROL.CONFIG[it.config_key]
                        if MOD_EQUIPMENT_CONTROL.ConfigSave then MOD_EQUIPMENT_CONTROL.ConfigSave() end   -- 即时落盘，保证持久化
                        -- 可选：翻转后的副作用刷新（如几何对齐需重建对齐动作集 / 插撤官方网格档位）
                        if it.on_toggle then it.on_toggle() end
                    elseif feature.get_state then
                        MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE:Trigger(feature.conf)
                    end
                end
            end

            table.insert(items, {
                label      = it.label,
                type       = it.type,
                filter_key = it.filter_key,   -- 非 nil => 悬停时演示该滤镜「挡住什么画面」
                atlas      = atlas,
                icon       = tex,
                get_on     = get_on,
                onclick    = onclick,
            })
        elseif it.type == "slider" then
            table.insert(sliders, it)
        end
    end

    local grid   -- 前置声明，供 CellCtor 的点击回调引用

    local function CellCtor(context, index)
        local w = Widget("cfg-cell-" .. index)
        w:SetScale(CELL_SCALE)                     -- 官方 w:SetScale(0.475)

        w.cell_root = w:AddChild(ImageButton(CRAFTING_ATLAS, "slot_frame.tex", "slot_frame_highlight.tex"))
        w.focus_forward = w.cell_root

        w.bg = w.cell_root:AddChild(Image(CRAFTING_ATLAS, "slot_bg.tex"))
        w.item_img = w.bg:AddChild(Image())
        w.item_img:ScaleToSize(CELL_ICON, CELL_ICON)
        w.item_img:SetClickable(false)
        w.fg = w.bg:AddChild(Image(CRAFTING_ATLAS, "slot_fg_lock.tex"))   -- 官方「未解锁」角标
        w.fg:SetClickable(false)
        w.fg:Hide()
        w.bg:MoveToBack()

        w.cell_root:SetOnClick(function()
            if w.data and w.data.onclick then
                w.data.onclick()
            end
            -- 原地刷新（重算可见格的状态底图/角标），避免整页重建导致 hover 焦点丢失
            if grid ~= nil then grid:RefreshView() end
        end)

        -- 悬停预览：用该滤镜的静态代表图铺满全屏、垫在底层（不实时驱动后处理，绝不崩）。
        -- 只读 w.data 而不捕获构建期的 data：滚动列表会复用格子（apply_fn 重写 w.data），
        -- 捕获旧 data 会预览到错误的滤镜上。无对应静态图的滤镜（色彩立方/扭曲/泛光等）跳过。
        w.cell_root:SetOnGainFocus(function()
            local d = w.data
            if d ~= nil and d.filter_key ~= nil then
                self:PreviewFilter(d.filter_key)
            end
        end)
        w.cell_root:SetOnLoseFocus(function()
            self:HideFilterPreview()
        end)

        return w
    end

    local function CellSetData(context, widget, data, index)
        if data == nil then
            widget:Disable()
            widget.cell_root:Hide()
            widget.data = nil
            return
        end

        widget:Enable()
        widget.cell_root:Show()
        widget.item_img:SetTexture(data.atlas, data.icon)
        widget.item_img:ScaleToSize(CELL_ICON, CELL_ICON)
        widget.cell_root:SetHoverText(type(data.label) == "function" and data.label() or data.label)

        local on = data.get_on and data.get_on()   -- 每次 apply 实时取值，不用构建期快照

        if data.type == "toggle" and on == false then
            -- 官方 build_state = "hint"：格底换缺料贴图、图标压暗到 0.7、盖锁定角标（craftingmenu_widget.lua:1063-1068）
            widget.bg:SetTexture(CRAFTING_ATLAS, "slot_bg_missing_mats.tex")
            widget.item_img:SetTint(0.7, 0.7, 0.7, 1)
            widget.fg:Show()
        else
            -- 官方 meta.can_build：普通格底、图标原色、无角标
            widget.bg:SetTexture(CRAFTING_ATLAS, "slot_bg.tex")
            widget.item_img:SetTint(1, 1, 1, 1)
            widget.fg:Hide()
        end

        widget.data = data
    end

    grid = TEMPLATES.ScrollingGrid(items, {
        context               = {},
        widget_width          = CELL_PITCH,        -- 官方 row_w + row_spacing = 66
        widget_height         = CELL_PITCH,
        peek_percent          = PEEK,
        num_visible_rows      = SUB_ROWS,
        num_columns           = SUB_COLS,
        item_ctor_fn          = CellCtor,
        apply_fn              = CellSetData,
        scrollbar_offset      = SB_OFFSET,
        scrollbar_height_offset = SB_HOFFSET,
    })

    -- 滚动条装饰：完全照官方 MakeRecipeList 尾部
    grid.up_button:SetTextures(CRAFTING_ATLAS, "scrollbar_arrow_up.tex", "scrollbar_arrow_up_hl.tex")
    grid.up_button:SetScale(0.4)
    grid.down_button:SetTextures(CRAFTING_ATLAS, "scrollbar_arrow_down.tex", "scrollbar_arrow_down_hl.tex")
    grid.down_button:SetScale(0.4)
    grid.scroll_bar_line:SetTexture(CRAFTING_ATLAS, "scrollbar_bar.tex")
    grid.scroll_bar_line:ScaleToSize(11, grid.scrollbar_height - 15)
    grid.position_marker:SetTextures(CRAFTING_ATLAS, "scrollbar_handle.tex")
    grid.position_marker.image:SetTexture(CRAFTING_ATLAS, "scrollbar_handle.tex")
    grid.position_marker:SetScale(.3)

    grid:SetPosition(0, self.sub_grid_y)   -- 官方 recipe_grid: SetPosition(-2, height/2 - filters_height - grid_h/2)
    self._subgrid = grid
    self.subpanel:AddChild(grid)           -- 关键：必须挂进树，否则整张网格是孤儿节点、格子与滚动条都不渲染

    -- 滑条：网格下方渲染（不进配方格，独占一行）
    for _, sl in ipairs(sliders) do
        self:BuildSlider(sl)
    end

    self:DoFocusHookups()                  -- 子面板重建后重连焦点跳转
end
-- 构建横向滑条：轨道/把手复用官方滚动条素材（scrollbar_bar / scrollbar_handle），
-- 左右箭头用 ui.xml 的 crafting_inventory_arrow_l/r（制作栏翻页粗箭头，指向左右），
-- 交互逻辑沿袭模组自身的「点击跳转 + 箭头步进」
-- sl = { label, config_key, value_key, min, max, step }
function ConfigHUD:BuildSlider(sl)
    local SLIDER_W  = 300
    local TRACK_H   = 11

    local w = self.subpanel:AddChild(Widget("cfg_slider_" .. (sl.value_key or "x")))

    -- 左箭头（递减）：crafting_inventory_arrow_l（制作栏左右翻页的粗箭头，比 Spinner 细箭头更醒目）
    -- 该贴图原生 UV 偏小（0.0308 vs 0.0483），放大到 0.62 保持与原箭头同屏尺寸。
    local left_btn = w:AddChild(ImageButton())
    left_btn:SetTextures(UI_ATLAS, "crafting_inventory_arrow_l_idle.tex", nil, "crafting_inventory_arrow_l_hl.tex", "crafting_inventory_arrow_l_idle.tex")
    left_btn:SetScale(0.62, 0.62)
    left_btn.scale_on_hover = false

    -- 右箭头（递增）：crafting_inventory_arrow_r
    local right_btn = w:AddChild(ImageButton())
    right_btn:SetTextures(UI_ATLAS, "crafting_inventory_arrow_r_idle.tex", nil, "crafting_inventory_arrow_r_hl.tex", "crafting_inventory_arrow_r_idle.tex")
    right_btn:SetScale(0.62, 0.62)
    right_btn.scale_on_hover = false

    -- 轨道底板：scrollbar_bar.tex（官方素材，纯视觉，不参与交互）
    local track_img = w:AddChild(Image(CRAFTING_ATLAS, "scrollbar_bar.tex"))
    track_img:ScaleToSize(SLIDER_W, TRACK_H)
    track_img:SetClickable(false)

    -- 把手：scrollbar_handle.tex（官方素材，缩放到 0.3 与官方一致）
    local knob = w:AddChild(Image(CRAFTING_ATLAS, "scrollbar_handle.tex"))
    knob:SetScale(0.3)
    knob:SetClickable(false)

    -- 点击热区：透明 square 铺满轨道 2 倍高度（不可见、无颜色，只管接收点击）
    -- ⚠ ImageButton:SetTextures 里 image:ScaleToSize 不改变按钮自身可点范围，
    -- 必须用独立 square 充当热区（alpha=0），才能在 300×22 区域内正常响应点击。
    local click_area = w:AddChild(ImageButton("images/global.xml", "square.tex"))
    click_area.image:SetTint(0, 0, 0, 0)
    click_area.image:ScaleToSize(SLIDER_W, TRACK_H * 2)
    click_area.scale_on_hover = false
    click_area:MoveToBack()

    -- 标签：左边名称，右边百分比
    local lbl_name = w:AddChild(Text(CHATFONT, 16, sl.label or ""))
    lbl_name:SetColour(LINE_R, LINE_G, LINE_B, 1)
    lbl_name:SetHAlign(ANCHOR_LEFT)
    local lbl_pct = w:AddChild(Text(CHATFONT, 16, ""))
    lbl_pct:SetColour(LINE_R, LINE_G, LINE_B, 1)
    lbl_pct:SetHAlign(ANCHOR_RIGHT)

    local function GetMax()
        local max = type(sl.max) == "function" and sl.max() or sl.max
        return math.max(sl.min, max or sl.min)
    end

    -- 统一刷新：把手 X 位置 + 百分比文字
    local function Refresh()
        local max = GetMax()
        local v = MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] or sl.min
        v = math.clamp(v, sl.min, max)
        local range = max - sl.min
        local pct = range > 0 and math.clamp((v - sl.min) / range, 0, 1) or 0
        knob:SetPosition(-SLIDER_W / 2 + pct * SLIDER_W, 0)
        if sl.label_format then
            lbl_pct:SetString(sl.label_format(v))
        else
            lbl_pct:SetString(string.format("%d%%", math.floor(v * 100 + 0.5)))
        end
    end

    local function AfterChange(newval)
        Refresh()
        if sl.fn then sl.fn(newval) end
        if self._subgrid then self._subgrid:RefreshView() end
    end

    -- 点击轨道：从鼠标 X 换算百分比
    click_area:SetOnClick(function()
        local sp = TheInput:GetScreenPosition()
        local wx, wy = w.inst.UITransform:GetWorldPosition()
        local scale = w:GetScale():Get()
        local lx = (sp.x - wx) / scale
        local pct = math.clamp((lx + SLIDER_W / 2) / SLIDER_W, 0, 1)
        local max = GetMax()

        local newval = math.clamp(
            math.floor((pct * (max - sl.min) + sl.min) / sl.step + 0.5) * sl.step,
            sl.min, max
        )
        MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] = newval
        if MOD_EQUIPMENT_CONTROL.ConfigSave then MOD_EQUIPMENT_CONTROL.ConfigSave() end
        AfterChange(newval)
    end)

    -- 左按钮：每次减一个步长
    left_btn:SetOnClick(function()
        local max = GetMax()
        local newval = math.clamp((MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] or sl.min) - sl.step, sl.min, max)
        MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] = newval
        if MOD_EQUIPMENT_CONTROL.ConfigSave then MOD_EQUIPMENT_CONTROL.ConfigSave() end
        AfterChange(newval)
    end)

    -- 右按钮：每次加一个步长
    right_btn:SetOnClick(function()
        local max = GetMax()
        local newval = math.clamp((MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] or sl.min) + sl.step, sl.min, max)
        MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] = newval
        if MOD_EQUIPMENT_CONTROL.ConfigSave then MOD_EQUIPMENT_CONTROL.ConfigSave() end
        AfterChange(newval)
    end)

    -- 滚轮调值：鼠标停在滑条上时滚动滚轮步进一个步长（up=+step / down=-step）。
    -- 只有滚轮真正落在滑条上才触发；面板其余区域的缩放由 modmain 的悬停拦截统一吞掉。
    w.OnMouseButton = function(slider, button, down, x, y)
        if down and (button == MOUSEBUTTON_SCROLLUP or button == MOUSEBUTTON_SCROLLDOWN) then
            local max = GetMax()
            local cur = MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] or sl.min
            local newval = cur + (button == MOUSEBUTTON_SCROLLUP and sl.step or -sl.step)
            newval = math.clamp(newval, sl.min, max)
            if newval ~= cur then
                MOD_EQUIPMENT_CONTROL.CONFIG[sl.value_key] = newval
                if MOD_EQUIPMENT_CONTROL.ConfigSave then MOD_EQUIPMENT_CONTROL.ConfigSave() end
                AfterChange(newval)
            end
            return true
        end
        return Widget.OnMouseButton(slider, button, down, x, y)
    end

    -- 布局
    local BTN_OFF = 8
    lbl_name:SetPosition(-SLIDER_W / 2, 14)
    lbl_pct:SetPosition(SLIDER_W / 2, 14)
    left_btn:SetPosition(-SLIDER_W / 2 - BTN_OFF, 0)
    right_btn:SetPosition(SLIDER_W / 2 + BTN_OFF, 0)

    w:SetPosition(0, self.sub_grid_y - self.sub_grid_h * 0.5 - 25)

    Refresh()
end

-- 按当前状态刷新（子面板展开时重建以反映最新状态）
function ConfigHUD:Refresh()
    if self.active_feature then
        self:ShowSubPanel(self.active_feature)
        self:_HighlightTiles()
    end
end

-- 屏幕定位：right 模式 self 挂在 right_root（原点=屏幕右中、自带HUD缩放），无需换算；
-- centered 模式才按 GetScreenSize 自行重算（极少用）。
function ConfigHUD:Reposition()
    local w, h = TheSim:GetScreenSize()
    if self.centered then
        local s = self:GetScale():Get()
        local yoff = IsSplitScreen() and -50 or 0
        self:SetPosition(w / 2 / s, h / 2 / s + yoff / s)
        self._screen_w, self._screen_h, self._scale = w, h, s
    else
        self:SetPosition(0, 0)   -- right_root 原点即屏幕右中，直接落位
        -- 适配屏幕高度：面板(含把手余量)过高会被屏幕上下缘截断，整体缩放以完整显示（正常屏不缩放）
        self:SetScale(1)                          -- 先复位本地缩放，干净读取父级(right_root)世界缩放
        local parentScale = self:GetScale():Get()
        local avail  = h * 0.94                   -- 屏幕可用高度（留 6% 边距）
        local needed = (FRAME_H + 40) * parentScale
        if needed > avail then
            self:SetScale(avail / needed)
        end
        self._screen_w, self._screen_h, self._scale = w, h, self:GetScale():Get()
    end
end

-- 居中/右贴边模式：窗口尺寸或 HUD 缩放变化时把面板重新定位
function ConfigHUD:OnUpdate(dt)
    if not (self.centered or self.screen_right) then return end
    local w, h = TheSim:GetScreenSize()
    local s = self:GetScale():Get()
    if w ~= self._screen_w or h ~= self._screen_h or s ~= self._scale then
        self:Reposition()
    end
end

-------------------------------------------------------------------------------
-- 展开/收起：照官方 CraftingMenuHUD:Open()/Close() 的接法
-------------------------------------------------------------------------------
local MOVE_TIME = .25

-------------------------------------------------------------------------------
-- 焦点系统：照官方 CraftingMenuWidget:DoFocusHookups 的接法
--   分类格（cat_grid）↕ 子配置格（_subgrid）之间焦点跳转
-------------------------------------------------------------------------------
function ConfigHUD:DoFocusHookups()
    if self.cat_grid == nil then return end

    -- 分类格 → 下：跳到子配置网格的同列格
    self.cat_grid:SetFocusChangeDir(MOVE_DOWN, function(w)
        if self._subgrid == nil then return end
        return GetClosestWidget(self._subgrid.widgets_to_update, w:GetFocusChild(), 0, -1)
    end)

    if self._subgrid then
        -- 子配置格 → 上：跳回分类格（只到分类格第一行）
        self._subgrid:SetFocusChangeDir(MOVE_UP, function(w)
            return GetClosestWidget(self.cat_widgets, w.widgets_to_update[w.focused_widget_index], 0, 1) or self.cat_grid
        end)
    end
end

-- 本面板只用鼠标点击/悬停，不参与任何键盘或手柄的方向焦点导航。
-- DST 把按住的 WASD(CONTROL_MOVE_*) 同时当作 UI 方向键，FrontEnd 每帧据此
-- 调用 OnFocusMove (frontend.lua:863-870)；而 Grid 的格子自带 focus_flow
-- (grid.lua:60-76)，一旦走基类，选中框就跟着 WASD 跑，OnFocusMove 返回 true
-- 还会关掉 tracking_mouse (frontend.lua:407-410)，鼠标光标也随之进入键盘导航态。
-- 官方制作菜单靠 crafting_navigation_mode 把 WASD 排除在导航之外；这里不做
-- 手柄/方向键适配，直接让本面板永远不接管方向焦点移动。
function ConfigHUD:OnFocusMove()
    return false
end

function ConfigHUD:OnControl(control, down)
    if self.is_open then
        -- 面板展开：子配置网格优先，再分类格，再基类
        if self._subgrid ~= nil and self._subgrid.focus then
            if self._subgrid:OnControl(control, down) then return true end
        end
        if self.cat_grid ~= nil and self.cat_grid.focus then
            if self.cat_grid:OnControl(control, down) then return true end
        end
    end
    if ConfigHUD._base.OnControl(self, control, down) then return true end
    return false
end

function ConfigHUD:SetOpen(is_open)
    is_open = is_open == true

    if is_open == self.is_open then
        return
    end

    self.is_open = is_open
    self.collapsed = not is_open

    if is_open then
        self.body:Show()
        self:MoveToFront()     -- 展开时置顶，避免被其他 UI 遮挡导致点击失效
        if self.active_feature then
            self:Refresh()
        end
        self.root:MoveTo(self.closed_pos, self.opened_pos, MOVE_TIME)
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/craft_open")
        -- 不设默认焦点：纯鼠标面板，焦点只由鼠标悬停/点击产生。
        -- 原来无条件 SetFocus() 把焦点钉在分类格上，WASD 立刻能沿 Grid 挪动它。
    else
        self:ClearFocus()   -- 收起时清掉面板内残留焦点，避免继续挂在前台焦点链上
        self.root:MoveTo(self.root:GetPosition(), self.closed_pos, MOVE_TIME, function()
            self.body:Hide()
        end)
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/craft_close")
    end
end

-- 兼容命名：折叠(true)/展开(false)
function ConfigHUD:SetCollapsed(collapsed)
    self:SetOpen(not (collapsed == true))
end

function ConfigHUD:Toggle()
    self:SetOpen(not self.is_open)
end

-- 供 playercontroller 的滚轮缩放防护判断：抽屉是否处于展开态
function ConfigHUD:IsOpen()
    return self.is_open == true
end

return ConfigHUD