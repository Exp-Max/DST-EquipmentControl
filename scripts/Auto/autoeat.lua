local InventoryUtil = require "util/inventoryutil"
local InventoryEventService = require "util/inventoryeventservice"
local PlayerUtil = require "util/playerutil"

-- 防抖：主库存获得新 prefab 物品时 itemget 与 gotnewitem 都会触发，
-- 且进食后 currenthunger 网络同步有延迟，避免一次获得食物连续吃两个
local EAT_DEBOUNCE = 1
local last_eat_time = 0

local function TryEat(classified)
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.FOOD then
        return
    end
    if classified == nil or classified._parent == nil then
        return
    end

    -- currenthunger 是 net_ushortint，服务端 SetValue 用 math.ceil 取整
    -- 只有实际饱食度恰好为 0 时 value() 才为 0
    if PlayerUtil:GetHunger() > 0 then
        return
    end

    local now = GetTime()
    if now - last_eat_time < EAT_DEBOUNCE then
        return
    end

    local actioncontroller = PlayerUtil:GetComponent("actioncontroller")
    if not actioncontroller then
        return
    end

    -- 饱食度为 0 时应吃 FOOD 分类（食物），而非 RESTORATION（治疗物品）
    local item = actioncontroller:GetItemFromCategory("FOOD")
    if item == nil then
        return
    end

    -- 珍贵食物（象鼻/蜂王浆/曼德拉草…）不自动吃。categories.lua 的 FOOD 分类已排除它们，
    -- 但用户偏好直选（Preferences.User）会绕过分类判定，故此处再拦一次作为双保险；
    -- 手动路径则由 eatconfirmation 要求按住确认键才能吃。
    local special = MOD_EQUIPMENT_CONTROL ~= nil and MOD_EQUIPMENT_CONTROL.SPECIALFOOD or nil
    if special ~= nil and special[item.prefab] then
        return
    end

    -- 直接原地吃：食物在主物品栏/背包/已打开的容器里都可用，不必先取到手持。
    -- 取到手持会让 UseItemFromInvTile 退化成"用手持物对该物品使用"，服务端静默丢弃 → 卡鼠标。
    if not InventoryUtil:CanUseInPlace(item) then
        return
    end

    -- 只吃 EAT：首选的自我动作不是 EAT（例如该物品首选是别的 INVENTORY 动作）时放弃，
    -- 避免莫名其妙执行了别的动作。
    if InventoryUtil:UseItemOnSelf(item, ACTIONS.EAT) then
        last_eat_time = now
    end
end

local function Init()
    if not ThePlayer or not ThePlayer.player_classified then
        return
    end

    local classified = ThePlayer.player_classified

    -- 饱食度变化时检测（立即响应饱食度归零）
    classified:ListenForEvent("hungerdirty", function(inst)
        TryEat(inst)
    end)

    -- 物品栏获得新物品时检测（重试机制）
    -- 饱食度归零后 currenthunger 停在 0 不再变化，hungerdirty 不会再触发；
    -- 若玩家当时没有食物，拾取/制作获得新食物后触发进食。
    -- 通过 InventoryEventService 统一监听主库存(itemget)+背包(gotnewitem)。
    InventoryEventService:OnItemGet(function()
        TryEat(classified)
    end)

    -- 中键切换自动进食开关（FOOD）后立即重试：
    -- 否则在“饱食度已归零且无新增物品”时关闭再打开开关，hungdirty 不会再次触发、
    -- 也无新物品入包，TryEat 不再被调用，有食物也不会进食（与 autocloth 同类缺陷）。
    -- TryEat 内部已判定 AUTO_EQUIP.FOOD，关闭时调用会直接返回，无副作用。
    ThePlayer:ListenForEvent("autoequeiptoggled", function(_, data)
        if data and data.category == "FOOD" then
            TryEat(classified)
        end
    end)
end

return Init
