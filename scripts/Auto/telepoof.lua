--============================================================================
-- 传送（telepoof）— 屏蔽传送动作 / 双击才跳 / 悬停提示
--============================================================================
-- 控制对象：ACTIONS.BLINK（法杖传送 + 沃拓克斯灵魂跳跃）
--
-- 实现方式：注册 actionutil 的**动作屏蔽器**（通道 H），而不是右键点击处理器。
--   原因（原 bug 的根因）：右键点击处理器只挂在 pc.OnRightClick 上，而排队论
--   (2873533916) 的实例级 OnControl 在按住队列键时直接 return，
--   OnRightClick 根本不执行 → 拦截永不触发。屏蔽器挂在
--     · DoAction           普通点击 / 排队论主机端 SendAction / 客机端 DoAction
--                           / 空格以外的动作键 / 各模块自调的 DoAction
--     · GetActionButtonAction  空格键（DoActionButton 不经 DoAction）
--     · 点击 RPC           绕过 DoAction 直接发 RPC 的模组（Exp_Max 的"中键灵魂跳跃"
--                          就是这条：SendRPCToServer(RPC.LeftClick, ACTIONS.BLINK.code)）
--   三条派发路径上，策略只有这一份，各路径行为不会互相不一致。
--   ⚠ 第三条（rpc 层）**也计数**：那条路径没有对应的 press，不计数就等于永久放行。
--
-- 配置一律**实时**读 MOD_EQUIPMENT_CONTROL.CONFIG（confighud 运行时改写后立即生效），
-- 只有双击间隔读 modinfo —— 那是开局设定，运行中不可改。
--============================================================================

local ConfigUtil = require "util/configutil"
local KeybindService  = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE
local ActionUtil  = require "util/actionutil"

local CONFIG = MOD_EQUIPMENT_CONTROL.CONFIG

-- 剩余点击数（上限 2）：2 = 还需要点一下才跳（本次按下被吞）。0 = 本次放行。
-- 只在真实按下（ctx.source == "press"）时变化，且每次递减都会安排一次回补。
local TELEPOOF_CLICKS = 2

local function IsDisabled()    return CONFIG.TELEPOOF_DISABLED == true end
local function IsWortoxBlink() return CONFIG.TELEPOOF_WORTOX == true end  -- 灵魂跳跃（沃拓克斯）是否一并接管
local function IsHoverHidden() return CONFIG.TELEPOOF_HOVER == true end   -- 禁用时是否连悬停提示一起隐藏

--- 双击间隔；返回 nil/false 表示"不需要双击"（配置里选了"禁用"档）
--- 走 modinfo 而非 CONFIG：这是开局选项，运行中不会变，没有实时求值的意义
local function DoubleClickInterval()
    local v = GetModConfigData("TELEPOOF_DOUBLECLICK", MOD_EQUIPMENT_CONTROL.MODNAME)
    if v and type(v) ~= "number" then return .5 end
    return v
end

--============================================================================
-- 悬停文本：STRINGS.ACTIONS.BLINK 的 ref 见 strings.lua:752-757
--   GENERIC  = 法杖传送
--   SOUL     = 灵魂跳跃（沃拓克斯）
--   FREESOUL = 灵魂回响（免费跳跃，actions.lua:3509 在 _freesoulhop_counter > 0 时返回它）
-- 原实现把 SOUL 项在加载期就按 TELEPOOF_WORTOX 定死了，confighud 打开后提示不刷新；
-- 这里改为按实时开关决定哪些 ref 参与。
--============================================================================
local BLINK_DISPLAY_REFS = { "GENERIC", "SOUL", "FREESOUL" }
local blinkOriginals = {}  -- ref -> 原始文本（首次使用时抓取，避免后缀越叠越长；false = 该 ref 不存在）

local function OriginalBlinkText(ref)
    local t = blinkOriginals[ref]
    if t == nil then
        t = STRINGS.ACTIONS.BLINK[ref] or false
        blinkOriginals[ref] = t
    end
    return t or nil
end

--- 把悬停文本刷成与当前配置一致（禁用 → "(Disabled)"；双击模式 → 剩余点击数）
--- 单一渲染入口：不管配置从哪个入口改的（键位 / confighud），都只需调它一次
local function RefreshBlinkText()
    local disabled = IsDisabled()
    local interval = DoubleClickInterval()
    for _, ref in ipairs(BLINK_DISPLAY_REFS) do
        local original = OriginalBlinkText(ref)
        if original ~= nil then
            if ref ~= "GENERIC" and not IsWortoxBlink() then
                -- 不接管灵魂跳跃时不要留下旧后缀
                STRINGS.ACTIONS.BLINK[ref] = original
            elseif disabled then
                STRINGS.ACTIONS.BLINK[ref] = original .. " (Disabled)"
            elseif interval then
                STRINGS.ACTIONS.BLINK[ref] = string.format("%s (%s)", original, TELEPOOF_CLICKS)
            else
                STRINGS.ACTIONS.BLINK[ref] = original
            end
        end
    end
end

--============================================================================
-- 动作屏蔽器
--============================================================================

--- 灵魂跳跃识别：BLINK.strfn（actions.lua:3509-3511）
---   无 invobject 且 doer 带 soulstealer 标签时返回 "SOUL"，免费跳跃计数 > 0 时返回 "FREESOUL"，
---   法杖传送返回 nil。
--- 拿不到 buffaction（点击 RPC 层只给了 action_id）时返回 nil = 无法区分，按法杖传送对待。
--- @return string|nil
local function BlinkRef(ctx)
    local action, ba = ctx.action, ctx.buffaction
    if action == nil or ba == nil or type(action.strfn) ~= "function" then return nil end
    local ok, ref = pcall(action.strfn, ba)
    return ok and ref or nil
