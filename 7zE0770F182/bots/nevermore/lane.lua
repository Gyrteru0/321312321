-- scripts/vscripts/bots/nevermore/lane.lua
--
-- Лейн-логика: фронт волны, опасность вражеской Т1 (щит из крипов), позиция для зонинга,
-- план пуша. Чистые вычисления поверх снимка мира; без аллокаций в тике (кроме Vector).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local LN = {}

local TOWER_RANGE = (C.TOWER and C.TOWER.ATTACK_RANGE) or 700
local TOWER_SAFE  = (C.TOWER and C.TOWER.SAFE_RADIUS) or 780
local EMPTY = {}

local function IsSiege(unit)
    local name = unit:GetUnitName() or ""
    return name:find("siege") ~= nil or name:find("catapult") ~= nil
end
LN.IsSiege = IsSiege

local function EnemyT1Pos(bot)
    return (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
end
LN.EnemyT1Pos = EnemyT1Pos

-------------------------------------------------------------------------------
-- Волна
-------------------------------------------------------------------------------

-- Мой передний крип = ближайший к вражеской Т1 (а не к центру карты - это было ошибкой
-- старой версии, когда волна уходила за центр).
function LN.FrontAllyCreep(bot, allyCreeps)
    local target = EnemyT1Pos(bot)
    local best, bestD = nil, math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, target)
            if d < bestD then
                bestD = d
                best = c
            end
        end
    end
    return best, bestD
end

-- Центр моей волны (среднее положение живых крипов) -> Vector или nil
function LN.AllyWaveCenter(allyCreeps)
    local n, sx, sy, sz = 0, 0, 0, 0
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local l = c:GetLocation()
            n = n + 1
            sx, sy, sz = sx + l.x, sy + l.y, sz + l.z
        end
    end
    if n == 0 then return nil end
    return Vector(sx / n, sy / n, sz / n)
end

-- Враг "занят волной": бьёт крипа / далеко от нас.
function LN.EnemyBusyWithWave(bot, enemy)
    if not U.CanQuery(enemy) then return true end
    local tgt = enemy.GetAttackTarget and enemy:GetAttackTarget()
    if tgt and tgt ~= bot and U.CanQuery(tgt) then
        local isHero = tgt.IsHero and tgt:IsHero()
        if not isHero then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Опасность вражеской башни
-------------------------------------------------------------------------------

-- Щит из крипов: есть ли живой (не осадный) мой крип в радиусе башни, который ближе к башне,
-- чем refLoc (точка, где я стою/буду стоять), и которого башня не вот-вот добьёт.
-- Возвращает count, closestCreepDist.
function LN.TowerShieldCount(tower, allyCreeps, refLoc)
    if not tower then return 0, math.huge end
    local tLoc = tower:GetLocation()
    local refDist = refLoc and U.DistanceBetweenLocations(tLoc, refLoc) or math.huge
    local count, closest = 0, math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() and not IsSiege(c) then
            local d = GetUnitToLocationDistance(c, tLoc)
            if d <= TOWER_RANGE + 40 and d < refDist - 25 and (c:GetHealth() or 0) >= 110 then
                count = count + 1
                if d < closest then closest = d end
            end
        end
    end
    return count, closest
end

-- Уровень опасности башни для точки refLoc (по умолчанию - текущая позиция бота):
--   0 - вне радиуса башни;
--   1 - в радиусе, но под щитом (крип ближе к башне, башня бьёт не нас);
--   2 - в радиусе без щита, или башня уже целится в нас.
function LN.TowerDanger(bot, tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return 0 end
    refLoc = refLoc or bot:GetLocation()
    local d = U.DistanceBetweenLocations(tower:GetLocation(), refLoc)
    if d > TOWER_SAFE then return 0 end
    -- GetAttackTarget у невидимой башни -> предупреждение "cannot be seen": только если видна
    local tgt = nil
    if tower.GetAttackTarget and (not tower.CanBeSeen or tower:CanBeSeen()) then tgt = tower:GetAttackTarget() end
    if tgt == bot then return 2 end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.0) then return 2 end
    local shield = LN.TowerShieldCount(tower, allyCreeps, refLoc)
    if shield >= 1 then return 1 end
    return 2
end

-- Точка выхода из радиуса башни (в сторону своего фонтана).
function LN.TowerEscapePoint(bot, tower)
    local fountain = U.GetFountain(bot)
    local tLoc = tower:GetLocation()
    local botLoc = bot:GetLocation()
    local dir = botLoc - tLoc
    if U.DistanceBetweenLocations(botLoc, tLoc) < 1 then dir = fountain - tLoc end
    dir = dir:Normalized()
    local toF = (fountain - botLoc):Normalized()
    local blend = (dir * 0.55 + toF * 0.45):Normalized()
    return tLoc + blend * (TOWER_SAFE + 120)
