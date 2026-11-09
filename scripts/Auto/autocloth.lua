local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local CacheService = require "util/cacheservice"
local WorldUtil = require "util/worldutil"
local PlayerUtil = require "util/playerutil"
local Say = require "util/say"
local InventoryEventService = require "util/inventoryeventservice"
local ConfigUtil = require "util/configutil"

local _active_mode = nil

-- 强制衣物覆盖回护甲的标志：由"关自动护甲"/"战斗结束(combattoggled active=false)"置位，
-- 使本次 OnReevaluate 忽略 headBlockedByCombat（无论 AUTO_EQUIP.ARMOR* 与 CheckThreats 此刻取值），
-- 保证衣物一定覆盖战斗/护甲占用的头部/身体槽。OnReevaluate 进入时消费并清零。
local _force_clothing = false

-- 注意：ItemUtil 的分类函数都是冒号定义（带隐式 self），不能直接当函数引用传。
-- 传 ItemUtil.IsClothingHat 会导致 self=物品、item=nil，函数体首行
-- `if not item then return false end` 恒返回 false，衣物永远匹配不到。
-- 必须包一层闭包（写法参考 categories.lua:179 / autohelm.lua:64）。
local function IsHat(item)   return ItemUtil:IsClothingHat(item) end
local function IsBody(item)  return ItemUtil:IsClothingBody(item) end
local function IsGoggle(item) return ItemUtil:IsGoggle(item) end

-- 候选衣物来源：主物品栏 + 背包 + 已打开的容器。
-- 官方 Inventory:CanAccessItem 的判定是：物品的直接 owner 是玩家，
-- 或其所在 container 正被玩家打开（IsOpenedBy 且非 readonlycontainer）；
-- 且 Inventory:Equip 内部会处理 prevcontainer。
-- 所以"从已打开的容器里直接装备"是官方支持的，可以纳入候选。
-- 排除已装备（否则把自己当候选）与手持物品。
local function GetClothingCandidates()
    return InventoryUtil:GetPlayerInventory(false, true, true)
end

local function GetInsulationValue(item, season_type)
    if not item then return 0 end
    if item.components and item.components.insulator and item.components.insulator.type == season_type then
        return item.components.insulator.insulation or 0
    end
    local c = CacheService:GetCachedItem(item)
    if c and c.insulator and c.insulator.insulatortype == season_type then
        return c.insulator.insulation or 0
    end
    return 0
end

-- 雨具判定（IsRainGear / GetWaterproofValue）已迁移到 ItemUtil，此处统一通过 ItemUtil 调用，避免重复实现。

-- 返回最佳候选及其数值；已装备的不参与比较
-- 排除已损坏/无法维持的衣物：损坏（无耐久）或 itemtracker 判定应卸下（低耐久且无修复材料/燃料）的衣物
-- 不应作为候选被反复装备（装后被立即卸下会死循环），修复/补燃料后自然归队。
-- 与 autoamulet / automedal / actioncontroller 的候选列表排除保持同一套判定。
local function GetBestItem(category_fn, value_fn)
    local best, best_val = nil, 0

    for _, item in pairs(GetClothingCandidates()) do
        if item and item:IsValid() and category_fn(item)
           and not (ItemUtil:IsBroken(item) or ItemUtil:ShouldAutoUnequip(item)) then
            local v = value_fn(item)
            if v > best_val then
                best = item
                best_val = v
            end
        end
    end
    return best, best_val
end

-- 是否允许替换当前装备：进入模式时无条件换；维持模式下只在
-- 空槽 / 已穿同类衣物但更差 时才换，避免覆盖护甲、也避免同档来回切换
local function CanReplace(in_slot, is_enter, is_same_kind_fn, cur_val, new_val)
    if is_enter then
        return true
    end
    if not in_slot then
        return true
    end
    return is_same_kind_fn(in_slot) and cur_val < new_val
end

-- 装备此身体衣物是否会顶掉背包：仅当背包与目标身体衣物共用同一装备槽时才冲突。
-- 原版背包占 BODY 槽（overflow），与身体衣物冲突 → 守卫生效，保背包；
-- 多格装备栏把背包挪到独立槽（如 EQUIPSLOTS.BACK），与身体衣物共存 → 不冲突，应正常穿身体衣物。
local function WouldDisplaceBackpack(body_item)
    return ItemUtil:WouldDisplaceBackpack(body_item)
