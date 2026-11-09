-- 染色服务
-- 统一 filterattack / filterpickup 的红色染色逻辑
-- 用于标记被过滤的实体

local TintService = {}

local FILTERED_COLOR = { 1, 0, 0, 1 }   -- 红色
local NORMAL_COLOR   = { 1, 1, 1, 1 }   -- 正常

--- 将实体染为红色（标记为已过滤）
function TintService:AddColor(ent)
    if ent and ent.AnimState then
        ent.AnimState:SetMultColour(FILTERED_COLOR[1], FILTERED_COLOR[2], FILTERED_COLOR[3], FILTERED_COLOR[4])
    end
end

--- 恢复实体正常颜色（取消过滤标记）
function TintService:RemoveColor(ent)
    if ent and ent.AnimState then
        ent.AnimState:SetMultColour(NORMAL_COLOR[1], NORMAL_COLOR[2], NORMAL_COLOR[3], NORMAL_COLOR[4])
    end
end

--- 遍历所有实体，将 prefab 匹配的实体染色/恢复
--- @param prefab string 要匹配的 prefab 名
--- @param add boolean true=染色, false=恢复
function TintService:TintAllByPrefab(prefab, add)
    local fn = add and self.AddColor or self.RemoveColor
    for _, ent in pairs(Ents) do
        if ent.prefab == prefab then
            fn(self, ent)
        end
    end
end

--- 创建 AddPrefabPostInitAny 回调，自动为新创建的实体染色
--- @param isFilteredFn function(ent) -> boolean 判断实体是否应被染色
--- @return function(inst) 传给 AddPrefabPostInitAny
function TintService:MakeTintIfFiltered(isFilteredFn)
    return function(inst)
        if inst and inst.AnimState and isFilteredFn(inst) then
            inst.AnimState:SetMultColour(FILTERED_COLOR[1], FILTERED_COLOR[2], FILTERED_COLOR[3], FILTERED_COLOR[4])
        end
    end
end

return TintService