local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local ConfigUtil = require "util/configutil"

local function IsWearingArmor(category_fn)
    return InventoryUtil:HasEquipped(category_fn)
end

-- 是否可以穿上护甲（不覆盖光源/衣物/背包/已有同类别护甲）
-- hasActive: 存在战斗威胁。有威胁时"战斗优先于衣服"，允许用护甲覆盖 autocloth 的衣物帽/衣；
-- 无威胁时维持原行为，不强行替换衣物（避免与自动穿衣冲突）。
-- armor_category: "ARMORHAT" 或 "ARMORBODY"
local function CanEquipArmor(armor_category, category_fn, hasActive)
    local slot = InventoryUtil:DetectEquipSlot(category_fn)
    if not slot then
        slot = armor_category == "ARMORHAT" and EQUIPSLOTS.HEAD or EQUIPSLOTS.BODY
    end
    local equippedItem = InventoryUtil:GetEquippedItemBySlot(slot)

    if not equippedItem then
        return true
    end

    if armor_category == "ARMORHAT" then
        -- 不覆盖衣物（雨帽/保暖帽/隔热帽由 autocloth 管理）；有威胁时战斗优先，允许覆盖衣物切护甲
        if ItemUtil:IsClothingHat(equippedItem) and not hasActive then
            return false
        end
        -- 仅无光环境下保留头部唯一光源：约每 5 秒 100 鬼手伤害，比不穿护甲死得更快。
        -- 有光环境（含可逃离避战的情形）正常让护甲覆盖，不失去"自动"的意义。
        -- 无光判定走 PlayerUtil:IsInLight()（官方 IsInLight() + 客户端本地假光闸门），不做反转封装。
        local function AmountOfEquippedLightSources()
            local ret = 0
            for _, item in pairs(InventoryUtil:GetEquips()) do
                if Categories.LIGHT.fn(item) then
                    ret = ret + 1
                end
            end
            return ret
        end
        if not PlayerUtil:IsInLight() and Categories.LIGHT.fn(equippedItem)
                and AmountOfEquippedLightSources() <= 1 then
            return false
        end
    else
        -- 身体护甲允许覆盖背包：保命优先于背包物资（死掉就什么都带不走），故不做背包冲突检查；
        -- 多格装备栏（背包在 BACK 槽）本就与身体护甲共存，无影响。
        -- 不覆盖衣物（雨衣/保暖衣/隔热衣由 autocloth 管理）；有威胁时战斗优先，允许覆盖衣物切护甲
        if ItemUtil:IsClothingBody(equippedItem) and not hasActive then
            return false
        end
    end

    return not category_fn(equippedItem)
end

-- 顶背包前保护：借用整理组件的瞬发归位（把背包内可装备物 swap 到主物品栏，
-- 只留原材料/杂物在背包），避免身体护甲顶掉背包时丢失武器装备。
-- 整理逻辑统一收敛到 Sorter 组件（InstantSortEquippable），此处只调用一下。
local protectingBackpack = false
local function ProtectBackpackEquip(armor)
    if protectingBackpack then return end
    protectingBackpack = true
    ThePlayer:StartThread(function()
        local sorter = ThePlayer.components.sorter
        if sorter then
            sorter:InstantSortEquippable()
        end
        -- 无论整理成败都装备护甲：保命优先于背包物资（此路径只在 ARMORBODY 分支触发）
        ConfigUtil:AutoEquip("ARMORBODY", armor, true)
        protectingBackpack = false
    end)
end

