local Widget = require "widgets/widget"
local Text = require "widgets/text"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local InvSlot = require "widgets/itemslot"

local CONFIG = MOD_EQUIPMENT_CONTROL.CONFIG
local InventoryUtil = require "util/inventoryutil"
local WorldUtil = require "util/worldutil"
local CameraUtil = require "util/camerautil"

-- 官方 ui.xml：crafting_inventory_arrow_*_idle 的 UV 为 0.0308，
-- 原 arrow2_*_down 为 0.0483；0.95 ≈ 原 0.6 的同屏尺寸（含点击热区）。
local ARROW_SCALE = 0.95

-- [3701729451/chestdisplay.lua:404-409] 按住修饰键时冻结箱子预览的显隐，
-- 鼠标才能离开箱子实体移到历史箭头上点击（single 模式尤其需要）。
-- 官方 KEY_ALT（scripts/constants.lua:327；debugkeys.lua:436 同用法）同时覆盖左右 Alt。
local HISTORY_HOLD_KEY = KEY_ALT

local function CreateBasicItemInfoForItem(item)
    local newitem = {}
    if not (item and item.replica and item.replica.inventoryitem) then
        return newitem
    end
    newitem.prefab = item.prefab
    newitem.atlas = InventoryUtil:GetAtlas(item)
    newitem.image = InventoryUtil:GetImage(item)
    newitem._stackable = item.replica.stackable ~= nil or nil
    if item.replica.stackable then
        newitem.stacksize = InventoryUtil:GetStackSize(item)
        newitem.stackmaxsize = InventoryUtil:GetMaxSize(item)
    end
    return newitem
end

local function CompareSameTables(t1, t2)
    if not t1 or not t2 then return false end
    local t1_empty, t2_empty = true, true
    for _, _ in pairs(t1) do t1_empty = false break end
    for _, _ in pairs(t2) do t2_empty = false break end
    if t1_empty and t2_empty then return true end
    if t1_empty or t2_empty then return false end
    for k, v in pairs(t1) do
        if not (t2[k] and t2[k].prefab == v.prefab
            and t2[k].stacksize == v.stacksize
            and t2[k].finiteusespercent == v.finiteusespercent) then
            return false
        end
    end
    return true
end

local function GetContainerSlotLayout(owner, container)
    -- 优先用全局 Containers（与游戏/autocontainer 用法一致）；拿不到再退回 require。
    -- 注意：必须用 rawget(_G,...) 访问，直接写 _G.Containers 会触发 strict 对未声明全局的报错
    local containers_mod = rawget(_G, "Containers") or require("containers")
    local params = containers_mod.params and containers_mod.params[owner.prefab] or nil

    -- 实时（已打开）容器的 widget 通常带 slotpos；关闭时 GetWidget() 返回 nil，
    -- 此时退而用 containers.params[...].widget 的静态 slotpos
    local live_widget = container:GetWidget()
    local widget = (live_widget and (live_widget.slotpos or live_widget.slotposfn)) and live_widget
        or (params and params.widget)
        or live_widget

    -- slotposfn 在关闭态可能返回 nil；静态 slotpos 也可能是空表 {}（仅由 slotposfn 动态填充的容器）。
    -- 这两种情况都必须回落到按槽位数自建网格，否则 ipairs({}) 会建出 0 个格子（即“没有格子”）
    local slotpos = widget and (widget.slotposfn and widget.slotposfn(owner, ThePlayer) or widget.slotpos)
    if slotpos == nil or #slotpos == 0 then
        -- 容器未打开/自定义容器：containers.params 无 slotpos 时，退而从槽位数构建网格
        local num_slots = InventoryUtil:GetSlotCount(owner)   -- 内部即 replica:GetNumSlots()
        if num_slots <= 0 and params ~= nil then
            num_slots = params.numslots or 0
        end
        if num_slots <= 0 then return nil, widget end

        local cols = math.ceil(math.sqrt(num_slots))
        slotpos = {}
        for i = 1, num_slots do
            local row = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            slotpos[i] = Vector3(col * 80 - (cols - 1) * 40, (cols - 1) * 40 - row * 80, 0)
        end
    end
    return slotpos, widget
end

