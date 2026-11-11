local skilltreedefs = require("prefabs/skilltree_defs")

local SkillTreeUtil = Class(function(self)
    self.initialized = false
    self.character_prefab = nil
    self.skilltree_updater = nil

    self._on_activate_callbacks = {}
    self._on_deactivate_callbacks = {}
    self._on_initialized_callbacks = {}
    self._on_xp_changed_callbacks = {}
end)

-- =============================================
-- 内部初始化
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:Reset()
    self.initialized = false
    self.character_prefab = nil
    self.skilltree_updater = nil
    self._on_initialized_callbacks = {}
    self._on_activate_callbacks = {}
    self._on_deactivate_callbacks = {}
    self._on_xp_changed_callbacks = {}
end

-- 来源：官方：ThePlayer on*skill_client 事件 + components.skilltreeupdater
function SkillTreeUtil:TryInit()
    -- 换人检测：角色变了或组件引用失效 → 重置
    if self.initialized then
        if not ThePlayer
            or ThePlayer.prefab ~= self.character_prefab
            or not ThePlayer.components
            or ThePlayer.components.skilltreeupdater ~= self.skilltree_updater
        then
            self:Reset()
        else
            return true
        end
    end
    if not ThePlayer or not ThePlayer.prefab then
        print("[SkillTreeUtil] 初始化失败: ThePlayer 未就绪")
        return false
    end
    if not ThePlayer.components or not ThePlayer.components.skilltreeupdater then
        print("[SkillTreeUtil] 初始化失败: skilltreeupdater 未就绪")
        return false
    end

    self.character_prefab = ThePlayer.prefab
    self.skilltree_updater = ThePlayer.components.skilltreeupdater
    self.initialized = true

    print("[SkillTreeUtil] 已初始化角色: " .. self.character_prefab)

    ThePlayer:ListenForEvent("onactivateskill_client", function(_, data)
        if data and data.skill then
            self:_FireCallbacks(self._on_activate_callbacks, data.skill)
        end
    end, ThePlayer)

    ThePlayer:ListenForEvent("ondeactivateskill_client", function(_, data)
        if data and data.skill then
            self:_FireCallbacks(self._on_deactivate_callbacks, data.skill)
        end
    end, ThePlayer)

    ThePlayer:ListenForEvent("onaddskillxp_client", function(_, data)
        if data then
            self:_FireCallbacks(self._on_xp_changed_callbacks, data.amount, data.total)
        end
    end, ThePlayer)

    self:_FireCallbacks(self._on_initialized_callbacks)

    return true
end

-- =============================================
-- 回调系统（内部）
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:_FireCallbacks(list, ...)
    if not list then return end
    for _, cb in ipairs(list) do
        local ok, err = pcall(cb, ...)
        if not ok then
            print("SkillTreeUtil: 回调异常 " .. tostring(err))
        end
    end
end

-- =============================================
-- 回调注册
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:OnSkillActivated(fn)
    table.insert(self._on_activate_callbacks, fn)
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:OnSkillDeactivated(fn)
    table.insert(self._on_deactivate_callbacks, fn)
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:OnInitialized(fn)
    table.insert(self._on_initialized_callbacks, fn)
    if self.initialized then
        fn()
    end
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:OnXPChanged(fn)
    table.insert(self._on_xp_changed_callbacks, fn)
end

-- =============================================
-- 基础查询
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetUpdater()
    self:TryInit()
    return self.skilltree_updater
end

-- 来源：官方：prefabs/skilltree_defs.lua 技能定义表
function SkillTreeUtil:HasSkillTree()
    if not ThePlayer then return false end
    return skilltreedefs.SKILLTREE_DEFS[ThePlayer.prefab] ~= nil
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetCharacterPrefab()
    return ThePlayer and ThePlayer.prefab or nil
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:IsReady()
    return self.initialized
end

-- =============================================
-- 技能状态查询
-- =============================================

