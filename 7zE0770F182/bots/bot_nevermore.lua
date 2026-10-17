-- scripts/vscripts/bots/bot_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")
local K = require("bots/nevermore/combat")
local W = require("bots/nevermore/world")
local LN = require("bots/nevermore/lane")
local I = require("bots/nevermore/intent")

-- Маркер загрузки: если этой строки нет в консоли, значит файл не загрузился и играет
-- стандартный бот Valve (ищите в консоли ошибки [VScript]).
print("[SF-BOT] bot_nevermore.lua loaded (v2.8: straight-flee/raze-kill-angle/free-pressure/aim-smoothing)")

U.DEBUG = false

-- Все обработчики живут в таблице H (а не в local function): обход лимита Lua 5.1
-- в 60 upvalue на функцию (иначе файл не компилируется в Dota).
local H = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local State = {
    hunting                   = false, -- v2.5: "охота" (H.ComputeHunt)
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    prepTargetTime            = 0,
    lhAttackTarget            = nil,
    defensive                 = false,
    defensiveSince            = 0,
    enemyAggroCount           = 0,
    tpOrderTime               = 0,
    lastMangoBuyTime          = -1000,
    lastFlaskBuyTime          = -1000,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    tpOrderTime               = -100,
    -- v2.6: обязательство "добить" / "бежать" (анти-дёргання бой<->бег)
    commitKillUntil           = 0,
    fleeUntil                 = 0,
    -- v2.6: враг телепортируется к Т1 (канал ТП виден / вернулся после смерти)
    enemyTPIncomingUntil      = 0,
    enemyWasAlive             = true,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    nearChainUntil            = 0,   -- v2.4: окно "цепочки" рейзов после наказания подошедшего вплотную врага (L1-L2)
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    holdPos = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    _lastSalveAutoBuyTime     = 0,
    -- tango: "липкое" дерево (фикс осцилляции между деревьями)
    tangoTree                 = nil,
    tangoCastAt = 0,
    tangoFails = 0,
    tangoTreeLoc              = nil,
    tangoChosenAt             = 0,
    tangoBestDist             = math.huge,
    tangoBadTree              = nil,
    tangoBadTreeTime          = 0,
    -- уклонение от рейза врага
    dodgeLoc                  = nil,
    dodgeUntil                = 0,
    -- намерение и контекст
    intent                    = "FARM",
    lastIntentPrint           = 0,
    siegeWaitUntil            = 0,
}

-- Контекст для автомата намерений (переиспользуется, без аллокаций в тике)
local IntentCtx = {
    enemy = false, race = nil, myHpPct = 1, myRazes = 0, healing = false,
    enemyDist = 99999, enemyDistToWave = 99999, enemyAbsent = false,
    enemyUnderHisTower = false, canCatch = true, underEnemyTower = false,
}

-- v2.5: хук для utils (глиф под дайв): "мы реально добиваем" = целимся рейзом / били героя <= 1 с назад
U._State = State -- тестовый хук: доступ к State из инструментов (run_vs_orig)
U._engagedCheck = function(bot, enemy)
    if State.aimingRaze then return true end
    if (GameTime() - (State.heroAttackTime or -10)) <= 1.0 then return true end
    return false
end

-- force=true: микро-шаги (поворот под рейз, уклонение) не должны съедаться дедупликацией.
function H.SmartMove(bot, loc, threshold, force)
    if not loc then return false end
    if State.actionTaken then return false end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if force then
        if last and (now - State.lastMoveTime) < 0.1 and U.DistanceBetweenLocations(last, loc) <= 4 then
            State.actionTaken = true
            return true
        end
    elseif last and U.DistanceBetweenLocations(last, loc) <= threshold and (now - State.lastMoveTime) < 0.6 then
        -- Приказ в эту точку уже отдан недавно: считаем, что действие выполняется (actionTaken),
        -- иначе следующий обработчик перебьёт его своим приказом, и на следующем тике всё
        -- повторится в обратную сторону - классическая осцилляция между двумя точками.
        State.actionTaken = true
        return true
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
    State.actionTaken = true
    return true
end

function H.ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

function H.ClearRazeState()
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
end

function H.StartRazeCast(ability, target, loc, validationRadius)
    State.lastRazeOrderTime = GameTime() -- v2.5: мгновенное зеркало - не чаще одного на его попадание
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.actionTaken = true
end

function H.HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        if not State.aimingTarget or not State.aimingTarget:IsAlive() then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local elapsed = now - State.aimingStartTime
        local remaining = C.RAZE.CAST_POINT - elapsed
        if remaining < 0.03 then remaining = 0.03 end

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local predicted = U.PredictPosition(State.aimingTarget, remaining + 0.03)
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit = (State.aimingValidationRadius or C.RAZE.HIT_RADIUS) + 50

        if error > limit then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
        end
        return true
    end

    if now > State.aimingStartTime + 1.0 then
        H.ClearRazeState()
    end

    return false
end

function H.SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    H.ClearMoveCache()
    return true
end

function H.BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = GameTime() + (duration or 0.75)
    -- v2.6: чистый бег: пока отступаем - не поворачиваемся на врага и не отвечаем
    State.fleeUntil = GameTime() + 1.5
    H.SafeClearActions(bot)
    bot:Action_MoveToLocation(loc)
    State.lastMoveLoc = loc
    State.lastMoveTime = GameTime()
    State.actionTaken = true
    return true
end

function H.ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

function H.CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if not ability then return false end
    if State.actionTaken then return false end
    -- v2.5: любой путь, решивший "CAST", проходит проверку разворота (см. H.RazeFacingOK): иначе TURN
    if actionType == "CAST" and aimLoc and not H.RazeFacingOK(bot, aimLoc) then
        actionType = "TURN"
    end

    local data = U.GetRazeAbilityData(ability)
    if data and target and U.CanQuery(target) then
        -- Проверяем полосу и по текущей позиции, и по предсказанной (aimLoc): рейз ложится
        -- через 0.55 с, и идущий на нас враг за это время сменит полосу. Раньше проверялась
        -- только текущая позиция, и каст по подходящему врагу срывался.
        local distNow = GetUnitToLocationDistance(bot, target:GetLocation())
        local errNow = math.abs(distNow - data.center)
        local errPred = errNow
        if aimLoc then
            errPred = math.abs(GetUnitToLocationDistance(bot, aimLoc) - data.center)
        end
        if math.min(errNow, errPred) > C.RAZE.STRICT_RADIUS + 25 then
            return false
        end
    end

    if actionType == "TURN" then
        -- v2.3: предохранитель от бесконечного доворота: доворот на 180 градусов занимает ~0.1 с,
        -- так что TURN подряд дольше 0.45 с = что-то не сходится (цель на границе круга и т.п.);
        -- тогда рейзы через TURN блокируем на 1 с и отдаём управление остальной логике.
        local now = GameTime()
        if now < (State.razeTurnBlockUntil or 0) then return false end
        if (now - (State.lastTurnTick or -10)) > 0.25 then State.turnSince = now end
        State.lastTurnTick = now
        if (now - (State.turnSince or now)) > 0.45 then
            State.razeTurnBlockUntil = now + 1.0
            State.turnSince = now
            return false
        end
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        local dist = U.DistanceBetweenLocations(botLoc, turnLoc)
        local stepLoc = turnLoc
        -- v2.5: шаг доворота 40 u (было 12): слишком короткий приказ движок мог исполнить без
        -- полного разворота героя; 40 u = ~0.13 с хода, каст следующим тиком его останавливает
        local step = (C.RAZE.TURN_STEP or 40)
        if dist > step + 10 then
            local dir = (turnLoc - botLoc):Normalized()
            stepLoc = botLoc + dir * step
        end
        H.SmartMove(bot, stepLoc, 20, true)
        State.actionTaken = true
        return true
    elseif actionType == "CAST" then
        U.SwitchTreadsIfNeeded(bot, 1)
        bot:Action_UseAbility(ability)
        H.StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        H.ClearMoveCache()
        return true
    end

    return false
end

-- v2.5: единая проверка разворота перед кастом. Рейз без цели летит туда, куда герой СМОТРИТ в
-- момент начала каста; "круг накрывает врага при текущем развороте" (errFacing <= 220) допускал
-- каст с ошибкой до ~18 градусов на дальней полосе - и любой шаг врага в сторону = промах
-- ("бот чуть довернул влево/вправо и промахнулся"). Теперь CAST только если угол между
-- направлением взгляда и точкой наведения <= MAX_ANGLE_TO_CAST; иначе TURN (0.03-0.1 с).
function H.RazeFacingOK(bot, aimLoc)
    if not aimLoc then return true end
    local maxAng = (C.RAZE.MAX_ANGLE_TO_CAST or 6)
    return U.GetAngleDifference(bot, aimLoc) <= maxAng
end



function H.GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

-- Робастно (v2.2): CAST, если при текущем развороте круг накрывает врага и сейчас, и через
-- время каста; TURN на точку наведения, если накроет после доворота; иначе nil.
function H.GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local data = U.GetRazeAbilityData(ability)
    if not data then return nil, nil end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30)
    -- v2.3: порог каста = порогу кандидата. Разные пороги (CAST <= limit-15, TURN <= limit) давали
    -- "мёртвую зону": после доворота errFacing == errAim в (limit-15, limit] -> каст никогда не
    -- проходит, а TURN выдаётся каждый тик (шаг 12 u) -> бот бесконечно "трясётся" на месте.
    -- v2.5: CAST = круг накрывает И герой развёрнут на точку наведения (угол <= MAX_ANGLE_TO_CAST);
    -- накрывает только после доворота -> TURN
    if errFacing <= limit and H.RazeFacingOK(bot, aim) then return "CAST", aim end
    if errAim <= limit then return "TURN", aim end
    return nil, aim
end

function H.GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

function H.GetPotentialCombatMana(bot)
    local mana = bot:GetMana() or 0
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and wand.GetCurrentCharges then
        mana = mana + (wand:GetCurrentCharges() or 0) * 15
    end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and stick.GetCurrentCharges then
        mana = mana + (stick:GetCurrentCharges() or 0) * 15
    end
    mana = mana + U.GetMangoMana(bot) -- v2.5: по зарядам
    return mana
end

function H.TryUseBurstManaItem(bot, allowMango)
    local item = H.GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

function H.IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

function H.IsSameAttackTarget(bot, target)
    return bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK and bot:GetAttackTarget() == target
end

