-- 滤镜消除：开关控制游戏各类屏幕覆盖层和后处理效果
-- 参考: Overlays Disabler (368686576) 和 ColourCube Control (3551241765)
--
-- 【实时开关】每个滤镜的消除状态由运行时表 MOD_EQUIPMENT_CONTROL.FILTER_STATE[key] 驱动：
--   key=true  => 消除（压制）该滤镜；key=false => 不消除，恢复该效果。
--   UI（confighud 的“滤镜消除”子项 toggle）实时改这张表 => 即时生效。
--   默认全部 true（消除），进入游戏即移除所有画面滤镜/覆盖层（干净屏幕）；可逐项 toggle 恢复。
--   API：MOD_EQUIPMENT_CONTROL.IsFilterRemoved(key) / SetFilterRemoved(key, removed)。
--   （modinfo 里的 FILTER_XXX 配置项保留但不再读取，改由本运行时表 + UI 实时控制。）
--
-- 【两类 Hook】游戏把滤镜推给画面的方式分两种，对应两套实时机制（详见各节注释）：
--   · 每帧型（第三/五节）：OnUpdate 里持续写显示状态 => 每帧读表即可，天然实时。
--   · 边沿型（第二/四/六/七节）：只在事件发生时被调一次（SetLunacyEnabled、ToggleGoggles…）
--      => 光读表不够，拨开关后没人再调就永远不刷新。这类走「重放」：记下最后一次调用参数，
--         SetFilterRemoved 翻转 key 时用原参数把 wrapper 重跑一遍 => 立刻生效。
--
-- 【注册时机】所有 AddClassPostConstruct / AddGamePostInit 一律顶层注册（modimport 加载）：
--   HUD（screens/playerhud、widgets/*over 等）在 prefabs/player_common.lua 的 ActivateHUD 就已构建，
--   而 playeractivated 在其后 —— 放进 Init()/AutoInits 注册必然挂不上（playerhud 只建一次）。

local MODNAME = MOD_EQUIPMENT_CONTROL.MODNAME
local IDENTITY_CC = "images/colour_cubes/identity_colourcube.tex"

local NIGHTVISION_CC_FILES = {
    ["mole_vision_off_cc.tex"] = true,
    ["mole_vision_on_cc.tex"] = true,
    ["nightvision_fruit_cc.tex"] = true,
}

--------------------------------------------------------------------------------
-- 季节 / 时段 / 满月 / 洞穴色块：色块文件名（去 .tex）=> 它归属的开关
--
-- 官方把「季节 + 时段」直接编码进文件名（day05=秋白天、dusk03=秋黄昏、snow_cc=冬白天…），
-- 所以不必去问世界状态，看文件名就能判断这张色块该不该被换掉。
-- 一张色块可以同时属于季节与时段两组（snowdusk_cc 既是冬季也是黄昏），
-- 任一组开关打开就替换成 identity。
--------------------------------------------------------------------------------
local CC_FILE_KEYS = {
    day05_cc        = { "FILTER_SEASON_AUTUMN" },
    dusk03_cc       = { "FILTER_SEASON_AUTUMN", "FILTER_PHASE_DUSK" },
    night03_cc      = { "FILTER_SEASON_AUTUMN", "FILTER_PHASE_NIGHT" },

    snow_cc         = { "FILTER_SEASON_WINTER" },
    snowdusk_cc     = { "FILTER_SEASON_WINTER", "FILTER_PHASE_DUSK" },
    night04_cc      = { "FILTER_SEASON_WINTER", "FILTER_PHASE_NIGHT" },

    spring_day_cc   = { "FILTER_SEASON_SPRING" },
    spring_dusk_cc  = { "FILTER_SEASON_SPRING", "FILTER_PHASE_DUSK" },
    spring_night_cc = { "FILTER_SEASON_SPRING", "FILTER_PHASE_NIGHT" },

    summer_day_cc   = { "FILTER_SEASON_SUMMER" },
    summer_dusk_cc  = { "FILTER_SEASON_SUMMER", "FILTER_PHASE_DUSK" },
    summer_night_cc = { "FILTER_SEASON_SUMMER", "FILTER_PHASE_NIGHT" },

    purple_moon_cc  = { "FILTER_FULLMOON" },

    ruins_dark_cc   = { "FILTER_CAVE_NIGHTMARE" },
    ruins_dim_cc    = { "FILTER_CAVE_NIGHTMARE" },
    ruins_light_cc  = { "FILTER_CAVE_NIGHTMARE" },
    caves_default   = { "FILTER_CAVE_NIGHTMARE" },

    -- 非常规色块：幽灵视野（playervision 的 GHOSTVISION_COLOURCUBES）、
    -- 停电全黑（forest/player_common）、洞穴真菌区与天坑区（cave）
    ghost_cc        = { "FILTER_GHOST" },
    blackout_cc     = { "FILTER_BLACKOUT" },
    fungus_cc       = { "FILTER_CAVE_FUNGUS" },
    sinkhole_cc     = { "FILTER_CAVE_SINKHOLE" },
    -- 海狸视野色块：与 beaverOL 那个 widget 同归 FILTER_BEAVER
    beaver_vision_cc= { "FILTER_BEAVER" },

    -- 活动模式专用（熔炉 / 暴食），正式模式用不到，不设开关
    -- lavaarena2_cc、quagmire_cc
}

--------------------------------------------------------------------------------
-- 运行时消除状态表（key=FILTER_XXX，value=bool；默认全部 true => 消除）
--------------------------------------------------------------------------------
local FILTER_STATE = {}
MOD_EQUIPMENT_CONTROL.FILTER_STATE = FILTER_STATE

-- 默认行为：进入游戏即移除（消除）全部画面滤镜/覆盖层，得到干净屏幕。
-- 运行时仍可逐项 toggle 关闭某条滤镜的消除（恢复对应效果）。
-- 清单在 util/config.lua 的 Config.FILTER_KEYS（唯一来源）；confighud 的 FILTER_RAW 只补 UI 文案。
-- 初值从 CONFIG 恢复（默认 true，见 config.lua），因此 HUD 里的逐项开关可持久化。
local ALL_FILTER_KEYS = require("util/config").FILTER_KEYS
for _, k in ipairs(ALL_FILTER_KEYS) do
    FILTER_STATE[k] = MOD_EQUIPMENT_CONTROL.CONFIG[k]
end

function MOD_EQUIPMENT_CONTROL.IsFilterRemoved(key)
    return FILTER_STATE[key] == true
end

--------------------------------------------------------------------------------
-- 色彩立方（三层色块）参数缓存 + 统一重放
--
-- 官方 colourcube 组件维护 index 0/1/2 三层色块，分别由
-- PostProcessor:SetColourCubeData / SetColourCubeLerp 推送：
--   0 = ambient（季节/黄昏/夜晚/满月、洞穴梦魇、幽灵、夜视覆盖）
--   1 = insanity（低理智灰屏）
--   2 = lunacy（月癫）
-- 这些推送是**边沿事件**（换季/换时段/理智变化时才推），所以拨开关后没人再推就看不到
-- 变化。这里把最后一次的参数全记下来，拨完开关用原参数重跑一遍 wrapper，
-- 让 wrapper 按新的 FILTER_STATE 重算 => 立刻生效，即「点一下就预览」。
-- （参照 ColourCube Control 3551241765 的 ForceReapplyColourCubes）
--------------------------------------------------------------------------------
local CC_DATA_CACHE = {}    -- index => { src, dest }
local CC_LERP_CACHE = {}    -- index => blend

-- 色彩立方总开关：把**所有**色块换成 identity，效果上等价于整条色块管线失效
-- （季节 / 黄昏 / 夜晚 / 满月紫月 / 洞穴梦魇 / 幽灵 / 低理智灰屏 一并消失）。
--
-- ⚠ 不能用 PostProcessor:EnablePostProcessEffect(ColourCube, false) 来做这件事：
--    禁用 effect 后，官方 colourcube 组件并不知情，它的 OnUpdate 仍每帧调
--    SetColourCubeData 往一个已失效的 effect 上塞纹理 —— 实测会触发引擎断言
--    HWEffect.cpp(467) 'src_data != NULL' 直接崩游戏。
--    正确做法是像 ColourCube Control 那样保持 effect 启用、只把纹理换成 identity。
--    下面这个函数只用于「确保启用」，防止别处把它关掉。
local function ApplyColourCubeEffect()
    local ppe = GLOBAL.PostProcessorEffects
    local id = ppe ~= nil and ppe.ColourCube or nil
    if id == nil or GLOBAL.PostProcessor == nil then return end
    GLOBAL.PostProcessor:EnablePostProcessEffect(id, true)
end

-- 需要靠重放才能即时生效的 key：所有经由 SetColourCubeData / SetColourCubeLerp wrapper
-- 影响色块的开关都要重放（季节/时段/满月/洞穴/幽灵/停电/真菌/天坑/海狸 + 夜视/低理智/月癫 + 总开关）。
-- 由 CC_FILE_KEYS 自动推导，避免漏掉某个季节/时段 key 导致「开关没效果」（SetColourCubeData 是
-- 边沿事件，翻转后不重跑 wrapper 画面就永远不刷新）。FILTER_COLOURCUBE 是总开关，也必须重放。
local CC_REAPPLY_KEYS = {}
for _, keys in pairs(CC_FILE_KEYS) do
    for _, k in ipairs(keys) do
        CC_REAPPLY_KEYS[k] = true
    end
end
CC_REAPPLY_KEYS.FILTER_NIGHTVISION_CC = true
CC_REAPPLY_KEYS.FILTER_INSANITY_CC    = true
CC_REAPPLY_KEYS.FILTER_LUNACY         = true
CC_REAPPLY_KEYS.FILTER_COLOURCUBE     = true

function MOD_EQUIPMENT_CONTROL.ReapplyColourCubes()
    local pp = GLOBAL.PostProcessor
    if pp == nil then return end
    for i = 0, 2 do
        local cc = CC_DATA_CACHE[i]
        -- 防御：src/dest 必须是有内容的色彩立方路径，空串/非串会被引擎当成无效纹理
        --       而触发 HWEffect.cpp(467) 'src_data != NULL' 断言崩游戏
        if type(cc) == "table" and type(cc.src) == "string" and cc.src ~= ""
                and type(cc.dest) == "string" and cc.dest ~= "" then
            pp:SetColourCubeData(i, cc.src, cc.dest)
        end
        local blend = CC_LERP_CACHE[i]
        if blend ~= nil then
            pp:SetColourCubeLerp(i, blend)
        end
    end
end

--------------------------------------------------------------------------------
-- 边沿触发钩子的「重放」机制
--
-- 问题：一部分 hook 只在游戏主动调用时才有机会改状态 —— 例如 PostProcessor:SetLunacyEnabled
-- 只在月癫状态切换时被调、gogglesover:ToggleGoggles 只在护目镜开关时被调。
-- 翻转 FILTER_STATE 后如果没人再调一次，画面要等到游戏下次因别的原因触发才变，
-- 表现为「UI 开关了但效果没跟上」。
--
-- 做法：这些 hook 各自记下最后一次调用参数；SetFilterRemoved 翻转对应 key 后，
-- 立刻用原参数把 wrapper 重放一遍。重放走的是 wrapper 本身，会用新的 FILTER_STATE
-- 重算一次 => 立即生效；而参数是游戏最后一次给的真值 => 语义不变、不会凭空造状态。
--
-- 每帧型 hook（OnUpdate 类，见第三/五节）不需要登记，它们本来就实时。
--------------------------------------------------------------------------------
local REPLAY = {}   -- key => { replay_fn, ... }

local function RegisterReplay(key, fn)
    REPLAY[key] = REPLAY[key] or {}
    table.insert(REPLAY[key], fn)
end

local function pack(...) return { n = select("#", ...), ... } end

-- 用法：local memo, getmemo = Memo()；调用点 memo(...)，重放点 getmemo() 取回参数包
local function Memo()
    local last = nil
    return function(...)
        last = pack(...)
    end, function()
        return last
    end
end

function MOD_EQUIPMENT_CONTROL.SetFilterRemoved(key, removed, persist)
    removed = removed == true
    if FILTER_STATE[key] == removed then return end

    FILTER_STATE[key] = removed == true
    -- persist=false 供演示使用：只改运行时状态，不写进配置
    if persist ~= false then
        MOD_EQUIPMENT_CONTROL.CONFIG[key] = removed == true   -- 持久化（退出世界时统一落盘）
    end

    local list = REPLAY[key]
    if list ~= nil then
        for _, fn in ipairs(list) do
            local ok, err = pcall(fn)
            if not ok then
                print("[Equipment Control] 滤镜重放失败 key=" .. tostring(key) .. " err=" .. tostring(err))
            end
        end
    end

    -- 色块类开关：重放最后一次的三层色块参数，让改动当场可见
    if CC_REAPPLY_KEYS[key] then
        MOD_EQUIPMENT_CONTROL.ReapplyColourCubes()
    end

    -- 色彩立方总开关：直接起停官方 effect
    if key == "FILTER_COLOURCUBE" then
        ApplyColourCubeEffect()
    end
end


--------------------------------------------------------------------------------
-- 边沿型覆盖层的通用钩子
--
-- 这类 widget 都长一个样：Toggle(show) / SetHat(hat) / PushLevel(level)，
-- 游戏事件驱动，且**幂等**（内部靠 self.shown 之类的守卫，状态没变就不干活）。
--
-- 于是两条纪律：
--   1) 压制必须无损 —— 只收尾改可见性，绝不写死动画/更新状态。否则守卫和内部状态
--      都被改坏了，重放时原方法会认为「状态没变」而不肯恢复。
--   2) 重放必须清守卫 —— 把 self.shown 改成与目标相反再调原方法，它才会真的走一遍。
--      （意图为「关」时不用重放：压制后本就是隐藏的，再跑一遍只会白放一次退场动画。）
--
-- restore_fn 可传 nil => 该滤镜是一次性特效（如墨汁、信号弹），关掉就不必再补。
--------------------------------------------------------------------------------
local function HookOverlay(widget, key, method_name, suppress_fn, restore_fn)
    local orig = widget[method_name]
    local memo, getmemo = Memo()

    widget[method_name] = function(self, ...)
        memo(...)
        if orig then orig(self, ...) end
        if FILTER_STATE[key] then suppress_fn(self) end
    end

    if restore_fn ~= nil then
        RegisterReplay(key, function()
            local a = getmemo()
            if a ~= nil then restore_fn(widget, a) end
        end)
    end
end

-- 通用重放：最后一次游戏意图是「开」时才需要恢复
local function RestoreToggle(method_name)
    return function(w, a)
        if a[1] == true then
            w.shown = false     -- 清掉 `show and not self.shown` 幂等守卫
            w[method_name](w, unpack(a, 1, a.n))
        end
    end
end

-- 通用压制：只隐藏，不动动画/更新状态
local function SuppressHide(self)
    self:Hide()
end

-- 海狸覆盖层是 prefabs/woodie.lua 现建现挂到 HUD 上的（inst.HUD.beaverOL = ...），
-- 这里存最后一次挂上的实例，供重放时恢复。
local beaver_ol = nil

RegisterReplay("FILTER_BEAVER", function()
    if beaver_ol ~= nil and beaver_ol._ec_want and beaver_ol.shown ~= true then
        beaver_ol:Show()
    end
end)

-- 总开关：整体启用 hook 注册（true）。若将来出问题可改 false 全部停用。
local FILTERS_ENABLED = true

--------------------------------------------------------------------------------
-- 每帧型覆盖层（沙暴/月风暴/瘴气）：压制是实体级 Hide，还原需显式 Show。
-- 仅用于下方 OnUpdate 安全压制逻辑（与演示无关）。
--------------------------------------------------------------------------------
local function StealthShow(self)
    if self ~= nil and self.shown and self.inst ~= nil then
        self.inst.entity:Show(false)
    end
end

-------------------------------------------------------------------------------
-- 悬停静态预览图：仅给「有现成覆盖层美术」的滤镜一张静态代表图，
-- 悬停 HUD 按钮时铺满全屏、垫在面板底层（不实时驱动后处理，绝不崩）。
-- 来源即 ColourCube Control 的 FX 面板缩略图所用的原版图集（data/images/fx*.xml）。
-- 色彩立方 / 扭曲 / 泛光 / 暗角等没有「单张静态图」可代表，故不入此表 => 悬停无预览。
-------------------------------------------------------------------------------
MOD_EQUIPMENT_CONTROL.FILTER_PREVIEW = {
    ["FILTER_ICE"]       = { atlas = "images/fx.xml",  tex = "ice_over.tex" },
    ["FILTER_BLOOD"]     = { atlas = "images/fx.xml",  tex = "blood_over.tex" },
    ["FILTER_BEEFBLOOD"] = { atlas = "images/fx.xml",  tex = "beefblood_over.tex" },
    ["FILTER_HEAT"]      = { atlas = "images/fx2.xml", tex = "heat_over.tex" },
    ["FILTER_FUME"]      = { atlas = "images/fx2.xml", tex = "fume_over.tex" },
    ["FILTER_NUTRIENTS"] = { atlas = "images/fx4.xml", tex = "nutrients_over.tex" },
    ["FILTER_GOGGLE"]    = { atlas = "images/fx3.xml", tex = "goggle_over.tex" },
    ["FILTER_FLARE"]     = { atlas = "images/fx4.xml", tex = "flare_over.tex" },
}

if FILTERS_ENABLED then
    ---------------------------------------------------------------------------
    -- 〇、色彩立方总开关（官方 base effect）
    -- 必须在 shader 构建完成之后才有 PostProcessorEffects.ColourCube，所以放在
    -- AddGamePostInit 里应用；重连 / 切世界会重建 HUD，那里再补一次。
    ---------------------------------------------------------------------------
    AddGamePostInit(ApplyColourCubeEffect)
    AddClassPostConstruct("screens/playerhud", function(self)
        ApplyColourCubeEffect()
    end)

    ---------------------------------------------------------------------------
    -- 一、ColourCube 色彩分级 (LUT) 拦截层：每次色彩立方设置都过 wrapper，按需替换夜视 LUT
    ---------------------------------------------------------------------------
    AddGamePostInit(function()
        local PostProcessor = GLOBAL.PostProcessor
        local pp_meta = GLOBAL.getmetatable(PostProcessor)
        if not (pp_meta and pp_meta.__index) then return end
        local ppmti = pp_meta.__index
        local orig_SetCC = ppmti.SetColourCubeData
        local memo_cc, getmemo_cc = Memo()
        ppmti.SetColourCubeData = function(self, index, src, dest)
            memo_cc(self, index, src, dest)
            -- 记原始参数（未经替换），重放时 wrapper 才会按当前 FILTER_STATE 重新算一遍
            CC_DATA_CACHE[index] = { src = src, dest = dest }
            local function replace_if_removed(path)
                if not path then return path end
                -- 总开关：任何色块都换成 identity（等价于整条色块管线失效）。
                -- 见 ApplyColourCubeEffect 的注释：这里绝不能改用「禁用 effect」来实现。
                if FILTER_STATE.FILTER_COLOURCUBE and path ~= IDENTITY_CC then
                    return IDENTITY_CC
                end
                local filename = string.match(path, "[^/\\]+$") or ""
                -- 夜视 LUT（鼹鼠帽 / 夜视果）
                if FILTER_STATE.FILTER_NIGHTVISION_CC and NIGHTVISION_CC_FILES[filename] then
                    return IDENTITY_CC
                end
                -- 季节 / 时段 / 满月 / 洞穴
                local keys = CC_FILE_KEYS[(filename:gsub("%.tex$", ""))]
                if keys ~= nil then
                    for _, key in ipairs(keys) do
                        if FILTER_STATE[key] then return IDENTITY_CC end
                    end
                end
                return path
            end
            return orig_SetCC(self, index,
                replace_if_removed(src),
                replace_if_removed(dest))
        end
        -- 重放：换 CC 是边沿事件，开关后必须用最后一次的 CC 重新过一遍 wrapper
        RegisterReplay("FILTER_NIGHTVISION_CC", function()
            local a = getmemo_cc()
            if a ~= nil and a[1] ~= nil then
                ppmti.SetColourCubeData(unpack(a, 1, a.n))
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- 二、后处理着色器效果（条件式 wrapper，实时响应 FILTER_STATE）
    ---------------------------------------------------------------------------
    AddGamePostInit(function()
        local PostProcessor = GLOBAL.PostProcessor
        local pp_meta = GLOBAL.getmetatable(PostProcessor)
        if not (pp_meta and pp_meta.__index) then return end
        local ppmti = pp_meta.__index

        -- ⚠ 核心纪律：绝不在「已禁用」的 effect 上设 uniform / 纹理（否则
        --   Shader uniform is undefined → HWEffect.cpp(467) 'src_data != NULL' 崩）。
        --   参考 ColourCube Control（Oni）的做法：月癫(lunacy)只当作「色彩分级」处理——
        --   即把 colour cube 三级 lerp 的 index2 归零（见下方 SetColourCubeLerp），
        --   它根本不碰 SetLunacyIntensity / SetOverlayBlend 这类参数型 setter。
        --   我们只对「扭曲(distortion)」做参数归零，且必须记录游戏真实的启用态：
        --   游戏会在非对应状态时把 distortion effect 关掉，setter 在 effect 关着时
        --   直接 return、不调 orig —— 既不崩也不污染画面。
        local distortion_on = false

        if ppmti.SetDistortionEnabled then
            local orig = ppmti.SetDistortionEnabled
            ppmti.SetDistortionEnabled = function(self, enabled, ...)
                distortion_on = (enabled == true)
                return orig(self, enabled, ...)
            end
        end

        -- ColourCube 三级 lerp：index 1 = 低理智灰屏，index 2 = 月癫（都在始终启用的 ColourCube effect 上，安全）
        if ppmti.SetColourCubeLerp then
            local orig = ppmti.SetColourCubeLerp
            local memo, getmemo = Memo()
            ppmti.SetColourCubeLerp = function(self, index, blend)
                memo(self, index, blend)
                CC_LERP_CACHE[index] = blend
                local b = blend
                if index == 1 and FILTER_STATE.FILTER_INSANITY_CC then
                    b = 0
                elseif index == 2 and FILTER_STATE.FILTER_LUNACY then
                    b = 0
                end
                return orig(self, index, b)
            end
            local function replay_lerp()
                local a = getmemo()
                if a ~= nil and a[1] ~= nil then ppmti.SetColourCubeLerp(unpack(a, 1, a.n)) end
            end
            RegisterReplay("FILTER_LUNACY", replay_lerp)
            RegisterReplay("FILTER_INSANITY_CC", replay_lerp)
        end

        -- 扭曲类 setter：effect 关着就跳过；开着时按消除需求归零
        if ppmti.SetDistortionFactor then
            local orig = ppmti.SetDistortionFactor
            local memo, getmemo = Memo()
            ppmti.SetDistortionFactor = function(self, factor, ...)
                memo(self, factor, ...)
                if not distortion_on then return end
                local f = (FILTER_STATE.FILTER_DISTORTION or FILTER_STATE.FILTER_INSANITY_CC) and 0 or factor
                return orig(self, f, ...)
            end
            local function replay()
                local a = getmemo()
                if a ~= nil and a[1] ~= nil then ppmti.SetDistortionFactor(unpack(a, 1, a.n)) end
            end
            RegisterReplay("FILTER_DISTORTION", replay)
            RegisterReplay("FILTER_INSANITY_CC", replay)
        end
        if ppmti.SetDistortionFishEyeIntensity then
            local orig = ppmti.SetDistortionFishEyeIntensity
            local memo, getmemo = Memo()
            ppmti.SetDistortionFishEyeIntensity = function(self, intensity, ...)
                memo(self, intensity, ...)
                if not distortion_on then return end
                return orig(self, FILTER_STATE.FILTER_DISTORTION and 0 or intensity, ...)
            end
            RegisterReplay("FILTER_DISTORTION", function()
                local a = getmemo()
                if a ~= nil and a[1] ~= nil then ppmti.SetDistortionFishEyeIntensity(unpack(a, 1, a.n)) end
            end)
        end
        -- 其余扭曲几何参数：effect 关着直接跳过（开着时原样转发，无需改值）
        for _, name in ipairs({ "SetDistortionRadii", "SetDistortionFishEyeTime", "SetDistortionEffectTime" }) do
            if ppmti[name] then
                local orig = ppmti[name]
                ppmti[name] = function(self, ...)
                    if not distortion_on then return end
                    return orig(self, ...)
                end
            end
        end

        -- 月癫(lunacy)：按 ColourCube Control 的方式，只走「色彩分级」——即上方
        --   SetColourCubeLerp(index==2) 归零，把紫色分级去掉。不 hook SetLunacyIntensity /
        --   SetOverlayBlend：它们是参数型 setter，往月癫 effect 上写 uniform 会在该 effect
        --   被游戏关掉时触发 HWEffect.cpp(467) 断言崩游戏。所以月癫的覆盖层(overlay)不在此消除。

        -- bloom：无标量参数可调，只能开关；游戏代码不会在 bloom 关闭时设它的 uniform
        --   （只有 SetBloomEnabled 被调用），禁用安全，保留这一处开关式消除。
        if ppmti.SetBloomEnabled then
            local orig = ppmti.SetBloomEnabled
            local memo, getmemo = Memo()
            ppmti.SetBloomEnabled = function(self, enabled, ...)
                memo(self, enabled, ...)
                return orig(self, FILTER_STATE.FILTER_BLOOM and false or enabled, ...)
            end
            RegisterReplay("FILTER_BLOOM", function()
                local a = getmemo()
                if a ~= nil and a[1] ~= nil then ppmti.SetBloomEnabled(unpack(a, 1, a.n)) end
            end)
        end
    end)

    ---------------------------------------------------------------------------
    -- 三、通用 OnUpdate 类覆盖层（每帧条件压制 => 真正实时）
    ---------------------------------------------------------------------------
    local function Hooker_Generic_OnUpdate(key)
        return function(self, owner)
            local OnUpdate_old = self.OnUpdate
            self.OnUpdate = function(self, ...)
                if FILTER_STATE[key] then
                    self:Hide()
                    return
                end
                if OnUpdate_old then return OnUpdate_old(self, ...) end
            end
        end
    end

    AddClassPostConstruct("widgets/bloodover",      Hooker_Generic_OnUpdate("FILTER_BLOOD"))
    AddClassPostConstruct("widgets/iceover",        Hooker_Generic_OnUpdate("FILTER_ICE"))
    AddClassPostConstruct("widgets/fireover",       Hooker_Generic_OnUpdate("FILTER_FIRE"))
    AddClassPostConstruct("widgets/heatover",       Hooker_Generic_OnUpdate("FILTER_HEAT"))
    AddClassPostConstruct("widgets/fumeover",       Hooker_Generic_OnUpdate("FILTER_FUME"))
    AddClassPostConstruct("widgets/beefbloodover",  Hooker_Generic_OnUpdate("FILTER_BEEFBLOOD"))
    AddClassPostConstruct("widgets/leafcanopy",     Hooker_Generic_OnUpdate("FILTER_LEAFCANOPY"))

    ---------------------------------------------------------------------------
    -- 四、Toggle 类覆盖层（事件驱动 => 走 HookOverlay + 重放）
    ---------------------------------------------------------------------------
    local function Hooker_Toggle(key, method_name)
        method_name = method_name or "Toggle"
        return function(self, owner)
            HookOverlay(self, key, method_name, SuppressHide, RestoreToggle(method_name))
        end
    end

    AddClassPostConstruct("widgets/nutrientsover", Hooker_Toggle("FILTER_NUTRIENTS", "ToggleNutrients"))

    AddClassPostConstruct("widgets/gogglesover", function(self, owner)
        -- ToggleGoggles(true) 会把 storm_overlays 从 storm_root 搬进自身、跟着护目镜一起显示。
        -- 压制时只 Hide 不够：天气覆盖层的父子关系会被困在隐藏的 widget 里，摘护目镜时
        -- 那个「搬回去」的分支又因为 shown 已被我们改掉而跳过 => 沙暴/月暴覆盖层永久消失。
        -- 所以压制时顺手把它搬回原位；重放走正常的 ToggleGoggles(true)，会再搬进来。
        HookOverlay(self, "FILTER_GOGGLE", "ToggleGoggles",
            function(w)
                w:Hide()
                if w.storm_root ~= nil and w.storm_overlays ~= nil then
                    w.storm_root:AddChild(w.storm_overlays)
                end
            end,
            RestoreToggle("ToggleGoggles"))
    end)

    AddClassPostConstruct("widgets/mindcontrolover", function(self, owner)
        -- 这里的幂等守卫是 self.level 而不是 self.shown（PushLevel 里 `if self.level ~= level`），
        -- 所以要先把 level 破坏掉，同一个等级重放才会真的走一遍、把画面 Show 回来。
        HookOverlay(self, "FILTER_MINDCONTROL", "PushLevel",
            SuppressHide,
            function(w, a)
                local level = a[1]
                if level ~= nil and level > 0 and w.shown ~= true then
                    w.level = -1
                    w:PushLevel(level)
                end
            end)
    end)

    ---------------------------------------------------------------------------
    -- 五、风暴/天气类覆盖层（OnUpdate 条件压制）
    ---------------------------------------------------------------------------
    local function StealthHide(self)
        if self.shown then
            self.inst.entity:Hide(false)
        end
    end

    local function Hooker_StealthKey(key, hide_self, ...)
        local child_fields = { ... }
        return function(self, owner)
            local OnUpdate_old = self.OnUpdate
            self.OnUpdate = function(self, ...)
                if OnUpdate_old then OnUpdate_old(self, ...) end
                if FILTER_STATE[key] then
                    for _, field in ipairs(child_fields) do
                        local child = self[field]
                        if child then StealthHide(child) end
                    end
                    if hide_self then
                        StealthHide(self)
                    end
                end
            end
        end
    end

    AddClassPostConstruct("widgets/sandover",                  Hooker_StealthKey("FILTER_SANDSTORM",   true, "dust"))
    AddClassPostConstruct("widgets/moonstormover",             Hooker_StealthKey("FILTER_MOONSTORM",  true, "dust"))
    AddClassPostConstruct("widgets/moonstormover_lightning",   Hooker_StealthKey("FILTER_MOONSTORM",  false, "lightning"))
    AddClassPostConstruct("widgets/miasmaover",                Hooker_StealthKey("FILTER_MIASMA",     true, "clouds"))
    -- 时空迷雾覆盖层由勋章模组（1909182187）提供：未启用该模组时模块不存在，
    -- 无条件 AddClassPostConstruct 会在 modimport 阶段抛 "module ... not found" 并中断整个 filterremover。
    -- 先探测模块可加载性，存在才挂钩（模组不在时该 widget 本就构造不出来）。
    if pcall(require, "widgets/medal_spacetimedustover") then
        AddClassPostConstruct("widgets/medal_spacetimedustover", Hooker_StealthKey("FILTER_SPACETIME_MIST", true))
    end

    ---------------------------------------------------------------------------
    -- 六、装备/物品视觉类覆盖层（事件驱动 => HookOverlay + 重放）
    ---------------------------------------------------------------------------
    AddClassPostConstruct("widgets/wagpunkui", function(self, owner)
        -- SetHat 每次都会把 overlay 动画重播回 hud_0_to_1，整体重放会把等级打回 1 级。
        -- 所以压制只隐藏 overlay，重放只 Show 回来，等级动画（ChangeLevel 推的）不受影响。
        HookOverlay(self, "FILTER_WAGPUNK", "SetHat",
            function(w) if w.overlay ~= nil then w.overlay:Hide() end end,
            function(w, a)
                if w.overlay ~= nil and w.hat ~= nil then w.overlay:Show() end
            end)
    end)

    AddClassPostConstruct("widgets/scrapmonocleover",         Hooker_Toggle("FILTER_WAGLENS"))
    AddClassPostConstruct("widgets/nightvisionfruitover",     Hooker_Toggle("FILTER_NIGHTVISION"))
    AddClassPostConstruct("widgets/inspectaclesover",         Hooker_Toggle("FILTER_INSPECTACLES"))
    AddClassPostConstruct("widgets/roseglassesover",          Hooker_Toggle("FILTER_ROSEGLASSES"))

    AddClassPostConstruct("widgets/dronezapover", function(self, owner)
        -- Enable 不是幂等的：Toggle 用 `source ~= self.source` 守卫，而启用期间 self.source
        -- 一直非空 => 光 Hide 再重放 Toggle 不会重新 Enable。
        -- 压制定为走一次完整的 Disable：清空 source、撤掉鱼眼畸变、淡回目标物体，
        -- 这样重放时 Toggle(true, source) 会重新走 Enable 全套。
        HookOverlay(self, "FILTER_DRONEZAP", "Toggle",
            function(w)
                if w.source ~= nil then w:Disable() end
                w:Hide()
                if w.arrow ~= nil then w.arrow:Hide() end
            end,
            RestoreToggle("Toggle"))
    end)

    ---------------------------------------------------------------------------
    -- 七、特殊覆盖层（PlayerHUD 层面）
    ---------------------------------------------------------------------------
    AddClassPostConstruct("screens/playerhud", function(self, owner)
        -- 疯狂暗角：GoInsane 只干一件事 —— 把暗角动画切成 "insane"。
        -- 压制 = 让原方法跑完后立刻切回 "basic"（无损，拨回开关时重放即可还原）。
        -- GoEnlightened 本来就切 "basic"，无需处理。
        HookOverlay(self, "FILTER_INSANITY_VIGNETTE", "GoInsane",
            function(w)
                if w.vig ~= nil then
                    w.vig:GetAnimState():PlayAnimation("basic", true)
                end
            end,
            function(w) w:GoInsane() end)
    end)

    AddClassPostConstruct("screens/playerhud", function(self, owner)
        -- 暗角：每帧压制（vig 的显隐在官方里由 GoInsane/GoEnlightened 的动画切换驱动，
        -- 没有任何逐帧逻辑，所以这里每帧 Hide 既压得住也天然实时）。
        -- 旧实现写成「insane 动画时 Show」——那正是原版行为，等于什么都没消除。
        local OnUpdate_old = self.OnUpdate
        self.OnUpdate = function(self, ...)
            if OnUpdate_old then OnUpdate_old(self, ...) end
            if FILTER_STATE.FILTER_VIGNETTE and self.vig ~= nil then
                self.vig:Hide()
            end
        end
    end)

    AddClassPostConstruct("screens/playerhud", function(self, owner)
        -- 海狸化覆盖层：beaverOL 由 prefabs/woodie.lua 现建现赋到 HUD 上
        -- （inst.HUD.beaverOL = inst.HUD.overlayroot:AddChild(...)），随后变身/解除时
        -- 直接 Show()/Hide()。这里在赋值那一刻包住它的 Show/Hide：
        --   _ec_want 记「游戏想要的状态」；滤镜开着时 Show 之后立刻跟一个 Hide 收尾。
        -- 旧实现把 Show 永久改写成空函数，一旦压制就再也恢复不了 —— 这里不再破坏原方法。
        local mt = GLOBAL.getmetatable(self)
        if mt == nil or mt._ec_beaver_hooked then return end
        mt._ec_beaver_hooked = true

        local newindex_old = mt.__newindex
        mt.__newindex = function(t, k, v)
            if k == "beaverOL" and type(v) == "table" and v.Show ~= nil and v._ec_hooked == nil then
                v._ec_hooked = true
                beaver_ol = v
                local Show_old, Hide_old = v.Show, v.Hide
                v.Show = function(self, ...)
                    self._ec_want = true
                    Show_old(self, ...)
                    if FILTER_STATE.FILTER_BEAVER then Hide_old(self) end
                end
                v.Hide = function(self, ...)
                    self._ec_want = false
                    Hide_old(self, ...)
                end
            end
            if newindex_old ~= nil then
                newindex_old(t, k, v)
            else
                GLOBAL.rawset(t, k, v)
            end
        end
        GLOBAL.setmetatable(self, mt)
    end)

    AddClassPostConstruct("widgets/inkover", function(self, owner)
        -- 墨汁是一次性喷溅特效，关掉就没有「补回来」的语义 => 不需要重放
        HookOverlay(self, "FILTER_INK", "Flash",
            function(w)
                if w.InkOver  ~= nil then w.InkOver:Hide()  end
                if w.InkOver2 ~= nil then w.InkOver2:Hide() end
            end,
            nil)
    end)

    AddClassPostConstruct("widgets/flareover", function(self, owner)
        -- OnUpdate 里 alpha 还没褪完时会 Show()，所以压制必须连更新一起停，
        -- 否则下一帧原方法就把 Hide 顶回去了。
        HookOverlay(self, "FILTER_FLARE", "StartFlare",
            function(w)
                w:Hide()
                w:StopUpdating()
            end,
            function(w, a)
                -- 信号弹同样是一次性闪光：重放 = 用当时的数据重新放一次
                w:StartFlare(a[1])
            end)
    end)
end