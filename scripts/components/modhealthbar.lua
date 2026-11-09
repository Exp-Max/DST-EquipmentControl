local function CreateBarEntity(self, name, colour, world_offset)
    local bg = CreateEntity(name .. "BarBG")
    --[[Non-networked entity]]
    bg.entity:AddTransform()
    bg.entity:AddImage()
    bg:AddTag("CLASSIFIED")
    bg:AddTag("NOCLICK")
    bg.Image:SetTexture(resolvefilepath(self.bar_atlas), self.bar_image)
    bg.Image:SetTint(unpack(self.bg_colour))
    bg.Image:SetWorldOffset(world_offset:Get())
    bg.Image:SetUIOffset(self.bar_ui_offset:Get())
    bg.Image:SetSize(self.bar_width, self.bar_height)
    bg.Image:Enable(false)
    bg.persists = false
    bg.entity:SetParent(self.inst.entity)

    local bar = CreateEntity(name .. "Bar")
    --[[Non-networked entity]]
    bar.entity:AddTransform()
    bar.entity:AddImage()
    bar.entity:AddLabel()
    bar:AddTag("CLASSIFIED")
    bar:AddTag("NOCLICK")
    bar.Image:SetTexture(resolvefilepath(self.bar_atlas), self.bar_image)
    bar.Image:SetTint(unpack(colour))
    bar.Image:SetWorldOffset(world_offset:Get())
    bar.Image:Enable(false)
    bar.Label:SetFontSize(9)
    bar.Label:SetFont(CODEFONT)
    bar.Label:SetColour(1, 1, 1)
    bar.Label:SetWorldOffset(world_offset:Get())
    bar.Label:SetUIOffset(self.label_ui_offset:Get())
    bar.Label:Enable(false)
    bar.fill_width = self.bar_width - self.bar_border * 2
    bar.fill_height = self.bar_height - self.bar_border * 2
    bar.persists = false
    bar.entity:SetParent(self.inst.entity)

    local penalty = CreateEntity(name .. "PenaltyBar")
    --[[Non-networked entity]]
    penalty.entity:AddTransform()
    penalty.entity:AddImage()
    penalty:AddTag("CLASSIFIED")
    penalty:AddTag("NOCLICK")
    penalty.Image:SetTexture(resolvefilepath(self.bar_atlas), self.bar_image)
    penalty.Image:SetTint(.35, .35, .35, .8)
    penalty.Image:SetWorldOffset(world_offset:Get())
    penalty.Image:SetSize(0, self.bar_height)
    penalty.Image:Enable(false)
    penalty.persists = false
    penalty.entity:SetParent(self.inst.entity)

    return { bg = bg, bar = bar, penalty = penalty, world_offset = world_offset }
end

local function SetBarVisible(bar_data, visible)
    if bar_data.bar then
        bar_data.bar.Label:Enable(visible)
        bar_data.bar.Image:Enable(visible)
    end
    if bar_data.penalty then
        bar_data.penalty.Image:Enable(visible)
    end
    if bar_data.bg then
        bar_data.bg.Image:Enable(visible)
    end
end

local function SetPenaltyOverlay(bar_data, self, penalty_pct)
    local penalty = bar_data.penalty
    if not penalty then return end
    local bar = bar_data.bar
    if penalty_pct > 0 then
        local penalty_width = bar.fill_width * penalty_pct
        penalty.Image:SetSize(penalty_width, bar.fill_height)
        penalty.Image:SetUIOffset(
            self.bar_ui_offset.x + (bar.fill_width - penalty_width) * .5,
            self.bar_ui_offset.y,
            self.bar_ui_offset.z)
        penalty.Image:Enable(true)
    else
        penalty.Image:Enable(false)
    end
end

local function SetBarValue(bar_data, self, percent, current, maxValue)
    if percent > 0 then
        local newwidth = bar_data.bar.fill_width * percent
        bar_data.bar.Label:SetText(math.floor(current) .. " / " .. maxValue)
        bar_data.bar.Image:SetSize(newwidth, bar_data.bar.fill_height)
        bar_data.bar.Image:SetUIOffset(
            self.bar_ui_offset.x + (newwidth - bar_data.bar.fill_width) * .5,
            self.bar_ui_offset.y,
            self.bar_ui_offset.z)
        SetBarVisible(bar_data, self.enabled)
    else
        SetBarVisible(bar_data, false)
    end
