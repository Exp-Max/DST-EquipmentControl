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

-- 数据层实现已收敛到 util/filesystem，widget 集合管理已收敛到 widgets/chestmemorydisplay。
-- 本文件只保留状态表 + 数据对接：业务条例（key / 配额 / 历史上限）在此注入，
-- 方法通过 __index 继承数据仓库，状态仍落在 CM 这张表上，外部访问方式不变。
local chest_memory_store = FileSystem:CreateShardedStore({
    get_seed = function() return WorldUtil:GetWorldSeed() end,
    shard_key = function(seed) return CM_DATA_PREFIX .. tostring(seed) end,
    index_key = MODNAME .. "_chest_memory_worlds",
    legacy_key = MODNAME .. "_chest_memory",
    max_worlds = CM_MAX_WORLDS,
    max_history = CM_MAX_HISTORY,
    on_loaded = function() ChestMemoryDisplay.OnDataLoaded() end,
    collect = function(_, widget) ChestMemoryDisplay.CollectSavedData(widget) end,
})
setmetatable(CM, { __index = chest_memory_store })
ChestMemoryDisplay.BindState(CM)

function CM:AddWidget(owner) ChestMemoryDisplay.AddWidget(owner, self) end
function CM:RemoveWidget(widget, chest_trigger) ChestMemoryDisplay.RemoveWidget(widget, chest_trigger) end
function CM:RemoveAllWidgets() ChestMemoryDisplay.RemoveAllWidgets() end
function CM:RefreshAllWidgets() ChestMemoryDisplay.RefreshAllWidgets() end
function CM:SetAndPushDisplayType(mode) ChestMemoryDisplay.SetAndPushDisplayType(mode) end
function CM:ChangeHighlighting(bool, item_prefab) ChestMemoryDisplay.ChangeHighlighting(bool, item_prefab) end
function CM:SetOpenedContainer(chest) ChestMemoryDisplay.SetOpenedContainer(chest) end

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
-- 快速移动 / 连续丢弃（原 scripts/Auto/quickmove.lua 已并入本文件）
--   Shift+双击左键 → 批量转移同 prefab
--   Shift+右键     → 快速丢弃（单击单件 / 双击连续，库存/容器）
--   Ctrl+双击装备槽 → 连续丢弃（装备槽，原 repeatdrop.lua 已并入本模块）
-- InventoryUtil / PlayerUtil / ItemUtil 复用本文件顶部已 require 的实例。
--============================================================================

local State = {
    enabled   = false,
    -- 功能开关（Init 填充）：快速移动 = 批量转移；快速丢弃 = Shift+双击物品栏/容器
    batch_enabled = false,
    drop_enabled  = false,
    -- 双击检测
    mv_time   = 0, mv_slot = nil, mv_item = nil,
    dr_time   = 0, dr_slot = nil, dr_item = nil,
    -- 追踪
    go_to     = nil,  -- go_to_container
    drop_th   = nil,
}

-- 双击窗口
local DOUBLE_CLICK_WINDOW = 0.4

local function IsDoubleClick(last_time, last_slot, last_item, slot)
    return GetTime() - last_time < DOUBLE_CLICK_WINDOW
       and last_slot == slot
       and last_item
end

local function StopDrop()
    if State.drop_th then
        State.drop_th:SetList(nil)
        State.drop_th = nil
    end
end

-- 注册到打断中心：玩家按攻击键/点击非 HUD 区域（移动指令）时停掉连续丢弃。
-- 注意：纯"走路移动"的打断改为在 StartQuickDrop 循环内用 PlayerUtil:IsMoving() 状态轮询
--       （见下方循环），以覆盖手柄/被推走等未走移动键的实际情况，比输入事件打断更稳。
PlayerUtil:AddInterruptFn(StopDrop)

