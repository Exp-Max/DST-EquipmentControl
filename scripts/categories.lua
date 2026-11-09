local ItemUtil = require "util/itemutil"
local SpecialFood = MOD_EQUIPMENT_CONTROL.SPECIALFOOD

local Category = Class(function(self, image, autoequip, imagepath)
    self._rawFn = function()
        return false
    end
    self._rawPriority = function()
        return 0
    end
    self.fn = function(item, ...)
        if not item then
            return false
        end
        return self._rawFn(item, ...)
    end
    self.priority = function(item, ...)
        if not item then
            return 0
        end
        return self._rawPriority(item, ...)
    end
    self.image = image or nil
    self.imagepath = imagepath
    self.autoequip = autoequip
end)

function Category:SetFn(fn)
    self._rawFn = fn
end

function Category:SetPriority(fn)
    self._rawPriority = fn
end

Categories = {
    TOOLS       = Category("axe_victorian"),              -- 工具 (TOOLS)
    LIGHT       = Category("lantern_tesla"),              -- 光源 (LIGHT)
    WEAPONS     = Category("ruins_bat_heavy", true),      -- 武器 (WEAPONS)
    ARMOUR      = Category("footballhat_hockey", true),   -- 盔甲 (ARMOUR)
    CLOTHING    = Category("armor_ruins_bulky"),          -- 服装 (CLOTHING)
    RESTORATION = Category("lifeinjector"),               -- 恢复 (RESTORATION)
    MAGIC       = Category("firestaff_lance"),            -- 魔法 (MAGIC)
    CONTAINER   = Category("backpack"),                   -- 容器 (CONTAINER)
}

Categories.CANE         = Category("cane_sharp")               -- 步行手杖
Categories.AXE          = Category("axe_victorian")            -- 华丽斧
Categories.PICKAXE      = Category("pickaxe_victorian")        -- 华丽鹤嘴锄
Categories.SHOVEL       = Category("shovel_victorian")         -- 华丽铲子
Categories.HAMMER       = Category("hammer_hammush")           -- 蘑菇锤
Categories.BUGNET       = Category("bugnet_garden")            -- 抓人捕虫网
Categories.SCYTHE       = Category("voidcloth_scythe")         -- 虚空布镰刀
Categories.HOE          = Category("farm_hoe")                 -- 园艺锄
Categories.PITCHFORK    = Category("pitchfork")                -- 干草叉
Categories.OAR          = Category("oar_swamp")                -- 鱼桨
Categories.FISHINGROD   = Category("fishingrod")               -- 鱼竿
Categories.WATERINGCAN  = Category("wateringcan")              -- 浇水壶
Categories.BRUSH        = Category("brush")                    -- 刷子
Categories.GESTALT_CAGE = Category("gestalt_cage")             -- 幻灵捕获器
Categories.ARMORHAT     = Category("footballhat_hockey")       -- 曲棍球头盔
Categories.ARMORBODY    = Category("armor_wood_roman")         -- 罗马木甲
Categories.CLOTHINGHAT  = Category("tophat_chef")              -- 主厨帽
Categories.CLOTHINGBODY = Category("trunkvest_winter")         -- 松软背心
Categories.BACKPACK     = Category("backpack_dragonfly_fire")  -- 烈焰背包
Categories.FOOD         = Category("bonestew")                 -- 大肉汤
Categories.HEALING      = Category("lifeinjector")             -- 强心针
Categories.STAFF        = Category("firestaff_lance")          -- 火焰螺旋魔杖
Categories.AMULET       = Category("amulet_red_relic")         -- 重游护符

-- ==========================================
-- 工具 (TOOLS) - 通过tag/组件筛选
-- ==========================================
Categories.TOOLS:SetFn(function(item)
    return ItemUtil:IsTool(item)
end)

Categories.TOOLS:SetPriority(function(item)
    if ItemUtil:IsCane(item) then
        return ItemUtil:GetWalkspeedMult(item) * 100
    end
    return ItemUtil:GetUses(item)
end)

Categories.CANE:SetFn(function(item) return ItemUtil:IsCane(item) end)
Categories.CANE:SetPriority(function(item) return ItemUtil:GetWalkspeedMult(item) * 100 end)

Categories.AXE:SetFn(function(item) return ItemUtil:IsAxe(item) end)
Categories.AXE:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.PICKAXE:SetFn(function(item) return ItemUtil:IsPickaxe(item) end)
Categories.PICKAXE:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.SHOVEL:SetFn(function(item) return ItemUtil:IsShovel(item) end)
Categories.SHOVEL:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.HAMMER:SetFn(function(item) return ItemUtil:IsHammer(item) end)
Categories.HAMMER:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.PITCHFORK:SetFn(function(item) return ItemUtil:IsPitchfork(item) end)
Categories.PITCHFORK:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.BUGNET:SetFn(function(item) return ItemUtil:IsBugnet(item) end)
Categories.BUGNET:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.SCYTHE:SetFn(function(item) return ItemUtil:IsScythe(item) end)
Categories.SCYTHE:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.HOE:SetFn(function(item) return ItemUtil:IsHoe(item) end)
Categories.HOE:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.OAR:SetFn(function(item) return ItemUtil:IsOar(item) end)
Categories.OAR:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.FISHINGROD:SetFn(function(item) return ItemUtil:IsFishingrod(item) end)
Categories.FISHINGROD:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.WATERINGCAN:SetFn(function(item) return ItemUtil:IsWateringcan(item) end)
Categories.WATERINGCAN:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.BRUSH:SetFn(function(item) return ItemUtil:IsBrush(item) end)
Categories.BRUSH:SetPriority(function(item) return ItemUtil:GetUses(item) end)

