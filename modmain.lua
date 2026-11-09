GLOBAL.setmetatable(env, {
    __index = function(_, k) return GLOBAL.rawget(GLOBAL, k) end
})

if GLOBAL.ManifestManager then
    GLOBAL.ManifestManager:AddFileToModManifest(modname, "scripts/Auto/autodrone.lua")
end

local MOD_EQUIPMENT_CONTROL                = {}
    MOD_EQUIPMENT_CONTROL.MODNAME        = modname
    MOD_EQUIPMENT_CONTROL.SPECIALFOOD    = require("util/specialfood")
    MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE = require("util/keybindservice")(modname)
    MOD_EQUIPMENT_CONTROL.AUTO_FROM_OPEN_CONTAINERS = GetModConfigData("AUTO_FROM_OPEN_CONTAINERS", modname)

    -- 按游戏语言加载对应语言文件。
    -- 注意：modmain 环境里并不保证存在全局 Language（CHANGELOG 已记：strict 下 'Language' is not declared），
    -- 直接用它恒为 nil，会永远落到 english.lua，导致你做的 chinese_s.lua 翻译从不被加载。
    -- 改用 LOC.GetLocaleCode() 取真实语言码，再映射到 scripts/language/ 下的实际文件名。
    local ec_lang = (GLOBAL.LOC ~= nil and GLOBAL.LOC.GetLocaleCode ~= nil and GLOBAL.LOC.GetLocaleCode())
            or (type(Language) == "string" and Language:lower())
            or "en"
    local EC_LANG_FILE = ({
        zh  = "chinese_s", zhr = "chinese_s", chs = "chinese_s",   -- 简体各变体
        zht = "chinese_s", cht = "chinese_s",                       -- 暂无 chinese_t.lua，先复用简体
    })[ec_lang] or "english"
    modimport("scripts/language/" .. EC_LANG_FILE .. ".lua")
    -- 兜底：若对应语言文件缺失（如未来新增但未提供的变体），退回英文，避免 STRINGS 为 nil 引发崩溃
    if STRINGS.EQUIPMENT_CONTROL == nil then
        modimport("scripts/language/english.lua")
    end
    MOD_EQUIPMENT_CONTROL.STRINGS        = STRINGS.EQUIPMENT_CONTROL
    MOD_EQUIPMENT_CONTROL.SPAWNING       = false
    MOD_EQUIPMENT_CONTROL.PICKUP_FILTER  = {}
    GLOBAL.MOD_EQUIPMENT_CONTROL         = MOD_EQUIPMENT_CONTROL
    MOD_EQUIPMENT_CONTROL.MODROOT       = "../mods/" .. modname .. "/"