-- 来源：官方：ThePlayer.components.skilltreeupdater:IsActivated
function SkillTreeUtil:IsSkillActivated(skill_name)
    if not self:TryInit() then return false end
    return self.skilltree_updater:IsActivated(skill_name)
end

-- 来源：官方：ThePlayer.components.skilltreeupdater:GetActivatedSkills
function SkillTreeUtil:GetActivatedSkills()
    if not self:TryInit() then return {} end
    return self.skilltree_updater:GetActivatedSkills() or {}
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetActivatedSkillNames()
    local skills = self:GetActivatedSkills()
    local names = {}
    for name in pairs(skills) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- 来源：官方：scripts/prefabs/wortox.lua:251 RecalculateInclination（注释 "Server and Client ran."）
-- 沃拓克斯倾向：官方客户端在 onactivateskill_client / ondeactivateskill_client 里按
-- skilltree_wortox.lua:95 的 CalculateInclination 算好，写入 inst.wortox_inclination。
-- 这里只做工具层封装，不二次推算；nil = 未倾斜的默认倾向，是官方合法返回值。
-- 不调 TryInit：技能树组件就绪前字段也可能为 nil，那应按默认倾向处理而非当初始化失败。
function SkillTreeUtil:GetInclination(player)
    local p = player or ThePlayer
    return p and p.wortox_inclination
end

-- =============================================
-- 标签查询
-- =============================================

-- 来源：官方：ThePlayer.components.skilltreeupdater:HasSkillTag
function SkillTreeUtil:HasTag(tag)
    if not self:TryInit() then return false end
    return self.skilltree_updater:HasSkillTag(tag)
end

-- 来源：官方：ThePlayer.components.skilltreeupdater:CountSkillTag
function SkillTreeUtil:CountTag(tag)
    if not self:TryInit() then return false end
    return self.skilltree_updater:CountSkillTag(tag)
end

-- =============================================
-- 远程玩家技能查询
-- =============================================

-- 来源：官方：TheNet:GetClientTable() + 官方技能标签
function SkillTreeUtil:_GetSkillNamesForPlayer(player)
    if player == ThePlayer then
        return self:GetActivatedSkills()
    end

    local clients = TheNet:GetClientTable()
    if not clients then return nil end

    for _, client in ipairs(clients) do
        if client.userid == player.userid and client.skillselection and TheSkillTree then
            local ok, result = pcall(TheSkillTree.GetNamesFromSkillSelection, TheSkillTree, client.skillselection, client.prefab)
            if ok and result then
                local names = {}
                for k, v in pairs(result) do
                    names[type(k) == "number" and v or k] = true
                end
                return names
            end
            break
        end
    end
    return nil
end

-- 来源：官方：TheNet:GetClientTable()（经 _GetSkillNamesForPlayer）+ 官方技能标签
function SkillTreeUtil:IsSkillActivatedOnPlayer(player, skill_name)
    local names = self:_GetSkillNamesForPlayer(player)
    if names then
        return names[skill_name] == true
    end
    return false
end

-- 来源：官方：TheNet:GetClientTable()（经 _GetSkillNamesForPlayer）+ 官方技能标签
function SkillTreeUtil:GetActivatedSkillsOnPlayer(player)
    return self:_GetSkillNamesForPlayer(player) or {}
end

-- 来源：官方：TheNet:GetClientTable()（经 _GetSkillNamesForPlayer）+ 官方技能标签
function SkillTreeUtil:GetActivatedSkillNamesOnPlayer(player)
    local names = self:_GetSkillNamesForPlayer(player)
    if not names then return {} end
    local list = {}
    for name in pairs(names) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

-- 来源：官方：TheNet:GetClientTable()（经 _GetSkillNamesForPlayer）+ 官方技能标签
function SkillTreeUtil:HasTagOnPlayer(player, tag)
    local names = self:_GetSkillNamesForPlayer(player)
    if not names then return false end
    local defs = skilltreedefs.SKILLTREE_DEFS[player.prefab]
    if not defs then return false end
    for name in pairs(names) do
        local info = defs[name]
        if info and info.tags then
            for _, t in ipairs(info.tags) do
                if t == tag then return true end
            end
        end
    end
    return false
