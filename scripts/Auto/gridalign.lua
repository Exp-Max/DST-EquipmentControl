-------------------------------------------------------------------------------
-- 几何对齐模块
--
-- 设计取向（极简 / 尽量交给官方）：
--   * 官方 Placer:SetBuilder 一次性调 CanStartAxisAlignedPlacementForItem 决定
--     axisalignedplacementallowedbyitem；之后每帧的可见性与切片刷新全部由官方
--     Placer:OnUpdate 自己驱动（placer.lua:432-439）。所以本模块 **不 hook OnUpdate**，
--     只把「哪些东西算可对齐」交给官方，官方就会自己显示、自己刷新。
--   * 每帧唯一的钩子是 GetAxisAlignedPlacementTransform——而且它本来就是官方每帧
--     调用的，我们只改返回值里的取整方式：除基础 1x1（cell≈一个地皮）外，其余网格
--     （含 16x16 等更小网格）一律改用顶点取整（对齐到分割线 / 网格线交点，即本模块
--     核心目的），仅 1x1 退回官方原生「格子中心」避免偏四角；
--     另保留 z 原点修正与船上原点（顶点对齐对除 1x1 外的所有网格生效，墙/整数米仍走官方 snap_to_meters）。
--   * 隐藏建造虚影 / 隐藏光标数量耐久：官方每帧都会 inst:Show()（placer.lua:541,560），
--     所以改成一次性中和 inst.Show，而不是每帧重设。
--   * 无额外美术资源、无每物品间距、无变色。
--
-- 两个网格的边界（唯一判据 = 当前左键动作，二者互斥，任何时刻只显示一个）：
--   * 官方建造网格 —— BUILD / DEPLOY（放置）：官方 placer 自带，本模块只做增强
--     （放开船、顶点取整、插 16x16 档位、隐藏虚影），绝不另起一套；
--     地皮 / 墙体这类不适用网格的交给官方自己的吸附规则（见 NonGridModes）。
--   * 我们的对齐网格 —— DROP（落点）：官方这一档压根不建网格，才需要我们补上；
--     载体仍是官方 gridplacer，所以显示出来的是同一套官方贴片。
--   建造模式下左键若被判成 DROP，官方那个照常显示（我们不再另起网格接管）。
--
-- 借鉴建筑对齐 Pro（3507292297）的三处设计：
--   1. 官方档位表「有序插入」+ 条目打标记，可精确插撤
--   2. placer hook 用 substitute / overlay 双模式包装，原生函数永远保留
--   3. 落点用「单一 snappos 源头」：先算好，再统一 SetActionPoint，
--      保证显示用与最终落点是同一个值
--   另：船上以平台中心为吸附原点（官方 placer 只处理旋转，不处理吸附原点）
-------------------------------------------------------------------------------

local MEC = GLOBAL.MOD_EQUIPMENT_CONTROL
if MEC == nil or MEC.CONFIG == nil then return end
local CONFIG = MEC.CONFIG

local GAU = require("util/gridalignutil")
MEC.GridAlignUtil = GAU   -- 挂到 MOD_EQUIPMENT_CONTROL，供其它模块复用

-- 总开关优先：关掉时所有细分开关一律视为关（含隐藏虚影这类附加项），
-- 保证「总开关一关，本模块所有改动立刻失效」，不留残留状态。
-- 所有取配置的地方都走这里，避免漏掉某一处导致关不掉。
local function OptOn(key)
    return CONFIG.GRIDALIGN_ENABLED == true and CONFIG[key] == true
end

-- 有效透明度：总开关 + 半透明开关都开时取 alpha 配置值，否则完全不透明
local function EffectiveAlpha()
    if not CONFIG.GRIDALIGN_ENABLED then return 1.0 end
    if not CONFIG.GRIDALIGN_TRANSPARENCY then return 1.0 end
    return CONFIG.GRIDALIGN_ALPHA or 0.6
end

