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

-- 分片表存档的索引维护：每个分片（如一个世界）一个独立文件，索引文件用 _order 记录最近使用的分片。
-- 只做「读索引 → 当前分片置顶 → 删除超出配额的旧分片文件 → 清理旧版合并存档 → 写回索引」；
-- index_key / current_shard / max_shards / shard_key_fn / legacy_key 全部由调用方提供，
-- 工具层不持有任何业务 key 命名或配额规则。
function FileSystem:PruneShardedTables(index_key, current_shard, max_shards, shard_key_fn, legacy_key)
    if index_key == nil or current_shard == nil then return false end
    max_shards = math.max(1, math.floor(tonumber(max_shards) or 1))

    self:LoadTableFromFile(index_key, function(index_data)
        local old_order = type(index_data._order) == "table" and index_data._order or {}
        local order = { current_shard }
        for _, old_shard in ipairs(old_order) do
            if old_shard ~= current_shard then
                if #order < max_shards then
                    order[#order + 1] = old_shard
                elseif shard_key_fn ~= nil then
                    self:EraseFile(shard_key_fn(old_shard))
                end
            end
        end
        if legacy_key ~= nil and not index_data.legacy_cleared then
            self:EraseFile(legacy_key)
        end
        self:SaveTableToFile(index_key, { _order = order, legacy_cleared = true })
    end)
    return true
end

-- 分片表数据仓库：加载 / 保存 / 增删改查的实现集中在工具层。
-- 业务条例（分片 key、世界配额、历史上限、widget 数据收集）由 opts 注入；
-- 状态表由对接层提供（方法以 self 读写，实际状态落在对接层的表上）。
function FileSystem:CreateShardedStore(opts)
    local max_history = opts.max_history or 3
    local store = {
        data = {}, index = {}, next_id = 1,
        seed = nil, dirty = false, data_loaded = false, pending_save_seed = nil,
        MAX_HISTORY = max_history,
    }

    local function DataIndexKey(item_data)
        if item_data.mobile then
            return "m|" .. tostring(item_data.prefab)
        end
        return "p|" .. tostring(item_data.prefab) .. "|" .. tostring(item_data.x) .. "|" .. tostring(item_data.z)
    end

    local function TrimHistory(history)
        if type(history) ~= "table" then return end
        while #history > max_history do
            table.remove(history, 1)
        end
    end

    function store:GetPersistenceKey()
        return opts.shard_key(self.seed or opts.get_seed())
    end

    function store:PruneShardedTables(seed)
        FileSystem:PruneShardedTables(opts.index_key, seed, opts.max_worlds,
            opts.shard_key, opts.legacy_key)
    end

    function store:ResetData()
        self.data = {}
        self.index = {}
        self.next_id = 1
        self.dirty = false
    end

    function store:AllocDataKey()
        local key
        repeat
            key = tostring(self.next_id)
            self.next_id = self.next_id + 1
        until self.data[key] == nil
        return key
    end

    function store:ModifyOrAddData(item_data)
        self.dirty = true
        TrimHistory(item_data.history)
        local bucket_key = DataIndexKey(item_data)
        local bucket = self.index[bucket_key]
        if bucket == nil then
            bucket = {}
            self.index[bucket_key] = bucket
        end
        for i = #bucket, 1, -1 do
            local k = bucket[i]
            local info = self.data[k]
            if info == nil then
                table.remove(bucket, i)
            elseif item_data.chest_type == nil or info.chest_type == nil
                or item_data.chest_type == info.chest_type then
                if info.history and item_data.history and #item_data.history <= #info.history then
                    item_data.history = info.history
                    item_data.historytime = info.historytime
                end
                if next(item_data.contents or {}) == nil and next(info.contents or {}) ~= nil then
                    item_data.contents = info.contents
                end
                self.data[k] = item_data
                return
            end
        end
        local key = self:AllocDataKey()
        self.data[key] = item_data
        bucket[#bucket + 1] = key
    end

    function store:RemoveData(key)
        local info = self.data[key]
        if info == nil then return end
        self.dirty = true
        local bucket = self.index[DataIndexKey(info)]
        if bucket ~= nil then
            for i, k in ipairs(bucket) do
                if k == key then
                    table.remove(bucket, i)
                    break
                end
            end
        end
        self.data[key] = nil
    end

    function store:GetData(prefab, x, z, chest_type)
        for _, info in pairs(self.data) do
            if info.prefab == prefab then
                local pos_match = info.mobile or (info.x == x and info.z == z)
                local type_match = info.chest_type == nil or info.chest_type == chest_type
                if pos_match and type_match then
                    return info
                end
            end
        end
        return {}
    end

    function store:LoadData()
        local seed = self.seed or opts.get_seed()
        if not seed then return end
        self.seed = seed
        self:ResetData()
        self.data_loaded = false

        self:PruneShardedTables(seed)

        FileSystem:LoadTableFromFile(self:GetPersistenceKey(), function(data)
            if self.seed ~= seed then return end
            for _, info in pairs(data) do
                if type(info) == "table" and info.prefab ~= nil then
                    TrimHistory(info.history)
                    self:ModifyOrAddData(info)
                end
            end
            self.data_loaded = true
            self.dirty = false
            if opts.on_loaded ~= nil then opts.on_loaded(self) end
            if self.pending_save_seed == seed then
                self.pending_save_seed = nil
                self:SaveData()
            end
        end)
    end

    function store:SaveData(widget)
        if not self.data_loaded then
            self.pending_save_seed = self.seed or opts.get_seed()
            return
        end
        if opts.collect ~= nil then opts.collect(self, widget) end
        if not self.seed then
            self.seed = opts.get_seed()
        end
        if not self.seed then return end

        local persist_data = {}
        for k, info in pairs(self.data) do
            if not info.mobile then
                persist_data[k] = info
            end
        end
        -- 每世界独立文件，内存里已是该世界的完整数据：直接整体覆盖写。
        FileSystem:SaveTableToFile(self:GetPersistenceKey(), persist_data)
        self.dirty = false
    end

    function store:FlushIfDirty()
        if self.dirty then
            self:SaveData()
        end
    end

    return store
end

return FileSystem