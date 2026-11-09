-- 地图坐标轮盘 + 定点跳跃（移植自 3372819329 小恶魔辅助的轮盘功能）
-- 两类目的地共存于同一个轮盘，按各自能力分别提供：
--   1) 地图坐标定点跳跃 ACTIONS.BLINK_MAP：CanSoulhop 持有者（Wortox 原生 / 佩戴噬空勋章者）
--      执行真传送；其余角色选中坐标仅提示，不瞬移。能力判断不硬编码 prefab。
--   2) WX-78 备份底盘远程换身 ACTIONS.SWAPBODIES_MAP：WX-78 且点了远程换身技能点时，
--      每个备份底盘作为一个轮盘项，选中即换身（移植自 WX-78辅助 3712173567 的思路，
--      但数据取自官方 GlobalMapIconsDB，不依赖其存档）。
local Widget = require "widgets/widget"
local Wheel = require "widgets/wheel"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local KeybindService = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE
local WorldUtil = require "util/worldutil"
local FileSystem = require "util/filesystem"

-- 图标纹理：直接用游戏官方的 GetInventoryItemAtlas(tex) 解析图集（参考 widgets/itembuttontile.lua），
-- 它会自动在 inventoryimages.xml / 1~4.xml 中查找正确图集，避免硬编码 inventoryimagesN.xml 出错。
local WHEEL_TEX = "wortox_soul.tex"
local function AtlasOf(tex)
    return GetInventoryItemAtlas(tex)
end

-------------------------------------------------------------------------------
-- 坐标存档（按 worldid 分片，跨洞穴/地表；移植自原 mod 的 LocationMemory）
-------------------------------------------------------------------------------
local locationpatch = "mod_config_data/equipment_control_locations"
local LocationMemory = {
    alldata = {},
    data_loaded = false,
    file_loaded = false,
    file_loading = false,
    activate_world_data = nil,
}
local saved_locations = {}
-- WX-78 底盘命名表：{ [key] = { n = 名字, x = 坐标, z = 坐标 } }
--   （旧存档是裸字符串，读取时兼容，见 RecordName）
--   key = 备份底盘地图形标的 GUID。注意官方地图形标是 wx78_backupbody_globalicon
--         （globalmapicon.lua:396 生成、:335 persists = false），每次进游戏都是新实体新 GUID，
--         所以这个键只在本次游戏内有效。
--   key = tostring(ThePlayer.GUID) —— 你现在驾驶的那台机身（圆心列表里的"当前机身"行）。
--         玩家实体 GUID 跟账号走，跨重登不变，故这一条不受上面那条限制。
-- x/z = 记账那一刻这台底盘的位置，专为"重登"准备：备份底盘钉在地上不会动，
--   下一局进游戏后按坐标把名字重新挂到新图标键上，见下方 ReanchorBodyNames。
-- 备份 ↔ 命名的对应关系另靠"换身时对调名字"维持，见下方 SwapChassisNames：
-- 你钻进去的那台带着它的名字成为当前机身，留在原地的那台承接你旧机身的名字。
local wx78_body_names = {}

local MAX_SAVED_WORLDS = 9

-- 坐标存档上限：最多保留最近游玩的 MAX_SAVED_WORLDS 个世界，超出清除时间最久者
local function EnforceMaxWorlds()
    local entries = {}
    for id, entry in pairs(LocationMemory.alldata) do
        table.insert(entries, { id = id, t = (entry and entry.last_access) or 0 })
    end
    if #entries <= MAX_SAVED_WORLDS then return end
    table.sort(entries, function(a, b) return a.t < b.t end)
    for i = 1, #entries - MAX_SAVED_WORLDS do
        LocationMemory.alldata[entries[i].id] = nil
    end
end

-- worldid（跨存档槽 + 地表/地下隔离）由 WorldUtil:GetWorldId() 统一提供，见 util/worldutil.lua。

local function SaveData(savestring)
    if not LocationMemory.data_loaded then
        -- 数据尚未加载，避免保存空数据覆盖
        return
    end
    local worldid = WorldUtil:GetWorldId()
    if worldid == nil or LocationMemory.worldid ~= worldid then
        return
    end
    local entry = LocationMemory.alldata[worldid]
    if not entry then
        entry = {}
        LocationMemory.alldata[worldid] = entry
    end
    entry.locations = saved_locations
    entry.wx78_bodynames = wx78_body_names
    entry.last_access = os.time() -- 标记最近游玩时间，用于上限淘汰
    EnforceMaxWorlds()
    FileSystem:SaveStringToFile(locationpatch, json.encode(LocationMemory.alldata), false)
end

local function LoadData(filepath, callback)
    FileSystem:LoadStringFromFile(filepath, function(load_success, str)
        local data = {}
        if load_success and string.len(str or "") > 0 then
            local success, decoded = pcall(json.decode, str)
            if not success then
                print("[Equipment Control] Failed to decode saved map locations: " .. tostring(decoded))
            elseif type(decoded) == "table" then
                data = decoded
            else
                print("[Equipment Control] Saved map locations did not contain a table.")
            end
        end
        callback(data)
    end)
end

local function AddMapLocation(name, x, z, iconatlas, icontex)
    local is_cave = TheWorld and TheWorld:HasTag("cave")
    table.insert(saved_locations, {
        name = name,
        x = x,
        z = z,
        iconatlas = iconatlas,
        icontex = icontex or "wortox_soul.tex",
        location_type = is_cave and "cave" or "surface",
    })
    SaveData("AddLocation")
end
GLOBAL.AddMapLocation = AddMapLocation

local function DeleteMapLocation(index)
    if saved_locations[index] then
        table.remove(saved_locations, index)
        SaveData("DeleteLocation")
        return true
    end
    return false
end
GLOBAL.DeleteMapLocation = DeleteMapLocation