-- 顶点模式（对齐到自身网格线交点 / 分割线）对「除基础 1x1 外的所有网格」启用：
--   · 更大的网格（单格跨越多块地皮，如 2x2/3x3 等大结构）
--   · 更小的网格（如 16x16 这类细分网格）
-- 只有基础 1x1 网格（cell≈一个地皮）退回瓦片中心，避免整张网格偏到四角、与真实地皮错位。
-- 这正是本模块的核心目的：让官方建造网格能生成在分割线上。
local function VertexEnabled(intervals)
    if not OptOn("GRIDALIGN_VERTEX") then return false end
    if intervals == nil or intervals == 0 then return false end
    local ts = GAU:GetTileScale()
    local cell = 1 / intervals
    -- 仅基础 1x1（cell≈一个地皮）退回瓦片中心；其余网格（含 16x16 小网格）都顶点对齐。
    return math.abs(cell - ts) > 1e-6
end



-- 本文件走 modimport，运行在 mod 环境，GLOBAL 可用；但一律安全取值，
-- 避免常量尚未就绪 / 版本差异导致的 nil 索引崩溃（取不到就退化成「不做扩展」）
local G         = GLOBAL
local Vector3   = G.Vector3
local ACTIONS   = G.ACTIONS or {}
local DEPLOYMODE = G.DEPLOYMODE or {}

local Placer           = require("components/placer")
local PlayerController = require("components/playercontroller")

-------------------------------------------------------------------------------
-- 包装器（仿 Pro 的 sap_sX / sap_oX 双模式）
--   substitute：有自定义实现则交给它，由它决定是否/如何调原生
--               （原生函数作为第 2 个参数传入）；没有则直接走原生
--   overlay：先无条件跑原生，再追加自定义（用于「补充」而非「替换」）
-- 自定义实现挂在类表上（Placer.ga_sXxx），实例通过类元表可见，无需逐实例设置
-------------------------------------------------------------------------------
local function WrapSubstitute(component, name)
    local original = component[name]
    if original == nil then return nil end
    local slot = "ga_s" .. name
    component[name] = function(self, ...)
        if self[slot] then
            return self[slot](self, original, ...)
        end
        return original(self, ...)
    end
    return original
end

local function WrapOverlay(component, name)
    local original = component[name]
    if original == nil then return nil end
    local slot = "ga_o" .. name
    component[name] = function(self, ...)
        local ret = original(self, ...)
        if self[slot] then
            self[slot](self, ...)
        end
        return ret
    end
    return original
end

-------------------------------------------------------------------------------
-- 「不适用网格」的放置类（按官方 placer 自带的 snap 标志 / 物品的 deploy 模式识别）
--   * 地皮：一次一格，官方按瓦片中心落子，格线没有意义
--   * 墙体：落在整数米上，放不到网格线上，网格顶点对墙没有意义
--   * 船用护舷：贴船边，同理
--   这类交给官方自己的吸附规则：统一网格既不显示，也不吸附。
-------------------------------------------------------------------------------
local NonGridModes = {
    { flag = "snap_to_tile",      mode = DEPLOYMODE.TURF },
    { flag = "snap_to_half_tile", mode = nil },
    { flag = "snap_to_meters",    mode = DEPLOYMODE.WALL },
    { flag = "snaptogrid",        mode = nil },
    { flag = "snap_to_boat_edge", mode = nil },
}

-------------------------------------------------------------------------------
-- 1. 让官方把船也当「可对齐物」——官方随后自己完成显示与刷新
--    （官方 SetBuilder 里只调一次，故这里不是每帧开销）
-------------------------------------------------------------------------------
WrapSubstitute(Placer, "CanStartAxisAlignedPlacementForItem")
Placer.ga_sCanStartAxisAlignedPlacementForItem = function(self, original, item)
    local ret = original(self, item)
    if ret or not CONFIG.GRIDALIGN_ENABLED then return ret end
    -- 船：官方 placer.lua:182 用 HasAnyTag("tile_deploy","groundtile","boatbuilder")
    -- 显式排除轴对齐，导致船下水没有网格。而船只 placer（boat_item_placer 等）的
    -- MakePlacer 参数 snap/metersnap 均为 false，即没有任何 snap 标志，
    -- 会正常落入轴对齐分支（placer.lua:431），所以这里放开即可显示并对齐。
    if item ~= nil and item:HasTag("boatbuilder") and OptOn("GRIDALIGN_BOAT") then
        return true
    end
    return ret
end

