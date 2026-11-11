local InventoryUtil = require "util/inventoryutil"
local PlayerUtil = require "util/playerutil"
local ConfigUtil = require "util/configutil"

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

-- 需要光源时补装：只发 EQUIP，从不主动卸下（旧装备由官方换回物品栏）。
-- 判定与 configutil 的 LIGHT 抑制共用 PlayerUtil:NeedsLightProtection()，只有一份基线。
-- 战斗抑制由 configutil:IsSuppressed 统一裁决：autolight 只发请求，宣告由 NoteEnterDark 解除抑制。
local function TryEquipLight()
    if not MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.LIGHT then
        return
    end
    if not PlayerUtil:NeedsLightProtection() then
        return
    end
    local lightsource = GetLightSource()
    if lightsource and not InventoryUtil:IsEquipped(lightsource) then
        ConfigUtil:AutoEquip("LIGHT", lightsource)
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

    -- 官方 wisecracker.lua:557-562 在真正进入黑暗（GetTimeInDark() >= .5）时
    -- 说 ANNOUNCE_ENTER_DARK；grue.lua:73 的 warndelay 只有 1 秒，这句台词意味着马上挨打。
    -- 宣告本身就是"该停手防鬼手了"：由 configutil 解除战斗抑制，再强制切回光源一次。
    -- 参考工坊模组 3123028409 的 talker.Say 钩子；_ec_ 标记防重复包裹。
    local talker = PlayerUtil:GetTalker()
    if talker and not talker._ec_light_dark_hook then
        talker._ec_light_dark_hook = true
        local oldSay = talker.Say
        talker.Say = function(self, script, ...)
            if script == GetString(ThePlayer, "ANNOUNCE_ENTER_DARK") then
                ConfigUtil:NoteEnterDark()
                TryEquipLight()
            end
            return oldSay(self, script, ...)
        end
    end

    StartThread(function()
        while ThePlayer do
            -- 是否放行由 configutil:IsSuppressed 统一裁决：战斗期间 LIGHT 请求一律被挡，
            -- 宣告解除抑制后切回一次；之后继续攻击又重新登记，直到下次宣告，如此反复。
            TryEquipLight()
            Sleep(.5)
        end
    end, "AutoLightThread")
end

return Init