local ChestMemoryDisplay = Class(Widget, function(self, owner, module_state)
    Widget._ctor(self, "ChestMemoryDisplay")

    self.owner = owner
    self.ms = module_state

    local x, _, z = self.owner.Transform:GetWorldPosition()
    self.ishidden = false
    self.displaytype = self.ms.displaytype or CONFIG.CHEST_MEMORY_DISPLAY_TYPE or "all"
    self._alreadyopenedonce = false
    self.inv = {}

    self.boat = TheWorld.Map:GetPlatformAtPoint(x, z)
    self.chest_type = self.boat and "boat" or "static"

    self.prefab = owner.prefab
    if self.boat then
        local boat_pos = self.boat:GetPosition()
        self._x = tonumber(string.format("%.2f", boat_pos.x - x))
        self._z = tonumber(string.format("%.2f", boat_pos.z - z))
    else
        self._x = tonumber(string.format("%.1f", x))
        self._z = tonumber(string.format("%.1f", z))
    end

    self.CS_contents = {}
    self.CS_history = {}
    self._pending_history = false
    self.history_index = 0

    self._slots_ready = self:RefreshSlotLayout()

    -- 官方制作栏翻页箭头（images/ui.xml）：normal=idle、focus=hl，与 confighud 滑条一致
    self.scroll_left = self:AddChild(ImageButton(
        "images/ui.xml", "crafting_inventory_arrow_l_idle.tex",
        "crafting_inventory_arrow_l_hl.tex", "crafting_inventory_arrow_l_idle.tex"))
    self.scroll_left:SetScale(ARROW_SCALE)
    self.scroll_left:SetOnClick(function() self:MoveTowardsThePast() end)
    self.scroll_left:Hide()

    self.scroll_right = self:AddChild(ImageButton(
        "images/ui.xml", "crafting_inventory_arrow_r_idle.tex",
        "crafting_inventory_arrow_r_hl.tex", "crafting_inventory_arrow_r_idle.tex"))
    self.scroll_right:SetScale(ARROW_SCALE)
    self.scroll_right:SetOnClick(function() self:MoveTowardsThePresent() end)
    self.scroll_right:Hide()

    self.historytime = self:AddChild(Text(BODYTEXTFONT, 28))
    self.historytime:SetRegionSize(240, 40)  -- 限制宽度，避免长文本与两侧箭头重叠
    self.historytime:SetString("")

    -- 箭头/日期在 RefreshSlotLayout 之前创建，这里主动定位一次，避免停在默认 (0,0) 与日期重叠
    self:RepositionHistoryControls()

    self:LoadChestData()

    self.onrefreshfn = function()
        if self.ms.openedchest == owner then
            self:OnContainerOpened()
        end
    end
    self.onitemchangefn = function()
        self:ScheduleOpenContainerRefresh()
    end
    self.onmouseoverfn = function()
        self.ms.highlightedchest = owner
        self:HandleWidgetDisplay()
    end
    self.onmouseoutfn  = function()
        if self.ms.highlightedchest == owner then
            self.ms.highlightedchest = nil
        end
        self:HandleWidgetDisplay()
    end

    owner:ListenForEvent("refresh", self.onrefreshfn)
    owner:ListenForEvent("itemget", self.onitemchangefn)
    owner:ListenForEvent("itemlose", self.onitemchangefn)
    owner:ListenForEvent("mouseover", self.onmouseoverfn)
    owner:ListenForEvent("mouseout", self.onmouseoutfn)

    self:Hide()
    if self.ms.openedchest == self.owner then
        self:OnContainerOpened()
    end
    self:StartUpdating()
end)

function ChestMemoryDisplay:RefreshSlotLayout()
    local container = self.owner.replica and self.owner.replica.container
    if container == nil then
        self:RepositionHistoryControls()
        return false
    end

    local slotpos, widget = GetContainerSlotLayout(self.owner, container)
    if slotpos == nil then
        self:RepositionHistoryControls()
        return false
    end

    for _, slot in ipairs(self.inv) do
        slot:Kill()
    end
    self.inv = {}

    for i, pos in ipairs(slotpos) do
        local slotbg = widget and widget.slotbg and widget.slotbg[i]
        -- [官方] scripts/widgets/itemslot.lua:5-9 构造签名是 (atlas, bgim, owner)，
        -- 第 8 行 self.bgimage 就是槽背景；原模组 2188383679/invslot_chestmemory.lua
        -- 是 5 参数包装类，EC 直接用官方 ItemSlot（变量名 InvSlot），必须按官方签名传。
        local slot = InvSlot(
            slotbg and slotbg.atlas or "images/hud.xml",
            slotbg and slotbg.image or "inv_slot.tex",
            self.owner)
        self.inv[i] = self:AddChild(slot)
        slot:SetClickable(false)
        slot:MoveToBack()
        slot:SetPosition(pos)
    end
    self:RepositionHistoryControls()
    return true
end

function ChestMemoryDisplay:OnContainerOpened()
    self.history_index = 0
    self:RefreshSlotLayout()
    self:UpdateItemMemory()
    self._alreadyopenedonce = true