-- 就地改名：由面板列表里的行内输入框回车提交。空名字视为放弃修改。
local function RenameMapLocation(index, name)
    local loc = saved_locations[index]
    if loc == nil then return false end
    if name == nil or name == "" then return false end
    loc.name = name
    SaveData("RenameLocation")
    return true
end
GLOBAL.RenameMapLocation = RenameMapLocation

local function GetSavedLocations()
    return saved_locations
end

-- 底盘命名：按 key 读写；传空名字即清除。改名后立即重建轮盘以便即时生效。
-- 值统一存 { n = 名字, x, z }：x/z 是这台底盘此刻的坐标（重登后按坐标重新挂名要用）。
-- 调用方不必操心坐标：x/z 留空时这里自己查，查不到就沿用旧值，绝不把已有锚点抹掉。
local GetChassisAnchor   -- 前置声明：定义在 GetWX78ChassisList 之后（那里才枚举得到坐标）

local function RecordName(v)
    if type(v) == "string" then return v end   -- 旧存档：裸字符串，无锚点
    if type(v) == "table" then return v.n end
    return nil
end

local function RawSetBodyName(key, name, x, z)
    if key == nil then return end
    key = tostring(key)
    if name == nil or name == "" then
        wx78_body_names[key] = nil
        return
    end
    local old = wx78_body_names[key]
    if x == nil and GetChassisAnchor ~= nil then
        x, z = GetChassisAnchor(key)
    end
    if x == nil and type(old) == "table" then
        x, z = old.x, old.z
    end
    -- s = 这条是"当前机身"（玩家自己在驾驶的那台），不是摆在地上的备份底盘。
    -- 存档是整片分片共用的，别的玩家驾驶过的机身也会留在同一张表里；标出来，
    -- 重挂名时才不会把"别人的当前机身"当成一台被换掉的备份底盘去匹配坐标。
    local is_self = ThePlayer ~= nil and key == tostring(ThePlayer.GUID)
    wx78_body_names[key] = { n = name, x = x, z = z, s = is_self or nil }
end

local function GetWX78BodyName(key)
    if key == nil then return nil end
    return RecordName(wx78_body_names[tostring(key)])
end

local function SetWX78BodyName(key, name)
    if key == nil then return end
    RawSetBodyName(key, name)
    SaveData("WX78BodyName")
    if RebuildMapWheel ~= nil then
        RebuildMapWheel()
    end
end
GLOBAL.SetWX78BodyName = SetWX78BodyName
GLOBAL.GetWX78BodyName = GetWX78BodyName

local function GetLocationsForCurrentShard()
    local is_cave = TheWorld and TheWorld:HasTag("cave")
    local locations = {}
    for _, location in ipairs(saved_locations) do
        if not location.location_type
            or (is_cave and location.location_type == "cave")
            or (not is_cave and location.location_type == "surface") then
            table.insert(locations, location)
        end
    end
    return locations
end

local function FormatLocationText(location)
    if not location then return "" end
    local name = location.name or "未命名"
    local coords = string.format("%.1f, %.1f", location.x or 0.0, location.z or 0.0)
    return name .. ": " .. coords
end

-------------------------------------------------------------------------------
-- 能力闸门：不硬编码 prefab。Wortox 原生拥有 CanSoulhop；噬空勋章通过重写
-- CanSoulhop + 添加 soulstealer / medal_map_blinker 标签授予任意角色该能力。
-------------------------------------------------------------------------------
local function CanMapTeleport(owner)
    if owner == nil then return false end
    if owner.CanSoulhop and owner:CanSoulhop() then return true end
    return owner:HasTag("soulstealer") or owner:HasTag("medal_map_blinker")
end

-------------------------------------------------------------------------------
-- WX-78 备份底盘远程换身（官方动作 ACTIONS.SWAPBODIES_MAP / "Transfer Consciousness"）
-------------------------------------------------------------------------------
-- 思路取自 WX-78辅助(3712173567) 的 body_bind，但数据源改为官方渠道，不依赖其存档格式。
-- 官方校验见 actions.lua:6810 SWAPBODIES_MAP.maponly_checkvalidpos_fn：
--   1) act.doer.wx78_classified 存在 → 必须是 WX-78；
--   2) skilltreeupdater:IsActivated("wx78_remotebodyswap") → 必须点了"远程换身"技能点；
--   3) 目标点 TUNING.SKILLS.WX78.REMOTEBODYSWAP_DETECTION_RADIUS(=20, tuning.lua:7502) 内
--      需存在 wx78_backupbody 地图图标 → 会自动吸附到最近的身体，故坐标无需绝对精确；
--   4) Wagstaff 竞技场屏障开启时会阻断跨屏障换身（判 fights Rank 内外不一致则失败）。
-- 结论：客户端只判"角色 + 技能"两项；身体是否存在、能否换身交给服务端裁决
--（actions.lua:6845 还会校验 mapent._target 与 activatable:CanActivate/DoActivate）。
local WX78_BODY_TEX = "wx78_backupbody.tex"  -- 官方 inventoryimages4.xml 中的库存图标

local function IsWX78(owner)
    return owner ~= nil and owner.prefab == "wx78" and owner.wx78_classified ~= nil
end

-- 客户端可读到 skilltreeupdater：官方 widget 如
-- widgets/upgrademodulesdisplay_inspecting.lua:236 直接读 ThePlayer.components.skilltreeupdater。
-- 取不到时按"放行"处理，让服务端最终拒绝，避免版本差异把可用技能误判为不可用。
local function CanWX78BodySwap(owner)
    if not IsWX78(owner) then return false end
    local updater = owner.components and owner.components.skilltreeupdater
    if updater == nil or updater.IsActivated == nil then return true end
    return updater:IsActivated("wx78_remotebodyswap") ~= false
end

