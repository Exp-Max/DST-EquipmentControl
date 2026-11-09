--============================================================================
-- 自动工具 (autotool) — 手中无工具时自动装备并执行对应动作
--============================================================================
-- LMB: 钓鱼(池塘/岩浆池/船上钓鱼池→勋章玻璃钓竿) > 标准工具(CHOP/MINE/NET) > 勋章玻璃锤(MEDALHAMMER)
-- RMB: 镰刀(SCYTHE) > 标准工具(DIG/HAMMER)
-- 注：HAMMER 走右键（官方 ISVALID.workable 只允许 right=true），别被它没有 rmb 字段骗了
--============================================================================
-- 适配模组工具:
--   1. TOOL_CATEGORY_MAP 加映射: ACTION_NAME = "CATEGORY"
--   2. 目标需有 ACTION_NAME_workable tag（ToolTagForTarget 检测）
--   3. 工具需有 ACTION_NAME_tool tag（tool:SetAction() 自动添加）
--   4. IsWorkAction() 追加新动作（自动重复用）
--============================================================================

local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local ActionUtil = require "util/actionutil"
local WorldUtil = require "util/worldutil"
local ConfigUtil = require "util/configutil"

-- 帧级库存快照缓存：放置/建造模式下 DoGetMouseActions 每帧被调用，
-- 同帧内 LMB/RMB 两次注入共用一次全量扫描（FindTool / FindToolByTag / 船桨）
local _inv_snapshot = nil
local _inv_snapshot_time = -1

local function GetInventorySnapshot()
    local now = GetTime()
    if _inv_snapshot == nil or now - _inv_snapshot_time > FRAMES then
        _inv_snapshot = InventoryUtil:GetPlayerInventory(true, false, true)
        _inv_snapshot_time = now
    end
    return _inv_snapshot
end

local function GetOarFromInventory()
    for _, item in pairs(GetInventorySnapshot()) do
        if item:IsValid() and ItemUtil:IsOar(item) then
            return item
        end
    end
end

-- 工具动作的匹配顺序（**必须是确定的顺序**）：同一目标带多个 "_workable" tag 时，
-- 取哪个动作决定了要自动装哪把工具，靠 pairs 的哈希序就是撞运气。
-- 顺序 = 官方 Action.priority 升序（actions.lua：CHOP/MINE/DIG/SCYTHE 为默认 0，
-- HAMMER/NET 为 3），同优先级按字母序。
-- REMOVELUNARBUILDUP 排在 CHOP 前面：月枝/月晶堆积的目标同时带 CHOP_workable 和
-- removelunarbuildup_workable 标签，清理动作必须先于砍伐被匹配。
local TOOL_ACTION_ORDER = { "REMOVELUNARBUILDUP", "CHOP", "DIG", "MINE", "SCYTHE", "HAMMER", "NET" }

local TOOL_CATEGORY_MAP = {
    REMOVELUNARBUILDUP = "PICKAXE",
    CHOP   = "AXE",
    MINE   = "PICKAXE",
    DIG    = "SHOVEL",
    HAMMER = "HAMMER",
    NET    = "BUGNET",
    SCYTHE = "SCYTHE",
}

-- 工作动作（自动重复记录用）
local WORK_ACTIONS = {
    CHOP = true, MINE = true, DIG = true, HAMMER = true, NET = true, SCYTHE = true,
    FILL = true, BRUSH = true, POUNCECAPTURE = true,
    REMOVELUNARBUILDUP = true,
    MEDALTRANSPLANT = true, MEDALNORMALTRANSPLANT = true, MEDALHAMMER = true,
}

local function IsWorkAction(action)
    for k in pairs(WORK_ACTIONS) do
        if action == GLOBAL.ACTIONS[k] then return true end
    end
    return false
end

local function IsFishableTarget(target)
    return target and target:IsValid() and target:HasTag("fishable")
end

local function IsScytheTarget(target)
    return target and target:IsValid()
        and target:HasTag("pickable")
        and target:HasOneOfTags({ "plant", "lichen", "oceanvine", "kelp" })
end

local function ToolTagForTarget(target)
    for _, act in ipairs(TOOL_ACTION_ORDER) do
        if target:HasTag(act .. "_workable") then return act end
    end
end