Categories.GESTALT_CAGE:SetFn(function(item) return ItemUtil:IsGestaltCage(item) end)
Categories.GESTALT_CAGE:SetPriority(function(item) return ItemUtil:GetUses(item) end)

local function InsulationPriority(item)
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.insulator then
        return cached.insulator.insulation or 0
    end
    return 0
end
-- ==========================================
-- 光源 (LIGHT) - 通过组件筛选光源物品
-- ==========================================
Categories.LIGHT:SetFn(function(item)
    return ItemUtil:IsLightSource(item)
end)

Categories.LIGHT:SetPriority(function(item)
    return ItemUtil:GetMaxFuel(item)
end)

-- ==========================================
-- 武器 (WEAPONS) - 近战、远程
-- ==========================================
Categories.WEAPONS:SetFn(function(item)
    return ItemUtil:IsMeleeWeapon(item)
        or ItemUtil:IsRangedWeapon(item)
end)

Categories.WEAPONS:SetPriority(function(item, target)
    return ItemUtil:GetDamage(item, target)
end)

-- ==========================================
-- 盔甲 (ARMOUR) - 头部护甲 + 身体护甲
-- ==========================================
Categories.ARMOUR:SetFn(function(item)
    return ItemUtil:IsArmor(item)
end)
Categories.ARMOUR:SetPriority(function(item) return ItemUtil:GetArmor(item) end)

Categories.ARMORHAT:SetFn(function(item) return ItemUtil:IsArmorHat(item) end)
Categories.ARMORHAT:SetPriority(function(item) return ItemUtil:GetArmor(item) end)

Categories.ARMORBODY:SetFn(function(item) return ItemUtil:IsArmorBody(item) end)
Categories.ARMORBODY:SetPriority(function(item) return ItemUtil:GetArmor(item) end)

-- ==========================================
-- 服装 (CLOTHING) - 头部衣物 + 身体衣物
-- ==========================================
Categories.CLOTHING:SetFn(function(item)
    return ItemUtil:IsCloth(item)
end)
Categories.CLOTHING:SetPriority(InsulationPriority)

Categories.CLOTHINGHAT:SetFn(function(item) return ItemUtil:IsClothingHat(item) end)
Categories.CLOTHINGHAT:SetPriority(InsulationPriority)

Categories.CLOTHINGBODY:SetFn(function(item) return ItemUtil:IsClothingBody(item) end)
Categories.CLOTHINGBODY:SetPriority(InsulationPriority)

-- ==========================================
-- 恢复 (RESTORATION) - 治疗物品
-- ==========================================
Categories.RESTORATION:SetFn(function(item)
    return ItemUtil:IsHealingItem(item)
end)

Categories.RESTORATION:SetPriority(function(item)
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.healer then
        return cached.healer.health or 0
    end
    return 0
end)

Categories.HEALING:SetFn(function(item)
    return ItemUtil:IsHealingItem(item)
end)

Categories.HEALING:SetPriority(function(item)
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.healer then
        return cached.healer.health or 0
    end
    return 0
end)

-- ==========================================
-- 魔法 (MAGIC) - 法杖 + 护符
-- ==========================================
Categories.MAGIC:SetFn(function(item)
    return ItemUtil:IsStaff(item)
        or ItemUtil:IsAmulet(item)
end)

Categories.MAGIC:SetPriority(function(item)
    return ItemUtil:GetFiniteUses(item)
end)

Categories.STAFF:SetFn(function(item) return ItemUtil:IsStaff(item) end)
Categories.STAFF:SetPriority(function(item)
    return ItemUtil:GetFiniteUses(item)
end)

Categories.AMULET:SetFn(function(item) return ItemUtil:IsAmulet(item) end)
Categories.AMULET:SetPriority(function(item)
    return ItemUtil:GetFiniteUses(item)
end)

-- ==========================================
-- 容器 (CONTAINER) - 背包
-- ==========================================
Categories.CONTAINER:SetFn(function(item) return ItemUtil:IsBackpack(item) end)
Categories.CONTAINER:SetPriority(function(item)
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.container then
        return cached.container.numslots or 0
    end
    return 0
end)

Categories.BACKPACK:SetFn(function(item) return ItemUtil:IsBackpack(item) end)
Categories.BACKPACK:SetPriority(function(item)
    local cached = ItemUtil:GetCachedItem(item)
    if cached and cached.container then
        return cached.container.numslots or 0
    end
    return 0
end)

-- ==========================================
-- 食物 (FOOD) - 杂类
-- ==========================================
Categories.FOOD:SetFn(function(item)
    return not SpecialFood[item.prefab]
        and ItemUtil:CanEat(item)
        and (ItemUtil:GetHunger(item) > 0
        and ItemUtil:GetHealth(item) >= 0
        or (item:HasTag("monstermeat") and ThePlayer
            and (ThePlayer.prefab == "webber" or ThePlayer.prefab == "wormwood")))
end)

Categories.FOOD:SetPriority(function(item)
    local hunger = ItemUtil:GetHunger(item)
    if item:HasTag("soul") and ThePlayer:HasTag("souleater") then
        hunger = TUNING.CALORIES_MEDSMALL
    end
    return hunger + ItemUtil:GetHealth(item)
end)