-- 所有权/可见性过滤：完全对齐官方 FindClosestMapIconInRangeSq 对 restricted_doer 的处理
--（simutil.lua:891-902）——客户端的 GlobalMapIconsDB 已按 classified 裁剪过，
-- 这里再叠一层 MiniMapEntity  Restricted 判断，确保"个数"只统计本人可用的底盘。
local function IsBodyIconVisibleTo(inst, doer)
    if inst == nil or doer == nil then return true end
    if inst.MiniMapEntity then
        return inst.MiniMapEntity:EntityHasRestriction(doer.GUID)
    end
    return true -- 无 MiniMapEntity 无法本地过滤，交由服务端最终裁决
end

-- 动态枚举当前分片的备份底盘：直接用官方 GlobalMapIconsDB（simutil.lua:851），
-- 与 mapscreen.lua:988 的 wx78_backupbody 分支同源；地图图标 inst 自身已定位在身体处，
-- 故取其坐标即可，无需 body._target（未加载区域里 _target 可能不存在）。
-- 换身是"位置互换"（wx78_backupbody.lua:504-519 双向 Teleport），
-- 所以传送后旧底盘会落到玩家原来的位置 —— 无需任何本地记账，
-- 下次打开轮盘（每次开都会 RebuildMapWheel）自然会把它列为新的传送点。
local function GetWX78BackupBodies()
    local bodies = {}
    local db = GLOBAL.GlobalMapIconsDB
    if db == nil or db.prefabs == nil then return bodies end
    local bin = db.prefabs["wx78_backupbody"]
    if bin == nil then return bodies end
    for inst, _ in pairs(bin) do
        if inst ~= nil and inst:IsValid() and inst.Transform ~= nil
            and IsBodyIconVisibleTo(inst, ThePlayer) then
            local x, y, z = inst.Transform:GetWorldPosition()
            table.insert(bodies, { x = x, y = y, z = z, guid = inst.GUID })
        end
    end
    -- 按 GUID 排序保证顺序稳定，避免每次重建轮盘时格子位置跳动
    table.sort(bodies, function(a, b) return a.guid < b.guid end)
    return bodies
end

-- 圆心列表里的"底盘"项：备份底盘 + 自身机身。
-- 二者都只能改名；自身机身不可传送（换了身它才会变成可传送的备份底盘），
-- 且按需求它们都不作为外环轮盘的格子出现。
-- 【必须定义在 CanWX78BodySwap / GetWX78BackupBodies 之后】——
-- 这两个都是文件内的 local 函数，若本块放在它们之前，Lua 会把它当全局查找，
-- 运行时报 "attempt to call global 'CanWX78BodySwap' (a nil value)"。
local SELF_CHASSIS_KEY = "self"

local function GetWX78ChassisList()
    local list = {}
    if ThePlayer == nil or not CanWX78BodySwap(ThePlayer) then return list end
    -- 迁移旧存档：历史上“自身”用静态键 "self" 记录，现统一改为按当前机身实体 GUID 记录，
    -- 使所有底盘（含当前机身）都按物理实体稳定命名，避免重载/换身后名字错配。
    if wx78_body_names[SELF_CHASSIS_KEY] ~= nil then
        local selfguid = tostring(ThePlayer.GUID)
        if wx78_body_names[selfguid] == nil then
            wx78_body_names[selfguid] = wx78_body_names[SELF_CHASSIS_KEY]
            -- 迁过来的这条就是"当前机身"，补上 s 标记（见 RawSetBodyName），
            -- 否则它以后会被重挂名当成一台散落的备份底盘去匹配坐标。
            if type(wx78_body_names[selfguid]) == "table" then
                wx78_body_names[selfguid].s = true
            end
        end
        wx78_body_names[SELF_CHASSIS_KEY] = nil
        SaveData("WX78ChassisName")
    end
    for _, body in ipairs(GetWX78BackupBodies()) do
        table.insert(list, {
            key = tostring(body.guid),
            name = GetWX78BodyName(body.guid),
            x = body.x,
            z = body.z,
            is_self = false,
        })
    end
    local px, py, pz = ThePlayer.Transform:GetWorldPosition()
    table.insert(list, {
        key = tostring(ThePlayer.GUID),
        name = GetWX78BodyName(ThePlayer.GUID),
        x = px,
        z = pz,
        is_self = true, -- 当前机身：只能改名，不能传送（换身后它才会变成可传送的备份底盘）
    })
    return list
end

local function SetWX78ChassisName(key, name)
    if key == nil then return false end
    RawSetBodyName(key, name)
    SaveData("WX78ChassisName")
    if RebuildMapWheel ~= nil then
        RebuildMapWheel()
    end
    return true
end
GLOBAL.GetWX78ChassisList = GetWX78ChassisList
GLOBAL.SetWX78ChassisName = SetWX78ChassisName

-- 查一台底盘此刻的坐标 —— 就是上面 RawSetBodyName 留空时用的那个锚点查询。
-- 直接复用 GetWX78ChassisList：它已经把"备份底盘 + 当前机身"都按 key 列全了。
GetChassisAnchor = function(key)
    if key == nil then return nil end
    key = tostring(key)
    for _, c in ipairs(GetWX78ChassisList()) do
        if c.key == key then return c.x, c.z end
    end
    return nil
end