end

local HealthBar = Class(function(self, inst)
    self.inst = inst

    self.maxhealth = 0
    self.maxhunger = 0
    self.maxsanity = 0

    self.bar_atlas = "images/hud.xml"
    self.bar_image = "stat_bar.tex"

    self.bar_width  = 250
    self.bar_height = 9
    self.bar_border = 3
    self.bg_colour = { .075, .07, .07, 1 }

    self.bar_ui_offset   = Vector3(0, 0, 0)
    self.label_ui_offset = Vector3(0, 0, 0)

    self.enabled = true

    self.bars = {
        shield = CreateBarEntity(self, "Shield", { .2, .6, 1, 1 }, Vector3(0, 3.4, 0)),
        health = CreateBarEntity(self, "Health", { .7, .1, 0, 1 }, Vector3(0, 3.0, 0)),
        hunger = CreateBarEntity(self, "Hunger", { .95, .9, .6, 1 }, Vector3(0, 2.6, 0)),
        sanity = CreateBarEntity(self, "Sanity", { 232/255, 123/255, 15/255, 1 }, Vector3(0, 2.8, 0)),
    }

    self.sanity_tint_sanity = { 232/255, 123/255, 15/255, 1 }
    self.sanity_tint_lunacy = { 191/255, 232/255, 240/255, 1 }

    -- 向后兼容 NPC 血量条
    self.bg = self.bars.health.bg
    self.bar = self.bars.health.bar
end)

function HealthBar:SetPosition(pos1)
    for _, bar_data in pairs(self.bars) do
        bar_data.bar.Image:SetWorldOffset(pos1:Get())
        bar_data.bar.Label:SetWorldOffset(pos1:Get())
        bar_data.bg.Image:SetWorldOffset(pos1:Get())
        if bar_data.penalty then
            bar_data.penalty.Image:SetWorldOffset(pos1:Get())
        end
    end
end

-- 向后兼容 NPC 血量条
function HealthBar:SetMaxHealth(maxhealth)
    self.maxhealth = maxhealth
end

function HealthBar:GetMaxHealth()
    return self.maxhealth
end

-- NPC 血量条（damage: 累计伤害）
function HealthBar:SetValue(percent, damage, maxHealth)
    SetBarValue(self.bars.health, self, percent, maxHealth - damage, maxHealth)
end

-- 玩家血量条（current: 当前血量）
function HealthBar:SetHealthValue(percent, current, maxHealth)
    self.maxhealth = maxHealth
    SetBarValue(self.bars.health, self, percent, current, maxHealth)
end

-- 血量惩罚（penalty: 0-1 的惩罚比例）
function HealthBar:SetHealthPenalty(penalty)
    SetPenaltyOverlay(self.bars.health, self, penalty)
end

-- 玩家饥饿度条
function HealthBar:SetHungerValue(percent, current, maxHunger)
    self.maxhunger = maxHunger
    SetBarValue(self.bars.hunger, self, percent, current, maxHunger)
end

-- 玩家理智值条
function HealthBar:SetSanityValue(percent, current, maxSanity)
    self.maxsanity = maxSanity
    SetBarValue(self.bars.sanity, self, percent, current, maxSanity)
end

-- 理智惩罚（penalty: 0-1 的惩罚比例）
function HealthBar:SetSanityPenalty(penalty)
    SetPenaltyOverlay(self.bars.sanity, self, penalty)
end

-- 理智启蒙状态颜色适配
function HealthBar:SetSanityTint(isLunacy)
    local tint = isLunacy and self.sanity_tint_lunacy or self.sanity_tint_sanity
    self.bars.sanity.bar.Image:SetTint(unpack(tint))
end

-- 机器人护盾条（WX-78）
function HealthBar:SetShieldValue(percent, current, maxShield)
    self.maxshield = maxShield
    if maxShield > 1 then
        SetBarValue(self.bars.shield, self, percent, current, maxShield)
    else
        SetBarVisible(self.bars.shield, false)
    end
end

function HealthBar:SetAllVisible(visible)
    self.enabled = visible
    for k, bar_data in pairs(self.bars) do
        if k ~= "shield" then
            SetBarVisible(bar_data, visible)
        end
    end
end

return HealthBar