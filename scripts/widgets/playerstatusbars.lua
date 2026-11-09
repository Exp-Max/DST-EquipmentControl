local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Text = require "widgets/text"
local PlayerUtil = require "util/playerutil"

local WHITE_ATLAS = "images/ui.xml"
local WHITE_TEX = "white.tex"

local BAR_W = 180
local OUTER_BORDER = 3
local FILL_W = BAR_W

local BG_COLOUR = { 19/255, 18/255, 18/255, 1 }
local BORDER_COLOUR = { 0, 0, 0, 1 }
local PENALTY_COLOUR = { 89/255, 89/255, 89/255, .8 }

local BAR_CONFIGS = {
    health      = { colour = { 179/255, 26/255, 0, 1 },           index = 0, height = 3 },
    sanity      = { colour = { 232/255, 122/255, 15/255, 1 },      index = 1, height = 3 },
    hunger      = { colour = { 242/255, 230/255, 153/255, 1 },     index = 2, height = 3 },
    shield      = { colour = { 51/255, 153/255, 1, 1 },            index = 3, height = 3 },
    wereness    = { colour = { 120/255, 72/255, 28/255, 1 },       index = 4, height = 3 },
    mightiness  = { colour = { 200/255, 40/255, 40/255, 1 },       index = 5, height = 3 },
    inspiration = { colour = { 240/255, 210/255, 50/255, 1 },      index = 6, height = 3 },
    abigail     = { colour = { 35/255, 152/255, 156/255, 1 },      index = 7, height = 3 },
}

local SANITY_NORMAL_TINT = { 232/255, 122/255, 15/255, 1 }
local SANITY_LUNACY_TINT  = { 191/255, 232/255, 240/255, 1 }

local function ShowStatPopup(value, size, pos, colour, font)
    if not ThePlayer or not ThePlayer.HUD or not ThePlayer.HUD.popupstats_root then
        return
    end
    local PopupNumber = require "widgets/popupnumber"
    local popup = ThePlayer.HUD.popupstats_root:AddChild(PopupNumber(
        ThePlayer, value, size, pos, 40, colour, false))
    if font then
        popup.text:SetFont(font)
    end
end

local function CreateBar(self, name, colour, height, row_y)
    local bar = {}
    bar._h = height

    bar.fill = self:AddChild(Image(WHITE_ATLAS, WHITE_TEX))
    bar.fill:SetPosition(0, row_y, 0)
    bar.fill:SetSize(1, height)
    bar.fill:SetTint(unpack(colour))
    bar.fill:SetHRegPoint(ANCHOR_LEFT)

    bar.penalty = self:AddChild(Image(WHITE_ATLAS, WHITE_TEX))
    bar.penalty:SetTint(unpack(PENALTY_COLOUR))
    bar.penalty:SetSize(1, height)
    bar.penalty:SetHRegPoint(ANCHOR_LEFT)
    bar.penalty:Hide()

    bar.label = self:AddChild(Text(CODEFONT, 9))
    bar.label:SetColour(1, 1, 1, 1)
    bar.label:SetHAlign(ANCHOR_MIDDLE)
    bar.label:SetPosition(BAR_W * 0.5, row_y - 1, 0)

    bar._y = row_y
    self.bars[name] = bar
    return bar
end

local PlayerStatusBars = Class(Widget, function(self, owner)
    Widget._ctor(self, "PlayerStatusBars")
    self.owner = owner
    self:UpdateWhilePaused(false)
    self:SetClickable(false)
    self:SetHAnchor(ANCHOR_LEFT)
    self:SetVAnchor(ANCHOR_BOTTOM)

    self.border = self:AddChild(Image(WHITE_ATLAS, WHITE_TEX))
    self.border:SetTint(unpack(BORDER_COLOUR))

    self.bg = self:AddChild(Image(WHITE_ATLAS, WHITE_TEX))
    self.bg:SetTint(unpack(BG_COLOUR))

    self.bars = {}
    self.fill_widths = {}
    self.visible = {}
    self.enabled = {}
    self._ghost = false

    for name, cfg in pairs(BAR_CONFIGS) do
        CreateBar(self, name, cfg.colour, cfg.height, -cfg.height)
        self.visible[name] = false
        self.fill_widths[name] = 0
        self.enabled[name] = false
    end

    self.enabled.health = true
    self.enabled.sanity = true
    self.enabled.hunger = true

    self:_InitEvents()
    self:Relayout()
    self:StartUpdating()

    self.owner:DoTaskInTime(0, function()
        if self.owner == nil or self.owner.IsValid == nil then return end
        if not self.owner:IsValid() then return end
        self:_OnHealthDirty()
        self:_OnHungerDirty()
        self:_OnSanityDirty()
        self:_RefreshShield()
        self:_OnAbigailInit()
    end)
end)

