-- Equipment Control 语言文件 - 简体中文
GLOBAL.STRINGS.EQUIPMENT_CONTROL =
{
    -- ========================================
    -- 配置界面标题
    -- ========================================
    SECTIONS =
    {
        KEYBINDS       = "按键绑定",
        TOGGLES        = "开关",
        BUTTONS        = "快捷按钮",
        PREFERENCES    = "偏好设置",
        AUTOMATION     = "自动化",
        QUICK_ACTIONS  = "快捷动作",
        PICKUP         = "拾取",
        TELEPOOF       = "传送",
        MOUSE_THROUGH  = "穿透鼠标",
        SORT           = "排序",
        MISC           = "杂项",
    },

    -- ========================================
    -- 配置项标签
    -- ========================================
    CONFIG =
    {
        TOOLS                       = "工具",
        LIGHT                       = "光源",
        WAR                         = "武器",
        ARMOR                       = "盔甲",
        DRESS                       = "服饰",
        SURVIVAL                    = "生存",
        MAGIC                       = "魔法",
        DROPKEY                     = "放下灯笼",
        MEAT_PRIORITIZATION_MODE    = "肉类优先模式",
        CONFIRM_TO_EAT              = "进食确认",
        PICKUP_FILTER_KEY           = "拾取过滤",
        ATTACK_FILTER_KEY           = "攻击过滤",
        SORT_INVENTORY_KEY          = "排序物品栏",
        SORT_CHEST_KEY              = "排序箱子",

        TOGGLE_TELEPOOF             = "切换传送",
        TOGGLE_SORTING_CONTAINER    = "切换排序容器",

        QUICK_ACTION_BEEFALO        = "剃牛毛",
        QUICK_ACTION_KLAUS_SACK     = "解锁克劳斯袋子",
        QUICK_ACTION_REPAIR_BOAT    = "修复船只",
        QUICK_ACTION_BUILD_FOSSIL   = "建造骨架",
        QUICK_ACTION_ATRIUM_GATE    = "插入远古钥匙",
        QUICK_ACTION_DIRTPILE       = "追踪动物",
        QUICK_ACTION_FEED_BIRD      = "喂鸟",
        QUICK_ACTION_WAKEUP_BIRD    = "唤醒鸟",
        QUICK_ACTION_IMPRISON_BIRD  = "囚禁鸟",
        QUICK_ACTION_BOTTLESSOUL    = "装入瓶子",
        QUICK_ACTION_DEVOURER       = "喂时空吞噬者",
        QUICK_ACTION_EXTINGUISH     = "灭火",
        QUICK_ACTION_QUICK_DEPLOY   = "快速部署",
        QUICK_ACTION_MEDAL_POLLUTE         = "污染血糖",
        QUICK_ACTION_MEDAL_PLANT_MANDRAKE  = "种植曼德拉",
        QUICK_ACTION_MEDAL_BURY_GREENGEM   = "埋下绿宝石",
        QUICK_ACTION_MEDAL_TREE_LEVEL_UP   = "嫁接树升级",
        QUICK_ACTION_MEDAL_WORMWOOD_FLOWER = "旋花藤缠绕",
        QUICK_ACTION_MEDAL_MAKE_COOLDOWN   = "强制冷却",
        QUICK_ACTION_MEDAL_GRINDING        = "研磨",
        QUICK_ACTION_MEDAL_CHEFFLAVOUR     = "调味",
        QUICK_ACTION_MEDAL_EAT_SPICES      = "吃调味料",
        QUICK_ACTION_MEDAL_SOUL_ABSORB     = "吸收黑暗灵魂",
        QUICK_ACTION_MEDAL_SOUL_AUTO       = "黑暗灵魂自动",

        PRIOTIZE_VALUABLE_ITEMS     = "优先拾取贵重物品",
        IGNORE_KNOWN_BLUEPRINT      = "忽略已知蓝图",
        PICKUP_IGNORE_FERNS         = "忽略蕨类植物",
        PICKUP_IGNORE_SUCCULENTS    = "忽略多肉植物",
        PICKUP_IGNORE_MARSH_BUSH    = "忽略沼泽灌木",

        TELEPOOF_DISABLED           = "默认禁用",
        TELEPOOF_HOVER              = "隐藏悬浮提示",
        TELEPOOF_DOUBLECLICK        = "双击速度",
        TELEPOOF_WORTOX             = "双击灵魂跳跃",

        FORCE_INSPECT_PLAYERS       = "强制查看玩家",
        FLYING_BIRDS_MOUSETHROUGH   = "飞行中的鸟不可点击",
        YELLOWSTAFF_MOUSETHROUGH    = "唤星者魔杖",
        ORANGESTAFF_MOUSETHROUGH    = "懒人魔杖",

        CONTAINER_SORT              = "排序容器",
        ARMOR_SORT_PRIORITY         = "护甲优先级",
        LIGHT_SORT_PRIORITY         = "光源优先级",
        STAFF_SORT_PRIORITY         = "法杖优先级",
        EQUIPMENT_SORT_PRIORITY     = "装备优先级",
        FOOD_SORT_PRIORITY          = "食物优先级",
        RESOURCE_SORT_PRIORITY      = "资源优先级",
        TOOL_SORT_PRIORITY          = "工具优先级",
        OVERRIDE_SLOT1_SORT         = "保持在1号槽",

        DAMAGE_ESTIMATION           = "伤害估算",

        -- 巨石躲避
        BOULDER_DODGE           = "巨石躲避",
        DODGE_MARGIN            = "躲避余量",
        DODGE_MANUAL_OVERRIDE   = "手动移动覆盖",
        DODGE_USE_CANE          = "自动切手杖加速",
        DODGE_CHOPS_OVERRIDE    = "砍倒刀数(0=自动)",
        DODGE_AUTO              = "自动",
    },

    -- ========================================
    -- 配置项悬浮提示
    -- ========================================
    HOVERS =
    {
        KEYBIND                 = "分配按键",
        TOGGLE                  = "分配按键",
        DEFAULT                 = "根据喜好设置",
        BETA                    = "实验性功能 - 使用风险自负！",
        TELEPOOF_DISABLED_HOVER = "进入游戏时传送处于禁用状态",
        TELEPOOF_HOVER_HIDE     = "传送禁用时隐藏悬浮提示",
        FORCE_INSPECT           = "需要按住强制查看键才能与玩家交互",
        FLYING_BIRDS            = "飞行中的鸟无法点击",
        YELLOWSTAFF             = "允许你将矮星召唤得更靠近",
        ORANGESTAFF             = "允许你穿墙传送",
        AUTO_RE_EQUIP_SAME      = "自动重新装备相同武器",
        AUTO_RE_EQUIP_BEST      = "自动重新装备下一把最佳武器",
        TRAP_TRIGGERED          = "仅在陷阱已触发时显示",
        TELEPOOF_SPEED_DEFAULT  = "双击速度为0.5秒",
        TELEPOOF_SPEED_FAST     = "双击速度为0.3秒",
        TELEPOOF_SPEED_FASTER   = "双击速度为0.25秒",
        TELEPOOF_SPEED_FASTEST  = "双击速度为0.2秒",
        SORT_FULL               = "排序您的物品栏和背包",
        SORT_INVENTORY          = "仅排序物品栏",
        SORT_BACKPACK           = "仅排序背包",
        PRIORITIZE_VALUABLE     = "优先拾取贵重物品",
        IGNORE_BLUEPRINT        = "过滤已知蓝图不拾取",
        IGNORE_FERNS            = "不拾取蕨类植物",
        IGNORE_SUCCULENTS       = "不拾取多肉植物",
        IGNORE_MARSH_BUSH       = "不拾取沼泽灌木",
        WORTOX_SOUL             = "双击灵魂跳跃",
        SORT_OVERRIDE           = "保持在1号槽",

        -- 巨石躲避
        BOULDER_DODGE           = "岩石树(Boulderbough)即将砸下巨石时，自动走开躲避",
        DODGE_MARGIN            = "在巨石伤害范围之外额外保持的距离",
        DODGE_MANUAL_OVERRIDE   = "按住方向键时允许玩家手动移动，覆盖自动躲避",
        DODGE_USE_CANE          = "躲避时自动装备手杖/橙宝石法杖加速移动",
        DODGE_CHOPS_OVERRIDE    = "手动指定砍倒岩石树需要的刀数，0=自动学习斧子数据",
    },

    -- ========================================
    -- 局内提示
    -- ========================================
    PROMPTS =
    {
        CANNOT_UNEQUIP          = "无法卸下 %s。",
        PREFERRED_ITEM          = "偏好物品：%s。",
        AUTO_EQUIP_CATEGORY     = "自动装备分类：%s。",
        TOGGLE_FORMAT           = "%s (%s)",
        SORT_OPEN_CONTAINER     = "请打开一个容器以进行排序。",
        SORTING                 = "正在排序 %s。",
        SORTING_CHEST           = "正在排序箱子。",
        SORTING_INVENTORY       = "正在排序物品栏。",
        SORTING_BACKPACK        = "正在排序背包。",
        SORTING_ALL             = "正在排序物品栏和背包。",
        SORTING_CONTAINER       = "排序容器 (%s)",
        CANNOT_FILTER           = "嗯……我无法过滤那个",
        FILTER_ADD              = '好的！从现在开始，我会把"%s"留在地上',
        FILTER_REMOVE           = '我会再捡起"%s"',
        MEAT_MODE               = '当前肉模式是"%s"。',
        HOLD_TO_EAT             = "按住 %s 食用 %s。",
        TEMP_ITEM_ADDED         = "已临时添加 %s 到 %s 快捷栏。",
        TEMP_ITEM_REMOVED       = "已取消临时物品 %s。",

        MEDAL_NOT_FOUND         = "自动佩戴失败：未找到 %s。",
        MEDAL_NOT_ACCESSIBLE    = "自动佩戴失败：%s 在容器中，无法自动取回佩戴。",
        MEDAL_PULL_FAILED       = "自动佩戴失败：无法从勋章盒取回 %s，请检查背包空间。",
        MEDAL_ORIGIN_NO_SLOT    = "本源联动失败：本源勋章已满，且没有可替换的勋章可换出腾位。",

        CHEST_MEMORY_DISPLAY_MODE   = "箱子记忆显示模式：%s。",
        CHEST_MEMORY_DISPLAY_BUTTON = "切换显示模式（当前：%s）",
    },

    -- ========================================
    -- 键位提示
    -- ========================================
    KEYBINDS =
    {
        FULL_INVENTORY_UNEQUIP = "无法卸下 %s，因为你的背包已满。",
    },

    -- ========================================
    -- 按钮操作提示
    -- ========================================
    BUTTONS =
    {
    },

    -- ========================================
    -- 拾取过滤器提示
    -- ========================================
    PICKUP_FILTER =
    {
        ADD    = "拾取过滤：已添加 %s。",
        REMOVE = "拾取过滤：已移除 %s。",
    },

    -- ========================================
    -- 攻击过滤器提示
    -- ========================================
    ATTACK_FILTER =
    {
        ADD    = "攻击过滤：已添加 %s。",
        REMOVE = "攻击过滤：已移除 %s。",
    },

    -- ========================================
    -- 自动卸下物品提示
    -- ========================================
    AUTO_UNEQUIP_ITEM =
    {
        UNEQUIP = "自动卸下：%s。",
        DROP    = "自动卸下：丢弃当前物品以保留 %s。",
        FAIL    = "自动卸下：卸下 %s 失败。",
    },

    -- ========================================
    -- 自动修复提示
    -- ========================================
    AUTO_REPAIR_ITEM =
    {
        REPAIRING   = "正在修复: %s。",
        RETRY       = "重试修复: %s (%d/3)",
        INTERRUPTED = "%s 修复被打断，等待空闲...",
        NO_MATERIAL = "缺少修复材料，%s 等待中...",
    },

    -- ========================================
    -- 开关文本
    -- ========================================
    TOGGLE =
    {
        ENABLED              = "已启用",
        DISABLED             = "已禁用",
        TELEPOOF             = "传送",
        AUTO_EQUIP_ON        = "自动装备: 已开启",
        AUTO_EQUIP_OFF       = "自动装备: 已关闭",
    },

    -- ========================================
    -- 箱子记忆显示模式名称（all / single / hidden）
    -- ========================================
    CHEST_MEMORY_DISPLAY =
    {
        ALL    = "全部",
        SINGLE = "悬停",
        HIDDEN = "隐藏",
    },

    -- ========================================
    -- 背包物品提示
    -- ========================================
    INVENTORY_ITEM =
    {
        EAT_VALUABLE_RESOURCE = "%s 是珍贵资源。（按住 %s 食用）",
    },
}