-- 返回该槽护甲是否已就位 / 已发出装备请求，供 EvaluateThreat 判断是否需要身体护甲兜底。
local function ProcessArmorSlot(armor_category, hasActive)
    local cat = Categories[armor_category]
    if not cat then return false end

    local category_fn = cat.fn

    -- 已穿戴同类别护甲 → 跳过（避免每帧重复装备）
    if IsWearingArmor(category_fn) then return true end

    -- 当前不可覆盖 → 跳过（有威胁时允许覆盖衣物，战斗优先；无光环境唯一光源除外）
    if not CanEquipArmor(armor_category, category_fn, hasActive) then return false end

    -- 无可用护甲 → 跳过
    local ac = PlayerUtil:GetComponent("actioncontroller")
    local armor = ac and ac:GetItemFromCategory(armor_category)
    -- 游戏返回的"最佳"护甲可能带 broken 标签（锻造装备 0 耐久）：完全不可用，排除出候选列表不装备
    if not armor or ItemUtil:IsBroken(armor) then return false end

    -- 有威胁且当前未穿同类护甲 → 穿。
    -- 用 hasActive（威胁存在）而非"新威胁"，否则护甲被卸下/损毁后同一威胁仍在就不会重穿
    -- （旧逻辑 hasNew 在首次装备后即恒 false，造成"有威胁也不切护甲"）。
    -- IsWearingArmor 已保证穿上后不再重复触发；护甲被卸下后下一帧自动重穿。
    if hasActive then
        -- 身体护甲顶掉背包时先整理（保命优先）；多格装备栏把背包挪到独立槽则不冲突，
        -- 由 ItemUtil:BackpackConflictWithSlot 按槽动态判定，身体护甲/身体衣物都不占背包。
        local needsProtect = false
        if armor_category == "ARMORBODY" then
            local equipped = InventoryUtil:GetEquippedItemBySlot(EQUIPSLOTS.BODY)
            if equipped and ItemUtil:IsBackpack(equipped) then
                needsProtect = true
            end
        end
        if needsProtect then
            ProtectBackpackEquip(armor)
        else
            ConfigUtil:AutoEquip(armor_category, armor, true)
        end
        return true
    end
    return false
end

local function Init()
    if not ThePlayer then
        return
    end

    local prevThreat = false

    -- 事件驱动评估：被攻击立即评估（威胁开始）；自动护甲开启时挂一个慢速安全轮询
    -- （仅用于客户端无"被锁定"事件时的兜底，约 0.5s 一次，远慢于原 10 帧热轮询），
    -- 捕捉"威胁结束/离开范围"。锁定是否生效完全由自动护甲开关决定：
    -- 关闭自动护甲 → 停止轮询并清状态，autocloth 立即重新评估把衣物顶上（见 autocloth 的
    -- autoequeiptoggled 处理），无需任何轮询。
    local function EvaluateThreat()
        if not (MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT or MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY) then
            return
        end

        local hasActive = PlayerUtil:CheckThreats()

        -- 威胁状态切换时通知 autocloth 重新评估：
        -- 进入战斗 → 护甲强制接管头部/身体，autocloth 让出；
        -- 离开战斗 → autocloth 换回保暖/隔热衣物（日常穿衣物）。
        if hasActive ~= prevThreat then
            prevThreat = hasActive
            ThePlayer:PushEvent("combattoggled", { active = hasActive })
        end

        -- 头部护甲可就位时保命已够，不再顶掉身体衣物；仅头部没有护甲时才用身体护甲兜底保命
        -- （例如无光环境下头部唯一光源不可覆盖）。身体护甲/身体衣物都不占背包。
        local headArmorReady = MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT
            and ProcessArmorSlot("ARMORHAT", hasActive)
        if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY and not headArmorReady then
            ProcessArmorSlot("ARMORBODY", hasActive)
        end
    end

    -- 被攻击 → 立即评估（无需等慢速轮询）
    ThePlayer:ListenForEvent("attacked", EvaluateThreat)

    -- 自动护甲开关绑定：开启才挂慢速安全轮询；关闭即停、清状态（锁定解除）
    local slow_task = nil
    local function StopSlowPoll()
        if slow_task ~= nil then
            slow_task:Cancel()
            slow_task = nil
        end
    end
    local function StartSlowPoll()
        if slow_task ~= nil then
            return
        end
        slow_task = ThePlayer:DoPeriodicTask(30 * FRAMES, EvaluateThreat)
    end

    ThePlayer:ListenForEvent("autoequeiptoggled", function(_, data)
        if data and (data.category == "ARMORHAT" or data.category == "ARMORBODY") then
            if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT or MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY then
                StartSlowPoll()
                EvaluateThreat()
            else
                StopSlowPoll()
                prevThreat = false
                -- 关闭自动护甲 → 通知 autocloth 立即把衣物顶回护甲占用的槽。
                -- 不能只靠 autocloth 自身的 autoequeiptoggled 处理：若关护甲的方式未走那条事件链，
                -- 衣物会一直被护甲占着；此处由护甲权威模块主动推送，确保 autocloth 重评（携带 force，无视残留威胁）。
                ThePlayer:PushEvent("combattoggled", { active = false })
            end
        end
    end)

    if MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORHAT or MOD_EQUIPMENT_CONTROL.AUTO_EQUIP.ARMORBODY then
        StartSlowPoll()
        EvaluateThreat()
    end
end

return Init