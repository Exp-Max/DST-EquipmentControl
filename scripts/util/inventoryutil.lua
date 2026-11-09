-- 库存功能模块 - 提供玩家库存管理的工具函数
-- 封装了库存操作、装备管理、物品查询等常用功能
--
-- 文件结构（与官方 inventory_replica.lua 对齐）：
--   一、库存副本方法镜像：逐方法委托 ThePlayer.replica.inventory，按官方 inventory_replica.lua 行序排列；
--       单世界走组件、多世界内部经 classified 自发包 RPC（官方 ismastersim 分支，见各副本方法实现）。
--       官方 Take/Swap/Put/Add 等方法只接受 slot（无 container），跨容器请走"容器端点专用 RPC 变体"。
--   二、容器/槽位工具（基于副本方法的模组扩展，洞安全/兜底）
--   三、装备管理扩展（mod 特有）
--   四、物品查询/扩展（mod 特有）
--   五、容器 swap（跨容器瞬发换位，含 RPC 变体）

local InventoryUtil = {}  -- 库存功能表

-- 归一化容器对象：容器实体 → container replica（物品栏 replica / classified 原样返回）
-- 本体的槽位 API 分布在两种 replica 上：inventory replica（主物品栏）与 container replica（背包/各种容器）
local function NormalizeContainer(container)
    if container ~= nil and container.replica ~= nil and container.replica.container ~= nil then
        return container.replica.container
    end
    return container
end

-- 获取玩家库存对象
-- @return: 玩家库存的副本对象
function InventoryUtil:GetInventory()
    return ThePlayer
        and ThePlayer.replica
        and ThePlayer.replica.inventory  -- 返回玩家库存副本
end

-- =============================================================
-- 一、库存副本方法镜像（按官方 inventory_replica.lua 行序排列）
-- 与官方 scripts/components/inventory_replica.lua 的 53 个方法逐一同名对齐：
--   L1~L196 的生命周期/网络方法也一并镜像，仅供对齐，业务层不要主动调用；
--   L332 GetItems 有同名镜像，GetInventoryItems 是模组自实现（带 or {} 兜底）。
-- 官方行序参考（行号均对应 data/databundles/scripts.zip 内 scripts/components/inventory_replica.lua）：
--   197 GetNumSlots
--   205 CanTakeItemInSlot  232 AcceptsStacks  240 IgnoresCanGoInContainer
--   248 EquipHasTag       260 IsHeavyLifting 268 IsFloaterHeld
--   276 IsVisible         284 IsOpenedBy     292 IsHolding
--   300 FindItem(fn)
--   308 GetActiveItem     316 GetItemInSlot  324 GetEquippedItem
--   332 GetItems          340 GetEquips      349 GetOpenContainers
--   369 GetOverflowContainer 378 IsFull       386 Has
--   396 HasItemWithTag    410 ReturnActiveItem
--   418 PutOneOfActiveItemInSlot  426 PutAllOfActiveItemInSlot
--   434 TakeActiveItemFromHalfOfSlot  442 TakeActiveItemFromCountOfSlot
--   450 TakeActiveItemFromAllOfSlot   458 AddOneOfActiveItemToSlot
--   466 AddAllOfActiveItemToSlot      474 SwapActiveItemWithSlot
--   482 UseItemFromInvTile  492 ControllerUseItemOnItemFromInvTile
--   502 ControllerUseItemOnSelfFromInvTile  512 ControllerUseItemOnSceneFromInvTile
--   522 InspectItemFromInvTile  532 DropItemFromInvTile
--   542 CastSpellBookFromInv  552 EquipActiveItem  560 EquipActionItem
--   568 SwapEquipWithActiveItem  576 TakeActiveItemFromEquipSlot
--   584 MoveItemFromAllOfSlot  592 MoveItemFromHalfOfSlot  600 MoveItemFromCountOfSlot
-- =============================================================

-- 官方 L1~L196 生命周期/网络方法镜像（仅为与官方逐方法对齐，业务层不要主动调用）
function InventoryUtil:OnRemoveEntity()
    local inventory = self:GetInventory()
    return inventory
        and inventory:OnRemoveEntity()
end

function InventoryUtil:AttachClassified(classified)
    local inventory = self:GetInventory()
    return inventory
        and inventory:AttachClassified(classified)
end

function InventoryUtil:DetachClassified()
    local inventory = self:GetInventory()
    return inventory
        and inventory:DetachClassified()
end

function InventoryUtil:OnOpen()
    local inventory = self:GetInventory()
    return inventory
        and inventory:OnOpen()
end

function InventoryUtil:OnClose()
    local inventory = self:GetInventory()
    return inventory
        and inventory:OnClose()
end

function InventoryUtil:OnShow()
    local inventory = self:GetInventory()
    return inventory
        and inventory:OnShow()
end

function InventoryUtil:OnHide()
    local inventory = self:GetInventory()
    return inventory
        and inventory:OnHide()
end

function InventoryUtil:SetHeavyLifting(heavylifting)
    local inventory = self:GetInventory()
    return inventory
        and inventory:SetHeavyLifting(heavylifting)
end

function InventoryUtil:SetFloaterHeld(floaterheld)
    local inventory = self:GetInventory()
    return inventory
        and inventory:SetFloaterHeld(floaterheld)
end

-- 获取主物品栏槽位数（官方 L197）
function InventoryUtil:GetNumSlots()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetNumSlots()
end

