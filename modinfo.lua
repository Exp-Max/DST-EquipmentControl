-- locale 由引擎注入: modindex.lua#596 → LOC.GetLocaleCode()
-- 值: "zh"/"zhr"/"zht"/"en"/"ru"/"ko"/"fr"/"de"/"es"/"pt"/"it"/"pl"/"tr"
local L = locale or "en"

-- ==== MODINFO_TRANSLATIONS ====
local I = {}

I.en = {
  m_name = "Equipment Control",
  m_desc = "If you have suggestions/ideas/bug reports, please leave a comment on the mod's Steam Workshop page.\n\n\n\n\n\n\n\n\n\n\n\n\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\tMade with \237\128\128\141",

  enabled     = "Enabled",
  disabled    = "Disabled",
  default     = "Default",
  fast        = "Fast",
  very_fast   = "Very Fast",
  top_speed   = "Top Speed",
  full_inv    = "Full Inventory",
  inventory   = "Inventory",
  backpack    = "Backpack",
  abigail     = "Abigail's Flower",

  sec_keybinds       = "Keybinds",
  sec_quick_buttons  = "Quick Buttons",
  sec_quick_actions  = "Quick Actions",
  sec_telepoof       = "Telepoof",
  sec_sort           = "Sort",
  sec_range_indicator= "Range Indicators",

  hov_default           = "Configure to your liking",
  hov_assign_key        = "Assign a key",
  hov_range             = "Show range circle when placing Icebox/Crock Pot",
  hov_confirm_eat       = "Avoid accidentally eating precious food",
  hov_telepoof_default  = "Double-click speed: 0.5s",
  hov_telepoof_fast     = "Double-click speed: 0.3s",
  hov_telepoof_veryfast = "Double-click speed: 0.25s",
  hov_telepoof_topspeed = "Double-click speed: 0.2s",
  hov_sort_full = "Sort your inventory and backpack",
  hov_sort_inv  = "Sort inventory only",
  hov_sort_bp   = "Sort backpack only",
  hov_same_kind_merge   = "Treat similar items (gems, seeds, toys) as the same category during batch move/repeat drop",
  hov_bundle_first      = "Shift+Quick Move prefers putting items into opened Bundling Wraps",
  hov_stewer_first      = "Shift+Quick Move prefers putting items into opened cookware (Crock Pot etc.)",
  hov_auto_containers   = "Auto-eat/auto-supply/auto-repair will also take from opened containers (chests, fridges, etc.) if main inventory and backpack lack the items",
  hov_range_indicator   = "Show range circle when placing Icebox/Crock Pot",
  hov_attack_range      = "Show the attack range circle of your held weapon",

  cfg_confirm_eat            = "Confirm to Eat",
  cfg_quick_deploy           = "Quick Deploy",
  cfg_row                    = "Row",
  cfg_batchmove              = "Batch Move",
  cfg_repeatdrop             = "Repeat Drop",
  cfg_zoom                   = "Scroll Zoom",
  cfg_caveclock              = "Cave Clock",
  cfg_same_kind_merge        = "Same Kind Merge",
  cfg_bundle_first           = "Quick Move Prefers Bundles",
  cfg_stewer_first           = "Quick Move Prefers Cookware",
  cfg_auto_open_containers   = "Auto from Open Containers",
  cfg_telepoof_speed         = "Double-Click Speed",
  cfg_container_sort         = "Sort Container",
  cfg_armor_priority         = "Armor Priority",
  cfg_light_priority         = "Light Priority",
  cfg_staff_priority         = "Staff Priority",
  cfg_equipment_priority     = "Equipment Priority",
  cfg_food_priority          = "Food Priority",
  cfg_resource_priority      = "Resource Priority",
  cfg_tool_priority          = "Tool Priority",
  cfg_override_slot1         = "Keep in Slot 1",
  cfg_range_enabled          = "Enable Range Indicator",
  cfg_attack_range           = "Attack Range",

  key_tab     = "Tab",
  key_minus   = "-",
  key_equals  = "=",
  key_space   = "Space",
  key_enter   = "Enter",
  key_esc     = "Esc",
  key_pause   = "Pause",
  key_print   = "Print Screen",
  key_capslock= "Caps Lock",
  key_scrollock= "Scroll Lock",
  key_rshift  = "RShift",
  key_lshift  = "LShift",
  key_shift   = "Shift",
  key_rctrl   = "RCtrl",
  key_lctrl   = "LCtrl",
  key_ctrl    = "Ctrl",
  key_ralt    = "RAlt",
  key_lalt    = "LAlt",
  key_alt     = "Alt",
  key_backspace= "Backspace",
  key_backslash= "\\",
  key_period  = ".",
  key_slash   = "/",
  key_semicolon= ";",
  key_rbracket= "]",
  key_lbracket= "[",
  key_tilde   = "`",
  key_up      = "Up Arrow",
  key_down    = "Down Arrow",
  key_right   = "Right Arrow",
  key_left    = "Left Arrow",
  key_insert  = "Insert",
  key_delete  = "Delete",
  key_home    = "Home",
  key_end     = "End",
  key_pageup  = "Page Up",
  key_pagedown= "Page Down",
}

