-- 物品快捷操作
--   Shift+双击左键 → 批量转移同 prefab
--   Shift+右键     → 快速丢弃（单击单件 / 双击连续，库存/容器）
--   Ctrl+双击装备槽 → 连续丢弃（装备槽，原 repeatdrop.lua 已并入本模块）

local InventoryUtil = require "util/inventoryutil"
local PlayerUtil = require "util/playerutil"
local ItemUtil = require "util/itemutil"

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
-- Init() — 填充 State，设置 replica 包装
-- =========================================================================
local function Init()
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

table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, Init)