end

local function EquipRainGear(is_enter, force)
    -- 战斗威胁存在且开启"自动头盔/护甲/武器"时，衣物让出头部/身体/手部槽，避免与 autohelm 反复争夺。
    -- force=true（关护甲/战斗结束）时忽略该阻挡，强制衣物覆盖回占用的槽。
    local threaten = PlayerUtil:CheckThreats()
    -- 槽位感知让位：护甲实际占据的槽（多格装备栏下护甲/衣物各占独立槽则不冲突）。
    -- 取"已实际装备护甲"的槽，无默认兜底（未装备不预判，避免误伤自定义槽物品）。
    local armorSlots = (not force) and threaten
        and InventoryUtil:GetEquippedSlotsOf(function(i) return ItemUtil:IsArmor(i) end) or {}
    local headBlockedByCombat = (not force) and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT and threaten
    -- 雨具（手持/身体）在战斗威胁时让出护甲占用的槽；武器占手（WEAPONS 开关开+威胁，预测性让位）
    local rainBlockedByCombat = (not force)
              and (MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY or MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS)
              and threaten

    local head_item, head_val = GetBestItem(IsHat, function(i) return ItemUtil:GetWaterproofValue(i) end)
    local rain_item, rain_val = GetBestItem(function(i) return ItemUtil:IsRainGear(i) end, function(i) return ItemUtil:GetWaterproofValue(i) end)

    local in_head = InventoryUtil:FindEquipped(IsHat)
    local in_rain = InventoryUtil:FindEquipped(function(i) return ItemUtil:IsRainGear(i) end)

    -- 无光环境下头部有光源 → 不换雨帽（黑暗伤害直接致死）；关掉自动光源后该约束自动取消
    local head_blocked = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.LIGHT
        and in_head and ItemUtil:IsLightSource(in_head) and not PlayerUtil:IsInLight()

    -- 1) 优先换头部雨帽；是否"够防雨"改由全身已装备防水值累加判定（见下）。
    --    官方防水值：草帽/蜂帽/橄榄球头盔 0.2、草伞 0.5、雨帽 0.7、猪皮伞 0.9、眼球伞帽 1。
    if head_item and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGHAT
            and not head_blocked
            and not (headBlockedByCombat and armorSlots[ItemUtil:GetEquipSlot(head_item)])
            -- 风暴护目镜优先于雨帽：已在头部戴护目镜时，雨帽不再覆盖它，避免与护目镜反复横跳
            and not (PlayerUtil:IsInStorm(ThePlayer) and in_head and ItemUtil:IsGoggle(in_head))
            and CanReplace(in_head, is_enter, IsHat, ItemUtil:GetWaterproofValue(in_head), head_val) then
        if is_enter and not force then
            Say("下雨了，自动换帽！")
        end
        ConfigUtil:AutoEquip("CLOTHINGHAT", head_item, true, force)
    end

    -- 官方 Inventory:GetWaterproofness()（components/inventory.lua:2714）把所有装备槽的
    -- waterproofer 防水值累加，Inventory:IsWaterproof()（:2736）以 >= 1
    -- （= TUNING.WATERPROOFNESS_ABSOLUTE）判定完全防雨。
    -- 客户端没有同步的玩家防水属性（moisture_replica 只有 IsWet，player_classified 只同步
    -- moisture/maxmoisture/ratescale），所以按官方口径本地累加已装备物品的防水值：
    -- 草帽 0.2 + 猪皮伞 0.9 才够 1，戴草帽不再把雨伞挡掉；满 100% 后才不再补雨具。
    local equipped_waterproof = 0
    for _, item in pairs(InventoryUtil:GetEquips()) do
        equipped_waterproof = equipped_waterproof + ItemUtil:GetWaterproofValue(item)
    end
    if equipped_waterproof < 1 then
        -- 2) 防水不足 100% → 穿"最佳雨具"（手持雨伞或身体雨衣，按防水值取最高者），统一受"自动身体衣物"开关控制。
        --    身体雨衣被背包占 BODY 槽时穿不上 → 回退到手持雨伞（不挤背包、背包不能丢）。
        if rain_item and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGBODY
                and not (rainBlockedByCombat
                         and (armorSlots[ItemUtil:GetEquipSlot(rain_item)]
                              or (MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.WEAPONS
                                  and ItemUtil:GetEquipSlot(rain_item) == EQUIPSLOTS.HANDS)))
                and CanReplace(in_rain, is_enter, function(i) return ItemUtil:IsRainGear(i) end, ItemUtil:GetWaterproofValue(in_rain), rain_val) then
            local is_hand = ItemUtil:GetEquipSlot(rain_item) == EQUIPSLOTS.HANDS
            if (not is_hand) and WouldDisplaceBackpack(rain_item) then
                -- 背包占身体槽，雨衣穿不上 → 改穿手持雨伞（若有）
                local hand_item = GetBestItem(
                    function(i) return ItemUtil:IsRainGear(i) and ItemUtil:GetEquipSlot(i) == EQUIPSLOTS.HANDS end,
                    function(i) return ItemUtil:GetWaterproofValue(i) end)
                if hand_item then
                    if is_enter and not force then
                        Say("下雨了，自动撑伞！")
                    end
                    ConfigUtil:AutoEquip("CLOTHINGBODY", hand_item, true, force)
                end
            else
                if is_enter and not force then
                    if is_hand then
                        Say("下雨了，自动撑伞！")
                    else
                        Say("下雨了，自动换衣！")
                    end
                end
                ConfigUtil:AutoEquip("CLOTHINGBODY", rain_item, true, force)
            end
        end
    end
