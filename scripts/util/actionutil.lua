-- 动作工具统一层 — 只做「包装 + 分发」，业务决策全部由注册回调负责。
-- 使用者：quickactions / quickdeploy / autotool / autocane / automedal / telepoof / gridalign / filterpickup。
--
-- 必须 modimport 加载（见 modmain.lua），不要直接 require：文件内使用 AddComponentPostInit 等
-- mod 专属 API，而 require 环境是游戏全局表、strict.lua 下这些 mod 全局未声明，加载期即报错。
-- modmain 会把 ActionUtil 写入 package.loaded，其它模块仍可 require("util/actionutil")。
--
-- 通道一览（各通道的处理器契约写在小节开头）：
--   A  左右键点击              RegisterLeft/RightClickHandler
--   B  物品栏格子使用/检查      RegisterInventoryItemHandler
--   C  物品栏动作表修饰         RegisterInventoryActionsModifier
--   C2 手持物→格子动作表修饰    RegisterUseItemActionsModifier
--   D  DoGetMouseActions 修改   RegisterMouseActionModifier
--   D2 左右键候选列表过滤       RegisterClickActionsFilter
--   E  点击 RPC 派发            RegisterClickRPCHandler
--   F  动作落点吸附             RegisterActionPointSnap
--   G  DoAction 拦截器          RegisterDoActionInterceptor
--   H  动作屏蔽                 RegisterActionBlocker / BlockAction / IsActionBlockedFor
--   I  控制前钩子               RegisterControlHandler
--
-- 注册约定：
--  · 支持 inst=nil 的全局通道：物品栏格子、库存动作表、落点吸附、动作屏蔽。
--    可在 ThePlayer 尚不存在时注册；其它通道要求传入 player/playeractionpicker 实例。
--  · 全部「实例级包裹 + 幂等」，且无处理器时不包裹 —— 未注册零开销
--  · 注册时机任意：组件已就绪当场包装，否则由文件末尾的挂载点补装
--  · 支持 priority 的处理器按 priority 升序执行，同优先级按注册顺序
--  · 动作属于左键还是右键一律问游戏：componentactions.lua:3174
--    EntityScript:IsActionValid(action, right)；只看 Action.rmb 会漏掉 HAMMER（无 rmb 字段但必须 right=true）。
ActionUtil = {}

local unpack_fn = GLOBAL.unpack or unpack

-- =============================================
-- [1] 动作判断
-- =============================================

-- 兼容原生 ACTIONS.xxx 引用与 mod 自定义 { id = "XXX" } 裸表
local function IsEmptyActionRaw(actionObj)
    if actionObj == nil then return true end
    if actionObj == ACTIONS.WALKTO or actionObj == ACTIONS.LOOKAT then return true end
    local id = actionObj.id
    if id ~= nil then
        return id == "WALKTO" or id == "LOOKAT"
    end
    return false
end

--- 空交互（无实际意义，可安全覆盖）：nil / 无 .action 的 BufferedAction / WALKTO / LOOKAT
function ActionUtil:IsEmptyClickAction(bufferedAction)
    if bufferedAction == nil then return true end
    local action = bufferedAction.action
    if action == nil then
        -- 部分 mod 直接传 ACTIONS.xxx 而非 BufferedAction
        return IsEmptyActionRaw(bufferedAction)
    end
    return IsEmptyActionRaw(action)
end

function ActionUtil:IsValidBufferedAction(buffaction)
    return buffaction ~= nil and buffaction.action ~= nil
end

--- BufferedAction 的 action_id（ACTIONS.xxx 的 .id）
function ActionUtil:GetActionId(buffaction)
    if buffaction == nil then return nil end
    local action = buffaction.action
    return action and action.id
end

--- 快速动作：由 quickactions 创建，automedal 的 HandleAction 据此跳过双重 AutoEquipMedal
function ActionUtil:IsQuickAction(buffaction)
    return buffaction ~= nil
        and buffaction.medal_prefabs ~= nil
        and buffaction.modaction ~= nil
end

--- 当前有效点击动作（优先右键，右键为空时回退左键）
--- @return BufferedAction|nil, "rmb"|"lmb"|nil
function ActionUtil:GetEffectiveClickAction(pc)
    if pc == nil then return nil, nil end
    local rmb = pc:GetRightMouseAction()
    if not ActionUtil:IsEmptyClickAction(rmb) then
        return rmb, "rmb"
    end
    local lmb = pc:GetLeftMouseAction()
    if not ActionUtil:IsEmptyClickAction(lmb) then
        return lmb, "lmb"
    end
    return nil, nil
end

-- =============================================
-- [2] 动作频率控制
-- =============================================

local last_action_id = nil
local last_action_time = 0

--- 动作变化 或 距上次处理超过 min_interval 秒时返回 true，并更新内部状态
function ActionUtil:ShouldProcessAction(action_id, min_interval)
    min_interval = min_interval or 0.1
    local now = GetTime()
    if action_id ~= last_action_id or (now - last_action_time) >= min_interval then
        last_action_id = action_id
        last_action_time = now
        return true
    end
    return false