I.zh = {
  m_name = "装备控制",
  m_desc = "如果您有建议/想法/发现bug，请在Steam上此模组的评论区告诉我\n\n\n\n\n\n\n\n\n\n\n\n\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t用 \237\128\128\141 制作",

  enabled     = "启用",
  disabled    = "禁用",
  default     = "默认",
  fast        = "快速",
  very_fast   = "极快",
  top_speed   = "极速",
  full_inv    = "完整背包",
  inventory   = "物品栏",
  backpack    = "背包",
  abigail     = "阿比盖尔之花",

  sec_keybinds       = "按键绑定",
  sec_quick_buttons  = "快捷按钮",
  sec_quick_actions  = "快捷动作",
  sec_telepoof       = "传送",
  sec_sort           = "排序",
  sec_range_indicator= "范围指示器",

  hov_default           = "根据喜好设置",
  hov_assign_key        = "分配按键",
  hov_range             = "放置冰柜/烹饪锅时显示范围圈",
  hov_confirm_eat       = "避免误吃珍贵食物",
  hov_telepoof_default  = "双击速度为0.5秒",
  hov_telepoof_fast     = "双击速度为0.3秒",
  hov_telepoof_veryfast = "双击速度为0.25秒",
  hov_telepoof_topspeed = "双击速度为0.2秒",
  hov_sort_full = "排序您的物品栏和背包",
  hov_sort_inv  = "仅排序物品栏",
  hov_sort_bp   = "仅排序背包",
  hov_same_kind_merge   = "批量转移/连续丢弃时，把同类物品（各色宝石、各种种子、各类小玩具等）视为同一类",
  hov_bundle_first      = "Shift+快速移动时，优先把物品放进打开的打包裹",
  hov_stewer_first      = "Shift+快速移动时，优先把物品放进打开的厨具（锅等）",
  hov_auto_containers   = "自动进食/自动补给/自动修复所需物品，若主物品栏与背包没有，也会从已打开的容器（箱子/冰箱等）自动取用，对应排队论 allow_all_open_containers",
  hov_range_indicator   = "冰柜/烹饪锅放置时显示范围圈",
  hov_attack_range      = "显示玩家手持武器的攻击范围圈",

  cfg_confirm_eat            = "进食确认",
  cfg_quick_deploy           = "快速部署",
  cfg_row                    = "划船",
  cfg_batchmove              = "批量转移",
  cfg_repeatdrop             = "连续丢弃",
  cfg_zoom                   = "滚轮缩放",
  cfg_caveclock              = "洞穴时钟",
  cfg_same_kind_merge        = "同类归并",
  cfg_bundle_first           = "快速移动优先进包裹",
  cfg_stewer_first           = "快速移动优先进厨具",
  cfg_auto_open_containers   = "自动模块从打开容器取物",
  cfg_telepoof_speed         = "双击速度",
  cfg_container_sort         = "排序容器",
  cfg_armor_priority         = "护甲优先级",
  cfg_light_priority         = "光源优先级",
  cfg_staff_priority         = "法杖优先级",
  cfg_equipment_priority     = "装备优先级",
  cfg_food_priority          = "食物优先级",
  cfg_resource_priority      = "资源优先级",
  cfg_tool_priority          = "工具优先级",
  cfg_override_slot1         = "保持在1号槽",
  cfg_range_enabled          = "启用范围指示器",
  cfg_attack_range           = "攻击范围",

  key_tab     = "Tab",
  key_minus   = "-",
  key_equals  = "=",
  key_space   = "空格",
  key_enter   = "回车",
  key_esc     = "Esc",
  key_pause   = "暂停",
  key_print   = "截图",
  key_capslock= "大小写锁定",
  key_scrollock= "滚动锁定",
  key_rshift  = "右Shift",
  key_lshift  = "左Shift",
  key_shift   = "Shift",
  key_rctrl   = "右Ctrl",
  key_lctrl   = "左Ctrl",
  key_ctrl    = "Ctrl",
  key_ralt    = "右Alt",
  key_lalt    = "左Alt",
  key_alt     = "Alt",
  key_backspace= "退格",
  key_backslash= "\\",
  key_period  = ".",
  key_slash   = "/",
  key_semicolon= ";",
  key_rbracket= "]",
  key_lbracket= "[",
  key_tilde   = "`",
  key_up      = "上箭头",
  key_down    = "下箭头",
  key_right   = "右箭头",
  key_left    = "左箭头",
  key_insert  = "插入",
  key_delete  = "删除",
  key_home    = "首页",
  key_end     = "末页",
  key_pageup  = "Page Up",
  key_pagedown= "Page Down",
}

