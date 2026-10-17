------------------------------------------------------------
-- bot_beastmaster.lua
-- All 4 go to ONE camp, farm it for 20s, then retreat far away, this script fixes 5 min afk SF gold reward
------------------------------------------------------------

local safeCamp = {
    [TEAM_RADIANT] = Vector(244, -5567),
    [TEAM_DIRE]    = Vector(-994, 4195),
}

-- Wait spot: 1500 units from the camp (out of aggro range)
local waitSpot = {
    [TEAM_RADIANT] = Vector(244, -4000),
    [TEAM_DIRE]    = Vector(-994, 2700),
}

local CYCLE = 120       -- every 2 minutes
local FARM_TIME = 20    -- farm the camp for 20s

function Think()
    local bot = GetBot()
    if bot == nil or not bot:IsAlive() then return end
    if DotaTime() < 60 then return end

    local team = GetTeam()
    local camp = safeCamp[team]
    local wait = waitSpot[team]
    if camp == nil or wait == nil then return end

    local timeInCycle = DotaTime() % CYCLE

    ------------------------------------------------
    -- FARM PHASE (first 20s)
    ------------------------------------------------
    if timeInCycle < FARM_TIME then
        local neutrals = bot:GetNearbyNeutralCreeps(1200)
        if neutrals ~= nil and #neutrals > 0 then
            bot:Action_AttackUnit(neutrals[1], true)
            return
        end

        -- Walk to the camp
        bot:Action_AttackMove(camp)
        return
    end

    ------------------------------------------------
    -- WAIT PHASE (20-120s)
    -- Stay far away to regen; neutrals won't reach us
    ------------------------------------------------
    bot:Action_MoveToLocation(wait)
end

function ItemPurchaseThink() end
function AbilityLevelUpThink()
    local bot = GetBot()
    if bot == nil then return end
    if bot:GetAbilityPoints() < 1 then return end

    local axes = bot:GetAbilityByName(
        "beastmaster_wild_axes"
    )
    if axes ~= nil and axes:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility(
            "beastmaster_wild_axes"
        )
        return
    end

    local inner = bot:GetAbilityByName(
        "beastmaster_inner_beast"
    )
    if inner ~= nil and inner:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility(
            "beastmaster_inner_beast"
        )
    end
end
function AbilityUsageThink() end
function CourierUsageThink() end
function BuybackUsageThink() end