end

-- 来源：官方：TheNet:GetClientTable()（经 _GetSkillNamesForPlayer）+ 官方技能标签
function SkillTreeUtil:CountTagOnPlayer(player, tag)
    local names = self:_GetSkillNamesForPlayer(player)
    if not names then return 0 end
    local defs = skilltreedefs.SKILLTREE_DEFS[player.prefab]
    if not defs then return 0 end
    local count = 0
    for name in pairs(names) do
        local info = defs[name]
        if info and info.tags then
            for _, t in ipairs(info.tags) do
                if t == tag then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
end

-- =============================================
-- 经验值查询
-- =============================================

-- 来源：官方：ThePlayer.components.skilltreeupdater:GetSkillXP
function SkillTreeUtil:GetSkillXP()
    if not self:TryInit() then return 0 end
    return self.skilltree_updater:GetSkillXP()
end

-- 来源：官方：ThePlayer.components.skilltreeupdater:GetAvailableSkillPoints
function SkillTreeUtil:GetAvailablePoints()
    if not self:TryInit() then return 0 end
    return self.skilltree_updater:GetAvailableSkillPoints()
end

-- 来源：官方：TheSkillTree:GetMaximumExperiencePoints（skilltreedata.lua:50）
function SkillTreeUtil:GetMaxXP()
    return TheSkillTree and TheSkillTree:GetMaximumExperiencePoints() or 0
end

-- 来源：官方：ThePlayer.components.skilltreeupdater:GetPointsForSkillXP
function SkillTreeUtil:GetPointsForXP(xp)
    if not self:TryInit() then return 0 end
    return self.skilltree_updater:GetPointsForSkillXP(xp or self:GetSkillXP())
end

-- =============================================
-- 技能定义查询
-- =============================================

-- 来源：官方：prefabs/skilltree_defs.lua 技能定义表
function SkillTreeUtil:GetSkillDefs()
    if not ThePlayer then return nil end
    return skilltreedefs.SKILLTREE_DEFS[ThePlayer.prefab]
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetAllSkillNames()
    local defs = self:GetSkillDefs()
    if not defs then return {} end
    local names = {}
    for name in pairs(defs) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetAllSkillsInfo()
    return self:GetSkillDefs() or {}
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetSkillInfo(skill_name)
    local defs = self:GetSkillDefs()
    return defs and defs[skill_name] or nil
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetSkillTags(skill_name)
    local info = self:GetSkillInfo(skill_name)
    return info and info.tags or {}
end

-- 来源：官方：prefabs/skilltree_defs.lua 技能定义表
function SkillTreeUtil:GetMetaInfo()
    if not ThePlayer then return nil end
    return skilltreedefs.SKILLTREE_METAINFO[ThePlayer.prefab]
end

-- =============================================
-- 分组查询
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetActivatedSkillsByGroup(group_tag)
    local result = {}
    local defs = self:GetSkillDefs()
    if not defs then return result end

    local activated = self:GetActivatedSkills()
    for skill_name in pairs(activated) do
        local info = defs[skill_name]
        if info and info.group == group_tag then
            result[skill_name] = info
        end
    end
    return result
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetActivatedSkillsGrouped()
    local result = {}
    local defs = self:GetSkillDefs()
    if not defs then return result end

    local activated = self:GetActivatedSkills()
    for skill_name in pairs(activated) do
        local info = defs[skill_name]
        if info then
            local group = info.group or "__ungrouped"
            if not result[group] then
                result[group] = {}
            end
            table.insert(result[group], skill_name)
        end
    end
    return result
end

-- 来源：官方：prefabs/skilltree_defs.lua 技能定义表
function SkillTreeUtil:GetSkillTreeOrders()
    if not ThePlayer then return nil end
    return skilltreedefs.SKILLTREE_ORDERS[ThePlayer.prefab]
