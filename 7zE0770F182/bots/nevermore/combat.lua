-- scripts/vscripts/bots/nevermore/combat.lua
--
-- Боевая модель SF vs SF:
--   * трекер рейзов врага (фаза каста -> время готовности, т.к. GetCooldownTimeRemaining
--     для вражеских способностей не работает);
--   * честный урон рейза (базовый + стаки + 2 за душу, талант через GetSpecialValueInt);
--   * "гонка" (Race): абсолютные HP после обмена, кто кого убивает, какие полосы врага опасны;
--   * правило догонялок (CanCatch): не бегать за врагом с равной скоростью.
--
-- Память: все таблицы состояния создаются один раз и переиспользуются (никаких аллокаций в тике,
-- кроме того, что возвращает сам API).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")

local K = {}

K.LABELS = { "near", "mid", "far" }
K.RAZE_NAMES = {
    near = "nevermore_shadowraze1",
    mid  = "nevermore_shadowraze2",
    far  = "nevermore_shadowraze3",
}

local RAZE_CD        = (C.RAZE and C.RAZE.COOLDOWN) or 9.0
local CAST_POINT     = (C.RAZE and C.RAZE.CAST_POINT) or 0.55
local HIT_RADIUS     = (C.RAZE and C.RAZE.HIT_RADIUS) or 250
local RAZE_MANA      = 75
local PER_SOUL_FALLBACK = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2

local function Center(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid" then return C.RAZE.MID_CENTER end
    return C.RAZE.FAR_CENTER
end
K.Center = Center

-------------------------------------------------------------------------------
-- Урон рейза
-------------------------------------------------------------------------------

function K.RazeRawDamage(ability, stacks, souls)
    if not ability or ability:GetLevel() == 0 then return 0 end
    local base = ability:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = ability:GetSpecialValueInt("stack_bonus_damage") or 0
    local perSoul = ability:GetSpecialValueInt("damage_per_soul") or 0
    if not perSoul or perSoul <= 0 then perSoul = PER_SOUL_FALLBACK end
    return base + (stacks or 0) * stackDmg + (souls or 0) * perSoul
end

-- Урон N моих рейзов по цели (текущие стаки на цели, мои души, маг. сопротивление цели).
function K.MyRazeDamage(bot, target, n, extraStacks)
    if n <= 0 or not U.CanQuery(target) then return 0 end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(bot)
    local stacks = (U.GetShadowrazeDebuff(target) or 0) + (extraStacks or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls)
        total = total + target:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Урон N рейзов врага по мне.
function K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    if n <= 0 or not U.CanQuery(enemy) then return 0 end
    local q = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(enemy)
    local stacks = stacksOverride or (U.GetShadowrazeDebuff(bot) or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls)
        total = total + bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Урон с руки после брони цели.
function K.AttackDamageVs(attacker, target)
    if not attacker or not U.CanQuery(target) then return 0 end
    local raw = attacker:GetAttackDamage() or 0
    if raw <= 0 then return 0 end
    return target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
end

-------------------------------------------------------------------------------
-- Мои рейзы: готовность + мана (с учётом манго/стика при allowConsumables)
-------------------------------------------------------------------------------

function K.MyManaBudget(bot, allowConsumables)
    local mana = bot:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(bot) -- v2.5: по зарядам
        local charges = U.GetStickCharges(bot)
        if charges > 0 then
            local stick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if stick then mana = mana + charges * 15 end
        end
    end
    return mana
end

-- Сколько моих рейзов реально доступно (кулдаун готов и хватает маны).
-- Возвращает count, readyIgnoringMana.
function K.MyReadyRazeCount(bot, allowConsumables)
    local ready = 0
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 and ab:IsCooldownReady() then
            ready = ready + 1
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / RAZE_MANA)
    if budget < ready then return budget, ready end
    return ready, ready
end

function K.MyRazeReady(bot, label)
    local ab = bot:GetAbilityByName(K.RAZE_NAMES[label])
    return ab and ab:GetLevel() > 0 and ab:IsCooldownReady() or false
end

-------------------------------------------------------------------------------
-- Трекер рейзов врага
-------------------------------------------------------------------------------