-------------------------------------------------------------------------------
-- 2. 唯一的每帧钩子：吸附取整（本来就是官方每帧调用，我们只改返回值）
--    本模块核心目的：让官方建造网格能对齐到「分割线 / 网格线交点」（顶点模式），
--    而非永远钉在瓦片中心。为此在官方「格子中心」取整基础上，除基础 1x1 外
--    （含 16x16 等更小网格）改用顶点取整 floor((x-ox)*i + 0.5)；仅 1x1 退回官方中心。
--    本钩子保留两处真正的修复：
--      · 修正官方 z 误用 worldoffsetx 的 bug（z 改用 worldoffsetz）
--      · 船上以平台中心为原点（官方只处理旋转，不处理吸附原点）
-------------------------------------------------------------------------------
WrapSubstitute(Placer, "GetAxisAlignedPlacementTransform")
Placer.ga_sGetAxisAlignedPlacementTransform = function(self, original, x, y, z, ignorescale, ...)
    local h = self.axisalignedhelpers
    if h == nil then
        return original(self, x, y, z, ignorescale, ...)
    end
    local i = h.intervals
    if i == nil or i == 0 then
        return original(self, x, y, z, ignorescale, ...)
    end

    -- 修正官方 z 误用 worldoffsetx；船上以平台中心为原点（官方只处理旋转）
    local ox, oz = nil, nil
    local px, pz = GAU:GetPlatformOrigin(x, z, self.builder)
    if px ~= nil then
        ox, oz = px, pz
    else
        ox, oz = h.worldoffsetx, h.worldoffsetz
    end

    -- 顶点对齐（生成在分割线 / 网格线交点）对所有「非基础 1x1」网格启用（含 16x16 小网格）；
    -- 仅基础 1x1 退回官方原生「格子中心」取整，避免整张网格偏到四角。
    -- 注意 ignorescale 语义（同官方 placer.lua:269-271）：为真时不除以 intervals。
    local inv = 1 / i
    local vertex = VertexEnabled(i)
    if ignorescale then
        local fx = vertex and math.floor((x - ox) * i + 0.5) or (math.floor((x - ox) * i) + 0.5)
        local fz = vertex and math.floor((z - oz) * i + 0.5) or (math.floor((z - oz) * i) + 0.5)
        return fx + ox, y, fz + oz
    end
    local gx = vertex and (math.floor((x - ox) * i + 0.5) * inv + ox)
                            or ((math.floor((x - ox) * i) + 0.5) * inv + ox)
    local gz = vertex and (math.floor((z - oz) * i + 0.5) * inv + oz)
                            or ((math.floor((z - oz) * i) + 0.5) * inv + oz)
    return gx, y, gz
end

-------------------------------------------------------------------------------
-- 3. 16x16 小网格：有序插进官方档位表，即可参与官方自带的网格切换
--    CycleAxisAlignmentValues 按「最接近当前 intervals 的档位 +1」循环，无需改切换逻辑
--    intervals = 4 => 每格 1/4 世界单位 => 一个瓦片 16x16 格
--    仿 Pro 的 AddInterval：按 data 降序（由细到粗）有序插入，并给条目打 ga_mod 标记
-------------------------------------------------------------------------------
local GRID16_INTERVALS = GAU:CellsPerTileToIntervals(16)
local GRID16_TEXT = "16x16 (0.25)"
local _grid16_injected = false

-- 档位表在调用时读取而非加载期捕获：官方可能在之后重建该表
local function GetAlignmentValues()
    local values = G.AXISALIGNMENT_VALUES
    if type(values) ~= "table" then return nil end
    return values
end

-- 有序插入：官方表为降序（2, 1, 0.5, 0.25 = 由细到粗），
-- 找到第一个比它小的项插到其前面；都不小则追加到末尾
local function InsertSorted(values, data, text)
    for _, v in ipairs(values) do
        if v.data == data then return false end   -- 已存在（可能是别模组/官方同值）
    end
    local pos = #values + 1
    for idx, v in ipairs(values) do
        if v.data < data then pos = idx break end
    end
    table.insert(values, pos, { text = text, data = data, ga_mod = true })
    return true
end

local function InjectGrid16()
    if _grid16_injected then return end
    local values = GetAlignmentValues()
    if values == nil then return end
    InsertSorted(values, GRID16_INTERVALS, GRID16_TEXT)
    _grid16_injected = true
end

