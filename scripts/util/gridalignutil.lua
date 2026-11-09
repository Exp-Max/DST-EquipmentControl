-------------------------------------------------------------------------------
-- 网格对齐工具（供 Auto/gridalign 及其它模块复用）
--
-- 只做纯计算，不挂任何 hook、不产生每帧开销。
--
-- 【全局访问统一约定】（见 scripts/Auto/gridalign.lua 顶部与 util/actionutil.lua:521）
--   本文件走 require 加载，运行环境就是游戏全局表 _G，**GLOBAL 在这里不存在**，
--   所以一律用裸全局（TheWorld / TUNING / TILE_SCALE）——与 worldutil / config.lua 一致。
--   防「未定义」的正确手段不是 rawget 包装（裸读本来就不会报错，取不到就是 nil），
--   而是：① 全部在函数体内懒读，不在文件顶层读（避开加载期尚未就绪）；
--         ② 关键项 or 兜底默认值。
--
-- 【计算量控制】
--   * 世界原点按 TheWorld 缓存成标量（不建表、不查表），只在换世界时重算一次
--   * SnapAxis 内用一次除法取倒数，换两次乘法，避免两次除法
--   * 真正的每帧路径（placer 吸附）不经过本工具，由 Auto/gridalign.lua 内联算术
--
-- 官方依据（data/databundles/scripts/components/placer.lua）：
--   CreateOffsetCache: worldoffsetx/z = 瓦片中心 + TILE_SCALE*0.5（即瓦片角点）
--   GetAxisAlignedPlacementTransform: floor((x-worldoffsetx)*intervals) + 0.5
--     —— 这个硬编码 +0.5 使落点永远在「格子中心」，是本体网格不在网格线上的根因。
--   另外官方 268 行 z 也减了 worldoffsetx（应为 worldoffsetz），本工具按各自 origin 修正。
-------------------------------------------------------------------------------

local GridAlignUtil = {}

local DEFAULT_TILE_SCALE = 4   -- 官方 constants.lua: TILE_SCALE = 4
local DEFAULT_INTERVALS  = 1   -- 官方 tuning.lua: AXISALIGNEDPLACEMENT_INTERVALS = 1

-------------------------------------------------------------------------------
-- 世界原点：瓦片中心 + 半格 => 瓦片角点（网格线交叉点）
-- 同一世界内恒定 => 缓存成标量，换世界（地表/洞穴）时才重算
-------------------------------------------------------------------------------
local _cached_world = nil
local _ox, _oz = 0, 0

local function GetTileScale()
    return TILE_SCALE or DEFAULT_TILE_SCALE
end

function GridAlignUtil:GetTileScale()
    return GetTileScale()
end

function GridAlignUtil:GetWorldOffset()
    local w = TheWorld                       -- 懒读：加载期可能尚未就绪
    if w == nil or w.Map == nil then return 0, 0 end
    if _cached_world ~= w then
        local ts = GetTileScale()
        local cx, cy, cz = w.Map:GetTileCenterPoint(0, 0, 0)
        _cached_world = w
        _ox = cx + ts * 0.5
        _oz = cz + ts * 0.5
    end
    return _ox, _oz
end

-------------------------------------------------------------------------------
-- 核心吸附。intervals = 每游戏单位的格数（官方 TUNING.AXISALIGNEDPLACEMENT_INTERVALS）
-- vertex=true  -> 取整到整数倍，落在网格线交叉点上
-- vertex=false -> 官方原生行为，落在格子中心
-------------------------------------------------------------------------------
function GridAlignUtil:SnapAxis(x, z, intervals, ox, oz, vertex)
    if intervals == nil or intervals == 0 then return x, z end
    local inv = 1 / intervals                -- 一次除法换两次乘法
    if vertex then
        return math.floor((x - ox) * intervals + 0.5) * inv + ox,
               math.floor((z - oz) * intervals + 0.5) * inv + oz
    end
    return (math.floor((x - ox) * intervals) + 0.5) * inv + ox,
           (math.floor((z - oz) * intervals) + 0.5) * inv + oz
end

-------------------------------------------------------------------------------
-- 官方当前档位（懒读 TUNING；会随官方网格切换变化，故不缓存）
-- 来源：官方 componentutil.lua:848 UpdateAxisAlignmentValues 会同步写入
--       TUNING.AXISALIGNEDPLACEMENT_INTERVALS；refreshaxisalignedplacementintervals
--       只用于 placer 重建 offset cache，本工具未缓存档位故无需监听。
-------------------------------------------------------------------------------
function GridAlignUtil:GetIntervals()
    local t = TUNING
    return (t and t.AXISALIGNEDPLACEMENT_INTERVALS) or DEFAULT_INTERVALS
end

-- 无 placer 的场景（丢弃等）：官方当前档位 + 缓存的世界原点
function GridAlignUtil:SnapWorld(x, z, vertex)
    local ox, oz = self:GetWorldOffset()
    return self:SnapAxis(x, z, self:GetIntervals(), ox, oz, vertex)
end

-------------------------------------------------------------------------------
-- 船上（平台）处理：官方 placer.lua:442-449 的船上逻辑只处理「旋转」朝向，
-- 吸附原点仍然是世界原点，导致船移动后网格不跟随。
-- 这里照搬建筑对齐 Pro 的做法：人在平台上且落点也在平台上时，
-- 改用「平台中心」当吸附原点，网格随船移动。
-- entity = 玩家（playercontroller.inst）或建造者（placer.builder）
-------------------------------------------------------------------------------
function GridAlignUtil:GetPlatformOrigin(x, z, entity)
    if entity == nil or entity.GetCurrentPlatform == nil then return nil end
    if entity:GetCurrentPlatform() == nil then return nil end          -- 人不在船上
    local map = TheWorld and TheWorld.Map
    if map == nil then return nil end
    local platform = map:GetPlatformAtPoint(x, z)                      -- 落点也在船上
    if platform == nil then return nil end
    local px, py, pz = platform.Transform:GetWorldPosition()
    return px, pz
end

-- 统一入口：在船上用船中心，否则用世界原点
function GridAlignUtil:SnapWorldPlatform(x, z, vertex, entity)
    local px, pz = self:GetPlatformOrigin(x, z, entity)
    if px ~= nil then
        return self:SnapAxis(x, z, self:GetIntervals(), px, pz, vertex)
    end
    return self:SnapWorld(x, z, vertex)
end

-------------------------------------------------------------------------------
-- 档位换算：官方档位表用「每游戏单位格数」，一格的世界尺寸 = 1 / intervals
-- 一个瓦片 = TILE_SCALE 世界单位，故每瓦片格数 = TILE_SCALE * intervals
-- （仅加载期用于换算 16x16，无运行时开销）
-------------------------------------------------------------------------------
function GridAlignUtil:CellsPerTileToIntervals(cells_per_tile)
    if cells_per_tile == nil or cells_per_tile == 0 then return nil end
    return cells_per_tile / GetTileScale()
end

return GridAlignUtil