end

local function EquipInsulationClothing(season_type, is_enter, force)
    -- 战斗威胁存在且开启"自动头盔/护甲"时，衣物让出头部/身体槽，避免与 autohelm 反复争夺。
    -- force=true（关护甲/战斗结束）时忽略该阻挡，强制衣物覆盖回护甲占用的槽。
    local threaten = PlayerUtil:CheckThreats()
    -- 槽位感知让位：护甲实际占据的槽（多格装备栏下护甲/衣物各占独立槽则不冲突）。
    -- 取"已实际装备护甲"的槽，无默认兜底（未装备不预判，避免误伤自定义槽物品）。
    local armorSlots = (not force) and threaten
        and InventoryUtil:GetEquippedSlotsOf(function(i) return ItemUtil:IsArmor(i) end) or {}
    local headBlockedByCombat = (not force) and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT and threaten
    local bodyBlockedByCombat = (not force) and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY and threaten

    local value_fn = function(item) return GetInsulationValue(item, season_type) end
    local head_item, head_val = GetBestItem(IsHat, value_fn)
    local body_item, body_val = GetBestItem(IsBody, value_fn)

    local in_head = InventoryUtil:FindEquipped(IsHat)
    local in_body = InventoryUtil:FindEquipped(IsBody)

    if head_item and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGHAT
            and not (headBlockedByCombat and armorSlots[ItemUtil:GetEquipSlot(head_item)])
            -- 风暴护目镜优先于季节帽：已在头部戴护目镜时，季节帽（如隔热眼球伞）不再覆盖它，避免反复横跳
            and not (PlayerUtil:IsInStorm(ThePlayer) and in_head and ItemUtil:IsGoggle(in_head))
            and CanReplace(in_head, is_enter, IsHat, GetInsulationValue(in_head, season_type), head_val) then
        if is_enter and not force then
            Say(season_type == "winter" and "冬天到了，自动换帽！" or "夏天到了，自动换帽！")
        end
        ConfigUtil:AutoEquip("CLOTHINGHAT", head_item, true, force)
    end

    if body_item and MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGBODY
            and not (bodyBlockedByCombat and armorSlots[ItemUtil:GetEquipSlot(body_item)])
            and CanReplace(in_body, is_enter, IsBody, GetInsulationValue(in_body, season_type), body_val)
            and not WouldDisplaceBackpack(body_item) then
        if is_enter and not force then
            Say(season_type == "winter" and "冬天到了，自动换衣！" or "夏天到了，自动换衣！")
        end
        ConfigUtil:AutoEquip("CLOTHINGBODY", body_item, true, force)
    end
end

-- ===== 风暴护目镜 =====

local function EquipStormGoggles()
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGHAT then
        return
    end

    -- 已穿戴护目镜则跳过（同样必须传闭包，不能传 ItemUtil.IsGoggle）
    if InventoryUtil:FindEquipped(IsGoggle) then
        return
    end

    -- 查找护目镜并装备（排除损坏/无法维持的）
    local goggles_item = InventoryUtil:FindItemAnywhere(function(item)
        return IsGoggle(item)
            and not (ItemUtil:IsBroken(item) or ItemUtil:ShouldAutoUnequip(item))
    end)
    if goggles_item then
        Say("沙尘暴！装备护目镜")
        ConfigUtil:AutoEquip("CLOTHINGHAT", goggles_item, true)
    end