local function RemoveGrid16()
    local values = GetAlignmentValues()
    if values == nil or not _grid16_injected then return end
    -- 只移除带 ga_mod 标记的自己的条目，避免误删同值的官方/其它模组档位
    for i = #values, 1, -1 do
        if values[i].ga_mod then
            table.remove(values, i)
        end
    end
    _grid16_injected = false
end

-- 可重试的注入：AXISALIGNMENT_VALUES 由 componentutil.lua 定义，
-- 若在 modmain 加载期尚未就绪，加载期那次会静默失败，故在首个 placer 创建时补做
local function TryInjectGrid16()
    if not OptOn("GRIDALIGN_GRID16") then return end
    InjectGrid16()
end
TryInjectGrid16()   -- 加载期先试一次（失败则由 placer 创建时补做）

-------------------------------------------------------------------------------
-- 4. 一次性设置（每个 placer 实例只跑一次，不是每帧）
-------------------------------------------------------------------------------
local function GetCursorWidget()
    -- 走 G.ThePlayer：mod 环境下 ThePlayer 可能尚未就绪，统一从 GLOBAL 取
    local player = G.ThePlayer
    local hud = player and player.HUD
    local controls = hud and hud.controls
    local mf = controls and controls.mousefollow
    if mf and mf.children then
        for _, child in pairs(mf.children) do return child end
    end
    return nil
end

AddComponentPostInit("placer", function(self)
    local inst = self.inst

    -- 首个 placer 创建时核心脚本必定已加载，此处补做 16x16 档位注入
    -- （加载期那次可能因 AXISALIGNMENT_VALUES 尚未就绪而失败）
    TryInjectGrid16()

    -- 隐藏建造虚影：官方每帧 inst:Show()，这里一次性把 Show 中和掉。
    -- 闭包每次读取配置（不是加载期快照），所以总开关/本开关一关，下一帧就恢复显示
    local _Show = inst.Show
    inst.Show = function(...)
        if not OptOn("GRIDALIGN_HIDEPLACER") then
            return _Show(...)
        end
    end
    if OptOn("GRIDALIGN_HIDEPLACER") then
        inst:Hide()
    end

    -- 隐藏鼠标跟随物上的耐久 / 数量；placer 移除时还原，避免影响后续物品
    local cursor = GetCursorWidget()
    local hidden = {}
    if cursor then
        if OptOn("GRIDALIGN_HIDEPERCENT") and cursor.percent then
            cursor.percent:Hide()
            hidden.percent = cursor.percent
        end
        if OptOn("GRIDALIGN_HIDEQUANTITY") and cursor.quantity then
            cursor.quantity:Hide()
            hidden.quantity = cursor.quantity
        end
    end
    if hidden.percent or hidden.quantity then
        inst:ListenForEvent("onremove", function()
            -- percent/quantity 是 Widget 而不是实体：IsValid() 是 EntityScript 的方法，
            -- Widget 上没有（直接调会报 attempt to call method 'IsValid'）。
            -- 且这些 widget 可能已被 Kill，故用 pcall 兜底还原显示。
            if hidden.percent then pcall(hidden.percent.Show, hidden.percent) end
            if hidden.quantity then pcall(hidden.quantity.Show, hidden.quantity) end
        end)
    end
end)
-- 网格透明度：官方 Placer:OnUpdate → UpdateAxisAlignedHelpers 对 axisalignedhelpers.cache
-- 中的 axisalignedplacement_outline 实体设色（红/绿 + alpha=intensity）。
-- 后处理：保留官方校验色 RGB，只将可见瓦片的 alpha 覆写为配置值。
WrapOverlay(Placer, "OnUpdate")
Placer.ga_oOnUpdate = function(self, dt)
    local alpha = EffectiveAlpha()
    if alpha >= 1.0 then return end
    local helpers = self.axisalignedhelpers
    if helpers == nil then return end
    local cache = helpers.cache
    if cache == nil then return end
    for _, v in ipairs(cache) do
        local ent = v.ent
        if ent ~= nil and ent:IsValid() then
            local r, g, b, a = ent.AnimState:GetMultColour()
            -- 仅动当前显示的格子（官方 a=1=可见，a=0=该格不亮），保留原始红/绿色
            if a > 0 and a ~= alpha then
                ent.AnimState:SetMultColour(r, g, b, alpha)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- 5. 建造 / 部署 / 丢弃 对齐
