local Text = require "widgets/text"
local Image = require "widgets/image"
local Widget = require "widgets/widget"

local ItemButtonTile = Class(Widget, function(self, category)
    Widget._ctor(self, "ItemButtonTile")

    local img = Categories[category].image or category:lower()

    self.imagedefault = img .. ".tex"
    self.default_atlas = GetInventoryItemAtlas(self.imagedefault)

    self.imagebg = self:AddChild(Image(self.default_atlas, self.imagedefault, "default.tex"))
    self.imagebg:SetTint(0,0,0,0.7)
    self.imagebg:SetClickable(false)
    self:SetScale(.75)
end)

function ItemButtonTile:SetImage(item)
    if item and item:IsValid() then
        if self._currentPrefab ~= item.prefab then
            self._currentPrefab = item.prefab
            self.imagebg:SetTint(1,1,1,1)
            self.imagebg:SetTexture(item.replica.inventoryitem:GetAtlas(), item.replica.inventoryitem:GetImage())
        end
    else
        if self._currentPrefab ~= nil then
            self._currentPrefab = nil
            self.imagebg:SetTint(0,0,0,0.7)
            self.imagebg:SetTexture(self.default_atlas, self.imagedefault)
        end
    end
end

return ItemButtonTile