K._enemy = {
    key = nil,
    raze = {
        near = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        mid  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        far  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
    },
    phaseLabel = nil,
    phaseStart = -1,
    lastAnyCastAt = -1,
    prevMyStacks = 0,
    prevMyStacksTime = -1,
}

local function ResetEnemyTracker()
    local E = K._enemy
    for i = 1, 3 do
        local st = E.raze[K.LABELS[i]]
        st.inPhase = false
        st.phaseStart = -1
        st.readyAt = 0
        st.lastCastAt = -1
    end
    E.phaseLabel = nil
    E.phaseStart = -1
    E.lastAnyCastAt = -1
end

local function EnemyKey(enemy)
    local pid = enemy.GetPlayerID and enemy:GetPlayerID()
    if pid == nil or pid < 0 then return tostring(enemy) end
    return pid
end

-- Вызывать каждый тик (enemy может быть nil / невидим).
function K.UpdateEnemyTracker(bot, enemy)
    local now = GameTime()
    local E = K._enemy

    if not U.CanQuery(enemy) then
        for i = 1, 3 do E.raze[K.LABELS[i]].inPhase = false end
        E.phaseLabel = nil
        return
    end

    local key = EnemyKey(enemy)
    if E.key ~= key then
        ResetEnemyTracker()
        E.key = key
    end

    E.phaseLabel = nil
    for i = 1, 3 do
        local label = K.LABELS[i]
        local st = E.raze[label]
        local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
        local inPhase = false
        if ab and ab:GetLevel() > 0 and ab:IsInAbilityPhase() then inPhase = true end

        if inPhase and not st.inPhase then
            st.phaseStart = now
        elseif st.inPhase and not inPhase then
            -- Фаза закончилась: если длилась почти весь каст-поинт - рейз выпущен, кулдаун пошёл.
            local dur = now - st.phaseStart
            if dur >= CAST_POINT - 0.15 then
                st.lastCastAt = now
                st.readyAt = now + RAZE_CD - 0.05
                E.lastAnyCastAt = now
            end
        end
        st.inPhase = inPhase
        if inPhase then
            E.phaseLabel = label
            E.phaseStart = st.phaseStart
        end
    end

    -- Резерв: стаки на мне выросли, а каста мы не видели (враг рейзил из тумана/на границе
    -- видимости) -> вычисляем полосу по дистанции и ставим ей кулдаун.
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local recentUpdate = E.prevMyStacksTime >= 0 and (now - E.prevMyStacksTime) < 0.5
    if recentUpdate and myStacks > E.prevMyStacks and (now - E.lastAnyCastAt) > 0.9 then
        local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        local label = U.GetRazeLabelByDistance(dist, HIT_RADIUS + 60)
        if label then
            local st = E.raze[label]
            st.lastCastAt = now
            st.readyAt = now + RAZE_CD - 0.6
            E.lastAnyCastAt = now
        end
    end
    E.prevMyStacks = myStacks
    E.prevMyStacksTime = now
end

-- Через сколько секунд полоса врага будет готова (0 = готова сейчас / неизвестно = готова).
function K.EnemyRazeReadyIn(label)
    local st = K._enemy.raze[label]
    if not st then return 0 end
    local dt = st.readyAt - GameTime()
    if dt < 0 then return 0 end
    return dt
end

function K.EnemyRazeReady(label, horizon)
    return K.EnemyRazeReadyIn(label) <= (horizon or 0)
end

-- Враг сейчас в фазе каста рейза? -> label, elapsed, remaining
function K.EnemyPhase()
    local E = K._enemy
    if not E.phaseLabel then return nil, 0, 0 end
    local elapsed = GameTime() - E.phaseStart
    local remaining = CAST_POINT - elapsed
    if remaining < 0 then remaining = 0 end
    return E.phaseLabel, elapsed, remaining
end

-- Центр круга рейза врага заданной полосы (по его текущему фейсингу).
function K.EnemyRazeCenter(enemy, label)
    local loc = enemy:GetLocation()
    local rad = math.rad(enemy:GetFacing() or 0)
    local d = Center(label)
    return Vector(loc.x + math.cos(rad) * d, loc.y + math.sin(rad) * d, loc.z)
end