--    本模块只提供「吸附哪些动作 / 吸到哪」的决策；
--    左右键与 action 相关的包装分发一律交给 actionutil 的
--    ActionUtil:RegisterActionPointSnap 通道（与 autotool / quickdeploy / automedal
--    等模块复用同一套机制，避免各自造钩子）。
--    通道内部用单一 snappos 源头，并已处理「DoAction 不读 act.pos」这一陷阱。
-------------------------------------------------------------------------------

-- 官方当前的建造 / 部署 placer（playercontroller 里就这两个字段；我们的载体不在其中）
local function GetBuildPlacer(pc)
    local function pick(inst)
        if inst == nil or not inst:IsValid() then return nil end
        return inst.components and inst.components.placer or nil
    end
    return pick(pc.placer) or pick(pc.deployplacer)
end

-- 地皮 / 墙体这类「不适用网格」的放置（见 NonGridModes）：不参与网格吸附。
-- 只针对 BUILD / DEPLOY——那一档本来就不归我们的网格（是官方建造网格的领域），
-- 这里要挡的是吸附：否则会把墙往网格线上吸、把地皮吸离瓦片中心。
-- 单纯丢弃（DROP）是个普通落点，照常走网格，不受这条影响。
local function IsNonGridPlacement(pc, buffaction)
    local act = buffaction ~= nil and buffaction.action or nil
    if act ~= ACTIONS.BUILD and act ~= ACTIONS.DEPLOY then return false end
    local q = GetBuildPlacer(pc)
    local item = buffaction ~= nil and buffaction.invobject or nil
    local inventoryitem = item ~= nil and item.replica and item.replica.inventoryitem or nil
    local deploymode = inventoryitem ~= nil and inventoryitem:GetDeployMode() or DEPLOYMODE.NONE
    for _, line in ipairs(NonGridModes) do
        if (q ~= nil and q[line.flag] == true)
            or (line.mode ~= nil and line.mode == deploymode)
        then
            return true
        end
    end
    return false
end

local SNAP_ACTIONS = {}
local function BuildSnapActionSet()
    SNAP_ACTIONS = {}
    if OptOn("GRIDALIGN_DROP")   and ACTIONS.DROP   then SNAP_ACTIONS[ACTIONS.DROP]   = true end
    if OptOn("GRIDALIGN_DEPLOY") and ACTIONS.DEPLOY then SNAP_ACTIONS[ACTIONS.DEPLOY] = true end
    if OptOn("GRIDALIGN_BUILD")  and ACTIONS.BUILD  then SNAP_ACTIONS[ACTIONS.BUILD]  = true end
end
BuildSnapActionSet()

-- 本模块只提供「吸附决策」，包装与分发一律走 actionutil 的通道
-- （与 autotool / quickdeploy / automedal 等模块的复用方式一致）
local ActionUtil = require "util/actionutil"

ActionUtil:RegisterActionPointSnap(nil, 0, function(pc, buffaction, pt)
    if not CONFIG.GRIDALIGN_ENABLED or pt == nil then return nil end
    -- 地皮 / 墙体这类有自己的吸附规则，网格不适用（理由见 NonGridModes）
    if IsNonGridPlacement(pc, buffaction) then return nil end
    if buffaction ~= nil then
        -- 鼠标点击路径：只吸附配置的动作
        if not SNAP_ACTIONS[buffaction.action] then return nil end
    elseif not OptOn("GRIDALIGN_DROP") then
        -- 快捷丢弃路径（无 BufferedAction）
        return nil
    end
    -- 在船上用船中心当原点，否则用世界原点
    -- 顶点对齐（>1x1 生成在分割线上）由 VertexEnabled 决定；1x1 退回瓦片中心
    -- （与真实地皮分界线一致），墙/整数米仍走官方 snap_to_meters 原生处理。
    local x, z = GAU:SnapWorldPlatform(pt.x, pt.z, VertexEnabled(GAU:GetIntervals()), pc and pc.inst)
    if Vector3 == nil then return nil end
    return Vector3(x, 0, z)
end)