-- =========================================================================
-- 目标容器追踪 — 顶层注册（统一规范）
-- AddClassPostConstruct 只包装类构造函数：放进 Init()（playeractivated）注册会漏掉
-- 此前已创建的实例，统一在 modimport 加载期注册，之后创建的所有实例都带上包装。
-- 已存在的实例由 Init 内显式调用 State.WrapReplica(inv / of) 补齐。
-- =========================================================================
function State.WrapReplica(replica)
    if not replica or replica._eq_qm then return end
    if type(replica.MoveItemFromAllOfSlot) ~= "function" then return end
    replica._eq_qm = true
    local old = replica.MoveItemFromAllOfSlot
    replica.MoveItemFromAllOfSlot = function(self, slot, container, ...)
        State.go_to = container
        return old(self, slot, container, ...)
    end
end

AddClassPostConstruct("components/inventory_replica", State.WrapReplica)
AddClassPostConstruct("components/container_replica", State.WrapReplica)

-- =========================================================================
-- invslot 包装 — modimport 时注册，比 HUD 创建早，覆盖所有 invslot
-- =========================================================================
AddClassPostConstruct("widgets/invslot", function(self)
    if self._eq_qm then return end
    self._eq_qm = true
    local orig = self.OnControl

    self.OnControl = function(self, control, down)
        if not State.enabled or not down then
            return orig(self, control, down)
        end
        if not TheInput:IsControlPressed(CONTROL_FORCE_TRADE) then
            return orig(self, control, down)
        end

        local item = self.tile and self.tile.item

        -- Shift+右键: 快速丢弃
        if control == CONTROL_SECONDARY then
            local prev = State.dr_item
            local is_double = IsDoubleClick(State.dr_time, State.dr_slot, prev, self)
            State.dr_time = GetTime(); State.dr_slot = self; State.dr_item = item

            if item then
                InventoryUtil:DropItemFromInvTile(item, false)
            end
            if is_double and prev then
                State.StartQuickDrop(prev, self.container or InventoryUtil:GetInventory())
            end
            return true
        end

        -- Shift+双击左键: 批量转移（仅快速移动开启时）
        if control == CONTROL_ACCEPT and State.batch_enabled then
            local prev = State.mv_item
            local is_double = IsDoubleClick(State.mv_time, State.mv_slot, prev, self)
            State.mv_time = GetTime(); State.mv_slot = self; State.mv_item = item

            -- 懒包装容器 replica（Init 前已存在的容器实体）
            if self.container and not self.container._eq_qm then
                State.WrapReplica(self.container)
            end

            local ret = orig(self, control, down)

            if is_double and prev then
                local src = self.container or InventoryUtil:GetInventory()
                local target = State.go_to
                if not (target and target:IsValid()) then
                    -- 回退：源是容器→目标玩家，源是玩家→第一个打开容器
                    local si = src and src.inst
                    target = (si and si ~= ThePlayer) and ThePlayer
                        or State.go_to
                        or State.FirstOpenContainer()
                end
                State.StartBatchMove(prev, src, target)
            end
            return ret
        end

        return orig(self, control, down)
    end
end)