-------------------------------------------------------------------------------
-- 换身时的名字对调：名字跟着"看得见的那台机身"走
-------------------------------------------------------------------------------
-- 官方换身（wx78_backupbody.lua:311 OnActivateFn）不是"销毁一台、再新建一台"，而是一次双方互换：
--   :504-519  你和那台底盘双向 Teleport —— 你 → 它原来的位置 P，它 → 你原来的位置 Q；
--   :495-503  双方 skinner 互换外壳皮肤、upgrademoduleowner 互换升级模块。
--   整个函数里没有 inst:Remove()：被点中的那台底盘【不会消失】，它的地图形标（挂在同一实体上，
--   globalmapicon.lua 给图标挂了跟随目标的 updatelooper）跟着它一起挪到 Q。
--   （TryToSpawnPossessedBody 里的 inst:Remove() 只走容器 / 断电 / 格斯特笼那些分支，换身路径不经过。）
--
-- 既然实体没被销毁，名字就【不需要检测】，只需要在点中的那一刻把两个键上的记录对调：
--   P 处现在的"你"长得就是那台底盘 → 拿走它的名字；
--   Q 处那一台长得就是你原来那台   → 拿走你旧机身的名字。
-- 这与外观一一对应，也就是"传送到已命名的备份就用这个备份的名字"。
--
-- 唯一的例外是服务端拒绝了这次换身（技能没激活 / 屏障阻断 / 目标已失效）：那时人不会出现在 P，
-- 名字必须换回来。判据只看坐标（成功了人必然站在 P 上），用一次性的 DoTaskInTime 核实，不是轮询。
local SWAP_NAME_RADIUS_SQ = 20 * 20   -- 官方吸附半径 20（TUNING.SKILLS.WX78.REMOTEBODYSWAP_DETECTION_RADIUS）
-- 换身后隔多久核实坐标。特意给得宽松：换身是服务端先改位置再同步回客机，0.1 秒有可能还没到；
-- 而"该回滚没回滚"只是名字暂时错位（再改一次名即可），"不该回滚却回滚了"恰好是用户报的那个 bug，
-- 所以宁可慢一点。0.5 秒内人走不出 20 单位（步行约 5/秒），不会把成功误判成失败。
local SWAP_NAME_VERIFY_DELAY = 0.5

local pending_swap_names = nil

