local InventoryUtil = require "util/inventoryutil"

local CraftUtil = {}

local function IsBuilding(animState)
    return animState:IsCurrentAnimation("build_pre")
        or animState:IsCurrentAnimation("build_loop")
end

function CraftUtil:IsCrafting()
    local animState = ThePlayer and ThePlayer.AnimState

    if not animState then
        return false
    end

    return IsBuilding(animState)
end

local function GetBuilder()
    return ThePlayer
       and ThePlayer.replica.builder
end

function CraftUtil:CanCraft(recipename)
    local builder = GetBuilder()
    return builder
       and builder:HasIngredients(GetValidRecipe(recipename))
end

function CraftUtil:KnowsRecipe(recipename)
    local builder = GetBuilder()
    return builder
       and builder:KnowsRecipe(recipename)
end

function CraftUtil:Craft(recipe, skin)
    recipe = GetValidRecipe(recipe)

    if not recipe then
        return
    end

    local builder = GetBuilder()
    if builder and not builder:IsBusy() then
        builder:MakeRecipeFromMenu(recipe, skin)
    end
end

return CraftUtil
