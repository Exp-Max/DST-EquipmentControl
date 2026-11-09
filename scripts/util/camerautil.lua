-- CameraUtil — 镜头（camera）相关工具类型（local + return，require 加载）。
-- 全部是无 self 的静态工具函数，一律点号定义 + 点号调用；有 self 的方法才用冒号。
-- 只做官方 TheCamera API 的薄透传与纯逻辑封装，不自建监听表 / 状态机；
-- hook 的安装（AddClassPostConstruct）放在 modmain。
--
-- 游戏本体的镜头缩放有且仅有两个入口（已核对 data/databundles/scripts.zip）：
--   · 滚轮：input 派发 "zoomcamera" 事件 → playercontroller:OnZoom → TheCamera:ZoomIn/ZoomOut
--   · 按住缩放键：playercontroller:DoCameraControl → TheCamera:ZoomIn/ZoomOut（CONTROL_ZOOM_IN/OUT）
--   两个入口最终都调用 TheCamera:ZoomIn / TheCamera:ZoomOut，因此拦截这两个方法即覆盖全部缩放路径；
--   镜头旋转（Q/E、中键拖拽）走 DoCameraControl 的另支路，本模块有意不拦截。

local CameraUtil = {}

-- 鼠标是否悬停在任意带 _ec_zoom_capture 标记的面板内（含该面板的任意子控件/纯背景）。
-- 依赖面板 widget 上的 _ec_zoom_capture 标记（confighud / 自动烹饪面板等已打此标记），
-- 通过 GetHUDEntityUnderMouse 命中实体回溯父链识别（纯 Image 背景也算命中，无需可点击）。
function CameraUtil.IsOverCapturePanel()
    if TheInput == nil or TheInput.GetHUDEntityUnderMouse == nil then
        return false
    end
    local inst = TheInput:GetHUDEntityUnderMouse()
    if inst == nil then
        return false
    end
    local w = inst.widget
    while w ~= nil do
        if w._ec_zoom_capture then
            return true
        end
        w = w:GetParent()
    end
    return false
end

-- 包裹 PlayerController:DoCameraControl，返回新的函数（不在此安装 hook）：
--   (1) confighud 抽屉展开且焦点在面板上 → 整段跳过镜头控制（滚轮只滚列表、不缩放）；
--       —— 镜像官方 craftingmenu.focus（菜单打开且焦点在菜单上时整段跳过缩放）。
--   (2) quickZoom 为 true 时，按住 Ctrl → 额外做 Ctrl+滚轮缩放视角。
function CameraUtil.WrapDoCameraControl(oldFn, quickZoom)
    return function(self)
        local hud = self.inst ~= nil and self.inst.HUD or nil

        -- (1) confighud 焦点闸门
        if hud ~= nil and hud.controls ~= nil then
            local ch = hud.controls._ec_confighud
                or (hud.controls.right_root ~= nil and hud.controls.right_root._ec_confighud)
            if ch ~= nil and ch:IsOpen() and ch.focus then
                return
            end
        end

        -- (2) Ctrl+滚轮缩放
        if quickZoom then
            local IsEnabled = self.IsEnabled
            self.IsEnabled = function(...)
                local ok, block = IsEnabled(...)
                if ok or (block == nil and not (hud ~= nil and hud:IsVisible() and hud:HasInputFocus())) then
                    return true
                end
                return ok, block
            end
            oldFn(self)
            self.IsEnabled = IsEnabled
            if TheInput:IsControlPressed(CONTROL_FORCE_TRADE) then
                local step = 2
                if TheInput:IsControlPressed(CONTROL_ZOOM_IN) then
                    TheCamera:ZoomIn(step)
                elseif TheInput:IsControlPressed(CONTROL_ZOOM_OUT) then
                    TheCamera:ZoomOut(step)
                end
            end
            return
        end

        return oldFn(self)
    end
end

-- 包裹 TheCamera:ZoomIn / ZoomOut：鼠标悬停在 EC 面板内时变空操作（只禁缩放、保留旋转），
-- 覆盖滚轮 "zoomcamera" 事件与按住缩放键两条路径。不在此安装 hook（幂等由调用方负责）。
function CameraUtil.WrapZoom(camera)
    if camera == nil or camera.ZoomIn == nil then
        return
    end
    local OldZoomIn  = camera.ZoomIn
    local OldZoomOut = camera.ZoomOut
    camera.ZoomIn = function(cam, ...)
        if CameraUtil.IsOverCapturePanel() then
            return
        end
        return OldZoomIn(cam, ...)
    end
    camera.ZoomOut = function(cam, ...)
        if CameraUtil.IsOverCapturePanel() then
            return
        end
        return OldZoomOut(cam, ...)
    end
end

--------------------------------------------------
-- 官方相机 API 薄透传（无 self → 点号；不自建状态机）
--------------------------------------------------

-- 官方依据（data/databundles/scripts.zip）：
--   scripts/cameras/followcamera.lua:558-564 AddListener / :566-576 RemoveListener
--   scripts/cameras/followcamera.lua:527-529,532-548 引擎每帧 Apply() 后回调监听者
--   scripts/components/reticule.lua:69,84 官方准星用同一对 API 逐帧跟随镜头
--   scripts/widgets/followtext.lua:49-63 官方跟随世界实体的 UI 也是逐帧换算屏幕坐标
-- 逐帧跟随才能平滑；回调由官方相机统一驱动，模组不建定时任务、不自建状态机。
-- 返回是否注册成功，供调用方决定是否下次重试。
function CameraUtil.AddListener(src, cb)
    if src == nil or cb == nil or TheCamera == nil then
        return false
    end
    TheCamera:AddListener(src, cb)
    return true
end

function CameraUtil.RemoveListener(src, cb)
    if src == nil or cb == nil or TheCamera == nil then return end
    TheCamera:RemoveListener(src, cb)
end

-- 直接读官方相机距离字段；兜底 30 取自官方默认值（followcamera.lua:35）。
function CameraUtil.GetDistance()
    return TheCamera ~= nil and TheCamera.distance or 30
end

return CameraUtil