function H.IssueHeroAttack(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local sameTarget = H.IsSameAttackTarget(bot, enemyHero)
    if not sameTarget then
        bot:Action_AttackUnit(enemyHero, true)
        H.ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    State.heroAttackTarget = enemyHero
    State.heroAttackTime = GameTime()
    return true
end

-- v2.5: детектор замаха по АНИМАЦИИ (GetAnimActivity/GetAnimCycle), а не по времени приказа:
-- приказ "атаковать" отдаётся за 0-1 с до реального замаха (герой ещё идёт/доворачивается),
-- поэтому "замок по времени приказа" истекал раньше настоящего замаха, и любой следующий
-- обработчик (сброс агро крипов, ласт-хит, доворот под рейз, позиция) отменял удар за долю
-- секунды до точки атаки. Вызывается каждый тик до принятия решений.
function H.UpdateAttackActivity(bot)
    local now = GameTime()
    local act, cyc = nil, nil
    if bot.GetAnimActivity then
        local ok, a = pcall(bot.GetAnimActivity, bot)
        if ok and type(a) == "number" then act = a end
    end
    if act == nil then
        State.atkAnimAvailable = false
        State.atkAnimSince = nil
        return
    end
    if bot.GetAnimCycle then
        local ok, c = pcall(bot.GetAnimCycle, bot)
        if ok and type(c) == "number" then cyc = c end
    end
    State.atkAnimAvailable = true
    local A1 = _G.ACTIVITY_ATTACK or 1503
    local A2 = _G.ACTIVITY_ATTACK2 or 1504
    local A3 = _G.ACTIVITY_ATTACK_EVENT or 1505
    local isAtk = (act == A1 or act == A2 or act == A3)
    if isAtk then
        local restarted = cyc and State.atkAnimCycle and (cyc < State.atkAnimCycle - 0.05)
        if not State.atkAnimSince or restarted then State.atkAnimSince = now end
    else
        State.atkAnimSince = nil
    end
    State.atkAnimCycle = cyc
end

-- Идёт замах удара с руки по вражескому герою (точка атаки ещё не пройдена)?
function H.IsHeroWindupNow(bot, enemyHero)
    if not enemyHero then return false end
    local okT, target = pcall(bot.GetAttackTarget, bot)
    if not okT or target ~= enemyHero then return false end
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK then return false end
    local ap = bot:GetAttackPoint() or 0.5
    if State.atkAnimAvailable then
        if not State.atkAnimSince then return false end
        return (GameTime() - State.atkAnimSince) < (ap + 0.03)
    end
    return H.IsHeroAttackWindupLocked(bot)
end

-- v2.5: "дать удару долететь": пока идёт замах по герою, никакие НЕэкстренные обработчики приказов
-- не отдают (удар 70-90 урона за 0.3-0.5 с дороже любого из них). Исключения: его бурст прямо сейчас
-- летален, вражеская башня бьёт нас, аварийный отход. (Уклонение от рейза стоит выше и уже отработало.)
function H.ShouldHoldForHeroWindup(bot, s, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not H.IsHeroWindupNow(bot, enemyHero) then return false end
    if State.emergencyRetreat then return false end
    if race and race.valid and race.heCanKillNow then return false end
    local t1 = s and s.enemyT1
    if t1 and t1.GetAttackTarget and (not t1.CanBeSeen or t1:CanBeSeen()) then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then return false end
    end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    return true
end

function H.IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local ap = bot:GetAttackPoint() or 0
    return elapsed < (ap + 0.06)
end

-- "Щит" под башней: живой (не осадный) мой крип в радиусе башни, который БЛИЖЕ к башне,
-- чем точка refLoc (по умолчанию - бот), и башня сейчас бьёт не нас. Старая проверка
-- ("любой крип в 760 от башни") пропускала ситуацию, когда крипы уходили за врагом,
-- а бот оставался ближайшей целью башни.
function H._hasTankCreepUnderTower(tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return false end
    local bot = GetBot()
    local tgt = tower.GetAttackTarget and tower:GetAttackTarget()
    if bot and tgt == bot then return false end
    -- v2.3: "ожог" после выхода из-под башни: она только что била НАС - щиту не верим
    -- (ласт-хиты/подходы только из-за её радиуса, пока ожог не прошёл)
    if H.TowerBurnActive and H.TowerBurnActive() then return false end
    local ref = refLoc or (bot and bot:GetLocation())
    local count = LN.TowerShieldCount(tower, allyCreeps, ref)
    return count >= 1
end

-- v2.7: крип-танк под башней не оправдывает заход, если вражеский герой рядом и мы слабее
-- (фулл HP он, мы нет): под башней в таком размене мы просто умираем, "блуждая" по точкам.
function H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc)
    if H._hasTankCreepUnderTower(tower, allyCreeps, targetLoc) then
        local eh = H._enemyHeroNear and H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            local d = GetUnitToLocationDistance(eh, targetLoc)
            if d <= 900 then
                local myHp, enHp = bot:GetHealth(), eh:GetHealth()
                if myHp < enHp - 100 or (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.50 then
                    return false
                end
            end
        end
        return true
    end
    return false
end

function H.GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

function H.GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

-- Единая точка входа для ЛЮБОГО сближения с вражеским героем:
--  1) не догонять врага с равной/большей скоростью, который уходит (бессмысленно, теряем крипов);
--  2) поводок у его Т1: не заходить в радиус башни без щита из крипов;
--  3) обычная коррекция точки относительно башни.
-- Можно ли сблизиться до дистанции dAfter с врагом, не попав под собственный "страх полосы"?
function H.ApproachIntoBandOK(bot, enemyHero, dAfter)
    if State.intent == I.RETREAT then return false end
    local R = K._race
    local killing = (R and R.valid and R.canKillSoon) or State.hunting -- v2.5: охота = добивание
    -- v2.5: со свежим стаком на мне сближение в ближнюю полосу (< 470 = его удар с руки + ближний
    -- рейз с бонусом за стак) запрещено, кроме добивания; с 2+ стаками не сближаемся вообще.
    -- Раньше проверялся только "страх полосы" (без стака не срабатывал при edge >= 0), и зеркало /
    -- добивание стака подводили застаканного бота вплотную к врагу.
    if not killing then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local nearFear = (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
            if dAfter < nearFear then return false end
            if st >= 2 then return false end
        end
    end
    -- единая минимальная дистанция (страх полосы + правило "со стаком вне его готовых полос")
    local fearMin = U.GetMinDistWithStack(bot, enemyHero)
    if fearMin <= 0 then return true end
    return dAfter >= fearMin - 20
end

function H.ApproachEnemyPoint(bot, enemyHero, loc, threshold, enemyTowers, allyCreeps, allowDive)
    if not loc then return false end
    if State.actionTaken then return false end
    if allowDive and H.TowerBurnActive() then allowDive = false end -- v2.3: после выхода из-под Т1 дайвов нет
    if enemyHero and U.CanQuery(enemyHero) then
        local botLoc = bot:GetLocation()
        local enLoc = enemyHero:GetLocation()
        local dNow = U.DistanceBetweenLocations(botLoc, enLoc)
        local dAfter = U.DistanceBetweenLocations(loc, enLoc)
        if dAfter < dNow - 60 then
            -- сближаемся: имеет ли это смысл?
            if not K.CanCatch(bot, enemyHero, dAfter, 2.0) then return false end
            -- Не лезем в его ГОТОВУЮ полосу, если там же сработает наш собственный страх
            -- (ShouldRetreatFromEnemyRazeStack): иначе получаем петлю "подошёл - испугался - отошёл".
            if not allowDive and not H.ApproachIntoBandOK(bot, enemyHero, dAfter) then return false end
        end
        local t1 = W.s.enemyT1
        if t1 and not allowDive then
            local okLoc, tLoc = pcall(t1.GetLocation, t1)
            if okLoc and tLoc then
                local leash = (C.TOWER and C.TOWER.CHASE_LEASH) or 820
                if U.DistanceBetweenLocations(tLoc, loc) < leash and LN.TowerDanger(bot, t1, allyCreeps, loc) >= 2 then
                    return false
                end
            end
        end
    end
    loc = H.GetSafeApproachLoose(bot, loc, enemyTowers or {}, allyCreeps or {})
    return H.SmartMove(bot, loc, threshold or 35)
end

function H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 420 then return false end
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            -- v2.2: удар с руки по герою в радиусе башни переводит башню на нас НЕЗАВИСИМО от
            -- крипов (правило агро башни на атаку героя) - сами стоим вне её радиуса всегда
            -- (+30 на шаг к цели). Крип-щит смягчает только требование к позиции цели.
            if GetUnitToLocationDistance(tower, botLoc) < 790 then return false end
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if H._hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

function H.GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

-- v2.3: бот рядом со своей Т1 (в radius от башни)
function H.IsNearOwnT1(bot, radius)
    local s = W.s
    local t1 = s and s.allyT1
    if not t1 then return false end
    local okL, tl = pcall(t1.GetLocation, t1)
    if not okL or not tl then return false end
    return GetUnitToLocationDistance(bot, tl) <= (radius or 400)
end

function H.IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

function H.HasRazeResource(bot)
    return H.GetPotentialCombatMana(bot) >= 75
end

function H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.TowerBurnActive() then return false end -- v2.3
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not H.HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

function H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

function H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if t1 and t1:IsAlive() then
        local dir = (fountain - t1:GetLocation()):Normalized()
        local extra = 150
        safeLoc = t1:GetLocation() + dir * (850 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

-- v2.3: единая защита от вражеской Т1 (вместо трюка "агро на крипа + отход", который каждый тик
-- чередовался с исполнителем отхода и давал дёрганье под башней до смерти крипов-щита).
--  1) башня целит в нас / недавно била нас -> немедленный выход из её радиуса;
--  2) в радиусе башни (<= 720) без щита из крипов -> выход;
--  3) в радиусе башни "по герою" (преследование, атака героя, наведение рейза) дольше
--     DIVE_MAX_TIME подряд -> выход.
-- Исключение (пп. 1 и 3): гарантированное добивание прямо сейчас (один удар с руки в радиусе
-- атаки / один рейз) - в пределах бюджета времени и при HP >= 40 % и >= 3 выстрелов башни.
-- Пуш/ласт-хит под щитом по времени не ограничены (их безопасность - TowerDanger/IsSafeToAttack).
-- После выхода - "ожог" towerBurnUntil: BURN_SEC без дайвов, рискованных коммитов и атак Т1.
function H.HandleEnemyTowerSafety(bot, s, enemyHero)
    local t1 = s.enemyT1
    if not t1 then State.t1EnterTime = nil return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then State.t1EnterTime = nil return false end
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okL or not tLoc then return false end
    local cfg = C.TOWER or {}
    local d = GetUnitToLocationDistance(bot, tLoc)
    local now = GameTime()
    local inRange = d <= ((cfg.ATTACK_RANGE or 700) + 20)
    if not inRange then State.t1EnterTime = nil end
    if d > (cfg.SAFE_RADIUS or 780) + 100 then return false end
    if State.actionTaken then return false end
    -- идёт каст (0.55 с): дорейзить, выйдем следующим тиком
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local onMe = false
    if t1.GetAttackTarget and (not t1.CanBeSeen or t1:CanBeSeen()) then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then onMe = true end
    end
    if not onMe and bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.0) then onMe = true end
    local reason = nil
    if onMe then
        reason = "tower on me"
    elseif inRange then
        if not State.t1EnterTime then State.t1EnterTime = now end
        local shield = LN.TowerShieldCount(t1, s.allyCreeps, bot:GetLocation())
        if shield == 0 then
            reason = "no shield"
        else
            local cur = bot:GetAttackTarget()
            local heroEngaged = State.aimingRaze and true or false
            if not heroEngaged and (now - (State.heroAttackTime or -10)) <= 1.5 then heroEngaged = true end
            if not heroEngaged and cur and U.CanQuery(cur) and cur.IsHero and cur:IsHero() then heroEngaged = true end
            if heroEngaged and (now - State.t1EnterTime) > (cfg.DIVE_MAX_TIME or 1.0) then
                reason = "dive budget"
            end
        end
    end
    -- v2.7: вражеский герой бьёт нас под его башней (рейз/удары), а мы его не добиваем -
    -- уходим сразу, а не "блуждаем" по точкам в радиусе башни (п.1 раунда 9)
    if not reason and inRange and enemyHero and U.CanQuery(enemyHero) and bot.WasRecentlyDamagedByHero then
        if bot:WasRecentlyDamagedByHero(enemyHero, 1.5) then
            local killing = U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            local committed = GameTime() < (State.commitKillUntil or 0)
            if not killing and not committed then
                reason = "hero hits me under T1"
            end
        end
    end
    if not reason then return false end
    -- исключение: гарантированное добивание сейчас, в пределах бюджета и с запасом HP
    if reason ~= "no shield" and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth()
        local maxHp = math.max(1, bot:GetMaxHealth())
        local okD, tDmg = pcall(t1.GetAttackDamage, t1)
        if not okD or type(tDmg) ~= "number" or tDmg <= 0 then tDmg = 100 end
        local hpOk = hp >= maxHp * 0.40 and hp >= tDmg * 3
        local within = (now - (State.t1EnterTime or now)) <= (cfg.DIVE_MAX_TIME or 1.0)
        if hpOk and within then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
            local razeKill = U.CanQuickTurnKillWithRaze(bot, enemyHero)
            if (oneShot and dist <= bot:GetAttackRange() + 60) or razeKill then
                return false
            end
        end
    end
    -- повторный выход из-под башни за короткое время -> ожог длиннее (не ходим туда-сюда)
    local burn = cfg.BURN_SEC or 2.5
    if (now - (State.lastTowerEscapeAt or -100)) < (cfg.REPEAT_WINDOW or 10) then burn = cfg.BURN_REPEAT_SEC or 6.0 end
    State.lastTowerEscapeAt = now
    State.towerBurnUntil = now + burn
    State.t1EnterTime = nil
    local escape = LN.TowerEscapePoint(bot, t1)
    H.BeginForcedRetreat(bot, escape, 0.9)
    if U.DEBUG then print(string.format("[SF-BOT] tower escape (%s) d=%.0f", reason, d)) end
    return true
end

-- v2.3: "ожог башни" активен (недавно пришлось выходить из-под Т1)
function H.TowerBurnActive()
    return GameTime() < (State.towerBurnUntil or 0)
end

function H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

function H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, 35)
    return true
end

function H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

function H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not H.HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        H.IssueHeroAttack(bot, enemyHero)
        return true
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = H.GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
    end

    return false
end

function H.TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local followUp = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase or followUp) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        -- v2.3: ради добивочного рейза в БЛИЖНЮЮ полосу (200 от него) не подходим - это его
        -- дальность удара с руки и его ближний рейз; добивать со средней/дальней или не добивать
        if setupPos and followUp and not isLethalChase and not forceExtend then
            local pred = U.PredictPosition(enemyHero, 0.35) or enemyHero:GetLocation()
            if U.DistanceBetweenLocations(setupPos, pred) <= C.RAZE.NEAR_CENTER + 10 then setupPos = nil end
        end
        if setupPos then
            -- Подход под его Т1 ради рейза допустим, пока башня занята крипом (рейз агро не даёт)
            -- и его бурст нас не убивает; при HP < 50% - нет.
            local allowDive = isLethalChase
            if not allowDive and (followUp or forceExtend) then
                local R = K._race
                local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
                if hpPct >= 0.5 and not (R and R.valid and R.heCanKillSoon) and H.TowerLockedOnCreep(W.s.enemyT1) then
                    allowDive = true
                end
            end
            -- Если безопасная граница (башня) отрезает большую часть подхода - позиция для рейза
            -- недостижима: не топчемся у границы, отдаём тик осаде/ласт-хитам (не для добивания).
            local reachable = true
            if not isLethalChase then
                local clamped = H.GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
                if clamped and U.DistanceBetweenLocations(clamped, setupPos) > 200 then reachable = false end
            end
            if reachable and H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps, allowDive) then
                return true
            end
        end
    end

    return false
end

function H.EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    -- v2.2: не бежим "продлевать" стак за врагом, которого не догнать до истечения (раньше -
    -- бесцельная пробежка к ушедшему врагу): нужна досягаемость дальнего рейза за остаток стака.
    if not K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS - 60, math.max(0.3, rem_time - C.RAZE.CAST_POINT)) then
        return false
    end
    -- Дисциплина маны/обороны: продление стака - тоже трата 75 маны. Разрешаем, если
    -- (а) это добивание, или (б) обычный харас по мане разрешён и мы не в обороне, или
    -- (в) стак уже >= 2 (вложено 2 рейза), гонка не против нас и мана после каста остаётся >= 75.
    local R = K._race
    local killing = R and R.valid and R.canKillSoon
    if killing then return true end
    -- v2.8: явный перевес в размене (edge >= 100, он не убивает нас сразу) - продлеваем стак,
    -- даже если формально "оборона"/резерв маны: наше рейз-преимущество должно работать
    if R and R.valid and R.edge >= 100 and not R.heCanKillNow and (bot:GetMana() - 75) >= 75 then return true end
    if State.defensive and not H.HasTradeSupport(R) then return false end
    if H.HarassManaOK(bot, R) then return true end
    if stacks >= 2 and R and R.valid and R.edge >= 0 and (bot:GetMana() - 75) >= 75 then return true end
    return false
end