-- =========================================================================
-- InitQuickMove() — 填充 State，设置 replica 包装（原 quickmove.lua 的 Init）
-- =========================================================================
local function InitQuickMove()
    local batchEnabled = GetModConfigData("QUICK_ACTION_BATCHMOVE", MOD_EQUIPMENT_CONTROL.MODNAME)
    local repeatEnabled = GetModConfigData("QUICK_ACTION_REPEATDROP", MOD_EQUIPMENT_CONTROL.MODNAME)
    if not (batchEnabled or repeatEnabled) then return end

    State.batch_enabled = batchEnabled
    State.drop_enabled  = batchEnabled or repeatEnabled

    -- 中断（连续丢弃：库存 / 容器共用一个 drop_th）
    ThePlayer:ListenForEvent("newactiveitem", StopDrop)

    local inv = InventoryUtil:GetInventory()

    -- ===== 容器列表构建（批量转移与快速丢弃共用） =====
    local function BuildContainers(src)
        local overflow = InventoryUtil:GetBackpack()
        local result = {}
        if src then table.insert(result, src) end
        if src == inv then
            if overflow then table.insert(result, overflow) end
        elseif src and src.inst and src.inst:HasTag("backpack") then
            table.insert(result, inv)
        end
        return result
    end

    -- ===== 快速丢弃（Shift+右键双击物品栏/容器，对应原 repeatdrop.lua 已并入本模块） =====
    function State.StartQuickDrop(src_item, src_container)
        StopDrop()
        local containers = BuildContainers(src_container)

        State.drop_th = ThePlayer:StartThread(function()
            while ThePlayer:IsValid() do
                -- 玩家自主移动 → 打断连续丢弃。用 PlayerUtil:IsMoving() 状态轮询
                -- （sg:HasStateTag("moving") ‖ wantstomoveforward），比纯输入事件打断更稳：
                -- 覆盖手柄/被推走等未走按键的实际情况。攻击/点非 HUD 的停止仍由 AddInterruptFn 负责。
                if PlayerUtil:IsMoving() then break end
                local found
                for _, c in ipairs(containers) do
                    if c and type(c.GetItems) == "function" then
                        for _, v in pairs(c:GetItems()) do
                            if v and ItemUtil:IsSameKind(v, src_item) then
                                inv:DropItemFromInvTile(v, false)
                                found = true; break
                            end
                        end
                    end
                    if found then break end
                end
                if not found then
                    local a = inv:GetActiveItem()
                    if a and ItemUtil:IsSameKind(a, src_item) then
                        inv:DropItemFromInvTile(a, false)
                        found = true
                    end
                end
                if not found then break end
                Sleep(2 * FRAMES)
            end
            State.drop_th = nil
        end)
    end

    -- 仅快速丢弃开启（快速移动关闭）时，快速丢弃已就绪，直接启用
    if not batchEnabled then
        State.enabled = true
        return
    end

    -- ===== 以下仅快速移动（批量转移）开启时需要 =====
    -- ===== 发送单个物品移动 RPC =====
    local function SendMoveRPC(slot, container, dst)
        if container == inv or container.inst == ThePlayer then
            SendRPCToServer(RPC.MoveInvItemFromAllOfSlot, slot, dst)
        elseif container.inst then
            SendRPCToServer(RPC.MoveItemFromAllOfSlot, slot, container.inst, dst)
        end
    end

    -- ===== 目标容器追踪：补齐已存在的实例（未来实例已在顶层注册）=====
    State.WrapReplica(inv)
    local of = InventoryUtil:GetBackpack()
    if of then State.WrapReplica(of) end

    -- ===== 第一个打开容器（回退目标） =====
    -- 保留本体 inventory_replica:GetOpenContainers() 的原始 {[entity]=true} 集合：
    -- 这里需要容器实体本身作为 RPC 目标；InventoryUtil:GetOpenContainers() 已过滤背包
    -- 且返回 container replica 数组，语义不同，不替换。
    function State.FirstOpenContainer()
        local open = inv:GetOpenContainers()
        if open then
            for k in pairs(open) do return k end
        end
        local bp = InventoryUtil:GetBackpack()
        return bp and bp.inst or ThePlayer
    end

    -- ===== 批量转移 =====
    function State.StartBatchMove(src_item, src_container, target)
        StopDrop()
        local dst = target
            or (src_container and src_container.inst ~= ThePlayer) and ThePlayer
            or State.go_to
            or State.FirstOpenContainer()
        if not dst then return end

        for _, c in ipairs(BuildContainers(src_container)) do
            if c and type(c.GetItems) == "function" then
                for slot, v in pairs(c:GetItems()) do
                    if v and ItemUtil:IsSameKind(v, src_item) then
                        SendMoveRPC(slot, c, dst)
                    end
                end
            end
        end
    end

    State.enabled = true
end

-- 原 quickmove.lua 末尾的 table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, Init) 已移除：
-- 初始化改由下方统一 Init 调用 InitQuickMove()。

--============================================================================
-- PART 3: 统一 Init
--============================================================================

local function Init()
    -- 快速移动 / 连续丢弃：原走 AutoInits 注册，现与容器初始化同入口。
    -- 放在 player_classified 守卫之前，保持与原先一致的前置条件。
    InitQuickMove()

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