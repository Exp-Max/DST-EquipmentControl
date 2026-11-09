-- 统一物品状态事件服务
-- 所有模块通过此服务订阅物品事件，无需各自 ListenForEvent，
-- 避免重复监听、遗漏事件、防抖不一致等问题。
--
-- 用法: 本文件必须 modimport 加载（见 modmain.lua 的 modimport 调用），不要 require。
--       require 环境的 strict 模式下 AddClassPostConstruct 等 mod API 全局未声明，
--       会在加载期直接报 LUA ERROR，并连带拖垮所有 require 它的模块。
--       订阅示例: InventoryEventService:On("item_added", function(data) ... end)

-- 定义为全局（modimport 环境），供其他文件通过 require 缓存或全局引用复用同一实例。
InventoryEventService = {}

-- 官方没有 onopencontainer / onclosecontainer 事件：
-- inventory.opencontainers 只是 Container:Open/Close 维护的普通表，不会推事件。
-- 这里从容器界面补发，使 CONTAINER_OPENED / CONTAINER_CLOSED 真正可用
-- （客户端 Inventory:GetOpenContainers() 读的就是 HUD.controls.containers）。
AddClassPostConstruct("widgets/containerwidget", function(self)
    local _Open = self.Open
    function self:Open(...)
        _Open(self, ...)
        if ThePlayer ~= nil then
            ThePlayer:PushEvent("onopencontainer", { container = self.container })
        end
    end

    local _Close = self.Close
    function self:Close(...)
        local container = self.container
        if container ~= nil and container:IsValid() and ThePlayer ~= nil then
            ThePlayer:PushEvent("onclosecontainer_pre", { container = container, widget = self })
        end
        _Close(self, ...)
        if container ~= nil and container:IsValid() and ThePlayer ~= nil then
            ThePlayer:PushEvent("onclosecontainer", { container = container })
        end
    end
end)

-- 事件名常量
InventoryEventService.EVENT = {
    ITEM_ADDED       = "item_added",
    ITEM_REMOVED     = "item_removed",
    EQUIPPED         = "equipped",
    UNEQUIPPED       = "unequipped",
    DURABILITY       = "durability",
    STACK_CHANGED    = "stack_changed",
    CONTAINER_OPENED = "container_opened",
    CONTAINER_CLOSED = "container_closed",
    ACTIVE_CHANGED   = "active_changed",
    INVENTORY_REFRESH= "inventory_refresh",
    ENTITY_REMOVED   = "entity_removed",
}

-- 模块级常量: 服务事件 → 原始游戏事件映射
local RAW_EVENT_MAP = {
    [InventoryEventService.EVENT.ITEM_ADDED]       = { "itemget", "gotnewitem" },
    [InventoryEventService.EVENT.ITEM_REMOVED]     = { "itemlose" },
    [InventoryEventService.EVENT.EQUIPPED]         = { "equip" },
    [InventoryEventService.EVENT.UNEQUIPPED]       = { "unequip" },
    [InventoryEventService.EVENT.STACK_CHANGED]    = { "stacksizechange" },
    [InventoryEventService.EVENT.CONTAINER_OPENED] = { "onopencontainer" },  -- 由下方 containerwidget 钩子补发
    [InventoryEventService.EVENT.CONTAINER_CLOSED] = { "onclosecontainer" }, -- 同上
    [InventoryEventService.EVENT.ACTIVE_CHANGED]   = { "newactiveitem" },
    [InventoryEventService.EVENT.INVENTORY_REFRESH]= { "refreshinventory" },
    [InventoryEventService.EVENT.ENTITY_REMOVED]   = { "onremove" },
}

-- 每个玩家实体的状态
-- _players[player] = {
--     onremove_handler = fn,       -- onremove 清理回调（用于 RemoveEventCallback）
--     raw_handlers = {              -- 原始事件 → 调度函数（用于 RemoveEventCallback）
--         [raw_event] = fn,
--     },
--     subs = {                      -- 服务事件 → 订阅者列表
--         [svc_event] = { fn, ... },
--     },
-- }
local _players = {}

