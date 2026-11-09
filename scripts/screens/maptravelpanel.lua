local Widget = require "widgets/widget"
local Text = require "widgets/text"
local TextEdit = require "widgets/textedit"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local UIAnim = require "widgets/uianim"
local UIAnimButton = require "widgets/uianimbutton"
local TEMPLATES = require "widgets/redux/templates"
local MapTravelScrollList = require "screens/maptravelscrolllist"
local HeaderTabs = require "widgets/redux/headertabs"

local label_width = 140
local widget_width = 150

local function NormalizeHeading(heading)
    while heading < -180 do heading = heading + 360 end
    while heading > 180 do heading = heading - 360 end
    return heading
end

local function EaseHeading(heading0, heading1, k)
    local delta = NormalizeHeading(heading1 - heading0)
    return NormalizeHeading(heading0 + math.clamp(delta * k, -20, 20))
end
local height = 28
local spacing = 3
local total_width = label_width + widget_width + spacing
local bg_width = spacing + total_width + spacing + 10
local bg_height = height + 2

-- 自官方 wortox_travel_panel 移植：重命名、去掉 Wortox 全局依赖，改用本模组 AddMapLocation / RebuildMapWheel
local MapTravelPanel = Class(Widget,
    function(self, owner, strings, get_locations_fn, delete_location_fn, rename_location_fn, on_locations_changed_fn, format_text_fn, get_chassis_fn, rename_chassis_fn)
        Widget._ctor(self, "MapTravelPanel")

        self.owner = owner
        self.isFE = false
        self.filters_shown = false
        self.current_search_filter = ""

        self.get_locations = get_locations_fn
        self.delete_location = delete_location_fn
        self.rename_location = rename_location_fn
        -- 底盘（备份底盘 + 自身机身）：只在列表里改名，不进外环轮盘
        self.get_chassis = get_chassis_fn
        self.rename_chassis = rename_chassis_fn
        self.on_locations_changed = on_locations_changed_fn
        self.format_location_text = format_text_fn

        self.strings = strings or {
            FILTERS = "Locations",
            DETAILS = "Details",
            TITLE = "Point Travel",
            NO_LOCATION = "No location selected",
            SEARCH_PLACEHOLDER = "Search locations",
            INPUT_PLACEHOLDER = "Enter location name",
            COORD_PLACEHOLDER = "Enter coordinates (e.g: 100.5, 50.3)",
            SAVE_BUTTON = "Save Current Position",
        }

        self:SetVAnchor(ANCHOR_MIDDLE)
        self:SetHAnchor(ANCHOR_MIDDLE)
        self:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local panel_width = 250
        local details_height = 277

        self.panelbg = self:AddChild(TEMPLATES.RectangleWindow(panel_width, details_height))
        self.panelbg.top:Hide()
        local r, g, b = unpack(UICOLOURS.BROWN_DARK)
        self.panelbg:SetBackgroundTint(r, g, b, 0.6)

        local function toggle_filter_fn() self:ToggleShowFilters() end
        local buttons = {
            {
                text = self.strings.FILTERS,
                cb = toggle_filter_fn,
            },
            {
                text = self.strings.DETAILS,
                cb = toggle_filter_fn,
            },
        }
        self.filters_header = self:AddChild(HeaderTabs(buttons))
        self.filters_header:SetPosition(0, details_height / 2 + 22.5)
        self.filters_header:SetScale(0.8)
        self.filters_header:MoveToBack()

        local close_btn_size = 30
        self.close_button = self:AddChild(ImageButton("images/global_redux.xml", "close.tex"))
        self.close_button:SetOnClick(function()
            self:Close()
        end)
        self.close_button.ignore_standard_scaling = true
        self.close_button:SetNormalScale(1, 1, 1)
        self.close_button:SetFocusScale(1.1, 1.1, 1)
        self.close_button:ForceImageSize(close_btn_size, close_btn_size)
        self.close_button:SetImageNormalColour(UICOLOURS.RED)
        self.close_button:SetImageFocusColour(UICOLOURS.RED)
        self.close_button:SetPosition(panel_width / 2 - close_btn_size / 2 + 35, details_height / 2 - close_btn_size / 2 - 5)
        self.close_button:SetHoverText("关闭")

        local search_width = 230
        local search_height = height

        local function CreateLocationButton(parent, location, onclick, ondelete, onrename)
            local group = parent:AddChild(Widget("location_item"))

            group.bg = group:AddChild(TEMPLATES.ListItemBackground(bg_width, bg_height))
            group.bg:MoveToBack()

            if location.location_type then
                local icon_atlas, icon_tex, icon_scale
                if location.location_type == "cave" then
                    icon_atlas = "minimap/minimap_data.xml"
                    icon_tex = "cave_open.png"
                    icon_scale = 0.4
                else
                    icon_atlas = "images/serverplaystyles.xml"
                    icon_tex = "endless_small.tex"
                    icon_scale = 0.1
                end

                group.type_icon = group:AddChild(Image(icon_atlas, icon_tex))
                group.type_icon:SetPosition((-total_width / 2) + 15, 0)
                group.type_icon:SetScale(icon_scale)
            end

            local name = location.name or "未命名"
            local coords = string.format("%.1f, %.1f", location.x or 0.0, location.z or 0.0)

            -- 名字即输入框：参考 2753774601 transfer_panel.lua:206-219 的行内编辑做法——
            -- 每行自身的名字用 TextEdit 承载，点击即可输入，回车提交改名，无需弹窗。
            local gold = UICOLOURS.GOLD
            group.label = group:AddChild(TextEdit(TITLEFONT, 20, name))
            group.label:SetPosition((-total_width / 2) + 30 + 60, 0)
            group.label:SetRegionSize(120, height * 1.4)
            group.label:SetHAlign(ANCHOR_LEFT)
            group.label:SetColour(gold)
            group.label:SetIdleTextColour(gold[1] or 1, gold[2] or 1, gold[3] or 1, gold[4] or 1)
            group.label:SetEditTextColour(1, 1, 1, 1)
            group.label:SetTextLengthLimit(50)
            group.label:EnableWordWrap(false)
            group.label:EnableScrollEditWindow(true)
            group.label:SetString(name)
            -- 回车提交（回调会随行刷新建带正确的 data.index）
            group.label.OnTextEntered = function(text)
                if onrename then onrename(text) end
            end

            group.coords_label = group:AddChild(Text(CHATFONT, 18, coords))
            group.coords_label:SetPosition((-total_width / 2) + 30 + 130, 0)
            group.coords_label:SetRegionSize(80, height * 1.4)
            group.coords_label:SetHAlign(ANCHOR_LEFT)
            group.coords_label:SetColour(0, 1, 0, 1)

            group.label:SetClickable(true)
            group.label.OnClick = onclick

            group.coords_label:SetClickable(true)
            group.coords_label.OnClick = onclick

            local button_x = (total_width / 2) - 20
            group.delete_btn = group:AddChild(TEMPLATES.IconButton(
                "images/button_icons.xml",
                "delete.tex",
                "删除",
                false,
                false,
                ondelete,
                {
                    offset_x = 0,
                    offset_y = 20,
                }
            ))
            group.delete_btn:SetPosition(button_x, 0)
            group.delete_btn:SetScale(.5)
            group.delete_btn:SetHelpTextMessage("删除此位置")

            group.focus_forward = group.delete_btn

            return group
        end

        local function ChassisDisplayName(c)
            -- 当前机身 = 你正在使用的机体；备份底盘 = 轮盘里可换身的目标。
            -- 二者命名需彼此区分，名字才有意义（避免张冠李戴）。
            return c.name or (c.is_self and "当前机身" or "备份底盘")
        end

        -- 底盘行：只能就地改名，没有删除/传送按钮。
        -- 自身机身不可传送（只有换身之后它才会变成可传送的备份底盘）；
        -- 备份底盘的传送入口在外环轮盘里，这里只负责改名。
        local function CreateChassisButton(parent, chassis, onrename)
            local group = parent:AddChild(Widget("chassis_item"))
            group.bg = group:AddChild(TEMPLATES.ListItemBackground(bg_width, bg_height))
            group.bg:MoveToBack()

            local name = ChassisDisplayName(chassis)
            local coords = string.format("%.1f, %.1f", chassis.x or 0.0, chassis.z or 0.0)
            local gold = UICOLOURS.GOLD

            group.label = group:AddChild(TextEdit(TITLEFONT, 20, name))
            group.label:SetPosition((-total_width / 2) + 30 + 60, 0)
            group.label:SetRegionSize(120, height * 1.4)
            group.label:SetHAlign(ANCHOR_LEFT)
            group.label:SetColour(gold)
            group.label:SetIdleTextColour(gold[1] or 1, gold[2] or 1, gold[3] or 1, gold[4] or 1)
            group.label:SetEditTextColour(1, 1, 1, 1)
            group.label:SetTextLengthLimit(50)
            group.label:EnableWordWrap(false)
            group.label:EnableScrollEditWindow(true)
            group.label:SetString(name)
            group.label.OnTextEntered = function(text)
                if onrename then onrename(text) end
            end

            group.coords_label = group:AddChild(Text(CHATFONT, 18,
                chassis.is_self and (coords .. " (当前·你在此)") or coords))
            group.coords_label:SetPosition((-total_width / 2) + 30 + 130, 0)
            group.coords_label:SetRegionSize(80, height * 1.4)
            group.coords_label:SetHAlign(ANCHOR_LEFT)
            group.coords_label:SetColour(0, 1, 0, 1)

            group.focus_forward = group.label
            return group
        end

        local function BuildScrollData(search_filter)
            local data = {}
            table.insert(data, { type = "search" })

            -- 底盘（当前机身 + 备份底盘）：只在此列表中改名，不进外环轮盘、不可传送。
            -- 当前机身排在最前并明确标注，避免与备份底盘混淆导致改名张冠李戴。
            local chassis = self.get_chassis and self.get_chassis() or {}
            local self_entry = nil
            local backups = {}
            for _, c in ipairs(chassis) do
                if c.is_self then
                    self_entry = c
                else
                    table.insert(backups, c)
                end
            end
            if self_entry ~= nil then
                table.insert(data, { type = "chassis", chassis = self_entry })
            end
            for _, c in ipairs(backups) do
                table.insert(data, { type = "chassis", chassis = c })
            end

            local locations = self.get_locations and self.get_locations() or {}
            for i, location in ipairs(locations) do
                local should_show = true
                if search_filter and search_filter ~= "" then
                    local location_name = (location.name or ""):lower()
                    local search_text = search_filter:lower()
                    should_show = location_name:find(search_text, 1, true) ~= nil
                end

                if should_show then
                    table.insert(data, {
                        type = "location",
                        index = i,
                        location = location
                    })
                end
            end

            return data
        end

        local function ScrollItemCtor(context, index)
            local widget = Widget("scroll_item_" .. index)

            local item_searchparent = widget:AddChild(Widget("searchbox"))
            local item_searchbox = item_searchparent:AddChild(TEMPLATES.StandardSingleLineTextEntry("", search_width,
                search_height, CHATFONT, 20, context.strings.SEARCH_PLACEHOLDER or "Search locations"))
            item_searchbox:SetPosition(0, 0)
            item_searchbox.textbox:SetTextLengthLimit(50)
            item_searchbox.textbox:SetForceEdit(true)
            item_searchbox.textbox:EnableWordWrap(false)
            item_searchbox.textbox:EnableScrollEditWindow(true)

            item_searchbox.textbox.OnTextInputted = function(str)
                if context.searchtask then
                    context.searchtask:Cancel()
                end
                context.searchtask = context.inst:DoStaticTaskInTime(0, function()
                    local search_text = item_searchbox.textbox:GetString()
                    context.current_search_filter = search_text
                    context.RefreshLocationButtons()
                end)
            end

            item_searchbox.textbox.OnTextEntered = function(str)
                local search_text = item_searchbox.textbox:GetString()
                context.current_search_filter = search_text
                context.RefreshLocationButtons()
            end

            item_searchbox:SetOnGainFocus(function() item_searchbox.textbox:OnGainFocus() end)
            item_searchbox:SetOnLoseFocus(function() item_searchbox.textbox:OnLoseFocus() end)
            item_searchparent.focus_forward = item_searchbox
            widget.search = item_searchparent

            widget.location_button = nil

            return widget
        end

        local function ScrollItemApply(context, widget, data, index)
            if widget.search then widget.search:Hide() end
            if widget.location_button then widget.location_button:Hide() end
            if widget.chassis_button then widget.chassis_button:Hide() end

            if not data then
                return
            end

            if data.type == "search" then
                widget.search:Show()
            elseif data.type == "location" then
                if not widget.location_button then
                    widget.location_button = CreateLocationButton(
                        widget,
                        data.location,
                        function() context:OnSelectLocation(data.index, data.location) end,
                        function() context:OnDeleteLocation(data.index, data.location) end,
                        function(text) context:OnRenameLocation(data.index, text) end
                    )
                else
                    local name = data.location.name or "未命名"
                    local coords = string.format("%.1f, %.1f", data.location.x or 0.0, data.location.z or 0.0)

                    widget.location_button.label:SetString(name)
                    widget.location_button.coords_label:SetString(coords)

                    if widget.location_button.type_icon and data.location.location_type then
                        local icon_atlas, icon_tex, icon_scale
                        if data.location.location_type == "cave" then
                            icon_atlas = "minimap/minimap_data.xml"
                            icon_tex = "cave_open.png"
                            icon_scale = 0.4
                        else
                            icon_atlas = "images/serverplaystyles.xml"
                            icon_tex = "endless_small.tex"
                            icon_scale = 0.1
                        end
                        widget.location_button.type_icon:SetTexture(icon_atlas, icon_tex)
                        widget.location_button.type_icon:SetScale(icon_scale)
                    end

                    widget.location_button.label.OnClick = function() context:OnSelectLocation(data.index, data.location) end
                    widget.location_button.coords_label.OnClick = function() context:OnSelectLocation(data.index, data.location) end
                    widget.location_button.delete_btn.onclick = function() context:OnDeleteLocation(data.index, data.location) end
                    -- 行被滚动复用/刷新后必须重新绑定，否则回车改到旧行（data.index 已变）
                    widget.location_button.label.OnTextEntered = function(text)
                        context:OnRenameLocation(data.index, text)
                    end
                end
                widget.location_button:Show()
            elseif data.type == "chassis" then
                if not widget.chassis_button then
                    widget.chassis_button = CreateChassisButton(
                        widget,
                        data.chassis,
                        function(text) context:OnRenameChassis(data.chassis.key, text) end
                    )
                else
                    local coords = string.format("%.1f, %.1f", data.chassis.x or 0.0, data.chassis.z or 0.0)
                    widget.chassis_button.label:SetString(ChassisDisplayName(data.chassis))
                    widget.chassis_button.coords_label:SetString(
                        data.chassis.is_self and (coords .. " (自身)") or coords)
                    -- 行复用：必须重绑，否则回车会把名字改到别的底盘上
                    widget.chassis_button.label.OnTextEntered = function(text)
                        context:OnRenameChassis(data.chassis.key, text)
                    end
                end
                widget.chassis_button:Show()
            end
        end

        self.RefreshLocationButtons = function()
            local data = BuildScrollData(self.current_search_filter)
            if self.filters_scroll_list then
                self.filters_scroll_list:SetItemsData(data)
            end
        end

        local scroll_width = 230
        local scroll_height = details_height
        local item_height = bg_height
        local item_padding = 5
        local num_visible_rows = math.floor((scroll_height - item_padding) / (item_height + item_padding))

        self.filters_scroll_list = self:AddChild(MapTravelScrollList({
            scroll_context = self,
            item_ctor_fn = ScrollItemCtor,
            apply_fn = ScrollItemApply,
            widget_width = scroll_width,
            widget_height = item_height,
            row_padding = item_padding,
            num_visible_rows = num_visible_rows
        }))
        self.filters_scroll_list:SetPosition(0, 0)

        self.RefreshLocationButtons()

        self.details_tab = self:AddChild(Widget("details_tab"))

        local detail_x = 0
        local width = 240
        local detail_y = details_height / 2 - 70

        self.current_coords_text = self.details_tab:AddChild(Text(CHATFONT, 22))
        self.current_coords_text:SetPosition(detail_x, detail_y, 0)
        self.current_coords_text:SetHAlign(ANCHOR_MIDDLE)
        self.current_coords_text:SetColour(UICOLOURS.GOLD_SELECTED)

        local locale = LOC and LOC.GetLocaleCode() or "en"
        local is_chinese = locale == "zh" or locale == "zhr" or locale == "zhs"
        self.coord_prefix = is_chinese and "当前坐标: " or "Current Position: "

        if self.owner and self.owner.Transform then
            local x, y, z = self.owner.Transform:GetWorldPosition()
            self.current_coords_text:SetString(string.format("%s%.1f, %.1f", self.coord_prefix, x, z))
        else
            self.current_coords_text:SetString(string.format("%s0.0, 0.0", self.coord_prefix))
        end

        detail_y = detail_y - 40

        local input_width = 230
        local input_height = height
        local inputparent = self.details_tab:AddChild(Widget("inputbox"))
        self.location_input = inputparent:AddChild(TEMPLATES.StandardSingleLineTextEntry("", input_width, input_height,
            CHATFONT, 20, self.strings.INPUT_PLACEHOLDER or "Enter location name"))
        self.location_input:SetPosition(detail_x, detail_y, 0)
        self.location_input.textbox:SetTextLengthLimit(50)
        self.location_input.textbox.OnTextEntered = function()
            local location_name = self.location_input.textbox:GetString()
        end
        self.location_input:SetOnGainFocus(function() self.location_input.textbox:OnGainFocus() end)
        self.location_input:SetOnLoseFocus(function() self.location_input.textbox:OnLoseFocus() end)
        inputparent.focus_forward = self.location_input

        detail_y = detail_y - 50

        local coord_inputparent = self.details_tab:AddChild(Widget("coord_inputbox"))
        self.coord_input = coord_inputparent:AddChild(TEMPLATES.StandardSingleLineTextEntry("", input_width, input_height,
            CHATFONT, 20, self.strings.COORD_PLACEHOLDER or "Enter coordinates (e.g: 100.5, 50.3)"))
        self.coord_input:SetPosition(detail_x, detail_y, 0)
        self.coord_input.textbox:SetTextLengthLimit(30)
        self.coord_input.textbox.OnTextEntered = function()
            local coord_text = self.coord_input.textbox:GetString()
        end
        self.coord_input:SetOnGainFocus(function() self.coord_input.textbox:OnGainFocus() end)
        self.coord_input:SetOnLoseFocus(function() self.coord_input.textbox:OnLoseFocus() end)
        coord_inputparent.focus_forward = self.coord_input

        local compass_x = detail_x + input_width / 2 + 20
        local compass_y = detail_y - 25

        self.compass_button = self.details_tab:AddChild(UIAnimButton("compass_hud", "compass_hud", "idle"))
        self.compass_button:SetPosition(compass_x, compass_y, 0)
        self.compass_button:SetScale(0.35)

        self.compass_button.animstate:Hide("arm")
        self.compass_button.animstate:Hide("arm1-0")
        self.compass_button.animstate:Hide("arm2-0")
        self.compass_button.animstate:Hide("arm top")

        self.compass_needle = self.compass_button:AddChild(UIAnim())
        self.compass_needle:GetAnimState():SetBank("compass_needle")
        self.compass_needle:GetAnimState():SetBuild("compass_needle")
        self.compass_needle:GetAnimState():PlayAnimation("idle", true)
        self.compass_needle:SetPosition(0, 70, 0)
        self.compass_needle:SetScale(1.0)

        self.compass_button:SetOnGainFocus(function()
            self.compass_button:SetScale(0.40)
        end)

        self.compass_button:SetOnLoseFocus(function()
            self.compass_button:SetScale(0.35)
        end)

        local hover_text = is_chinese and "点击获取坐标" or "Click to Get Coordinates"
        self.compass_button:SetHoverText(hover_text, { offset_y = -25 })

        self.compass_button.onclick = function()
            if self.owner and self.owner.Transform and self.coord_input then
                local x, y, z = self.owner.Transform:GetWorldPosition()
                self.coord_input.textbox:SetString(string.format("%.1f, %.1f", x, z))
            end
        end

        self.compass_displayheading = 0
        self.compass_currentheading = 0
        self.compass_headingvel = 0
        self.compass_forceperdegree = 0.005
        self.compass_damping = 0.98

        detail_y = detail_y - 50

        local save_button_width = 230
        self.save_button = self.details_tab:AddChild(TEMPLATES.StandardButton(
            function()
                local location_name = self.location_input.textbox:GetString()
                local coord_text = self.coord_input.textbox:GetString()

                if location_name ~= "" then
                    local x, z

                    if coord_text ~= "" then
                        local x_str, z_str = coord_text:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)")
                        if x_str and z_str then
                            x = tonumber(x_str)
                            z = tonumber(z_str)
                        end
                    end

                    if not x or not z then
                        if self.owner and self.owner.Transform then
                            local px, py, pz = self.owner.Transform:GetWorldPosition()
                            x = px
                            z = pz
                        end
                    end

                    if x and z and AddMapLocation then
                        AddMapLocation(location_name, x, z)

                        if self.RefreshLocationButtons then
                            self.RefreshLocationButtons()
                        end

                        if RebuildMapWheel then
                            RebuildMapWheel()
                        end

                        if self.owner and self.owner.components.talker then
                            local msg = string.format("已保存: %s (%.1f, %.1f)", location_name, x, z)
                            self.owner.components.talker:Say(msg)
                        end

                        self.location_input.textbox:SetString("")
                        self.coord_input.textbox:SetString("")

                        if self.owner then
                            self.owner:DoTaskInTime(0.1, function()
                                self:Close()
                            end)
                        else
                            self:Close()
                        end
                    end
                end
            end,
            self.strings.SAVE_BUTTON or "Save Current Position",
            { save_button_width, 40 }
        ))
        self.save_button:SetPosition(detail_x, detail_y, 0)

        self.focus_forward = self.filters_scroll_list

        self:ToggleShowFilters()

        self.coord_update_task = self.inst:DoPeriodicTask(0.1, function()
            if self.current_coords_text and self.owner and self.owner.Transform then
                local x, y, z = self.owner.Transform:GetWorldPosition()
                self.current_coords_text:SetString(string.format("%s%.1f, %.1f", self.coord_prefix, x, z))
            end
        end)

        self:StartUpdating()
    end)