function H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if not H.EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
            return true
        end
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 45, enemyTowers, allyCreeps) then
            return true
        end
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return true
    end
    if H.ApproachEnemyPoint(bot, enemyHero, desired, 45, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.LevelUpAbilities(bot)
    if bot:GetAbilityPoints() == 0 then return end
    local order = (C.SKILL and C.SKILL.ORDER) or {}
    local lvl = bot:GetLevel()
    -- Считаем, сколько раз каждая способность должна быть изучена к текущему уровню,
    -- и доучиваем недостающее (самовосстановление, если какой-то уровень был пропущен).
    local want = {}
    for i = 1, lvl do
        local name = order[i]
        if name then want[name] = (want[name] or 0) + 1 end
    end
    for name, cnt in pairs(want) do
        if not (C.SKILL and C.SKILL.ALLOW_FRENZY == false and name == "nevermore_frenzy") then
            local ab = bot:GetAbilityByName(name)
            if ab and ab:GetLevel() < cnt then
                if not ab.CanAbilityBeUpgraded or ab:CanAbilityBeUpgraded() then
                    bot:ActionImmediate_LevelAbility(name)
                    return
                end
            end
        end
    end
end

function H.IsInDangerForRegen(bot, heroDist)
    heroDist = heroDist or 850
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

function H.HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

function H.GetSalveSafeRetreatLocation(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    if enemyHero and U.CanQuery(enemyHero) then
        local enemyLoc = enemyHero:GetLocation()
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return enemyLoc + dir * safeDistance
    end
    local dir = fountain - botLoc
    if U.DistanceBetweenLocations(fountain, botLoc) < 1 then
        return fountain
    end
    dir = dir:Normalized()
    return botLoc + dir * 450
end

function H.HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    local incomingProjectile = H.HasEnemyProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return true
    end
    State.actionTaken = true
    return true
end

-- v2.7: он отвернулся (идёт от нас/за спину) во время нашего бега - кидаем ему рейз вслед.
-- Условие безопасности: он не успевает развернуться, догнать и положить нам второй стак.
-- v2.7 (п.6): добивание крипа вслед за снарядом вражеского героя. Его снаряд в полёте,
-- после попадания крип попадает в мой порог добивания -> бью сейчас, чтобы мой удар лёг
-- сразу после его (окно между его ударом и смертью крипа).
function H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local now = GameTime()
    if now < (State.snipeCooldown or 0) then return false end
    if State.prepTarget then return false end
    local myPoint = bot:GetAttackPoint() or 0.5
    for _, c in pairs(enemyCreeps or {}) do
        if c and U.CanQuery(c) and c:IsAlive() then
            local okP, projs = pcall(function() return c:GetIncomingTrackingProjectiles() end)
            if okP and type(projs) == "table" then
                for _, pr in pairs(projs) do
                    if pr.is_attack and pr.caster == enemyHero then
                        local speed = 1200
                        local okS, sp = pcall(function() return enemyHero:GetAttackProjectileSpeed() end)
                        if okS and type(sp) == "number" and sp > 0 then speed = sp end
                        local eta = 0.3
                        if pr.location then
                            eta = U.DistanceBetweenLocations(pr.location, c:GetLocation()) / speed
                        end
                        if eta <= 0.7 then
                            local myDmg = U.SFDamageRange(bot, c).min
                            local ctx = U.GetTargetPredictionContext(c, { enemyHero })
                            local hpAfter = U.PredictHPWithContext(ctx, c, eta + 0.05, "avg")
                            -- его удар не убивает крипа, но делает его моим
                            if hpAfter > 0 and hpAfter <= myDmg * 0.97 then
                                local travel = 0.2
                                local okPS, psp = pcall(function() return bot:GetAttackProjectileSpeed() end)
                                if okPS and type(psp) == "number" and psp > 0 then
                                    travel = U.DistanceBetweenLocations(bot:GetLocation(), c:GetLocation()) / psp
                                end
                                local impact = myPoint + travel + 0.03
                                -- мой удар ложится ПОСЛЕ его снаряда и в окно до смерти крипа
                                if impact >= eta - 0.06 and impact <= eta + 1.1 then
                                    if H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                                        State.prepTarget = c
                                        State.prepTargetTime = now
                                        State.snipeCooldown = now + 0.3
                                        if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK
                                            or bot:GetAttackTarget() ~= c then
                                            bot:Action_AttackUnit(c, true)
                                            H.ClearMoveCache()
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function H.HandleFleePunishRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local now = GameTime()
    if now >= (State.fleeUntil or 0) or now < (State.commitKillUntil or 0) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist < 550 or dist > 1250 then return false end
    -- он смотрит на нас - не провоцируем ответный стак
    local okF, facingUs = pcall(function() return enemyHero:IsFacingLocation(bot:GetLocation(), 60) end)
    if okF and facingUs then return false end
    -- он может успеть вернуться к нам на полосу рейза - не рискуем
    if K.CanCatch(bot, enemyHero, 450, 2.0) then return false end
    if bot:GetMana() < 75 then return false end
    if GameTime() - (State.lastRazeOrderTime or -10) < 1.2 then return false end
    for i = 1, 3 do
        local ab = H.GetRazeAbilityByLabel(bot, K.LABELS[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                State.fleeUntil = now + 1.5
                return true
            end
        end
    end
    return false
end

function H.HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- v2.6: чистый бег - без разворотов на врага
    if GameTime() < (State.fleeUntil or 0) and GameTime() >= (State.commitKillUntil or 0) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if H.CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

function H.GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end

function H.GetPotentialRecallManaPct(bot)
    local mana = bot:GetMana() or 0
    local maxMana = math.max(1, bot:GetMaxMana() or 1)
    local bonus = 0
    if U.HasItem(bot, "item_enchanted_mango") then
        bonus = bonus + 100
    end
    local charges = U.GetStickCharges(bot)
    if charges > 0 then
        bonus = bonus + charges * 15
    end
    if bot:HasModifier("modifier_clarity_potion") or U.GetActiveItemByName(bot, "item_clarity") then
        bonus = math.max(bonus, 100)
    end
    return math.min(maxMana, mana + bonus) / maxMana
end

function H.ShouldGoToFountain(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        return true, "HP"
    end
    return false, nil
end

function H.ShouldAbortFountainRecall(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= hpCritical then
        return true
    end
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    return potentialHpPct >= hpCritical
end

function H.IsAtFountain(bot)
    local fountain = P.GetFountain(bot)
    local radius = (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

function H.IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = bot:GetMaxHealth()
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_HP_PCT) or 0.98
    local waitManaPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_MANA_PCT) or 0.98
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

function H.HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        if not H.IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and H.ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if H.IsAtFountain(bot) then
            if H.IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            H.SmartMove(bot, fountain, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if H.IsInDangerForRegen(bot, 900) then return false end
    local should, reason = H.ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        H.ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        H.SmartMove(bot, fountain, 80)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local farFromT1 = GetUnitToLocationDistance(bot, t1) > C.TP.RETURN_DISTANCE_FROM_T1
    local nearFount = GetUnitToLocationDistance(bot, fountain) < (C.TP.FOUNTAIN_RADIUS or 400)
    -- v2.6: стартовый свиток не тратим на "ТП в линию" в первые 20 с игры (идём пешком),
    -- дальше работают needsTP (смерть/фонтан) и возврат с фонтана
    if not (State.needsTP or (nearFount and farFromT1 and GameTime() > 20)) then return false end
    if not H.IsFountainFullyRestored(bot) then
        State.actionTaken = true
        return true
    end
    local tp = U.GetTPScroll(bot)
    if not tp then
        -- v2.7: выделенный слот ТП (15/16) может быть невидим для GetItemInSlot. Прежде чем
        -- ПОКУПАТЬ новый свиток (у героя он уже есть!) - пробуем переложить его в слот 0.
        local step = State.tpSwapStep or 0
        if step < 2 and GameTime() - (State.tpSwapAt or -100) > 0.5 then
            State.tpSwapStep = step + 1
            State.tpSwapAt = GameTime()
            pcall(function() bot:ActionImmediate_SwapItems(15 + step, 0) end)
            State.actionTaken = true
            return true
        end
        if bot:GetGold() >= 100 and GameTime() - (State.tpBuyTime or -100) > 2.0 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            State.tpBuyTime = GameTime()
            return true
        end
        if GameTime() - (State.tpBuyTime or -100) <= 2.0 then return true end
        State.needsTP = false
        return false
    end
    State.tpSwapStep = 0
    -- Приказ на ТП уже отдан: не переотдаём (переотдача сбрасывает канал телепорта)
    if GameTime() - (State.tpOrderTime or -100) < 4.5 then
        State.actionTaken = true
        return true
    end
    local castOk, castable = pcall(function() return tp:IsFullyCastable() end)
    if castOk and castable then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.tpOrderTime = GameTime()
        State.needsTP = false
        State.actionTaken = true
        return true
    end
    -- свиток на перезарядке: ждём до 10 с, потом идём пешком
    local cdOk, cd = pcall(tp.GetCooldownTimeRemaining, tp)
    if cdOk and type(cd) == "number" and cd > 0 and cd <= 10 then
        State.actionTaken = true
        return true
    end
    State.needsTP = false
    return false
end

-- Оборонительная поза "я слабее" (гистерезис). Критерий - K.Race: проекция размена на 6 с
-- (бурст + авто-атаки + пул HP + башни), а не только рейзы. Пока в обороне: не отвечаем на его
-- авто-атаки без поддержки крипов/башни, не харасим, не лезем за спорными ласт-хитами,
-- стоим за своими крипами (PASSIVE-позиция), лечимся раньше.
function H.UpdateDefensive(bot, s, race)
    local now = s.now or GameTime()
    local cfg = C.DEFENSE or {}
    if not race or not race.valid then
        if not s.enemyAlive then State.defensive = false end
        return State.defensive
    end
    if not State.defensive then
        if race.weaker then
            State.defensive = true
            State.defensiveSince = now
        end
    else
        local held = now - (State.defensiveSince or 0)
        if not race.weaker and race.edgeLong > -(cfg.EXIT_EDGE or 40) and held >= (cfg.MIN_HOLD_SEC or 2.0) then
            State.defensive = false
        end
    end
    return State.defensive
end

-- Поддержка в драке: мои крипы бьют его / он под моей башней.
function H.HasTradeSupport(race)
    local cfg = C.DEFENSE or {}
    if (State.enemyAggroCount or 0) >= (cfg.SUPPORT_CREEPS or 2) then return true end
    if race and race.valid and (race.myTowerOnHim or 0) > 0 then return true end
    return false
end

-- Можно ли потратить 75 маны на харас-рейз (не CS, не добивание): резерв зависит от уровня.
-- followUp = на враге свежий стак и он ещё в досягаемости: второй/третий рейз добивает стак
-- (бонус +35/50/65/80 за стак, он не отвечает) - резерв маны к нему не применяем.
function H.HarassManaOK(bot, race, followUp)
    local mana = H.GetPotentialCombatMana(bot)
    if mana < 75 then return false end
    if race and race.valid and race.canKillSoon then return true end
    if State.hunting then return true end -- v2.5: охота: мана на 1 рейз (+манго) - этого достаточно
    local cfg = C.MANA or {}
    local lvl = bot:GetLevel() or 1
    if followUp then
        -- v2.3: на L1-L2 цепочка "рейз + добивочный по стаку" ограничена резервом 130 (иначе при
        -- исправленном наведении бот выкидывал 3 рейза подряд и оставался с 66 маны на минуту)
        -- v2.4: исключение - враг сам подошёл вплотную и получил ближний рейз: добиваем цепочкой
        -- до 3 рейзов (ближний -> средний -> дальний по уходящему), резерв маны не держим.
        if GameTime() < (State.nearChainUntil or 0) then return true end
        local keep = cfg.FOLLOWUP_KEEP or 60
        if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then keep = cfg.FOLLOWUP_KEEP_L2 or 130 end
        return (mana - 75) >= keep
    end
    local reserve = cfg.RESERVE_FOR_PRESSURE or 75
    if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then
        reserve = cfg.EARLY_RESERVE_L2 or 150
    elseif lvl <= (cfg.EARLY_LEVEL_L4 or 4) then
        reserve = cfg.EARLY_RESERVE_L4 or 112
    end
    return (mana - 75) >= reserve
end

-- "Добивание стака": на враге свежий стак рейза (остаток >= FOLLOWUP_MIN_REMAIN) и он в пределах
-- досягаемости полос (с учётом его движения за время каста).
function H.IsRazeFollowUp(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    local stacks, rem = U.GetShadowrazeDebuff(enemyHero)
    if (stacks or 0) <= 0 then return false end
    if (rem or 0) < (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then return false end
    local pred = U.PredictPosition(enemyHero, C.RAZE.PREDICT_DELAY)
    local d = GetUnitToLocationDistance(bot, pred or enemyHero:GetLocation())
    return d <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 60
end

-- Вражеская Т1 "занята" крипом: её текущая цель - не герой, живая, с запасом HP на >= 2 выстрела.
-- Башня не переключается на героя, пока цель жива и никто не бьёт героя с руки (рейз агро не даёт).
function H.TowerLockedOnCreep(t1)
    if not t1 then return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false end
    if t1.CanBeSeen and not t1:CanBeSeen() then return false end
    local okT, tgt = pcall(t1.GetAttackTarget, t1)
    if not okT or not tgt or not U.CanQuery(tgt) then return false end
    if tgt.IsHero and tgt:IsHero() then return false end
    local okD, dmg = pcall(t1.GetAttackDamage, t1)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then dmg = 100 end
    return (tgt:GetHealth() or 0) >= dmg * 2
end

-- Покупка расходника из боевого кода: есть в магазине, не чаще cooldown, билд не разоряем.
function H.ConsumableBuyOK(bot, itemName, cost, lastTime, cooldown)
    local now = GameTime()
    if now < (lastTime or -1000) + (cooldown or 60) then return false end
    if type(GetItemStockCount) == "function" then
        local ok, n = pcall(GetItemStockCount, itemName)
        if ok and type(n) == "number" and n <= 0 then return false end
    end
    local keep = (C.CONSUMABLE_BUY and C.CONSUMABLE_BUY.KEEP_GOLD_FOR_BUILD) or 210
    local gold = bot:GetGold() or 0
    if gold - cost < keep then return false end
    return true
end

-- v2.4: true = политика L1-L2 запрещает инициировать рейз сейчас (см. ShouldTryRazePressure).
function H.EarlyRazePolicyBlocks(bot, enemyHero)
    local cfg = C.RAZE or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    if razeLvl >= (cfg.AGGRO_MIN_RAZE_LEVEL or 2) then return false end
    if not U.CanQuery(enemyHero) then return true end
    -- зеркало / ответ: он кастовал рейз (попал или промахнулся) в последние MIRROR_WINDOW с
    local E = K._enemy
    if E and E.lastAnyCastAt and (GameTime() - E.lastAnyCastAt) <= (cfg.MIRROR_WINDOW or 2.5) then return false end
    if U.HasEnemyMissedRazeRecently() then return false end
    -- он подошёл вплотную: с ближней полосы начинается цепочка до 3 рейзов
    local pred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT) or enemyHero:GetLocation()
    local d = GetUnitToLocationDistance(bot, pred)
    local dNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if math.min(d, dNow) <= (cfg.EARLY_CHAIN_DIST or 360) then return false end
    -- открытое окно цепочки (он уже получил ближний рейз и уходит)
    if GameTime() < (State.nearChainUntil or 0) then return false end
    return true
end

function H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if not U.CanQuery(enemyHero) then return false, current_mode end
    local intent = State.intent
    if intent == I.RETREAT then return false, current_mode end
    -- Резерв маны: давим рейзами, только если после каста останется мана ещё на один
    -- (кроме случаев, когда враг не может ответить или мы его убиваем).
    local R = K._race
    local killing = R and R.valid and (R.canKillSoon or State.hunting) -- v2.5: охота = добивание
    local followUp = H.IsRazeFollowUp(bot, enemyHero)
    -- v2.8: "бесплатное давление": у врага НЕТ доступного рейза (кулдаун или мана), а мы
    -- в размене впереди - рейзуем без резерва маны. Раньше резерв (112-150) держал бота
    -- на одних тычках, хотя враг ответить рейзом не мог ("у меня 1 койл, у него 0 - бей!").
    local freePressure = R and R.valid and (R.enRazesSoon or 0) == 0 and R.edge >= 0
        and bot:GetMana() >= 75
    -- Мана: резерв по уровню (на 1-2 уровне "безобидный" враг - не повод уйти в ноль: мана нужна
    -- на ласт-хиты и ответ, а он просто отрегенит 64 урона). Добивание стака - без резерва.
    if not killing and not freePressure and not H.HarassManaOK(bot, R, followUp) then
        return false, current_mode
    end
    -- v2.4: политика рейзов с 1 очком (герой L1-L2): НЕ инициируем размен издалека - 85 урона он
    -- отрегенит/съест манго, а 75 маны (четверть пула) потеряны. Рейзим только: (а) зеркалом/ответом
    -- на его каст, (б) когда он сам подошёл вплотную (цепочка ближний->средний->дальний),
    -- (в) добивая стак / убивая. С 2 очков в рейзе (обычно L3) - агрессия как раньше.
    if not killing and not followUp and H.EarlyRazePolicyBlocks(bot, enemyHero) then
        return false, current_mode
    end
    -- Оборона: рейзим его только с поддержкой (крипы/башня бьют его), на добивание, или
    -- добивая стак по УХОДЯЩЕМУ врагу (он не отвечает, стак бесплатный)
    if State.defensive and not killing and not H.HasTradeSupport(R) then
        if not (followUp and K.IsEnemyMovingAway(bot, enemyHero)) then
            return false, current_mode
        end
    end
    if followUp then return true, "AGGRESSIVE" end
    if intent == I.ALLIN or intent == I.TRADE or intent == I.ZONE then return true, "AGGRESSIVE" end
    if intent == I.PUSH and R and R.valid and R.edge >= 0 then return true, "AGGRESSIVE" end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and H.GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or H.GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

function H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if not U.CanQuery(enemyHero) then return false end
    if State.defensive and not H.HasTradeSupport(K._race) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

function H.GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

function H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

function H.IsDryVsEnemyRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local myHasResource = H.GetPotentialCombatMana(bot) >= 75
    if myHasResource then return false end
    local enemyHasResource = enemyHero:GetMana() >= 75 or U.HasItem(enemyHero, "item_enchanted_mango") or U.HasItem(enemyHero, "item_magic_wand") or U.HasItem(enemyHero, "item_magic_stick")
    if not enemyHasResource then return false end
    return true
end

function H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    -- v2.5: харас-рейз - с резервом маны по уровню (как любое давление)
    if not H.HarassManaOK(bot, K._race) then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            -- v2.5: это рейз "2 в 1" (крип + герой): герой должен накрываться робастно
                            -- (и сейчас, и через каст), иначе это просто 75 маны за одного крипа, а полоса
                            -- уходит в кд как раз к его подходу
                            local heroErrAim = U.RobustRazeErrors(bot, enemyHero, data.center, C.RAZE.CAST_POINT)
                            local heroCovered = heroErrAim <= (C.RAZE.HIT_RADIUS - 60)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS and heroCovered then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if H.CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- v2.6: экстренные расходники ДО отступления/салвов: палочка/faerie, когда почти умерли,
-- манго - на добивание (рейз решает бой). Раньше они были в HandleItemsAndConsumables
-- в конце тика - при отходе тик заканчивался раньше и faerie "не нажимался перед смертью".
function H.HandleEmergencyConsumables(bot, race)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.lastItemUseTime or 0) + 0.3 then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local commitKill = GameTime() < (State.commitKillUntil or 0)
    local heLethalSoon = race and race.valid and race.heCanKillSoon or false
    if hpPct < 0.10 then
        local stickItem = H.GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    if hpPct < 0.20 or (heLethalSoon and hpPct < 0.35) or (commitKill and hpPct < 0.40) then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    -- манго на добивание: пусть рейз решит бой прямо сейчас
    if commitKill and bot:GetMana() < 75 and (bot:GetMana() + U.GetMangoMana(bot)) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    return false
end

function H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    U.ManageInventorySlots(bot)
    -- Отдали приказ съесть дерево: держим позицию до появления modifier_tango_heal (до 1 с)
    if State.tangoCastAt > 0 and (GameTime() - State.tangoCastAt) < 1.0 then
        if bot:HasModifier("modifier_tango_heal") then
            H.ClearTangoState()
            State.tangoFails = 0
        else
            State.actionTaken = true
            return true
        end
    end
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    -- (v2.6: палочка/faerie переехали в HandleEmergencyConsumables - в начало тика)
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    local tcfg = C.TANGO or {}
    local missingHp = bot:GetMaxHealth() - bot:GetHealth()
    local wantTango = hpPct < (tcfg.USE_HP_PCT or 0.80) and missingHp >= (tcfg.MIN_MISSING_HP or 100)
    -- в активной драке (TRADE/ALLIN) не ходим к деревьям, пока HP выше 60%; в ZONE - едим при < 60%
    local intent = State.intent
    if (intent == "TRADE" or intent == "ALLIN") and hpPct >= 0.60 then wantTango = false end
    if intent == "ZONE" and hpPct >= 0.60 then wantTango = false end
    if intent == "RETREAT" then wantTango = false end
    -- "ценный крип под ударом" задерживает танго только при HP >= 50%
    if hpPct < 0.50 then isHighValueBeingAttacked = false end
    if bot:HasModifier("modifier_tango_heal") then
        H.ClearTangoState()
        wantTango = false
    end

    if wantTango and not isHighValueBeingAttacked then
        local tango = U.GetActiveItemByName(bot, "item_tango")
        if tango then
            local now = GameTime()
            -- Уже отдали приказ съесть дерево: ждём появления modifier_tango_heal, не уходя от дерева.
            -- Иначе следующий обработчик уводит бота от дерева, и приказ "съесть" срывается (петля).
            if State.tangoCastAt > 0 and (now - State.tangoCastAt) < 1.0 then
                State.actionTaken = true
                return true
            end
            if State.tangoCastAt > 0 then
                -- приказ не сработал за 1 с: пробуем ещё раз, после двух неудач - другое дерево
                State.tangoFails = (State.tangoFails or 0) + 1
                State.tangoCastAt = 0
                if State.tangoFails >= 2 then
                    State.tangoBadTree = State.tangoTree
                    State.tangoBadTreeTime = now
                    State.tangoFails = 0
                    H.ClearTangoState()
                end
            end
            local tree, treeLoc = H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
            if tree and treeLoc then
                local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                if distToTree > 165 then
                    H.SmartMove(bot, treeLoc, 40)
                    return true
                end
                bot:Action_UseAbilityOnTree(tango, tree)
                State.lastItemUseTime = now
                State.tangoCastAt = now
                State.actionTaken = true
                return true
            end
        end
    elseif not wantTango then
        H.ClearTangoState()
    end

    return false
end

function H.ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

function H.HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if H.IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        else
            -- HP восстановилось по дороге (реген/танго/сальва): аварийный отход окончен. Иначе
            -- "FOUNTAIN" висел бы в State и при следующем проседании HP < 50% принудительно
            -- гнал бы на фонтан (committedFountain) без реальной причины.
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
        end
        return false
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and (GameTime() - State.emergencyRetreatStartTime) >= 5.0
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        H.BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            H.SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    H.BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

function H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if U.CanQuery(c) and c:GetAttackTarget() == bot then -- v2.3: крип в тумане -> не опрашиваем
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if H.HasEnemyProjectileIncoming(bot) then
            local safeLoc = H.GetSalveSafeRetreatLocation(bot, nil)
            H.BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleAutoBuySalveInsteadOfFountain(bot)
    local cfg = C.SALVE_AUTOBUY or { HP_PCT_THRESHOLD = 0.40, MIN_GOLD = 110, BUY_COOLDOWN = 8.0 }
    if State.goingToFountain then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct > (cfg.HP_PCT_THRESHOLD or 0.40) then return false end
    if U.HasItem(bot, "item_flask") then return false end
    local stashHasFlask = false
    for i = 9, 14 do
        local it = bot:GetItemInSlot(i)
        if it and it:GetName() == "item_flask" then
            stashHasFlask = true
            break
        end
    end
    if stashHasFlask then return false end
    if (bot:GetGold() or 0) < (cfg.MIN_GOLD or 110) then return false end
    local now = GameTime()
    if now < (State._lastSalveAutoBuyTime or 0) + math.max(cfg.BUY_COOLDOWN or 8.0, 20.0) then
        return false
    end
    if type(GetItemStockCount) == "function" then
        local ok, n = pcall(GetItemStockCount, "item_flask")
        if ok and type(n) == "number" and n <= 0 then return false end
    end
    bot:ActionImmediate_PurchaseItem("item_flask")
    State._lastSalveAutoBuyTime = now
    return false
end

function H.HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        return true
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        H.BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

function H.HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if not H.IsDryVsEnemyRaze(bot, enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- v2.3: у своей Т1 не отступаем дальше
    if State.actionTaken then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midDangerRadius = math.max(C.RAZE.STRICT_RADIUS, 210)
    if math.abs(dist - C.RAZE.MID_CENTER) > midDangerRadius then return false end
    -- v2.3: короткий выход за край полосы (раньше ~1000 к фонтану -> возврат за крипом -> снова страх)
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero)
    H.BeginForcedRetreat(bot, retreatLoc, 0.75)
    return true
end

function H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        H.SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- v2.5: со стаком на мне к врагу НЕ подходим (ближняя полоса = его удар с руки + ближний рейз
    -- с бонусом); "держать дистанцию ответа" только если уже вплотную (отойти до 215)
    if dist > maxDist then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

function H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end

    return H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

function H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local isAggressive = U.IsAggressivePlaystyle(bot, enemyHero, allyCreepsData, enemyCreepsData)
    if isAggressive then
        local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
        if active and hitLabel then
            local targetCenter = U.GetRazeCenterByLabel(hitLabel)
            if targetCenter then
                local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
                if setupPos then
                    if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                        return true
                    end
                end
            end
        end
    end

    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or not hitLabel then return false end
    local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
    if eStacks > 0 and eRem > C.RAZE.EXTEND_AT then
        local targetCenter = U.GetRazeCenterByLabel(hitLabel)
        if targetCenter then
            local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
            if setupPos then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
        return false
    end

    local ability = H.GetRazeAbilityByLabel(bot, hitLabel)
    if not ability or not U.IsRazeAbilityCastable(bot, ability) then return false end

    local willHit, _, predicted = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
    if not willHit then
        local targetCenter = U.GetRazeCenterByLabel(hitLabel)
        if targetCenter then
            local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
            if setupPos then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
        return false
    end

    local actionType = "TURN"
    if U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST then
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, ability, actionType, predicted, enemyHero) then
        return true
    end
    return false
end

-- v2.5: мгновенное зеркало. Его рейз только что попал по нам (<= MIRROR_INSTANT_SEC): он стоит
-- в той же полосе с нашей стороны (симметрия) - отвечаем сразу, той же полосой (его копия в кд 9 с)
-- или любой, что накрывает робастно. Раньше ответ шёл после правила выхода из стака и блока
-- добивания, т.е. через 0.5-1 с, когда враг уже сместился ("медленно зеркалит").
-- Без сближения: только каст/доворот с места. Не зеркалим: его бурст сейчас летален; после его
-- следующего рейза останется < MIRROR_MIN_HP_LEFT; мы под его Т1 без крипа-щита.
H._mirrorOrder = { nil, nil, nil }
function H.HandleInstantMirrorRaze(bot, enemyHero, race, s)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- v2.7: во время бега отвечать МОЖНО (мгновенный ответ на его попавший в нас рейз) -
    -- это осознанное "повернуться, каст, снова бег", а не дёрганье (как было до v2.6)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local age = U.GetRecentEnemyRazeHitAge(enemyHero)
    if age > ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then return false end
    -- один ответ на одно попадание (ответ из уклонения / свой рейз 1.2 с назад - уже ответили;
    -- дальше работает обычное добивание стака)
    if (GameTime() - (State.lastRazeOrderTime or -10)) < 1.2 then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    local canKillNow = race and race.valid and race.canKillNow
    if race and race.valid and race.heCanKillNow and not canKillNow then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
    if not canKillNow and (bot:GetHealth() - oneRaze) < ((C.RAZE and C.RAZE.MIRROR_MIN_HP_LEFT) or 110) then
        return false
    end
    local underT1 = H.IsBotUnderEnemyT1(bot, s and s.enemyTowers or {})
    if underT1 and not H.TowerLockedOnCreep(s and s.enemyT1) then return false end
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
        return false
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemyHero)
    local order = H._mirrorOrder
    local n = 0
    if hitLabel then n = n + 1; order[n] = hitLabel end
    for i = 1, 3 do
        if K.LABELS[i] ~= hitLabel then n = n + 1; order[n] = K.LABELS[i] end
    end
    for i = 1, n do
        local ab = H.GetRazeAbilityByLabel(bot, order[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                if U.DEBUG then print(string.format("[SF-BOT] instant mirror %s (%s) age=%.2f", order[i], actionType, age)) end
                return true
            end
        end
    end
    return false
end

function H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            -- v2.5: через общий CastOrTurnRaze (проверка разворота + шаг доворота, а не ход к врагу)
            local actionType = H.RazeFacingOK(bot, predicted) and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    -- v2.4: резерв маны для ближнего наказания снят (v2.3 гейтил его резервом 130: с 141 маны бот
    -- молча стоял в ближней полосе и получал стаки). Враг сам подошёл вплотную - это лучший момент
    -- для размена: ближний рейз сейчас, средний/дальний - по уходящему. Нужны только 75 маны.
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    -- v2.2: робастно - ближний круг должен накрыть врага и сейчас, и через время каста
    -- (уходящего из ближней полосы врага не "наказываем" рейзом в пустоту)
    -- Запас от края ближнего круга >= 100 u: стоящий у края враг (380-450) успевает выйти из
    -- круга за время каста, едва начав движение; такого бьёт средний рейз (через GetBestRaze).
    if K.IsEnemyMovingAway(bot, enemyHero) then return false end
    local errAim, errFacing, predicted = U.RobustRazeErrors(bot, enemyHero, C.RAZE.NEAR_CENTER, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - 100
    if errAim > limit then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if errFacing <= limit then -- v2.3: тот же порог, что у кандидата (без мёртвой зоны TURN)
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        if actionType == "CAST" then
            -- v2.4: окно цепочки: следующие ~5 с добивочные рейзы по его стаку идут без резерва маны
            State.nearChainUntil = GameTime() + ((C.RAZE and C.RAZE.NEAR_CHAIN_WINDOW) or 5.0)
        end
        return true
    end
    return false
end

function H.HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- v2.3: у своей Т1 не отступаем дальше
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- v2.3: короткий выход за край полосы
    H.BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

-- v2.3: активен ли какой-либо "страх средней полосы" (те же условия, что у трёх обработчиков ниже,
-- без проверки дистанции). Флаг U._midFear делает минимальную дистанцию до врага проактивной.
function H.MidRazeFearActive(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not U.EnemyHasRaze(enemyHero) then return false end
    -- у своей Т1 дальше не отходим: башня его накажет, а отход за башню = потеря линии
    if H.IsNearOwnT1(bot, 400) then return false end
    if State.enemyReachedLevel2First and bot:GetLevel() < 2 then return true end
    if H.IsDryVsEnemyRaze(bot, enemyHero) then return true end
    if U.ShouldFearBootsMidRaze(bot, enemyHero) and not U.IsInEnemyRazeKillThreat(bot, enemyHero)
        and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
        return true
    end
    return false
end

function H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if not State.enemyReachedLevel2First then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- v2.3: у своей Т1 не отступаем дальше
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- v2.3: короткий выход за край полосы
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    if H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return true end
    local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    H.BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

function H.HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- v2.3: удар по герою в радиусе его Т1 переводит башню на нас: только с запасом HP
    -- (>= 40 % и >= 3 выстрела башни) и не сразу после выхода из-под башни
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 then
        local hp = bot:GetHealth()
        if H.TowerBurnActive() or hp < bot:GetMaxHealth() * 0.40 or hp < 300 then return false end
    end
    if dist <= attackRange then
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        State.commitKillUntil = GameTime() + 2.5
        return true
    end
    if dist <= attackRange + 300 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 250)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not canKill then return false end
    -- v2.6: не срывать замах УДАРА, который и так его убивает
    if H.IsHeroAttackWindupLocked(bot) then
        local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        if oneShot then return false end
    end
    local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            U.SwitchTreadsIfNeeded(bot, 1)
            bot:Action_UseAbility(ability)
            H.StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            H.ClearMoveCache()
            -- v2.6: обязательство "добить": ближайшие секунды не убегаем и не дёргаемся
            State.commitKillUntil = GameTime() + 2.5
            return true
        else
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local stepLoc = botLoc + dir * math.min(15, U.DistanceBetweenLocations(botLoc, predLoc))
            H.SmartMove(bot, stepLoc, 15)
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    return false
end

function H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.5)
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local R = K._race

    -- Я слабее (уровень/души/предметы/HP): размен ударами с руки проигран заранее. Не отвечаем
    -- без поддержки (мои крипы/башня бьют его) - выходим из его радиуса атаки в сторону своих
    -- крипов/башни. Преследуя нас с ударами, он теряет дистанцию (каждый удар = 0.5 с стоя),
    -- а у моих крипов его атака по герою вызывает агро.
    if State.defensive and not H.HasTradeSupport(R) and not (R and R.valid and R.canKillSoon) then
        local enRange = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.KITE_PAD) or 140)
        if dist <= enRange then
            local botLoc = bot:GetLocation()
            local eLoc = enemyHero:GetLocation()
            local away = botLoc - eLoc
            if dist < 1 then away = P.GetT1Close(bot) - botLoc end
            away = away:Normalized()
            local toHome = (P.GetT1Close(bot) - botLoc):Normalized()
            local need = (enRange - dist) + 80
            local target = botLoc + (away * 0.6 + toHome * 0.4):Normalized() * need
            target = H.GetSafeApproach(bot, target, enemyTowers, allyCreeps)
            H.SmartMove(bot, target, 60)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < 0.25 then return false end

    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    H.IssueHeroAttack(bot, enemyHero)
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end


-------------------------------------------------------------------------------
-- v2: уклонение от рейза врага (любая полоса), липкое танго, зонинг, пуш, намерения
-------------------------------------------------------------------------------

-- Уклонение: враг в фазе каста рейза, мы внутри его круга -> выходим из круга напрямую
-- (Action_MoveDirectly), если успеваем; иначе - контр-рейз (размен), если его рейз не летален.
function H.HandleEnemyRazeDodge(bot, enemyHero)
    local now = GameTime()
    local label, elapsed, remaining = K.EnemyPhase()
    if State.dodgeLoc and now < State.dodgeUntil then
        -- v2.5: во время уклонения продолжаем смотреть на его каст: он может ОТМЕНИТЬ рейз
        -- (мы вышли из круга) и тут же кастовать другую полосу - раньше мы 0.6 с слепо бежали по
        -- старой точке и получали новый рейз в упор ("медленно уворачивается").
        local E = K._enemy
        local newCast = label and (label ~= State.dodgeLabel
            or math.abs((E.phaseStart or -1) - (State.dodgePhaseStart or -2)) > 0.01)
        local cancelled = (not label) and (now - (State.dodgePhaseStart or -10)) < (C.RAZE.CAST_POINT - 0.05)
        if newCast then
            State.dodgeLoc = nil -- переоценка ниже
        elseif cancelled then
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        else
            bot:Action_MoveDirectly(State.dodgeLoc)
            State.lastMoveLoc = State.dodgeLoc
            State.lastMoveTime = now
            State.actionTaken = true
            return true
        end
    end
    State.dodgeLoc = nil
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not label then return false end
    local center = K.EnemyRazeCenter(enemyHero, label)
    local botLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(botLoc, center)
    local R = C.RAZE.HIT_RADIUS
    if dFromCenter > R + 40 then return false end

    local dmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myHp = bot:GetHealth()
    local lethal = dmg >= myHp
    local ms = bot:GetCurrentMovementSpeed() or 305
    local selfCasting = bot:IsUsingAbility() or bot:IsChanneling() or (State.aimingRaze ~= nil)

    local dir
    if dFromCenter < 1 then
        dir = (botLoc - enemyHero:GetLocation()):Normalized()
    else
        dir = (botLoc - center):Normalized()
    end
    -- v2.3: запас за краем круга 45 u (было 70): рейз бьёт по позиции юнита в радиусе 250, лишние
    -- 25 u запаса делали уклонение "невозможным" там, где его хватало впритык (ближний рейз)
    local escapeLoc = center + dir * (R + 45)
    local need = (R + 45) - dFromCenter
    -- v2.5: честное время уклонения: минус разворот (0.03 * угол(рад) / 0.9: 180 градусов ~0.105 с)
    -- и задержка приказа. Неудавшееся уклонение = получили рейз И не ответили; при сомнении лучше ответ.
    local turnAng = U.GetAngleDifference(bot, escapeLoc)
    local turnTime = 0.03 * math.rad(turnAng) / 0.9
    local canEscape = ((remaining - turnTime - 0.03) * ms * 0.95) >= need

    if canEscape and (not selfCasting or lethal) then
        if selfCasting then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        State.dodgeLoc = escapeLoc
        State.dodgeUntil = now + remaining + 0.08
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        bot:Action_MoveDirectly(escapeLoc)
        State.lastMoveLoc = escapeLoc
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- не убежать: отвечаем рейзом (любой полосой, которая попадает), если его рейз нас не убивает
    -- v2.6: но НЕ во время чистого бега - бегом занимаемся бегом (разворот = лишние удары/койл)
    if not selfCasting and not lethal and bot:GetMana() >= 75
        and not (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0)) then
        for i = 1, 3 do
            local ab = H.GetRazeAbilityByLabel(bot, K.LABELS[i])
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
                if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                    return true
                end
            end
        end
    end
    return false
end

-- Липкое дерево для танго: выбираем один раз и держим (COMMIT_TIME), пока не съели / не стало
-- опасно / не застряли. Фильтры: далеко от вражеской башни, не ближе к врагу, тот же уровень высоты.
function H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
    local now = GameTime()
    local cfg = C.TANGO or {}
    local botLoc = bot:GetLocation()
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil

    if State.tangoTree and State.tangoTreeLoc then
        local age = now - State.tangoChosenAt
        local d = U.DistanceBetweenLocations(botLoc, State.tangoTreeLoc)
        if d < State.tangoBestDist - 15 then
            State.tangoBestDist = d
            State.tangoProgressAt = now
        end
        local stuck = d > 165 and (now - (State.tangoProgressAt or State.tangoChosenAt)) > (cfg.STUCK_TIME or 4.0)
        local unsafe = enemyLoc and U.DistanceBetweenLocations(State.tangoTreeLoc, enemyLoc) < ((cfg.ENEMY_MIN_DIST or 650) - 150)
        if age <= (cfg.COMMIT_TIME or 8.0) and not stuck and not unsafe then
            return State.tangoTree, State.tangoTreeLoc
        end
        if stuck then
            State.tangoBadTree = State.tangoTree
            State.tangoBadTreeTime = now
        end
        State.tangoTree = nil
        State.tangoTreeLoc = nil
    end

    local trees = bot:GetNearbyTrees(cfg.SEARCH_RADIUS or 900)
    if not trees or #trees == 0 then return nil, nil end
    local myH = nil
    if type(GetHeightLevel) == "function" then myH = GetHeightLevel(botLoc) end
    local fountain = P.GetFountain(bot)

    local best, bestLoc, bestScore = nil, nil, math.huge
    for pass = 1, 2 do
        for _, tree in ipairs(trees) do
            local bad = (State.tangoBadTree == tree) and (now - State.tangoBadTreeTime) < 20
            if not bad then
                local loc = GetTreeLocation(tree)
                local ok = true
                for _, tower in pairs(enemyTowers or {}) do
                    if tower:IsAlive() and GetUnitToLocationDistance(tower, loc) < (cfg.TOWER_MIN_DIST or 1125) then
                        ok = false
                        break
                    end
                end
                if ok and enemyLoc and U.DistanceBetweenLocations(loc, enemyLoc) < (cfg.ENEMY_MIN_DIST or 650) then ok = false end
                if ok and pass == 1 and myH and GetHeightLevel(loc) ~= myH then ok = false end
                if ok then
                    local score = U.DistanceBetweenLocations(botLoc, loc)
                    score = score + U.DistanceBetweenLocations(fountain, loc) * 0.10
                    if enemyLoc then
                        score = score - math.min(400, U.DistanceBetweenLocations(loc, enemyLoc)) * 0.25
                    end
                    if score < bestScore then
                        bestScore, best, bestLoc = score, tree, loc
                    end
                end
            end
        end
        if best then break end
    end
    if best then
        State.tangoTree = best
        State.tangoTreeLoc = bestLoc
        State.tangoChosenAt = now
        State.tangoBestDist = math.huge
        State.tangoProgressAt = now
    end
    return best, bestLoc
end

function H.ClearTangoState()
    State.tangoTree = nil
    State.tangoTreeLoc = nil
    State.tangoCastAt = 0
end

-- Контекст + автомат намерений. Возвращает намерение.
-- v2.5 "Охота" (жалоба: +400 HP против врага с низким HP, а бот фармит). Идём добивать, когда:
-- рейз >= 2 очков, перевес по абсолютным HP >= HUNT_HP_EDGE, мои HP >= HUNT_MIN_HP_PCT, он не под
-- своей Т1, его бурст по мне со средней дистанции не опасен (запас HUNT_SAFETY_HP), мой бурст за
-- HUNT_HORIZON с подходом в среднюю полосу (рейзы, которые успеют откатиться; мана С манго;
-- 1-2 удара с руки) покрывает его HP, и он догоняем. Гистерезис: пока охотимся - пороги мягче.
function H.ComputeHunt(bot, s, race, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not race or not race.valid then return false end
    -- v2.6: он возвращается по ТП к Т1 (свежий, полный) - не залетаем
    if (State.enemyTPIncomingUntil or 0) > s.now then return false end
    local cfg = C.INTENT or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() < 2 then return false end
    local was = State.hunting and true or false
    local edgeNeed = (cfg.HUNT_HP_EDGE or 250) - (was and 60 or 0)
    if race.hpDiff < edgeNeed then return false end
    local myHp = race.myHp
    if (myHp / math.max(1, bot:GetMaxHealth())) < ((cfg.HUNT_MIN_HP_PCT or 0.40) - (was and 0.05 or 0)) then return false end
    if race.dist > ((cfg.HUNT_MAX_DIST or 1100) + (was and 150 or 0)) then return false end
    if race.heCanKillSoon then return false end
    local t1 = s and s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 760 then
            return false
        end
    end
    local dmg, n = K.MyHuntBurst(bot, enemyHero, cfg.HUNT_HORIZON or 4.0)
    if dmg < race.enHp + (was and -20 or 10) then return false end
    -- Его ответ за время моего добивания: столько же рейзов, сколько нужно мне (не больше его
    -- готовых по кд/мане с манго), по моим текущим стакам; удары с руки не считаем - он кастует.
    -- Полный его бурст за 2.5 с (3 рейза = ~970) здесь неуместен: он умирает раньше третьего.
    local hisReady = K.EnemyReadyRazeCount(enemyHero, 1.5, true)
    local hisN = math.min(math.max(n, 1), hisReady)
    local enBurst = K.EnemyRazeDamage(bot, enemyHero, hisN)
    if enBurst >= myHp - (cfg.HUNT_SAFETY_HP or 80) then return false end
    if not K.CanCatch(bot, enemyHero, C.RAZE.MID_CENTER + 200, 2.5) then return false end
    return true
end

function H.UpdateIntent(bot, s, race)
    local ctx = IntentCtx
    local enemyHero = s.enemy
    ctx.enemy = enemyHero ~= nil
    ctx.race = race
    ctx.myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    ctx.myRazes = K.MyReadyRazeCount(bot, true)
    ctx.healing = U.IsActivelyHealing(bot)
    ctx.enemyDist = s.enemyDist
    ctx.enemyAbsent = W.EnemyAbsent((C.INTENT and C.INTENT.ENEMY_ABSENT_SEC) or 5.0)
    -- Живой враг пропал из виду рядом с линией (хайграунд/деревья/туман) - он, скорее всего,
    -- караулит, а не ушёл. Не считаем его "отсутствующим" раньше 12 с.
    if ctx.enemyAbsent and s.enemyAlive and s.enemyLastLoc and s.enemyAbsentFor < 12.0 then
        if U.DistanceBetweenLocations(s.enemyLastLoc, bot:GetLocation()) < 1400 then
            ctx.enemyAbsent = false
        end
    end
    ctx.enemyDistToWave = enemyHero and LN.EnemyDistToAllyWave(enemyHero, s.allyCreeps) or 99999
    ctx.enemyUnderHisTower = false
    ctx.underEnemyTower = false
    local t1 = s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            if enemyHero then
                ctx.enemyUnderHisTower = U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 720
            end
            ctx.underEnemyTower = LN.TowerDanger(bot, t1, s.allyCreeps, nil) >= 2
        end
    end
    ctx.canCatch = enemyHero and K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER, 2.0) or false
    ctx.defensive = State.defensive and not H.HasTradeSupport(race)
    -- v2.6: он тпается к своей Т1 (канал виден / вернулся после смерти)
    ctx.enemyTPIncoming = (State.enemyTPIncomingUntil or 0) > s.now
    ctx.enemyT1Dist = 99999
    if t1 then
        local okT1, t1Loc = pcall(t1.GetLocation, t1)
        if okT1 and t1Loc then
            ctx.enemyT1Dist = U.DistanceBetweenLocations(bot:GetLocation(), t1Loc)
        end
    end
    ctx.hunt = H.ComputeHunt(bot, s, race, enemyHero)
    State.hunting = ctx.hunt
    local intent = I.Update(ctx, s.now)
    State.intent = intent
    if U.DEBUG and (s.now - State.lastIntentPrint) > 2.0 then
        State.lastIntentPrint = s.now
        print(string.format("[SF-BOT] intent=%s (%s) edge=%.0f myB=%.0f enB=%.0f dist=%.0f",
            intent, I.reason, race.valid and race.edge or 0, race.valid and race.myBurstSoon or 0,
            race.valid and race.enBurstSoon or 0, s.enemyDist))
    end
    return intent
end

-- Отступление по намерению RETREAT: выйти за пределы готовых полос врага в сторону своей Т1.
-- Если уже достаточно далеко - ничего не делаем (дальше работает фарм под башней).
function H.ExecuteRetreat(bot, enemyHero, race)
    -- v2.6: мы взяли обязательство добить - не убегаем
    if GameTime() < (State.commitKillUntil or 0) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local hp = bot:GetHealth()
    local critical = race.valid and race.enBurstNow >= hp
    H.BeginForcedRetreat(bot, safeLoc, critical and 1.0 or 0.6)
    return true
end

-- Зонинг: стоим между врагом и своей волной на HOLD_DIST (вне его near-полосы), бьём его
-- с руки, когда он в радиусе атаки; не покидаем волну; не стоим в его ГОТОВЫХ полосах.
function H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.ZONE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- 0) если он в моей кастуемой полосе и мана позволяет - рейз (давление) приоритетнее позиции
    local canPressure = H.ShouldTryRazePressure(bot, enemyHero, "AGGRESSIVE", 0)
    if canPressure and dist <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS then
        if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return true end
    end
    local hold = cfg.HOLD_DIST or 520
    -- не стоять в его готовой полосе: отодвигаем дистанцию за её край
    local minSafe = race.valid and race.minSafeDist or 0
    if minSafe > hold then hold = minSafe end
    -- удар с руки, если он в радиусе и это не заводит нас в его готовую полосу
    local attackRange = bot:GetAttackRange() + (cfg.ATTACK_RANGE_PAD or 40)
    if dist <= attackRange and dist >= minSafe - 30 then
        if H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) and not H.IsHeroAttackWindupLocked(bot) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end
    local pos = LN.ZonePosition(bot, enemyHero, allyCreeps, hold, cfg.MAX_FROM_WAVE or 520)
    if not pos then return false end
    -- если позиция требует сближения с убегающим врагом - не бежим за ним
    local dAfter = U.DistanceBetweenLocations(pos, enemyHero:GetLocation())
    if dAfter < dist - 60 and not K.CanCatch(bot, enemyHero, dAfter, 1.5) then
        return false
    end
    pos = H.GetSafeApproachLoose(bot, pos, enemyTowers or {}, allyCreeps or {})
    if GetUnitToLocationDistance(bot, pos) > 70 then
        return H.SmartMove(bot, pos, 45)
    end
    -- На месте: позицию держим (итоговое позиционирование не должно уводить бота), но
    -- управление отдаём дальше - предметы/регены должны отрабатывать.
    State.holdPos = true
    return false
end

-- Пуш: толкаем волну и бьём Т1 под щитом из крипов; ласт-хиты имеют приоритет (вызывается
-- только когда ближайшего ласт-хита нет). Враг рядом и занят волной - бить башню можно,
-- враг свободен и может рейзить - только крипов и только вне радиуса башни.
function H.ExecutePush(bot, enemyHero, race, s)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemyCreeps, allyCreeps, enemyTowers = s.enemyCreeps, s.allyCreeps, s.enemyTowers
    local t1 = s.enemyT1
    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local now = GameTime()

    -- 1) крипы врага рядом -> бьём "толстых" (низкое HP - зона ласт-хита, туда пуш-ударом не лезем)
    local pushCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
    -- текущая цель пуша просела до зоны ласт-хита: прекращаем непрерывную атаку по ней
    if bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK then
        local cur = bot:GetAttackTarget()
        if cur and U.CanQuery(cur) and not (cur.IsHero and cur:IsHero()) and not (cur.IsTower and cur:IsTower())
            and State.lhAttackTarget ~= cur and (cur:GetHealth() or 0) <= LN.PushHpFloor(bot, cur, allyCreeps) then
            if pushCreep == cur then pushCreep = nil end
            if not pushCreep then
                bot:Action_ClearActions(false)
                H.ClearMoveCache()
                State.actionTaken = true
                return true
            end
        end
    end
    if pushCreep then
        if H.IsSafeToAttack(bot, pushCreep:GetLocation(), enemyTowers, allyCreeps) then
            if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= pushCreep then
                bot:Action_AttackUnit(pushCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    -- 2) башня Т1: только под щитом (>= MIN_SHIELD крипов ближе к башне, чем я; башня не на мне)
    if t1 and t1:IsAlive() and myHpPct >= ((C.PUSH and C.PUSH.MIN_HP_PCT_TO_PUSH) or 0.50) then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            local botDist = U.DistanceBetweenLocations(bot:GetLocation(), tLoc)
            local enemyOk = true
            if enemyHero and U.CanQuery(enemyHero) then
                local busy = LN.EnemyBusyWithWave(bot, enemyHero)
                local far = GetUnitToLocationDistance(bot, enemyHero:GetLocation()) > 950
                local harmless = race.valid and (race.enRazesSoon == 0 or race.edge >= 200) and not race.heCanKillSoon
                enemyOk = busy or far or harmless
                -- враг свободен и может рейзить, а мы под башней без запаса - не стоим под ней
                if race.valid and race.heCanKillSoon then enemyOk = false end
            end
            local shieldOk = LN.CanHitTower(bot, t1, allyCreeps, (C.TOWER and C.TOWER.MIN_SHIELD_TO_HIT) or 2)
            if H.TowerBurnActive() then shieldOk = false end -- v2.3: после выхода из-под Т1 башню не бьём
            if enemyOk and shieldOk and botDist <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
                if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= t1 then
                    bot:Action_AttackUnit(t1, true)
                    H.ClearMoveCache()
                end
                State.actionTaken = true
                return true
            end
            -- 3) крипов нет / щита нет: ждём следующую волну вне радиуса башни
            if botDist <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 60 and not shieldOk then
                local wait = LN.SiegeWaitPoint(bot, t1)
                H.SmartMove(bot, wait, 60)
                return true
            end
            if not pushCreep and (not allyCreeps or #allyCreeps == 0) then
                local wait = LN.SiegeWaitPoint(bot, t1)
                if GetUnitToLocationDistance(bot, wait) > 150 then
                    H.SmartMove(bot, wait, 60)
                    return true
                end
                State.siegeWaitUntil = now + 1.0
                return false
            end
        end
    end

    -- 4) идём с волной вперёд (за передним крипом), если крипы есть
    local front = LN.FrontAllyCreep(bot, allyCreeps)
    if front then
        local fountain = P.GetFountain(bot)
        local dir = (fountain - front:GetLocation()):Normalized()
        local pos = front:GetLocation() + dir * 300
        pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
        -- v2.3: "идти с волной" никогда не заводит под Т1: без удара по башне (п.2) внутри её
        -- радиуса делать нечего (крипы умрут - башня переключится на нас). Держимся >= 800.
        if t1 and t1:IsAlive() then
            local okTL, tl = pcall(t1.GetLocation, t1)
            if okTL and tl then
                local keep = ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 20
                if U.DistanceBetweenLocations(pos, tl) < keep then
                    pos = tl + (pos - tl):Normalized() * keep
                end
            end
        end
        if GetUnitToLocationDistance(bot, pos) > 120 then
            return H.SmartMove(bot, pos, 60)
        end
        State.holdPos = true -- на месте за волной: не даём итоговому позиционированию увести назад
        return false
    end
    return false