-- 为某个 raw_event 创建命名调度函数并注册 ListenForEvent
local function _makeDispatcher(raw_event, svc_event, player)
    local dispatcher = function(inst, data)
        local p = _players[player]
        if not p then return end
        local subs = p.subs[svc_event]
        if not subs then return end
        for i = #subs, 1, -1 do
            subs[i](data)
        end
    end
    return dispatcher
end

-- 容器实体（背包/打开容器）→ raw_event → dispatcher 的自管理表
local _container_listeners = {}

-- 必须定义在 _ensureContainerListener 之前：后者内的 dispatcher 闭包会调用它。
-- 若定义在后，闭包创建时该 local 尚未声明，闭包内的引用会编译成全局查找，
-- 运行时报 attempt to call global '_removeContainerListener' (a nil value)。
local function _removeContainerListener(entity, raw_event)
    if entity == nil then return end
    local rec = _container_listeners[entity]
    if rec and rec[raw_event] then
        if entity:IsValid() then
            entity:RemoveEventCallback(raw_event, rec[raw_event])
        end
        rec[raw_event] = nil
    end
end

local function _ensureContainerListener(player, entity, raw_event, svc_event)
    if entity == nil or not entity:IsValid() then return end
    if _container_listeners[entity] and _container_listeners[entity][raw_event] then
        return
    end
    local dispatcher = function(inst, data)
        local p = _players[player]
        if not p then
            -- 玩家已清理：自移除并清表，避免泄漏
            _removeContainerListener(entity, raw_event)
            return
        end
        local subs = p.subs[svc_event]
        if not subs then return end
        for i = #subs, 1, -1 do
            subs[i](data)
        end
    end
    if _container_listeners[entity] == nil then _container_listeners[entity] = {} end
    _container_listeners[entity][raw_event] = dispatcher
    entity:ListenForEvent(raw_event, dispatcher)
end

-- 为玩家背包（overflow）与所有已打开容器注册 itemlose→ITEM_REMOVED / itemget→ITEM_ADDED。
-- 背包可能延迟出现（拾起背包），故在 refreshinventory / onopencontainer 时也重跑（见下方 _ensurePlayer 外独立监听）。
local function _ensureContainerListenersForPlayer(player)
    local inv = player.replica and player.replica.inventory
    if inv == nil then return end

    local overflow = inv.GetOverflowContainer and inv:GetOverflowContainer() or nil
    if overflow ~= nil and overflow.inst ~= nil and overflow.inst:IsValid() then
        _ensureContainerListener(player, overflow.inst, "itemlose", InventoryEventService.EVENT.ITEM_REMOVED)
        _ensureContainerListener(player, overflow.inst, "itemget", InventoryEventService.EVENT.ITEM_ADDED)
    end

    if inv.GetOpenContainers then
        local containers = inv:GetOpenContainers()
        if containers ~= nil then
            for container_entity in pairs(containers) do
                if container_entity ~= nil and container_entity:IsValid() then
                    _ensureContainerListener(player, container_entity, "itemlose", InventoryEventService.EVENT.ITEM_REMOVED)
                    _ensureContainerListener(player, container_entity, "itemget", InventoryEventService.EVENT.ITEM_ADDED)
                end
            end
        end
    end
end

-- 覆盖背包延迟出现 + 容器动态开合：独立监听（不依赖订阅），确保候选及时刷新
local function _ensureContainerHooks(player)
    player:ListenForEvent("refreshinventory", function()
        _ensureContainerListenersForPlayer(player)
    end)
    player:ListenForEvent("onopencontainer", function(inst, data)
        if data and data.container and data.container:IsValid() then
            _ensureContainerListener(player, data.container, "itemlose", InventoryEventService.EVENT.ITEM_REMOVED)
            _ensureContainerListener(player, data.container, "itemget", InventoryEventService.EVENT.ITEM_ADDED)
        end
    end)
    player:ListenForEvent("onclosecontainer", function(inst, data)
        if data and data.container then
            _removeContainerListener(data.container, "itemlose")
            _removeContainerListener(data.container, "itemget")
        end
    end)
end

