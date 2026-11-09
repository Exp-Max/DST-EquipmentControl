local InventoryUtil = require "util/inventoryutil"
local ItemUtil = require "util/itemutil"
local PlayerUtil = require "util/playerutil"
local FileSystem = require "util/filesystem"
local KeybindService = MOD_EQUIPMENT_CONTROL.KEYBINDSERVICE
local Say = require "util/say"

-- 自动卸下可修复装备：永久启用
local AUTO_UNEQUIP_REPAIRABLES = true

local Preferences =
{
    AutoEquipCategory = "WEAPONS",
    User = {},
    Static =
    {
        glasscutter = TUNING.GLASSCUTTER.DAMAGE - .5,
        molehat = .5,
    },
}

local ActionController = Class(function(self, inst)
    self.inst = inst
    self._refresh_id = 0
    self._cached_inventory = nil
    self._priority_cache = {}
    self._refresh_active = false  -- 是否处于 BeginRefresh/EndRefresh 窗口内
    self._refresh_started = 0     -- 窗口开启时间，超时兜底防止 EndRefresh 未执行导致快照永久滞留
    self._temp_items = {}

    FileSystem:LoadStringFromFile("equipment_control_temp_items", function(load_success, str)
        if load_success and str and str ~= "" then
            local success, data = pcall(json.decode, str)
            if success and data then
                -- 迁移旧格式 {category: "prefab"} → 新格式 {category: {prefab: true}}
                for category, val in pairs(data) do
                    if type(val) == "string" then
                        data[category] = { [val] = true }
                    end
                end
                -- 合并加载的数据到当前状态，避免覆盖用户已添加的临时物品
                for category, set in pairs(data) do
                    if not self._temp_items[category] then
                        self._temp_items[category] = {}
                    end
                    for prefab, _ in pairs(set) do
                        self._temp_items[category][prefab] = true
                    end
                    -- 仅当用户尚未设置偏好时，才从加载数据中恢复（确定性取最小 prefab，避免 next(set) 顺序随机）
                    if not Preferences.User[category] then
                        local first
                        for prefab in pairs(set) do
                            if first == nil or prefab < first then
                                first = prefab
                            end
                        end
                        if first then
                            Preferences.User[category] = first
                        end
                    end
                end
                if self.inst.HUD and self.inst.HUD.controls.inv.buttons then
                    self.inst.HUD.controls.inv.buttons:Refresh()
                end
            end
        end
    end)

    for category in pairs(Categories) do
        local conf = GetModConfigData("PREFERRED_" .. category, MOD_EQUIPMENT_CONTROL.MODNAME)
        if conf then
            Preferences.User[category] = conf
        end
    end

    -- 自动装备玻璃刀：永久启用
    Preferences.Static.glasscutter = TUNING.SPEAR_DAMAGE - 1
end)

local function GetPreference(category, item)
    -- 选择（按钮上的武器）由 GetAutoEquipCategoryItem / GetItemFromCategory 直接读取 Preferences.User 处理，
    -- 这里只保留静态优先级（如玻璃刀），不再对用户选择/临时物品做 math.huge 无限优先级干预，避免偏好逻辑干扰轮转与自动装备。
    return Preferences.Static[item.prefab]
end

local function GetNamePriority(item)
    return item
        and item.prefab
       and #item.prefab * .001
        or 0
end

local function GetPercentUsedPriority(item)
    return ItemUtil:GetPercentUsed(item) * .01
end

local function GetPriority(category, item, ignorePreferences, target)
    return not ignorePreferences and GetPreference(category, item)
        or Categories[category].priority(item, target)
         + (not Categories.CANE.fn(item) and GetNamePriority(item) - GetPercentUsedPriority(item) or 0)
end

local function IsAutoUnEquipping(item)
    return AUTO_UNEQUIP_REPAIRABLES
        and ItemUtil:IsRepairable(item)
        and not ItemUtil:IsMedalUndying(item)
        and (
            (not ItemUtil:IsForgeRepairable(item) and ItemUtil:GetPercentUsed(item) <= ItemUtil:GetFiniteUses(item))
            or (ItemUtil:IsForgeRepairable(item) and ItemUtil:GetPercentUsed(item) <= 0)
        )
end

-- 刷新窗口（BeginRefresh/EndRefresh 之间）复用库存快照与优先级结果：
-- 一次 Buttons:Refresh 要遍历 15 个分类，每个分类最多 3 次全量扫描 + 排序，
-- 不复用时单次刷新约 45 次 GetPlayerInventory。
-- 只在窗口内缓存；窗口外一律实时取，避免拿到过期库存。
-- 兜底：若刷新过程中报错导致 EndRefresh 未执行，2 秒后自动退出窗口，
-- 避免一直复用过期快照
local REFRESH_WINDOW_TIMEOUT = 2

