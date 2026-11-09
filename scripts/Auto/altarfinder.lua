-- 祭坛定位：右键天体探测仪/勋章宝藏探测仪 -> 扫描底座 -> 交点标记
local Say = require "util/say"

-- 顶层状态：顶层注册的 mapwidget hook 闭包需要读写这些 upvalue
local mark_x, mark_y
local ground_marker = nil

-- 小地图图标（顶层注册，统一规范）
-- MapWidget 只在 screens/mapscreen.lua:20 打开地图时按需新建，
-- 此前放在 Init()（playeractivated）里注册属"侥幸可用"——依赖目标恰好晚于该事件才创建；
-- 统一提到加载期注册，消除这层隐性依赖。
AddClassPostConstruct("widgets/mapwidget", function(self)
    if not mark_x then return end
    local mark = self:AddChild(Image("minimap/minimap_data.xml", "messagebottletreasure_marker.png"))
    local old = self.OnUpdate
    self.OnUpdate = function(self, ...)
        old(self, ...)
        local half_x, half_y = RESOLUTION_X / 2, RESOLUTION_Y / 2
        local sw, sh = TheSim:GetScreenSize()
        local mx, my = TheWorld.minimap.MiniMap:WorldPosToMapPos(mark_x, mark_y, 0)
        mark:SetPosition(((mx * half_x) + half_x) / RESOLUTION_X * sw,
                        ((my * half_y) + half_y) / RESOLUTION_Y * sh)
        mark:SetScale(1 - require("easing").outExpo(TheWorld.minimap.MiniMap:GetZoom() - 1, 0, 0.75, 8))
    end
end)

-- 计算交点 + 地面标记
local function CalcIntersection()
    local bases = {}
    local x, _, z = ThePlayer.Transform:GetWorldPosition()
    for _, ent in ipairs(TheSim:FindEntities(x, 0, z, 40, nil, {"INLIMBO"})) do
        if ent.prefab == "archive_resonator_base" or ent.prefab == "medal_resonator_base" then
            bases[#bases + 1] = ent
        end
    end
    if #bases < 2 then
        Say("Equipment Control：需要两座箭头底座")
        return false
    end
    local b1, b2 = bases[1], bases[2]
    local x1, _, z1 = b1.Transform:GetWorldPosition()
    local x2, _, z2 = b2.Transform:GetWorldPosition()
    local r1 = math.rad(b1:GetRotation() - 90 + 180)
    local r2 = math.rad(b2:GetRotation() - 90 + 180)
    local m1, m2 = -math.tan(r1), -math.tan(r2)
    if m1 == m2 then return false end
    local c1, c2 = z1 - m1 * x1, z2 - m2 * x2
    local x = (c2 - c1) / (m1 - m2)
    mark_x, mark_y = x, m1 * x + c1

    if ground_marker then ground_marker:Remove() end
    ground_marker = SpawnPrefab("wurt_tentacle_warning")
    if ground_marker then
        ground_marker.Transform:SetPosition(mark_x, 0, mark_y)
        ground_marker.entity:AddMiniMapEntity()
        ground_marker.MiniMapEntity:SetIcon("pirate_stash.png")
        ground_marker.MiniMapEntity:SetPriority(11)
        ground_marker.MiniMapEntity:SetDrawOverFogOfWar(true)
        ground_marker.MiniMapEntity:SetIsProxy(true)
        ground_marker.MiniMapEntity:SetEnabled(true)
    end

    ThePlayer.HUD.controls:ShowMap(Vector3(mark_x, 0, mark_y))
    Say("Equipment Control：已标记宝藏交点")
    return true
end

-- 覆写 inventory_replica 的 InspectItemFromInvTile（同为类级补丁，一并提到加载期）
local InventoryReplica = require("components/inventory_replica")
local oldInspect = InventoryReplica.InspectItemFromInvTile
function InventoryReplica:InspectItemFromInvTile(item, ...)
    if ThePlayer and item and (item.prefab == "archive_resonator_item" or item.prefab == "medal_resonator_item") then
        CalcIntersection()
        return
    end
    return oldInspect(self, item, ...)
end
