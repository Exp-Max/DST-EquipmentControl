local ItemUtil = require "util/itemutil"
local InventoryUtil = require "util/inventoryutil"
local ActionUtil = require "util/actionutil"
local quickDeployEnabled = GetModConfigData("QUICK_ACTION_QUICK_DEPLOY")

if quickDeployEnabled then

    --
    -- 手持可部署物品点击世界 → 远距离部署，将 DEPLOY 替换为 DEPLOY_FLOATING 突破距离限制。
    -- 手持时走官方 placer 预览，无需 EC 介入；右键路径已被下方 RPC 拦截绕过，不会进入此钩子。
    --
    local PlayerController = require "components/playercontroller"
    local OldDoAction = PlayerController.DoAction
    function PlayerController:DoAction(buffaction, spellbook, ...)
        if self.inst == ThePlayer and
            ActionUtil:IsValidBufferedAction(buffaction) and buffaction.action == ACTIONS.DEPLOY then
            buffaction.action = ACTIONS.DEPLOY_FLOATING
        end
        return OldDoAction(self, buffaction, spellbook, ...)
    end

    --
    -- 受限部署物 × 勋章联动（部署相关逻辑一律归本模块）
    -- 受限部署物 = 可部署物中"必须由具备某标签的角色才能部署"的那类：
    --   handyperson → 薇诺娜工程物（发电机/聚光灯/投石机等）：巧手勋章佩戴后赋予该标签
    --   masterchef  → 便携厨具（烹饪锅/香料站/研磨器）：厨师勋章组佩戴后赋予该标签
    --   判定统一走 ItemUtil:IsDeployRestrictedTo（比字符串！deployrestrictedtag 是 net_hash，
    --   读出来是数字哈希，见 itemutil 的说明）
    -- 缺标签时官方 CanDeploy 直接拒绝：右键只会是"检查"、ItemUtil:IsDeployable 同样是 false，
    -- 于是"检查→部署"的动作表修饰进不去。故把这类物品也算作快速部署目标，
    -- 并在点击生效前戴上对应勋章取得标签（见 PrepareRestrictedDeploy）。
    --

    local function GetAutoMedalAPI()
        local mec = GLOBAL.MOD_EQUIPMENT_CONTROL
        return mec and mec.automedal_api or nil
    end

    -- 受限部署物 → 所需勋章组；非受限部署物或无对应勋章返回 nil（视为前置不满足）
    local function GetDeployMedalPrefabs(item)
        local api = GetAutoMedalAPI()
        if api == nil then return nil end
        -- 必须按"标签名→hash"比较，不能直接比字符串（net_hash 读出来是数字）
        if ItemUtil:IsDeployRestrictedTo(item, "handyperson") then
            local final = api.GetFinalPrefab("handy_certificate")
            return final ~= nil and { final } or nil
        elseif ItemUtil:IsDeployRestrictedTo(item, "masterchef") then
            -- 按"具备 masterchef 标签"派生（只有大厨/主厨），**不能用整组**：
            --   整组含 test 档 cook_certificate（烹饪勋章，没有 masterchef），戴上既部署不了，
            --   还会顶掉研磨所需的 final 主厨（与 automedal 的 RUMMAGE/STORE/OPEN_CRAFTING 同口径）。
            return api.GetMedalsByPlayerTag("masterchef")
        end
        return nil
    end

    -- 纯判定（无副作用）：该物品能否靠"戴勋章取得标签"变成可部署。
    -- FindMedal 只查库存，无副作用，故可安全用于悬停提示（与点击共用同一判定）。
    -- owner 显式传入而不用 ThePlayer：本判定在**服务端**也会跑（服务端要用它算 actions[1]
    --   来校验客户端发来的动作码，见 inventory.lua:2295），而专服上 ThePlayer 为 nil。
    local function CanRestrictedDeploy(item, owner)
        local tag = item and ItemUtil:GetDeployRestrictedTag(item)
        if tag == nil then return false end
        -- 已具备标签（本人角色、或已戴对应勋章）也算目标：prepare 会自然 no-op，不会多抢勋章
        if owner ~= nil and owner:HasTag(tag) then return true end
        local api = GetAutoMedalAPI()
        if api == nil then return false end
        local prefabs = GetDeployMedalPrefabs(item)
        return prefabs ~= nil and api.FindMedal(prefabs) ~= nil
    end

    -- 快速部署的适用目标：原生可部署，或"受限部署物且能靠勋章取得标签"
    local function IsQuickDeployTarget(item, owner)
        if item == nil then return false end
        return ItemUtil:IsDeployable(item, owner) or CanRestrictedDeploy(item, owner)
    end

    -- A 环节①：官方动作表修饰——把 DEPLOY 顶成 actions[1]。
    -- 悬停提示（itemtile.lua:513）与实际点击（inventory_classified.lua:912）都取这张表的 [1]，
    -- 故改一处即同时生效、结构上不可能分叉；服务端也会跑，保证动作码校验与客户端一致。
    local function RestrictedDeployActionsModifier(actions, item, owner)
        if owner == nil or item == nil then return nil end
        if not IsQuickDeployTarget(item, owner) then return nil end
        local primary = actions[1] ~= nil and actions[1].action or nil
        local is_plain = primary == nil
            or primary == ACTIONS.LOOKAT
            or primary == ACTIONS.TOGGLE_DEPLOY_MODE
            or primary == ACTIONS.DEPLOY
        local is_force = GLOBAL.TheInput ~= nil
            and GLOBAL.TheInput:IsControlPressed(GLOBAL.CONTROL_FORCE_INSPECT)
        if is_plain or is_force then
            return { BufferedAction(owner, nil, ACTIONS.DEPLOY, item, owner:GetPosition()) }
        end
        return actions
    end

    -- A 环节②：前置型处理器——点击生效前补齐部署标签（戴勋章），动作本身交回官方链路。
    -- 挂在 replica 的 UseItemFromInvTile 而非 RPC 层：主机（监听服/单机）走的是
    --   inventory 组件直连、根本不发 RPC（inventory_replica.lua:485），
    --   挂 RPC 层在主机上永远不触发。replica 是主机与客机的共同入口。
    local function PrepareRestrictedDeploy(item, kind)
        if kind ~= "use" then return false end
        -- 鼠标拿着物品时，右键格子的语义是"用手持物对该格子物品使用"（如研磨：食材→物品栏研磨器），
        --   不是部署。此时若仍按部署需求戴勋章，会按整组挑最低档（烹饪档）顶掉刚戴好的 final 主厨，
        --   导致研磨失败——日志实测：同一次点击里先 headchef_certificate、紧接着 cook_certificate。
        if InventoryUtil:GetActiveItem() ~= nil then return false end
        local tag = item and ItemUtil:GetDeployRestrictedTag(item)
        if tag == nil then return false end
        if ThePlayer ~= nil and ThePlayer:HasTag(tag) then return false end
        local api = GetAutoMedalAPI()
        local prefabs = api and GetDeployMedalPrefabs(item)
        if prefabs ~= nil then
            api.AutoEquipMedal(prefabs)
        end
        return false  -- 前置型：不接管，交回官方链路
    end

    --
    -- 覆盖 GetInventoryActions（主机 & 专服客机统一逻辑）：
    --   右键实际会执行的那条动作（排序后的 actions[1]）若是平凡的
    --   "检查 / 切换部署模式"类动作 → 整表替换为"部署"
    --   若有更具意义的右键动作（打开、吃、装备…）→ 保留原生行为
    --   Alt + 右键 → 强制部署所有可部署物品
    --
    -- 为什么判定 actions[1]，而不是像旧实现那样扫描整张表找"有没有其它动作"：
    --   右键执行与悬停提示取的都是同一条 actions[1]——
    --     prefabs/inventory_classified.lua : "local act = actions[1]"
    --     widgets/itemtile.lua            : actions[1]:GetActionString()
    --   排在后面的动作右键永远轮不到，旧判定却因"表里存在其它动作"直接放弃覆盖，
    --   于是客机上本该被替换成"部署"的可部署物品，右键仍旧是"检查"。
    --
    -- 注意：PC 无手柄时 deploy_mode = true，componentactions 不会添加 TOGGLE_DEPLOY_MODE。
    --   但物品本身仍是可部署的且仅有 LOOKAT 等平凡动作，
    --   此时同样应视为"可替换"物品并覆盖为部署。
    --
    -- A 方案的两个环节统一走 actionutil 的通道（与书本阅读同一套机制，不再各自造钩子）：
    --   ① 动作表修饰 → 悬停提示与实际点击的唯一真源
    --   ② 前置型处理器 → 点击前戴勋章，动作仍走官方链路
    -- 全局注册（inst 传 nil）的原因：本文件在 modmain 期执行，那时 ThePlayer 还不存在；
    -- 且动作表修饰必须服务端也生效，否则服务端算出的 actions[1] 与客户端动作码不一致会静默失败。
    -- actionutil 会在 playercontroller / playeractionpicker 挂上时自动补装。
    ActionUtil:RegisterInventoryActionsModifier(nil, 0, RestrictedDeployActionsModifier)
    ActionUtil:RegisterInventoryItemHandler(nil, 0, PrepareRestrictedDeploy)

    --
    -- RPC 拦截：GetInventoryActions 钩子已将"检查"类物品覆盖为 DEPLOY
    -- 此处将 DEPLOY 动作码重定向为 ControllerActionButtonDeploy（脚下部署）
    -- "打开"类物品不会被钩子覆盖，其原生动作码不会进入此拦截
    --
    -- 客机这条链路能走通（已核对官方源码，勿再怀疑）：
    --   右键 → invslot:UseItem → inventory_classified:UseItemFromInvTile 取 actions[1]
    --        → PlayerController:RemoteUseItemFromInvTile 挂 preview_cb
    --        → locomotor:PreviewAction 把 BufferedAction 交给 stategraph
    --        → 客机用的是 stategraphs/SGwilson_client.lua，其 doshortaction 状态
    --          onenter 里调用 inst:PerformPreviewBufferedAction()（见该文件 doshortaction 定义）
    --        → preview_cb 触发，发出 RPC.UseItemFromInvTile(DEPLOY.code, item, controlmods)
    --        → 本拦截改发 RPC.ControllerActionButtonDeploy
    -- 该 RPC 的参数由 networkclientrpc.lua 的 ControllerActionButtonDeploy 校验
    --   (invobject, x, z, rotation, isreleased, platform, platform_relative)，
    --   服务端最终执行 playercontroller:OnRemoteControllerActionButtonDeploy(invobject, Vector3(x,0,z), rotation, isreleased)。
    --
    --
    -- 脚下部署：发出 ControllerActionButtonDeploy（暴露给勋章联动复用，避免各模块重复拼参数）
    -- isreleased = true：键鼠右键没有"按住手柄动作键"这回事，
    --   服务端 OnRemoteControllerActionButtonDeploy 里 isreleased 只用于
    --   remote_controls[CONTROL_CONTROLLER_ACTION] 的记账（nil vs 0），
    --   传 false 会留下"动作键被按住"的残留状态，可能触发服务端重复动作。
    --
    local function DeployAtFeet(item)
        if item == nil then return end
        local x, y, z = ThePlayer.Transform:GetWorldPosition()
        GLOBAL.SendRPCToServer(RPC.ControllerActionButtonDeploy, item, x, z, 0, true, nil, false)
    end

    local OldSendRPCToServer = GLOBAL.SendRPCToServer
    GLOBAL.SendRPCToServer = function(code, ...)
        if code == RPC.UseItemFromInvTile or code == RPC.ControllerUseItemOnSelfFromInvTile then
            local action, item = ...
            local action_code = type(action) == "number" and action or (action and action.action and action.action.code)
            if item and IsQuickDeployTarget(item, ThePlayer) then
                if action_code == ACTIONS.DEPLOY.code then
                    -- 受限部署物的勋章已由 PrepareRestrictedDeploy（replica 前置）戴好，
                    -- 此处只负责把 DEPLOY 重定向为脚下部署。
                    DeployAtFeet(item)
                    return
                end
            end
        end
        return OldSendRPCToServer(code, ...)
    end

    local function RemovePlacementPreview(item)
        if item._placement_preview and item._placement_preview:IsValid() then
            item._placement_preview:Remove()
            item._placement_preview = nil
        end
    end

    --
    -- 玩家脚下放置预览：手动创建 placer（复用游戏本体 placer prefab），固定在玩家脚下
    -- 游戏本体 placer prefab 自带 deployhelper_key → 发电机范围联动自动生效
    --
    local function CreatePlacementPreview(item)
        if item._placement_preview then
            return
        end

        local placer_name = item.replica.inventoryitem:GetDeployPlacerName()
        if not placer_name then
            return
        end

        local placer_inst = GLOBAL.SpawnPrefab(placer_name)
        if not placer_inst or not placer_inst.components.placer then
            if placer_inst then placer_inst:Remove() end
            return
        end

        item._placement_preview = placer_inst
        local placer = placer_inst.components.placer
        placer:SetBuilder(GLOBAL.ThePlayer, nil, item)

        placer.testfn = function(pt)
            if not item:IsValid() or not item.replica.inventoryitem then
                return false, false
            end
            return item.replica.inventoryitem:CanDeploy(pt, nil, GLOBAL.ThePlayer, 0)
        end

        for _, v in ipairs(placer.linked) do
            v:Show()
        end

        local main_build = placer_inst.AnimState:GetBuild()
        if not main_build or not main_build:find("placement") then
            placer_inst.AnimState:SetMultColour(0, 0, 0, 0)
        end

        placer.OnUpdate = function(self, dt)
            if not item:IsValid() or not item.replica.inventoryitem
                or not item.replica.inventoryitem:IsDeployable(GLOBAL.ThePlayer) then
                RemovePlacementPreview(item)
                return
            end

            local is_held = InventoryUtil:GetActiveItem() == item
            if is_held then
                self.inst:Hide()
                for _, v in ipairs(self.linked) do
                    v:Hide()
                end
                return
            end

            local x, y, z = GLOBAL.ThePlayer.Transform:GetWorldPosition()
            self.inst.Transform:SetPosition(x, y, z)

            GLOBAL.TriggerDeployHelpers(x, y, z, 64, self.recipe, self.inst)

            self.can_build, self.mouse_blocked = self:TestCanBuild()
            if self.can_build and not self.mouse_blocked then
                self.inst.AnimState:SetAddColour(.25, .75, .25, 0)
                self.inst:Show()
                for _, v in ipairs(self.linked) do
                    v.AnimState:SetMultColour(1, 1, 1, 1)
                    v.AnimState:SetAddColour(.25, .75, .25, 0)
                    v:Show()
                end
            elseif not self.can_build and not self.mouse_blocked then
                self.inst.AnimState:SetAddColour(.75, .25, .25, 0)
                self.inst:Show()
                for _, v in ipairs(self.linked) do
                    v.AnimState:SetMultColour(1, 1, 1, 1)
                    v.AnimState:SetAddColour(.75, .25, .25, 0)
                    v:Show()
                end
            else
                self.inst:Hide()
                for _, v in ipairs(self.linked) do
                    v:Hide()
                end
            end
        end

        local x, y, z = GLOBAL.ThePlayer.Transform:GetWorldPosition()
        placer_inst.Transform:SetPosition(x, y, z)
        GLOBAL.TriggerDeployHelpers(x, y, z, 64, placer.recipe, placer_inst)
        local can_build, mouse_blocked = placer:TestCanBuild()
        if can_build and not mouse_blocked then
            placer_inst.AnimState:SetAddColour(.25, .75, .25, 0)
            for _, v in ipairs(placer.linked) do
                v.AnimState:SetMultColour(1, 1, 1, 1)
                v.AnimState:SetAddColour(.25, .75, .25, 0)
            end
        elseif not can_build and not mouse_blocked then
            placer_inst.AnimState:SetAddColour(.75, .25, .25, 0)
            for _, v in ipairs(placer.linked) do
                v.AnimState:SetMultColour(1, 1, 1, 1)
                v.AnimState:SetAddColour(.75, .25, .25, 0)
            end
        end
    end

    --
    -- 接入 widgets/itemtile：鼠标悬停时在玩家脚下显示放置预览
    --
    AddClassPostConstruct("widgets/itemtile", function(self)
        local old_OnGainFocus = self.OnGainFocus
        local old_OnLoseFocus = self.OnLoseFocus

        self.OnGainFocus = function(self)
            if old_OnGainFocus then
                old_OnGainFocus(self)
            end

            if self.item and ItemUtil:IsDeployable(self.item, ThePlayer) then
                local is_held = InventoryUtil:GetActiveItem() == self.item
                if not is_held then
                    CreatePlacementPreview(self.item)
                end
            end
        end

        self.OnLoseFocus = function(self)
            if old_OnLoseFocus then
                old_OnLoseFocus(self)
            end

            if self.item then
                RemovePlacementPreview(self.item)
            end
        end
    end)

    --
    -- 受限部署物的放置预览：不放宽为 IsQuickDeployTarget。
    -- 缺标签时 placer 的 CanDeploy 恒 false，预览会一直是红色"不可建造"，
    -- 反而误导（实际右键能靠戴勋章部署成功）。故只在原生确实可部署时才显示预览。
    --
end