end

-------------------------------------------------------------------------------
-- Зонинг
-------------------------------------------------------------------------------

-- Позиция между врагом и моей волной на дистанции holdDist от врага.
-- Не уходим от волны дальше, чем на maxFromWave; не заходим под вражескую Т1.
function LN.ZonePosition(bot, enemy, allyCreeps, holdDist, maxFromWave)
    if not U.CanQuery(enemy) then return nil end
    local enLoc = enemy:GetLocation()
    local waveCenter = LN.AllyWaveCenter(allyCreeps)
    local anchor = waveCenter or U.GetFountain(bot)
    local dir = anchor - enLoc
    local dAnchor = U.DistanceBetweenLocations(anchor, enLoc)
    if dAnchor < 1 then dir = U.GetFountain(bot) - enLoc end
    dir = dir:Normalized()
    local hold = holdDist or 520
    local pos = enLoc + dir * hold
    if waveCenter then
        local dWave = U.DistanceBetweenLocations(pos, waveCenter)
        local limit = maxFromWave or 520
        if dWave > limit then
            -- враг далеко от волны: держимся у волны со стороны врага
            local toEnemy = (enLoc - waveCenter):Normalized()
            pos = waveCenter + toEnemy * limit
        end
    end
    return pos
end

-- Насколько враг близко к моей волне (мин. дистанция до моего крипа).
function LN.EnemyDistToAllyWave(enemy, allyCreeps)
    if not U.CanQuery(enemy) then return math.huge end
    local eLoc = enemy:GetLocation()
    local best = math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, eLoc)
            if d < best then best = d end
        end
    end
    return best
end

-------------------------------------------------------------------------------
-- Пуш
-------------------------------------------------------------------------------

-- Лучшая цель для пуша среди вражеских крипов (ближняя, с низким HP приоритетнее).
-- Крип для пуша с руки. Бьём "толстых" крипов: крип, которого свои добьют и так (HP <= ~2.5
-- моих ударов), - кандидат на ласт-хит, и удар пуша по нему лишь ломает тайминг ласт-хита
-- (раньше, наоборот, предпочитали низкое HP -> крипы "срезались" в зону, где их добивали свои).
function LN.PushHpFloor(bot, c, allyCreeps)
    -- ниже этого HP крип - кандидат на ласт-хит, пуш-ударом его не трогаем:
    -- 2.5 моих удара + то, что снимут с него мои крипы за ~1.2 с (пока летит мой цикл атаки)
    local myDmg = bot:GetAttackDamage() or 50
    local focus = 0
    for _, a in pairs(allyCreeps or EMPTY) do
        if a and U.CanQuery(a) and a:GetAttackTarget() == c then focus = focus + 1 end
    end
    return myDmg * 2.5 + focus * 21 * 1.2
end

function LN.BestPushCreep(bot, enemyCreeps, maxRange, allyCreeps)
    local best, bestScore = nil, math.huge
    local fallback, fallbackScore = nil, math.huge
    for _, c in pairs(enemyCreeps or EMPTY) do
        if c and U.CanQuery(c) then
            local d = GetUnitToLocationDistance(bot, c:GetLocation())
            if d <= (maxRange or 700) then
                local hp = c:GetHealth() or 0
                local score = -hp + d * 0.15
                if IsSiege(c) then score = score + 200 end
                if hp > LN.PushHpFloor(bot, c, allyCreeps) then
                    if score < bestScore then bestScore, best = score, c end
                else
                    if d < fallbackScore then fallbackScore, fallback = d, c end
                end
            end
        end
    end
    return best or fallback
end

-- Можно ли бить Т1: щит из >= minShield крипов (ближе к башне, чем я), башня не на мне.
function LN.CanHitTower(bot, tower, allyCreeps, minShield)
    if not tower or not tower:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, tower, allyCreeps, nil)
    if danger >= 2 then return false end
    local shield = LN.TowerShieldCount(tower, allyCreeps, bot:GetLocation())
    return shield >= (minShield or 2)
end

-- Точка ожидания следующей волны у вражеской Т1 (вне радиуса башни, со стороны своего фонтана).
function LN.SiegeWaitPoint(bot, tower)
    local fountain = U.GetFountain(bot)
    local tLoc = tower and tower:GetLocation() or EnemyT1Pos(bot)
    local dir = (fountain - tLoc):Normalized()
    return tLoc + dir * (TOWER_SAFE + 260)
end

return LN
