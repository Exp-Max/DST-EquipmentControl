local Widget = require "widgets/widget"
local Image = require "widgets/image"

-- 自官方 wortoxscrolllist 移植，仅重命名，供 maptravelpanel 复用
local MapTravelScrollList = Class(Widget, function(self, params)
    Widget._ctor(self, "MapTravelScrollList")

    self.item_ctor_fn = params.item_ctor_fn
    self.apply_fn = params.apply_fn
    self.scroll_context = params.scroll_context
    self.widget_width = params.widget_width
    self.widget_height = params.widget_height
    self.row_padding = params.row_padding or 0
    self.num_visible_rows = params.num_visible_rows or 8

    self.item_widgets = {}
    self.items_data = {}
    self.scroll_offset = 0

    local total_height = self.num_visible_rows * (self.widget_height + self.row_padding)
    self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
    self.bg:ScaleToSize(self.widget_width, total_height)
    self.bg:SetTint(0, 0, 0, 0)  -- 完全透明

    for i = 1, self.num_visible_rows do
        local widget = self:AddChild(self.item_ctor_fn(self.scroll_context, i))
        local y_offset = (self.num_visible_rows / 2 - i + 0.5) * (self.widget_height + self.row_padding)
        widget:SetPosition(0, y_offset)
        table.insert(self.item_widgets, widget)
    end

    self:SetFocusChangeDir(MOVE_DOWN, nil)
    self:SetFocusChangeDir(MOVE_UP, nil)
end)

function MapTravelScrollList:SetItemsData(data)
    self.items_data = data or {}
    self.scroll_offset = 0
    self:RefreshView()
end

function MapTravelScrollList:RefreshView()
    for i, widget in ipairs(self.item_widgets) do
        local data_index = self.scroll_offset + i
        local data = self.items_data[data_index]

        if self.apply_fn then
            self.apply_fn(self.scroll_context, widget, data, data_index)
        end

        if data then
            widget:Show()
        else
            widget:Hide()
        end
    end
end

function MapTravelScrollList:OnControl(control, down)
    if Widget.OnControl(self, control, down) then
        return true
    end

    if down then
        if control == CONTROL_SCROLLBACK then
            self:Scroll(-1)
            return true
        elseif control == CONTROL_SCROLLFWD then
            self:Scroll(1)
            return true
        end
    end

    return false
end

function MapTravelScrollList:Scroll(delta)
    local max_offset = math.max(0, #self.items_data - self.num_visible_rows)
    self.scroll_offset = math.clamp(self.scroll_offset + delta, 0, max_offset)
    self:RefreshView()
end

return MapTravelScrollList