-- 帧级快捷栏缓存：GetItemFromCategory 内部是一次全量扫描 + 排序，
-- 放置/建造模式下每帧都会走到这里，同帧内复用结果
local _hotbar_cache = {}
local _hotbar_cache_time = -1

local function GetHotbarItem(category)
    local now = GetTime()
    if now - _hotbar_cache_time > FRAMES then
        _hotbar_cache = {}
        _hotbar_cache_time = now
    end
    if _hotbar_cache[category] == nil then
        -- false 表示"确实没有"，避免每帧重复空扫
        local ac = PlayerUtil:GetComponent("actioncontroller")
        _hotbar_cache[category] = (ac and ac:GetItemFromCategory(category)) or false
    end
    return _hotbar_cache[category] or nil
end

local function FindTool(act)
    local tag = act .. "_tool"
    local category = TOOL_CATEGORY_MAP[act]

    -- 优先使用快捷栏设定的物品（参考 autocane 的 ShouldEquipCane 逻辑：
    -- controller:GetItemFromCategory 会返回快捷栏设定/偏好/优先级最高的物品）
    if category and PlayerUtil:GetComponent("actioncontroller") then
        local hotbarItem = GetHotbarItem(category)
        if hotbarItem and hotbarItem:IsValid() and hotbarItem:HasTag(tag) then
            return hotbarItem
        end
    end

    for _, item in pairs(GetInventorySnapshot()) do
        if item:IsValid() and item:HasTag(tag) then return item end
    end
end

local function FindToolByTag(tag)
    for _, item in pairs(GetInventorySnapshot()) do
        if item:IsValid() and item:HasTag(tag) then return item end
    end
end

local function FindBrushTool()
    return InventoryUtil:FindItemAnywhere("brush")
        or FindToolByTag("brush")
end

local function FindWateringCan()
    for _, item in ipairs(GetInventorySnapshot()) do
        if item:IsValid() and item:HasTag("fillable") and ItemUtil:GetPercentUsed(item) < 100 then
            return item
        end
    end
    return nil
end

local function IsToolEnabled(actionName)
    local category = TOOL_CATEGORY_MAP[actionName]
    if category then
        local toggle = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[category]
        return toggle == nil or toggle == true
    end
    return true
end

