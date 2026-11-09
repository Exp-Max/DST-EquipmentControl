--============================================================================
-- 智能烹饪面板（框架层）
--
-- 布局参照官方烹饪指南（cookbookpage_crockpot.lua / cookbookwidget.lua）：
--   背景板     quagmire_recipe_menu_bg.tex  ScaleToSize(900, 550)
--   网格       TEMPLATES.ScrollingGrid      5 列 × 5 可见行
--   格子       128 底图缩到 73，行距 5，force_peek
--   网格根     (-180, -35)；网格 (-15, 0)
--   详情装饰   (grid_w/2 + 30, 0)，360×500，角装饰 100×100
--   滚动条     scrollbar_offset 20 / scrollbar_height_offset -60
--
-- 显示规则：默认显示全部食谱；不可做的食谱照样显示，只做变暗处理。
-- 通过「排序」和「种类」两个 Spinner 进行分类筛选。
-- 食谱目录、可做判定、当前锅候选、投料执行由 Auto/autocook.lua 通过
-- SetRecipeList / SetCraftableMap / SetPotCandidates / on_fill 注入。
--============================================================================

local Widget = require "widgets/widget"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local Text = require "widgets/text"
local Spinner = require "widgets/spinner"
local TEMPLATES = require "widgets/redux/templates"

local COOKBOOK_ATLAS = "images/quagmire_recipebook.xml"

-- 官方烹饪书比例: 背景板 900×550, 网格 cell=73, 间距=5, 5×5
-- 内容采用官方 1:1 数值，通过 panel_root:SetScale(0.3) 统一缩放到 270×165
local PANEL_W, PANEL_H = 900, 550

local BASE_SIZE    = 128
local CELL_SIZE    = 73
local CELL_SPACING = 5
local COLS         = 5
local VISIBLE_ROWS = 5
local FOOD_SIZE    = CELL_SIZE + 20

local GRID_ROOT_X, GRID_ROOT_Y = -180, -35

local DETAILS_W, DETAILS_H = 350, 500
-- 详情区 X 运行时按官方 grid_w/2 + 30 计算，不写死常量

local FILTER_ALL = "ALL"

local function GetRecipeIcon(recipe)
    local recipe_def = recipe.recipe_def or {}
    local tex = recipe_def.cookbook_tex or (recipe.prefab .. ".tex")
    local atlas = recipe_def.cookbook_atlas or GetInventoryItemAtlas(tex, true)
    if atlas == nil then
        return COOKBOOK_ATLAS, "cookbook_missing.tex"
    end
    return atlas, tex
end

local function GetFoodTypeName(foodtype)
    return (STRINGS.UI.FOOD_TYPES ~= nil and STRINGS.UI.FOOD_TYPES[foodtype]) or tostring(foodtype)
end

local function GetCookingTimeString(cooktime)
    return cooktime == nil and "未知"
        or cooktime < 1.0 and "很短"
        or cooktime < 2.0 and "一般"
        or cooktime < 2.5 and "较长"
        or "很长"
end

local function AddDetailsLine(root, x, y, scale, tex)
    local line = root:AddChild(Image(COOKBOOK_ATLAS, tex or "quagmire_recipe_line.tex"))
    line:SetScale(scale, scale)
    line:SetPosition(x, y)
    return line
end

local AutocookPanel = Class(Widget, function(self, owner)
    Widget._ctor(self, "AutocookPanel")

    self.owner = owner

    self.all_recipes     = {}
    self.filtered_recipes = {}
    self.craftable_map   = {}
    self.medal_food_set  = {}
    self.selected        = nil
    self._user_selected  = false    -- 手动点过食谱后不再自动改选
    self._last_craftable_key = nil  -- 档位变化去重，避免每帧重建详情
    self.preview_cookable = false   -- 当前预览能否真正一键投料

    self.foodtype_filter = FILTER_ALL
    self.sort_mode       = "default"
    self._suppress_change = false

    self.on_fill            = nil       -- function(panel, recipe) end
    self.on_switch_combo    = nil       -- function(panel, index) end
    self.on_update          = nil       -- function(dt) end，供数据层分帧推进
    self.on_retrieve        = nil       -- function(panel, prefab) end，预览食材图标右键取物
    self.pot_candidates     = nil       -- 通道 2：当前锅反向候选，用于标记食谱网格
    self.preview_combos     = nil       -- { {prefab,...}, ... } 所有可行组合
    self.preview_index      = 1         -- 当前展示组合索引

    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_MIDDLE)
    self:SetScaleMode(SCALEMODE_PROPORTIONAL)

    -- 镜头缩放防护标记：鼠标悬停在本面板上时，modmain 里的 ZoomIn/ZoomOut 拦截器
    -- 会把滚轮缩放变空操作，滚轮改由面板内网格/微调器接管（详见 modmain 的 IsOverCapturePanel）。
    self._ec_zoom_capture = true

    self.panel_root = self:AddChild(Widget("panel_root"))
    self.panel_root:SetScale(0.3, 0.3, 1)

    local backdrop = self.panel_root:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_menu_bg.tex"))
    backdrop:ScaleToSize(PANEL_W, PANEL_H)

    local click_blocker = self.panel_root:AddChild(Image("images/global.xml", "square.tex"))
    click_blocker:ScaleToSize(PANEL_W, PANEL_H)
    click_blocker:SetTint(0, 0, 0, 0)
    click_blocker.OnMouseButton = function()
        return true
    end

    -- children 是哈希集，遍历顺序不保证；SetFocusFromChild 还会清掉兄弟的 focus。
    -- 右键统一在 panel_root 这一层先拦截，命中带标记的食材图标就直接取物。
    self.panel_root.OnMouseButton = function(root, button, down, x, y)
        if button == MOUSEBUTTON_RIGHT and down and self.on_retrieve ~= nil then
            local prefab = self:_FindFocusedIngredient()
            if prefab ~= nil then
                self.on_retrieve(self, prefab)
                return true
            end
        end
        Widget.OnMouseButton(root, button, down, x, y)
        return true
    end

    self:CreateGrid()
    self:CreateDetails()