local function DistSq(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return dx * dx + dz * dz
end

-- 整条记录写入 / 清除。回滚时要原样写回，所以这里不做任何坐标补查（这是它与 RawSetBodyName 的区别）。
-- 旧存档的裸字符串一并兼容，按 { n = 字符串 } 处理。
local function SetBodyRecord(key, rec)
    if key == nil then return end
    key = tostring(key)
    if type(rec) == "string" then
        rec = { n = rec }
    end
    if rec == nil or rec.n == nil or rec.n == "" then
        wx78_body_names[key] = nil
    else
        wx78_body_names[key] = { n = rec.n, x = rec.x, z = rec.z, s = rec.s }
    end
end

-- 前置声明：SwapChassisNames 里要用到它（它定义在下面，晚一点没关系）
local VerifySwapPosition

-- 点中某台备份底盘、发出换身指令的那一刻：立刻把两个键上的名字对调。
-- 这一步是确定性的 —— 不检测、不等待、不轮询；换身成不成立都先按"成立"写，0.5 秒后再用坐标兜一次底。
local function SwapChassisNames(body)
    if body == nil or ThePlayer == nil or ThePlayer.Transform == nil then return end
    local self_key = tostring(ThePlayer.GUID)
    local target_key = tostring(body.guid)
    if target_key == self_key then return end   -- 自身不进外环，理论上到不了这里

    local px, _, pz = ThePlayer.Transform:GetWorldPosition()   -- Q：我原来的位置，那台底盘要落到的地方

    -- 换身前把两条原记录抄下来，供服务端拒绝时原样回滚
    local target_rec = wx78_body_names[target_key]
    local self_rec = wx78_body_names[self_key]

    -- 锚点必须显式写成"换身后"的位置：重登后按坐标重挂名（ReanchorBodyNames）靠的就是它，
    -- 沿用旧值会把名字挂到隔壁那台底盘上。self 这条带上 s 标记（当前机身，见 RawSetBodyName）。
    SetBodyRecord(self_key, { n = RecordName(target_rec), x = body.x, z = body.z, s = true })
    SetBodyRecord(target_key, { n = RecordName(self_rec), x = px, z = pz })
    SaveData("WX78SwapNames")

    -- 上一次的核实还没跑完就被新一次点击顶掉（0.5 秒内连点两次）：直接作废上一笔。
    -- 名字已经按新的一笔写好了，再去回滚旧的那笔反而是错的。
    pending_swap_names = {
        self_key = self_key,
        target_key = target_key,
        self_rec = self_rec,
        target_rec = target_rec,
        target_x = body.x,   -- P：换身成功后我应该站的地方
        target_z = body.z,
    }
    if TheWorld ~= nil then
        TheWorld:DoTaskInTime(SWAP_NAME_VERIFY_DELAY, VerifySwapPosition)
    else
        VerifySwapPosition()
    end
end

-- 一次性核实（不是轮询）：换身成功的话，我此刻应该正站在那台底盘原来的位置 P 上 —— 官方就是双方互换位置。
--   在 P 上（或读不到坐标）⇒ 对调后的名字保持不动；
--   明显不在 P ⇒ 服务端拒绝了这次换身，把两条记录原样写回去。
-- 注意这里用赋值而不是 local function：SwapChassisNames 捕获的是上面那句前置声明的那个 local，
-- 若这里再写 local 就会造出一个新局部，前者永远是 nil。
VerifySwapPosition = function()
    local p = pending_swap_names
    if p == nil then return end
    pending_swap_names = nil   -- 只算一次，先清账

    if ThePlayer == nil or ThePlayer.Transform == nil then
        return   -- 拿不到坐标就不回滚：宁可留着对调后的名字，也不要乱回滚
    end
    local px, _, pz = ThePlayer.Transform:GetWorldPosition()
    if DistSq(px, pz, p.target_x, p.target_z) <= SWAP_NAME_RADIUS_SQ then
        return   -- 人已经站到 P 上了，换身确实发生了
    end

    -- 回滚：两条记录都写回点击前抄下的原值（原本没名字的就还原成没名字）
    SetBodyRecord(p.self_key, p.self_rec)
    SetBodyRecord(p.target_key, p.target_rec)
    SaveData("WX78SwapNames")
    if RebuildMapWheel ~= nil then
        RebuildMapWheel()
    end
end

-------------------------------------------------------------------------------
-- 重登后按坐标重新定位备份名字
-------------------------------------------------------------------------------
-- 名字以地图形标 GUID 为键，而图标每次进游戏都是新实体、新 GUID（globalmapicon.lua:335
-- persists = false），上一局存下来的键这一局全是死键 —— 名字会集体退化成「未命名」。
-- 但备份底盘是钉在地上不会动的，于是记账时把坐标一起存下来（见 RawSetBodyName），
-- 进游戏后按"哪台底盘离这个坐标最近"把名字重新挂到本局的新图标键上。
-- 放在每次重建轮盘时做：这时图标数据库必定已同步好（首次开轮盘/开面板即触发）。
local REANCHOR_RADIUS_SQ = 12 * 12   -- 底盘不挪窝，宽松即可；比换身的 20 收紧些，避免相邻底盘张冠李戴

local function ReanchorBodyNames()
    if ThePlayer == nil then return false end
    local bodies = GetWX78BackupBodies()
    if #bodies == 0 then return false end   -- 图标还没同步过来，等下次重建轮盘

    -- 已经有活键的底盘不参与匹配：一个键被本局的实体用着，就说明它不需要恢复，
    -- 更不能让一条旧记录把它的名字盖掉。也让本函数天然幂等（每台底盘最多被恢复一次）。
    local live = {}
    for _, b in ipairs(bodies) do
        local k = tostring(b.guid)
        if wx78_body_names[k] ~= nil then
            live[k] = true
        end
    end

    local self_key = tostring(ThePlayer.GUID)   -- 玩家 GUID 跨重登不变，永远不需要恢复
    -- 收集"死键 ↔ 底盘"的全部候选配对，按距离升序贪心配对（近者优先）。
    -- 注意：绝不在 pairs 遍历 wx78_body_names 的过程中写回它 —— Lua 只允许在遍历中改值或置 nil，
    -- 新增键是未定义行为（可能报 invalid key to 'next'）。故此处只收集，配对完再统一落地。
    local cands = {}
    for key, rec in pairs(wx78_body_names) do
        -- 跳过：本局自己的机身键、活键、无锚点的旧格式字符串、以及别的玩家驾驶的机身（rec.s）
        if key ~= self_key and not live[key] and type(rec) == "table"
            and not rec.s and rec.x ~= nil and rec.n ~= nil then
            for _, b in ipairs(bodies) do
                local bkey = tostring(b.guid)
                if not live[bkey] then
                    local dsq = DistSq(b.x, b.z, rec.x, rec.z)
                    if dsq <= REANCHOR_RADIUS_SQ then
                        table.insert(cands, { key = key, bkey = bkey, body = b, dsq = dsq })
                    end
                end
            end
        end
    end
    table.sort(cands, function(a, b) return a.dsq < b.dsq end)

    local changed = false
    local taken_key, taken_body = {}, {}
    for _, c in ipairs(cands) do
        if not taken_key[c.key] and not taken_body[c.bkey] then
            taken_key[c.key] = true
            taken_body[c.bkey] = true
            local nm = RecordName(wx78_body_names[c.key])
            wx78_body_names[c.key] = nil   -- 死键作废，免得下次再匹配一遍
            wx78_body_names[c.bkey] = { n = nm, x = c.body.x, z = c.body.z }
            changed = true
        end
    end
    if changed then
        SaveData("ReanchorBodyNames")
    end
    return changed
end

-------------------------------------------------------------------------------
-- 轮盘数据集（坐标项 + WX-78 底盘项 + 圆心管理按钮）
-------------------------------------------------------------------------------
-- 尺寸与官方 commandwheel 对齐思路：基础半径 140（比官方 175 更小，符合"轮盘太大"反馈），
-- 焦点半径略大于基础半径（+3），这样鼠标悬停时图标是轻微向外移，而不是向内缩，
-- 避免出现"图标移走→光标脱离→失焦弹回→再悬停"的反复上下跳动（官方用 175/178 同理）。
local WHEEL_RADIUS = 140
local WHEEL_FOCUS_RADIUS = 143

local function IsChinese()
    local code = rawget(GLOBAL, "LOC") and GLOBAL.LOC.GetLocaleCode() or "en"
    return code == "zh" or code == "zhr" or code == "zhs"
end

-------------------------------------------------------------------------------
-- 旅行面板（新增/删除/搜索坐标）
-------------------------------------------------------------------------------
local travel_panel = nil
function OpenTravelPanel(show_filters)
    local MapTravelPanel = require("screens/maptravelpanel")
    if travel_panel then
        travel_panel:Close()
        travel_panel = nil
    end

    local panel_strings = {
        FILTERS = IsChinese() and "坐标列表" or "Coordinate List",
        DETAILS = IsChinese() and "新增坐标" or "Add Coordinate",
        TITLE = IsChinese() and "坐标管理" or "Coordinate Manager",
        NO_LOCATION = IsChinese() and "未选择地点" or "No location selected",
        SEARCH_PLACEHOLDER = IsChinese() and "搜索坐标" or "Search coordinates",
        INPUT_PLACEHOLDER = IsChinese() and "输入坐标名称" or "Enter coordinate name",
        COORD_PLACEHOLDER = IsChinese() and "输入坐标 (例如: 100.5, 50.3)" or "Enter coordinates (e.g: 100.5, 50.3)",
        SAVE_BUTTON = IsChinese() and "保存坐标" or "Save Coordinate",
        SAVE_DESC = IsChinese()
            and "输入名称和坐标后点击保存\n留空坐标则使用当前位置"
            or "Enter a name and coordinates, then click save\nLeave coordinates empty to use current position",
    }

    local hud = ThePlayer and ThePlayer.HUD
    if hud then
        local on_locations_changed = function()
            RebuildMapWheel()
        end
        travel_panel = hud:AddChild(MapTravelPanel(
            ThePlayer,
            panel_strings,
            GetSavedLocations,
            DeleteMapLocation,
            RenameMapLocation,
            on_locations_changed,
            FormatLocationText,
            GetWX78ChassisList,
            SetWX78ChassisName
        ))
        travel_panel:SetPosition(0, 0)
        if show_filters then
            travel_panel:ToggleShowFilters(true)
        end
    end
end

-- 给某个 widget 垫一层"圆形底盘"（用于 B：逐格圆框、C：圆心框）。
-- 参照 Gesture Wheel 模组的清晰做法：用官方头像高清贴图 images/avatars.xml 的
--   avatar_bg.tex（圆形底盘填充）+ avatar_frame_white.tex（白色圆形描边圈，可染色）。
-- 关键：frame_d 为【固定】框直径，把高清贴图【下采样】到该尺寸（下采样=清晰、不糊），
-- 图标再缩放到 frame_d*icon_fit 坐在框内——不再用贴图原生大尺寸，避免图标被放大到几百像素而发糊/过大。
-- 层级：[disc 底, ring 描边, image 图标]。黑色风格：disc=近黑填充，ring=清晰可见的灰色描边（避免黑底黑环糊成一团）。
local function AddRoundBacking(w, frame_d, ring_tint, disc_tint, icon_fit)
    icon_fit = icon_fit or 0.58
    local disc = w:AddChild(Image("images/avatars.xml", "avatar_bg.tex"))
    disc:SetClickable(false)
    disc:SetTint(disc_tint[1], disc_tint[2], disc_tint[3], disc_tint[4])
    disc:SetSize(frame_d, frame_d)        -- 高清贴图下采样到固定框，保持清晰
    disc:MoveToBack()
    local ring = w:AddChild(Image("images/avatars.xml", "avatar_frame_white.tex"))
    ring:SetClickable(false)
    ring:SetTint(ring_tint[1], ring_tint[2], ring_tint[3], ring_tint[4])
    ring:SetSize(frame_d, frame_d)        -- 与底盘同尺寸贴合
    if w.image ~= nil then
        w.image:SetSize(frame_d * icon_fit, frame_d * icon_fit)
        w.image:MoveToFront()
    end
end

local function BuildWheelDataset()
    local items = {}
    -- 外环只列出"当前角色真正用得上"的那类目的地：
    --   有地图跳跃能力 → 列坐标项；有 WX-78 远程换身能力 → 列底盘项；
    --   两种能力都具备 → 全部显示；只有其一 → 只显示对应的那类。
    -- 圆心管理页不受此限制，仍显示全部已存坐标（走 GetSavedLocations，与本函数无关）。
    local locations = CanMapTeleport(ThePlayer) and GetLocationsForCurrentShard() or {}
    for _, loc in ipairs(locations) do
        local icontex = loc.icontex or WHEEL_TEX
        local iconatlas = loc.iconatlas or AtlasOf(icontex)
        local x, z = loc.x, loc.z
        table.insert(items, {
            label = loc.name or "未命名",
            atlas = iconatlas,
            normal = icontex,
            execute = function()
                -- 无灵魂跳跃能力时静默：不走传送逻辑、也不提示（保持与"—开启闸门"一致的静默风格）
                if CanMapTeleport(ThePlayer) then
                    -- 官方地图灵魂跳跃动作：服务端会校验 soulstealer/CanSoulhop，
                    -- 对 Wortox 与噬空勋章佩戴者均通过。
                    SendRPCToServer(RPC.DoActionOnMap, ACTIONS.BLINK_MAP.code, x, z, nil, nil)
                end
                return false -- 触发 OnExecute 关闭轮盘
            end,
            -- 逐格圆框（方案 B）：给每个坐标图标垫一张圆形底盘。
            -- 固定框直径 84（< 头像贴图原生 95px，纯下采样，清晰）、图标缩到 0.58（约 49px）坐在框内。
            -- 黑色风格：disc=近黑填充，ring=清晰可见的灰色描边（暗灰会糊成一体，故用 0.55 灰确保边界干脆）。
            postinit = function(w)
                if w.image ~= nil then
                    AddRoundBacking(w, 84, { 0.55, 0.55, 0.55, 1 }, { 0.02, 0.02, 0.02, 0.98 }, 0.58)
                end
            end,
        })
    end

    -- WX-78 备份底盘：满足"角色 + 远程换身技能"时，把每个备份底盘追加为轮盘项。
    -- 执行走官方统一入口 playercontroller:OnMapAction（playercontroller.lua:5237）：
    -- 它内部按 主机 / 纯客户端 / 预测客户端 三种情形分别处理（PushAction / 直发 RPC / preview_cb），
    -- 比自行拼 SendRPCToServer(RPC.DoActionOnMap, ...) 更稳。
    if CanWX78BodySwap(ThePlayer) then
        local bodies = GetWX78BackupBodies()
        for i, body in ipairs(bodies) do
            local nm = GetWX78BodyName(body.guid)
            local coords = string.format("(%.0f, %.0f)", body.x, body.z)
            local fallback = IsChinese()
                and string.format("备份底盘 %d %s", i, coords)
                or  string.format("Backup Body %d %s", i, coords)
            table.insert(items, {
                -- 已命名则显示名字+坐标；未命名退回"序号+坐标"
                label = nm and (nm .. " " .. coords) or fallback,
                atlas = AtlasOf(WX78_BODY_TEX),
                normal = WX78_BODY_TEX,
                execute = function()
                    local pc = ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller
                    if pc == nil then return false end
                    -- 点中的那一刻就把名字对调（见 SwapChassisNames）：名字跟着"看得见的那台机身"走
                    SwapChassisNames(body)
                    -- 只需给大致坐标：服务端会在半径 20 内吸附到最近的 wx78_backupbody
                    pc:OnMapAction(ACTIONS.SWAPBODIES_MAP.code, Vector3(body.x, 0, body.z), nil, nil)
                    return false -- 触发 OnExecute 关闭轮盘
                end,
                -- 与坐标项同款黑色圆框（固定 84 下采样、灰描边、图标 0.58）
                postinit = function(w)
                    if w.image ~= nil then
                        AddRoundBacking(w, 84, { 0.55, 0.55, 0.55, 1 }, { 0.02, 0.02, 0.02, 0.98 }, 0.58)
                    end
                end,
            })
        end

        -- 注意：自身（当前所在机身）按需求【不进外环】——
        -- 它只在圆心管理面板的列表里作为可改名的底盘项出现（见 GetWX78ChassisList）。
    end

    return items
end

local map_wheel = nil
local map_center_btn = nil

-- 统一关闭：隐藏圆心"坐标管理"按钮，并在轮盘已打开时关闭它。
-- 空坐标时轮盘的 Wheel:Open 会因 activeitems 为空而提前返回（不 Show、isopen 不置真），
-- 此时仍要能关闭圆心按钮，故单独管理其显隐。
local function CloseMapWheel()
    if map_center_btn ~= nil then
        map_center_btn:Hide()
    end
    if map_wheel ~= nil and map_wheel:IsOpen() then
        map_wheel:Close()
    end
end


function RebuildMapWheel()
    if map_wheel == nil then return end
    -- 收上一局留下的死键：重登后图标 GUID 全换新了，按坐标把名字重新挂回来。
    ReanchorBodyNames()
    local ds = BuildWheelDataset()
    map_wheel:SetItems(ds, WHEEL_RADIUS, WHEEL_FOCUS_RADIUS)
end
GLOBAL.RebuildMapWheel = RebuildMapWheel



-------------------------------------------------------------------------------
-- 轮盘挂载到 controls（官方 HUD 控件层），并加一个打开轮盘的 HUD 按钮
-------------------------------------------------------------------------------
AddClassPostConstruct("widgets/controls", function(self)
    -- 注意：不要用 self.owner ~= ThePlayer 来守卫——HUD 初次构建时 ThePlayer 可能尚未就绪，
    -- 会导致整段被 return 掉，按钮与轮盘永远建不出来（表现为 F7/图标全无反应）。
    -- Controls 永远只为本机玩家构建，故仅当 owner 为 nil 时才跳过。
    if self.owner == nil then return end

    -- Controls 会在玩家死亡重生 / 切换世界 / 穿梭分片时被重建（player_common 的 ActivateHUD
    -- 会重新 PushScreen 并 SetMainCharacter）。旧的 Controls 被 PopScreen 销毁，若仍缓存旧
    -- 轮盘实例，之后按指令轮盘键会对已销毁的 inst 调 SetClickable，触发 C 层崩溃。
    -- 因此每次重建都重新创建轮盘，绝不跨重建持有旧实例（旧实例已随旧 Controls 销毁，
    -- 此处仅丢弃 Lua 引用，不可再对其 Kill 以免二次释放）。
    map_wheel = nil

    -- 居中根节点：轮盘挂在 MIDDLE 锚点的根上，稳定显示在屏幕正中。
    -- 参照官方 commandwheelroot 做法；本机 HUD 坐标系原点在左下，直接 (0,0) 会跑到左下角。
    local wheelroot = self:AddChild(Widget("MapWheelRoot"))
    wheelroot:SetHAnchor(ANCHOR_MIDDLE)
    wheelroot:SetVAnchor(ANCHOR_MIDDLE)
    wheelroot:SetScaleMode(SCALEMODE_PROPORTIONAL)

    local wheel = wheelroot:AddChild(Wheel("MapWheel", self.owner, { ignoreleftstick = true }))
    wheel:Hide()
    wheel.OnCancel = CloseMapWheel
    wheel.OnExecute = CloseMapWheel
    map_wheel = wheel

    -- 整轮底盘：仿官方 SpellWheel 的 bg（playerhud.lua:1288 往 Wheel 加 UIAnim 并 MoveToBack）。
    -- 用官方通用白色圆 circle.tex（images/button_icons.xml，可染色）叠两层实现"带外环的圆盘"：

    -- 两者 SetClickable(false) 且 MoveToBack()，不挡格子点击；随 map_wheel 显隐自动同步。


    -- 圆心"坐标管理"按钮：独立于扇形格子，挂在 wheelroot 上（而非 wheel 自身），
    -- 这样即便没有已存坐标（Wheel:Open 因空数据集提前返回不显示）也能独立显隐。
    -- 点击：先关闭轮盘/按钮，再打开旅行面板（面板内含增删坐标）。
    local center_btn = wheelroot:AddChild(ImageButton(AtlasOf(WHEEL_TEX), WHEEL_TEX))
    center_btn:SetPosition(0, 0)
    center_btn:SetHoverText(IsChinese() and "坐标管理" or "Coordinate Manager", { offset_y = -45 })
    center_btn:SetOnClick(function()
        CloseMapWheel()
        OpenTravelPanel(true)
    end)
    center_btn:Hide()
    center_btn:MoveToFront()
    -- 圆心框（方案 C）：给"坐标管理"按钮垫一张圆形底盘，与逐格圆框（B）风格统一（黑色）。
    -- 固定框直径 90（≤ 原生 95px，不放大保持清晰）、图标缩到 0.6（约 54px）坐在框内。
    if center_btn.image ~= nil then
        AddRoundBacking(center_btn, 90, { 0.55, 0.55, 0.55, 1 }, { 0.02, 0.02, 0.02, 0.98 }, 0.6)
    end
    map_center_btn = center_btn

    -- ESC 关闭：空坐标时 Wheel 并未真正 isopen，其自身 OnControl 不会处理 CONTROL_CANCEL，
    -- 故在此拦截——只要圆心按钮可见，按 ESC 就关闭整个轮盘界面（含圆心按钮）。
    local OldOnControl = self.OnControl
    self.OnControl = function(self, control, down)
        if map_center_btn ~= nil and map_center_btn:IsVisible()
            and control == CONTROL_CANCEL and down then
            CloseMapWheel()
            return true
        end
        return OldOnControl(self, control, down)
    end

    -- 手柄：轮盘开启时用左摇杆导航
    local OldOnUpdate = self.OnUpdate
    self.OnUpdate = function(self, ...)
        OldOnUpdate(self, ...)
        if map_wheel ~= nil and map_wheel:IsOpen() then
            map_wheel:OnUpdate()
        end
    end
end)

-------------------------------------------------------------------------------
-- 按键：使用本模组独立的"坐标轮盘"键位（mod 配置里可重绑，默认 F7），
-- 而非劫持游戏本体的 CONTROL_CHARACTER_COMMAND_WHEEL。
-- 原因：官方"角色指令轮盘"对每个角色都会打开（含表情/玩家列表等），若我们复用
-- 同一个键，两个轮盘会同开互相打架（表现为按键"无反应"+ 与勋章授予的灵魂跳跃
-- 等官方指令轮盘内容重叠）。独立按键彻底避免重叠，官方指令轮盘恢复正常工作。
-- 键位注册见下方：优先用 KeybindService（尊重重绑/"禁用"且内置 HUD 守卫）；
-- 若新配置项尚未写入存档导致解析为 nil，则回退 F7 并自行加 HUD 守卫。
-------------------------------------------------------------------------------
-- 只开不关：R 键 / HUD 按钮只负责"打开"轮盘，绝不在再次按下时把它关掉。
-- 原因：原先 toggle 模式 + 偶数次单击会以"关闭"收尾，且打开瞬间格子图标可能为空，
-- 用户看不到任何东西，于是反复按 → 最终停在关闭态，表现为"按了没反应/什么都没出现"。
-- 关闭改由选坐标（OnExecute）或 ESC（OnCancel）完成。
local function OpenMapWheel()
    if ThePlayer == nil or map_wheel == nil then
        return
    end
    -- 灵魂状态（ghost）下禁止打开：官方 command wheel 也对 playerghost 做禁用处理。
    if ThePlayer:HasTag("playerghost") then
        return
    end
    -- R 作为开关：若轮盘或圆心"坐标管理"按钮已显示，则先关闭（即便能力丢失也允许关，避免卡住）；否则打开。
    if map_wheel:IsOpen() or (map_center_btn ~= nil and map_center_btn:IsVisible()) then
        CloseMapWheel()
        return
    end
    -- 能力闸门：既无地图跳跃能力（Wortox 原生 / 噬空勋章）、也无 WX-78 远程换身能力的角色
    -- 直接静默返回——不打开、不提示。任一能力具备即可打开轮盘。
    if not CanMapTeleport(ThePlayer) and not CanWX78BodySwap(ThePlayer) then
        return
    end
    RebuildMapWheel()
    -- 圆心"坐标管理"按钮始终显示：即便没有已存坐标（扇形数据集为空），
    -- Wheel:Open 会因 activeitems 为空提前返回而不显示，但圆心按钮仍可独立弹出，
    -- 便于用户进入面板重新增删坐标。
    if map_center_btn ~= nil then
        -- 圆心悬停提示：两句 —— 第一句是"你现在驾驶的机身叫什么"（换身后名字会跟着机身走），
        -- 第二句是入口说明。外环每一格各自带着"名字 + 坐标"的悬停标签，二者互不干扰。
        local self_name = GetWX78BodyName(ThePlayer.GUID)
        local tip = IsChinese()
            and string.format("当前机身：%s\n坐标管理（可给机身改名）", self_name or "未命名")
            or  string.format("Current Chassis: %s\nCoordinate Manager (rename)", self_name or "Unnamed")
        map_center_btn:SetHoverText(tip, { offset_y = -45 })
        map_center_btn:Show()
    end
    local ds = map_wheel.items["root"]
    if ds ~= nil and #ds > 0 then
        map_wheel:Open()
    end
end

-- 始终注册处理器（供 confighud 的"坐标轮盘"按钮经 KeybindService:Trigger 复用）；
-- F 键已自 modinfo 解绑（默认 NONE），此处不再回退 F7。
KeybindService:AddKey("MAP_WHEEL", OpenMapWheel)

-------------------------------------------------------------------------------
-- 世界初始化时加载坐标存档
-------------------------------------------------------------------------------
AddPrefabPostInit("world", function(world)
    local player_activated = false
    local function ActivateWorldData()
        if not player_activated or not LocationMemory.file_loaded
            or not world:IsValid() or TheWorld ~= world then
            return
        end
        local worldid = WorldUtil:GetWorldId()
        if not worldid or (LocationMemory.data_loaded and LocationMemory.worldid == worldid) then
            return
        end
        LocationMemory.worldid = worldid
        local entry = LocationMemory.alldata[worldid]
        if entry and entry.locations then
            saved_locations = entry.locations
        else
            saved_locations = {}
            LocationMemory.alldata[worldid] = { locations = saved_locations }
        end
        wx78_body_names = (entry and entry.wx78_bodynames) or {}
        LocationMemory.alldata[worldid].last_access = os.time() -- 标记最近游玩
        LocationMemory.data_loaded = true
    end
    LocationMemory.activate_world_data = ActivateWorldData
    world:ListenForEvent("playeractivated", function()
        player_activated = true
        ActivateWorldData()
    end)

    if not LocationMemory.file_loaded and not LocationMemory.file_loading then
        LocationMemory.file_loading = true
        LoadData(locationpatch, function(data)
            LocationMemory.alldata = data
            LocationMemory.file_loading = false
            LocationMemory.file_loaded = true
            if LocationMemory.activate_world_data ~= nil then
                LocationMemory.activate_world_data()
            end
        end)
    end

    world:WatchWorldState("cycles", function(inst)
        SaveData("cycles")
    end)
end)

return function() end
