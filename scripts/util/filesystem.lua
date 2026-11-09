local FileSystem = {}
require "dumper"

local DEBUG_MODE = false

function FileSystem:SetDebugMode(enabled)
    DEBUG_MODE = enabled
end

local function debugPrint(...)
    if DEBUG_MODE then
        print(...)
    end
end

local function serialiseTable(t)
    local ok, payload = pcall(DataDumper, t, nil, true)
    if not ok then
        debugPrint("[EC:FileSystem] DataDumper failed: " .. tostring(payload))
        return ""
    end
    return payload
end

-- 来源：官方：RunInSandboxSafe（util.lua:810，空环境；RunInSandbox 的 env 同样是空表）
local function _sandbox(chunk)
    local ok, result = RunInSandboxSafe(chunk)
    if not ok then
        debugPrint("[EC:FileSystem] RunInSandboxSafe failed: " .. tostring(result))
        return {}
    end
    return result
end

local function deserialiseTable(str)
    if type(str) ~= "string" then
        return {}
    end
    if str:match("^%s*{") then
        str = "return " .. str
    end
    local result = _sandbox(str)
    return type(result) == "table" and result or {}
end

function FileSystem:LoadStringFromFile(path, callback)
    if callback ~= nil then
        local success, data = TheSim:GetPersistentString(path)
        if success and data ~= nil and data ~= "" and data ~= "loading" then
            callback(success, data)
            return data
        end

        -- Startup may return an empty/loading value before the async read is ready.
        TheSim:GetPersistentString(path, callback)
        return
    end

    return TheSim:GetPersistentString(path)
end

function FileSystem:SaveStringToFile(path, data, encode, callback)
    if type(data) ~= "string" then
        if callback ~= nil then callback(false) end
        return false
    end
    TheSim:SetPersistentString(path, data, encode or false, callback)
    return true
end

-- 官方 TheSim:ErasePersistentString（mainfunctions.lua:42 / scrapbookpartitions.lua:536 同用法）
function FileSystem:EraseFile(path)
    if path == nil then return false end
    TheSim:ErasePersistentString(path)
    return true
end

function FileSystem:LoadTableFromFile(path, callback)
    debugPrint("[EC:FileSystem] LoadTableFromFile START key=" .. tostring(path))
    if callback ~= nil then
        local loaded
        local sync_data = self:LoadStringFromFile(path, function(success, data)
            debugPrint("[EC:FileSystem] LoadTableFromFile callback: success=" .. tostring(success) .. " datalen=" .. tostring(data and #data or 0))
            local result = success and data ~= nil and data ~= "" and deserialiseTable(data) or {}
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            debugPrint("[EC:FileSystem] LoadTableFromFile deserialised: " .. tostring(count) .. " keys")
            loaded = result
            callback(result)
        end)
        return sync_data ~= nil and loaded or nil
    end

    local success, data = self:LoadStringFromFile(path)
    debugPrint("[EC:FileSystem] LoadTableFromFile sync: success=" .. tostring(success) .. " datalen=" .. tostring(data and #data or 0))
    if success and data ~= nil and data ~= "" then
        local result = deserialiseTable(data)
        local count = 0
        for _ in pairs(result) do count = count + 1 end
        debugPrint("[EC:FileSystem] LoadTableFromFile sync deserialised: " .. tostring(count) .. " keys")
        return result
    end

    debugPrint("[EC:FileSystem] LoadTableFromFile: nothing found")
    return {}
end

function FileSystem:LoadNamespacedTableFromFile(path, namespace, callback)
    if path == nil or namespace == nil or callback == nil then return false end

    self:LoadTableFromFile(path, function(all_data)
        local data
        if type(all_data._order) == "table" then
            data = all_data[namespace]
        else
            data = {}
        end
        callback(type(data) == "table" and data or {})
    end)
    return true
end

local namespaced_save_queues = {}

-- Serialize read-modify-write operations per key so concurrent world saves cannot overwrite each other.
local function SaveNextNamespacedTable(path)
    local queue = namespaced_save_queues[path]
    if queue == nil or queue.busy then return end

    local operation = table.remove(queue.pending, 1)
    if operation == nil then
        namespaced_save_queues[path] = nil
        return
    end
    queue.busy = true

    FileSystem:LoadTableFromFile(path, function(existing)
        local all_data
        if type(existing._order) == "table" then
            all_data = existing
        else
            all_data = { _order = {}, [operation.namespace] = existing }
        end
        local order, seen = {}, { [operation.namespace] = true }
        for _, namespace in ipairs(all_data._order) do
            if namespace ~= operation.namespace and not seen[namespace] then
                order[#order + 1] = namespace
                seen[namespace] = true
            end
        end
        table.insert(order, 1, operation.namespace)
        all_data[operation.namespace] = operation.data

        if operation.max_namespaces ~= nil then
            while #order > operation.max_namespaces do
                local removed = table.remove(order)
                all_data[removed] = nil
            end
        end
        all_data._order = order

        FileSystem:SaveTableToFile(path, all_data, function(success)
            queue.busy = false
            if #queue.pending > 0 then
                SaveNextNamespacedTable(path)
            else
                namespaced_save_queues[path] = nil
            end
            if operation.callback ~= nil then
                operation.callback(success)
            end
        end)
    end)
end

function FileSystem:SaveTableToFile(path, tbl, callback)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    debugPrint("[EC:FileSystem] SaveTableToFile key=" .. tostring(path) .. " keys=" .. tostring(count))
    local payload = serialiseTable(tbl)
    if payload == "" then
        debugPrint("[EC:FileSystem] SaveTableToFile SKIP: payload empty")
        if callback ~= nil then callback(false) end
        return false
    end
    debugPrint("[EC:FileSystem] SaveTableToFile payload length=" .. tostring(#payload))
    self:SaveStringToFile(path, payload, false, function(success)
        debugPrint("[EC:FileSystem] SaveTableToFile SetPersistentString callback: success=" .. tostring(success))
        if callback then callback(success) end
    end)
    debugPrint("[EC:FileSystem] SaveTableToFile SetPersistentString called (returning)")
    return true
end

function FileSystem:SaveNamespacedTableToFile(path, namespace, tbl, max_namespaces, callback)
    if path == nil or namespace == nil or type(tbl) ~= "table" then
        if callback ~= nil then callback(false) end
        return false
    end
    if max_namespaces ~= nil then
        max_namespaces = math.max(1, math.floor(tonumber(max_namespaces) or 1))
    end

    local queue = namespaced_save_queues[path]
    if queue == nil then
        queue = { pending = {}, busy = false }
        namespaced_save_queues[path] = queue
    end
    queue.pending[#queue.pending + 1] = {
        namespace = namespace,
        data = deepcopy(tbl), -- 来源：官方 deepcopy（util.lua:906）
        max_namespaces = max_namespaces,
        callback = callback,
    }

    if not queue.busy then
        SaveNextNamespacedTable(path)
    end
    return true
end

return FileSystem