-- 从 picker 的候选动作列表里剔除已关闭的工具动作。
-- 必须在这一层剔（而不是等 DoGetMouseActions 选出 actions[1] 后再把它置 nil）：
-- 同一目标上往往还有别的可用动作（手持锤子右键便携厨具 = 首选 HAMMER、次选"打开"），
-- 把选好的那一个置 nil 会把整个按键清空，次选也一起没了；
-- 在候选列表层剔除则 picker 的自然回退（取下一个可用动作）照常工作。
-- 无命中时原样返回，不产生新表。
local function FilterToolActions(actions)
    if actions == nil then return actions end
    local has_disabled = false
    for _, act in ipairs(actions) do
        local id = act.action and act.action.id
        if id ~= nil and not IsToolEnabled(id) then
            has_disabled = true
            break
        end
    end
    if not has_disabled then return actions end

    local ret = {}
    for _, act in ipairs(actions) do
        local id = act.action and act.action.id
        if id == nil or IsToolEnabled(id) then
            ret[#ret + 1] = act
        end
    end
    return ret
end

-- 判断某动作在该目标上走的是左键还是右键 —— 一律问游戏，不猜 Action 字段。
-- 官方把这件事写在 EntityScript:IsActionValid(action, right)（componentactions.lua:3174）里，
-- 工具收集器也是这么筛的（componentactions.lua:1811 按 target:IsActionValid(ACTIONS[k], right) 决定插不插）。
-- 只看 act.rmb 会漏：HAMMER = Action({ priority=3 })（actions.lua:407）**没有 rmb 字段**，
-- 却因为 ISVALID.workable 的 `(right or action ~= ACTIONS.HAMMER)`
-- （componentactions.lua:3034）而只在右键有效 —— 这正是"锤子动作被注入到左键"那个 bug 的根因。
local function ActionUsesRightButton(target, act, isRMB)
    if target ~= nil and target.IsActionValid ~= nil then
        -- 官方去重语义（playeractionpicker.lua:535-541）：左右键都有效时左键优先、右键让位，
        -- 故"右键命中"要求"右键有效且左键无效"，而"左键命中"只要求左键有效。
        -- mod 的自定义 actioncomponent 校验器可能抛异常，退化为 rmb 字段判断而不是让点击失效。
        local ok, valid = pcall(target.IsActionValid, target, act, isRMB)
        if ok then
            if isRMB then
                local ok2, left = pcall(target.IsActionValid, target, act, false)
                return valid and (not ok2 or not left)
            end
            return valid
        end
    end
    -- 兜底：旧版/无 IsActionValid 时按 rmb 字段判（HAMMER 这类动作在这里会判错，故只作最后手段）
    return isRMB and act.rmb == true or act.rmb ~= true
end

-- 尝试注入标准工具动作，按 isRMB 过滤（判定见 ActionUsesRightButton）
local function TryStandardTool(inst, target, toolAction, isRMB)
    if not toolAction or not IsToolEnabled(toolAction) then return nil end
    local act = GLOBAL.ACTIONS[toolAction]
    if not act then return nil end
    if ActionUsesRightButton(target, act, isRMB) then
        local tool = FindTool(toolAction)
        if tool then
            local mouseAction = GLOBAL.BufferedAction(inst, target, act, tool)
            mouseAction.AUTOEQUIP = tool
            return mouseAction
        end
    end
end

--============================================================================
-- 特殊目标动作配置（按顺序匹配，先匹配先生效）
-- condition(target, toolAction): toolAction 为 ToolTagForTarget 返回值，可能为 nil
-- findTool(target): 返回背包中的工具实体，找不到返回 nil
--============================================================================

-- 勋章玻璃钓竿适配：所有 fishable 组件目标（池塘/岩浆池/船上钓鱼池/虚空钓鱼池等）
-- 玻璃钓竿可钓遗失塑料袋；岩浆池仅玻璃钓竿可钓（勋章模组 FISH fn 校验 doer 的 medal_fishingrod 标签，
-- 玻璃钓竿与暗影魔法工具钓竿形态装备时都会加该标签）
-- 通过组件检测而非 prefab 硬编码，自动适配 Medal 模组未来新增的池塘类型

local LMB_SPECIAL_ACTIONS = {
    {
        name = "BRUSH",
        condition = function(target, toolAction)
            return target and target:IsValid() and target:HasTag("brushable")
        end,
        findTool = function()
            return FindBrushTool()
        end,
    },
    {
        name = "POUNCECAPTURE",
        condition = function(target, toolAction)
            return target and target:IsValid() and target:HasTag("gestaltcapturable")
        end,
        findTool = function()
            return FindToolByTag("gestalt_cage")
        end,
    },
    {
        -- 可捕捉目标（蝴蝶/蜜蜂等 catchable）：注入 ACTIONS.CATCH 而非 NET。
        -- CATCH 带 distance=math.huge 且无 rangecheckfn，引擎会先走过去再捕捉；
        -- 原生 NET 无 distance 且只在该目标已在 ≤5 单位内才产出（playercontroller:2144），
        -- 直接用 NET 注入远距目标会导致原地空挥、白耗耐久。
        name = "CATCH",
        condition = function(target, toolAction)
            return target and target:IsValid()
                and target:HasTag("catchable")
                and IsToolEnabled("NET")
        end,
        findTool = function()
            return FindTool("NET")
        end,
    },
    {
        name = "FISH",
        condition = function(target, toolAction)
            return not toolAction and IsFishableTarget(target)
        end,
        findTool = function(target)
            return InventoryUtil:FindItemAnywhere("medal_fishingrod")
                or InventoryUtil:FindItemAnywhere("fishingrod")
        end,
    },
    {
        name = "MEDALHAMMER",
        condition = function(target, toolAction)
            if not (target and target:IsValid()) then return false end
            if not target:HasTag("MEDALHAMMER_workable") then return false end
            return WorldUtil:IsFullMoon() or (ThePlayer and ThePlayer:HasTag("inmoonlight"))
        end,
        findTool = function(target)
            return InventoryUtil:FindItemAnywhere("medal_moonglass_hammer")
        end,
    },
}

local RMB_SPECIAL_ACTIONS = {
    {
        name = "FILL",
        condition = function(target, toolAction)
            return target and target:IsValid() and target:HasTag("watersource")
        end,
        findTool = function()
            return FindWateringCan()
        end,
    },
    {
        name = "SCYTHE",
        condition = function(target, toolAction)
            return IsScytheTarget(target)
        end,
        findTool = function()
            return FindTool("SCYTHE")
        end,
    },
    {
        name = "MEDALNORMALTRANSPLANT",
        condition = function(target, toolAction)
            return target and target:IsValid()
                and target:HasTag("MEDALNORMALTRANSPLANT_workable")
        end,
        findTool = function()
            return InventoryUtil:FindItemAnywhere("medal_moonglass_shovel")
        end,
    },
    {
        name = "MEDALTRANSPLANT",
        condition = function(target, toolAction)
            return target and target:IsValid()
                and target:HasTag("MEDALTRANSPLANT_workable")
        end,
        findTool = function()
            return InventoryUtil:FindItemAnywhere("medal_moonglass_shovel")
        end,
    },
    {
        name = "MEDALHAMMER",
        condition = function(target, toolAction)
            if not (target and target:IsValid()) then return false end
            if not target:HasTag("MEDALHAMMER_workable") then return false end
            local is_fullmoon = WorldUtil:IsFullMoon()
            local has_moonlight = ThePlayer and ThePlayer:HasTag("inmoonlight")
            return is_fullmoon or has_moonlight
        end,
        findTool = function()
            return InventoryUtil:FindItemAnywhere("medal_moonglass_hammer")
        end,
    },
}

--============================================================================
-- Phase 1: DoGetMouseActions — LMB/RMB 独立拦截注入
-- 通过 actionutil 纯分发机制注册：actionutil 只负责包装 DoGetMouseActions + 调用修改器，
-- 所有决策逻辑（目标匹配、工具选择、动作注入）由本函数全权负责
--============================================================================
local function ModifyMouseActions(self, position, target, lmb, rmb)
    -- self = playeractionpicker 组件，self.inst = ThePlayer

    if not target then
        target = GLOBAL.TheInput:GetWorldEntityUnderMouse()
    end

    local activeItem = InventoryUtil:GetActiveItem()

    -- 手持已满 fillable 且悬停在水源上时，仍需注入以切换到下一个空壶
    local hasFullFillable = activeItem and activeItem:HasTag("fillable")
        and ItemUtil:GetPercentUsed(activeItem) >= 100
        and target and target:HasTag("watersource")

    if (not activeItem or hasFullFillable)
        and not InventoryUtil:IsHeavyLifting()
        and target and GLOBAL.CanEntitySeeTarget(self.inst, target)
    then
        -- 该函数在放置/建造模式下每帧被调用，结果对同一 target 恒定，只算一次
        local toolAction = ToolTagForTarget(target)

        -- LMB 注入：WALKTO/LOOKAT → 钓鱼/标准 LMB 工具（仅空手时）
        if not activeItem and ActionUtil:IsEmptyClickAction(lmb)
        then
            local did_inject = false

            -- 特殊目标动作（钓鱼、月雹清理等）
            for _, cfg in ipairs(LMB_SPECIAL_ACTIONS) do
                if not did_inject and cfg.condition(target, toolAction) then
                    local tool = cfg.findTool(target)
                    if tool then
                        lmb = GLOBAL.BufferedAction(self.inst, target, GLOBAL.ACTIONS[cfg.name], tool)
                        lmb.AUTOEQUIP = tool
                        did_inject = true
                    end
                end
            end

            -- 标准 LMB 工具 (CHOP/MINE/HAMMER/NET)
            if not did_inject then
                lmb = TryStandardTool(self.inst, target, toolAction, false) or lmb
            end
        end

        -- RMB 注入：nil/WALKTO/LOOKAT → 镰刀/标准 RMB 工具
        -- hasFullFillable 时默认 RMB 为 FILL，也需覆盖以切换到下一个空壶
        if hasFullFillable
            or ActionUtil:IsEmptyClickAction(rmb)
        then
            local did_inject = false

            -- 特殊目标动作（镰刀收割等）
            for _, cfg in ipairs(RMB_SPECIAL_ACTIONS) do
                if not did_inject and cfg.condition(target, toolAction) then
                    local tool = cfg.findTool()
                    if tool then
                        rmb = GLOBAL.BufferedAction(self.inst, target, GLOBAL.ACTIONS[cfg.name], tool)
                        rmb.AUTOEQUIP = tool
                        did_inject = true
                    end
                end
            end

            -- 标准 RMB 工具 (DIG)
            if not did_inject then
                rmb = TryStandardTool(self.inst, target, toolAction, true) or rmb
            end
        end
    end

    -- 船上右键水面时，把船桨作为自动工具装备后执行划船。
    if not InventoryUtil:GetActiveItem()
        and not InventoryUtil:IsHeavyLifting()
        and target == nil
        and GLOBAL.GetModConfigData("QUICK_ACTION_ROW", MOD_EQUIPMENT_CONTROL.MODNAME)
        and GLOBAL.ThePlayer:GetCurrentPlatform() ~= nil
    then
        local oar = GetOarFromInventory()
        if oar and ActionUtil:IsEmptyClickAction(rmb)
        then
            rmb = GLOBAL.BufferedAction(self.inst, nil, GLOBAL.ACTIONS.ROW, oar, position)
            rmb.AUTOEQUIP = oar
        end
    end

    return lmb, rmb
end

--============================================================================
-- Phase 2: OnLeftClick / OnRightClick — AUTOEQUIP 检测与装备切换
-- Phase 3: equip 事件 — 装备完成后执行动作
--============================================================================
-- 本钩子只需构造期的 self / self.inst，处理器挂载时机由 actionutil 统一兜底
-- （AddClassPostConstruct 跑在 self.components[name] 赋值之前，actionutil 内部用
--   AddComponentPostInit 在组件挂到实体后补装，故这里无需自行处理时机）
AddClassPostConstruct("components/playercontroller", function(self)
    if self.inst ~= GLOBAL.ThePlayer then return end

    self.autotool_pendingAction = nil
    self.autotool_workTarget = nil

    -- DoGetMouseActions 修改器注册：actionutil 负责纯分发包装，本文件 ModifyMouseActions 负责所有决策
    ActionUtil:RegisterMouseActionModifier(self.inst, ModifyMouseActions)

    -- 已关闭的工具动作从 picker 候选列表里剔除（显示与执行同源）：
    -- DoGetMouseActions 的 lmb/rmb 就是 actions[1]（playeractionpicker.lua:525-526），
    -- 在列表层过滤后，首选被关闭时 picker 会自动回退到同一目标的下一个可用动作
    -- （如手持锤子右键便携厨具：HAMMER 被关闭 → 回退到"打开"），
    -- 而不是把整个按键清空、连其它动作一起屏蔽。
    -- 包装与分发交给 actionutil 的通道 D2（与物品栏动作表修饰同构），本文件只提供过滤决策。
    ActionUtil:RegisterClickActionsFilter(self.inst, 0, FilterToolActions)

    -- AUTOEQUIP 通用处理：保存 pendingAction → Equip → return true
    local function HandleAutoEquip(act)
        if not act or not act.AUTOEQUIP then return false end
        -- 工具已装备则跳过，避免 Equip→Server 的 toggle 行为导致反复装卸
        if InventoryUtil:IsEquipped(act.AUTOEQUIP) then return false end
        self.autotool_pendingAction = {
            target   = act.target,
            action   = act.action,
            tool     = act.invobject,
            position = act.pos,
        }
        ConfigUtil:AutoEquip("TOOL", act.AUTOEQUIP)
        return true
    end

    -- 左/右键 AUTOEQUIP 检测：装备所需工具后拦截原点击，由 equip 事件延迟执行动作。
    -- 复用 actionutil 通用点击分发（RegisterLeftClickHandler / RegisterRightClickHandler），
    -- 处理器契约 fn(self, act, down) -> "consume" 拦截原点击，否则原点击照常执行。
    local function ClickAutoEquipHandler(self, act, down)
        if down then
            self.autotool_workTarget = nil
            if act then
                if IsWorkAction(act.action) then self.autotool_workTarget = act.target end
                if HandleAutoEquip(act) then return "consume" end
            end
        end
    end

    ActionUtil:RegisterLeftClickHandler(self.inst, 0, ClickAutoEquipHandler)
    ActionUtil:RegisterRightClickHandler(self.inst, 0, ClickAutoEquipHandler)

    -- DoAction 拦截：鼠标左右键 + Shift排队论 的最后一环
    -- 注意：空格键（CONTROL_ACTION）不经过 DoAction，由下方的通道 H button 屏蔽器处理
    ActionUtil:RegisterDoActionInterceptor(self.inst, 0, function(pc, act)
        local action = act and act.action
        if not action then return nil end
        local actionName = type(action) == "table" and action.id or (type(action) == "string" and action)
        if not actionName then return nil end
        if not IsToolEnabled(actionName) then
            return "block"
        end
    end)

    -- 空格键（CONTROL_ACTION）屏蔽：DoActionButton 不经 DoAction，
    -- 由 actionutil 通道 H 的 button 安检点处理，覆盖主机（PushAction）
    -- 和客机（RemoteActionButton）两条派发路径
    ActionUtil:RegisterActionBlocker(self.inst, 0, function(ctx)
        if ctx.source ~= "button" then return nil end
        local id = ctx.action_id
        if id ~= nil and not IsToolEnabled(id) then
            return true
        end
    end)

    -- Equip 事件（LMB/RMB 共用）
    -- 延迟一帧执行，等待装备状态完全就绪（避免 IsBusy 拦截）
    self.inst:ListenForEvent("equip", function(inst, data)
        if not self.autotool_pendingAction or not data or not data.item then return end
        local pa = self.autotool_pendingAction

        if not pa.tool or data.item.prefab ~= pa.tool.prefab then return end

        local target, action = pa.target, pa.action
        if IsWorkAction(action) then
            self.autotool_workTarget = target
        end
        self.autotool_pendingAction = nil

        if ((not target or not target:IsValid()) and action ~= GLOBAL.ACTIONS.ROW) or not action then return end

        local position = pa.position or (target and target:GetPosition()) or GLOBAL.TheInput:GetWorldPosition()
        local rpc = action.rmb and GLOBAL.RPC.RightClick or GLOBAL.RPC.LeftClick
        local tool = data.item  -- 捕获物品实体引用供延迟回调使用

        -- 仿原生 OnRightClick/OnLeftClick 的 RPC 参数序列：
        -- code, x, z, target, rotation, isreleased, controlmods, canforce/noforce, mod_name, platform, has_platform
        -- 必须传 mod_name，否则服务端 OnRemoteRightClick 的 rmb.action.mod_name == mod_name 校验失败
        local controlmods = self:EncodeControlMods()
        local platform, pos_x, pos_z = self:GetPlatformRelativePosition(position.x, position.z)
        local ctrl = action.rmb and GLOBAL.CONTROL_SECONDARY or GLOBAL.CONTROL_PRIMARY

        if self.inst.components.locomotor == nil then
            if action.rmb then
                GLOBAL.SendRPCToServer(rpc, action.code, pos_x, pos_z, target,
                    nil, nil, controlmods, action.canforce, action.mod_name,
                    platform, platform ~= nil)
            else
                GLOBAL.SendRPCToServer(rpc, action.code, pos_x, pos_z, target,
                    nil, controlmods, action.canforce, action.mod_name,
                    platform, platform ~= nil)
            end
        else
            if self.locomotor == nil then
                self.locomotor = self.inst.components.locomotor
            end
            self.inst:DoTaskInTime(0, function()
                if not (tool:IsValid() and (action == GLOBAL.ACTIONS.ROW or target:IsValid())) then
                    return
                end
                local act = GLOBAL.BufferedAction(inst, target, action, tool, position)
                act.preview_cb = function()
                    local isreleased = not GLOBAL.TheInput:IsControlPressed(ctrl)
                    GLOBAL.SendRPCToServer(rpc, action.code, pos_x, pos_z, target,
                        nil, isreleased, controlmods, nil, action.mod_name,
                        platform, platform ~= nil)
                end
                self:DoAction(act)
            end)
        end
    end)

    -- 自动重复
    if WorldUtil:IsMasterSim() then
        local _IsAnyOfControlsPressed = self.IsAnyOfControlsPressed
        function self:IsAnyOfControlsPressed(...)
            if self.inst:HasTag("working") or (self.inst.sg and self.inst.sg:HasStateTag("working")) then
                for _, control in ipairs({...}) do
                    if control == GLOBAL.CONTROL_ACTION then return true end
                end
            end
            return _IsAnyOfControlsPressed(self, ...)
        end
    else
        local _OnUpdate = self.OnUpdate
        function self:OnUpdate(...)
            if self.inst:HasTag("working") or (self.inst.sg and self.inst.sg:HasStateTag("working")) then
                self:OnControl(GLOBAL.CONTROL_ACTION, true)
            end
            _OnUpdate(self, ...)
        end
    end
end)