local function IsRefreshing(ac)
    return ac ~= nil
        and ac._refresh_active
        and (GetTime() - (ac._refresh_started or 0)) < REFRESH_WINDOW_TIMEOUT
end

local function GetInventorySnapshot()
    local ac = PlayerUtil:GetComponent("actioncontroller")
    if IsRefreshing(ac) then
        if ac._cached_inventory == nil then
            ac._cached_inventory = InventoryUtil:GetPlayerInventory(true, nil, true)
        end
        return ac._cached_inventory
    end
    return InventoryUtil:GetPlayerInventory(true, nil, true)
end

local function PriorityCacheKey(category, ignorePreferences, target)
    return tostring(category) .. "|" .. (ignorePreferences and "1" or "0") .. "|" .. tostring(target)
end

local function GetItemPriorityTable(category, ignorePreferences, target)
    if not category or not Categories[category] or type(Categories[category].fn) ~= "function" then
        return {}
    end

    local ac = PlayerUtil:GetComponent("actioncontroller")
    local cacheKey = IsRefreshing(ac) and PriorityCacheKey(category, ignorePreferences, target) or nil
    if cacheKey ~= nil and ac._priority_cache[cacheKey] ~= nil then
        return ac._priority_cache[cacheKey]
    end

    local ret = {}

    for _, item in pairs(GetInventorySnapshot()) do
        local fnres = Categories[category].fn(item)
        if (ignorePreferences or not IsAutoUnEquipping(item)) and fnres then
            if category == "FOOD" or category == "RESTORATION" or category == "HEALING" or ItemUtil:GetEquipSlot(item) then
                ret[#ret + 1] =
                {
                    item = item,
                    priority = GetPriority(category, item, ignorePreferences, target)
                }
            end
        end
    end

    -- 临时物品（模组物品可能不通过 Categories[cat].fn 识别）纳入候选列表：
    -- 仅在未被识别（不在 ret 中）时追加，使用真实优先级（忽略用户偏好，不走 math.huge），
    -- 形成"已识别武器 + 未被识别的临时物品"完整列表，且不压过其它武器，
    -- 避免无偏好时锁定在临时物品、表现为"只切两把临时武器"。
    if ac and ac._temp_items[category] then
        local have = {}
        for _, entry in ipairs(ret) do have[entry.item.prefab] = true end
        for _, item in pairs(GetInventorySnapshot()) do
            if ac._temp_items[category][item.prefab] and not have[item.prefab]
               and (ignorePreferences or not IsAutoUnEquipping(item))
               and ItemUtil:GetEquipSlot(item) then
                ret[#ret + 1] = { item = item, priority = GetPriority(category, item, true, target) }
            end
        end
    end

    table.sort(ret, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        -- 同分时按prefab名稳定排序，避免奔雷矛/铥棒等同分物品每次顺序不同
        return (a.item.prefab or "") < (b.item.prefab or "")
    end)

    if cacheKey ~= nil then
        ac._priority_cache[cacheKey] = ret
    end

    return ret
end

local function GetNextItemInPriorityTable(category, item)
    local t = GetItemPriorityTable(category, true)

    -- 候选列表已由 GetItemPriorityTable 统一纳入临时物品（未被识别的），此处无需重复追加。
    local nextItem = t[#t] and t[#t].item

    local found = false
    for i = #t, 1, -1 do
        if t[i].item.prefab == item.prefab then
            found = true
        elseif found then
            nextItem = t[i].item
            break
        end
    end

    return nextItem
end

function ActionController:CycleEquipItem(category, item)
    local nextItem = GetNextItemInPriorityTable(category, item)
    if nextItem and nextItem.prefab ~= item.prefab then
        InventoryUtil:Equip(nextItem)
    else
        self:UseItem(item)
    end
end

function ActionController:EquipItem(item)
    if item and ItemUtil:GetEquipSlot(item) then
        InventoryUtil:Equip(item)
    end
end

local function GetBestItem(category, target)
    local itemPriorityTable = GetItemPriorityTable(category, false, target)
    return itemPriorityTable[1]
       and itemPriorityTable[1].item
end

function ActionController:GetAutoEquipCategoryItem(target)
    -- 攻击只返回"按钮上的那个武器"（即用户选择 Preferences.User[category]），不做任何偏好/优先级计算。
    local category = Preferences.AutoEquipCategory
    local selected = Preferences.User[category]
    if selected then
        for _, item in pairs(GetInventorySnapshot()) do
            if item.prefab == selected and not IsAutoUnEquipping(item) then
                return item
            end
        end
    end
    return GetBestItem(category, target)
end

function ActionController:ChangePreferredItem(category, item)
    local nextItem = GetNextItemInPriorityTable(category, item)
    if nextItem then
        Preferences.User[category] = nextItem.prefab
        if self.inst.HUD and self.inst.HUD.controls.inv.buttons then
            self.inst.HUD.controls.inv.buttons:Refresh()
        end
        Say(("[%s] " .. MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.PREFERRED_ITEM):format(category, nextItem.name))
    end
end

function ActionController:SavePreferredItem(category, prefab)
    Preferences.User[category] = prefab
end

function ActionController:GetUserPrefab(category)
    return Preferences.User[category]
end

function ActionController:SetAutoEquipCategory(category)
    if Categories[category].autoequip then
        Preferences.AutoEquipCategory = category
        Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.AUTO_EQUIP_CATEGORY, category))
    end
end

function ActionController:UseItem(item)
    if not item then
        return
    end

    if ItemUtil:GetEquipSlot(item) then
        for _, invItem in pairs(InventoryUtil:GetEquips()) do
            if invItem.prefab == item.prefab and not invItem:HasTag("fueldepleted") then
                if InventoryUtil:HasFreeSlot() then
                    InventoryUtil:Unequip(invItem)
                else
                    Say(
                        string.format(
                            MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.CANNOT_UNEQUIP,
                            invItem.name
                        )
                    )
                end
                return
            end
        end
        InventoryUtil:Equip(item)
        return
    end

    InventoryUtil:UseItemFromInvTile(item)
end

function ActionController:AddTempItem(category, item)
    if not item then
        return false
    end
    if not ItemUtil:GetEquipSlot(item) then
        return false
    end
    if not self._temp_items[category] then
        self._temp_items[category] = {}
    end
    self._temp_items[category][item.prefab] = true
    Preferences.User[category] = item.prefab
    self:_SaveTempItems()
    if self.inst.HUD and self.inst.HUD.controls.inv.buttons then
        self.inst.HUD.controls.inv.buttons:Refresh()
    end
    Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.TEMP_ITEM_ADDED, item.name, category))
    return true
