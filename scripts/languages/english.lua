-- Equipment Control Language File - English
GLOBAL.STRINGS.EQUIPMENT_CONTROL =
{
    SECTIONS =
    {
        KEYBINDS       = "Keybinds",
        TOGGLES        = "Toggles",
        BUTTONS        = "Quick Buttons",
        PREFERENCES    = "Preferences",
        AUTOMATION     = "Automation",
        QUICK_ACTIONS  = "Quick Actions",
        PICKUP         = "Pickup",
        TELEPOOF       = "Telepoof",
        MOUSE_THROUGH  = "Mouse Through",
        SORT           = "Sort",
        MISC           = "Misc",
    },

    CONFIG =
    {
        TOOLS                       = "Tools",
        LIGHT                       = "Light",
        WAR                         = "Weapons",
        ARMOR                       = "Armor",
        DRESS                       = "Clothing",
        SURVIVAL                    = "Survival",
        MAGIC                       = "Magic",
        DROPKEY                     = "Drop Lantern",
        MEAT_PRIORITIZATION_MODE    = "Meat Priority Mode",
        CONFIRM_TO_EAT              = "Confirm to Eat",
        PICKUP_FILTER_KEY           = "Pickup Filter",
        ATTACK_FILTER_KEY           = "Attack Filter",
        SORT_INVENTORY_KEY          = "Sort Inventory",
        SORT_CHEST_KEY              = "Sort Chest",

        TOGGLE_TELEPOOF             = "Toggle Telepoof",
        TOGGLE_SORTING_CONTAINER    = "Toggle Sort Container",

        QUICK_ACTION_BEEFALO        = "Shave Beefalo",
        QUICK_ACTION_KLAUS_SACK     = "Open Klaus Sack",
        QUICK_ACTION_REPAIR_BOAT    = "Repair Boat",
        QUICK_ACTION_BUILD_FOSSIL   = "Build Fossil",
        QUICK_ACTION_ATRIUM_GATE    = "Insert Ancient Key",
        QUICK_ACTION_DIRTPILE       = "Track Animals",
        QUICK_ACTION_FEED_BIRD      = "Feed Bird",
        QUICK_ACTION_WAKEUP_BIRD    = "Wake Bird",
        QUICK_ACTION_IMPRISON_BIRD  = "Imprison Bird",
        QUICK_ACTION_BOTTLESSOUL    = "Bottle Soul",
        QUICK_ACTION_DEVOURER       = "Feed Devourer",
        QUICK_ACTION_EXTINGUISH     = "Extinguish",
        QUICK_ACTION_QUICK_DEPLOY   = "Quick Deploy",
        QUICK_ACTION_MEDAL_POLLUTE         = "Pollute Medal",
        QUICK_ACTION_MEDAL_PLANT_MANDRAKE  = "Plant Mandrake",
        QUICK_ACTION_MEDAL_BURY_GREENGEM   = "Bury Green Gem",
        QUICK_ACTION_MEDAL_TREE_LEVEL_UP   = "Graft Tree Level Up",
        QUICK_ACTION_MEDAL_WORMWOOD_FLOWER = "Wormwood Flower",
        QUICK_ACTION_MEDAL_MAKE_COOLDOWN   = "Force Cooldown",
        QUICK_ACTION_MEDAL_GRINDING        = "Grinding",
        QUICK_ACTION_MEDAL_CHEFFLAVOUR     = "Chef Flavour",
        QUICK_ACTION_MEDAL_EAT_SPICES      = "Eat Spices",
        QUICK_ACTION_MEDAL_SOUL_ABSORB     = "Absorb Dark Soul",
        QUICK_ACTION_MEDAL_SOUL_AUTO       = "Dark Soul Auto",

        PRIOTIZE_VALUABLE_ITEMS     = "Prioritize Valuables",
        IGNORE_KNOWN_BLUEPRINT      = "Ignore Known Blueprints",
        PICKUP_IGNORE_FERNS         = "Ignore Ferns",
        PICKUP_IGNORE_SUCCULENTS    = "Ignore Succulents",
        PICKUP_IGNORE_MARSH_BUSH    = "Ignore Marsh Bush",

        TELEPOOF_DISABLED           = "Disabled by Default",
        TELEPOOF_HOVER              = "Hide Hover Hint",
        TELEPOOF_DOUBLECLICK        = "Double-Click Speed",
        TELEPOOF_WORTOX             = "Double-Click Soul Hop",

        FORCE_INSPECT_PLAYERS       = "Force Inspect Players",
        FLYING_BIRDS_MOUSETHROUGH   = "Flying Birds Unclickable",
        YELLOWSTAFF_MOUSETHROUGH    = "Star Caller Staff",
        ORANGESTAFF_MOUSETHROUGH    = "Lazy Explorer",

        CONTAINER_SORT              = "Sort Container",
        ARMOR_SORT_PRIORITY         = "Armor Priority",
        LIGHT_SORT_PRIORITY         = "Light Priority",
        STAFF_SORT_PRIORITY         = "Staff Priority",
        EQUIPMENT_SORT_PRIORITY     = "Equipment Priority",
        FOOD_SORT_PRIORITY          = "Food Priority",
        RESOURCE_SORT_PRIORITY      = "Resource Priority",
        TOOL_SORT_PRIORITY          = "Tool Priority",
        OVERRIDE_SLOT1_SORT         = "Keep in Slot 1",

        DAMAGE_ESTIMATION           = "Damage Estimation",

        -- Boulder Dodge
        BOULDER_DODGE           = "Boulder Dodge",
        DODGE_MARGIN            = "Dodge Margin",
        DODGE_MANUAL_OVERRIDE   = "Manual Override",
        DODGE_USE_CANE          = "Auto-Equip Cane",
        DODGE_CHOPS_OVERRIDE    = "Chops to Fell (0=Auto)",
        DODGE_AUTO              = "Auto",
    },

    HOVERS =
    {
        KEYBIND                 = "Assign key",
        TOGGLE                  = "Assign key",
        DEFAULT                 = "Set according to preference",
        BETA                    = "Experimental feature - use at your own risk!",
        TELEPOOF_DISABLED_HOVER = "Telepoof is disabled on game start",
        TELEPOOF_HOVER_HIDE     = "Hide hover hint when telepoof is disabled",
        FORCE_INSPECT           = "Hold force inspect key to interact with players",
        FLYING_BIRDS            = "Flying birds cannot be clicked",
        YELLOWSTAFF             = "Allow you to summon stars closer",
        ORANGESTAFF             = "Allow you to teleport through walls",
        AUTO_RE_EQUIP_SAME      = "Auto re-equip the same weapon",
        AUTO_RE_EQUIP_BEST      = "Auto re-equip the next best weapon",
        TRAP_TRIGGERED          = "Only show when trap is triggered",
        TELEPOOF_SPEED_DEFAULT  = "Double-click speed 0.5s",
        TELEPOOF_SPEED_FAST     = "Double-click speed 0.3s",
        TELEPOOF_SPEED_FASTER   = "Double-click speed 0.25s",
        TELEPOOF_SPEED_FASTEST  = "Double-click speed 0.2s",
        SORT_FULL               = "Sort your inventory and backpack",
        SORT_INVENTORY          = "Sort inventory only",
        SORT_BACKPACK           = "Sort backpack only",
        PRIORITIZE_VALUABLE     = "Prioritize picking up valuable items",
        IGNORE_BLUEPRINT        = "Filter known blueprints from pickup",
        IGNORE_FERNS            = "Do not pick up ferns",
        IGNORE_SUCCULENTS       = "Do not pick up succulents",
        IGNORE_MARSH_BUSH       = "Do not pick up marsh bushes",
        WORTOX_SOUL             = "Double-click soul hop",
        SORT_OVERRIDE           = "Keep in slot 1",

        BOULDER_DODGE           = "Automatically walks away when a Boulderbough tree is about to drop a boulder on you",
        DODGE_MARGIN            = "Extra distance to keep beyond the boulder's damage radius",
        DODGE_MANUAL_OVERRIDE   = "Holding movement keys allows manual movement, overriding auto-dodge",
        DODGE_USE_CANE          = "Auto-equip cane/orangestaff for movement speed during dodge",
        DODGE_CHOPS_OVERRIDE    = "Manually set chops needed to fell a rock tree. 0 = auto-learn per axe type",
    },

    PROMPTS =
    {
        CANNOT_UNEQUIP          = "Cannot unequip %s.",
        PREFERRED_ITEM          = "Preferred item: %s.",
        AUTO_EQUIP_CATEGORY     = "Auto-equip category: %s.",
        TOGGLE_FORMAT           = "%s (%s)",
        SORT_OPEN_CONTAINER     = "Please open a container to sort.",
        SORTING                 = "Sorting %s.",
        SORTING_CHEST           = "Sorting chest.",
        SORTING_INVENTORY       = "Sorting inventory.",
        SORTING_BACKPACK        = "Sorting backpack.",
        SORTING_ALL             = "Sorting inventory and backpack.",
        SORTING_CONTAINER       = "Sorting container (%s)",
        CANNOT_FILTER           = "Hmm... I can't filter that",
        FILTER_ADD              = 'Alright! From now on, I will leave "%s" on the ground',
        FILTER_REMOVE           = 'I will pick up "%s" again',
        MEAT_MODE               = 'Current meat mode is "%s".',
        HOLD_TO_EAT             = "Hold %s to eat %s.",
        TEMP_ITEM_ADDED         = "Temporarily added %s to %s quickbar.",
        TEMP_ITEM_REMOVED       = "Temporary item %s removed.",

        MEDAL_NOT_FOUND         = "Auto-equip failed: %s not found.",
        MEDAL_NOT_ACCESSIBLE    = "Auto-equip failed: %s is in a container, cannot auto-retrieve.",
        MEDAL_PULL_FAILED       = "Auto-equip failed: cannot retrieve %s from medal box, check backpack space.",
        MEDAL_ORIGIN_NO_SLOT    = "Origin link failed: Origin medals full, no slot to swap out.",

        CHEST_MEMORY_DISPLAY_MODE   = "Chest memory display mode: %s.",
        CHEST_MEMORY_DISPLAY_BUTTON = "Switch display mode (current: %s)",

        AUTO_SOUL_FIX_JAR_ON    = "Auto soul jar refresh enabled",
        AUTO_SOUL_FIX_JAR_OFF   = "Auto soul jar refresh disabled",
    },

    KEYBINDS =
    {
        FULL_INVENTORY_UNEQUIP = "Cannot unequip %s because your backpack is full.",
    },

    BUTTONS =
    {
    },

    PICKUP_FILTER =
    {
        ADD    = "Pickup filter: added %s.",
        REMOVE = "Pickup filter: removed %s.",
    },

    ATTACK_FILTER =
    {
        ADD    = "Attack filter: added %s.",
        REMOVE = "Attack filter: removed %s.",
    },

    AUTO_UNEQUIP_ITEM =
    {
        UNEQUIP = "Auto-unequip: %s.",
        DROP    = "Auto-unequip: dropping current item to keep %s.",
        FAIL    = "Auto-unequip: failed to unequip %s.",
    },

    AUTO_REPAIR_ITEM =
    {
        REPAIRING   = "Repairing: %s.",
        RETRY       = "Retrying repair: %s (%d/3)",
        INTERRUPTED = "%s repair interrupted, waiting...",
        NO_MATERIAL = "Missing repair material, %s waiting...",
    },

    TOGGLE =
    {
        ENABLED              = "Enabled",
        DISABLED             = "Disabled",
        TELEPOOF             = "Telepoof",
        AUTO_EQUIP_ON        = "Auto-equip: ON",
        AUTO_EQUIP_OFF       = "Auto-equip: OFF",
    },

    -- Chest memory display mode names (all / single / hidden)
    CHEST_MEMORY_DISPLAY =
    {
        ALL    = "All",
        SINGLE = "Hover",
        HIDDEN = "Hidden",
    },

    INVENTORY_ITEM =
    {
        EAT_VALUABLE_RESOURCE = "%s is a valuable resource. (Hold %s to eat)",
    },
}