end

local function IsSoulRef(ref)
    return ref == "SOUL" or ref == "FREESOUL"
end

--- 动作判定：只认 BLINK，且**一律用 id 字符串**（通道 H 约定：ctx.action 可能是裸表或副本，
--- 对象相等（ctx.action ~= ACTIONS.BLINK）会漏判 —— 灵魂跳跃一旦走到那条分支就整段失效）。
local function IsBlink(ctx)
    local id = ctx.action_id
    if id == nil then
        local a = ctx.action
        if type(a) == "table" then id = a.id end
    end
    return id == "BLINK"
end

--- 计数的来源白名单（语义见 actionutil 文件头通道 H）。
---   "press" 真实按下：DoAction 系（鼠标左右键 / 排队论 / 各模块自调 DoAction）
---   "rpc"   绕过 DoAction 直接发的点击 RPC（Exp_Max 的"中键灵魂跳跃"就是这条）
---           —— 它没有对应的 press，这里不计数就等于永久无条件放行；
---           而 press 已计过数、由 preview_cb 发出的那种 RPC，到达 rpc 层时计数已归零，
---           天然不会被重复扣（BlockBlink 只在计数 > 0 时才递减）。
--- "button"（GetActionButtonAction 被反复轮询）与 "hover"（只读）一律不计数。
local function IsCountingSource(source)
    return source == "press" or source == "rpc"
end

--- 屏蔽器：BLINK 的精准拦截
--- ctx.source 的用法（关键，通道 H 的约定）见上方 IsCountingSource
local function BlockBlink(ctx)
    if not IsBlink(ctx) then return nil end

    -- 禁用：所有派发路径一律屏蔽（最高优先级，含灵魂跳跃）
    if IsDisabled() then return true end

    -- 不接管沃拓克斯时只控法杖传送（拿不到 ref —— 如 rpc 层 —— 时按法杖处理）
    if not IsWortoxBlink() and IsSoulRef(BlinkRef(ctx)) then return nil end

    -- 双击模式：只有"真实派发"的来源参与计数；单击（计数未归零）直接放行
    local interval = DoubleClickInterval()
    if not (interval and IsCountingSource(ctx.source)) then return nil end

    local inst = ctx.pc ~= nil and ctx.pc.inst or nil
    if TELEPOOF_CLICKS > 0 and inst ~= nil then
        TELEPOOF_CLICKS = TELEPOOF_CLICKS - 1
        RefreshBlinkText()
        -- 回补：间隔内没有第二下就恢复成"需要双击"
        inst:DoTaskInTime(interval, function()
            if TELEPOOF_CLICKS < 2 then
                TELEPOOF_CLICKS = TELEPOOF_CLICKS + 1
                RefreshBlinkText()
            end
        end)
    end
    return TELEPOOF_CLICKS > 0
end

--============================================================================
-- 悬停提示的隐藏：直接问屏蔽器，保证"显示"与"实际拦截"同源
-- （source="hover" 是只读查询，不会消耗双击计数）
--============================================================================
local function InstallHoverOverride(pc)
    if pc == nil or pc._ec_telepoof_hover_hooked then return end
    pc._ec_telepoof_hover_hooked = true

    local _GetRightMouseAction = pc.GetRightMouseAction
    pc.GetRightMouseAction = function(self, ...)
        local act = _GetRightMouseAction(self, ...)
        if act ~= nil and IsHoverHidden()
            and ActionUtil:IsActionBlockedFor(self.inst, {
                source = "hover", buffaction = act, right = true,
            }) then
            return nil  -- 隐藏"右键: 传送"提示
        end
        return act
    end
end

local function Init()
    local PlayerController = ThePlayer and ThePlayer.components.playercontroller

    -- 文本刷新放在守卫之前：重复进入世界时也要与当前配置对齐
    RefreshBlinkText()

    if not PlayerController then
        return
    end

    -- 幂等守卫：同一 playercontroller 实例只注册一次，避免重复叠加
    if PlayerController._ec_telepoof_hooked then
        return
    end
    PlayerController._ec_telepoof_hooked = true

    ActionUtil:RegisterActionBlocker(ThePlayer, 0, BlockBlink)

    InstallHoverOverride(PlayerController)
end

KeybindService:AddKey("TOGGLE_TELEPOOF", function()
    -- DoToggle 的语义：传入"当前状态"，返回/提示"翻转后的状态"
    local next_disabled = ConfigUtil:DoToggle(
        MOD_EQUIPMENT_CONTROL.STRINGS.TOGGLE.TELEPOOF, not IsDisabled())
    -- 状态只有 CONFIG 一份：confighud「传送选项」读的也是它，两个入口天然同源
    CONFIG.TELEPOOF_DISABLED = next_disabled
    RefreshBlinkText()
end)

-- 暴露传送禁用状态，供 confighud 的"切换传送"按钮显示 开/关
MOD_EQUIPMENT_CONTROL.IsTelepoofDisabled = function() return IsDisabled() end
-- 供 confighud 在开关变化后刷新悬停文本（与键位入口共用同一个渲染函数）
MOD_EQUIPMENT_CONTROL.RefreshTelepoofDisplay = RefreshBlinkText

return Init