-------------------------------------------------------------------------------
-- 6. 网格视觉：只保留「真实地皮分界线」（见 6b）
--    早期的「跟随鼠标的统一网格」(grid_carrier) 已移除——它和真实地皮分界线
--    同时出现、且要接管官方建造网格，体验拧巴。现在：
--      · 丢弃/放置的吸附仍由第 5 节的 RegisterActionPointSnap 通道负责
--        （落点吸附到瓦片中心，与真实地皮分界线一致）；
--      · 唯一的网格视觉就是 6b 的 tile_outline：钉死在真实地皮上、不跟随鼠标自由飘，
--        且只由总开关决定显隐（见 OnUpdate），与丢弃/建造/部署都无关。
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- 6b. 独立的地皮方框（真实地皮分界线）
--     直接用官方现成 prefab「tile_outline」（gridplacer.lua 注册）：它只是画地皮
--     方格的纯视觉实体，没有 placer 组件、没有轴对齐/吸附逻辑，比自起 gridplacer
--     简得多。每帧在 OnUpdate 里钉到 GetTileCenterPoint(光标所在格)，
--     画的就是真实地皮四条边，不跟随鼠标自由飘。
--     显隐只由总开关决定（见 OnUpdate：总开关开则每帧钉到光标格、关则隐藏），
--     与丢弃/建造/部署都无关，是常驻的真实地皮参考线。
-------------------------------------------------------------------------------
local tile_outline = nil   -- 真实地皮分界线实体（官方 tile_outline prefab）

local function GetTileOutline()
    if tile_outline ~= nil and tile_outline:IsValid() then return tile_outline end
    tile_outline = nil
    local inst = G.SpawnPrefab("tile_outline")
    if inst == nil then return nil end
    tile_outline = inst
    return inst
end

local function DestroyTileOutline()
    if tile_outline ~= nil then
        if tile_outline:IsValid() then tile_outline:Remove() end
        tile_outline = nil
    end
end

-- overlay 模式：先跑官方 OnUpdate，再处理「真实地皮分界线」
--   唯一的网格视觉就是 tile_outline（6b）：钉死在真实地皮上、不跟随鼠标自由飘，
--   总开关开 + 玩家处于建造/部署/丢弃模式（LMBaction 匹配或持有 placer/deployplacer）时显示。
WrapOverlay(PlayerController, "OnUpdate")
PlayerController.ga_oOnUpdate = function(self)
    if G.ThePlayer == nil then
        DestroyTileOutline()   -- 玩家离场，销毁避免实体残留
        return
    end
    -- 真实地皮分界线（参考框）：总开关开 + 左键动作是建造/部署/丢弃，或玩家正持有建造虚影时显示。
    -- 它画出真实地皮分割线，配合官方建造网格的顶点对齐（见 GetAxisAlignedPlacementTransform），
    -- 让玩家能看清「官方建造网格生成在分割线上」的位置。
    local show = false
    if CONFIG.GRIDALIGN_ENABLED then
        local act = self.LMBaction and self.LMBaction.action
        show = act == ACTIONS.BUILD or act == ACTIONS.DEPLOY or act == ACTIONS.DROP
            or self.placer ~= nil or self.deployplacer ~= nil
    end
    if show then
        local o = GetTileOutline()
        if o ~= nil and o:IsValid() then
            o:Show()
            local p = G.TheInput:GetWorldPosition()
            local x, y, z = G.TheWorld.Map:GetTileCenterPoint(p.x, p.y, p.z)
            o.Transform:SetPosition(x, y, z)
            -- 透明度：每帧检查并应用（配置可能运行时被改写）
            local alpha = EffectiveAlpha()
            if alpha < 1.0 then
                o.AnimState:SetMultColour(1, 1, 1, alpha)
            end
        end
    elseif tile_outline ~= nil and tile_outline:IsValid() then
        tile_outline:Hide()
    end
end

-------------------------------------------------------------------------------
-- 7. 供 confighud 实时开关刷新（重建动作集 / 插撤官方档位）
-------------------------------------------------------------------------------
MEC.RefreshGridAlign = function()
    BuildSnapActionSet()
    -- 档位表是全局的：总开关关掉也必须撤掉自己那条，否则官方档位循环里还留着
    if OptOn("GRIDALIGN_GRID16") then
        InjectGrid16()
    else
        RemoveGrid16()
    end
end