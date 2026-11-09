-------------------------------------------------------------------------------
-- WX-78 无人机派遣：按 rmb.action 白名单接管，强制官方地图动作发送。
--
-- 显示层（通道 D）：Alt 反转 / 注入标签——WX-78 运输机空→运送、满→收回；
--   普通角色只注入运送（官方 candismantle / deployable 均要 batteryuser，收回是点不动的假动作）；
--   侦察机→探索。
-- 点击层（通道 A）：仅 STARTMAPDELIVER / MAPSCOUTSELECT_MAP 接管，
--   一律 PullUpMap(机, MAPDELIVER_MAP)；其余放行，显示与执行同源。
-- 绕过：MAPDELIVER_MAP 跳过 StartMapAction 的 batteryuser / required_skill /
--   空门槛，直达 SendToPoint；服务端只查飞行路径。
--   运输机：WX-78 满机无条件绕过，空机收回放行，普通角色只有 Alt 运送一条路。
--   侦察机：官方世界动作被 mapscout 标签排除，改借通用的 MAPDELIVER_MAP.fn；
--   只认鼠标精确指向的实体（automedal.lua:2079 同法），不扫描世界。
--   落点须已探索（无 map_works_on_unexplored），探图仍归 owner。
--   满→收回的 NOTEMPTY 在服务端，纯客户端绕不过，保留此限制。
-------------------------------------------------------------------------------
local EC_ALT_REVERSE_ENABLED = true

local DELIVERY_LARGE = "wx78_drone_delivery"
local DELIVERY_SMALL = "wx78_drone_delivery_small"
local SCOUT = "wx78_drone_scout"

local function IsDeliveryDrone(entity)
    return entity ~= nil and entity:IsValid()
        and (entity.prefab == DELIVERY_LARGE or entity.prefab == DELIVERY_SMALL)
end

local function IsScout(entity)
    return entity ~= nil and entity:IsValid() and entity.prefab == SCOUT
end

local function CanSend(entity)
    if IsScout(entity) then return true end
    if not IsDeliveryDrone(entity) or entity:HasTag("flying") then return false end
    local container = entity.replica and entity.replica.container
    return container ~= nil and container:CanBeOpened()
end

local function RegisterPlayerHandlers(player)
    if player ~= ThePlayer or player._ec_dispatch_handlers
        or player.components == nil or player.components.playercontroller == nil
        or player.replica == nil or player.replica.inventory == nil then
        return
    end
    player._ec_dispatch_handlers = true

    ActionUtil:RegisterRightClickHandler(player, -100, function(_, act, down)
        if not down or player ~= ThePlayer or TheInput == nil then
            return
        end
        -- 兼容裸 ACTIONS.xxx 与 BufferedAction（quickdeploy.lua:178 同口径）
        -- act 可为 nil（原版无世界动作，如未 Alt 右键侦察机），须在取 target 前退出
        local actiondef = type(act) == "table" and (act.action or act) or nil
        local wants_scout = actiondef == ACTIONS.MAPSCOUTSELECT_MAP
        if not wants_scout and actiondef ~= ACTIONS.STARTMAPDELIVER then
            return
        end
        -- 点击目标优先（等价 automedal.lua:2085 的 lmb.target 兜底），否则鼠标下实体
        local target = act.target
        if not (IsDeliveryDrone(target) or IsScout(target)) then
            target = TheInput:GetWorldEntityUnderMouse()
        end
        if wants_scout then
            if not IsScout(target) then return end
        elseif not IsDeliveryDrone(target) then
            return
        end
        if not CanSend(target) then
            return
        end
        player.components.playercontroller:PullUpMap(target, ACTIONS.MAPDELIVER_MAP)
        return "stop"
    end)

    -- Alt 反转标签：WX-78 运输机空→运送 / 满→收回；普通角色只注入运送；
    -- 侦察机注入探索（原版无世界动作）。
    -- DoGetMouseActions 无参调用，target / position 入参恒 nil（playercontroller:2821）。
    if EC_ALT_REVERSE_ENABLED then
        ActionUtil:RegisterMouseActionModifier(player, function(self, position, target, lmb, rmb)
            -- 非 Alt 直接返回，连鼠标实体查询都不做
            if TheInput == nil or not TheInput:IsControlPressed(CONTROL_FORCE_INSPECT) then
                return lmb, rmb
            end
            local uetarget = target or TheInput:GetWorldEntityUnderMouse()
            if not CanSend(uetarget) then
                return lmb, rmb
            end
            local act
            if IsScout(uetarget) then
                act = ACTIONS.MAPSCOUTSELECT_MAP
            elseif not player:HasTag("batteryuser") then
                -- 官方 CanDismantle / CanMapDeliver 都要 doer:HasTag("batteryuser")，
                -- deployable.restrictedtag 也是 batteryuser；普通角色没有收回/部署资格，
                -- 满机反转成 DISMANTLE 只会被服务端 NOTEMPTY + candismantle 拒掉。
                -- 仅注入能由点击层接管、借 MAPDELIVER_MAP 绕过的运送。
                act = ACTIONS.STARTMAPDELIVER
            else
                local container = uetarget.replica.container
                local isempty
                if uetarget.isempty ~= nil then
                    -- net_bool 权威：false 也是有效值，不能用 and/or 落到客户端 replica
                    isempty = uetarget.isempty:value()
                else
                    isempty = container:IsEmpty()
                end
                act = isempty and ACTIONS.STARTMAPDELIVER or ACTIONS.DISMANTLE
            end
            local pos = position or (TheInput ~= nil and TheInput:GetWorldPosition()) or nil
            return lmb, BufferedAction(self.inst, uetarget, act, nil, pos)
        end)
    end
end

AddPrefabPostInit("world", function(world)
    world:ListenForEvent("playeractivated", function(_, player)
        RegisterPlayerHandlers(player)
    end)
end)