end

function ChestMemoryDisplay:ScheduleOpenContainerRefresh()
    if self.ms.openedchest ~= self.owner or self._item_refresh_task ~= nil then return end
    self._item_refresh_task = self.inst:DoTaskInTime(0, function()
        self._item_refresh_task = nil
        if self.owner:IsValid() and self.ms.openedchest == self.owner then
            self:UpdateItemMemory()
            self._alreadyopenedonce = true
        end
    end)
end

local function CreateSimpleTile(data)
    local tile = Widget("memory_tile")
    local img = tile:AddChild(Image(data.atlas, data.image, "default.tex"))
    img:SetClickable(false)
    if data._stackable and data.stacksize then
        local txt = tile:AddChild(Text(NUMBERFONT, 42))
        txt:SetPosition(2, 16, 0)
        txt:SetString(tostring(data.stacksize))
    end
    tile._data = data
    return tile
end

-- 快照每次都会新建 table，按内容比较才能复用 tile，避免关箱时整格重建。
local function SameItemData(a, b)
    if a == b then return true end
    if a == nil or b == nil then return false end
    return a.prefab == b.prefab
        and a.atlas == b.atlas
        and a.image == b.image
        and a.stacksize == b.stacksize
        and a.stackmaxsize == b.stackmaxsize
        and a._stackable == b._stackable
end

function ChestMemoryDisplay:RefreshItems()
    local idx = self.history_index or 0
    local items
    local history_count = #self.CS_history
    if idx > 0 and history_count > 0 then
        local history_pos = math.max(1, history_count - idx + 1)
        local entry = self.CS_history[history_pos]
        items = entry and entry.items
    else
        items = self.CS_contents
    end

    for k, v in pairs(self.inv) do
        local item = items and items[k]
        if item == nil or (item.prefab == nil and item.atlas == nil) then
            if v.tile ~= nil then
                v:SetTile(nil)
            end
        elseif v.tile == nil or not SameItemData(v.tile._data, item) then
            v:SetTile(CreateSimpleTile(item))
        end
    end
end