end

function H.RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    State.actionTaken = false
    State.holdPos = false

    -- Снимок мира + трекер рейзов врага (каждый тик, до любых решений)
    local s = W.Update(bot)
    K.UpdateEnemyTracker(bot, s.enemy)
    H._enemyHeroNear = s.enemy -- v2.7: GetSafeApproach учитывает врага при заходе под башню
    -- v2.5: трекер попаданий/промахов его рейзов - до решений (мгновенное зеркало читает его)
    if s.enemy then U.UpdateEnemyRazeMissTracker(bot, s.enemy) end

    -- v2.6: видим его ТП-канал (item_tpscroll) / он только что вернулся после смерти -
    -- он будет у своей Т1 через ~3-6 с (см. intent: "enemy tp incoming")
    if s.enemy and U.IsEnemyTPChanneling(s.enemy) then
        State.enemyTPIncomingUntil = s.now + 3.0
    end
    if s.enemyAlive and State.enemyWasAlive == false then
        State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, s.now + 6.0)
    end
    State.enemyWasAlive = s.enemyAlive

    -- v2.6: идёт канал ТП - никаких приказов (любой приказ срывает телепорт на Т1)
    if bot:IsChanneling() then
        State.actionTaken = true
        return
    end

    if H.HandleActiveRazeValidation(bot) then return end

    -- v2.6: гарантированное добивание раньше уклона и всего остального: если можем убить
    -- его рейзом/ударом прямо сейчас - убиваем сразу, не откладывая на секунды
    if s.enemy then
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end

    -- Уклонение от рейза врага имеет приоритет даже над собственным кастом (если рейз летален)
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end

    if bot:IsUsingAbility() then return end

    if State.forcedRetreatLoc and GameTime() < (State.forcedRetreatUntil or 0) then
        -- v2.7: во время бега - только два осознанных действия вместо бега (не дёрганья!):
        -- 1) его рейз ТОЛЬКО ЧТО в нас попал - мгновенный ответ (повернуться, каст, снова бег);
        -- 2) он отвернулся и уходит - бесплатный рейз ему вслед (он не успевает вернуться и
        --    положить нам второй стак).
        local eh = H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            if U.GetRecentEnemyRazeHitAge(eh) <= ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then
                if H.HandleInstantMirrorRaze(bot, eh, K.Race(bot, eh, false, s), s) then
                    State.fleeUntil = GameTime() + 1.5
                    return
                end
            end
            if H.HandleFleePunishRaze(bot, eh) then return end
        end
        bot:Action_MoveToLocation(State.forcedRetreatLoc)
        State.lastMoveLoc = State.forcedRetreatLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return
    elseif State.forcedRetreatLoc then
        H.ClearForcedRetreat()
    end

    H.ProcessTelemetry(bot)
    H.LevelUpAbilities(bot)

    if not State.aimingRaze then
        local hpPct = bot:GetHealth() / bot:GetMaxHealth()
        if hpPct < 0.30 then
            U.SwitchTreadsIfNeeded(bot, 0)
        else
            U.SwitchTreadsIfNeeded(bot, 2)
        end
    end

    local enemyHero = s.enemy
    local earlyEnemyTowers = s.enemyTowers
    local earlyAllyCreeps = s.allyCreeps

    -- Гонка (абсолютные HP, доступные рейзы обеих сторон) и намерение на тик
    local race = K.Race(bot, enemyHero, false, s)
    H.UpdateDefensive(bot, s, race)
    local intent = H.UpdateIntent(bot, s, race)

    -- v2.5: идёт замах удара по герою - даём ему долететь (см. ShouldHoldForHeroWindup)
    H.UpdateAttackActivity(bot)
    if enemyHero and H.ShouldHoldForHeroWindup(bot, s, enemyHero, race) then
        State.actionTaken = true
        return
    end

    -- v2.6: экстренные расходники (faerie/палочка/манго на добивание) - сразу после замаха,
    -- до сальвов и отступлений
    if H.HandleEmergencyConsumables(bot, race) then return end

    if H.HandleActiveSalveSafety(bot, enemyHero) then return end
    if H.HandleEnemyNearRazeCounter(bot, enemyHero) then return end
    if enemyHero and H.HandleInstantMirrorRaze(bot, enemyHero, race, s) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    -- (v2.6: гарантированные добивания переехали вверх - до уклона и замаха)
    if H.HandleReturnTP(bot) then return end

    -- v2.3: защита от вражеской Т1 - раньше всего остального
    if H.HandleEnemyTowerSafety(bot, s, enemyHero) then return end

    if H.HandleEmergencyRetreat(bot, enemyHero) then return end

    -- Намерение RETREAT: выйти из готовых полос врага (его доступный бурст летален)
    if intent == I.RETREAT and enemyHero then
        if H.ExecuteRetreat(bot, enemyHero, race) then return end
    end

    if H.HandleForcedSalve(bot) then return end
    H.HandleAutoBuySalveInsteadOfFountain(bot)
    if H.HandleFountainRecall(bot) then return end

    -- v2.8: намерение всё ещё RETREAT, но мы уже на безопасной дистанции (ExecuteRetreat
    -- вернул false). Раньше управление проваливалось к ласт-хитам/prehit - те разворачивали
    -- бота к пачке крипов, враг догонял, снова бег - кривой зигзаг вместо ухода.
    -- Держим чистый шаг строго от врага, пока он рядом.
    if intent == I.RETREAT and enemyHero and U.CanQuery(enemyHero) and not State.actionTaken then
        local bLoc, eLoc = bot:GetLocation(), enemyHero:GetLocation()
        local d = U.DistanceBetweenLocations(bLoc, eLoc)
        if d < 1100 and d >= 1 then
            H.SmartMove(bot, bLoc + (bLoc - eLoc):Normalized() * 160, 60)
            return
        end
    end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_clarity_potion")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        isHealing = false
        H.ClearForcedRetreat()
    end

    local needsFlask = (myHpPct < 0.5 and flask and not isHealing)
    local needsClarity = (mpPct < 0.4 and clarity and not isHealing and not hasMango)

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if H.IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            H.BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if H.HasEnemyProjectileIncoming(bot) then
                local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
                H.BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            -- v2.3: списки из снимка мира (отфильтрованы через CanQuery - без крипов в тумане)
            local enemyCreepsNearby = s.enemyCreeps or {}
            local allyCreepsNearby = s.allyCreeps or {}
            if #enemyCreepsNearby == 0 and #allyCreepsNearby == 0 then
                local targetPos = bot:HasModifier("modifier_flask_healing") and P.GetT1Close(bot) or C.POSITIONS.MIDLANE_CENTER
                if GetUnitToLocationDistance(bot, targetPos) > 200 then
                    H.SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not H.IsInDangerForRegen(bot, dangerRange) then
                    H.SmartMove(bot, safeLoc, 60)
                end
            end
            return
        end
    end

    local enemyCreeps = s.enemyCreeps
    local allyCreeps = s.allyCreeps
    local enemyTowers = s.enemyTowers
    local allyTowers = s.allyTowers
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)
    -- v2.5: вражеский герой тоже бьёт крипов (добивает своих = денай, добивает моих). Его удар
    -- учитывается в прогнозе HP цели (GetAttackTarget() == цель): окно "безопасного" ласт-хита
    -- закрывается его ударом -> бьём раньше/сразу, а не ждём момент, который он забирает.
    if enemyHero and U.CanQuery(enemyHero) then
        table.insert(enemyAttackers, enemyHero)
        table.insert(allyAttackers, enemyHero)
    end
    local enemyNearWave = enemyHero ~= nil and s.enemyDist <= 1300

    U.UpdateAllyCreepHealthTracking(allyCreeps)


    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if State.defensive then current_mode = "PASSIVE" end
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if H.HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    U._midFear = (enemyHero ~= nil) and H.MidRazeFearActive(bot, enemyHero) or false
    if enemyHero and H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and H.HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    -- Стаки на мне: решение по доступному бурсту врага и абсолютным HP (а не "2 стака = бежим").
    -- Если его рейзы на кулдауне / нет маны / полоса недосягаема - продолжаем давить.
    if enemyHero then
        local shouldFear, fearLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
        if shouldFear and fearLoc then
            H.BeginForcedRetreat(bot, fearLoc, 0.80)
            return
        end
    end

    if enemyHero and H.HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not mustRetreatFromT1Soon and s.enemyT1 then
        -- щит ушёл (крипы убежали за врагом / умерли), а мы ещё в радиусе башни
        local okLoc, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, bot:GetLocation()) <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) then
            if LN.TowerDanger(bot, s.enemyT1, allyCreeps, nil) >= 2 then
                mustRetreatFromT1Soon = true
            end
        end
    end
    if mustRetreatFromT1Soon and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        -- v2.5: глиф ради выхода из-под башни НЕ тратим (случайный заход в радиус Т1 без добивания
        -- сжигал глиф на 5 минут) - просто выходим
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and H.GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            local Rr = K._race
            if Rr and Rr.valid then
                -- только РЕАЛЬНО доступные рейзы (кулдауны/мана), а не "два рейза по формуле"
                lethal = Rr.canKillSoon
            end
            if intent == I.RETREAT then lethal = false end
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (H.GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                -- его Т1 занята нашим крипом (>= 2 выстрела), HP >= 50%, его бурст не летален:
                -- рейзы под башней не вызывают агро - добивание разрешено
                local towerLockedSafe = isSafeChase and H.TowerLockedOnCreep(s.enemyT1)
                    and myHpPct >= 0.5 and not (Rr and Rr.valid and Rr.heCanKillSoon)
                    and not H.TowerBurnActive() -- v2.3
                if (canChase and isSafeChase) or normalSafe or glyphActive or towerLockedSafe then
                    if H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 450 then
            H.SmartMove(bot, wardLoc, 60)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            H.ClearMoveCache()
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    -- сколько МОИХ крипов бьют вражеского героя (поддержка в размене)
    local enemyAggroCount = 0
    if enemyHero and U.CanQuery(enemyHero) then
        for _, c in pairs(allyCreeps) do
            if U.CanQuery(c) and c:GetAttackTarget() == enemyHero then enemyAggroCount = enemyAggroCount + 1 end
        end
    end
    State.enemyAggroCount = enemyAggroCount
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    if GameTime() > State.deaggroTime then
        local should_deaggro = false
        if allyCreeps and #allyCreeps > 0 then
            -- v2.4: сброс агро только когда крипы РЕАЛЬНО бьют нас (>= 2 крипа, или 1 + урон, или
            -- дальний + урон). Старое условие "2 вражеских крипа ближе 350" срабатывало при любом
            -- ласт-хите рядом с волной: CLEAR + "атаковать своего крипа" + отход на 400 каждые 1.2 с ->
            -- потерянные ласт-хиты и дёрганье к башне.
            if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) or (hasRangedAggro and is_taking_damage) then
                should_deaggro = true
            end
        else
            if is_under_my_tower and bot:GetHealth() > 300 then
                if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) then
                    should_deaggro = true
                end
            else
                if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) or hasRangedAggro then
                    should_deaggro = true
                end
            end
        end
        if should_deaggro then
            bot:Action_ClearActions(false)
            H.ClearMoveCache()
            State.heroAttackTarget = nil
            State.heroAttackTime = 0
            local fountain = P.GetFountain(bot)
            if allyCreeps and #allyCreeps > 0 then
                local closestAlly = allyCreeps[1]
                local minDist2 = 9999
                for _, c in pairs(allyCreeps) do
                    local d = GetUnitToLocationDistance(bot, c:GetLocation())
                    if d < minDist2 then
                        minDist2 = d
                        closestAlly = c
                    end
                end
                local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 400
                bot:ActionQueue_AttackUnit(closestAlly, true)
                bot:ActionQueue_MoveToLocation(safe_pos)
                State.deaggroTime = GameTime() + 1.2
            else
                local kite_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 300
                bot:Action_MoveToLocation(kite_pos)
                State.deaggroTime = GameTime() + 0.6
            end
            return
        end
    end

    if GameTime() < State.aggroPullTime then
        if H.IsHeroAttackWindupLocked(bot) then return end
        if H.IsInHeroAttackAnimation(bot) then return end
        H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    -- Ласт-хит, ради которого надо зайти в его готовую полосу при невыгодном размене, не берём:
    -- иначе "подошёл за крипом - испугался - отошёл" по кругу, и каждый заход - его рейз в нас.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) then
        local fearMin = U.GetFearMinDist(bot, enemyHero)
        if fearMin > 0 then
            local eLoc = enemyHero:GetLocation()
            local cLoc = bestTarget:GetLocation()
            local botD = U.DistanceBetweenLocations(bot:GetLocation(), eLoc)
            local inRangeNow = GetUnitToLocationDistance(bot, cLoc) <= bot:GetAttackRange() + 20
            local creepD = U.DistanceBetweenLocations(cLoc, eLoc)
            if not (inRangeNow and botD >= fearMin - 40) and creepD < fearMin - bot:GetAttackRange() + 40 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- v2.3: не идём за крипом в точку, где его доступный бурст (готовые полосы + удары с руки)
    -- убивает меня: иначе "подошёл за крипом -> стало летально -> RETREAT на 1 с -> вернулся"
    -- по кругу каждые 2-3 с (дёрганье). Берём только то, что достаётся с нелетальной дистанции.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) and race.valid and not race.canKillNow then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        local atkD = U.DistanceBetweenLocations(atkPos, eLoc)
        local curD = U.DistanceBetweenLocations(bLoc, eLoc)
        if atkD < curD - 30 then
            local burst = K.EnemyBurstVs(bot, enemyHero, atkD, 2.5, false)
            if burst >= bot:GetHealth() - 20 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Оборона (я заметно слабее, поддержки крипов/башни нет): не заходим за ласт-хитом в его радиус
    -- атаки - каждый заход это 1-2 его удара (при 20 душах и брейсерах 70+ за удар), крип столько
    -- не стоит. Берём только то, что достаётся с позиции вне его радиуса, или пока он занят волной.
    local myHpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if bestTarget and enemyHero and State.defensive and race.valid and race.weakerSustained
        and U.CanQuery(enemyHero) and not H.HasTradeSupport(race) then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local hisReach = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.CONTEST_PAD) or 80)
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        -- v2.3: пропускаем крип только если он реально нас прессует (бьёт нас / бил за последние
        -- 3 с) или мы низко при его готовом рейзе. Просто "стоит у волны" - не повод отдавать
        -- весь фарм: раньше более слабый бот с таким правилом не брал ни одного крипа.
        local pressing = false
        if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then pressing = true end
        if not pressing and bot.WasRecentlyDamagedByHero then
            pressing = bot:WasRecentlyDamagedByHero(enemyHero, 3.0) and true or false
        end
        if not pressing and myHpPctNow <= 0.45 and (race.enRazesSoon or 0) >= 1 then
            pressing = true
        end
        if pressing and U.DistanceBetweenLocations(atkPos, eLoc) <= hisReach and not LN.EnemyBusyWithWave(bot, enemyHero) then
            bestTarget, isDeny = nil, false
        end
    end
    local bestTargetTime = 999
    if bestTarget then
        bestTargetTime = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
    end
    local lasthitImminent = bestTarget ~= nil and bestTargetTime >= 0 and bestTargetTime <= 1.2

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            H.SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                H.IssueHeroAttack(bot, enemyHero)
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and H.GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        -- продление 2 стаков - продолжение комбо: разрешаем при выгодном размене или по резерву маны
        local extendOk = (race.valid and race.edge >= 0 and bot:GetMana() >= 75) or H.HarassManaOK(bot, race)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 and extendOk and not State.defensive then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro
        and H.HarassManaOK(bot, race) and not State.defensive then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    -- ZONE: держим врага от своей волны (если нет ласт-хита прямо сейчас)
    if intent == I.ZONE and enemyHero and not lasthitImminent and not am_i_tanking_too_much and not inKillThreat then
        if H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers) then return end
    end

    if H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    -- Расходники из боевого кода: с проверкой наличия в магазине, кулдауном и резервом золота
    -- под билд. Раньше манго покупалось КАЖДЫЙ тик при мане < 75 (спам "out of stock" в консоли,
    -- 4 манго = 260 золота в первые минуты -> рецепты брейсеров не покупались).
    if bot:GetGold() >= 65 then
        local cb = C.CONSUMABLE_BUY or {}
        if current_mode == "PASSIVE" and myHpPct < 0.60 then
            if not U.HasItem(bot, "item_flask") and bot:GetItemInSlot(14) == nil
                and H.ConsumableBuyOK(bot, "item_flask", 100, State.lastFlaskBuyTime, cb.FLASK_COOLDOWN or 45) then
                bot:ActionImmediate_PurchaseItem("item_flask")
                State.lastFlaskBuyTime = GameTime()
            end
        end
        if bot:GetMana() < 75 and not U.HasItem(bot, "item_enchanted_mango") and bot:GetItemInSlot(14) == nil
            and H.ConsumableBuyOK(bot, "item_enchanted_mango", 65, State.lastMangoBuyTime, cb.MANGO_COOLDOWN or 60) then
            bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
            State.lastMangoBuyTime = GameTime()
        end
    end

    -- prepTarget (крип для "пред-удара") раньше не сбрасывался НИКОГДА (кроме ForceExtend):
    -- после первого пред-удара навсегда отключались харас, пуш и сам пред-удар, а мёртвый хэндл
    -- опрашивался каждый тик. Сбрасываем: цель мертва/не видна, удар сделан, или прошло > 2.5 с.
    if State.prepTarget then
        local pt = State.prepTarget
        local age = GameTime() - (State.prepTargetTime or 0)
        if not U.CanQuery(pt) or age > 2.5
            or (bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK and age > 0.6) then
            State.prepTarget = nil
            State.prepTargetTime = 0
        end
    end

    -- v2.7 (п.6): снаряд врага уже летит в крипа, его удара не хватит на добивание, а после
    -- попадания крип станет моим - отправляем свой удар СРАЗУ ВСЛЕД за его снарядом.
    if H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps) then return end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) then
                local in_tower_range = false
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                        in_tower_range = true
                        break
                    end
                end
                -- "Формирование HP": пред-удар разрешён и вне своей башни, если враг не может
                -- наказать (далеко от крипа / занят волной / нет готовых рейзов) и мы не под его Т1.
                local prehit_ok = in_tower_range
                if not prehit_ok and (C.LASTHIT.PREHIT_ANYWHERE ~= false) and not inKillThreat and not State.defensive then
                    local eFar = true
                    if enemyHero and U.CanQuery(enemyHero) then
                        local dce = U.DistanceBetweenLocations(c:GetLocation(), enemyHero:GetLocation())
                        local R = K._race
                        eFar = dce > 850 or LN.EnemyBusyWithWave(bot, enemyHero) or (R and R.valid and R.enRazesSoon == 0)
                    end
                    local underEnemyTower = false
                    for _, t in pairs(enemyTowers) do
                        if t:IsAlive() and GetUnitToLocationDistance(t, c:GetLocation()) < 800 then underEnemyTower = true break end
                    end
                    prehit_ok = eFar and not underEnemyTower
                end
                if prehit_ok then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.GetTargetPredictionContext(c, allyAttackers)
                            ctx_prehit.hp = ctx_prehit.hp - myDmg
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.GetTargetPredictionContext(c, enemyAttackers)
                                ctx_prehit.hp = ctx_prehit.hp - myDmg
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = prehit_target:GetIncomingTrackingProjectiles()
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                State.prepTargetTime = GameTime()
                if H.IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= prehit_target then
                        -- ОДИН удар (раньше - непрерывная атака: второй удар срезал крипа в зону,
                        -- где его добивали свои)
                        bot:Action_AttackUnit(prehit_target, true)
                        H.ClearMoveCache()
                    end
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    -- Добивание стака по врагу не ждёт "свободного окна" в 1.9 с до ласт-хита: каст 0.55 с,
    -- уступаем только ласт-хиту, который надо бить в ближайшие 0.7 с.
    -- v2.3: добивочный рейз по стаку важнее ласт-хита, если ласт-хит не "прямо сейчас" (<= 0.45 с):
    -- рейз по герою со стаком (~120-160 урона + продление стака) стоит больше одного крипа
    local followUpNow = enemyHero and H.IsRazeFollowUp(bot, enemyHero) and (bestTargetTime < 0 or bestTargetTime > 0.45)
    -- v2.5: охота (State.hunting) важнее ласт-хита и не блокируется моим стаком (его бурст по мне
    -- уже проверен в ComputeHunt с учётом стака)
    local hunting = (State.hunting and enemyHero ~= nil) or false
    local allowHarass = (is_free_to_prehit or enemyMissedAggro or followUpNow or hunting) and not State.prepTarget and not inKillThreat and (not secondStackActive or hunting)
    -- Окно "только добивание стака" (ласт-хит через 0.45-1.9 с): разрешены лишь рейзы (каст 0.55 с),
    -- а удар с руки по герою (0.5 с замах + 1.6 с перезарядка) стоил бы ласт-хита.
    local razeOnlyWindow = followUpNow and not (is_free_to_prehit or enemyMissedAggro or hunting)
    -- При RETREAT никакой агрессии; при FARM - без сближения с врагом (только если он сам подошёл)
    if intent == I.RETREAT then allowHarass = false end
    local allowApproach = (intent == I.TRADE or intent == I.ALLIN)
    
    if H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if H.TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if razeOnlyWindow then
            -- добивание стака не вышло (нет накрытия/маны) - возвращаемся к ласт-хиту
        elseif H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = H.GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if hunting then
            approachThreshold = (C.INTENT and C.INTENT.HUNT_MAX_DIST or 1100) + 150
            minHpPct = (C.INTENT and C.INTENT.HUNT_MIN_HP_PCT) or 0.40
            effectiveMode = "AGGRESSIVE"
        end
        if allowApproach and not razeOnlyWindow
            and (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            if U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220 then
                return
            end
            local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
            -- v2.3: если "страх" отодвинул точку дальше текущей позиции - это уже не сближение,
            -- а отход: не идём (иначе бот бесконечно пятился от наступающего врага)
            if U.DistanceBetweenLocations(rawApproachClamped, enemyHero:GetLocation()) >= dist - 20 then
                return
            end
            if H.ApproachEnemyPoint(bot, enemyHero, rawApproachClamped, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    local isAttacking = (bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK)
    local target = bot:GetAttackTarget()
    -- цель ушла в туман/умерла: её нельзя опрашивать (иначе "[Developer] ... cannot be seen" каждый тик)
    if isAttacking and target and not U.CanQuery(target) then
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
        isAttacking = false
        target = nil
    end
    local lhFallThrough = false
    if isAttacking and target then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        -- Удар не "ласт-хитовый" (пуш/добор волны): логику отмены к нему не применяем - раньше
        -- она отменяла КАЖДЫЙ такой удар за 0.08 с до точки атаки (крип "слишком живой"), и бот
        -- бесконечно дёргался, не нанося урона. Если при этом созрел настоящий ласт-хит - уступаем ему.
        if State.lhAttackTarget ~= target then
            if target == bestTarget then
                -- непрерывная атака (пуш) по крипу, который стал кандидатом на ласт-хит:
                -- если он добиваем прямо сейчас - пусть удар долетит; иначе прекращаем атаку,
                -- тайминг возьмёт на себя логика ласт-хита ниже
                if bestTargetTime <= 0.05 then return end
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
                isAttacking = false
                target = nil
                lhFallThrough = true
            elseif bestTarget and bestTargetTime >= 0 and bestTargetTime <= (bot:GetSecondsPerAttack() + 0.4) then
                lhFallThrough = true
            else
                return
            end
        end
    end
    if isAttacking and target and not lhFallThrough then
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed) + C.LASTHIT.NET_LATENCY
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time, "avg")
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = (predHP <= 0) or (predHP > commit_threshold + commit_buffer)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    if bestTarget then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local botFacing = bot:GetFacing()
        local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
        if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
        local angleDiff = math.abs(botFacing - angleToTarget)
        if angleDiff > 180 then angleDiff = 360 - angleDiff end
        -- Dota: время поворота = 0.03 * угол(рад) / turn_rate (SF 0.9) -> 180 градусов ~0.105 с
        local turn_time = angleDiff > 15 and (0.03 * math.rad(angleDiff) / 0.9) or 0
        -- Моя собственная перезарядка атаки: следующий удар не раньше lastAttack + spa
        local readyIn = 0
        if bot.GetLastAttackTime then
            local okL, lastAtk = pcall(bot.GetLastAttackTime, bot)
            if okL and type(lastAtk) == "number" and lastAtk > 0 then
                readyIn = math.max(0, (lastAtk + bot:GetSecondsPerAttack()) - GameTime())
            end
        end
        -- v2.2: если крип вне дальности атаки, приказ "атаковать" сначала ведёт бота к нему -
        -- это время раньше не учитывалось, и удар ложился с опозданием (особенно в начале игры,
        -- когда бот держится дальше от волны).
        local atkRange = bot:GetAttackRange() or 525
        local walk_in = 0
        if dist > atkRange then walk_in = (dist - atkRange + 25) / ms end
        local flightDist = math.min(dist, atkRange)
        local current_t_attack = walk_in + math.max(turn_time + ap, readyIn) + (flightDist / projSpeed) + C.LASTHIT.NET_LATENCY
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable, t_window_end = U.GetTimeToKillable(bot, bestTarget, attackers)
        -- Моё попадание должно лечь ПОСЛЕ момента, когда крип станет добиваемым (с запасом
        -- IMPACT_LEAD на джиттер), и ДО момента, когда его добьют свои. Раньше допускалось
        -- попадание на 0.05 с РАНЬШЕ порога -> систематические "ударил рано, крип выжил".
        local lead = (C.LASTHIT and C.LASTHIT.IMPACT_LEAD) or 0.06
        if t_killable < 0 then
            -- окна нет: крип умрёт от своих раньше. Если он уже почти добиваем - бьём сейчас (шанс).
            local hpNow = bestTarget:GetHealth()
            local dr = U.SFDamageRange(bot, bestTarget)
            if hpNow <= dr.avg + 4 and not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    H.ClearMoveCache()
                    return
                end
            end
            t_killable = 999
        end
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    H.ClearMoveCache()
                end
            end
            return
        elseif (t_killable + lead) <= current_t_attack and (t_window_end == nil or current_t_attack < t_window_end - 0.03 or t_window_end <= t_killable + lead) then
            if not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    H.ClearMoveCache()
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    -- PUSH: толкаем волну / бьём Т1 под щитом (ласт-хиты выше по приоритету - сюда попадаем,
    -- только если ближайшего ласт-хита нет)
    -- Осада как запасной план (v2.2): намерение агрессивное (ALLIN/ZONE/TRADE), но враг прячется
    -- под своей Т1 и недосягаем, а перевес большой и волна под башней - бьём башню/крипов под
    -- щитом, а не стоим рядом без дела. (ExecutePush сам проверяет щит, HP и опасность врага.)
    local siegeFallback = false
    if intent ~= I.PUSH and intent ~= I.RETREAT and intent ~= I.FARM and not State.defensive
        and race.valid and s.enemyT1 and myHpPct >= ((C.INTENT and C.INTENT.PUSH_MIN_HP_PCT) or 0.55)
        and race.edge >= ((C.INTENT and C.INTENT.PUSH_EDGE) or 260) and not race.heCanKillSoon then
        local okTL, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okTL and tLoc and GetUnitToLocationDistance(bot, tLoc) <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
            siegeFallback = true
        end
    end
    if (intent == I.PUSH or siegeFallback) and not State.prepTarget and not am_i_tanking_too_much then
        if H.ExecutePush(bot, enemyHero, race, s) then return end
    end

    -- Крипов нет: идём на линию (к центру, если далеко; иначе к своей Т1)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    -- v2.3: гистерезис по времени - списки крипов берутся в радиусе 1200 от бота, и при отходе
    -- за эту границу "крипов нет -> идём к Т1 (ближе к волне) -> крипы снова есть -> отходим"
    -- давало дёрганье 20 раз в секунду. "Нет крипов" = не видели их >= 1.5 с.
    local nowC = GameTime()
    if hasCreeps then State.lastCreepsSeenTime = nowC end
    if not hasCreeps and (nowC - (State.lastCreepsSeenTime or -1e9)) < 1.5 then hasCreeps = true end
    if not hasCreeps and not U.IsActivelyHealing(bot) then
        -- Крипов нет (начало игры / волна погибла): ждём у своей Т1 (точка T1_CLOSE, как в v2).
        -- Одна цель без порогов "центр/Т1" (они давали дёрганье на границе 1500 от центра);
        -- точка "между Т1 и центром" из v2.1 убрана - за Dire она выходила на реку.
        local targetPos = P.GetT1Close(bot)
        if intent == I.PUSH and s.enemyT1 then
            targetPos = LN.SiegeWaitPoint(bot, s.enemyT1)
        end
        if GetUnitToLocationDistance(bot, targetPos) > 200 then
            H.SmartMove(bot, targetPos, 80)
        end
        return
    end

    if State.holdPos then return end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    if enemyHero and U.CanQuery(enemyHero) then
        pos = U.ClampMinDistFromEnemy(bot, enemyHero, pos) -- не заходим в его полосу при "страхе"
    end
    pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        H.SmartMove(bot, pos, 60)
    end
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        H.ClearForcedRetreat()
        H.ClearRazeState()
        H.ClearMoveCache()
        H.ClearTangoState()
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        State.intent = "FARM"
        I.Reset()
        return
    end

    local success, err = pcall(H.RealThink)
    if not success then
        print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
    end
end