function K.EnemyManaBudget(enemy, allowConsumables)
    local mana = enemy:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(enemy) -- v2.5: по зарядам (2 манго = +200 = ещё 2 рейза)
        local charges = U.GetStickCharges(enemy)
        if charges > 0 then mana = mana + charges * 15 end
    end
    return mana
end

-- Сколько рейзов врага будут готовы в течение horizon сек (ограничено маной).
-- Возвращает count, countIgnoringMana.
function K.EnemyReadyRazeCount(enemy, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    if not U.EnemyHasRaze(enemy) then return 0, 0 end
    local n = 0
    for i = 1, 3 do
        if K.EnemyRazeReadyIn(K.LABELS[i]) <= (horizon or 0) then n = n + 1 end
    end
    local budget = math.floor(K.EnemyManaBudget(enemy, allowConsumables) / RAZE_MANA)
    if budget < n then return budget, n end
    return n, n
end

-- Может ли полоса врага достать меня с дистанции dist в течение horizon сек.
-- Если враг не быстрее меня - считаем, что он сможет сократить дистанцию лишь на ~120u
-- (я отступаю с той же скоростью), иначе - на (его скорость * horizon).
local function BandCanReach(bot, enemy, label, dist, horizon, pinned)
    local reach = Center(label) + HIT_RADIUS + 25
    if dist <= reach then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance
    if pinned or enMS > myMS + 5 then
        closeAllowance = enMS * (horizon or 0) + 60
    else
        closeAllowance = 120
    end
    return dist <= reach + closeAllowance
end

-- Бурст врага по мне с дистанции dist в горизонте horizon (учёт готовности полос, маны,
-- досягаемости полос и его урона с руки, если он уже в радиусе атаки).
-- Возвращает damage, razeCount.
function K.EnemyBurstVs(bot, enemy, dist, horizon, pinned, stacksOverride)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local n = 0
    if U.EnemyHasRaze(enemy) then
        for i = 1, 3 do
            local label = K.LABELS[i]
            if K.EnemyRazeReadyIn(label) <= horizon and BandCanReach(bot, enemy, label, dist, horizon, pinned) then
                n = n + 1
            end
        end
        local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
        if budget < n then n = budget end
    end
    local dmg = K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    -- удары с руки: только если он уже рядом (иначе мы отходим)
    local atkRange = (enemy:GetAttackRange() or 525) + 80
    if dist <= atkRange then
        local atk = K.AttackDamageVs(enemy, bot)
        local spa = enemy:GetSecondsPerAttack() or 1.6
        local hits = math.floor(horizon / math.max(0.6, spa))
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    end
    return dmg, n
end

-- Мой бурст по врагу с дистанции dist в горизонте horizon.
-- Первый рейз должен быть кастуем "отсюда" (полоса в досягаемости по тем же правилам).
function K.MyBurstVs(bot, enemy, dist, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance = 120
    if myMS > enMS + 5 then closeAllowance = (myMS - enMS) * horizon + 120 end
    local n = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.MyRazeReady(bot, label) then
            local reach = Center(label) + HIT_RADIUS + 25
            if dist <= reach + closeAllowance then n = n + 1 end
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / RAZE_MANA)
    if budget < n then n = budget end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local atkRange = (bot:GetAttackRange() or 525) + 80
    if dist <= atkRange then
        local atk = K.AttackDamageVs(bot, enemy)
        local spa = bot:GetSecondsPerAttack() or 1.6
        local hits = math.floor(horizon / math.max(0.6, spa))
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    end
    return dmg, n
end

-- v2.5 "Охота": мой бурст по врагу за horizon сек при условии, что я ДОЙДУ до средней полосы
-- (оттуда достают все три): рейзы, которые будут готовы в горизонте (кд <= horizon - 0.6),
-- ограниченные маной С манго; плюс 1-2 удара с руки. Решение "идти добивать" при большом
-- перевесе по HP, когда обычная гонка (разы только с текущей дистанции) кила не видит.
function K.MyHuntBurst(bot, enemy, horizon)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 4.0
    local n = 0
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 then
            local cd = 0
            if ab.GetCooldownTimeRemaining then
                local ok, v = pcall(ab.GetCooldownTimeRemaining, ab)
                if ok and type(v) == "number" then cd = v end
            elseif not ab:IsCooldownReady() then
                cd = 999
            end
            if cd <= horizon - 0.6 then n = n + 1 end
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, true) / RAZE_MANA)
    if budget < n then n = budget end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local spa = bot:GetSecondsPerAttack() or 1.6
    if spa <= 0 then spa = 1.6 end
    local hits = math.floor((horizon - 1.5) / math.max(0.6, spa))
    if hits < 1 then hits = 1 end
    if hits > 2 then hits = 2 end
    return dmg + K.AttackDamageVs(bot, enemy) * hits, n
