-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",

    "item_magic_stick",
    "item_branches", "item_recipe_magic_wand",

    "item_boots",
    "item_gloves",
    "item_boots_of_elves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}

-- Returns true if there is a real (non-bot) player on EITHER side
local function HasHumanInGame()
    local radiantPlayers = GetTeamPlayers(TEAM_RADIANT)
    for _, playerId in pairs(radiantPlayers) do
        if not IsPlayerBot(playerId) then
            return true
        end
    end
    local direPlayers = GetTeamPlayers(TEAM_DIRE)
    for _, playerId in pairs(direPlayers) do
        if not IsPlayerBot(playerId) then
            return true
        end
    end
    return false
end

-- Gets or creates the purchase state for a specific bot
local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
        }
    end

    return BotPurchaseState[pid]
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    local gold = bot:GetGold()

    -- 0. WARD AT 4:30 (270 seconds)
    if DotaTime() >= 270 and not state.bought5MinWard then
        bot:ActionImmediate_PurchaseItem("item_ward_observer")
        state.bought5MinWard = true
    end

    -- 1. DYNAMIC HEAL AND MANA PURCHASE (Mango prioritized)
    if DotaTime() > 0 and GameTime() - state.lastSalveBuyTime > 30 then
        local hpPct = bot:GetHealth() / bot:GetMaxHealth()
        local mpPct = bot:GetMana() / bot:GetMaxMana()

        local hasSalve = bot:FindItemSlot("item_flask") >= 0
        local hasMango = bot:FindItemSlot("item_enchanted_mango") >= 0

        if hpPct <= 0.40 and not hasSalve and gold >= 100 then
            bot:ActionImmediate_PurchaseItem("item_flask")
            state.lastSalveBuyTime = GameTime()
            gold = gold - 100
        end

        if mpPct < 0.35 and not hasMango and gold >= 65 then
            bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
            state.lastSalveBuyTime = GameTime()
            gold = gold - 65
        end
    end

    -- 2. MAIN BUILD
    if state.currentItemIndex <= #PurchaseTable then
        local nextItem = PurchaseTable[state.currentItemIndex]
        if gold >= GetItemCost(nextItem) then
            bot:ActionImmediate_PurchaseItem(nextItem)
            state.currentItemIndex = state.currentItemIndex + 1
        end
    end

    -- 3. SMART COURIER (strictly personal)
    if GameTime() - state.lastCourierCallTime > 1.0 then

        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = GetNumCouriers()
        local myCourier = nil

        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() then
                if c:GetPlayerID() == pid then
                    myCourier = c
                    break
                end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)

            if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE then

                local stashItemsCount = 0
                local onlyWardInStash = true

                for i = 9, 14 do
                    local item = bot:GetItemInSlot(i)
                    if item then
                        stashItemsCount = stashItemsCount + 1
                        if item:GetName() ~= "item_ward_observer" then
                            onlyWardInStash = false
                        end
                    end
                end

                if stashItemsCount > 0 and not (stashItemsCount == 1 and onlyWardInStash) then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    state.lastCourierCallTime = GameTime()
                end
            end
        end
    end
end