function PlayerStatusBars:_InitEvents()
    PlayerUtil:On("healthdelta", function() self:_OnHealthDirty() end)
    PlayerUtil:On("hungerdelta", function() self:_OnHungerDirty() end)
    PlayerUtil:On("sanitydelta", function() self:_OnSanityDirty() end)
    PlayerUtil:On("shielddelta", function() self:_RefreshShield() end)
    PlayerUtil:On("werenessdelta", function(data) self:_OnWerenessDelta(data) end)
    PlayerUtil:On("mightinessdelta", function(data) self:_OnMightinessDelta(data) end)
    PlayerUtil:On("inspirationdelta", function(data) self:_OnInspirationDelta(data) end)
    PlayerUtil:On("clientpethealthdirty", function(data) self:_OnAbigailHealthDirty(data) end)
    PlayerUtil:On("clientpetmaxhealthdirty", function(data) self:_OnAbigailMaxHealthDirty(data) end)
    PlayerUtil:On("ms_becameghost", function() self:_OnBecameGhost() end)
    PlayerUtil:On("ms_respawnedfromghost", function() self:_OnRespawned() end)
    PlayerUtil:On("finishseamlessplayerswap", function()
        self.owner = ThePlayer
        self._ghost = false
        self:_OnRespawned()
    end)
end

function PlayerStatusBars:_OnHealthDirty()
    if self._ghost then return end
    local current = PlayerUtil:GetHealth()
    local max = PlayerUtil:GetMaxHealth()
    if current ~= self._last_health or max ~= self._last_max_health then
        self._last_health = current
        self._last_max_health = max
        self:SetBarValue("health", current, max)
    end
    self:SetPenalty("health", PlayerUtil:GetHealthPenaltyPct())
    self:_StatPopup("health", current, 3.0,
        {1, 80/255, 40/255, 1}, {80/255, 1, 80/255, 1})
end

function PlayerStatusBars:_OnHungerDirty()
    if self._ghost then return end
    local current = PlayerUtil:GetHunger()
    local max = PlayerUtil:GetMaxHunger()
    if current ~= self._last_hunger or max ~= self._last_max_hunger then
        self._last_hunger = current
        self._last_max_hunger = max
        self:SetBarValue("hunger", current, max)
    end
    self:_StatPopup("hunger", current, 2.6,
        {1, 180/255, 80/255, 1}, {200/255, 1, 100/255, 1})
end

function PlayerStatusBars:_OnSanityDirty()
    if self._ghost then return end
    local current = PlayerUtil:GetSanity()
    local max = PlayerUtil:GetMaxSanity()
    if current ~= self._last_sanity or max ~= self._last_max_sanity then
        self._last_sanity = current
        self._last_max_sanity = max
        self:SetBarValue("sanity", current, max)
    end
    self:SetPenalty("sanity", PlayerUtil:GetSanityPenaltyPct())
    self:SetSanityTint(PlayerUtil:IsSanityLunacy())
    self:_StatPopup("sanity", current, 2.8,
        {180/255, 100/255, 1, 1}, {100/255, 1, 1, 1})
end

