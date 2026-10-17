-- scripts/vscripts/bots/nevermore/positioning.lua

local C = require("bots/nevermore/constants")

local P = {}

function P.GetFountain(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function P.GetT1Tower(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
end

function P.GetT1Close(bot)
    if bot:GetTeam() == TEAM_RADIANT then
        return C.POSITIONS.RADIANT_T1_CLOSE
    else
        return C.POSITIONS.DIRE_T1_CLOSE
    end
end

function P.GetHoldFlank(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_FLANK_TOP or C.POSITIONS.DIRE_FLANK_TOP
end

function P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, prepareTarget, mode)
    local fountain = P.GetFountain(bot)

    if prepareTarget and prepareTarget:IsAlive() then
        local numEnemies = enemyCreeps and #enemyCreeps or 0
        if (allyCreeps and #allyCreeps > 0) or numEnemies <= 2 then
            local dir = (fountain - prepareTarget:GetLocation()):Normalized()
            return prepareTarget:GetLocation() + dir * 150
        end
    end

    local numAllies = allyCreeps and #allyCreeps or 0
    local numEnemies = enemyCreeps and #enemyCreeps or 0

    if numAllies == 0 and numEnemies == 0 then return P.GetT1Close(bot) end
    if numAllies == 0 and numEnemies > 0 then return P.GetT1Close(bot) end

    if numAllies > 0 then
        -- Передний крип = ближайший к ВРАЖЕСКОЙ Т1 (раньше брали ближайшего к центру карты,
        -- и когда волна уходила за центр, бот вставал за задним крипом - ласт-хиты терялись).
        local enemyT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
        local frontAlly = allyCreeps[1]
        local minDist = math.huge
        for _, c in pairs(allyCreeps) do
            if c and c:IsAlive() then
                local d = GetUnitToLocationDistance(c, enemyT1)
                if d < minDist then
                    minDist = d
                    frontAlly = c
                end
            end
        end
        local dir = (fountain - frontAlly:GetLocation()):Normalized()
        local dist_from_creeps = 450
        if mode == "PASSIVE" then
            dist_from_creeps = 650
        elseif mode == "AGGRESSIVE" then
            dist_from_creeps = 250
        end
        return frontAlly:GetLocation() + dir * dist_from_creeps
    end

    return P.GetT1Close(bot)
end

return P