function MapTravelPanel:OnUpdate(dt)
    if self.compass_needle and TheCamera then
        local target_heading = TheCamera:GetHeading() - 45

        local delta = NormalizeHeading(target_heading - self.compass_currentheading)

        self.compass_headingvel = self.compass_headingvel + delta * self.compass_forceperdegree
        self.compass_headingvel = self.compass_headingvel * self.compass_damping
        self.compass_currentheading = NormalizeHeading(self.compass_currentheading + self.compass_headingvel)

        self.compass_displayheading = EaseHeading(self.compass_displayheading, self.compass_currentheading, 0.5)

        self.compass_needle:SetRotation(self.compass_displayheading)
    end
end

function MapTravelPanel:ToggleShowFilters(forcehide)
    if not self.filters_shown and not forcehide then
        self.filters_shown = true
        self.filters_header:SelectButton(1)
        self.filters_scroll_list:Show()
        self.details_tab:Hide()
    else
        self.filters_shown = false
        self.filters_header:SelectButton(2)
        self.filters_scroll_list:Hide()
        self.details_tab:Show()
    end
end

function MapTravelPanel:OnSelectLocation(index, location)
    if location and self.owner and self.owner.components.talker then
        local display_text = self.format_location_text and self.format_location_text(location) or
        (location.name or "未知位置")
        self.owner.components.talker:Say("选择: " .. display_text)
    end

    if self.owner then
        self.owner:DoTaskInTime(0.5, function()
            self:Close()
        end)
    else
        self:Close()
    end