function PlayerStatusBars:_StatPopup(name, current, offset, colour_down, colour_up)
    local prev_key = "_prev_" .. name
    if self[prev_key] and current ~= self[prev_key] then
        local delta = current - self[prev_key]
        if self.owner and self.owner:IsValid() and self.owner.Transform then
            local px, py, pz = self.owner.Transform:GetWorldPosition()
            if py then
                ShowStatPopup(math.abs(delta), 36, Vector3(px, py + offset, pz),
                    delta < 0 and colour_down or colour_up)
            end
        end
    end
    self[prev_key] = current
end

function PlayerStatusBars:_RefreshShield()
    if self._ghost then return end
    local current = PlayerUtil:GetShield()
    local max = PlayerUtil:GetMaxShield()
    if max > 0 then
        self:SetBarValue("shield", current, max)
    else
        self:SetBarValue("shield", 0, 0)
    end
end

function PlayerStatusBars:_OnWerenessDelta(data)
    if self._ghost then return end
    local pct = (data and data.newpercent) or PlayerUtil:GetWereness() or 0
    local display_val = math.floor(pct * 100)
    if display_val ~= self._last_wereness then
        self._last_wereness = display_val
        self:SetBarValue("wereness", pct * 100, 100)
    end
end

function PlayerStatusBars:_OnMightinessDelta(data)
    if self._ghost then return end
    local pct = (data and data.newpercent) or PlayerUtil:GetMightiness() or 0
    local display_val = math.floor(pct * 100)
    if display_val ~= self._last_mightiness then
        self._last_mightiness = display_val
        self:SetBarValue("mightiness", pct * 100, 100)
    end
end

function PlayerStatusBars:_OnInspirationDelta(data)
    if self._ghost then return end
    local pct = (data and data.newpercent) or PlayerUtil:GetInspiration() or 0
    local display_val = math.floor(pct * 100)
    if display_val ~= self._last_inspiration then
        self._last_inspiration = display_val
        self:SetBarValue("inspiration", pct * 100, 100)
    end
end

function PlayerStatusBars:_OnAbigailInit()
    if self._ghost then return end
    if PlayerUtil:HasPet() then
        local max = PlayerUtil:GetPetMaxHealth()
        local pct = PlayerUtil:GetPetHealthPct()
        if max > 0 then
            self:SetBarValue("abigail", pct * max, max)
        end
    else
        self.enabled.abigail = false
        self:Relayout()
    end
end

function PlayerStatusBars:_OnAbigailHealthDirty(data)
    if self._ghost then return end
    if not PlayerUtil:HasPet() then
        self.enabled.abigail = false
        self:Relayout()
        return
    end
    local max = PlayerUtil:GetPetMaxHealth()
    local pct = data and data.percent or PlayerUtil:GetPetHealthPct()
    if max > 0 then
        self:SetBarValue("abigail", pct * max, max)
    end
end

function PlayerStatusBars:_OnAbigailMaxHealthDirty(data)
    if self._ghost then return end
    if not PlayerUtil:HasPet() then return end
    local max = data and data.max or PlayerUtil:GetPetMaxHealth()
    local pct = PlayerUtil:GetPetHealthPct()
    if max > 0 then
        self:SetBarValue("abigail", pct * max, max)
    end
end

function PlayerStatusBars:_OnBecameGhost()
    self._ghost = true
    self:SetAllVisible(false)
    self._prev_health = nil
    self._prev_hunger = nil
    self._prev_sanity = nil
    self._last_health = nil
    self._last_max_health = nil
    self._last_hunger = nil
    self._last_max_hunger = nil
    self._last_sanity = nil
    self._last_max_sanity = nil
    self._last_wereness = nil
    self._last_mightiness = nil
    self._last_inspiration = nil
end

function PlayerStatusBars:_OnRespawned()
    self._ghost = false
    self:SetAllVisible(true)
    self:_OnHealthDirty()
    self:_OnHungerDirty()
    self:_OnSanityDirty()
    self:_RefreshShield()
    self:_OnAbigailInit()
    self:_OnWerenessDelta(nil)
    self:_OnMightinessDelta(nil)
    self:_OnInspirationDelta(nil)
end

