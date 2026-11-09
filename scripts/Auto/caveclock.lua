-- 洞穴时钟：移植自创意工坊模组 Lazy Controls（workshop-2111412487）的 main/modules/cave_clock.lua
--
-- 官方机制（scripts/widgets/uiclock.lua，实测自 data/databundles/scripts.zip）：
--   L31  self._cave = TheWorld:HasTag("cave")；洞穴时钟 UI（_rim/_hands）仅 _cave 为真时构建（L98）
--   L207 OpenCaveClock() 首行 `if not self._cave or self._caveopen == true then return`
--        → 地表恒 no-op，且幂等（已开则直接返回）
--   L187 UpdateCaveClock(owner)：仅靠近 sinkhole（tags "sinkhole"+"lightsource"）时 Open，否则 Close
--   唯一调用点 widgets/controls.lua:162/192/218，且仅当 IsCaveClock() 为真才创建 0.5s 周期任务
--   ⇒ 本功能只在洞穴世界生效；地表没有"洞穴时钟"可显示（非 bug，官方机制如此）。
--
-- 移植要点（对照原模组，修掉上一版的 3 处偏差）：
--   1) 必须在 modimport 加载期注册 AddClassPostConstruct：它只包装类的构造函数，对**已存在的实例无效**；
--      HUD/UIClock 在 prefabs/player_common.lua:741 已构建，:826 才 push playeractivated，
--      上一版放在 Init()/AutoInits 里注册 → 包装根本没挂到屏幕上那个时钟（失效主因）。
--   2) 强制开启时【不能】再调用官方 UpdateCaveClock：官方在远离 sinkhole 时会 CloseCaveClock()，
--      会把刚打开的立刻关掉。原模组是**二选一分支**，不是"先 Open 再 old"。（上一版行为错误）
--   3) 保留原模组的点击切换：洞穴中聚焦时钟按确认键，在"强制显示 / 正常"之间切换。

local MODNAME = MOD_EQUIPMENT_CONTROL.MODNAME
local Say = require "util/say"

if GetModConfigData("QUICK_ACTION_CAVECLOCK", MODNAME) then
    local force_open = true  -- 初始值跟随配置（开启=默认强制显示），运行中可由点击切换

    AddClassPostConstruct("widgets/uiclock", function(self)
        local Old_UpdateCaveClock = self.UpdateCaveClock
        self.UpdateCaveClock = function(self, owner, ...)
            if force_open then
                -- 强制常开：独占分支，绝不回落官方逻辑（官方会 CloseCaveClock 撤销）
                self:OpenCaveClock()
                return
            end
            return Old_UpdateCaveClock(self, owner, ...)
        end

        -- 洞穴中聚焦时钟、按下确认键 → 切换"强制显示 / 正常"
        local Old_OnControl = self.OnControl
        self.OnControl = function(self, control, down, ...)
            if down and control == GLOBAL.CONTROL_ACCEPT
                and self.focus and self:IsCaveClock() then
                force_open = not force_open
                Say("洞穴时钟：" .. (force_open and "强制显示" or "正常"))
            end
            return Old_OnControl(self, control, down, ...)
        end
    end)
end