end

function MapTravelPanel:OnDeleteLocation(index, location)
    if self.delete_location then
        local success = self.delete_location(index)
        if success then
            if self.owner and self.owner.components.talker then
                local display_text = self.format_location_text and self.format_location_text(location) or
                (location.name or "未知位置")
                self.owner.components.talker:Say("删除: " .. display_text)
            end

            self.RefreshLocationButtons()

            if self.on_locations_changed then
                self.on_locations_changed()
            end
        end
    end
end

function MapTravelPanel:OnRenameLocation(index, newname)
    if self.rename_location then
        local success = self.rename_location(index, newname)
        if success then
            -- 与删除保持一致：刷新列表 + 通知外部（轮盘数据集）重建
            self.RefreshLocationButtons()

            if self.on_locations_changed then
                self.on_locations_changed()
            end
        end
    end
end

function MapTravelPanel:OnRenameChassis(key, newname)
    if self.rename_chassis then
        local success = self.rename_chassis(key, newname)
        if success then
            self.RefreshLocationButtons()

            if self.on_locations_changed then
                self.on_locations_changed()
            end
        end
    end
end

function MapTravelPanel:Close()
    if self.coord_update_task then
        self.coord_update_task:Cancel()
        self.coord_update_task = nil
    end

    self:StopUpdating()

    if self.parent then
        self.parent:RemoveChild(self)
    end
    self:Kill()
end

return MapTravelPanel