end

function ActionUtil:GetLastActionId()
    return last_action_id
end

-- =============================================
-- [3] USEITEM 可用性判定
-- 用桩 doer 复用官方已注册的 component action，不硬编码目标条件。
-- =============================================

-- HasTag 恒真：补上"佩戴勋章后才有的能力标签"（如 expertchef/masterchef）；
-- 其余字段回退真实玩家，避免 testfn 取 doer.components / doer.prefab 时拿到 nil。
-- 整体调用由 pcall 兜底，单个 testfn 出错只判否。
local STUB_DOER = setmetatable({}, {
    __index = function(_, k)
        if k == "HasTag" then
            return function() return true end
        end
        return ThePlayer ~= nil and ThePlayer[k] or nil
    end,
})

--- 判定"某物品对某目标能否执行指定 USEITEM 动作"。
--- 不能直接用 picker:GetUseItemActions：其 doer 固定为真实玩家，而 mod 的 testfn 常含
--- doer:HasTag(<能力标签>)，快速动作/预切场景恰恰是"勋章尚未佩戴"，会永远判否。
--- 官方写法见 playeractionpicker.lua:145（useitem:CollectActions("USEITEM", ...)）。
--- @param action_id string|Action
function ActionUtil:AcceptsUseItemAction(item, target, action_id)
    local action = type(action_id) == "string" and ACTIONS[action_id] or action_id
    if not (item and target and action) then return false end
    if item.CollectActions == nil then return false end

    local actions = {}
    local ok = pcall(item.CollectActions, item, "USEITEM", STUB_DOER, target, actions, true)
    if not ok then return false end

    for _, a in ipairs(actions) do
        if a == action then return true end
    end
    return false
end

-- =============================================
-- [4] 注册中心 & 通用分发
-- 实例处理器挂在 registries（弱键，inst 回收即释放）；全局处理器各通道一个普通表。
-- 同一次分发里先跑实例、后跑全局。
-- =============================================

local CHANNELS = {
    "lmb", "rmb", "invitem", "invactions", "useitemactions",
    "mouse", "clickactions", "snap", "doaction", "blockers", "control",
}

local registries = setmetatable({}, { __mode = "k" })

local function GetRegistry(inst)
    if inst == nil then return nil end
    local reg = registries[inst]
    if reg == nil then
        reg = {}
        for _, k in ipairs(CHANNELS) do reg[k] = {} end
        registries[inst] = reg
    end
    return reg
end

local function RequireInstance(inst, method)
    assert(inst ~= nil, method .. " requires an instance")
end

-- 稳定排序：table.sort 非稳定，故显式带注册序号
local function SortHandlers(handlers)
    for i, h in ipairs(handlers) do h._order = i end
    table.sort(handlers, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a._order < b._order
    end)
end

local function InsertSorted(handlers, priority, fn)
    table.insert(handlers, { priority = priority or 0, fn = fn })
    SortHandlers(handlers)
end

-- 插入的是「规则表」而非函数（判定见 BlockSpecMatches）
local function InsertSpec(handlers, priority, spec)
    table.insert(handlers, { priority = priority or 0, spec = spec })
    SortHandlers(handlers)
end

-- 全局通道去重：按函数身份，世界重载 / 换角色重复注册不会翻倍
local function PushUnique(list, priority, fn)
    for _, h in ipairs(list) do
        if h.fn == fn then return end
    end
    InsertSorted(list, priority, fn)
end

-- 列表修饰器分发：处理器返回非 nil 则替换当前列表
local function DispatchList(list, value, ...)
    for _, h in ipairs(list) do
        local res = h.fn(value, ...)
        if res ~= nil then value = res end
    end
    return value
end

-- 通用「包装返回列表的方法」：dispatch(list, self, ...) 负责分发。
-- 目标方法缺失或已包装时直接返回，保留已有补丁链。
local function InstallListHook(target, method, flag, dispatch)
    if target == nil or target[method] == nil or target[flag] then return end
    target[flag] = true
    local orig = target[method]
    target[method] = function(self, ...)
        return dispatch(orig(self, ...), self, ...)
    end
end

-- =============================================
-- [5] 动作屏蔽核心（通道 H）
-- ctx 契约：屏蔽器 fn(ctx) -> true 屏蔽 / nil 放行
--   source = "press"  DoAction 系列（鼠标 / 排队论 / 各模块自调）
--            "button" GetActionButtonAction（DoActionButton 不经 DoAction，单独挂载点）
--            "rpc"    绕过 DoAction 直接发的点击 RPC —— 真实派发，计数型应在此计数
--            "hover"  只读查询
-- 一次物理动作只计一次：press 放行后其后续 RPC 到达时计数已归零；press 被拦则不产生 RPC。
-- =============================================

local globalActionBlockers = {}