-- 动态配置层：必须在下面任何 Auto/* 之前加载（它们顶层就会读 CONFIG）。
-- 挂载 MOD_EQUIPMENT_CONTROL.CONFIG；AUTO_EQUIP 改为转发到 CONFIG 的代理表
-- （「每个分类独立的自动装备开关」，物品栏按钮条中键切换），默认值见 util/config.lua。
-- 改配置只写内存，退出世界时由下面的 playerdeactivated 统一落盘一次。
local Config = require("util/config")
GLOBAL.PlayerUtil = require("util/playerutil")

-- 技能树工具（原属 Exp_Max，统一收归 EC 通用工具层）：提供技能/标签/经验查询与回调系统。
GLOBAL.SkillTreeUtil = require("util/skilltreeutil")()

-- 生命周期由 EC 接管：新角色生成时监听初始化事件并触发 TryInit（换人自动重置由 util 内部处理）。
AddPlayerPostInit(function(player)
    player:ListenForEvent("skilltreeinitialized_client", function()
        GLOBAL.SkillTreeUtil:TryInit()
    end, player)
end)

-- actionutil 必须 modimport 加载（不要 require）：文件内用 AddComponentPostInit 等 mod 专属 API，
-- 而 require 环境是游戏全局表、非 mod 环境，strict 模式下这些 mod 全局未声明会直接报错
-- （拖垮所有 require 它的 Auto 模块）。modimport 走 mod 环境，文件以全局 ActionUtil 暴露自身
-- （modimport 不返回 chunk 返回值，只能靠这个全局）；写入 package.loaded
-- 使后续 require("util/actionutil") 仍返回同一实例，无需重跑。
modimport("scripts/util/actionutil")
package.loaded["util/actionutil"] = ActionUtil

-- InventoryEventService 改为 modimport 加载（不要 require）：文件内直接用 AddClassPostConstruct 等
-- mod API，require 环境的 strict 模式下这些全局未声明，会在加载期报 LUA ERROR 并拖垮所有调用方。
-- 设为 package.loaded 以便其他文件仍可用 require("util/inventoryeventservice") 拿到同一实例，无需重跑。
modimport("scripts/util/inventoryeventservice")
package.loaded["util/inventoryeventservice"] = InventoryEventService

-- ShowMeUtil 改为 modimport 加载（不要 require）：文件内直接用 AddPrefabPostInit 等
-- mod API，require 环境的 strict 模式下这些全局未声明，会在加载期报 LUA ERROR 并拖垮所有调用方。
-- 设为 package.loaded 以便其他文件仍可用 require("util/showmeutil") 拿到同一实例，无需重跑。
modimport("scripts/util/showmeutil")
package.loaded["util/showmeutil"] = ShowMeUtil

require("categories")
local WorldUtil = require("util/worldutil")

-- 防御：部分 mod 以 nil modname 调用 AddComponentAction（env.modname 在其环境下为 nil），
-- 会生成 MOD_ACTION_COMPONENT_IDS[nil] / MOD_COMPONENT_ACTIONS[nil] / MOD_ACTION_COMPONENT_NAMES[nil]
-- 等损坏条目。官方 RegisterComponentActions / UnregisterComponentActions 遍历到 nil key 时索引
-- self.actionreplica.modactioncomponents[nil] 崩溃（attempt to index field '?'）。
-- 这些条目本身无法工作（无 modname 可关联），清掉即可避免崩溃。
local function SanitizeModActions()
    for _, t in ipairs({ MOD_ACTION_COMPONENT_IDS, MOD_COMPONENT_ACTIONS, MOD_ACTION_COMPONENT_NAMES }) do
        if t ~= nil then
            t[nil] = nil
        end
    end
end

-- 防御：客户端 mod 的 modname 不在 ModManager:GetServerModsNames() 列表里，官方只在服务端 mod
-- 名下预建 actionreplica.modactioncomponents 条目（entityscript.lua）。客户端 mod 注册组件动作时
-- 该条目缺失，官方 :set 会崩溃。这里按官方同样方式补建缺失的 net 条目。
local function EnsureModActionReplica(inst, name)
    if inst.actionreplica == nil or type(inst.actionreplica.modactioncomponents) ~= "table" then
        return
    end
    if type(MOD_ACTION_COMPONENT_IDS) ~= "table" then
        return
    end
    for modname, idmap in pairs(MOD_ACTION_COMPONENT_IDS) do
        if modname ~= nil
            and type(idmap) == "table" and idmap[name] ~= nil
            and inst.actionreplica.modactioncomponents[modname] == nil then
            inst.actionreplica.modactioncomponents[modname] =
                net_smallbytearray(inst.GUID, "modactioncomponents"..modname, "modactioncomponentsdirty"..modname)
        end
    end
end

local function EntityScriptPostConstruct(self)
    local OldRegisterComponentActions = self.RegisterComponentActions
    local OldUnregisterComponentActions = self.UnregisterComponentActions

    function self:RegisterComponentActions(...)
        if type(self) ~= "table" or self.GUID == nil then
            return
        end
        if MOD_EQUIPMENT_CONTROL.SPAWNING then
            return
        end
        SanitizeModActions()
        EnsureModActionReplica(self, (...))
        OldRegisterComponentActions(self, ...)
    end

    function self:UnregisterComponentActions(name, ...)
        if type(self) ~= "table" or self.GUID == nil then
            return
        end
        if not MOD_EQUIPMENT_CONTROL.SPAWNING or (self.modactioncomponents and self.modactioncomponents[name]) then
            SanitizeModActions()
            OldUnregisterComponentActions(self, name, ...)
        end
    end
end
AddGlobalClassPostConstruct("entityscript", "EntityScript", EntityScriptPostConstruct)

-- 显示按钮：永久启用
do
    local Buttons = require "widgets/buttons"
    AddClassPostConstruct("widgets/inventorybar",function(self)
        self.buttons = self.root:AddChild(Buttons(self.owner, self))
    end)
end

-- 类原生侧边抽屉 ConfigHUD（scripts/screens/confighud.lua，原 FeatureDrawerHUD 改名）
-- 展开后露出功能按钮网格：原 F1-F9 + K 键的功能（开关/动作/循环）统一收敛到本抽屉，
-- 点击按钮 == 原 F 键触发同一处理器（经 KeybindService:Trigger）。F 键已自 modinfo 解绑。
-- UI 基础设施、不是自动化功能，挂载写在 modmain（与上面的 inventorybar 按钮一致），
-- 不放进 scripts/Auto/（那目录只放功能模块）。
do
    -- HUD 按官方约定放在 scripts/screens/（官方 screens/playerhud.lua 就是 HUD 的 Screen）
    local ConfigHUD = require "screens/confighud"

    -- 直接挂 controls.right_root：官方右侧锚点（原点=屏幕右中，自带 HUD 缩放）。
    -- 制作菜单(CraftingMenu) 同样挂在 right_root 上 => 与制作菜单完全一致地靠右贴边停靠。
    AddClassPostConstruct("widgets/controls", function(self)
        if self.owner == nil then return end
        -- Controls 会重建（死亡重生/切世界），用 self 上的字段做幂等保护
        if self._ec_confighud ~= nil then return end

        local anchor = self.right_root or self   -- right_root 不存在（极老版本）时退回 controls 自身
        self._ec_confighud = anchor:AddChild(ConfigHUD(self.owner, false, "right"))
    end)
end

-- 镜头事件：逻辑封装在 util/camerautil（与 worldutil 同类型，纯工具），此处只装 hook
do
    local CameraUtil = require("util/camerautil")
    local quick_zoom = MOD_EQUIPMENT_CONTROL ~= nil
        and GetModConfigData("QUICK_ACTION_ZOOM", MOD_EQUIPMENT_CONTROL.MODNAME)
    AddClassPostConstruct("components/playercontroller", function(self)
        self.DoCameraControl = CameraUtil.WrapDoCameraControl(self.DoCameraControl, quick_zoom)
        if TheCamera ~= nil and TheCamera._ec_zoom_wrapped ~= true then
            TheCamera._ec_zoom_wrapped = true
            CameraUtil.WrapZoom(TheCamera)
        end
    end)
end

-- 玩家自身状态条（Widget 屏幕空间，固定在头顶，不随缩放改变大小）
do
    AddClassPostConstruct("widgets/controls", function(self)
        if self.owner == nil or self.owner ~= ThePlayer then return end
        local PlayerStatusBars = require "widgets/playerstatusbars"
        self.playerstatusbars = self.owner.HUD:AddChild(
            PlayerStatusBars(self.owner))
    end)
end

-- 始终加载（武器/手杖/工具/光源/伍迪换装/勋章），中键统一切换
-- 始终加载模块（Init 函数列表 + 副作用文件）
-- 原 Overrides 模块：不再通过 modinfo 门控，始终加载，由 confighud 动态开关控制
modimport("scripts/Auto/mousethrough")
modimport("scripts/Auto/filterattack")
modimport("scripts/Auto/filterpickup")
modimport("scripts/Auto/autodrone")
modimport("scripts/Auto/autocook")
MOD_EQUIPMENT_CONTROL.AutoInits = {}
table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, require("Auto/eatconfirmation"))
table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, require("Auto/telepoof"))
table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, require("Auto/quickactions"))

local AlwaysLoad = {
    "Auto/autoweapon",
    "Auto/autocane",
    "Auto/autolight",
    "Auto/autoeat",
    "Auto/autohelm",
    "Auto/autocloth",
    "Auto/woodieregear",
}
modimport("scripts/Auto/quickmove")
modimport("scripts/Auto/caveclock")
modimport("scripts/Auto/quickdeploy")
modimport("scripts/Auto/altarfinder")
modimport("scripts/Auto/wagstaffgiver")
modimport("scripts/Auto/autotool")
modimport("scripts/Auto/automedal")
modimport("scripts/Auto/autoamulet")
modimport("scripts/Auto/filterremover")
modimport("scripts/Auto/rangeindicator")
modimport("scripts/Auto/mapteleport")
modimport("scripts/Auto/gridalign")
modimport("scripts/Auto/autocontainer")
modimport("scripts/Auto/boulderdodge")
local function OnPlayerActivated(_, player)
    if player ~= ThePlayer then return end

    -- 绑定 PlayerUtil 的玩家事件（幂等）。配置落盘的 playerdeactivated 走它的回调体系，
    -- 不能只依赖某个功能模块（如 automedal）顺手 Init——那会让落盘时机取决于别的模块是否加载。
    PlayerUtil:Init(player)

    player:AddComponent("actioncontroller")
    player:AddComponent("eventtracker")
    player:AddComponent("itemtracker")

    -- 排序组件默认挂载：功能开关入口统一收归 confighud，不再受 modinfo 门控
    player:AddComponent("sorter")

    if MOD_EQUIPMENT_CONTROL.CONFIG.HEALTHBAR_ENABLED then
        player:AddComponent("damagetracker")
    end

    -- Auto 延迟初始化
    for _, init in ipairs(MOD_EQUIPMENT_CONTROL.AutoInits) do
        init()
    end

    -- 始终加载模块
    for _, mod in ipairs(AlwaysLoad) do
        require(mod)()
    end

    MOD_EQUIPMENT_CONTROL.AutoContainerInit()

end

AddPrefabPostInit("world", function(inst) WorldUtil:OnPlayerActivated(OnPlayerActivated) end)

-- 配置落盘：玩家停用（退出世界 / 断开连接 / 洞穴迁移）时统一写一次文件。
-- 改配置不频繁，全程只在内存里改，到这里才落盘（不防抖、不每次写盘）。
PlayerUtil:OnDeactivated(function()
    Config:Save()
end)