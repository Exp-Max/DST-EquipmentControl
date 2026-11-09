-- 按键注册服务（基于官方 TheInput API，无猴子补丁）
-- 用法: local KH = require("util/keyhandlers")
--       KH.AddKey(KEY_F1, function() ... end)
--       KH.RemoveKey(KEY_F1, fn)

local KeyHandlers = {}

-- 每个按键的状态: { fn_down, fn_up, down_handler, up_handler, subscribers = {fn, ...} }
local _states = {}

-- 为指定按键创建按键处理函数（闭包捕获 debounce 状态）
local function _makeDown(key)
    return function()
        local state = _states[key]
        if not state then return end
        for i = 1, #state.subscribers do
            state.subscribers[i]()
        end
    end
end

local function _makeUp(key)
    return function() end
end

--- 注册按键回调
--- @param key  number  KEY_* 常量
--- @param fn   function 按键按下时回调
function KeyHandlers.AddKey(key, fn)
    if not key or type(fn) ~= "function" then return end

    local state = _states[key]
    if not state then
        state = {
            fn_down      = _makeDown(key),
            fn_up        = _makeUp(key),
            down_handler = nil,
            up_handler   = nil,
            subscribers  = {},
        }
        _states[key] = state
        state.down_handler = TheInput:AddKeyDownHandler(key, state.fn_down)
        state.up_handler = TheInput:AddKeyUpHandler(key, state.fn_up)
    end
    table.insert(state.subscribers, fn)
end

--- 取消注册按键回调
--- @param key  number  KEY_* 常量
--- @param fn   function 之前注册的回调
function KeyHandlers.RemoveKey(key, fn)
    if not key or not fn then return end

    local state = _states[key]
    if not state then return end

    for i = #state.subscribers, 1, -1 do
        if state.subscribers[i] == fn then
            table.remove(state.subscribers, i)
            break
        end
    end

    if #state.subscribers == 0 then
        if state.down_handler then state.down_handler:Remove() end
        if state.up_handler then state.up_handler:Remove() end
        _states[key] = nil
    end
end

return KeyHandlers