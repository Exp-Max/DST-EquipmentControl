--[[
    Equipment Control Mod - Auto Container Module
    容器功能模块

    PART 1 - 自动容器收集：
    - 糖果袋(candybag)：自动收集万圣节物品到专用容器
    - 种子袋(seedpouch)：自动收集种子类物品到专用容器

    PART 2 - 箱子记忆显示：
    - 无需打开箱子即可查看内容物图标
    - 历史回溯：全局滑块统一控制快照回看
    - 悬停高亮：物品栏/制作菜单悬停时高亮包含该物品的箱子
    - 跨会话持久化：通过 EC 的 FileSystem 存储
    - 显示模式切换：all(全部)/single(悬停)/hidden(隐藏)

    PART 4 - 智能取物 / 中键收纳 / 容器绿光：
    - 右键制作材料 → 自动从附近容器取出物品
    - 右键制作栏/固定配方 → 自动取材料
    - 中键背包物品 → 存入附近同类容器
    - 材料悬停 → 绿色高亮含该材料的实体容器
]]

--============================================================================
-- 公共依赖
--============================================================================
local InventoryUtil = require "util/inventoryutil"
local PlayerUtil = require "util/playerutil"
local ItemUtil      = require "util/itemutil"
local WorldUtil     = require "util/worldutil"
local ShowMeUtil    = require "util/showmeutil"
local InsightUtil   = require "util/insightutil"
local FileSystem    = require "util/filesystem"
local Say           = require "util/say"
local CameraUtil    = require "util/camerautil"
local Containers    = require "containers"

local CONFIG = MOD_EQUIPMENT_CONTROL.CONFIG
local MODNAME = MOD_EQUIPMENT_CONTROL.MODNAME

--============================================================================
-- PART 1: 自动容器收集（糖果袋 / 种子袋）
--============================================================================

local EventManager = {}
local IsMasterSim = WorldUtil:IsMasterSim()

-- 快速移动优先容器
local UpvalueHacker = require "util/upvaluehacker"
local bundle_first = GetModConfigData("BUNDLE_FIRST", MODNAME)
local stewer_first = GetModConfigData("STEWER_FIRST", MODNAME)

if bundle_first or stewer_first then
    local InvSlot = require("widgets/invslot")
    if InvSlot ~= nil and type(InvSlot.TradeItem) == "function" then
        local orig_find, upvalue_index, scope_fn =
            UpvalueHacker.GetUpvalue(InvSlot.TradeItem, "FindBestContainer")
        if type(orig_find) == "function" and upvalue_index ~= nil then
            local function SubsetByTag(containers, tag)
                local subset
                for ent in pairs(containers) do
                    if ent ~= nil and ent:HasTag(tag) then
                        if subset == nil then subset = {} end
                        subset[ent] = true
                    end
                end
                return subset
            end
            local function FindBestContainerWrapper(self, item, containers, exclude_containers)
                if item == nil or containers == nil then
                    return orig_find(self, item, containers, exclude_containers)
                end
                if bundle_first then
                    local bundles = SubsetByTag(containers, "bundle")
                    if bundles ~= nil then
                        local best = orig_find(self, item, bundles, exclude_containers)
                        if best ~= nil then return best end
                    end
                end
                if stewer_first then
                    local stewers = SubsetByTag(containers, "stewer")
                    if stewers ~= nil then
                        local best = orig_find(self, item, stewers, exclude_containers)
                        if best ~= nil then return best end
                    end
                end
                return orig_find(self, item, containers, exclude_containers)
            end
            debug.setupvalue(scope_fn, upvalue_index, FindBestContainerWrapper)
        end
    end
end

local CONTAINERS = {
    {
        prefab = "candybag",
        validateItem = function(data)
            local item = data and data.item
            if not item then return false end
            return item:HasTag("halloweencandy")
                or item:HasTag("halloween_ornament")
                or string.sub(item.prefab, 1, 8) == "trinket_"
        end
    },
    {
        prefab = "seedpouch",
        validateItem = function(data)
            local item = data and data.item
            if not item then return false end
            return item:HasTag("deployedfarmplant")
                or item:HasTag("edible_SEEDS")
        end
    }
}