-- 补全 ctx；外部只读查询（hover）也走这里
local function MakeBlockContext(pc, opts)
    local ba = opts.buffaction
    local action = opts.action or (ba ~= nil and ba.action) or nil
    return {
        pc         = opts.pc or pc,
        source     = opts.source or "query",
        buffaction = ba,
        action     = action,
        action_id  = opts.action_id or (action ~= nil and action.id) or nil,
        target     = opts.target or (ba ~= nil and ba.target) or nil,
        invobject  = opts.invobject or (ba ~= nil and ba.invobject) or nil,
        doer       = opts.doer or (ba ~= nil and ba.doer) or nil,
        right      = opts.right == true,
    }
end

local function MatchesAny(value, candidate)
    if type(candidate) == "table" then
        for _, v in ipairs(candidate) do
            if value == v then return true end
        end
        return false
    end
    return value == candidate
end

--- 精准规则匹配：spec 中每个非 nil 字段都参与判定（同时给出时须全部满足）
local function BlockSpecMatches(spec, ctx)
    -- enabled 每次实时求值，不缓存 —— confighud 运行时改写 CONFIG 立即生效
    local en = spec.enabled
    if type(en) == "function" then en = en(ctx) end
    if en == false then return false end

    if spec.action_id ~= nil and not MatchesAny(ctx.action_id, spec.action_id) then return false end
    if spec.right ~= nil and spec.right ~= ctx.right then return false end
    if spec.sources ~= nil and not MatchesAny(ctx.source, spec.sources) then return false end

    if spec.target_prefab ~= nil
        and (ctx.target == nil or not MatchesAny(ctx.target.prefab, spec.target_prefab)) then
        return false
    end
    if spec.target_tag ~= nil then
        if ctx.target == nil then return false end
        if type(spec.target_tag) == "table" then
            local hit = false
            for _, tag in ipairs(spec.target_tag) do
                if ctx.target:HasTag(tag) then
                    hit = true
                    break
                end
            end
            if not hit then return false end
        elseif not ctx.target:HasTag(spec.target_tag) then
            return false
        end
    end
    if spec.target_match ~= nil
        and (ctx.target == nil or not spec.target_match(ctx.target)) then
        return false
    end
    if spec.invobject_prefab ~= nil
        and (ctx.invobject == nil or not MatchesAny(ctx.invobject.prefab, spec.invobject_prefab)) then
        return false
    end
    return true
end

--- 跑一遍全部屏蔽器（先实例、后全局）
local function RunActionBlockers(inst, pc, opts)
    local ctx = MakeBlockContext(pc, opts)
    local reg = inst ~= nil and registries[inst] or nil

    if reg ~= nil then
        for _, h in ipairs(reg.blockers) do
            if h.spec ~= nil then
                if BlockSpecMatches(h.spec, ctx) then return true end
            elseif h.fn ~= nil and h.fn(ctx) == true then
                return true
            end
        end
    end
    for _, h in ipairs(globalActionBlockers) do
        if h.spec ~= nil then
            if BlockSpecMatches(h.spec, ctx) then return true end
        elseif h.fn ~= nil and h.fn(ctx) == true then
            return true
        end
    end
    return false
end

local function HasAnyActionBlocker(inst)
    if #globalActionBlockers > 0 then return true end
    local reg = inst ~= nil and registries[inst] or nil
    return reg ~= nil and #reg.blockers > 0
end

-- =============================================
-- [6] 落点吸附核心（通道 F）
-- 契约 fn(pc, buffaction, pt) -> Vector3|nil（nil = 不吸附）
-- =============================================

local globalSnapHandlers = {}

local function HasSnapHandlers(inst)
    if #globalSnapHandlers > 0 then return true end
    local reg = inst ~= nil and registries[inst] or nil
    return reg ~= nil and #reg.snap > 0
end

local function RunSnapHandlers(inst, pc, buffaction, pt)
    local reg = inst ~= nil and registries[inst] or nil
    if reg ~= nil then
        for _, h in ipairs(reg.snap) do
            local v = h.fn(pc, buffaction, pt)
            if v ~= nil then return v end
        end
    end
    for _, h in ipairs(globalSnapHandlers) do
        local v = h.fn(pc, buffaction, pt)
        if v ~= nil then return v end
    end
    return nil
end

-- =============================================
-- [7] 点击 RPC 派发（通道 E）
-- 覆盖客户端 SendRPCToServer(LeftClick/RightClick)：正式发往服务端前跑屏蔽器
-- （source="rpc"）与通知型处理器。主机端本地点击不走 RPC，由 DoAction 层覆盖；
-- 排队论没有独立派发路径（SendAction 主机端必调 DoAction，客机端必走 RPC），无需额外钩子。
-- =============================================

local clickRPCInstalled = false
local clickRPCHandlers = {}