-- 检查物品能否放入指定槽位（官方 L205）
function InventoryUtil:CanTakeItemInSlot(item, slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:CanTakeItemInSlot(item, slot)
end

-- 库存是否接受堆叠（官方 L232）
function InventoryUtil:AcceptsStacks()
    local inventory = self:GetInventory()
    return inventory
        and inventory:AcceptsStacks()
end

-- 物品是否忽略"能否进容器"限制（官方 L240）
function InventoryUtil:IgnoresCanGoInContainer()
    local inventory = self:GetInventory()
    return inventory
        and inventory:IgnoresCanGoInContainer()
end

-- 检查装备是否具有指定标签（官方 L248）
-- @param tag: 要检查的标签
-- @return: 布尔值，表示装备是否具有该标签
function InventoryUtil:EquipHasTag(tag)
    local inventory = self:GetInventory()
    return inventory
        and inventory:EquipHasTag(tag)
end

-- 检查玩家是否正在搬运重物（官方 L260）
-- @return: 布尔值，表示是否正在搬运重物
function InventoryUtil:IsHeavyLifting()
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsHeavyLifting()
end

-- 是否正举着漂浮物（官方 L268）
function InventoryUtil:IsFloaterHeld()
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsFloaterHeld()
end

-- 库存是否可见（官方 L276）
function InventoryUtil:IsVisible()
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsVisible()
end

-- 检查指定实体是否打开了玩家库存（官方 L284）
function InventoryUtil:IsOpenedBy(guy)
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsOpenedBy(guy)
end

-- 玩家是否持有某物（官方 L292，checkcontainer: 是否跨容器查）
function InventoryUtil:IsHolding(item, checkcontainer)
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsHolding(item, checkcontainer)
end

-- 按谓词查找物品（官方 L300）
function InventoryUtil:FindItem(fn)
    local inventory = self:GetInventory()
    return inventory
        and inventory:FindItem(fn)
end

-- 获取当前手持物品（官方 L308）
-- @return: 当前手持的物品
function InventoryUtil:GetActiveItem()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetActiveItem()
end

-- 读取指定槽位物品（官方 L316，仅主物品栏；容器请走 GetItemInSlotSafe）
function InventoryUtil:GetItemInSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetItemInSlot(slot)
end

-- 获取指定装备槽位的物品（官方 L324）
-- @param eslot: 装备槽位标识符
-- @return: 该槽位的装备物品
function InventoryUtil:GetEquippedItem(eslot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetEquippedItem(eslot)
end

-- 获取库存中的所有物品（官方 L332 同名镜像）
function InventoryUtil:GetItems()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetItems()
end

-- 模组自实现：GetItems 的空表兜底变体（官方无此方法名）
-- @return: 物品列表，如果库存不存在则返回空表
function InventoryUtil:GetInventoryItems()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetItems()
        or {}
end

-- 获取所有已装备的物品（官方 L340）
-- @return: 装备物品列表
function InventoryUtil:GetEquips()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetEquips()
        or {}
end

-- 获取所有已打开容器（replica 列表，不含背包——背包由 GetBackpack 单独处理）
-- 参考本体 inventory_replica:GetOpenContainers()：HUD 可见容器实体 + 背包实体（官方 L349）
function InventoryUtil:GetOpenContainers()
    local inventory = self:GetInventory()
    if inventory == nil or inventory.GetOpenContainers == nil then return {} end
    local entities = inventory:GetOpenContainers()
    if entities == nil then return {} end
    local overflow = self:GetBackpack()
    local result = {}
    for entity in pairs(entities) do
        if entity ~= nil and entity:IsValid() then
            local replica = entity.replica ~= nil and entity.replica.container or nil
            if replica ~= nil and replica ~= overflow then
                result[#result + 1] = replica
            end
        end
    end
    return result
end

-- 获取溢出容器（通常是背包，官方 L369）
-- @return: 溢出容器对象
function InventoryUtil:GetOverflowContainer()
    local inventory = self:GetInventory()
    return inventory
        and inventory:GetOverflowContainer()
end

-- 库存是否已满（官方 L378）
function InventoryUtil:IsFull()
    local inventory = self:GetInventory()
    return inventory
        and inventory:IsFull()
end

-- 检查库存中是否拥有指定物品（官方 L386，最新签名含 checkallcontainers：是否跨所有容器搜索）
-- @param prefab: 物品的prefab名称
-- @param amount: 所需数量（可选）
-- @param checkallcontainers: 是否跨所有容器统计（可选，对齐官方）
-- @return: 布尔值，表示是否拥有足够数量的物品
function InventoryUtil:Has(prefab, amount, checkallcontainers)
    local inventory = self:GetInventory()
    return inventory
        and inventory:Has(prefab, amount, checkallcontainers)
end

-- 检查是否拥有带指定标签的物品（官方 L396）
function InventoryUtil:HasItemWithTag(tag, amount)
    local inventory = self:GetInventory()
    return inventory
        and inventory:HasItemWithTag(tag, amount)
end

-- 返回当前手持物品到库存（官方 L410）
function InventoryUtil:ReturnActiveItem()
    local inventory = self:GetInventory()
    return inventory
        and inventory:ReturnActiveItem()
end

-- 将手持物的一份放入主物品栏槽位（官方 L418，单世界免 RPC）
function InventoryUtil:PutOneOfActiveItemInSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:PutOneOfActiveItemInSlot(slot)
end

-- 将手持物品直放主物品栏槽位（官方 L426，单世界免 RPC）
function InventoryUtil:PutAllOfActiveItemInSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:PutAllOfActiveItemInSlot(slot)
end

-- 从主物品栏槽位取一半到手持（官方 L434，单世界免 RPC）
function InventoryUtil:TakeActiveItemFromHalfOfSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:TakeActiveItemFromHalfOfSlot(slot)
end

-- 从主物品栏槽位取若干到手持（官方 L442，单世界免 RPC；官方仅接受 slot，count 由引擎内部决定）
function InventoryUtil:TakeActiveItemFromCountOfSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:TakeActiveItemFromCountOfSlot(slot)
end

-- 从所有指定槽位取出手持物品（官方 L450，单世界免 RPC）
-- @param slot: 槽位标识符
function InventoryUtil:TakeActiveItemFromAllOfSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:TakeActiveItemFromAllOfSlot(slot)
end

-- 将手持物的一份加入主物品栏槽位（官方 L458，单世界免 RPC）
function InventoryUtil:AddOneOfActiveItemToSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:AddOneOfActiveItemToSlot(slot)
end

-- 将手持物全部加入主物品栏槽位（官方 L466，单世界免 RPC）
function InventoryUtil:AddAllOfActiveItemToSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:AddAllOfActiveItemToSlot(slot)
end

-- 将手持物品与主物品栏槽位互换（官方 L474，单世界免 RPC）
function InventoryUtil:SwapActiveItemWithSlot(slot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:SwapActiveItemWithSlot(slot)
end

-- 从库存格子使用物品（官方 L482）
-- @param item: 要使用的物品
function InventoryUtil:UseItemFromInvTile(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:UseItemFromInvTile(item)
end

-- 对另一个物品使用手持物品（官方 L492，active_item 为手持物；多世界内部自理 RPC）
function InventoryUtil:ControllerUseItemOnItemFromInvTile(item, active_item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:ControllerUseItemOnItemFromInvTile(item, active_item)
end

-- 控制器模式下从库存格子对自己使用物品（官方 L502）
-- @param item: 要使用的物品
function InventoryUtil:ControllerUseItemOnSelfFromInvTile(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:ControllerUseItemOnSelfFromInvTile(item)
end

-- 按 actioncode + mod_name 解析动作对象（官方同款查表，不硬编码 code）
-- 官方两处同样实现：actions.lua:262（SetClientRequestedAction）、playercontroller.lua:5240
-- @param actioncode: 动作码；nil 表示调用方没带（如 Unequip 的无 code 调用）
-- @param mod_name: 模组名（模组动作必须带；基础动作传 nil）
-- @return Action|nil
function InventoryUtil:ResolveAction(actioncode, mod_name)
    if actioncode == nil then return nil end
    if mod_name ~= nil then
        local by_mod = MOD_ACTIONS_BY_ACTION_CODE[mod_name]
        return by_mod ~= nil and by_mod[actioncode] or nil
    end
    return ACTIONS_BY_ACTION_CODE[actioncode]
end

-- 覆盖 Inventory:ControllerUseItemOnSelfFromInvTile，让指定动作绕开官方链路直接执行
-- （仅单世界安装；客机没有 components.inventory，走 SendEquipAction 的 RPC 分支）
-- 为什么绕开，官方实现（inventory.lua:2337）两点不适用：
--   ① 有 busy 门——即时动作被丢会出现"摘了但没穿上"，应进动作队列延后执行；
--   ② 靠 GetItemSelfAction 收集动作——手持物品时收集结果里没有目标动作。
-- 其余动作码（含不带 code 的调用）原样交回官方链路。
-- @param inventory: inst.components.inventory
-- @param force_actions: 要直接执行的动作对象表，如 { ACTIONS.WEARMEDAL, ACTIONS.TAKEOFFMEDAL }
--   传动作对象而非 code：新增动作只改调用方，无需在此维护 code→action 映射
function InventoryUtil:InstallUseItemOnSelfHook(inventory, force_actions)
    if inventory == nil or force_actions == nil then return end
    local force = {}
    for _, a in ipairs(force_actions) do
        if a ~= nil then force[a] = true end
    end
    local _orig = inventory.ControllerUseItemOnSelfFromInvTile
    function inventory:ControllerUseItemOnSelfFromInvTile(item, actioncode, mod_name)
        local action = InventoryUtil:ResolveAction(actioncode, mod_name)
        if action ~= nil and force[action]
            and self:CanAccessItem(item)
            and self.inst.components.playercontroller ~= nil then
            InventoryUtil:SendEquipAction(action, item, mod_name)
            return
        end
        return _orig(self, item, actioncode, mod_name)
    end
end

-- 控制器模式下从库存格子对场景使用物品（官方 L512）
function InventoryUtil:ControllerUseItemOnSceneFromInvTile(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:ControllerUseItemOnSceneFromInvTile(item)
end

-- 从库存格子 inspect 物品（官方 L522）
function InventoryUtil:InspectItemFromInvTile(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:InspectItemFromInvTile(item)
end

-- 从库存格子丢弃物品（官方 L532）
-- @param item: 要丢弃的物品
-- @param single: true 只丢一个；nil/false 丢整堆（对齐官方 Inventory:DropItemFromInvTile(item, single)）
function InventoryUtil:DropItemFromInvTile(item, single)
    local inventory = self:GetInventory()
    return inventory
        and inventory:DropItemFromInvTile(item, single)
end

-- 从库存施放法术书（官方 L542）
function InventoryUtil:CastSpellBookFromInv(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:CastSpellBookFromInv(item)
end

-- 装备当前手持物品（官方 L552）
function InventoryUtil:EquipActiveItem()
    local inventory = self:GetInventory()
    return inventory
        and inventory:EquipActiveItem()
end

-- 将手持物品作为动作物品装备（官方 L560）
function InventoryUtil:EquipActionItem(item)
    local inventory = self:GetInventory()
    return inventory
        and inventory:EquipActionItem(item)
end

-- 将手持物与已装备物互换（官方 L568）
function InventoryUtil:SwapEquipWithActiveItem()
    local inventory = self:GetInventory()
    return inventory
        and inventory:SwapEquipWithActiveItem()
end

-- 从装备槽位取出手持物品（官方 L576）
-- @param eslot: 装备槽位
function InventoryUtil:TakeActiveItemFromEquipSlot(eslot)
    local inventory = self:GetInventory()
    return inventory
        and inventory:TakeActiveItemFromEquipSlot(eslot)
end

-- 从所有指定槽位移动物品到容器（官方 L584，副本方法本身接受 container）
-- @param slot: 槽位标识符
-- @param container: 目标容器
function InventoryUtil:MoveItemFromAllOfSlot(slot, container)
    local inventory = self:GetInventory()
    return inventory
        and inventory:MoveItemFromAllOfSlot(slot, container)
end

-- 从所有指定槽位移一半物品到容器（官方 L592，副本方法本身接受 container）
function InventoryUtil:MoveItemFromHalfOfSlot(slot, container)
    local inventory = self:GetInventory()
    return inventory
        and inventory:MoveItemFromHalfOfSlot(slot, container)
end

-- 从所有指定槽位移指定数量物品到容器（官方 L600，副本方法本身接受 container）
function InventoryUtil:MoveItemFromCountOfSlot(slot, container, count)
    local inventory = self:GetInventory()
    return inventory
        and inventory:MoveItemFromCountOfSlot(slot, container, count)
end

-- -------------------------------------------------------------
-- 库存分类信息（replica.classified 属性，官方 replica 内部字段）
-- -------------------------------------------------------------

-- 获取库存的分类信息对象
-- @return: 库存分类信息对象
function InventoryUtil:GetClassified()
    local inventory = self:GetInventory()
    return inventory
        and inventory.classified
end

-- 检查库存是否繁忙
-- @return: 布尔值，表示库存是否正在处理操作
function InventoryUtil:IsBusyClassified()
    local classified = self:GetClassified()
    return classified
        and classified.IsBusy
        and classified:IsBusy()
end

-- 玩家当前是否空闲、可以安全发起自动操作（自动维护/自动卸下等的前置门槛）
-- 判定链与官方一致：库存未繁忙 + 玩家无 busy 标签 + 状态图不处于 busy 状态
-- + actionpicker/playercontroller 两个组件已就绪（缺任一则动作无法组装）
-- @return: 布尔值
function InventoryUtil:IsPlayerFree()
    return not self:IsBusyClassified()
        and ThePlayer
        and not ThePlayer:HasTag("busy")
        and not (ThePlayer.sg ~= nil and ThePlayer.sg:HasStateTag("busy"))
        and ThePlayer.components.playeractionpicker ~= nil
        and ThePlayer.components.playercontroller ~= nil
end

-- =============================================================
-- 二、容器/槽位工具（基于上方副本方法的模组扩展，洞安全/兜底）
-- 本体事实（components/inventory*.lua、container*.lua、prefabs/*_classified.lua）：
--   1) GetItems() 按槽位索引保留空洞（空槽值为 nil）；# 对稀疏表不可靠，
--      槽位范围必须以 GetNumSlots() 为准，读取已有物品可用 pairs
--   2) 客户端 ContainerReplica:GetNumSlots() 读取 _numslots，不随网络同步；未注册且未打开时
--      可能为 0。主机端组件可直接读取真实槽位数。0 表示范围未知，不用稀疏 GetItems() 猜测
--   3) 客户端 ContainerReplica:GetItems()/IsFull() 以 opener 为门槛；未打开返回空表，
--      这不代表容器为空。主机端组件直接读取 slots；背包是否可用仍须检查 IsOpenedBy
--   4) inventory replica 无 opener 门槛（主物品栏 classified 始终同步），其 GetNumSlots 为
--      游戏模式常量 GetMaxItemSlots，GetItems 不含手持物品
--   5) 装备槽与主槽分开：服务端 equipslots 按槽位名索引，classified 只同步标准槽位；
--      自定义槽位（如 EQUIPSLOTS.MEDAL）客户端只能遍历 GetEquips + EquipSlot() 定位
-- =============================================================

-- 获取容器槽位数量（物品栏/背包/各种容器通用，实体或 replica 均可）
-- 0 表示本体尚未提供槽位数；不能通过稀疏 GetItems() 可靠推断空槽边界
-- @return: 槽位数；完全不可知返回 0
function InventoryUtil:GetSlotCount(container)
    local replica = NormalizeContainer(container)
    if replica == nil then return 0 end
    local num = replica.GetNumSlots ~= nil and replica:GetNumSlots() or 0
    return type(num) == "number" and num > 0 and num or 0
end

-- 读取物品当前堆叠数量（非堆叠物品返回 1；实体或 replica 均可）
function InventoryUtil:GetStackSize(ent)
    if ent == nil then return 1 end
    local stackable = (ent.replica ~= nil and ent.replica.stackable)
        or (ent.components ~= nil and ent.components.stackable)
    return stackable ~= nil and stackable:StackSize() or 1
end

-- 读取物品真实最大堆叠数量（无限堆叠返回实际配额而非 math.huge，可直接用于“是否已满”比较）
function InventoryUtil:GetMaxSize(ent)
    if ent == nil then return 1 end
    local stackable = (ent.replica ~= nil and ent.replica.stackable)
        or (ent.components ~= nil and ent.components.stackable)
    if stackable == nil then return 1 end
    local old_huge = math.huge
    math.huge = false
    local maxsize = stackable:MaxSize()
    math.huge = old_huge
    return maxsize
end

-- 读取物品展示用 atlas / image（实体或 replica 均可；无 inventoryitem 返回 nil）
function InventoryUtil:GetAtlas(item)
    local invitem = (item.replica ~= nil and item.replica.inventoryitem)
        or (item.components ~= nil and item.components.inventoryitem)
    return invitem ~= nil and invitem:GetAtlas() or nil
end

function InventoryUtil:GetImage(item)
    local invitem = (item.replica ~= nil and item.replica.inventoryitem)
        or (item.components ~= nil and item.components.inventoryitem)
    return invitem ~= nil and invitem:GetImage() or nil
end

-- 获取实体或 replica 对应的有效容器 replica；不会把玩家 inventory replica 当作容器。
function InventoryUtil:GetContainerReplica(container)
    if container == nil then return nil end
    if container.IsValid ~= nil and not container:IsValid() then return nil end

    local replica = NormalizeContainer(container)
    local inst = replica ~= nil and replica.inst or nil
    return inst ~= nil and inst.replica ~= nil and inst.replica.container == replica
        and replica or nil
end

-- 检查实体是否为有效容器实体（以本体 _container 标签为准）。
function InventoryUtil:IsContainer(inst)
    return inst ~= nil and inst:IsValid() and inst:HasTag("_container")
end

-- 容器数据当前是否可用（已打开）
-- 仅 container replica 有 opener 门槛；主物品栏 replica 始终同步，视为可用
function InventoryUtil:IsContainerOpened(container)
    local replica = NormalizeContainer(container)
    if replica == nil then return false end
    local is_container = replica.inst ~= nil and replica.inst.replica ~= nil
        and replica.inst.replica.container == replica
    if is_container and replica.IsOpenedBy ~= nil and ThePlayer ~= nil then
        return replica:IsOpenedBy(ThePlayer) and true or false
    end
    return true
end

-- 检查指定实体/replica 的容器是否由指定玩家（默认本地玩家）打开。
function InventoryUtil:IsContainerOpenedBy(container, doer)
    local replica = self:GetContainerReplica(container)
    if replica == nil or replica.IsOpenedBy == nil then return false end
    return replica:IsOpenedBy(doer or ThePlayer) and true or false
end

-- 检查指定容器 replica 当前是否包含 prefab；关闭容器的客户端数据可能不可用。
function InventoryUtil:HasContainerItem(container, prefab, amount)
    local replica = self:GetContainerReplica(container)
    if replica == nil or replica.Has == nil or prefab == nil then return false end
    return replica:Has(prefab, amount or 1) and true or false
end

-- 获取容器空槽数量（洞安全逐槽统计）
-- 未打开的容器数据不可用（GetItems 返回 {}），返回 nil 表示未知而非误报全空
-- @return: 空槽数；数据不可用返回 nil
function InventoryUtil:GetFreeSlotCount(container)
    local replica = NormalizeContainer(container)
    if replica == nil then return nil end
    if not self:IsContainerOpened(replica) then return nil end
    local num = self:GetSlotCount(replica)
    if num <= 0 then return nil end
    local items = replica:GetItems()
    if items == nil then return nil end
    local occupied = 0
    for slot = 1, num do
        if items[slot] ~= nil then occupied = occupied + 1 end
    end
    return num - occupied
end

-- 查找容器第一个空槽（洞安全逐槽遍历）
-- @return: 槽位号；容器已满或数据不可用返回 nil
function InventoryUtil:FindEmptySlot(container)
    local replica = NormalizeContainer(container)
    if replica == nil then return nil end
    if not self:IsContainerOpened(replica) then return nil end
    local num = self:GetSlotCount(replica)
    if num <= 0 then return nil end
    local items = replica:GetItems()
    if items == nil then return nil end
    for slot = 1, num do
        if items[slot] == nil then return slot end
    end
    return nil
end

-- 在容器中查找物品所在槽位（GUID 优先，引用兜底——装备/换箱会重建 replica 引用）
-- @return: 槽位号；不在该容器返回 nil
function InventoryUtil:FindItemSlot(container, item)
    local replica = NormalizeContainer(container)
    if replica == nil or item == nil then return nil end
    local guid = item.GUID
    local items = replica.GetItems ~= nil and replica:GetItems() or nil
    if items == nil then return nil end
    for slot, slot_item in pairs(items) do
        if type(slot) == "number" and slot_item ~= nil
            and ((guid ~= nil and slot_item.GUID == guid) or slot_item == item) then
            return slot
        end
    end
    return nil
end

-- 读取容器指定槽位物品（nil 安全；容器不可用/槽位越界返回 nil）
function InventoryUtil:GetItemInSlotSafe(container, slot)
    local replica = NormalizeContainer(container)
    if replica == nil or slot == nil then return nil end
    local items = replica.GetItems ~= nil and replica:GetItems() or nil
    if items == nil then return nil end
    return items[slot]
end

-- 背包容器（GetOverflowContainer 的别名）
-- @return: 背包容器对象
function InventoryUtil:GetBackpack()
    return self:GetOverflowContainer()
end

-- 获取背包中的所有物品
-- @return: 背包物品列表
function InventoryUtil:GetBackpackItems()
    local backpack = self:GetBackpack()
    return backpack
        and backpack:GetItems()
        or {}
end

-- 获取所有已打开容器中的物品（箱子、切斯特、冰箱等；不含背包）
-- 复用本体 inventory_replica:GetOpenContainers() 定位已打开容器，洞安全逐槽读取
-- @return: 物品列表
function InventoryUtil:GetOpenContainerItems()
    local items = {}
    for _, container in ipairs(self:GetOpenContainers()) do
        local containerItems = container:GetItems()
        if containerItems ~= nil then
            local slot_count = self:GetSlotCount(container)
            if slot_count > 0 then
                for slot = 1, slot_count do
                    local item = containerItems[slot]
                    if item ~= nil then
                        items[#items + 1] = item
                    end
                end
            else
                for _, item in pairs(containerItems) do
                    if item ~= nil then
                        items[#items + 1] = item
                    end
                end
            end
        end
    end
    return items
end

-- 检查是否有空闲槽位
-- 主物品栏精确统计；背包未打开时数据不可用（GetItems 返回 {}），按乐观处理——
-- 服务端放入物品时自动回落到背包，空位由服务端裁决，乐观处理与旧行为一致
-- @return: 布尔值，表示库存或背包是否有空闲槽位
function InventoryUtil:HasFreeSlot()
    local inventory = self:GetInventory()
    local free = inventory ~= nil and self:GetFreeSlotCount(inventory) or nil
    if free == nil then
        -- 主物品栏数据不可用（极罕见）：按有空间处理，避免误判丢弃
        return true
    elseif free > 0 then
        return true
    end
    local backpack = self:GetBackpack()
    if backpack == nil then return false end
    local backpackFree = self:GetFreeSlotCount(backpack)
    return backpackFree == nil or backpackFree > 0
end

-- 在整个可访问范围（主物品栏 → 背包 → 已打开容器）中定位物品所在容器与槽位
-- @return: replica, slot, kind（"inventory"=主物品栏 / "container"=容器）；未找到返回 nil
function InventoryUtil:FindItemContainer(item)
    if item == nil or item.GUID == nil then return nil end
    local inventory = self:GetInventory()
    if inventory ~= nil then
        local slot = self:FindItemSlot(inventory, item)
        if slot ~= nil then return inventory, slot, "inventory" end
    end
    local backpack = self:GetBackpack()
    local slot = self:FindItemSlot(backpack, item)
    if slot ~= nil then return backpack, slot, "container" end
    for _, container in ipairs(self:GetOpenContainers()) do
        slot = self:FindItemSlot(container, item)
        if slot ~= nil then return container, slot, "container" end
    end
    return nil
end

-- 自动消耗前置：判断物品能否"原地"被自动模块消耗（**不再把物品取到手持**）
-- 官方所有"从格子使用物品"的服务端入口都先过 Inventory:CanAccessItem（inventory.lua:2259），
-- 它接受 owner==玩家、或 owner 是容器且正被该玩家打开 —— 也就是说容器/背包里的物品
-- 根本不需要先取到手持就能使用（右键吃冰箱里的食物正是这条路径）。
-- 反过来，UseItemFromInvTile 的语义会被"手上是否有东西"反转（GetActiveItem()~=nil 时退化成
-- "用手持物对该物品使用"），一旦把消耗品取到手上，服务端动作收集就变成自使用、
-- 结果是静默丢弃 + 物品永久卡在鼠标上。故此处只做可达性判定，取物一律取消。
-- @return: true=库存可见，且物品位于主栏、装备、手持、已打开背包或配置允许的容器
function InventoryUtil:CanUseInPlace(item)
    if item == nil then return false end
    local inv = self:GetInventory()
    if inv == nil or not self:IsVisible() then return false end
    if self:IsEquipped(item) then return true end
    local replica = self:FindItemContainer(item)
    if replica == nil then
        -- FindItemContainer 不查手持：物品正拿在手里同样可对自己/目标使用
        return self:GetActiveItem() == item
    end
    if replica == inv then return true end
    local bp = self:GetBackpack()
    if replica == bp then return self:IsContainerOpened(replica) end
    -- 位于其它已打开容器：受"从打开容器取用"配置控制
    if not MOD_EQUIPMENT_CONTROL.AUTO_FROM_OPEN_CONTAINERS then return false end
    -- 服务端 CanAccessItem 要求容器正被该玩家打开（容器可能刚被关掉）
    return self:IsContainerOpened(replica)
end

-- 原地对自己使用物品（吃/喝之类 INVENTORY 动作），不取到手持
-- 走 ControllerUseItemOnSelfFromInvTile：它的动作收集（GetItemSelfAction → GetInventoryActions）
-- 完全不看手持，语义稳定；单世界走组件、客机由 classified 自行收集动作并发出带正确
-- actioncode 的 RPC，不会出现"客户端与服务端首选动作不一致被丢弃"。
-- @param item: 要使用的物品（可在主物品栏/背包/已打开容器/手上）
-- @param action: 期望动作（如 ACTIONS.EAT）；不传则只要求存在自我动作
-- @return: true=已发起
function InventoryUtil:UseItemOnSelf(item, action)
    if item == nil then return false end
    local inventory = self:GetInventory()
    if inventory == nil or inventory.ControllerUseItemOnSelfFromInvTile == nil then
        return false
    end
    local pc = ThePlayer ~= nil and ThePlayer.components ~= nil
        and ThePlayer.components.playercontroller or nil
    if pc ~= nil and pc.GetItemSelfAction ~= nil then
        local act = pc:GetItemSelfAction(item)
        if act ~= nil then
            -- 期望动作与首选动作不一致则不发起：单世界 actioncode 为 nil 时官方会直接执行首选动作
            if action ~= nil and act.action ~= action then return false end
            inventory:ControllerUseItemOnSelfFromInvTile(item)
            return true
        end
    end
    -- 本地收集不到动作（客户端 replica 尚未就绪等）→ 回退直发 RPC 由服务端裁决。
    -- 由于不再预先取物，即使服务端同样判定失败也零副作用（物品留在容器里，不会占用鼠标）。
    if action == nil then return false end
    SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, action.code, item, action.mod_name)
    return true
end

-- =============================================================
-- 三、装备管理扩展（mod 特有）
-- =============================================================

-- 装备物品
-- @param item: 要装备的物品
-- @param avoidDuplicate: true 时若已有同 prefab 装备则跳过
function InventoryUtil:Equip(item, avoidDuplicate)
    if not item then
        return false
    end
    if avoidDuplicate and self:IsEquipped(item.prefab) then
        return false
    end

    return self:SendEquipAction(ACTIONS.EQUIP, item)
end

-- 检查物品是否已装备
-- @param item: 要检查的物品（可以是物品实例或prefab字符串）
-- @return: 布尔值，表示物品是否已装备
function InventoryUtil:IsEquipped(item)
    if not item then
        return false
    end

    -- 根据item类型选择不同的比较方式
    if type(item) == "string" then
        -- 如果是字符串，比较prefab名称
        for _, equippedItem in pairs(self:GetEquips()) do
            if equippedItem.prefab == item then
                return true
            end
        end
    else
        -- 如果是物品实例，直接比较对象
        for _, equippedItem in pairs(self:GetEquips()) do
            if equippedItem == item then
                return true
            end
        end
    end

    return false
end

-- 遍历所有装备获取指定槽位的物品（客户端安全，支持自定义槽位）
-- GetEquippedItem 对自定义槽位（如 EQUIPSLOTS.MEDAL）返回 nil，
-- 因为 classified netvar 只同步标准槽位。遍历 EquipSlot() 是客户端获取自定义槽位物品的唯一可靠路径。
-- @param eslot: 装备槽位标识符
-- @return: 该槽位的装备物品
function InventoryUtil:GetEquippedItemBySlot(eslot)
    for _, item in pairs(self:GetEquips()) do
        if item.replica and item.replica.equippable
            and item.replica.equippable:EquipSlot() == eslot then
            return item
        end
    end
    return nil
end

-- 返回所有匹配 pred 的已装备物品的槽位集合（键为槽标识符，值 true；去重）。
-- 用于"更高优先级物品实际占据的槽"判定，使让位逻辑槽位感知、适配多格装备栏。
-- 仅基于"已实际装备"的物品，不做任何默认槽假设；未装备时不预判，避免误伤自定义槽物品。
-- @param pred: function(item) -> boolean
-- @return: { [slot] = true, ... }
function InventoryUtil:GetEquippedSlotsOf(pred)
    local slots = {}
    for _, item in pairs(self:GetEquips()) do
        if pred(item) and item.replica and item.replica.equippable then
            slots[item.replica.equippable:EquipSlot()] = true
        end
    end
    return slots
end

-- 获取玩家完整的库存（包括背包和装备）
-- @param equips: 是否包含装备物品
-- @param noActiveItem: 是否排除当前手持物品
-- @param includeContainers: 是否包含打开的容器中的物品
-- @return: 完整的物品列表
function InventoryUtil:GetPlayerInventory(equips, noActiveItem, includeContainers)
    local playerInventory = {}

    -- 添加主库存物品
    for _, item in pairs(self:GetInventoryItems()) do
        playerInventory[#playerInventory + 1] = item
    end

    -- 添加背包物品
    for _, item in pairs(self:GetBackpackItems()) do
        playerInventory[#playerInventory + 1] = item
    end

    -- 添加打开的容器中的物品
    if includeContainers then
        for _, item in pairs(self:GetOpenContainerItems()) do
            playerInventory[#playerInventory + 1] = item
        end
    end

    -- 添加装备物品（如果启用）
    if equips then
        for _, item in pairs(self:GetEquips()) do
            playerInventory[#playerInventory + 1] = item
        end

        -- 添加当前手持物品（如果不排除）
        if not noActiveItem then
            local activeItem = self:GetActiveItem()
            if activeItem then
                playerInventory[#playerInventory + 1] = activeItem
            end
        end
    end

    return playerInventory
end

-- 卸下装备（复用统一动作发送器，单世界入动作队列，客机由服务端裁决）
function InventoryUtil:Unequip(item)
    return self:SendEquipAction(ACTIONS.UNEQUIP, item)
end

-- 统一装备动作发送（单世界 PushAction / 客机 SendRPCToServer 双路径）
-- 单世界（客户端=服务端，有 locomotor 组件）：直接 PushAction 执行
-- 客机（纯客户端，无 components）：发 RPC.ControllerUseItemOnSelfFromInvTile 由服务端裁决
-- @param action: ACTIONS.EQUIP / WEARMEDAL / UNEQUIP / TAKEOFFMEDAL
-- @param item: 目标物品（须有效；官方 replica 入口同样校验 item:IsValid()，inventory_replica.lua:503）
-- @param mod_name: 可选，模组动作的 workshop id；缺省取 action.mod_name
--   （AddAction 时写入，modutil.lua:455）——调用方漏传也不会把模组动作发成服务端解析不了的 RPC
-- @return boolean 是否已发起
function InventoryUtil:SendEquipAction(action, item, mod_name)
    if action == nil or item == nil or not item:IsValid() then return false end
    mod_name = mod_name or action.mod_name
    if ThePlayer ~= nil and ThePlayer.components ~= nil and ThePlayer.components.locomotor ~= nil then
        -- 模组动作必须设 CLIENT_REQUESTED_ACTION（actions.lua:262，内部按
        -- MOD_ACTIONS_BY_ACTION_CODE[mod_name][code] 解析）：官方
        -- Inventory:ControllerUseItemOnSelfFromInvTile 也是这么包着的（inventory.lua:2343/2349）。
        -- 基础动作不发（它不靠标志解析，且不必扰动其它调用点的上下文）。
        if mod_name ~= nil then SetClientRequestedAction(action.code, mod_name) end
        -- target=nil、invobject=item：与官方动作收集的构造一致
        -- （playeractionpicker.lua:254 GetInventoryActions → SortActionList(actions, nil, useitem)）
        ThePlayer.components.locomotor:PushAction(
            BufferedAction(ThePlayer, nil, action, item), true)
        if mod_name ~= nil then ClearClientRequestedAction() end
    elseif mod_name ~= nil then
        SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, action.code, item, mod_name)
    else
        SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, action.code, item)
    end
    return true
end

-- 装备上下文：保存/恢复指定槽位装备，供自动切换装备场景复用
-- 用 GUID 而非对象引用，避免物品 replica 在装备/卸下时重建导致引用失效
local equip_contexts = {}

function InventoryUtil:SaveEquipContext(slot)
    local currentItem = self:GetEquippedItem(slot)
    if currentItem then
        equip_contexts[slot] = currentItem.GUID
    end
end

-- 在玩家所有可访问容器中按 GUID 查找物品
-- 搜索范围：主栏 + 背包容器 + 所有已打开容器（箱子、切斯特、冰箱等）
-- @param guid: 物品的 GUID
-- @return: 找到的物品 replica，未找到返回 nil
function InventoryUtil:FindItemByGUID(guid)
    for _, item in ipairs(self:GetPlayerInventory(nil, nil, true)) do
        if item.GUID == guid then
            return item
        end
    end
    return nil
end

function InventoryUtil:RestoreEquipContext(slot)
    local guid = equip_contexts[slot]
    equip_contexts[slot] = nil

    if not guid or not ThePlayer then
        return false
    end

    local savedItem = self:FindItemByGUID(guid)
    if not savedItem then
        return false
    end

    self:Equip(savedItem, true)
    return true
end

function InventoryUtil:ClearEquipContext(slot)
    equip_contexts[slot] = nil
end

function InventoryUtil:HasEquipContext(slot)
    return equip_contexts[slot] ~= nil
end

-- 在所有已装备物品中查找第一个匹配的（不依赖槽位名，兼容多格模组）
function InventoryUtil:FindEquipped(predicate)
    for _, item in pairs(self:GetEquips()) do
        if predicate(item) then return item end
    end
    return nil
end

-- 判断是否有某类物品已装备（不依赖槽位名）
function InventoryUtil:HasEquipped(predicate)
    return self:FindEquipped(predicate) ~= nil
end

-- 探测某类物品所属的装备槽位：找任一匹配库存物品 → 读它的 equipslot → 缓存
-- 用于替代 "这个类别一定在 EQUIPSLOTS.BODY" 的硬编码假设
local _slot_cache = {}
function InventoryUtil:DetectEquipSlot(predicate)
    local key = tostring(predicate)
    if _slot_cache[key] then return _slot_cache[key] end
    -- 已装备中找
    for _, item in pairs(self:GetEquips()) do
        if predicate(item) and item.replica and item.replica.equippable then
            _slot_cache[key] = item.replica.equippable:EquipSlot()
            return _slot_cache[key]
        end
    end
    -- 库存中找
    for _, item in pairs(self:GetInventoryItems()) do
        if predicate(item) and item.replica and item.replica.equippable then
            _slot_cache[key] = item.replica.equippable:EquipSlot()
            return _slot_cache[key]
        elseif predicate(item) and item.components and item.components.equippable then
            _slot_cache[key] = item.components.equippable.equipslot
            return _slot_cache[key]
        end
    end
    return nil
end

-- =============================================================
-- 四、物品查询/扩展（mod 特有）
-- =============================================================

-- 对另一个物品使用物品（fuel/repair/sew），原地发起，不取到手持
-- 官方 ControllerUseItemOnItemFromInvTile 的 active_item 参数并不要求真的拿在手上：
-- 动作收集走 GetItemUseAction → GetUseItemActions（不校验持有，只排除 STORE/COMBINESTACK/ATTACK
-- 等少数动作），执行阶段 Fueled:TakeFuelItem 也只是 item:Remove()，容器里的物品同样有效。
-- 这里不再裸发 RPC，而是先本地取首选动作校验、再走副本方法：
--   单世界 → 组件版（actioncode=nil，官方执行首选动作，故必须先校验）
--   客机   → classified 版（自带 busy 检查，并发出带正确 actioncode 的 RPC）
-- @param target: 目标物品（如需要补燃料/修复的装备）
-- @param fuel: 消耗品（可在主物品栏/背包/已打开容器/手上）
-- @param action: 期望动作（如 ACTIONS.ADDFUEL）；不传则不校验
-- @return: true=已发起
function InventoryUtil:UseItemOnItem(target, fuel, action)
    if target == nil or fuel == nil then return false end
    if not self:CanUseInPlace(target) or not self:CanUseInPlace(fuel) then
        return false
    end
    local inventory = self:GetInventory()
    if inventory == nil or inventory.ControllerUseItemOnItemFromInvTile == nil then
        return false
    end
    local pc = ThePlayer ~= nil and ThePlayer.components ~= nil
        and ThePlayer.components.playercontroller or nil
    if pc ~= nil and pc.GetItemUseAction ~= nil then
        local act = pc:GetItemUseAction(fuel, target)
        if act ~= nil then
            if action ~= nil and act.action ~= action then return false end
            inventory:ControllerUseItemOnItemFromInvTile(target, fuel)
            return true
        end
    end
    -- 本地收集不到动作（客户端 replica 尚未就绪等）→ 回退直发 RPC 由服务端裁决。
    -- 不再预先取物，因此即使服务端判定失败也零副作用（燃料留在容器里，不会占用鼠标）。
    if action == nil then return false end
    SendRPCToServer(RPC.ControllerUseItemOnItemFromInvTile, action.code, target, fuel, action.mod_name)
    return true
end

-- 在全量库存中查找物品：传字符串按 prefab 精确匹配，传函数按谓词匹配（首命中即返回）
function InventoryUtil:FindItemAnywhere(matcher)
    local is_fn = type(matcher) == "function"
    for _, item in ipairs(self:GetPlayerInventory(true, false, true)) do
        if is_fn then
            if matcher(item) then
                return item
            end
        elseif item.prefab == matcher then
            return item
        end
    end
    return nil
end

-- 检查主库存中是否包含指定物品引用
function InventoryUtil:ContainsItem(item)
    for _, invItem in pairs(self:GetInventoryItems()) do
        if invItem == item then
            return true
        end
    end
    return false
end

-- 判断库存中是否有某类装备兜底（护甲/衣物回退）
-- 按类别名（"ARMORHAT"/"ARMORBODY"）→ 多格兼容；或传入 EQUIPSLOTS.HEAD/BODY 兼容旧调用
function InventoryUtil:HasArmorFallback(slot_or_category)
    local check_fn
    if type(slot_or_category) == "string" then
        -- 按类别名（"ARMORHAT"/"ARMORBODY"）→ 多格兼容
        local category = Categories[slot_or_category]
        if category == nil then return false end
        check_fn = category.fn
    elseif slot_or_category == EQUIPSLOTS.HEAD then
        check_fn = Categories.ARMORHAT.fn
    elseif slot_or_category == EQUIPSLOTS.BODY then
        check_fn = Categories.ARMORBODY.fn
    else
        return false
    end
    for _, item in pairs(self:GetInventoryItems()) do
        if check_fn(item) then
            return true
        end
    end
    return false
end

-- =============================================================
-- 五、容器 swap（跨容器瞬发换位）
-- 端点分派原则（来自官方副本方法的 ismastersim 分支）：
--   某端点为 nil（主物品栏）→ 副本本地方法（单世界免显式 RPC、多世界内部自发包 RPC）；
--   某端点为容器实体        → 直发 RPC 变体（官方 Take/Swap/Put 副本/组件方法不含 container 参数，引擎限制）。
-- =============================================================

-- 容器端点专用：直发 RPC 的三段基础函数（便于单独调用/节流），均走 SendRPCToServer：
-- 注：官方 inventory 副本/组件的 Take/Swap/Put 均只接受 slot、不含 container 参数（仅 Move 接受 container）；
-- 跨容器取/放/互换须直接发 RPC（同 sortutil.lua 的写法）。container 传 nil 表示主物品栏。
--   TakeSlotToActive(slot, container)   —— 取物到手持（RPC.TakeActiveItemFromAllOfSlot，支持任意容器）
--   PutActiveToSlot(slot, container)    —— 手持直放目标槽（RPC.PutAllOfActiveItemInSlot，不互换）
--   SwapActiveWithSlot(slot, container) —— 手持与目标槽互换（RPC.SwapActiveItemWithSlot）
-- container 传 nil 表示主物品栏；传容器实体表示背包/箱子/融合箱等
-- 借鉴 Exp_Max sort.lua 跨容器 swap：RPC.SwapActiveItemWithSlot(slot, container) 第二参为容器实体

-- 取物到手持（直发 RPC，支持任意容器）：官方副本 TakeActiveItemFromAllOfSlot 不含 container，故不走副本方法
function InventoryUtil:TakeSlotToActive(slot, container)
    SendRPCToServer(RPC.TakeActiveItemFromAllOfSlot, slot, container)
end

-- 将手持物品放入目标容器槽位（直放，不互换）
function InventoryUtil:PutActiveToSlot(slot, container)
    SendRPCToServer(RPC.PutAllOfActiveItemInSlot, slot, container)
end

-- 将手持物品与目标容器槽位物品互换
function InventoryUtil:SwapActiveWithSlot(slot, container)
    SendRPCToServer(RPC.SwapActiveItemWithSlot, slot, container)
end

-- 容器间瞬发 swap：把 srcContainer 的 srcSlot 物品与 dstContainer 的 dstSlot 物品互换（不依赖空槽）
-- swapMode：
--   "swap"（默认）目标槽有物→SwapActiveItemWithSlot 互换（两槽都有物）
--   "put"         目标槽空  →PutAllOfActiveItemInSlot 直放（不互换，等价于移动）
-- 端点分派：某端点为 nil（主物品栏）→ 副本本地方法（单世界免 RPC、多世界内部自发包 RPC）；
--          某端点为容器实体        → 直发 RPC 变体（副本/组件方法不含 container 参数，引擎限制）。
-- 仅发 RPC、不等待网络；连续多次 swap 时调用方需自行 RPC 节流（rpc>18 时 Sleep(0) 一次）
-- 用途：自动勋章的勋章盒↔融合容器↔物品栏直接换位（加速联动），以及整理归位复用
-- @return: true=已发出三连；false=前置条件不满足（手持非空）未发出
function InventoryUtil:SwapContainerSlots(srcContainer, srcSlot, dstContainer, dstSlot, swapMode)
    -- 前置：手持必须为空。官方 Take 在手持非空时是 no-op（inventory.lua:2195），
    -- 若此时照发第 2/3 步，就会拿"玩家原本拿在手上的东西"去和目标槽互换 → 物品错位。
    if self:GetActiveItem() ~= nil then
        return false
    end
    -- 1) 取 src 物到手持
    if srcContainer == nil then
        self:TakeActiveItemFromAllOfSlot(srcSlot)        -- 主物品栏：副本本地方法（免显式 RPC）
    else
        self:TakeSlotToActive(srcSlot, srcContainer)     -- 容器：直发 RPC（缺 container 参数）
    end
    -- 2) 手持物 → dst 槽（put 直放 / swap 互换）
    if dstContainer == nil then
        if swapMode == "put" then
            self:PutAllOfActiveItemInSlot(dstSlot)       -- 主物品栏：副本本地方法
        else
            self:SwapActiveItemWithSlot(dstSlot)         -- 主物品栏：副本本地方法
        end
    else
        if swapMode == "put" then
            self:PutActiveToSlot(dstSlot, dstContainer)
        else
            self:SwapActiveWithSlot(dstSlot, dstContainer)
        end
    end
    -- 3) 原 dst 物（现手持）→ 放回 src 槽
    if srcContainer == nil then
        self:PutAllOfActiveItemInSlot(srcSlot)           -- 主物品栏：副本本地方法
    else
        self:PutActiveToSlot(srcSlot, srcContainer)
    end
    return true
end

return InventoryUtil  -- 导出库存功能模块