end

function ActionController:RemoveTempItem(category, item)
    local tempSet = self._temp_items[category]
    if not tempSet or not item or not tempSet[item.prefab] then
        return false
    end
    local was_pref = (Preferences.User[category] == item.prefab)
    tempSet[item.prefab] = nil
    if not next(tempSet) then
        self._temp_items[category] = nil
        Preferences.User[category] = nil
    elseif was_pref then
        -- 如果移除的是当前偏好物品，切换到下一个临时物品
        local nextPref = next(tempSet)
        Preferences.User[category] = nextPref
    end
    self:_SaveTempItems()
    if self.inst.HUD and self.inst.HUD.controls.inv.buttons then
        self.inst.HUD.controls.inv.buttons:Refresh()
    end
    Say(string.format(MOD_EQUIPMENT_CONTROL.STRINGS.PROMPTS.TEMP_ITEM_REMOVED, item.name))
    return true
end

function ActionController:_SaveTempItems()
    FileSystem:SaveStringToFile("equipment_control_temp_items", json.encode(self._temp_items), false)
end

function ActionController:GetItemFromCategory(category)
    -- 与攻击路径一致：直接返回按钮上的武器（用户选择），无偏好/优先级；
    -- 仅当未选择或选中武器不可用时退回真实伤害最高的。
    local selected = Preferences.User[category]
    if selected then
        for _, item in pairs(GetInventorySnapshot()) do
            if item.prefab == selected and not IsAutoUnEquipping(item) then
                return item
            end
        end
    end
    return GetBestItem(category)
end

function ActionController:GetItemsFromCategory(category)
    local ret = {}
    local seen = {}

    local tempSet = self._temp_items[category]
    -- 所有临时物品置顶
    if tempSet then
        for _, item in pairs(GetInventorySnapshot()) do
            if tempSet[item.prefab] and not seen[item.prefab] then
                ret[#ret + 1] = item
                seen[item.prefab] = true
            end
        end
    end

    -- 其余物品按优先级排列（排除已添加的临时物品）
    for _, t in pairs(GetItemPriorityTable(category)) do
        if not seen[t.item.prefab] then
            ret[#ret + 1] = t.item
            seen[t.item.prefab] = true
        end
    end

    return ret
end

-- 开启刷新窗口：窗口内复用同一份库存快照 + 各分类的优先级结果
function ActionController:BeginRefresh()
    self._refresh_id = self._refresh_id + 1
    self._priority_cache = {}
    self._cached_inventory = nil
    self._refresh_active = true
    self._refresh_started = GetTime()
end

-- 结束刷新窗口：窗口外一律实时取库存，保证不会读到过期数据
function ActionController:EndRefresh()
    self._cached_inventory = nil
    self._refresh_active = false
end

KeybindService:AddKey("DROPKEY", function()
    for _, item in pairs(InventoryUtil:GetPlayerInventory(true, true)) do
        if item and item.prefab == "lantern" and not item:HasTag("fueldepleted") then
            InventoryUtil:DropItemFromInvTile(item)
            return
        end
    end
end)

return ActionController