I.zht = {
  m_name = "裝備控制",
  m_desc = "如果您有建議/想法/發現bug，請在Steam上此模組的評論區告訴我\n\n\n\n\n\n\n\n\n\n\n\n\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t用 \237\128\128\141 製作",

  enabled     = "啟用",
  disabled    = "禁用",
  default     = "預設",
  fast        = "快速",
  very_fast   = "極快",
  top_speed   = "極速",
  full_inv    = "完整背包",
  inventory   = "物品欄",
  backpack    = "背包",
  abigail     = "阿比蓋爾之花",

  sec_keybinds       = "按鍵綁定",
  sec_quick_buttons  = "快捷按鈕",
  sec_quick_actions  = "快捷動作",
  sec_telepoof       = "傳送",
  sec_sort           = "排序",
  sec_range_indicator= "範圍指示器",

  hov_default           = "根據喜好設定",
  hov_assign_key        = "分配按鍵",
  hov_range             = "放置冰櫃/烹飪鍋時顯示範圍圈",
  hov_confirm_eat       = "避免誤吃珍貴食物",
  hov_telepoof_default  = "雙擊速度為0.5秒",
  hov_telepoof_fast     = "雙擊速度為0.3秒",
  hov_telepoof_veryfast = "雙擊速度為0.25秒",
  hov_telepoof_topspeed = "雙擊速度為0.2秒",
  hov_sort_full = "排序您的物品欄和背包",
  hov_sort_inv  = "僅排序物品欄",
  hov_sort_bp   = "僅排序背包",

  cfg_confirm_eat            = "進食確認",
  cfg_quick_deploy           = "快速部署",
  cfg_row                    = "划船",
  cfg_batchmove              = "批量轉移",
  cfg_repeatdrop             = "連續丟棄",
  cfg_zoom                   = "滾輪縮放",
  cfg_caveclock              = "洞穴時鐘",

  key_space   = "空格",
  key_enter   = "回車",
  key_pause   = "暫停",
  key_print   = "截圖",
  key_capslock= "大小寫鎖定",
  key_scrollock= "滾動鎖定",
  key_backspace= "退格",
  key_up      = "上箭頭",
  key_down    = "下箭頭",
  key_right   = "右箭頭",
  key_left    = "左箭頭",
  key_insert  = "插入",
  key_delete  = "刪除",
  key_home    = "首頁",
  key_end     = "末頁",
}

-- 语言选择: zhr(Rail简体) → zh; 其余按 locale
if L == "zhr" then L = "zh" end
local S = I[L]
if not S then S = I.en end

local function T(key)
  S = S
  if S[key] then return S[key] end
  if I.en[key] then return I.en[key] end
  return key
end

-- === mod 元数据 ===
name = ChooseTranslationTable({
  I.en and I.en.m_name,
  zh  = I.zh.m_name,
  zht = I.zht.m_name,
  zhr = I.zh.m_name,
  en  = I.en.m_name,
})

description = ChooseTranslationTable({
  I.en and I.en.m_desc,
  zh  = I.zh.m_desc,
  zht = I.zht.m_desc,
  zhr = I.zh.m_desc,
  en  = I.en.m_desc,
})