function PlayerStatusBars:Relayout()
    local active = {}
    for name, cfg in pairs(BAR_CONFIGS) do
        if self.enabled[name] then
            active[#active + 1] = { name = name, index = cfg.index, height = cfg.height }
        end
    end
    table.sort(active, function(a, b) return a.index < b.index end)

    local count = #active
    if count == 0 then return end

    local total_h = 0
    for _, entry in ipairs(active) do
        total_h = total_h + entry.height
    end
    local center_y = -total_h * 0.5

    self.border:SetSize(BAR_W + OUTER_BORDER * 2, total_h + OUTER_BORDER * 2)
    self.border:SetPosition(BAR_W * 0.5, center_y, 0)
    self.bg:SetSize(BAR_W, total_h)
    self.bg:SetPosition(BAR_W * 0.5, center_y, 0)

    local y_offset = 0
    for _, entry in ipairs(active) do
        local bar = self.bars[entry.name]
        if bar then
            local row_y = y_offset - entry.height * 0.5
            bar._y = row_y
            bar._h = entry.height
            local fill_w = bar.fill:GetSize()
            bar.fill:SetSize(fill_w, entry.height)
            local pen_w = bar.penalty:GetSize()
            bar.penalty:SetSize(pen_w, entry.height)
            bar.fill:SetPosition(0, row_y, 0)
            bar.label:SetPosition(BAR_W * 0.5, row_y - 1, 0)
            y_offset = y_offset - entry.height
        end
    end

    for name in pairs(BAR_CONFIGS) do
        if not self.enabled[name] then
            local bar = self.bars[name]
            if bar then
                bar.fill:Hide()
                bar.penalty:Hide()
                bar.label:Hide()
                self.visible[name] = false
                self.fill_widths[name] = 0
            end
        end
    end
end

function PlayerStatusBars:OnUpdate(dt)
    self._tick = (self._tick or 0) + 1
    if self._tick < 2 then return end
    self._tick = 0

    if not self.owner:IsValid() then return end
    local x, y = TheSim:GetScreenPos(self.owner.Transform:GetWorldPosition())
    self:SetPosition(x - (BAR_W * 0.5 + OUTER_BORDER), y + 100, 0)
end

function PlayerStatusBars:SetBarValue(name, current, max_value)
    local bar = self.bars[name]
    if not bar then return end

    if max_value > 0 and not self.enabled[name] then
        self.enabled[name] = true
        self:Relayout()
    end

    if current > 0 and max_value > 0 then
        local fill_px = FILL_W * current / max_value
        self.fill_widths[name] = fill_px
        bar.fill:SetSize(fill_px, bar._h)
        bar.fill:Show()
        bar.label:SetString(string.format("%d / %d", math.floor(current), max_value))
        bar.label:Show()
        self.visible[name] = true
    else
        self.fill_widths[name] = 0
        bar.fill:Hide()
        bar.label:Hide()
        self.visible[name] = false
    end
end

function PlayerStatusBars:SetPenalty(name, penalty_pct)
    local bar = self.bars[name]
    if not bar then return end

    if penalty_pct and penalty_pct > 0 and self.visible[name] then
        local penalty_px = FILL_W * penalty_pct
        local fill_w = self.fill_widths[name] or 0
        bar.penalty:SetPosition(fill_w, bar._y, 0)
        bar.penalty:SetSize(penalty_px, bar._h)
        bar.penalty:Show()
    else
        bar.penalty:Hide()
    end
end

function PlayerStatusBars:SetSanityTint(is_lunacy)
    local bar = self.bars.sanity
    if not bar then return end
    if is_lunacy then
        bar.fill:SetTint(unpack(SANITY_LUNACY_TINT))
    else
        bar.fill:SetTint(unpack(SANITY_NORMAL_TINT))
    end
end

function PlayerStatusBars:SetAllVisible(visible)
    if visible then
        self.border:Show()
        self.bg:Show()
    else
        self.border:Hide()
        self.bg:Hide()
    end
    for name, bar in pairs(self.bars) do
        if visible then
            if self.visible[name] then
                bar.fill:Show()
                bar.label:Show()
            end
        else
            bar.fill:Hide()
            bar.label:Hide()
            bar.penalty:Hide()
        end
    end
end

return PlayerStatusBars