local function AddEvent_AutoCollect(event, callback)
    ThePlayer:ListenForEvent(event, callback)
    EventManager[#EventManager + 1] = { event = event, callback = callback }
end

local function RemoveEvents_AutoCollect()
    for i = 1, #EventManager do
        ThePlayer:RemoveEventCallback(EventManager[i].event, EventManager[i].callback)
        EventManager[i] = nil
    end
end

local function GetContainerConfig(prefab)
    for _, config in ipairs(CONTAINERS) do
        if config.prefab == prefab then return config end
    end
    return nil
end

local function ValidateContainer(data)
    if not data or not data.item then return nil end
    return GetContainerConfig(data.item.prefab)
end

local function OnGetItem(inst, data, validateFunc)
    if validateFunc(data) then
        inst:DoTaskInTime(IsMasterSim and 0 or FRAMES * 4, function()
            if InventoryUtil:ContainsItem(data.item)
                and InventoryUtil:GetBackpack()
                and not InventoryUtil:GetBackpack():IsFull() then
                local backpack = InventoryUtil:FindEquipped(function(item)
                    return ItemUtil:IsBackpack(item)
                end)
                if backpack then
                    InventoryUtil:MoveItemFromAllOfSlot(data.slot, backpack)
                end
            end
        end)
    end
end

local function OnContainerUnequip_AutoCollect(inst, data)
    if data and data.item and ItemUtil:IsBackpack(data.item) then
        RemoveEvents_AutoCollect()
    end
end

local function OnContainerEquip_AutoCollect(config)
    RemoveEvents_AutoCollect()
    AddEvent_AutoCollect("gotnewitem", function(inst, data)
        OnGetItem(inst, data, config.validateItem)
    end)
    AddEvent_AutoCollect("unequip", OnContainerUnequip_AutoCollect)
end

--============================================================================
-- PART 2: 箱子记忆显示
--============================================================================

local ChestMemoryDisplay = require "widgets/chestmemorydisplay"

local CM_loaded_radius = 80
local CM_MAX_WORLDS  = 3
local CM_MAX_HISTORY = 3
local CM_DATA_PREFIX = MODNAME .. "_chest_memory_"

local CM = {
    chestwidgets  = {},
    chest         = {},
    data          = {},
    index         = {},   -- 索引键 -> data 键数组，替代全表线性扫描
    next_id       = 1,
    MAX_HISTORY   = CM_MAX_HISTORY,
    openedchest   = nil,
    seed          = nil,
    highlightedchest = nil,
    highlightitem = nil,
    displaytype   = nil,
    player        = nil,
    listener_world = nil,
    activeitem_player = nil,
    activeitem_fn = nil,
    container_event_player = nil,
    open_container_fn = nil,
    close_container_pre_fn = nil,
    close_container_fn = nil,
    data_loaded    = false,
    dirty          = false,   -- 内容有变化但尚未落盘
    pending_save_seed = nil,
}

local CM_MUST_HAVE_TAGS   = { "_container" }
local CM_CANT_HAVE_TAGS   = { "INLIMBO", "_equippable", "backpack", "burnt" }

-- 每个世界一个独立文件：读/写时不再把其它世界的数据一起解析、重写。
function CM:GetPersistenceKey()
    return CM_DATA_PREFIX .. tostring(self.seed or WorldUtil:GetWorldSeed())
end

function CM:GetIndexKey()
    return MODNAME .. "_chest_memory_worlds"
end

function CM:GetLegacyKey()
    return MODNAME .. "_chest_memory"
end

function CM:ResetData()
    self.data = {}
    self.index = {}
    self.next_id = 1
    self.dirty = false
end

local function DataIndexKey(item_data)
    if item_data.mobile then
        return "m|" .. tostring(item_data.prefab)
    end
    return "p|" .. tostring(item_data.prefab) .. "|" .. tostring(item_data.x) .. "|" .. tostring(item_data.z)
end

local function TrimHistory(history)
    if type(history) ~= "table" then return end
    while #history > CM_MAX_HISTORY do
        table.remove(history, 1)
    end
end

-- 只保留最近 3 个世界：超出配额的世界数据文件、旧的单文件合并存档一并清理。
function CM:PruneWorldFiles(seed)
    FileSystem:LoadTableFromFile(self:GetIndexKey(), function(index_data)
        local old_order = type(index_data._order) == "table" and index_data._order or {}
        local order = { seed }
        for _, old_seed in ipairs(old_order) do
            if old_seed ~= seed then
                if #order < CM_MAX_WORLDS then
                    order[#order + 1] = old_seed
                else
                    FileSystem:EraseFile(CM_DATA_PREFIX .. tostring(old_seed))
                end
            end
        end
        if not index_data.legacy_cleared then
            FileSystem:EraseFile(self:GetLegacyKey())
        end
        FileSystem:SaveTableToFile(self:GetIndexKey(), { _order = order, legacy_cleared = true })
    end)
end

function CM:LoadData()
    local seed = self.seed or WorldUtil:GetWorldSeed()
    if not seed then return end
    self.seed = seed
    self:ResetData()
    self.data_loaded = false

    self:PruneWorldFiles(seed)

    FileSystem:LoadTableFromFile(self:GetPersistenceKey(), function(data)
        if self.seed ~= seed then
            return
        end
        for _, info in pairs(data) do
            if type(info) == "table" and info.prefab ~= nil then
                TrimHistory(info.history)
                self:ModifyOrAddData(info)
            end
        end
        self.data_loaded = true
        self.dirty = false
        for _, widget in pairs(self.chestwidgets) do
            local has_existing_data = false
            for __, __v in pairs(widget.CS_contents) do
                has_existing_data = true
            end
            if not has_existing_data then
                local observed_contents = widget._olditemtrigger and widget.CS_contents or nil
                widget:LoadChestData()
                if observed_contents ~= nil then
                    widget._olditems = widget.CS_contents
                    widget._olditemtrigger = true
                    widget.CS_contents = observed_contents
                    widget:RefreshItems()
                end
            end
            if self.openedchest == widget:GetOwner() then
                widget:OnContainerOpened()
            end
        end
        if self.pending_save_seed == seed then
            self.pending_save_seed = nil
            self:SaveData()
        end
    end)
end

local function UpdateWidgetData(widget)
    local owner = widget:GetOwner()
    if owner ~= nil and owner:IsValid() then
        widget:UpdateSavedData()
    end
end

-- 传入 widget 时只回写该容器；不传则全量回写。
-- 关箱已不再调用本函数（只更新内存缓存并标脏），落盘由新一天 / 退出 / 切世界 / 关总开关触发。
function CM:SaveData(widget)
    if not self.data_loaded then
        self.pending_save_seed = self.seed or WorldUtil:GetWorldSeed()
        return
    end

    if widget ~= nil then
        UpdateWidgetData(widget)
    else
        for _, w in pairs(self.chestwidgets) do
            UpdateWidgetData(w)
        end
    end
    if not self.seed then
        self.seed = WorldUtil:GetWorldSeed()
    end
    if not self.seed then return end

    local persist_data = {}
    for k, info in pairs(self.data) do
        if not info.mobile then
            persist_data[k] = info
        end
    end

    -- 每世界独立文件，内存里已是该世界的完整数据：直接整体覆盖写，
    -- 不再读旧文件、不再深拷贝、不再跨世界 read-modify-write。
    FileSystem:SaveTableToFile(self:GetPersistenceKey(), persist_data)
    self.dirty = false
end

-- 新一天 / 季节切换时调用：有未落盘的变化才写一次。
function CM:FlushIfDirty()
    if self.dirty then
        self:SaveData()
    end
end

function CM:AllocDataKey()
    local key
    repeat
        key = tostring(self.next_id)
        self.next_id = self.next_id + 1
    until self.data[key] == nil
    return key
end

function CM:ModifyOrAddData(item_data)
    self.dirty = true
    TrimHistory(item_data.history)
    local bucket_key = DataIndexKey(item_data)
    local bucket = self.index[bucket_key]
    if bucket == nil then
        bucket = {}
        self.index[bucket_key] = bucket
    end

    -- 同 prefab/坐标的记录都在一个桶里，桶通常只有 1 项，不再扫全表。
    for i = #bucket, 1, -1 do
        local k = bucket[i]
        local info = self.data[k]
        if info == nil then
            table.remove(bucket, i)
        elseif item_data.chest_type == nil or info.chest_type == nil
            or item_data.chest_type == info.chest_type then
            if info.history and item_data.history and #item_data.history <= #info.history then
                item_data.history = info.history
                item_data.historytime = info.historytime
            end
            if next(item_data.contents or {}) == nil and next(info.contents or {}) ~= nil then
                item_data.contents = info.contents
            end
            self.data[k] = item_data
            return
        end
    end

    local key = self:AllocDataKey()
    self.data[key] = item_data
    bucket[#bucket + 1] = key
end

function CM:RemoveData(key)
    local info = self.data[key]
    if info == nil then return end
    self.dirty = true
    local bucket = self.index[DataIndexKey(info)]
    if bucket ~= nil then
        for i, k in ipairs(bucket) do
            if k == key then
                table.remove(bucket, i)
                break
            end
        end
    end
    self.data[key] = nil
end

function CM:GetData(prefab, x, z, chest_type)
    for _, info in pairs(self.data) do
        if info.prefab == prefab then
            local pos_match = info.mobile or (info.x == x and info.z == z)
            local type_match = info.chest_type == nil or info.chest_type == chest_type
            if pos_match and type_match then
                return info
            end
        end
    end
    return {}
end

-- 容器工具函数
function CM:AddWidget(owner)
    if not owner or self.chest[owner]
        or not owner:IsValid()
        or not InventoryUtil:GetContainerReplica(owner) then
        return
    end
    if not ThePlayer.HUD then return end

    local widget = ChestMemoryDisplay(owner, self)
    widget.mobile = self:IsMobileContainer(owner)
    ThePlayer.HUD:AddChild(widget)
    widget:HandleWidgetDisplay()
    self.chest[owner] = widget
    table.insert(self.chestwidgets, widget)

    if widget.mobile then
        owner:ListenForEvent("onremove", function()
            self:RemoveWidget(widget, true)
            widget:Kill()
            widget:StopUpdating()
        end)
    end
end

function CM:RemoveWidget(_widget, chest_trigger)
    local owner, widget_num
    for k, widget in pairs(self.chestwidgets) do
        if widget == _widget then
            owner = widget:GetOwner()
            widget_num = k
            break
        end
    end
    if not chest_trigger and widget_num then
        self.chestwidgets[widget_num]:DoRemove()
    end
    if widget_num then
        if _widget.mobile and owner ~= nil then
            local prefab = owner.prefab
            local pos = owner:GetPosition()
            local x = pos and tonumber(string.format("%.1f", pos.x))
            local z = pos and tonumber(string.format("%.1f", pos.z))
            for k, info in pairs(self.data) do
                if info.mobile and info.prefab == prefab
                    and (info.x == nil or x == nil or math.abs(info.x - x) < 2)
                    and (info.z == nil or z == nil or math.abs(info.z - z) < 2) then
                    self:RemoveData(k)
                end
            end
        end
        table.remove(self.chestwidgets, widget_num)
    end
    if owner then
        self.chest[owner] = nil
    end
end

function CM:RemoveAllWidgets()
    for _, widget in pairs(self.chestwidgets) do
        local owner = widget:GetOwner()
        if owner ~= nil and owner:IsValid() and owner.AnimState ~= nil then
            owner.AnimState:SetAddColour(0, 0, 0, 0)
        end
        widget:DoRemove()
    end
    self.chest = {}
    self.chestwidgets = {}
    self.highlightedchest = nil
end

-- 按当前镜头批量重算所有箱子预览的位置与显隐。
-- 只在「相机真的变了 / 模式切换 / 容器事件」时调用，不放在每个 widget 的 OnUpdate 里。
function CM:RefreshAllWidgets()
    for _, widget in pairs(self.chestwidgets) do
        widget:HandleWidgetDisplay()
    end
end

-- 相机每帧更新（官方 AddListener）时批量刷新，逐帧跟随镜头；注册/注销走 util/camerautil 的官方透传。
local function OnChestMemoryCameraChanged()
    if CONFIG.CHEST_MEMORY_ENABLED
        and CONFIG.CHEST_MEMORY_DISPLAY_TYPE ~= "hidden"
        and #CM.chestwidgets > 0 then
        CM:RefreshAllWidgets()
    end
end

local function EnsureChestMemoryCameraListener()
    if CM.camera_listening then return end
    CM.camera_listening = CameraUtil.AddListener(CM, OnChestMemoryCameraChanged)
end

local function RemoveChestMemoryCameraListener()
    if not CM.camera_listening then return end
    CameraUtil.RemoveListener(CM, OnChestMemoryCameraChanged)
    CM.camera_listening = false
end

function CM:SetAndPushDisplayType(display_type)
    self.displaytype = display_type
    for _, widget in pairs(self.chestwidgets) do
        widget:UpdateDisplayType()
    end
    -- 按当前镜头立刻重算位置与显隐，不用等下一次鼠标事件
    self:RefreshAllWidgets()
end

function CM:ChangeHighlighting(bool, item_prefab)
    for _, widget in pairs(self.chestwidgets) do
        widget:HighlightWithItem(bool, item_prefab)
    end
end

function CM:IsMobileContainer(inst)
    return inst:IsValid() and (
        inst:HasTag("locomotor") or
        inst:HasTag("_inventoryitem")
    )
end

function CM:SetOpenedContainer(chest)
    self.openedchest = chest
end

local function AddChestDisplayToNearbyChests()
    if not ThePlayer then return end
    local pos = ThePlayer:GetPosition()
    local chests = TheSim:FindEntities(pos.x, pos.y, pos.z, CM_loaded_radius,
        CM_MUST_HAVE_TAGS, CM_CANT_HAVE_TAGS)
    for _, chest in pairs(chests) do
        if InventoryUtil:GetContainerReplica(chest) then
            CM:AddWidget(chest)
        end
    end
end

local function AddChestMemoryWidget(inst)
    if not CONFIG.CHEST_MEMORY_ENABLED or not ThePlayer or not ThePlayer.HUD
        or not InventoryUtil:IsContainer(inst) or not InventoryUtil:GetContainerReplica(inst)
        or inst.Transform == nil
        or inst:HasTag("INLIMBO") or inst:HasTag("_equippable")
        or inst:HasTag("backpack") or inst:HasTag("burnt")
        or inst:HasTag("chester")
        or inst.prefab == "bundle_container" then  -- 瞬时打包容器，不记记忆（参考模组 bancontainers）
        return
    end

    local player_pos = ThePlayer:GetPosition()
    local chest_pos = inst:GetPosition()
    local dx = player_pos.x - chest_pos.x
    local dz = player_pos.z - chest_pos.z
    if dx * dx + dz * dz <= CM_loaded_radius * CM_loaded_radius then
        CM:AddWidget(inst)
    end
end

local function OnChestMemoryContainerOpened(player, data)
    if not CONFIG.CHEST_MEMORY_ENABLED then return end
    local container = data and data.container
    if container == nil or not container:IsValid() then return end
    CM:SetOpenedContainer(container)
    local widget = CM.chest[container]
    if widget == nil then
        AddChestMemoryWidget(container)
    else
        widget:OnContainerOpened()
    end
end

local function OnChestMemoryContainerClosing(player, data)
    if not CONFIG.CHEST_MEMORY_ENABLED then return end
    local container = data and data.container
    if container == nil or not container:IsValid() then return end
    local widget = container and CM.chest[container]
    if widget ~= nil and widget._alreadyopenedonce then
        widget:UpdateItemMemory(data.widget and data.widget.inv)
    end
end

local function OnChestMemoryContainerClosed(player, data)
    local closed_container = data and data.container
    local closed_widget = closed_container and closed_container:IsValid()
        and CM.chest[closed_container] or nil
    if closed_widget ~= nil then
        if closed_widget._alreadyopenedonce then
            closed_widget:DoHistoryAndContentMiniSave()
            closed_widget._alreadyopenedonce = false
        else
            closed_widget:UpdateSavedData()
        end
    end

    local inventory = InventoryUtil:GetInventory()
    -- 此处要官方原始的 {[entity]=true} 集合；InventoryUtil:GetOpenContainers() 返回过滤后的 replica 数组，语义不同
    local open_containers = inventory and inventory:GetOpenContainers() or {}
    local open_chest
    for container in pairs(open_containers) do
        if CM.chest[container] then
            open_chest = container
            break
        end
    end
    CM:SetOpenedContainer(open_chest)
    -- 只更新内存缓存（UpdateSavedData 会标脏），落盘统一等新一天 / 退出 / 切世界
end

AddPrefabPostInitAny(function(inst)
    inst:DoTaskInTime(0, function(inst)
        AddChestMemoryWidget(inst)
    end)
end)

-- 箱子记忆显示模式循环
local CM_CYCLES = { "all", "single", "hidden" }

-- [Ref-4] 2188383679/modmain.lua:305-335
-- 原模组切换模式时补扫附近箱子(:328) + talker:Say 提示(:318)；EC 已对齐这两点。
local function CycleChestMemoryDisplay()
    -- 从当前配置推导下一档：配置是异步读回存档的，另存一份本地索引会让首次切换跳错档
    local current = CONFIG.CHEST_MEMORY_DISPLAY_TYPE or "all"
    local index = 1
    for i, cycle_mode in ipairs(CM_CYCLES) do
        if cycle_mode == current then
            index = i
            break
        end
    end
    local mode = CM_CYCLES[index % #CM_CYCLES + 1]

    CONFIG.CHEST_MEMORY_DISPLAY_TYPE = mode
    MOD_EQUIPMENT_CONTROL.ConfigSave()
    CM:SetAndPushDisplayType(mode)
    -- 走动后靠近的箱子可能还没登记 widget，切到非隐藏模式时补扫一次（原模组 :328）
    if mode ~= "hidden" then
        AddChestDisplayToNearbyChests()
    end

    local strings = MOD_EQUIPMENT_CONTROL.STRINGS
    Say(string.format(strings.PROMPTS.CHEST_MEMORY_DISPLAY_MODE,
        strings.CHEST_MEMORY_DISPLAY[string.upper(mode)] or mode))
end

local function OnChestMemorySeasonTick()
    CM:FlushIfDirty()
end

-- 新一天开始：当天所有变化合并成一条历史（每容器最多 3 条），然后一次性落盘。
local function OnChestMemoryDayChanged(cycles)
    local day = math.floor(tonumber(cycles) or 0) + 1
    for _, widget in pairs(CM.chestwidgets) do
        if widget._pending_history then
            widget:TryPushPendingHistory(day)
        end
    end
    if CONFIG.CHEST_MEMORY_ENABLED then
        CM:FlushIfDirty()
    end
end

local function OnChestMemoryPlayerDeactivated(_, player)
    local container = CM.openedchest
    local widget = container and CM.chest[container]
    local replica = container and InventoryUtil:GetContainerReplica(container)
    if widget ~= nil and widget._alreadyopenedonce and replica ~= nil
        and replica:IsOpenedBy(player or ThePlayer) then
        widget:UpdateItemMemory()
    end
    CM:SaveData()
    CM:RemoveAllWidgets()
    CM.openedchest = nil
    if CM.container_event_player ~= nil and CM.container_event_player:IsValid() then
        CM.container_event_player:RemoveEventCallback("onopencontainer", CM.open_container_fn)
        CM.container_event_player:RemoveEventCallback("onclosecontainer_pre", CM.close_container_pre_fn)
        CM.container_event_player:RemoveEventCallback("onclosecontainer", CM.close_container_fn)
    end
    if CM.activeitem_player ~= nil and CM.activeitem_player:IsValid() and CM.activeitem_fn ~= nil then
        CM.activeitem_player:RemoveEventCallback("newactiveitem", CM.activeitem_fn)
    end
    CM.container_event_player = nil
    CM.open_container_fn = nil
    CM.close_container_pre_fn = nil
    CM.close_container_fn = nil
    CM.activeitem_player = nil
    CM.activeitem_fn = nil
    RemoveChestMemoryCameraListener()
    CM.player = nil
end

local function OnChestMemoryActiveItem(_, data)
    if CONFIG.CHEST_MEMORY_ENABLED then
        CM:ChangeHighlighting(true, data.item and data.item.prefab or "")
    end
end

local function EnsureChestMemoryWorldListeners()
    if CM.listener_world == TheWorld then return end
    if CM.listener_world ~= nil and CM.listener_world:IsValid() then
        CM.listener_world:RemoveEventCallback("seasontick", OnChestMemorySeasonTick)
        CM.listener_world:RemoveEventCallback("playerdeactivated", OnChestMemoryPlayerDeactivated)
    end
    if CM._day_watcher_id then
        WorldUtil:StopWatchingState(CM._day_watcher_id)
        CM._day_watcher_id = nil
    end
    CM.listener_world = TheWorld
    TheWorld:ListenForEvent("seasontick", OnChestMemorySeasonTick)
    TheWorld:ListenForEvent("playerdeactivated", OnChestMemoryPlayerDeactivated)
    CM._day_watcher_id = WorldUtil:WatchState("cycles", OnChestMemoryDayChanged, TheWorld)
end

local function SetChestMemoryEnabled(enabled)
    if enabled then
        MOD_EQUIPMENT_CONTROL.InitChestMemory()
    else
        CM:SaveData()
        CM:RemoveAllWidgets()
        CM.openedchest = nil
        CM.highlightedchest = nil
    end
end

--============================================================================
-- PART 4: 智能取物 / 中键收纳 / 容器绿色高亮
--============================================================================

local CM_highlighted_boxes = {}

local function CM_GetContainerPrefabAndPos(chest)
    if not chest then return end
    local pos = chest:GetPosition()
    if not pos then return end
    local prefab = chest.prefab
    local boat = TheWorld and TheWorld.Map and TheWorld.Map.GetPlatformAtPoint
        and TheWorld.Map:GetPlatformAtPoint(pos.x, pos.z)
    local chest_type = boat and "boat" or "static"
    local x, z
    if boat then
        local boat_pos = boat:GetPosition()
        x = tonumber(string.format("%.2f", boat_pos.x - pos.x))
        z = tonumber(string.format("%.2f", boat_pos.z - pos.z))
    else
        x = tonumber(string.format("%.1f", pos.x))
        z = tonumber(string.format("%.1f", pos.z))
    end
    return prefab, x, z, chest_type
end

local function CM_GetMemoryContents(chest)
    if InventoryUtil:IsContainerOpenedBy(chest) then
        local container = InventoryUtil:GetContainerReplica(chest)
        return container and container:GetItems() or {}
    end
    local widget = CM.chest and CM.chest[chest]
    if widget and widget.GetItems then
        return widget:GetItems() or {}
    end
    local prefab, x, z, chest_type = CM_GetContainerPrefabAndPos(chest)
    if not prefab then return {} end
    local info = CM:GetData(prefab, x, z, chest_type)
    return info.contents or {}
end

local function CM_ContainerHasItem(chest, target_prefab)
    if InventoryUtil:IsContainerOpenedBy(chest) then
        return InventoryUtil:HasContainerItem(chest, target_prefab)
    end
    for _, slot in pairs(CM_GetMemoryContents(chest)) do
        if slot.prefab == target_prefab then
            return true
        end
    end
    return false
end

-- 容器能否再接收指定 prefab：
-- 已开容器读 live replica；未开容器依赖箱子记忆（基本物品信息含 stacksize / stackmaxsize）。
-- 两种情况都需满足“存在未满同物堆（可合并）或存在空槽（可放新堆）”才接收，
-- 否则（已满且同物堆已满）明确拒绝，避免缓冲出注定失败的 STORE。
local function CM_ContainerCanAccept(inst, prefab)
    local replica = InventoryUtil:GetContainerReplica(inst)
    if replica == nil then return false end
    if InventoryUtil:IsContainerOpened(replica) then
        local items = replica:GetItems()
        if items ~= nil then
            for _, v in pairs(items) do
                if v ~= nil and v.prefab == prefab then
                    local cur = InventoryUtil:GetStackSize(v)
                    local max = InventoryUtil:GetMaxSize(v)
                    if max ~= nil and cur < max then
                        return true
                    end
                end
            end
        end
        local free = InventoryUtil:GetFreeSlotCount(replica)
        return free ~= nil and free > 0 or false
    end
    -- 未开容器：用箱子记忆判定（CM_GetMemoryContents 返回基本物品信息数组，空槽为 {}）
    local contents = CM_GetMemoryContents(inst)
    if contents == nil then return true end
    local total, occupied, mergeable = 0, 0, false
    for _, slot in pairs(contents) do
        if slot ~= nil then
            total = total + 1
            if slot.prefab ~= nil then
                occupied = occupied + 1
                if slot.prefab == prefab then
                    -- 不可堆叠物品无法合并，只能放进空槽（下方 occupied < total 判定）
                    if slot._stackable then
                        local cur = slot.stacksize or 1
                        local max = slot.stackmaxsize
                        if max == nil then
                            mergeable = true            -- 记忆缺上限信息，保守认为可合并
                        elseif cur < max then
                            mergeable = true
                        end
                    end
                end
            end
        end
    end
    if mergeable then return true end
    if total > 0 and occupied < total then return true end  -- 仍有空槽
    if total == 0 then return true end                       -- 记忆不可用，保守放行
    return false
end

local function CM_FindInCon(con, prefab)
    local container = InventoryUtil:GetContainerReplica(con)
    if container == nil then return end
    for k, v in pairs(container:GetItems()) do
        if v.prefab == prefab then
            return v, k
        end
    end
end

local function CM_DoSceneAction(target, action)
    local pos = target:GetPosition()
    local pc = PlayerUtil:GetComponent("playercontroller")
    if PlayerUtil:CanLocomote() then
        local ba = BufferedAction(ThePlayer, target, action)
        ba.preview_cb = function()
            SendRPCToServer(RPC.LeftClick, action.code, pos.x, pos.z, target)
        end
        pc:DoAction(ba)
    else
        SendRPCToServer(RPC.LeftClick, action.code, pos.x, pos.z, target)
    end
end

local function CM_CanPutIn(container, item)
    local contab = Containers.params[container.prefab]
    local testfn = contab and contab.itemtestfn
    if testfn then
        return testfn(InventoryUtil:GetContainerReplica(container), item, 1)
    end
    return true
end

-- ShowMe / Insight 服务器容器追踪（仅 Insight；取物兜底判断，避免 ShowMe 独占时误跳过 EC 记忆）
local function CM_HasShowmeOrInsight()
    return InsightUtil.IsAvailable()
end

-- ShowMe / Insight 任一模组可用（高亮场景：交给模组自身处理世界容器高亮，EC 不重复）
local function CM_TrackerAvailable()
    return ShowMeUtil.IsAvailable() or InsightUtil.IsAvailable()
end

-- 容器内容检查：收敛到工具文件，EC 不再自行实现
-- （ShowMeUtil 读实体 ShowMe_chest_table；InsightUtil 读 replica.insight:ContainerHas）
local function CM_CheckShowmeAndInsight(inst, prefab)
    return ShowMeUtil.ContainerHas(inst, prefab) or InsightUtil.ContainerHas(inst, prefab)
end

-- 右键材料/配方 → 从附近容器自动取出物品
local function CM_FindAndRetrieve(prefab, num, deepth)
    deepth = deepth or 0
    if deepth > 7 or not prefab then return end

    local box = FindEntity(ThePlayer, 30, function(inst)
        if not InventoryUtil:IsContainer(inst) then return false end
        if inst.replica.inventoryitem and inst.replica.inventoryitem:IsGrandOwner(ThePlayer) then
            return false
        end
        -- ShowMe / Insight 实时数据（服务器提供，最准确）
        if CM_CheckShowmeAndInsight(inst, prefab) then
            return true
        end
        -- 已打开且包含该物品的容器
        if InventoryUtil:IsContainerOpenedBy(inst) and InventoryUtil:HasContainerItem(inst, prefab) then
            return true
        end
        -- 若 ShowMe / Insight 已存在则不再查 CM 记忆（避免冗余命中空数据）
        if inst.ShowMe_chest_table or CM_HasShowmeOrInsight() then
            return false
        end
        -- EC 箱子记忆快照数据
        if CM_ContainerHasItem(inst, prefab) then
            return true
        end
        return false
    end)

    if box then
        local opened = InventoryUtil:IsContainerOpenedBy(box)
        if opened then
            local item, k = CM_FindInCon(box, prefab)
            if num and item then
                local nowsize = InventoryUtil:GetStackSize(item) or 1
                local diff = nowsize - num
                if diff > 0 then
                    -- 直接取 num 个到物品栏：游戏本体 MoveItemFromCountOfSlot 内部走 ReceiveItem，
                    -- 自动合并到同物非满堆 / 放入空槽（就是本体已有的逻辑），无需先取到鼠标再手动遍历找槽位。
                    SendRPCToServer(RPC.MoveItemFromCountOfSlot, k, box, nil, num)
                else
                    SendRPCToServer(RPC.MoveItemFromAllOfSlot, k, box, nil)
                    if diff ~= 0 then
                        ThePlayer:DoTaskInTime(0.1, function()
                            CM_FindAndRetrieve(prefab, -diff, deepth + 1)
                        end)
                    end
                end
            elseif k then
                SendRPCToServer(RPC.MoveItemFromAllOfSlot, k, box, nil)
            else
            end
        else
            CM_DoSceneAction(box, ACTIONS.RUMMAGE)
        end
    else
        -- 地上掉落物
        box = FindEntity(ThePlayer, 80, function(inst)
            return inst.prefab == prefab
        end)
        if box then
            CM_DoSceneAction(box, ACTIONS.PICKUP)
        end
    end
end

-- 绿色高亮世界容器
local function CM_HighlightBox(ent)
    if not ent then return end
    if not ent.components.highlight then
        ent:AddComponent("highlight")
    end
    if ent.components.highlight then
        ent.components.highlight:SetAddColour({ x = 0, y = 128 / 255, z = 0 })
        ent.components.highlight.highlit = true
    end
    CM_highlighted_boxes[ent] = true
end

local function CM_ClearHighlights()
    for ent, _ in pairs(CM_highlighted_boxes) do
        if ent:IsValid() and ent.components.highlight then
            ent.components.highlight:UnHighlight()
        end
    end
    CM_highlighted_boxes = {}
end

local function CM_RefreshContainerHighlight(prefab)
    CM_ClearHighlights()
    if not prefab or not ThePlayer then return end
    if CM_TrackerAvailable() then
        return
    end
    local px, _, pz = ThePlayer:GetPosition():Get()
    for _, ent in pairs(TheSim:FindEntities(px, 0, pz, 30, CM_MUST_HAVE_TAGS)) do
        if CM_ContainerHasItem(ent, prefab) then
            CM_HighlightBox(ent)
        end
    end
end

-- 物品栏/材料悬停高亮（箱子记忆面板 + 实体容器绿色高亮）
local CM_last_highlight

local function CM_PushHighlightEvent(item_prefab)
    if ThePlayer and item_prefab then
        CM:ChangeHighlighting(true, item_prefab)
        CM_RefreshContainerHighlight(item_prefab)
        CM_last_highlight = item_prefab
    end
end

local function CM_PushUnhighlightEvent(item_prefab)
    if ThePlayer and item_prefab then
        CM:ChangeHighlighting(false, item_prefab)
        CM_ClearHighlights()
        CM_last_highlight = nil
    end
end

-- 中键收纳：鼠标中键点击物品 → 存入附近同类容器
local function CM_SetupMiddleClickStore()
    local function GetItemUnderMouse()
        local target = TheInput:GetHUDEntityUnderMouse()
        local widget = target and target.widget
        for _ = 1, 5 do
            if widget == nil then break end
            if widget.item ~= nil then
                return widget.item
            end
            if widget.tile ~= nil and widget.tile.item ~= nil then
                return widget.tile.item
            end
            widget = widget.parent
        end
    end

    local function FindRememberedContainer(item)
        if not ThePlayer then return nil end
        local px, _, pz = ThePlayer.Transform:GetWorldPosition()
        local entities = TheSim:FindEntities(px, 0, pz, 30, CM_MUST_HAVE_TAGS, CM_CANT_HAVE_TAGS)
        local best, best_rank, best_distance

        for _, inst in ipairs(entities) do
            local replica = InventoryUtil:GetContainerReplica(inst)
            if inst:IsValid()
                and replica ~= nil
                and not (inst.replica.inventoryitem and inst.replica.inventoryitem:IsGrandOwner(ThePlayer))
                and CM_CanPutIn(inst, item) then
                local rank
                if InventoryUtil:IsContainerOpenedBy(inst)
                    and InventoryUtil:HasContainerItem(inst, item.prefab) then
                    rank = 1
                elseif CM_ContainerHasItem(inst, item.prefab) then
                    rank = 2
                elseif CM_CheckShowmeAndInsight(inst, item.prefab) then
                    rank = 3
                end

                if rank ~= nil and CM_ContainerCanAccept(inst, item.prefab) then
                    local pos = inst:GetPosition()
                    local dx = px - pos.x
                    local dz = pz - pos.z
                    local distance = dx * dx + dz * dz
                    if best == nil or rank < best_rank
                        or (rank == best_rank and distance < best_distance) then
                        best = inst
                        best_rank = rank
                        best_distance = distance
                    end
                end
            end
        end
        return best
    end

    TheInput:AddMouseButtonHandler(function(button, down, x, y)
        if not down then return false end
        if button ~= MOUSEBUTTON_MIDDLE then return false end
        if TheInput:IsControlPressed(CONTROL_FORCE_INSPECT)
            or TheInput:IsControlPressed(CONTROL_FORCE_STACK)
            or TheInput:IsControlPressed(CONTROL_FORCE_TRADE) then
            return false
        end
        local item = GetItemUnderMouse()
        if not item or not item.prefab or not ThePlayer then return false end

        local aimbox = FindRememberedContainer(item)

        if aimbox then
            local controller = ThePlayer.components and ThePlayer.components.playercontroller
            if controller == nil then return false end
            local ba = BufferedAction(ThePlayer, aimbox, ACTIONS.STORE)
            controller:RemoteControllerUseItemOnSceneFromInvTile(ba, item)
            return true
        end
        return false
    end)
end

-- 制作菜单材料悬停高亮 + 右键取物 + 容器绿色高亮
local function CM_SetupIngredientHighlight()
    -- 材料图标：从 self.ing.texture 反推 prefab（Exp_Max 同款方案，IngredientUI 构造函数不传 recipe_type）
    AddClassPostConstruct("widgets/ingredientui", function(self, ...)
        local function getPrefab()
            local str = self.ing and self.ing.texture and self.ing.texture
            str = tostring(str)
            local b = str and str:match('[^/]+$')
            return b and b:gsub('%.tex$', '')
        end

        local _OnMouseButton = self.OnMouseButton
        function self:OnMouseButton(button, down, ...)
            if button == MOUSEBUTTON_RIGHT and down and GetTime() ~= self.lasttime then
                self.lasttime = GetTime()
                local prefab = getPrefab()
                local str = self.quant and self.quant.string
                local num = str and str:match("(%d+)$")
                if prefab then
                    CM_FindAndRetrieve(prefab, tonumber(num) or 1)
                end
            end
            return _OnMouseButton(self, button, down, ...)
        end

        local old_OnGainFocus = self.OnGainFocus
        function self:OnGainFocus(...)
            CM_PushHighlightEvent(getPrefab())
            old_OnGainFocus(self, ...)
        end

        local old_OnLoseFocus = self.OnLoseFocus
        function self:OnLoseFocus(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_OnLoseFocus(self, ...)
        end
    end)

    -- 切标签 / 滚动时清除高亮
    AddClassPostConstruct("widgets/tabgroup", function(self)
        local old_DeselectAll = self.DeselectAll
        function self:DeselectAll(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_DeselectAll(self, ...)
        end
    end)

    AddClassPostConstruct("widgets/crafting", function(self, owner, num_slots)
        local old_ScrollUp = self.ScrollUp
        local old_ScrollDown = self.ScrollDown
        function self:ScrollUp(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_ScrollUp(self, ...)
        end
        function self:ScrollDown(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_ScrollDown(self, ...)
        end
    end)

    -- 制作栏：右键取物 + 悬停高亮（纯焦点事件驱动，无 DoTaskInTime）
    AddClassPostConstruct("widgets/redux/craftingmenu_hud", function(self, ...)
        local function getFocusedPrefab(self)
            local menu = self.craftingmenu
            if not menu then return nil end
            local grid = menu.recipe_grid
            local skin = menu.details_root and menu.details_root.skins_spinner
            if grid and grid.focus and grid.shown then
                local idx = grid.focused_widget_index + grid.displayed_start_index
                local items = grid.items
                if idx and items and items[idx] and items[idx].recipe then
                    return items[idx].recipe.name
                end
            elseif skin and skin.focus and skin.enabled and skin.shown then
                return skin.recipe and skin.recipe.name
            end
            return nil
        end

        local _OnMouseButton = self.OnMouseButton
        function self:OnMouseButton(button, down, ...)
            if button == MOUSEBUTTON_RIGHT and down then
                if not (self.pinbar and self.pinbar.open_menu_button and self.pinbar.open_menu_button.focus) then
                    local prefab = getFocusedPrefab(self)
                    if prefab then
                        CM_FindAndRetrieve(prefab)
                    end
                end
            end
            return _OnMouseButton(self, button, down, ...)
        end

        local old_OnGainFocus = self.OnGainFocus
        function self:OnGainFocus(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            -- 焦点事件触发时 grid.focus 已设置，直接读取
            CM_PushHighlightEvent(getFocusedPrefab(self))
            old_OnGainFocus(self, ...)
        end

        local old_OnLoseFocus = self.OnLoseFocus
        function self:OnLoseFocus(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_OnLoseFocus(self, ...)
        end
    end)

    -- 固定配方：右键取物 + 悬停高亮（recipe_name 随时可用，无延迟）
    AddClassPostConstruct("widgets/redux/craftingmenu_pinslot", function(self, ...)
        local _OnMouseButton = self.OnMouseButton
        function self:OnMouseButton(button, down, ...)
            if button == MOUSEBUTTON_RIGHT and down
                and not (self.recipe_popup and self.recipe_popup.focus) then
                if self.recipe_name then
                    CM_FindAndRetrieve(self.recipe_name)
                end
            end
            return _OnMouseButton(self, button, down, ...)
        end

        local old_OnGainFocus = self.OnGainFocus
        function self:OnGainFocus(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            CM_PushHighlightEvent(self.recipe_name)
            old_OnGainFocus(self, ...)
        end

        local old_OnLoseFocus = self.OnLoseFocus
        function self:OnLoseFocus(...)
            CM_PushUnhighlightEvent(CM_last_highlight)
            old_OnLoseFocus(self, ...)
        end
    end)
end

CM_SetupIngredientHighlight()
CM_SetupMiddleClickStore()

-- 箱子记忆初始化
local function InitChestMemory()
    if not ThePlayer or not ThePlayer.HUD then return end

    local player = ThePlayer
    local seed = WorldUtil:GetWorldSeed()

    if seed ~= nil then
        EnsureChestMemoryWorldListeners()

        if seed ~= CM.seed then
            if CM.seed ~= nil then
                CM:SaveData()
                CM:RemoveAllWidgets()
            end
            CM.pending_save_seed = nil
            CM.seed = seed
            CM:ResetData()
            CM:LoadData()
        else
            for _, widget in pairs(CM.chestwidgets) do
                widget:LoadChestData()
            end
        end
    end

    if CM.player ~= player then
        if CM.container_event_player ~= nil and CM.container_event_player:IsValid() then
            CM.container_event_player:RemoveEventCallback("onopencontainer", CM.open_container_fn)
            CM.container_event_player:RemoveEventCallback("onclosecontainer_pre", CM.close_container_pre_fn)
            CM.container_event_player:RemoveEventCallback("onclosecontainer", CM.close_container_fn)
        end
        CM.player = player
        CM.container_event_player = player
        CM.open_container_fn = OnChestMemoryContainerOpened
        CM.close_container_pre_fn = OnChestMemoryContainerClosing
        CM.close_container_fn = OnChestMemoryContainerClosed
        player:ListenForEvent("onopencontainer", CM.open_container_fn)
        player:ListenForEvent("onclosecontainer_pre", CM.close_container_pre_fn)
        player:ListenForEvent("onclosecontainer", CM.close_container_fn)
    end

    if CM.activeitem_player ~= player then
        if CM.activeitem_player ~= nil and CM.activeitem_player:IsValid() and CM.activeitem_fn ~= nil then
            CM.activeitem_player:RemoveEventCallback("newactiveitem", CM.activeitem_fn)
        end
        CM.activeitem_player = player
        CM.activeitem_fn = OnChestMemoryActiveItem
        player:ListenForEvent("newactiveitem", CM.activeitem_fn)
    end

    CM.displaytype = CONFIG.CHEST_MEMORY_DISPLAY_TYPE or "all"

    if CONFIG.CHEST_MEMORY_ENABLED then
        -- 初次激活时只扫描一次；之后由实体生成和容器开合事件增量登记。
        AddChestDisplayToNearbyChests()
        EnsureChestMemoryCameraListener()
    else
        CM:RemoveAllWidgets()
    end

    -- 数据保存和卸载由稳定的世界事件回调统一处理，避免重复注册匿名函数。
end

-- 提供给 confighud 的切换函数
MOD_EQUIPMENT_CONTROL.CycleChestMemoryDisplay = CycleChestMemoryDisplay
MOD_EQUIPMENT_CONTROL.SetChestMemoryEnabled = SetChestMemoryEnabled
MOD_EQUIPMENT_CONTROL.InitChestMemory = InitChestMemory
MOD_EQUIPMENT_CONTROL.CM = CM
-- 供烹饪面板复用「按 prefab 从附近容器取物」；函数不使用 self，走点号调用
MOD_EQUIPMENT_CONTROL.CM.FindAndRetrieve = CM_FindAndRetrieve

--============================================================================
-- PART 3: 统一 Init
--============================================================================

local function Init()
    if not ThePlayer or not ThePlayer.player_classified then
        return
    end

    -- === 自动容器收集 ===
    local item = InventoryUtil:FindEquipped(function(it)
        return it and GetContainerConfig(it.prefab) ~= nil
    end)
    if item then
        local config = GetContainerConfig(item.prefab)
        if config then
            OnContainerEquip_AutoCollect(config)
        end
    end

    local InventoryEventService = require "util/inventoryeventservice"
    InventoryEventService:On(InventoryEventService.EVENT.EQUIPPED, function(data)
        local config = ValidateContainer(data)
        if config then
            OnContainerEquip_AutoCollect(config)
        else
            OnContainerUnequip_AutoCollect(ThePlayer, data)
        end
    end, ThePlayer)

    ThePlayer.player_classified:ListenForEvent("isghostmodedirty", function()
        RemoveEvents_AutoCollect()
    end)

    -- === 箱子记忆 ===
    InitChestMemory()
end

MOD_EQUIPMENT_CONTROL.AutoContainerInit = Init