--- @return boolean true = 已被屏蔽，调用方应直接 return，不发 RPC
local function DispatchClickHandlers(action_id, target, right)
    if action_id == nil then return false end
    local inst = ThePlayer
    local pc = inst ~= nil and inst.components ~= nil and inst.components.playercontroller or nil
    if RunActionBlockers(inst, pc, {
        source = "rpc", action_id = action_id, right = right, target = target,
    }) then
        return true
    end
    for _, fn in ipairs(clickRPCHandlers) do
        fn(action_id, target)
    end
    return false
end

local _actionCodeToId = nil
local function GetActionCodeToId()
    if _actionCodeToId == nil then
        _actionCodeToId = {}
        for name, act in pairs(ACTIONS) do
            if type(act) == "table" and act.code then
                _actionCodeToId[act.code] = name
            end
        end
    end
    return _actionCodeToId
end

local function InstallClickRPC()
    if clickRPCInstalled then return end
    clickRPCInstalled = true
    local _orig = SendRPCToServer
    -- 写必须走 GLOBAL.*：mod 环境只挂了 __index 回退到 _G，没有 __newindex，
    -- 裸赋值只写到 mod 环境自己的表上，拦不到官方/其它 mod 的调用。
    GLOBAL.SendRPCToServer = function(rpc, ...)
        if rpc == RPC.LeftClick or rpc == RPC.RightClick then
            local args = { ... }
            local action_code = args[1]
            local target = args[4]
            if action_code and DispatchClickHandlers(
                    GetActionCodeToId()[action_code], target, rpc == RPC.RightClick) then
                return
            end
        end
        return _orig(rpc, ...)
    end
end

-- =============================================
-- [8] DoAction 安检（通道 G + F + H 的 press 层）
-- DoAction 是动作执行的唯一漏斗（playercontroller.lua:4514）：
-- 鼠标点击、排队论、各模块自调都经过它。顺序：屏蔽器 → 拦截器 → 落点吸附 → 原调用。
-- =============================================

local function RunDoActionInterceptors(inst, pc, act)
    local reg = inst ~= nil and registries[inst] or nil
    if reg == nil then return nil end
    for _, h in ipairs(reg.doaction) do
        if h.fn(pc, act) == "block" then return "block" end
    end
    return nil
end

-- 吸附坐标的两个出口。只有本次 DoAction 算出 snappos 时才替换；
-- GetPlatformRelativePosition 还被行走预测共用，非 DoAction 期间必须原样放行。
local function InstallSnapPositionHooks(pc, inst)
    if pc._ec_snap_pos_hooked then return end
    pc._ec_snap_pos_hooked = true

    local _GetPlatformRelativePosition = pc.GetPlatformRelativePosition
    pc.GetPlatformRelativePosition = function(self, absolute_x, absolute_z, ...)
        if self._ec_snappoint then
            absolute_x, absolute_z = self._ec_snappoint.x, self._ec_snappoint.z
        end
        return _GetPlatformRelativePosition(self, absolute_x, absolute_z, ...)
    end

    -- 快捷丢弃没有 BufferedAction，单独走一次吸附
    local _GetRemotePredictPositionExternal = pc.GetRemotePredictPositionExternal
    pc.GetRemotePredictPositionExternal = function(self, ...)
        local v = _GetRemotePredictPositionExternal(self, ...)
        if v ~= nil then
            local s = RunSnapHandlers(inst, self, nil, v)
            if s ~= nil then return s end
        end
        return v
    end
end