icon_atlas     = "scripts/images/modicon.xml"
icon = "modicon.tex"
author = "Boas"
version = "8.17"
forumthread = ""
dont_starve_compatible = false
reign_of_giants_compatible = false
dst_compatible = true
all_clients_require_mod = false
client_only_mod = true
api_version = 10
folder_name = folder_name or name
if not folder_name:find("workshop-") then
  name = name .. " (dev)"
end

-- === 工具函数 ===
local function opt(desc, data, hover)
  return { description = desc, data = data, hover = hover }
end

local function boolOpt(hover)
  return { opt(T("disabled"), false, hover), opt(T("enabled"), true, hover) }
end

local function cfg(label, cfg_name, options, default, hover)
  return { label = label, name = cfg_name, options = options, default = default, hover = hover }
end

local function title(text)
  return cfg(text, "", { { description = "", data = 0 } }, 0)
end

-- === OPTION_SETS ===
local OPTION_SETS = {}

OPTION_SETS.YESNO = boolOpt()

OPTION_SETS.PRIORITY = {}
for p = 7, 1, -1 do
  OPTION_SETS.PRIORITY[#OPTION_SETS.PRIORITY + 1] = opt("" .. (8 - p), p)
end

do
  local base_kb = {}
  base_kb[#base_kb + 1] = opt(T("disabled"), false)
  local ALPHA = { "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z" }
  for i = 1, #ALPHA do base_kb[#base_kb + 1] = opt(ALPHA[i], "KEY_" .. ALPHA[i]) end
  for i = 0, 9 do base_kb[#base_kb + 1] = opt("" .. i, "KEY_" .. i) end
  for i = 1, 12 do base_kb[#base_kb + 1] = opt("F" .. i, "KEY_F" .. i) end
  local specialsTXT = {
    T("key_tab"), T("key_minus"), T("key_equals"),
    T("key_space"), T("key_enter"), T("key_esc"),
    T("key_pause"), T("key_print"), T("key_capslock"),
    T("key_scrollock"),
    T("key_rshift"), T("key_lshift"), T("key_shift"),
    T("key_rctrl"), T("key_lctrl"), T("key_ctrl"),
    T("key_ralt"), T("key_lalt"), T("key_alt"),
    T("key_backspace"), T("key_backslash"),
    T("key_period"), T("key_slash"),
    T("key_semicolon"), T("key_rbracket"),
    T("key_lbracket"), T("key_tilde"),
    T("key_up"), T("key_down"), T("key_right"), T("key_left"),
    T("key_insert"), T("key_delete"),
    T("key_home"), T("key_end"),
    T("key_pageup"), T("key_pagedown"),
  }
  local specialsKEY = {
    "TAB","MINUS","EQUALS","SPACE","ENTER","ESCAPE","PAUSE","PRINT","CAPSLOCK",
    "SCROLLOCK","RSHIFT","LSHIFT","SHIFT","RCTRL","LCTRL","CTRL","RALT","LALT",
    "ALT","BACKSPACE","BACKSLASH","PERIOD","SLASH","SEMICOLON","RIGHTBRACKET",
    "LEFTBRACKET","TILDE","UP","DOWN","RIGHT","LEFT","INSERT","DELETE",
    "HOME","END","PAGEUP","PAGEDOWN",
  }
  for i = 1, #specialsTXT do
    base_kb[#base_kb + 1] = opt(specialsTXT[i], "KEY_" .. specialsKEY[i])
  end
  base_kb[#base_kb + 1] = opt(T("disabled"), false)

  OPTION_SETS.KB = base_kb

  local function create_kb_variant(hover_text)
    local variant = {}
    for i = 1, #base_kb do
      variant[#variant + 1] = opt(base_kb[i].description, base_kb[i].data, hover_text)
    end
    return variant
  end
  OPTION_SETS.KB_CONFIRM_EAT   = create_kb_variant(T("hov_confirm_eat"))
end

OPTION_SETS.TELEPOOF_SPEED = {
  opt(T("disabled"), false), opt(T("default"), .5, T("hov_telepoof_default")),
  opt(T("fast"), .3, T("hov_telepoof_fast")),
  opt(T("very_fast"), .25, T("hov_telepoof_veryfast")),
  opt(T("top_speed"), .2, T("hov_telepoof_topspeed")),
}

OPTION_SETS.SORT_OVERRIDE = {
  opt(T("disabled"), false), opt(T("abigail"), "abigail_flower"),
}

OPTION_SETS.SORT_CONTAINER = {
  opt(T("full_inv"), 3, T("hov_sort_full")),
  opt(T("inventory"), 2, T("hov_sort_inv")),
  opt(T("backpack"), 1, T("hov_sort_bp")),
}

-- === CONFIG_STRUCTURE（翻译键 → 循环中 T() 解析）===
-- 已在 confighud 中管理的配置已从此处移除，只在游戏内 HUD 中调整
local CS = {
  {
    title = "sec_keybinds",
    hov = "hov_assign_key",
    items = {
      {"cfg_confirm_eat", "CONFIRM_TO_EAT", "KB_CONFIRM_EAT", "KEY_CTRL"},
    },
  },
  {
    title = "sec_quick_buttons",
    hov = "hov_default",
    items = {},
  },
  {
    title = "sec_quick_actions",
    hov = "hov_default",
    items = {
      {"cfg_quick_deploy",         "QUICK_ACTION_QUICK_DEPLOY",        "YESNO", true},
      {"cfg_row",                  "QUICK_ACTION_ROW",              "YESNO", true},
      {"cfg_batchmove",            "QUICK_ACTION_BATCHMOVE",        "YESNO", true},
      {"cfg_repeatdrop",           "QUICK_ACTION_REPEATDROP",       "YESNO", true},
      {"cfg_zoom",                 "QUICK_ACTION_ZOOM",             "YESNO", true},
      {"cfg_caveclock",            "QUICK_ACTION_CAVECLOCK",        "YESNO", true},
      {"cfg_same_kind_merge",      "SAME_KIND_MERGE",   "YESNO", true,  "hov_same_kind_merge"},
      {"cfg_bundle_first",         "BUNDLE_FIRST",      "YESNO", true,  "hov_bundle_first"},
      {"cfg_stewer_first",         "STEWER_FIRST",      "YESNO", true,  "hov_stewer_first"},
      {"cfg_auto_open_containers", "AUTO_FROM_OPEN_CONTAINERS", "YESNO", true, "hov_auto_containers"},
    },
  },
  {
    title = "sec_telepoof",
    hov = "hov_default",
    items = {
      {"cfg_telepoof_speed", "TELEPOOF_DOUBLECLICK", "TELEPOOF_SPEED", 0.5},
    },
  },
  {
    title = "sec_sort",
    hov = "hov_default",
    items = {
      {"cfg_container_sort",     "CONTAINER_SORT",           "SORT_CONTAINER", 3},
      {"cfg_armor_priority",     "ARMOR_SORT_PRIORITY",      "PRIORITY",       7},
      {"cfg_light_priority",     "LIGHT_SORT_PRIORITY",      "PRIORITY",       6},
      {"cfg_staff_priority",     "STAFF_SORT_PRIORITY",      "PRIORITY",       5},
      {"cfg_equipment_priority", "EQUIPMENT_SORT_PRIORITY",  "PRIORITY",       4},
      {"cfg_food_priority",      "FOOD_SORT_PRIORITY",       "PRIORITY",       3},
      {"cfg_resource_priority",  "RESOURCE_SORT_PRIORITY",   "PRIORITY",       2},
      {"cfg_tool_priority",      "TOOL_SORT_PRIORITY",       "PRIORITY",       1},
      {"cfg_override_slot1",     "OVERRIDE_SLOT1_SORT",      "SORT_OVERRIDE",  false},
    },
  },
  {
    title = "sec_range_indicator",
    hov = "hov_range",
    items = {
      {"cfg_range_enabled", "RANGEINDICATOR_ENABLED",      "YESNO", true,  "hov_range_indicator"},
      {"cfg_attack_range",  "RANGEINDICATOR_ATTACK_RANGE", "YESNO", false, "hov_attack_range"},
    },
  },
}

-- === 构建 configuration_options ===
configuration_options = {}

for i = 1, #CS do
  local sec = CS[i]
  configuration_options[#configuration_options + 1] = title(T(sec.title))
  if sec.items then
    for j = 1, #sec.items do
      local it = sec.items[j]
      local label = T(it[1])
      local cname = it[2]
      local okey  = it[3]
      local defv  = it[4]
      local hover = T(it[5]) or T(sec.hov)
      local olist = OPTION_SETS[okey] or {}
      configuration_options[#configuration_options + 1] = cfg(label, cname, olist, defv, hover)
    end
  end
end