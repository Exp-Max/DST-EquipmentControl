local KH = require("util/keyhandlers")

local ModKeybindService = Class(function(self, modname)
    self.modname = modname or "Development"
    self._keys = {}       -- 记录已注册的 key→fn，用于清理
    self._handlers = {}   -- 记录 conf→fn，供 HUD 按钮 Trigger 复用（与 F 键同一处理器）
end)

function ModKeybindService:GetKeyFromConfig(conf)
    return rawget(_G, GetModConfigData(conf, self.modname))
end

function ModKeybindService:AddGlobalKey(conf, fn)
    local key = self:GetKeyFromConfig(conf)
    if key then
        KH.AddKey(key, fn)
        self._keys[key] = self._keys[key] or {}
        table.insert(self._keys[key], fn)
    end
end

local function GetActiveScreenName()
    local activeScreen = TheFrontEnd:GetActiveScreen()
    return activeScreen and activeScreen.name or ""
end

function ModKeybindService:ValidateKeybind()
    return GetActiveScreenName() == "HUD"
end

function ModKeybindService:AddKey(conf, fn)
    self:AddHandler(conf, fn)
    self:AddGlobalKey(conf, function()
        if self:ValidateKeybind() then
            fn()
        end
    end)
end

function ModKeybindService:AddHandler(conf, fn)
    self._handlers[conf] = fn
end

-- 供 HUD 按钮复用与 F 键完全相同的处理器（如 confighud 点击触发同一功能）
function ModKeybindService:Trigger(conf)
    local fn = self._handlers[conf]
    if fn == nil then return end
    if self:ValidateKeybind() then
        fn()
    end
end

return ModKeybindService