-- 确保玩家状态已初始化（含 onremove 清理监听）
-- 置于容器监听函数（_ensureContainerListenersForPlayer / _ensureContainerHooks）之后定义，
-- 使其 local 声明已进入作用域，避免被当作全局访问导致运行期崩溃。
local function _ensurePlayer(player)
    local p = _players[player]
    if p then return p end

    p = { raw_handlers = {}, subs = {} }

    local onremove_handler = function(inst)
        _cleanupPlayer(player)
    end
    p.onremove_handler = onremove_handler
    player:ListenForEvent("onremove", onremove_handler)

    _players[player] = p

    -- 容器（背包/打开容器）物品增删也需转发到玩家级 ITEM_ADDED/ITEM_REMOVED：
    -- 官方 container_replica 的 itemlose/itemget 派发在“容器实体”而非 ThePlayer 上，
    -- 仅监听 ThePlayer 会导致物品从背包/容器移除时按钮候选不刷新（旧 item 残留）。
    _ensureContainerListenersForPlayer(player)
    _ensureContainerHooks(player)
    return p
end

-- 确保 raw_event 已注册监听器（每个 raw_event 每个玩家只注册一次）
local function _ensureListener(player, raw_event, svc_event)
    local p = _ensurePlayer(player)

    if not p.raw_handlers[raw_event] then
        local dispatcher = _makeDispatcher(raw_event, svc_event, player)
        p.raw_handlers[raw_event] = dispatcher
        p.subs[svc_event] = p.subs[svc_event] or {}
        player:ListenForEvent(raw_event, dispatcher)
    end
end

-- 清理玩家所有监听器
function _cleanupPlayer(player)
    local p = _players[player]
    if not p then return end

    -- 移除 onremove 清理回调
    if p.onremove_handler then
        player:RemoveEventCallback("onremove", p.onremove_handler)
    end

    -- 移除所有 raw 事件监听器
    for raw_event, handler in pairs(p.raw_handlers) do
        player:RemoveEventCallback(raw_event, handler)
    end

    _players[player] = nil
end

--- 订阅物品事件
--- @param event   string  事件名（InventoryEventService.EVENT.* 之一）
--- @param fn      function 回调，接收事件 data
--- @param player  EntityScript 可选，默认 ThePlayer
--- @return function 调用以取消订阅
function InventoryEventService:On(event, fn, player)
    player = player or ThePlayer
    if not player or type(fn) ~= "function" then
        return function() end
    end

    local raw_list = RAW_EVENT_MAP[event]
    if not raw_list then
        return function() end
    end

    for _, raw_event in ipairs(raw_list) do
        _ensureListener(player, raw_event, event)
    end

    local subs = _players[player].subs[event]
    subs[#subs + 1] = fn

    return function()
        for i = #subs, 1, -1 do
            if subs[i] == fn then
                table.remove(subs, i)
                return
            end
        end
    end
end

--- 取消订阅物品事件（对标 RemoveEventCallback）
--- @param event   string  事件名
--- @param fn      function 之前注册的回调
--- @param player  EntityScript 可选，默认 ThePlayer
function InventoryEventService:Off(event, fn, player)
    player = player or ThePlayer
    if not player or not fn then return end

    local p = _players[player]
    if not p then return end

    local subs = p.subs[event]
    if not subs then return end

    for i = #subs, 1, -1 do
        if subs[i] == fn then
            table.remove(subs, i)
            break
        end
    end

    -- 如果该事件已无订阅者，移除底层 raw 事件监听器
    if #subs == 0 then
        local raw_list = RAW_EVENT_MAP[event]
        if raw_list then
            for _, raw_event in ipairs(raw_list) do
                if p.raw_handlers[raw_event] then
                    player:RemoveEventCallback(raw_event, p.raw_handlers[raw_event])
                    p.raw_handlers[raw_event] = nil
                end
            end
        end
        p.subs[event] = nil
    end
end

--- 向后兼容：等价于 On(EVENT.ITEM_ADDED, callback, player)
function InventoryEventService:OnItemGet(callback, player)
    return self:On(self.EVENT.ITEM_ADDED, callback, player)
end

return InventoryEventService