end

-- Минимальная безопасная дистанция до врага: за пределами всех его полос, готовых в horizon.
-- 0 = ни одна полоса не готова (или нет маны) -> стоять можно где угодно.
function K.EnemyMinSafeDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + HIT_RADIUS + 45
            if r > best then best = r end
        end
    end
    return best
end

-- "Увернительная" дистанция: стоим у внешнего края его самой дальней ГОТОВОЙ полосы
-- (центр + 200 из 250 радиуса): по анимации каста (0.55 с) успеваем выйти из круга.
-- Это компромисс "зонированного" SF: не отдавать всю волну, но и не стоять в центре полосы.
function K.EnemyDodgeableDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + 200
            if r > best then best = r end
        end
    end
    return best
end

-- Полоса врага, готовая в horizon, в которой я сейчас стою (или nil).
function K.EnemyReadyBandAt(enemy, dist, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return nil end
    if K.EnemyManaBudget(enemy, true) < RAZE_MANA then return nil end
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            if math.abs(dist - Center(label)) <= HIT_RADIUS + 30 then return label end
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Гонка (Race): абсолютные HP, кто кого убивает.
-------------------------------------------------------------------------------

K._race = {
    valid = false,
    dist = 0,
    myHp = 0, enHp = 0,
    myBurstNow = 0, myBurstSoon = 0, myRazesSoon = 0,
    enBurstNow = 0, enBurstSoon = 0, enRazesSoon = 0,
    canKillNow = false, canKillSoon = false,
    heCanKillNow = false, heCanKillSoon = false,
    edge = 0,           -- (мои HP после его бурста) - (его HP после моего бурста)
    hpDiff = 0,         -- мои HP - его HP (абсолютно)
    minSafeDist = 0,    -- дистанция, вне которой его готовые полосы меня не достают
    enemyFaster = false,
    enemyBandHere = nil, -- готовая полоса врага, в которой я стою
}

-- Урон башни по герою за horizon сек (если герой в её радиусе). Т1: ~90 урона, BAT 0.9.
local function TowerDamageOn(tower, hero, horizon)
    if not tower or not U.CanQuery(hero) then return 0 end
    local okAlive, alive = pcall(tower.IsAlive, tower)
    if not okAlive or not alive then return 0 end
    local okLoc, tLoc = pcall(tower.GetLocation, tower)
    if not okLoc or not tLoc then return 0 end
    if GetUnitToLocationDistance(hero, tLoc) > 720 then return 0 end
    local raw = 90
    local okD, d = pcall(tower.GetAttackDamage, tower)
    if okD and type(d) == "number" and d > 0 then raw = d end
    local per = hero:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
    return per * math.floor(horizon / 0.9)
end

-- s (опционально) = снимок мира W.s: башни Т1 для учёта их урона в гонке.
function K.Race(bot, enemy, pinned, s)
    local R = K._race
    R.valid = false
    if not bot or not U.CanQuery(enemy) then return R end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 0

    local myNow = K.MyBurstVs(bot, enemy, dist, 0.3, true)
    local mySoon, myRazesSoon = K.MyBurstVs(bot, enemy, dist, 2.5, true)
    local enNow = K.EnemyBurstVs(bot, enemy, dist, 0.3, pinned)
    local enSoon, enRazesSoon = K.EnemyBurstVs(bot, enemy, dist, 2.5, pinned)

    -- Башни: он под моей Т1 - её урон на моей стороне; я под его Т1 - на его стороне.
    R.myTowerOnHim = 0
    R.hisTowerOnMe = 0
    if s then
        R.myTowerOnHim = TowerDamageOn(s.allyT1, enemy, 2.5)
        R.hisTowerOnMe = TowerDamageOn(s.enemyT1, bot, 2.5)
        mySoon = mySoon + R.myTowerOnHim
        enSoon = enSoon + R.hisTowerOnMe
    end

    -- Затяжной размен с руки: DPS и время убийства друг друга авто-атаками
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local mySpa = bot:GetSecondsPerAttack() or 1.6
    local enSpa = enemy:GetSecondsPerAttack() or 1.6
    if mySpa <= 0 then mySpa = 1.6 end
    if enSpa <= 0 then enSpa = 1.6 end
    R.myDps = myAtk / mySpa
    R.enDps = enAtk / enSpa
    R.ttkMe = (R.enDps > 0) and (myHp / R.enDps) or 999
    R.ttkHim = (R.myDps > 0) and (enHp / R.myDps) or 999

    R.dist = dist
    R.myHp = myHp
    R.enHp = enHp
    R.myBurstNow = myNow
    R.myBurstSoon = mySoon
    R.myRazesSoon = myRazesSoon
    R.enBurstNow = enNow
    R.enBurstSoon = enSoon
    R.enRazesSoon = enRazesSoon
    R.canKillNow = (myNow > 0) and (myNow >= enHp)
    R.canKillSoon = (mySoon > 0) and (mySoon >= enHp)
    R.heCanKillNow = (enNow > 0) and (enNow >= myHp)
    R.heCanKillSoon = (enSoon > 0) and (enSoon >= myHp)
    R.edge = (myHp - enSoon) - (enHp - mySoon)
    R.hpDiff = myHp - enHp
    -- Проекция размена на 6 с: бурст "скоро" + авто-атаки оставшееся время (абсолютные HP).
    local T = 6.0
    local myAfter = myHp - enSoon - R.enDps * (T - 2.5)
    local enAfter = enHp - mySoon - R.myDps * (T - 2.5)
    R.edgeLong = myAfter - enAfter
    local cfgD = C.DEFENSE or {}
    R.weaker = (R.edgeLong < -(cfgD.WEAKER_EDGE or 120))
        or (R.ttkMe < R.ttkHim * 0.6 and R.edge < 0)
    -- "Слабее надолго": проигрыш именно в затяжном размене с руки (уровни/души/предметы/пул HP),
    -- а не временный перекос из-за кд рейзов. Используется там, где цена ошибки - CS (спорные ласт-хиты).
    R.weakerSustained = R.ttkMe < R.ttkHim * (cfgD.SUSTAINED_TTK_RATIO or 0.8)
    R.minSafeDist = K.EnemyMinSafeDistance(enemy, 2.5)
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    R.enemyFaster = enMS > myMS + 5
    R.enemyBandHere = K.EnemyReadyBandAt(enemy, dist, 1.0)
    R.valid = true
    return R
end

-------------------------------------------------------------------------------
-- Догонялки
-------------------------------------------------------------------------------

-- Можно ли сократить дистанцию до neededDist за разумное время.
-- Враг с равной/большей скоростью, убегающий от нас - недогоняем.
function K.CanCatch(bot, enemy, neededDist, maxTime)
    if not U.CanQuery(enemy) then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d <= neededDist + 60 then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local vx, vy = 0, 0
    if enemy.GetVelocity then
        local v = enemy:GetVelocity()
        if v then vx, vy = v.x or 0, v.y or 0 end
    end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 40 then
        -- стоит: догоним, если дистанция разумная
        return (d - neededDist) / myMS <= (maxTime or 2.5)
    end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    local awaySpeed = vx * ax + vy * ay -- >0: убегает от нас
    if awaySpeed > 0.4 * speed then
        local closing = myMS - awaySpeed
        if closing <= 15 then return false end
        return (d - neededDist) / closing <= (maxTime or 2.5)
    end
    -- идёт к нам / вбок
    return (d - neededDist) / (myMS + math.max(0, -awaySpeed)) <= (maxTime or 2.5)
end

-- Враг движется от нас (убегает)?
function K.IsEnemyMovingAway(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return false end
    local v = enemy:GetVelocity()
    if not v then return false end
    local speed = math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2)
    if speed < 60 then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return false end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    return (v.x * ax + v.y * ay) > 0.5 * speed
end

-- Хук для utils (utils не может require combat из-за цикла)
U._K = K

return K