end)

-------------------------------------------------------------------------------
-- 食谱网格
-------------------------------------------------------------------------------
function AutocookPanel:CreateGrid()
    self.gridroot = self.panel_root:AddChild(Widget("autocook_grid_root"))
    self.gridroot:SetPosition(GRID_ROOT_X, GRID_ROOT_Y)

    self.recipe_grid = self.gridroot:AddChild(self:BuildRecipeGrid())
    self.recipe_grid:SetPosition(-15, 0)

    local _, grid_h = self.recipe_grid:GetScrollRegionSize()

    -- 上下两条装饰线，与官方一致
    local boarder_scale = 0.75
    local line = self.gridroot:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_line.tex"))
    line:SetScale(boarder_scale, boarder_scale)
    line:SetPosition(-3, grid_h / 2 + 1)
    line = self.gridroot:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_line.tex"))
    line:SetScale(boarder_scale, -boarder_scale)
    line:SetPosition(-3, -grid_h / 2)

    -- 排序 / 种类两个 Spinner，位置同官方 CreateRecipeBook:109
    self.spinner_root = self.gridroot:AddChild(self:BuildSpinners())
    self.spinner_root:SetPosition(0, grid_h / 2 + 5)
end

function AutocookPanel:BuildSpinners()
    local root = Widget("spinner_root")

    local width_label  = 150
    local width_spinner = 150
    local height = 25
    local spacing = 5

    local function MakeSpinner(labeltext, options, initial_data, onchanged)
        local total_width = width_label + width_spinner + spacing
        local wdg = Widget("labelspinner")

        local label = wdg:AddChild(Text(HEADERFONT, 18, labeltext))
        label:SetPosition((-total_width / 2) + (width_label / 2), 0)
        label:SetRegionSize(width_label, height)
        label:SetHAlign(ANCHOR_RIGHT)
        label:SetColour(UICOLOURS.BROWN_DARK)

        local spinner = wdg:AddChild(Spinner(
            options, width_spinner, height,
            { font = HEADERFONT, size = 18 },
            nil, COOKBOOK_ATLAS, nil, true))
        spinner:SetTextColour(UICOLOURS.BROWN_DARK)
        spinner:SetPosition((total_width / 2) - (width_spinner / 2), 0)
        spinner:SetOnChangedFn(onchanged)
        spinner:SetSelected(initial_data)

        return wdg, spinner
    end

    local sort_options = {
        { text = "默认",   data = "default" },
        { text = "名称",   data = "alphabetical" },
        { text = "生命",   data = "health" },
        { text = "饱食",   data = "hunger" },
        { text = "理智",   data = "sanity" },
    }

    local foodtype_options = {
        { text = "全部种类", data = FILTER_ALL },
    }

    local sort_widget, sort_spinner = MakeSpinner(
        "排序", sort_options, self.sort_mode,
        function(selected)
            if self._suppress_change then return end
            self.sort_mode = selected
            self:ApplyFilters()
        end)

    local foodtype_widget, foodtype_spinner = MakeSpinner(
        "种类", foodtype_options, self.foodtype_filter,
        function(selected)
            if self._suppress_change then return end
            self.foodtype_filter = selected
            self:ApplyFilters()
        end)

    self.sort_spinner = sort_spinner
    self.foodtype_spinner = foodtype_spinner

    -- 官方 BuildSpinners:703 = (#items - i + 1) * (height + 3)
    sort_widget:SetPosition(50, 2 * (height + 3))
    foodtype_widget:SetPosition(50, height + 3)

    root:AddChild(sort_widget)
    root:AddChild(foodtype_widget)

    return root
end

function AutocookPanel:BuildRecipeGrid()
    local cell_scale = CELL_SIZE / BASE_SIZE
    local focus_scale = cell_scale + 0.05

    local function CellCtor(context, index)
        local w = Widget("autocook-cell-" .. index)

        w.cell_root = w:AddChild(ImageButton(
            COOKBOOK_ATLAS,
            "cookbook_known.tex",
            "cookbook_known_selected.tex"))
        w.cell_root:SetNormalScale(cell_scale, cell_scale)
        w.cell_root:SetFocusScale(focus_scale, focus_scale)
        w.focus_forward = w.cell_root

        w.recipe_root = w.cell_root.image:AddChild(Widget("recipe_root"))

        w.food_img = w.recipe_root:AddChild(Image("images/global.xml", "square.tex"))
        w.food_img:ScaleToSize(FOOD_SIZE, FOOD_SIZE)

        w.medal_icon = w.recipe_root:AddChild(Image(COOKBOOK_ATLAS, "coin1.tex"))
        w.medal_icon:ScaleToSize(35, 35)
        w.medal_icon:SetPosition(BASE_SIZE / 2 - 23, BASE_SIZE / 2 - 25)
        w.medal_icon:Hide()

        w.cell_root:SetOnClick(function()
            if w.data ~= nil then
                self:OnCellClicked(w.data)
            end
        end)

        return w
    end

    local function CellApply(context, widget, data, index)
        widget.data = data

        if data == nil then
            widget.food_img:SetTexture("images/global.xml", "square.tex")
            widget.medal_icon:Hide()
            widget:Disable()
            widget:Hide()
            return
        end

        widget:Show()
        widget:Enable()

        local atlas, tex = GetRecipeIcon(data)
        widget.food_img:SetTexture(atlas, tex)
        widget.food_img:ScaleToSize(FOOD_SIZE, FOOD_SIZE)

        local pot = data.autocook_pot == true
        local craftable = data.craftable == true
        local nearby = not craftable and data.autocook_nearby == true
        local selected = self.selected == data
        local medal_done = self.medal_food_set[data.prefab] == true

        local r, g, b, a
        if pot then
            -- 当前锅已填食材，反向算出这一锅会做的料理：金色高亮
            if selected then
                r, g, b, a = 1, 0.88, 0.45, 1
            else
                r, g, b, a = 0.95, 0.74, 0.28, 1
            end
        elseif craftable then
            -- 角色物品栏 + 所有打开容器就够：正常色，可一键制作
            if selected then
                r, g, b, a = 1, 0.92, 0.65, 1
            else
                r, g, b, a = 1, 1, 1, 1
            end
        elseif nearby then
            -- 材料在附近容器：灰色，需先右键取物
            if selected then
                r, g, b, a = 0.84, 0.80, 0.66, 0.90
            else
                r, g, b, a = 0.68, 0.68, 0.68, 0.72
            end
        else
            -- 无材料：深灰色
            if selected then
                r, g, b, a = 0.75, 0.70, 0.55, 0.80
            else
                r, g, b, a = 0.45, 0.45, 0.45, 0.45
            end
        end

        widget.cell_root.image:SetTint(r, g, b, a)
        widget.food_img:SetTint(1, 1, 1,
            (pot or craftable) and 1 or (nearby and 0.65 or 0.40))

        if medal_done then
            widget.medal_icon:Show()
        else
            widget.medal_icon:Hide()
        end

    end

    local grid = TEMPLATES.ScrollingGrid(
        {},
        {
            context = {},
            widget_width  = CELL_SIZE + CELL_SPACING,
            widget_height = CELL_SIZE + CELL_SPACING,
            force_peek    = true,
            num_visible_rows = VISIBLE_ROWS,
            num_columns      = COLS,
            item_ctor_fn = CellCtor,
            apply_fn     = CellApply,
            scrollbar_offset = 20,
            scrollbar_height_offset = -60,
        })

    grid.up_button:SetTextures(COOKBOOK_ATLAS, "quagmire_recipe_scroll_arrow_hover.tex")
    grid.up_button:SetScale(0.5)

    grid.down_button:SetTextures(COOKBOOK_ATLAS, "quagmire_recipe_scroll_arrow_hover.tex")
    grid.down_button:SetScale(-0.5)

    grid.scroll_bar_line:SetTexture(COOKBOOK_ATLAS, "quagmire_recipe_scroll_bar.tex")
    grid.scroll_bar_line:SetScale(.8)

    grid.position_marker:SetTextures(COOKBOOK_ATLAS, "quagmire_recipe_scroll_handle.tex")
    grid.position_marker.image:SetTexture(COOKBOOK_ATLAS, "quagmire_recipe_scroll_handle.tex")
    grid.position_marker:SetScale(.6)

    return grid
end

-------------------------------------------------------------------------------
-- 右侧详情（装饰 + 内容）
-------------------------------------------------------------------------------
function AutocookPanel:CreateDetails()
    -- 官方 cookbookpage_crockpot.lua:78,90 用网格滚动区宽度定位详情区
    local grid_w = self.recipe_grid:GetScrollRegionSize()
    local details_x = grid_w / 2 + 30

    local decor_root = self.panel_root:AddChild(Widget("details_decor_root"))
    decor_root:SetPosition(details_x, 0)

    local block = decor_root:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_menu_block.tex"))
    block:ScaleToSize(360, DETAILS_H)

    local corner = decor_root:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_corner_decoration.tex"))
    corner:ScaleToSize(100, 100)
    corner:SetPosition(-120, -190)

    corner = decor_root:AddChild(Image(COOKBOOK_ATLAS, "quagmire_recipe_corner_decoration.tex"))
    corner:ScaleToSize(-100, 100)
    corner:SetPosition(120, -190)

    self.details_root = self.panel_root:AddChild(Widget("details_root"))
    self.details_root:SetPosition(details_x, 0)

    self:RefreshDetails()
end

-- ============================================================
-- 详情面板（复用官方 PopulateRecipeDetailPanel 布局流，追加预览条）
-- ============================================================

local INGREDIENT_ICON_REMAP = {
    onion  = "quagmire_onion",
    tomato = "quagmire_tomato",
    acorn  = "acorn_cooked",
    trunk  = "trunk_cooked",
}
local INGREDIENT_NAME_REMAP = {
    acorn = "acorn_cooked",
    trunk = "trunk_cooked",
}

-- 预览条：固定占 60px，空配方用 4 个空槽占位，避免下方元素漂移。
-- 反向配方结果显示在左侧食谱网格，不占用详情区。
function AutocookPanel:_BuildPreviewBar(root, y)
    local has = self.preview_combos ~= nil and #self.preview_combos > 0
    local show_arrows = has and #self.preview_combos > 1

    local header_text = "空配方"
    if has and not self.preview_cookable then
        -- 只供右键取物的组合，不能再提示「点击烹饪按钮确认」
        header_text = #self.preview_combos > 1
            and string.format("附近容器食材 %d/%d · 右键取物", self.preview_index, #self.preview_combos)
            or "附近容器食材 · 先右键取物"
    elseif has then
        header_text = #self.preview_combos > 1
            and string.format("预填食材 %d/%d", self.preview_index, #self.preview_combos)
            or "预填食材 - 点击烹饪按钮确认"
    end

    local header = root:AddChild(Text(HEADERFONT, 16, header_text, UICOLOURS.BROWN_DARK))
    header:SetPosition(0, y)
    y = y - 22

    local ingredient_size = 30
    local x_spacing = 2
    local items = has and self.preview_combos[self.preview_index] or nil

    if items == nil then
        local start_x = -(4 * ingredient_size + 3 * x_spacing) / 2 + ingredient_size / 2
        for i = 1, 4 do
            local slot = root:AddChild(Image(COOKBOOK_ATLAS, "cookbook_missing.tex"))
            slot:ScaleToSize(ingredient_size, ingredient_size)
            slot:SetPosition(start_x + (i - 1) * (ingredient_size + x_spacing), y)
        end
        return y - ingredient_size - 8
    end

    local total_w = #items * ingredient_size + (#items - 1) * x_spacing
    local start_x = -total_w / 2 + ingredient_size / 2

    if show_arrows then
        local btn_left = root:AddChild(ImageButton("images/frontend.xml", "turnarrow_icon.tex", "turnarrow_icon.tex", nil, nil, nil, {1, 1}, {0, 0}))
        btn_left:SetScale(0.55, 0.55)
        btn_left:SetPosition(start_x - 25, y)
        btn_left:SetOnClick(function()
            self.preview_index = self.preview_index - 1
            if self.preview_index < 1 then self.preview_index = #self.preview_combos end
            if self.on_switch_combo ~= nil then self.on_switch_combo(self, self.preview_index) end
            self:RefreshDetails()
        end)
    end

    for i = 1, #items do
        local prefab = items[i]
        local ing_name = INGREDIENT_ICON_REMAP[prefab] or prefab
        local img_name = ing_name .. ".tex"
        local img_atlas = GetInventoryItemAtlas(img_name, true)
        local img = root:AddChild(Image("images/global.xml", "square.tex"))
        img:ScaleToSize(ingredient_size, ingredient_size)
        img:SetPosition(start_x + (i - 1) * (ingredient_size + x_spacing), y)
        if img_atlas ~= nil then
            img:SetTexture(img_atlas, img_name)
        end
        local display_name = INGREDIENT_NAME_REMAP[prefab] or prefab
        img:SetHoverText(STRINGS.NAMES[string.upper(display_name)] or display_name:gsub("_", " "))
        img._ec_autocook_ingredient = prefab
    end

    if show_arrows then
        local btn_right = root:AddChild(ImageButton("images/frontend.xml", "turnarrow_icon.tex", "turnarrow_icon.tex", nil, nil, nil, {1, 1}, {0, 0}))
        btn_right:SetScale(-0.55, 0.55)
        btn_right:SetPosition(start_x + (#items - 1) * (ingredient_size + x_spacing) + 25, y)
        btn_right:SetOnClick(function()
            self.preview_index = self.preview_index + 1
            if self.preview_index > #self.preview_combos then self.preview_index = 1 end
            if self.on_switch_combo ~= nil then self.on_switch_combo(self, self.preview_index) end
            self:RefreshDetails()
        end)
    end

    return y - ingredient_size - 8
end

-- 食材图标（配方区 / 已发现配方）统一带 _ec_autocook_ingredient 标记，
-- 右键时按当前 focus 找出鼠标指向的那一个。
function AutocookPanel:_FindFocusedIngredient()
    if self.details_root == nil then
        return nil
    end
    for _, child in pairs(self.details_root.children) do
        if child.focus and child._ec_autocook_ingredient ~= nil then
            return child._ec_autocook_ingredient
        end
    end
    return nil
end

-- 检测是否有「已发现配方」数据
function AutocookPanel:_HasIngredientData(prefab)
    local known = TheCookbook ~= nil and TheCookbook.preparedfoods ~= nil
        and TheCookbook.preparedfoods[prefab] or nil
    return known ~= nil and known.recipes ~= nil and next(known.recipes) ~= nil
end

function AutocookPanel:RefreshDetails()
    local root = self.details_root
    root:KillAllChildren()

    local data = self.selected
    if data == nil then
        local hint = root:AddChild(Text(HEADERFONT, 20, "点击食谱查看详情", UICOLOURS.BROWN_DARK))
        hint:SetPosition(0, 40)
        self:_BuildPreviewBar(root, -20)
        return
    end

    local top = DETAILS_H / 2
    local left = -DETAILS_W / 2
    local image_size = 110
    local name_font_size = 34
    local title_font_size = 18
    local body_font_size = 16

    -- ===== 复用官方 PopulateRecipeDetailPanel 布局 =====
    local y = top - 11

    -- 食谱名 + 分割线
    y = y - name_font_size / 2
    local title = root:AddChild(Text(HEADERFONT, name_font_size, data.name, UICOLOURS.BROWN_DARK))
    title:SetPosition(0, y)
    y = y - name_font_size / 2 - 4
    AddDetailsLine(root, 0, y - 10, -.55, "quagmire_recipe_line_break.tex")
    y = y - 30

    -- 图标框架 + 食物贴图
    local icon_size = image_size - 20
    local frame = root:AddChild(Image("images/quagmire_recipebook.xml", "cookbook_known.tex"))
    frame:ScaleToSize(image_size, image_size)
    y = y - image_size / 2
    frame:SetPosition(left + image_size / 2 + 30, y)
    y = y - image_size / 2

    local atlas, tex = GetRecipeIcon(data)
    local food_img = root:AddChild(Image(atlas, tex))
    food_img:ScaleToSize(icon_size, icon_size)
    food_img:SetPosition(frame:GetPosition())

    -- 三维状态徽章（同官方）
    local details_x = 60
    local details_y = y + 85
    local status_scale = 0.7

    local function AddStatBadge(stat, x)
        local val = data.recipe_def ~= nil and data.recipe_def[stat] or 0
        val = math.floor(10 * val) / 10
        local id = (val >= 0) and stat or (stat .. "_bad")
        local badge = root:AddChild(TEMPLATES.MakeUIStatusBadge(id))
        badge:SetPosition(x, details_y)
        badge.status_value:SetString(tostring(val))
        badge:SetScale(status_scale)
    end
    AddStatBadge("health", details_x - 60)
    AddStatBadge("hunger", details_x)
    AddStatBadge("sanity", details_x + 60)

    y = y - 12
    local row_start_y = y
    local column_offset_x = 80

    -- 食物类型（左列）
    y = y - title_font_size / 2
    title = root:AddChild(Text(HEADERFONT, title_font_size, STRINGS.UI.COOKBOOK.FOOD_TYPE_TITLE, UICOLOURS.BROWN_DARK))
    title:SetPosition(-column_offset_x, y)
    y = y - title_font_size / 2
    AddDetailsLine(root, -column_offset_x, y - 2, .5, "quagmire_recipe_line_veryshort.tex")
    y = y - 8
    y = y - body_font_size / 2
    local type_str = STRINGS.UI.FOOD_TYPES[data.recipe_def and data.recipe_def.foodtype or FOODTYPE.GENERIC]
        or STRINGS.UI.COOKBOOK.FOOD_TYPE_UNKNOWN
    local type_tags = root:AddChild(Text(HEADERFONT, body_font_size, type_str, UICOLOURS.BROWN_DARK))
    type_tags:SetPosition(-column_offset_x, y)
    y = y - body_font_size / 2 - 4

    y = row_start_y

    -- 烹饪时间（右列，替代官方的 Perish Rate）
    y = y - title_font_size / 2
    title = root:AddChild(Text(HEADERFONT, title_font_size, STRINGS.UI.COOKBOOK.COOKINGTIME_TITLE, UICOLOURS.BROWN_DARK))
    title:SetPosition(column_offset_x, y)
    y = y - title_font_size / 2
    AddDetailsLine(root, column_offset_x, y - 2, .5, "quagmire_recipe_line_veryshort.tex")
    y = y - 8
    y = y - body_font_size / 2
    local time_str = GetCookingTimeString(data.cooktime or (data.recipe_def and data.recipe_def.cooktime))
    local time_tags = root:AddChild(Text(HEADERFONT, body_font_size, time_str, UICOLOURS.BROWN_DARK))
    time_tags:SetPosition(column_offset_x, y)
    y = y - body_font_size / 2 - 4

    -- ===== 预览条（固定区块；反向配方标在左侧食谱网格） =====
    y = y - 15
    y = self:_BuildPreviewBar(root, y)

    -- ===== 已发现配方（复用官方 _SetupRecipeIngredientDetails） =====
    y = y - 15
    if self:_HasIngredientData(data.prefab) then
        y = y - title_font_size / 2
        title = root:AddChild(Text(HEADERFONT, title_font_size, STRINGS.UI.RECIPE_BOOK.DETAILS_LABEL_RECIPES, UICOLOURS.BROWN_DARK))
        title:SetPosition(0, y)
        y = y - title_font_size / 2
        AddDetailsLine(root, 0, y - 2, .49)
        y = y - 10
        self:_SetupIngredientDetails(data.prefab, root, y)
    end
end

-------------------------------------------------------------------------------
-- 数据注入
-------------------------------------------------------------------------------
function AutocookPanel:_SetupIngredientDetails(prefab, parent, y)
    local known = TheCookbook ~= nil and TheCookbook.preparedfoods ~= nil
        and TheCookbook.preparedfoods[prefab] or nil
    if known == nil or known.recipes == nil or next(known.recipes) == nil then
        return
    end

    local recipes = known.recipes  -- array of ingredient arrays

    local ingredient_size = 30
    local x_spacing = 2
    local row_h = ingredient_size + 5
    local icon_y = y - ingredient_size / 2

    if #recipes <= 3 then
        for b = 1, #recipes do
            local items = recipes[b]
            local x = -((#items + 1) * ingredient_size + (#items - 1) * x_spacing) / 2
            for i = 1, #items do
                local ing_name = INGREDIENT_ICON_REMAP[items[i]] or items[i]
                local img_name = ing_name .. ".tex"
                local img_atlas = GetInventoryItemAtlas(img_name, true)
                local img = parent:AddChild(Image(img_atlas or COOKBOOK_ATLAS, img_atlas ~= nil and img_name or "cookbook_missing.tex"))
                img:ScaleToSize(ingredient_size, ingredient_size)
                img:SetPosition(x + i * ingredient_size + (i - 1) * x_spacing, icon_y - (b - 1) * row_h)
                local display_name = INGREDIENT_NAME_REMAP[items[i]] or items[i]
                img:SetHoverText(STRINGS.NAMES[string.upper(display_name)] or display_name:gsub("_", " "))
                img._ec_autocook_ingredient = items[i]
            end
        end
    else
        local width = 4 * ingredient_size + 3 * x_spacing
        local col_gap = 8
        for b = 1, #recipes do
            local items = recipes[b]
            local col = b % 2
            local row = math.floor((b - 1) / 2)
            local x_offset = (col == 1) and (-width - ingredient_size + col_gap / 2) or (-col_gap / 2)
            for i = 1, #items do
                local ing_name = INGREDIENT_ICON_REMAP[items[i]] or items[i]
                local img_name = ing_name .. ".tex"
                local img_atlas = GetInventoryItemAtlas(img_name, true)
                local img = parent:AddChild(Image(img_atlas or COOKBOOK_ATLAS, img_atlas ~= nil and img_name or "cookbook_missing.tex"))
                img:ScaleToSize(ingredient_size, ingredient_size)
                img:SetPosition(x_offset + i * ingredient_size + (i - 1) * x_spacing, icon_y - row * row_h)
                local display_name = INGREDIENT_NAME_REMAP[items[i]] or items[i]
                img:SetHoverText(STRINGS.NAMES[string.upper(display_name)] or display_name:gsub("_", " "))
                img._ec_autocook_ingredient = items[i]
            end
        end
    end
end

-- 数据层的枚举分帧预算挂在 widget 更新循环里；开锅 StartUpdating、关锅 StopUpdating
function AutocookPanel:OnUpdate(dt)
    if self.on_update ~= nil then
        self.on_update(dt)
    end
end

function AutocookPanel:SetPreviewCombos(combos, cookable)
    self.preview_combos = combos
    self.preview_cookable = cookable == true
    self.preview_index = 1
    self:RefreshDetails()
end

function AutocookPanel:SetRecipeList(recipes)
    local previous = self.selected ~= nil and self.selected.prefab or nil

    self.all_recipes = recipes or {}
    -- 食谱目录是跨开锅复用的表，档位必须先清掉，否则新一轮会用上一锅的旧标记取组合
    for _, recipe in ipairs(self.all_recipes) do
        recipe.craftable = false
        recipe.autocook_nearby = false
    end
    self.selected = nil
    self._user_selected = false
    self._last_craftable_key = nil

    if previous ~= nil then
        for _, recipe in ipairs(self.all_recipes) do
            if recipe.prefab == previous then
                self.selected = recipe
                break
            end
        end
    end

    if self.selected == nil then
        self.selected = self.all_recipes[1]
    end

    self:BuildFoodtypeOptions()
end

-- 未手动选过食谱时，自动落在「可一键烹饪」的食谱上；
-- 没有可做的才退到「附近有材料」，最后才轮到无材料。
function AutocookPanel:SelectBestCraftable()
    local best = nil
    for _, recipe in ipairs(self.filtered_recipes) do
        if recipe.craftable == true then
            best = recipe
            break
        end
    end
    if best == nil then
        for _, recipe in ipairs(self.filtered_recipes) do
            if recipe.autocook_nearby == true then
                best = recipe
                break
            end
        end
    end
    if best == nil then
        best = self.filtered_recipes[1]
    end

    if best == nil or best == self.selected then
        return
    end
    self.selected = best
    self.recipe_grid:RefreshView()
    self:RefreshDetails()
end

function AutocookPanel:SetCraftableMap(craftable_map)
    self.craftable_map = craftable_map or {}

    for _, recipe in ipairs(self.all_recipes) do
        recipe.craftable = self.craftable_map[recipe.prefab] == true
    end

    self:ApplyFilters()

    -- 档位没变就不重建预览：planner 分帧期间每 0.35s 会重算一次
    local parts = {}
    for _, recipe in ipairs(self.all_recipes) do
        if recipe.craftable then
            table.insert(parts, "c:" .. recipe.prefab)
        elseif recipe.autocook_nearby then
            table.insert(parts, "n:" .. recipe.prefab)
        end
    end
    local key = table.concat(parts, ",")
    if key == self._last_craftable_key then
        return
    end
    self._last_craftable_key = key

    if not self._user_selected then
        self:SelectBestCraftable()
    end
    -- 档位变了必须重取当前选中食谱的组合，否则 Cook 会用旧配方的投料条目
    if self.selected ~= nil and self.on_fill ~= nil then
        self.on_fill(self, self.selected)
    end
end

-- 通道 2：把「当前锅会做出什么」标到食谱网格，而不是详情区。
function AutocookPanel:SetPotCandidates(candidates)
    self.pot_candidates = candidates

    for _, recipe in ipairs(self.all_recipes) do
        recipe.autocook_pot = false
        recipe.autocook_pot_random = false
    end

    if candidates ~= nil and candidates.names ~= nil then
        local by_prefab = {}
        for _, recipe in ipairs(self.all_recipes) do
            by_prefab[recipe.prefab] = recipe
        end
        for _, name in ipairs(candidates.names) do
            local recipe = by_prefab[name]
            if recipe ~= nil then
                recipe.autocook_pot = true
                recipe.autocook_pot_random = not candidates.deterministic
            end
        end
    end

    -- 过滤列表变了，必须重跑 ApplyFilters（只 RefreshView 不会隐藏无关食谱）
    self:ApplyFilters()
end

function AutocookPanel:SetMedalFoodSet(food_set)
    self.medal_food_set = food_set or {}
    self.recipe_grid:RefreshView()
end

function AutocookPanel:BuildFoodtypeOptions()
    local seen = {}
    for _, recipe in ipairs(self.all_recipes) do
        seen[recipe.foodtype or FOODTYPE.GENERIC] = true
    end

    local foodtypes = {}
    for foodtype in pairs(seen) do
        table.insert(foodtypes, foodtype)
    end
    table.sort(foodtypes, function(a, b)
        return GetFoodTypeName(a) < GetFoodTypeName(b)
    end)

    local options = { { text = "全部种类", data = FILTER_ALL } }
    for _, foodtype in ipairs(foodtypes) do
        table.insert(options, { text = GetFoodTypeName(foodtype), data = foodtype })
    end

    self._suppress_change = true

    self.foodtype_spinner:SetOptions(options)

    local still_valid = self.foodtype_filter == FILTER_ALL
    if not still_valid then
        for _, option in ipairs(options) do
            if option.data == self.foodtype_filter then
                still_valid = true
                break
            end
        end
    end
    if not still_valid then
        self.foodtype_filter = FILTER_ALL
    end
    self.foodtype_spinner:SetSelected(self.foodtype_filter)

    self._suppress_change = false
end

-------------------------------------------------------------------------------
-- 筛选 / 排序
-------------------------------------------------------------------------------
function AutocookPanel:ApplyFilters()
    -- 锅内已填食材：网格只显示反向预测出来的料理，避免已确认结果旁边还堆着无关食谱。
    -- 没有任何预测料理能对应到食谱目录时，退化为正常显示全部食谱。
    local pot_only = false
    for _, recipe in ipairs(self.all_recipes) do
        if recipe.autocook_pot == true then
            pot_only = true
            break
        end
    end

    local filtered = {}
    for _, recipe in ipairs(self.all_recipes) do
        local keep = true

        if keep and pot_only then
            keep = recipe.autocook_pot == true
        end

        -- 只看预测料理时忽略食物类型筛选，否则可能把预测结果全筛掉
        if keep and not pot_only and self.foodtype_filter ~= FILTER_ALL then
            keep = (recipe.foodtype or FOODTYPE.GENERIC) == self.foodtype_filter
        end

        if keep then
            table.insert(filtered, recipe)
        end
    end

    self:SortRecipes(filtered)

    self.filtered_recipes = filtered
    self.recipe_grid:SetItemsData(filtered)
    self.recipe_grid:RefreshView()

    if self.selected ~= nil then
        local still_visible = false
        for _, recipe in ipairs(filtered) do
            if recipe == self.selected then
                still_visible = true
                break
            end
        end
        if not still_visible then
            -- 选中项被筛掉时重取组合，避免详情换了食谱而 Cook 仍投旧配方的料
            self.selected = nil
            self._user_selected = false
            self:SelectBestCraftable()
            if self.selected == nil then
                self:RefreshDetails()
            elseif self.on_fill ~= nil then
                self.on_fill(self, self.selected)
            end
        end
    end
end

function AutocookPanel:SortRecipes(list)
    local mode = self.sort_mode

    -- 三档优先：可做 → 附近有材料（灰色）→ 无材料（深灰）
    local function TierOf(recipe)
        if recipe.craftable == true then return 0 end
        if recipe.autocook_nearby == true then return 1 end
        return 2
    end

    local function craftable_first(a, b)
        local ta, tb = TierOf(a), TierOf(b)
        if ta ~= tb then
            return ta < tb
        end
        return nil
    end

    local function StatSort(stat)
        table.sort(list, function(a, b)
            local cf = craftable_first(a, b)
            if cf ~= nil then return cf end
            local va = a[stat] or 0
            local vb = b[stat] or 0
            if va == vb then
                return (a.name or "") < (b.name or "")
            end
            return va > vb
        end)
    end

    if mode == "alphabetical" then
        table.sort(list, function(a, b)
            local cf = craftable_first(a, b)
            if cf ~= nil then return cf end
            return (a.name or "") < (b.name or "")
        end)
    elseif mode == "health" then
        StatSort("health")
    elseif mode == "hunger" then
        StatSort("hunger")
    elseif mode == "sanity" then
        StatSort("sanity")
    else
        table.sort(list, function(a, b)
            local cf = craftable_first(a, b)
            if cf ~= nil then return cf end
            local pa = a.priority or 0
            local pb = b.priority or 0
            if pa == pb then
                return (a.name or "") < (b.name or "")
            end
            return pa > pb
        end)
    end
end

-------------------------------------------------------------------------------
-- 交互
-------------------------------------------------------------------------------
function AutocookPanel:OnCellClicked(data)
    if data == nil then
        return
    end

    self.selected = data
    self._user_selected = true
    self.recipe_grid:RefreshView()
    self:RefreshDetails()

    -- 单击即取预览：可做 / 附近有材料都要能看到所需食材（右键取物入口）；
    -- 无材料由 on_fill 清掉旧预览，真正投料仍按实时库存门控。
    if self.on_fill ~= nil then
        self.on_fill(self, data)
    end
end

return AutocookPanel