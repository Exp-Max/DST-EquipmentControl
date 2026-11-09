local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local WorldUtil = require "util/worldutil"
local ConfigUtil = require "util/configutil"

-- 官方玩家 LightWatcher:SetLightThresh(.075)（scripts/prefabs/player_common.lua:2446）：
-- 低于该阈值即处于黑暗、会被鬼手攻击；用于校验"举着的光源是否真的在发光"。
local LIGHT_THRESH = 0.075
-- 举着自身光源时，合成照度相对保持态基线的增量只能来自外部光/天光增强。
local EXTERNAL_LIGHT_DELTA = 0.1

local LIGHT_STATE = {
    PROTECTED = 1,  -- 外部光/天光已保护：不需要自身光源
    HELD      = 2,  -- 自身光源正在保护：保持，低等级自动装备让位
    DARK      = 3,  -- 无光：需要装备自身光源
}

local function IsUsableLightSource(item)
    if item:HasTag("fueldepleted") then
        return false
    end
    -- Light:IsEnabled() 是引擎对"此刻正在发光"的判定，对世界光源实体有效；
    -- 背包物品通常未点亮，这里主要靠 "light" 标签兜底分类外的模组光源。
    if item.Light and item.Light:IsEnabled() then
        return true
    end
    if item:HasTag("light") then
        return true
    end
    return false
end

-- ItemUtil 的分类方法是冒号定义（带 self），传给 FindEquipped 必须包一层命名闭包，
-- 不能用 ItemUtil.IsLightSource 直接传引用；命名闭包也让谓词缓存 key 稳定。
local function IsLightSourceItem(item)
    return ItemUtil:IsLightSource(item)
end

local function GetLightSource()
    local ac = PlayerUtil:GetComponent("actioncontroller")
    if not ac then
        return nil
    end

    -- 与按钮条 Refresh（widgets/buttons.lua:128）和 autocane 一致：
    -- GetItemFromCategory 优先返回按钮上选定的 LIGHT 预设（Preferences.User.LIGHT）。
    -- GetItemsFromCategory 只把临时物品置顶再按燃料上限排序，不认用户预设；
    -- 取它的 [1] 会装备 nightstick 这类高燃料上限的物品，而不是按钮上显示的那盏灯。
    local preferred = ac:GetItemFromCategory("LIGHT")
    if preferred then
        return preferred
    end

    -- 分类里连一件可用物品都没有：扫描背包中未被分类但实际能发光的光源（兼容任意模组光源）
    local fallback = {}
    for _, item in ipairs(InventoryUtil:GetPlayerInventory(true, false, true)) do
        if IsUsableLightSource(item) then
            fallback[#fallback + 1] = item
        end
    end
    return fallback[1]
end

-- 三态判定：默认纯即时，只读当前装备、世界时钟与官方 LightWatcher；
-- 读到客户端本地假光时改走缓存的结构判据，不再采信 LightWatcher。
-- held_item / held_baseline 是线程内局部变量：只在自身光源保持期间记录"是哪盏灯、
-- 当时的合成照度"，用于识别外部光增强；随线程结束自然消失，无需清理。
local function GetLightState(held_item, held_baseline)
    local held = InventoryUtil:FindEquipped(IsLightSourceItem)

    -- 天光已保护：无论是否举着光源都应撤掉，省耐久（TheWorld.state 由服务端网络相位驱动）
    if WorldUtil:IsDay() then
        return LIGHT_STATE.PROTECTED, held
    end

    -- 客户端本地假光只进本机光照网格，服务端 grue 仍按黑暗判定。
    -- 此时照度、GetTimeInDark、基线增量全部失真，一律不采信：
    -- 只按服务器可见的装备状态决定——举着真光源就保持，否则按黑暗补光。
    -- 代价是假光期间不会因篝火等外部光而卸灯（多烧一点燃料），换来不再挨鬼手。
    if PlayerUtil:HasClientFakeLight() then
        -- 假光会伪造照度，IsLightGreaterThan 此时必然为真；改用物品自身的官方耗尽标签
        -- （components/fueled.lua:76）识别"举着但已经不发光"的光源，避免一直 HELD 不换灯。
        if held and held:HasTag("fueldepleted") then
            return LIGHT_STATE.DARK, nil
        end
        return held and LIGHT_STATE.HELD or LIGHT_STATE.DARK, held
    end

    if held then
        -- 举着光源却仍低于官方安全阈值：这盏灯没在发光（未点燃/已耗尽），不能算 HELD
        if not ThePlayer:IsLightGreaterThan(LIGHT_THRESH) then
            return LIGHT_STATE.DARK, nil
        end
        -- 举着自身光源时玩家被自己点亮，IsInLight()/GetLightValue() 无法反推环境是否黑暗；
        -- 只有同一盏灯的照度相对基线明显增加，才说明外部光/天光已接手保护。
        if held == held_item and held_baseline
                and ThePlayer.LightWatcher:GetLightValue() - held_baseline > EXTERNAL_LIGHT_DELTA then
            return LIGHT_STATE.PROTECTED, held
        end
        return LIGHT_STATE.HELD, held
    end

    -- 没举自身光源：LightWatcher 的黑暗状态机（官方 enterdark/enterlight 迟滞）
    -- 直接给出外部光是否足够，比纯阈值比较更不容易在亮度边界抖动。
    if ThePlayer.LightWatcher:GetTimeInDark() > 0 then
        return LIGHT_STATE.DARK, nil
    end
    return LIGHT_STATE.PROTECTED, nil
end

local function UnequipLightSource(item)
    if item and InventoryUtil:IsEquipped(item) then
        InventoryUtil:Unequip(item)
    end
end

local function Init()
    if not ThePlayer then
        return
    end

    -- LightWatcher 可能尚未就绪（专服客机加载时序），延迟重试
    if not ThePlayer.LightWatcher then
        ThePlayer:DoTaskInTime(1.0, Init)
        return
    end

    StartThread(function()
        local held_item, held_baseline
        while ThePlayer do
            if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.LIGHT then
                local state, held = GetLightState(held_item, held_baseline)

                if state == LIGHT_STATE.DARK then
                    held_item, held_baseline = nil, nil
                    local lightsource = GetLightSource()
                    if lightsource and not InventoryUtil:IsEquipped(lightsource) then
                        -- 攻击窗口内（见 autoweapon 的 _ec_last_attack）：让出 HANDS 给预设武器，
                        -- 避免光源把刚切出的武器顶掉；停手超过窗口后光源照常装回（恢复防鬼手）。
                        if not (MOD_EQUIPMENT_CONTROL._ec_last_attack
                                and GetTime() - MOD_EQUIPMENT_CONTROL._ec_last_attack < 3) then
                            ConfigUtil:AutoEquip("LIGHT", lightsource)
                        end
                    end
                elseif state == LIGHT_STATE.PROTECTED then
                    -- 只卸自动光源保持过的那盏（held_item 仅在 HELD 态赋值），
                    -- 不碰玩家白天手动举起的光源；卸完把 HANDS 还给自动手杖/雨具。
                    UnequipLightSource(held_item)
                    held_item, held_baseline = nil, nil
                else
                    -- HELD：保持自身光源，ConfigUtil 的槽位仲裁会挡住手杖/雨具覆盖该槽。
                    -- 基线只在刚进入保持态（或换了一盏光源）时采样一次，避免逐帧漂移。
                    if held ~= held_item then
                        held_item = held
                        held_baseline = ThePlayer.LightWatcher:GetLightValue()
                    end
                end
            else
                held_item, held_baseline = nil, nil
            end
            Sleep(.5)
        end
    end, "AutoLightThread")
end

return Init