local function InstallDoActionHooks(pc, inst)
    if pc == nil or inst == nil then return end
    local reg = GetRegistry(inst)
    if not (HasAnyActionBlocker(inst) or #reg.doaction > 0 or HasSnapHandlers(inst)) then
        return
    end
    if HasSnapHandlers(inst) then
        InstallSnapPositionHooks(pc, inst)
    end
    if pc._ec_doaction_hooked then return end
    pc._ec_doaction_hooked = true

    local _DoAction = pc.DoAction
    pc.DoAction = function(self, buffaction, spellbook, ...)
        -- 第一道：动作屏蔽（source="press"：一次物理动作一次计数）
        if RunActionBlockers(inst, self, {
            source = "press",
            buffaction = buffaction,
            -- right 只是 hint（空格/动作键拿不到键位）；判定键位请用 target:IsActionValid
            right = buffaction ~= nil and buffaction.action ~= nil and buffaction.action.rmb == true,
        }) then
            return
        end
        -- 第二道：各模块自定义安检
        if RunDoActionInterceptors(inst, self, buffaction) == "block" then
            return
        end
        -- 第三道：落点吸附。显示与实际执行共用同一个 snappos
        local v
        if HasSnapHandlers(inst) and buffaction ~= nil then
            local pt = buffaction.GetActionPoint and buffaction:GetActionPoint()
                or (TheInput ~= nil and TheInput:GetWorldPosition())
            v = RunSnapHandlers(inst, self, buffaction, pt)
            if v ~= nil then
                self._ec_snappoint = v
                if buffaction.SetActionPoint then
                    buffaction:SetActionPoint(v)
                end
            end
        end
        if v == nil then
            return _DoAction(self, buffaction, spellbook, ...)
        end
        -- pcall 保证异常时清理 snappos（残留会影响后续行走预测），并透传全部返回值
        local results = { pcall(_DoAction, self, buffaction, spellbook, ...) }
        self._ec_snappoint = nil
        if not results[1] then
            error(results[2], 2)
        end
        return unpack_fn(results, 2)
    end
end

-- 空格 / CONTROL_ACTION：DoActionButton 直接 locomotor:PushAction（主机）
-- 或 RemoteActionButton（客机），不经过 DoAction，必须单独安检。
local function InstallActionButtonHooks(pc, inst)
    if pc == nil or not HasAnyActionBlocker(inst) then return end
    if pc._ec_actionbutton_hooked then return end
    pc._ec_actionbutton_hooked = true

    local _GetActionButtonAction = pc.GetActionButtonAction
    pc.GetActionButtonAction = function(self, force_target, ...)
        local act = _GetActionButtonAction(self, force_target, ...)
        if act ~= nil and RunActionBlockers(inst, self, {
            source = "button", buffaction = act,
        }) then
            return nil
        end
        return act
    end
end

-- 注册屏蔽器后把各安检点补装到当前 playercontroller（各自幂等）。
-- InstallClickRPC 必须在此一起装：只注册屏蔽器、没注册通知处理器时，
-- 绕过 DoAction 的点击 RPC 否则无人可拦。
local function InstallBlockerHooks(pc, inst)
    InstallDoActionHooks(pc, inst)
    InstallActionButtonHooks(pc, inst)
    InstallClickRPC()
end

local function InstallBlockerHooksForPlayer(inst)
    if inst == nil or inst.components == nil then return end
    InstallBlockerHooks(inst.components.playercontroller, inst)
end

--- 注册通用动作屏蔽器
--- @param fn function(ctx) -> true 屏蔽 / nil 放行
function ActionUtil:RegisterActionBlocker(inst, priority, fn)
    if inst == nil then
        PushUnique(globalActionBlockers, priority, fn)
        InstallBlockerHooksForPlayer(ThePlayer)
        return
    end
    InsertSorted(GetRegistry(inst).blockers, priority, fn)
    InstallBlockerHooksForPlayer(inst)
end

--- 精准屏蔽某一个动作（规则写在代码里，不新增 HUD 编辑列表）
--- @param opts enabled boolean|function(ctx)  实时求值，开关即时生效
---             sources string|table         只对指定来源生效，如 {"button"}；省略 = 所有路径
---             right boolean
---             target_prefab string|table
---             target_tag string|table
---             target_match function(target)
---             invobject_prefab string|table
---             priority number
function ActionUtil:BlockAction(inst, action_id, opts)
    opts = opts or {}
    local spec = {
        action_id        = type(action_id) == "table" and action_id.id or action_id,
        enabled          = opts.enabled,
        sources          = opts.sources,
        right            = opts.right,
        target_prefab    = opts.target_prefab,
        target_tag       = opts.target_tag,
        target_match     = opts.target_match,
        invobject_prefab = opts.invobject_prefab,
    }
    if inst == nil then
        InsertSpec(globalActionBlockers, opts.priority, spec)
        InstallBlockerHooksForPlayer(ThePlayer)
    else
        -- 与 RegisterActionBlocker 共用一张列表，靠「有 spec / 有 fn」区分
        InsertSpec(GetRegistry(inst).blockers, opts.priority, spec)
        InstallBlockerHooksForPlayer(inst)
    end
    return spec
end

--- 该动作在给定上下文中是否会被屏蔽（hover 等只读查询用；source 给 "hover" 不会触发计数）
function ActionUtil:IsActionBlockedFor(inst, ctx)
    local pc = inst ~= nil and inst.components ~= nil and inst.components.playercontroller or nil
    return RunActionBlockers(inst, pc, ctx)
end

-- =============================================
-- [9] 通道 A：左右键点击
-- 契约 fn(self, act, down) -> "consume"|"stop"|nil
--   "consume" = 软吞：跳过原始点击，但其余处理器继续
--   "stop"    = 硬吞：跳过原始点击且不再执行后续处理器
--   不返回    = 原点击照常执行
-- 处理器只在常规世界点击时运行：框架复刻官方 OnLeft/RightClick 的早期退出
-- （非鼠标 / 抬起 / AOE 瞄准 / 未启用 / 悬停 HUD / 建造放置模式）。
-- =============================================

local function MakeClickWrapper(handlers, pc, which)
    local _orig = (which == "lmb") and pc.OnLeftClick or pc.OnRightClick
    local getActionName = (which == "lmb") and "GetLeftMouseAction" or "GetRightMouseAction"
    return function(self, down, ...)
        -- 与官方 OnLeftClick/OnRightClick（playercontroller.lua:4648 / 4943）保持一致的早期退出
        if not self:UsingMouse()
            or not down
            or self:IsAOETargeting()
            or not self:IsEnabled()
            or (TheInput ~= nil and TheInput:GetHUDEntityUnderMouse() ~= nil)
            or self.placer_recipe ~= nil then
            return _orig(self, down, ...)
        end
        -- 动态取动作，始终反映最新的 GetLeft/RightMouseAction 覆写（如 telepoof 的禁用隐藏）
        local act = self[getActionName](self)
        local consumed = false
        for _, h in ipairs(handlers) do
            local r = h.fn(self, act, down)
            if r == "stop" then
                consumed = true
                break
            elseif r == "consume" then
                consumed = true
            end
        end
        if consumed then return end
        return _orig(self, down, ...)
    end
end

local function InstallClickHandlers(pc, inst)
    if pc == nil then return end
    local reg = inst ~= nil and registries[inst] or nil
    if reg == nil then return end
    if not pc._ec_click_lmb and #reg.lmb > 0 then
        pc._ec_click_lmb = true
        pc.OnLeftClick = MakeClickWrapper(reg.lmb, pc, "lmb")
    end
    if not pc._ec_click_rmb and #reg.rmb > 0 then
        pc._ec_click_rmb = true
        pc.OnRightClick = MakeClickWrapper(reg.rmb, pc, "rmb")
    end
end

function ActionUtil:RegisterLeftClickHandler(inst, priority, fn)
    RequireInstance(inst, "RegisterLeftClickHandler")
    InsertSorted(GetRegistry(inst).lmb, priority, fn)
    InstallClickHandlers(inst.components and inst.components.playercontroller, inst)
end

function ActionUtil:RegisterRightClickHandler(inst, priority, fn)
    RequireInstance(inst, "RegisterRightClickHandler")
    InsertSorted(GetRegistry(inst).rmb, priority, fn)
    InstallClickHandlers(inst.components and inst.components.playercontroller, inst)
end

-- =============================================
-- [10] 通道 B：物品栏格子的使用/检查接管
-- 格子操作由 widget 直接处理，不经 OnControl：
--   右键 → InvSlot:UseItem → inventory:UseItemFromInvTile（invslot.lua:400 / replica:482）
--   检查 → InvSlot:Inspect → inventory:InspectItemFromInvTile（invslot.lua:409 / replica:522）
-- 契约 fn(item, kind) -> true 已接管；kind = "use" | "inspect"
-- =============================================

local globalInvItemHandlers = {}
local globalInvActionsHandlers = {}

local function RunInventoryItemHandlers(inst, item, kind)
    local reg = inst ~= nil and registries[inst] or nil
    if reg ~= nil then
        for _, h in ipairs(reg.invitem) do
            if h.fn(item, kind) then return true end
        end
    end
    for _, h in ipairs(globalInvItemHandlers) do
        if h.fn(item, kind) then return true end
    end
    return false
end

-- 无处理器时也先装：后续注册即可生效
local function InstallInventoryItemHooks(inst)
    local invrep = inst and inst.replica and inst.replica.inventory
    if invrep == nil then return end
    if not invrep._ec_use_hooked then
        invrep._ec_use_hooked = true
        local orig = invrep.UseItemFromInvTile
        invrep.UseItemFromInvTile = function(self, item)
            if RunInventoryItemHandlers(inst, item, "use") then return end
            return orig(self, item)
        end
    end
    if not invrep._ec_inspect_hooked then
        invrep._ec_inspect_hooked = true
        local orig = invrep.InspectItemFromInvTile
        invrep.InspectItemFromInvTile = function(self, item)
            if RunInventoryItemHandlers(inst, item, "inspect") then return end
            return orig(self, item)
        end
    end
end

--- @param fn function(item, kind) -> true 接管；false = 只做前置准备，动作交回官方链路
function ActionUtil:RegisterInventoryItemHandler(inst, priority, fn)
    if inst == nil then
        PushUnique(globalInvItemHandlers, priority, fn)
        InstallInventoryItemHooks(ThePlayer)
        return
    end
    InsertSorted(GetRegistry(inst).invitem, priority, fn)
    InstallInventoryItemHooks(inst)
end

-- =============================================
-- [11] 通道 C / C2 / D2：动作列表修饰
-- C  GetInventoryActions(item)               空手时格子的悬停提示与右键点击
-- C2 GetUseItemActions(target, useitem, right) 手持物对格子物品使用
-- D2 GetLeft/RightClickActions(position, target) 世界目标的左右键候选
-- 契约 fn(actions, ...) -> actions|nil（nil = 不改）
-- =============================================

local function HasAnyInvActionsHandler(inst)
    if #globalInvActionsHandlers > 0 then return true end
    local reg = inst ~= nil and registries[inst] or nil
    return reg ~= nil and #reg.invactions > 0
end

-- 服务端也必须装：服务端要用修饰结果算 actions[1] 校验动作码
-- （inventory.lua:2295），两端结果不一致会静默失败。
local function InstallInventoryActionsHook(inst, picker)
    picker = picker or (inst and inst.components and inst.components.playeractionpicker)
    if picker == nil then return end
    InstallListHook(picker, "GetInventoryActions", "_ec_invactions_hooked",
        function(actions, self, item, ...)
            if actions == nil then return nil end
            local owner = self.inst
            local reg = inst ~= nil and registries[inst] or nil
            if reg ~= nil then
                actions = DispatchList(reg.invactions, actions, item, owner)
            end
            return DispatchList(globalInvActionsHandlers, actions, item, owner)
        end)
end

--- @param fn function(actions, item, owner) -> actions|nil
function ActionUtil:RegisterInventoryActionsModifier(inst, priority, fn)
    if inst == nil then
        PushUnique(globalInvActionsHandlers, priority, fn)
        InstallInventoryActionsHook(ThePlayer)
        return
    end
    InsertSorted(GetRegistry(inst).invactions, priority, fn)
    InstallInventoryActionsHook(inst)
end

-- 本通道只在客户端安装。动作只要前置处理器先戴好勋章，服务端重算时条件自然成立；
-- 若最终不一致，服务端只是不执行，不会崩。
local function InstallUseItemActionsHook(inst, picker)
    picker = picker or (inst and inst.components and inst.components.playeractionpicker)
    if picker == nil then return end
    InstallListHook(picker, "GetUseItemActions", "_ec_useitemactions_hooked",
        function(actions, self, target, useitem, right, ...)
            if actions == nil then return nil end
            local reg = inst ~= nil and registries[inst] or nil
            if reg == nil then return actions end
            return DispatchList(reg.useitemactions, actions, target, useitem, right, self.inst)
        end)
end

local function HasAnyUseItemActionsHandler(inst)
    local reg = inst ~= nil and registries[inst] or nil
    return reg ~= nil and #reg.useitemactions > 0
end

--- @param fn function(actions, target, useitem, right, owner) -> actions|nil
function ActionUtil:RegisterUseItemActionsModifier(inst, priority, fn)
    RequireInstance(inst, "RegisterUseItemActionsModifier")
    InsertSorted(GetRegistry(inst).useitemactions, priority, fn)
    InstallUseItemActionsHook(inst)
end

-- D2 必须在候选列表层过滤：DoGetMouseActions 拿到的已是 actions[1]
-- （playeractionpicker.lua:525-526），选中后再置 nil 会连带丢掉同键次选
-- （手持锤子右键便携厨具 = 首选 HAMMER、次选"打开"）。
local function InstallClickActionsFilter(pap, inst)
    if pap == nil then return end
    local reg = inst ~= nil and registries[inst] or nil
    if reg == nil or #reg.clickactions == 0 then return end

    local function Filter(actions, self, kind, position, target)
        local r = inst ~= nil and registries[inst] or nil
        if r == nil then return actions end
        return DispatchList(r.clickactions, actions, kind, position, target, self.inst)
    end

    InstallListHook(pap, "GetLeftClickActions", "_ec_leftclick_actions_hooked",
        function(actions, self, position, target, ...)
            return Filter(actions, self, "lmb", position, target)
        end)
    InstallListHook(pap, "GetRightClickActions", "_ec_rightclick_actions_hooked",
        function(actions, self, position, target, ...)
            return Filter(actions, self, "rmb", position, target)
        end)
end

--- 注册候选动作列表过滤器（在 actions[1] 选出之前剔除候选，保留 picker 的自然回退）
--- @param fn function(actions, kind, position, target, owner) -> actions|nil
function ActionUtil:RegisterClickActionsFilter(inst, priority, fn)
    RequireInstance(inst, "RegisterClickActionsFilter")
    InsertSorted(GetRegistry(inst).clickactions, priority, fn)
    InstallClickActionsFilter(inst.components and inst.components.playeractionpicker, inst)
end

-- =============================================
-- [12] 通道 D：DoGetMouseActions 修改器
-- 契约 fn(self, position, target, lmb, rmb) -> lmb, rmb
-- =============================================

local function InstallMouseActionModifier(pap, inst)
    if pap == nil then return end
    local reg = inst ~= nil and registries[inst] or nil
    if reg == nil or #reg.mouse == 0 or pap._ec_mouseaction_installed then return end
    pap._ec_mouseaction_installed = true

    local orig = pap.DoGetMouseActions
    pap.DoGetMouseActions = function(self, position, target, ...)
        local lmb, rmb = orig(self, position, target, ...)
        local r = inst ~= nil and registries[inst] or nil
        if r ~= nil then
            for _, h in ipairs(r.mouse) do
                lmb, rmb = h.fn(self, position, target, lmb, rmb)
            end
        end
        return lmb, rmb
    end
end

function ActionUtil:RegisterMouseActionModifier(inst, fn)
    RequireInstance(inst, "RegisterMouseActionModifier")
    InsertSorted(GetRegistry(inst).mouse, 0, fn)
    InstallMouseActionModifier(inst.components and inst.components.playeractionpicker, inst)
end

-- =============================================
-- [13] 通道 F / G 注册入口
-- =============================================

--- @param fn function(pc, buffaction, pt) -> Vector3|nil
function ActionUtil:RegisterActionPointSnap(inst, priority, fn)
    if inst == nil then
        PushUnique(globalSnapHandlers, priority, fn)
        InstallDoActionHooks(
            ThePlayer ~= nil and ThePlayer.components ~= nil
                and ThePlayer.components.playercontroller or nil,
            ThePlayer)
        return
    end
    InsertSorted(GetRegistry(inst).snap, priority, fn)
    InstallDoActionHooks(inst.components and inst.components.playercontroller, inst)
end

--- @param fn function(pc, act) -> "block"|nil
function ActionUtil:RegisterDoActionInterceptor(inst, priority, fn)
    RequireInstance(inst, "RegisterDoActionInterceptor")
    InsertSorted(GetRegistry(inst).doaction, priority, fn)
    InstallDoActionHooks(inst.components and inst.components.playercontroller, inst)
end

--- 覆盖绕过 DoAction 直接发点击 RPC 的模组（如动作队列 / 第三方中键技能）
--- @param fn function(action_id, target)
function ActionUtil:RegisterClickRPCHandler(fn)
    InstallClickRPC()
    table.insert(clickRPCHandlers, fn)
end

-- =============================================
-- [14] 通道 I：控制前钩子（本机玩家）
-- 契约 fn(pc, control, down)（无返回值；返回 "stop" 只跳过本通道后续处理器）
--
-- 不包装 pc.OnControl：排队论在加载期用实例级包装把 OnControl 后半段（含左右键）
-- 整个吃掉，类级/更早的实例级包装都会被遮蔽。这里改骑输入事件总线
-- TheInput:AddGeneralControlHandler（input.lua:143），加载期先注册，
-- 必定先于 playercontroller 在 Activate() 里注册的监听器（playercontroller.lua:319）。
-- 代价：只能抢跑，不能否决后续处理；否决请用通道 H。
-- =============================================

local controlListenerInstalled = false

local function RunControlHandlers(pc, inst, control, down)
    local reg = inst ~= nil and registries[inst] or nil
    if reg == nil then return end
    for _, h in ipairs(reg.control) do
        if h.fn(pc, control, down) == "stop" then break end
    end
end

local function InstallControlListener()
    if controlListenerInstalled then return true end
    if TheInput == nil or TheInput.AddGeneralControlHandler == nil then return false end
    controlListenerInstalled = true
    TheInput:AddGeneralControlHandler(function(control, value)
        local inst = ThePlayer
        if inst == nil or inst.components == nil then return end
        local reg = registries[inst]
        if reg == nil or #reg.control == 0 then return end
        local pc = inst.components.playercontroller
        if pc == nil or IsPaused() or not pc:IsEnabled() then return end
        RunControlHandlers(pc, inst, control, value)
    end)
    return true
end

--- @param fn function(pc, control, down)
function ActionUtil:RegisterControlHandler(inst, priority, fn)
    RequireInstance(inst, "RegisterControlHandler")
    InsertSorted(GetRegistry(inst).control, priority, fn)
    -- 极少数情况下本文件加载时 TheInput 还没建好：退一帧再试（有次数上限）
    if not InstallControlListener() then
        local tries = inst._ec_control_listener_retries or 0
        if tries < 30 then
            inst._ec_control_listener_retries = tries + 1
            inst:DoTaskInTime(0, function()
                if InstallControlListener() then inst._ec_control_listener_retries = nil end
            end)
        end
    end
end

InstallControlListener()

-- =============================================
-- [15] 挂载点
-- 必须放在所有 local 函数之后：Lua 的 local 只对声明之后的代码可见。
-- 注册方可能早于组件就绪（如 gridalign 在 modmain 期注册全局处理器），
-- 故在组件挂载时统一补装；每个安装函数各自幂等。
-- =============================================

AddComponentPostInit("playercontroller", function(pc, inst)
    InstallClickHandlers(pc, inst)
    InstallInventoryItemHooks(inst)
    if HasAnyInvActionsHandler(inst) then
        InstallInventoryActionsHook(inst)
    end
    InstallDoActionHooks(pc, inst)
    InstallActionButtonHooks(pc, inst)
    if HasAnyActionBlocker(inst) then
        InstallClickRPC()
    end
end)

AddComponentPostInit("playeractionpicker", function(pap, inst)
    InstallInventoryItemHooks(inst)
    if HasAnyInvActionsHandler(inst) then
        InstallInventoryActionsHook(inst, pap)
    end
    if HasAnyUseItemActionsHandler(inst) then
        InstallUseItemActionsHook(inst, pap)
    end
    InstallMouseActionModifier(pap, inst)
    InstallClickActionsFilter(pap, inst)
end)

return ActionUtil