end

local function OnReevaluate()
    if not InventoryUtil:GetInventory() then
        return
    end

    -- 消费强制标志：本次评估忽略战斗阻挡（关护甲/战斗结束），让衣物覆盖回护甲占用的槽
    local force = _force_clothing
    _force_clothing = false

    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGHAT and not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGBODY then
        _active_mode = nil
        return
    end

    -- 优先级：风暴 > 下雨 > 季节。风暴时头部只护目镜，身体仍按雨/季节气需（不冲突头部）
    local in_storm = PlayerUtil:IsInStorm(ThePlayer)
    local target_mode = nil
    if in_storm then
        target_mode = "storm"
    elseif (WorldUtil:IsRaining() or WorldUtil:IsAcidRaining()) and not WorldUtil:IsLunarhailing() then
        target_mode = "rain"
    else
        -- 分支一：直接用季节判定（本地/已同步的专服客机，season 实时正确）
        target_mode = WorldUtil:GetSeason()
        -- 分支二：季节不是冬/夏（专服客机滞后返回 autumn，或真实春秋）时，
        -- 用持续同步、实时可靠的世界环境温度兜底判断保暖/隔热模式，
        -- 保证切换开关瞬间即可穿对衣物；季节同步后走分支一，行为不变。
        if target_mode ~= "winter" and target_mode ~= "summer" then
            if WorldUtil:IsFreezingTemperature() then
                target_mode = "winter"
            elseif WorldUtil:IsOverheatTemperature() then
                target_mode = "summer"
            else
                target_mode = nil
            end
        end
    end

    -- 模式未变 → 维持（持续确保穿衣，不播提示）
    if target_mode == _active_mode then
        if target_mode == "storm" then
            -- 风暴：头部护目镜（最高优先级）；身体仍按雨/季节气需（头部由 Equip* 的守卫让位）
            if (WorldUtil:IsRaining() or WorldUtil:IsAcidRaining()) and not WorldUtil:IsLunarhailing() then EquipRainGear(false, force) end
            if WorldUtil:IsFreezingTemperature() then EquipInsulationClothing("winter", false, force)
            elseif WorldUtil:IsOverheatTemperature() then EquipInsulationClothing("summer", false, force) end
            EquipStormGoggles()
        elseif target_mode == "rain" then
            EquipRainGear(false, force)
        elseif target_mode ~= nil then
            EquipInsulationClothing(target_mode, false, force)
        end
        return
    end

    -- 模式切换 → 进入新模式
    local prev_mode = _active_mode
    _active_mode = target_mode

    if not target_mode and prev_mode then
        if prev_mode == "rain" then
            if not force then Say("雨停了") end
        elseif prev_mode == "winter" then
            if not force then Say("冬天结束了") end
        elseif prev_mode == "summer" then
            if not force then Say("夏天结束了") end
        elseif prev_mode == "storm" then
            if not force then Say("风暴结束了") end
        end
    end

    if target_mode == "storm" then
        EquipStormGoggles()
        -- 身体仍按雨/季节气需（头部由护目镜占，Equip* 守卫让位）
        if (WorldUtil:IsRaining() or WorldUtil:IsAcidRaining()) and not WorldUtil:IsLunarhailing() then EquipRainGear(true, force) end
        if WorldUtil:IsFreezingTemperature() then EquipInsulationClothing("winter", true, force)
        elseif WorldUtil:IsOverheatTemperature() then EquipInsulationClothing("summer", true, force) end
    elseif target_mode == "rain" then
        if not force then Say("下雨了，换雨具") end
        EquipRainGear(true, force)
    elseif target_mode == "winter" then
        if not force then Say("过冬换保暖") end
        EquipInsulationClothing("winter", true, force)
    elseif target_mode == "summer" then
        if not force then Say("过夏换隔热") end
        EquipInsulationClothing("summer", true, force)
    end
end