end

-- =============================================
-- 个性化适配匹配
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:MatchSkills(match_map, match_by_tag)
    local result = {}
    if match_by_tag then
        for tag, handler in pairs(match_map) do
            if self:HasTag(tag) then
                result[tag] = handler
            end
        end
    else
        for skill_name, handler in pairs(match_map) do
            if self:IsSkillActivated(skill_name) then
                result[skill_name] = handler
            end
        end
    end
    return result
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:ApplySkillMatches(match_map, match_by_tag)
    local matches = self:MatchSkills(match_map, match_by_tag)
    for key, handler in pairs(matches) do
        local ok, err = pcall(handler)
        if not ok then
            print("SkillTreeUtil: ApplySkillMatches 异常 [" .. tostring(key) .. "] " .. tostring(err))
        end
    end
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:BindSkillAdapt(match_map, match_by_tag)
    local function get_handlers(skill_name)
        if match_by_tag then
            local handlers = {}
            for _, tag in ipairs(self:GetSkillTags(skill_name)) do
                if match_map[tag] then
                    for k, v in pairs(match_map[tag]) do
                        handlers[k] = v
                    end
                end
            end
            return next(handlers) and handlers or nil
        end
        return match_map[skill_name]
    end

    self:OnInitialized(function()
        for key, handlers in pairs(match_map) do
            local active = match_by_tag and self:HasTag(key) or self:IsSkillActivated(key)
            if active and handlers.on then
                handlers.on()
            end
        end
    end)

    self:OnSkillActivated(function(skill_name)
        local handlers = get_handlers(skill_name)
        if handlers and handlers.on then handlers.on(skill_name) end
    end)

    self:OnSkillDeactivated(function(skill_name)
        local handlers = get_handlers(skill_name)
        if handlers and handlers.off then handlers.off(skill_name) end
    end)
end

-- =============================================
-- 快照输出
-- =============================================

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:GetSnapshot()
    local all_names = self:GetAllSkillNames()
    local activated_names = self:GetActivatedSkillNames()
    local groups = self:GetActivatedSkillsGrouped()

    return {
        character = self:GetCharacterPrefab(),
        has_skilltree = self:HasSkillTree(),
        ready = self:IsReady(),
        skill_xp = self:GetSkillXP(),
        max_xp = self:GetMaxXP(),
        available_points = self:GetAvailablePoints(),
        total_points = self:GetPointsForXP(self:GetSkillXP()),
        all_skills = all_names,
        all_skills_count = #all_names,
        activated_skills = activated_names,
        activated_count = #activated_names,
        groups = groups,
    }
end

-- 来源：模组自实现：基于官方技能树数据的本地聚合/回调
function SkillTreeUtil:Dump()
    local snap = self:GetSnapshot()
    print("========================================")
    print("SkillTreeUtil 快照")
    print("  角色: " .. tostring(snap.character))
    print("  有技能树: " .. tostring(snap.has_skilltree))
    print("  就绪: " .. tostring(snap.ready))
    print("  经验: " .. snap.skill_xp .. " / " .. snap.max_xp)
    print("  技能点: " .. snap.total_points .. " 总计, " .. snap.available_points .. " 可用")
    print("  技能: " .. snap.activated_count .. " / " .. snap.all_skills_count .. " 已激活")
    print("  已激活 (" .. snap.activated_count .. "):")
    for _, name in ipairs(snap.activated_skills) do
        local info = self:GetSkillInfo(name)
        local tags = info and table.concat(info.tags or {}, ", ") or ""
        print("    - " .. name .. (tags ~= "" and (" [" .. tags .. "]") or ""))
    end
    print("  分组:")
    for group, skills in pairs(snap.groups) do
        print("    [" .. group .. "] " .. table.concat(skills, ", "))
    end
    print("========================================")
end


return SkillTreeUtil
