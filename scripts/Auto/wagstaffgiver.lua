-- Wagstaff 自动递工具：附近有约束静电时，自动给 Wagstaff 递工具
local InventoryUtil = require "util/inventoryutil"
local WorldUtil = require "util/worldutil"
local Say = require "util/say"

local function Init()
    local tool_wanted = nil
    AddPrefabPostInit("wagstaff_npc", function(inst)
        if WorldUtil:IsMasterSim() then return end
        local old_say = inst.components.talker.Say
        inst.components.talker.Say = function(self, script, ...)
            for i = 1, 5 do
                if type(script) == "string" and script:find("WAGSTAFF_NPC_WANT_TOOL_" .. i) then
                    tool_wanted = "wagstaff_tool_" .. i
                    local px, _, pz = ThePlayer.Transform:GetWorldPosition()
                    local has_static = false
                    for _, e in ipairs(TheSim:FindEntities(px, 0, pz, 40, {"moonstorm_static"}, {"INLIMBO"})) do
                        if e:IsValid() then has_static = true; break end
                    end
                    if has_static then
                        local tool = InventoryUtil:FindItemAnywhere(tool_wanted)
                        if tool then
                            -- 走 InventoryUtil 包装器（= 原生调用，单世界免 RPC、多世界内部自理）；
                            -- 不能改用 InventoryUtil:UseItemOnItem（需显式传 action，不等价）
                            -- 参数顺序＝官方签名 ControllerUseItemOnItemFromInvTile(item, active_item)：
                            -- 第一个是**目标**、第二个是**被使用的物品**（服务端走
                            -- GetItemUseAction(active_item, item)），所以给 NPC 递工具是 (inst, tool)。
                            InventoryUtil:ControllerUseItemOnItemFromInvTile(inst, tool)
                            Say("Equipment Control：已自动递 " .. (GLOBAL.STRINGS.NAMES["WAGSTAFF_TOOL_" .. i] or tool_wanted))
                            tool_wanted = nil
                            break
                        end
                    end
                end
            end
            return old_say(self, script, ...)
        end
    end)
end
table.insert(MOD_EQUIPMENT_CONTROL.AutoInits, Init)