function ChestMemoryDisplay:UpdateHistoryControls()
    local has_history = #self.CS_history > 0
    local visible = not self.ishidden and has_history
    if self.scroll_left then
        self.scroll_left:SetClickable(visible)
        if visible then self.scroll_left:Show() else self.scroll_left:Hide() end
    end
    if self.scroll_right then
        self.scroll_right:SetClickable(visible)
        if visible then self.scroll_right:Show() else self.scroll_right:Hide() end
    end
    if self.historytime then
        if not has_history then
            self.historytime:SetString("")
        elseif self.history_index == 0 then
            self.historytime:SetString(string.format("Day %d", math.floor(WorldUtil:GetDayFraction())))
        else
            local entry = self.CS_history[#self.CS_history - self.history_index + 1]
            local day = entry and entry.time
            self.historytime:SetString(day and string.format("Day %d", math.floor(day)) or "Unknown day")
        end
    end
end

function ChestMemoryDisplay:RepositionHistoryControls()
    -- 箭头+日期作为一个整体 [◀ 日期 ▶] 横排，置于格子下方（基于格子最小 y 偏移），
    -- 不写死绝对坐标——写死会被更高/更宽网格的容器格子盖住。
    -- 该函数在构造函数与布局成败各分支都会被调用，因此箭头/日期绝不会停在默认 (0,0) 与彼此重叠。
    local min_y = 0
    if #self.inv > 0 then
        min_y = self.inv[1]:GetPosition().y
        for i = 2, #self.inv do
            local sy = self.inv[i]:GetPosition().y
            if sy < min_y then min_y = sy end
        end
    end

    local padding = 110        -- 与最下一排格子的间距
    local row_y = min_y - padding
    local arrow_spacing = 150   -- 相对居中日期（限宽 240 → 半宽 120）的间距，保证不重叠

    if self.scroll_left then
        self.scroll_left:SetPosition(-arrow_spacing, row_y)
    end
    if self.historytime then
        self.historytime:SetPosition(0, row_y)
    end
    if self.scroll_right then
        self.scroll_right:SetPosition(arrow_spacing, row_y)
    end
end

-- history_index：0 = 当前内容，数值越大表示越旧的快照。
-- 两端到头就停住，不回绕（一直点左箭头不会回到最新日期）。
function ChestMemoryDisplay:MoveTowardsThePresent()
    if #self.CS_history == 0 or self.history_index <= 0 then return end
    self.history_index = self.history_index - 1
    self:UpdateHistoryControls()
    self:RefreshItems()
end

function ChestMemoryDisplay:MoveTowardsThePast()
    local history_count = #self.CS_history
    if history_count == 0 or self.history_index >= history_count then return end
    self.history_index = self.history_index + 1
    self:UpdateHistoryControls()
    self:RefreshItems()
end

function ChestMemoryDisplay:UpdateItemMemory(slotwidgets)
    local chest = self.owner

    self.CS_contents = {}
    local slotCount = InventoryUtil:GetSlotCount(chest)
    for i = 1, slotCount do
        local slotwidget = slotwidgets and slotwidgets[i]
        local item = slotwidget and slotwidget.tile and slotwidget.tile.item
            or InventoryUtil:GetItemInSlotSafe(chest, i)
        self.CS_contents[i] = CreateBasicItemInfoForItem(item)
    end
    self:RefreshItems()
end

local function SetChestDataFromMemory(self)
    local data = self.ms:GetData(self.prefab, self._x, self._z, self.chest_type)
    self.CS_contents    = data.contents or {}
    self.CS_history     = data.history or {}
    -- 旧存档/合并写入可能带回超额历史，读取时再兜底裁剪一次。
    while #self.CS_history > (self.ms.MAX_HISTORY or 3) do
        table.remove(self.CS_history, 1)
    end
    self.chest_type     = data.chest_type or self.chest_type
end

function ChestMemoryDisplay:LoadChestData()
    SetChestDataFromMemory(self)
    self:RefreshItems()
end

-- 只放大被悬停的那个；[2188383679/chestdisplay.lua:418] 原模组把全局高亮实体
-- 当作 hover_exists 传给所有 widget，导致别处悬停时其余容器一起缩小。
function ChestMemoryDisplay:OnIsHoveredOver(ishovered)
    local dist = CameraUtil.GetDistance()
    local hud_scale = TheFrontEnd:GetHUDScale()
    local hover_mult = 1.5

    local base_scale = (10 / dist) * hud_scale
    local scale = ishovered and base_scale * hover_mult or base_scale

    if ishovered then
        self:MoveToFront()
    else
        self:MoveToBack()
    end
    self:SetScale(scale, scale, scale)
end

function ChestMemoryDisplay:DoDisplay(display)
    local is_highlighted = self.ms.highlightedchest == self.owner
    if display == "all" then
        self:Show()
        self.ishidden = false
    elseif display == "single" then
        if is_highlighted then
            self:Show()
            self.ishidden = false
        else
            self:Hide()
            self.ishidden = true
        end
    else
        self:Hide()
        self.ishidden = true
    end
    -- [2188383679/chestdisplay.lua:418] 不再传全局 highlightedchest，只按自身悬停状态缩放
    self:OnIsHoveredOver(is_highlighted)
end

function ChestMemoryDisplay:HandleWidgetDisplay()
    local x, y, z = self.owner.Transform:GetWorldPosition()
    self.boat = TheWorld.Map:GetPlatformAtPoint(x, z)
    self.chest_type = self.boat and "boat" or "static"

    local screen_x, screen_y, screen_z = TheSim:GetScreenPos(x, y, z)
    self:SetPosition(screen_x, screen_y + screen_y * (1 / CameraUtil.GetDistance()), 0)

    -- 屏幕尺寸用时读取（官方 scripts/widgets/hoverer.lua:158 同做法）；
    -- 缓存会在改窗口/全屏后过期，导致箱子被误判为屏幕外而隐藏。
    local screen_w, screen_h = TheSim:GetScreenSize()
    local is_offscreen = screen_x < 0 or screen_y < 0 or screen_x > screen_w or screen_y > screen_h
    -- 按住 KEY_ALT 时冻结当前显隐：mouseout 后 widget 与历史箭头保持可点
    -- [3701729451/chestdisplay.lua:369-370,404-409] 原模组用 DoDisplay(display, pause) 达到同样效果
    local hold_display = TheInput:IsKeyDown(HISTORY_HOLD_KEY)
    if is_offscreen then
        self:Hide()
        self.ishidden = true
    elseif not hold_display then
        self:DoDisplay(self.displaytype)
    end
    self:UpdateHistoryControls()
end

function ChestMemoryDisplay:HasItem(item_prefab)
    if not item_prefab then return false end
    for _, item in pairs(self.CS_contents) do
        if item.prefab == item_prefab then
            return true
        end
    end
    return false
end

function ChestMemoryDisplay:HighlightWithItem(bool, item_prefab)
    if not (self.owner and self.owner:IsValid() and self.owner.AnimState) then
        return
    end
    if self:HasItem(item_prefab) then
        if bool then
            self.owner.AnimState:SetAddColour(0, 0.5, 0, 1)
        else
            self.owner.AnimState:SetAddColour(0, 0, 0, 1)
        end
    else
        self.owner.AnimState:SetAddColour(0, 0, 0, 1)
    end
end

function ChestMemoryDisplay:GetItems()
    return self.CS_contents
end

function ChestMemoryDisplay:GetOwner()
    return self.owner
end

-- [Ref-3] 2188383679/scripts/widgets/chestdisplay.lua:165-168
-- 原模组在此直接 DoDisplay(displaytype)，切换模式立即显隐；EC 只赋值，靠调用方补重绘。
function ChestMemoryDisplay:UpdateDisplayType()
    self.displaytype = self.ms.displaytype or CONFIG.CHEST_MEMORY_DISPLAY_TYPE or "all"
end

function ChestMemoryDisplay:PushHistory(items, day)
    local copy = {}
    for k, v in pairs(items) do copy[k] = v end
    self.CS_history[#self.CS_history + 1] = {
        items = copy,
        time  = day or math.floor(WorldUtil:GetDayFraction()),
    }
    while #self.CS_history > (self.ms.MAX_HISTORY or 3) do
        table.remove(self.CS_history, 1)
    end
end

-- day 由新一天回调传入（整数天数）；同一天的多次变化只合并成这一条。
function ChestMemoryDisplay:TryPushPendingHistory(day)
    if not self._pending_history then return end
    self._pending_history = false
    self:PushHistory(self.CS_contents, day)
    self:UpdateSavedData()
end

-- 关箱只写内存缓存：首次快照立即入历史，之后当天变化标 pending 等新一天合并；不落盘。
function ChestMemoryDisplay:DoHistoryAndContentMiniSave()
    local last_entry = self.CS_history[#self.CS_history]
    local last_items = last_entry and last_entry.items

    if #self.CS_history == 0 then
        self:PushHistory(self.CS_contents)
    elseif not CompareSameTables(self.CS_contents, last_items) then
        self._pending_history = true
    end

    self:UpdateSavedData()
end

function ChestMemoryDisplay:UpdateSavedData()
    self.ms:ModifyOrAddData({
        x = self._x, z = self._z,
        contents    = self.CS_contents,
        history     = self.CS_history,
        prefab      = self.prefab,
        chest_type  = self.chest_type,
        mobile      = self.mobile,
    })
end

function ChestMemoryDisplay:DoRemove(callcomponent)
    if self._item_refresh_task ~= nil then
        self._item_refresh_task:Cancel()
        self._item_refresh_task = nil
    end
    local owner = self.owner
    if owner ~= nil then
        if owner:IsValid() then
            -- [3701729451/chestdisplay.lua:440] 单个 widget 移除也要还原高亮加色，
            -- 否则箱子被染绿后单独移除，绿色会一直残留。
            if owner.AnimState ~= nil then
                owner.AnimState:SetAddColour(0, 0, 0, 0)
            end
            self:UpdateSavedData()
            owner:RemoveEventCallback("refresh", self.onrefreshfn)
            owner:RemoveEventCallback("itemget", self.onitemchangefn)
            owner:RemoveEventCallback("itemlose", self.onitemchangefn)
            owner:RemoveEventCallback("mouseover", self.onmouseoverfn)
            owner:RemoveEventCallback("mouseout", self.onmouseoutfn)
        else
            self:UpdateSavedData()
        end
    end
    if callcomponent then
        self.ms:RemoveWidget(self, true)
    end
    self:Kill()
    self:StopUpdating()
end

-- [Ref-1] 2188383679/scripts/widgets/chestdisplay.lua:527-533
-- [Ref-2] 2188383679/scripts/widgets/chestdisplay.lua:422-455
-- 原模组 OnUpdate 每帧调 HandleWidgetDisplay 重算 GetScreenPos + SetPosition；
-- EC 改由 util/camerautil 透传的官方相机更新回调逐帧调用 HandleWidgetDisplay（跟随镜头），
-- 这里只保留槽位/历史逻辑，不在每个 widget 上轮询。
function ChestMemoryDisplay:OnUpdate(dt)
    if self.owner == nil or not self.owner:IsValid() then
        self:DoRemove(true)
        return
    end

    if not (self.owner.replica and self.owner.replica.container) then
        self._slots_ready = false
        return
    end

    if not self._slots_ready then
        self._slots_ready = self:RefreshSlotLayout()
        self:RefreshItems()
        return
    end

    if self._alreadyopenedonce and self.ms.openedchest ~= self.owner then
        self:DoHistoryAndContentMiniSave()
        self._alreadyopenedonce = false
    end
end

return ChestMemoryDisplay