local function Init()
    if not ThePlayer then return end

    WorldUtil:OnSeasonTick(OnReevaluate)
    WorldUtil:OnIsRainingChanged(OnReevaluate)
    WorldUtil:OnSeasonChanged(OnReevaluate)
    WorldUtil:OnPrecipitationChanged(OnReevaluate)

    -- 中键切换衣物自动装备开关（CLOTHINGHAT/CLOTHINGBODY）后立即重新评估：
    -- 打开开关时强制重置 _active_mode=nil，使 OnReevaluate 走"进入新模式"路径（is_enter=true，
    -- CanReplace 无条件替换），从而立即覆盖头部/身体已装备的护甲（如头盔）换上对应衣物；
    -- 否则走"维持"路径时，CanReplace 对"非同类（头盔≠帽子）"返回 false，需先手动卸下护甲才装备。
    -- 关闭开关时 _active_mode 已被双关分支置 nil，此处重置为 nil 亦无副作用。
    -- 季节滞后已由 OnReevaluate 内的世界环境温度兜底解决，切换瞬间即可穿对衣物，无需延时补评。
    --
    -- 切换"自动护甲"开关（ARMORHAT/ARMORBODY）也要重评：仇恨锁定期间 autocloth 只是暂停，
    -- 头盔是被 autohelm 强制穿上时"换"掉的（autocloth 不主动卸）。用户"关自动护甲想穿帽"
    -- 必须让 autocloth 立即重评——关护甲时置 _force_clothing 强制衣物覆盖回护甲（即便 AUTO_EQUIP.ARMOR* /
    -- CheckThreats 此刻残留为 true 也不挡）；开护甲则由 autohelm 线程（30 帧兜底轮询）接管该槽。
    -- 不再用 _active_mode 守卫：否则战斗中 _active_mode 为 nil 时关护甲不会触发重评，衣物永不回来。
    ThePlayer:ListenForEvent("autoequeiptoggled", function(_, data)
        if not data then return end
        if data.category == "CLOTHINGHAT" or data.category == "CLOTHINGBODY" then
            if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[data.category] then
                _active_mode = nil
            end
            OnReevaluate()
        elseif data.category == "ARMORHAT" or data.category == "ARMORBODY" then
            -- 关闭该护甲开关 → 强制衣物覆盖回对应槽
            if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP[data.category] then
                _force_clothing = true
            end
            _active_mode = nil
            OnReevaluate()
        end
    end)

    -- 战斗威胁结束（autohelm 推送 active=false）：置 _force_clothing 强制衣物覆盖回护甲占用的槽，
    -- 但【不】重置 _active_mode——战斗中 _active_mode 通常已是当前季节（如 winter），OnReevaluate 走
    -- "维持"路径（is_enter=false）即可把衣物换回护甲，且不会重复播报"过冬换保暖/冬天到了自动换帽"。
    -- 若此处重置 _active_mode=nil，每次 combattoggled{active=false}（怪在威胁范围 30 边缘反复进出时会
    -- 多次触发）都会强制 is_enter 模式切换，反复重播季节提示 → 提示过频。
    -- 维持路径下 in_head 为 nil（头盔非衣物帽，FindEquipped(IsHat) 只认衣物帽），CanReplace 直接返回
    -- true，衣物照样覆盖护甲，功能不受影响。
    -- 战斗开始（active=true）无需处理：autohelm 强制接管，autocloth 维持路径已让出头部。
    ThePlayer:ListenForEvent("combattoggled", function(_, data)
        if data and data.active == false then
            _force_clothing = true
            OnReevaluate()
        end
    end)

    -- 风暴 → 自动护目镜
    PlayerUtil:On("startstorm", function(data, player)
        EquipStormGoggles()
    end)
    -- 物品栏变化（拾取/移动/卸下）→ 重新评估衣物：只要自动衣物开关开启就重评，
    -- 不再依赖 _active_mode（否则 _active_mode 异常为 nil 时连"动一下物品栏"都触发不了重评）。
    local function OnInventoryChanged(data)
        if not (MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGHAT or MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.CLOTHINGBODY) then
            return
        end
        if data and not data.item then
            return
        end
        OnReevaluate()
    end
    InventoryEventService:On(InventoryEventService.EVENT.ITEM_ADDED, OnInventoryChanged)
    InventoryEventService:On(InventoryEventService.EVENT.UNEQUIPPED, OnInventoryChanged)

    ThePlayer:DoTaskInTime(0.5, OnReevaluate)
end

return Init