-- scripts/vscripts/bots/nevermore/intent.lua
--
-- Намерение бота на тик: конечный автомат с гистерезисом (минимальное время в состоянии +
-- разные пороги входа/выхода), чтобы не дёргаться между режимами каждый кадр.
--
-- Состояния (по приоритету):
--   RETREAT - враг может убить меня своим доступным бурстом, а я его "сейчас" - нет;
--   ALLIN   - я убиваю его доступным бурстом (и могу достать);
--   ZONE    - я сильнее в абсолютных HP, враг у моей волны: держу его от крипов;
--   TRADE   - размен выгоден/равен, враг в досягаемости: давление рейзами/ударами;
--   PUSH    - враг мёртв/не виден >5 с, или большое преимущество: толкаю волну, бью Т1 под щитом;
--   FARM    - по умолчанию: ласт-хиты/денаи.

local C = require("bots/nevermore/constants")

local I = {}

I.RETREAT, I.ALLIN, I.ZONE, I.TRADE, I.PUSH, I.FARM = "RETREAT", "ALLIN", "ZONE", "TRADE", "PUSH", "FARM"

local PRIO = { RETREAT = 5, ALLIN = 4, ZONE = 3, TRADE = 3, PUSH = 2, FARM = 1 }
local DWELL = { RETREAT = 0.9, ALLIN = 0.6, ZONE = 1.2, TRADE = 0.8, PUSH = 3.0, FARM = 0.4 }

local CFG = C.INTENT or {}
local PUSH_EDGE    = CFG.PUSH_EDGE or 260
local ZONE_EDGE    = CFG.ZONE_EDGE or 70
local TRADE_EDGE   = CFG.TRADE_EDGE or -30
local LOW_HP_PCT   = CFG.LOW_HP_PCT or 0.22
local PUSH_MIN_HP  = CFG.PUSH_MIN_HP_PCT or 0.55
local PUSH_KEEP_HP = CFG.PUSH_KEEP_HP_PCT or 0.45
local ZONE_WAVE_DIST = CFG.ZONE_WAVE_DIST or 900
local ABSENT_SEC   = CFG.ENEMY_ABSENT_SEC or 5.0

I.state = I.FARM
I.since = -1
I.reason = ""

-- ctx (переиспользуемая таблица, заполняется в RealThink):
--   enemy (bool: враг виден), race (K._race), myHpPct, myRazes (доступных рейзов с маной),
--   healing (bool), enemyDist, enemyDistToWave, enemyAbsent (bool), enemyUnderHisTower (bool),
--   canCatch (bool), underEnemyTower (bool: я в радиусе его Т1 без щита),
--   hunt (bool: v2.5 "охота" - см. H.ComputeHunt),
--   defensive (bool: по длинной проекции (K.Race.weaker) я слабее и без поддержки крипов/башни -
--              агрессивные намерения ZONE/TRADE/PUSH-"преимущество" запрещены, остаётся FARM/RETREAT/ALLIN)
function I.Update(ctx, now)
    local prev = I.state
    local R = ctx.race
    local rv = ctx.enemy and R and R.valid
    local want = I.FARM
    local reason = "default"

    -- v2.6: гарантированное добивание (canKillNow) имеет приоритет даже над отходом:
    -- "если можешь убить его перед смертью - убивай и не бойся" (обмен убийствами).
    -- v2.7: отход срабатывает РАНЬШЕ (запас 50 HP), но НЕ когда мы сами добиваем и после
    -- размена впереди (edge >= 0) - "побеждаю, но убегаю" больше не бывает.
    local heThreatens = R.heCanKillSoon or (R.enBurstSoon >= R.myHp - 50)
    local weWinTrade = R.canKillSoon and R.edge >= 0
    -- v2.8: явный перевес в размене (edge >= 100) и он НЕ убивает нас мгновенно -
    -- не боимся: рейз-преимущество (уровень рейза выше) должно реализовываться агрессией,
    -- а не отходом ("я L3 с рейзом 2 боюсь L2 с рейзом 1")
    local weOutdamage = R.edge >= 100 and not R.heCanKillNow
    if rv and heThreatens and not R.canKillNow and not weWinTrade and not weOutdamage then
        want, reason = I.RETREAT, "enemy burst lethal"
    elseif rv and R.canKillNow then
        want, reason = I.ALLIN, "kill available"
    elseif rv and weWinTrade and ctx.canCatch then
        want, reason = I.ALLIN, "winning trade"
    elseif ctx.enemyTPIncoming and not ctx.healing and ctx.myHpPct < (CFG.TP_IN_MIN_HP_PCT or 0.55)
        and ((ctx.enemyT1Dist or 99999) <= 1500 or ctx.enemyDist <= 900) then
        -- v2.6: видим его ТП к Т1 (канал/возврат после смерти) - заранее отходим, если мы не в форме
        want, reason = I.RETREAT, "enemy tp incoming"
    elseif ctx.enemy and ctx.myHpPct < LOW_HP_PCT and not ctx.healing and ctx.enemyDist <= 1100 then
        want, reason = I.RETREAT, "low hp"
    elseif rv and (R.canKillSoon and not R.heCanKillSoon and ctx.canCatch) then
        want, reason = I.ALLIN, "kill soon"
    elseif rv and ctx.hunt then
        -- v2.5: "охота" - большой перевес по HP, его добивает мой бурст за горизонт с подходом
        -- в среднюю полосу (мана с манго), его бурст мне не опасен
        want, reason = I.ALLIN, "hunt"
    elseif ctx.enemyAbsent then
        want, reason = I.PUSH, "enemy absent"
    elseif ctx.defensive then
        want, reason = I.FARM, "defensive"
    elseif rv and R.edge >= PUSH_EDGE and ctx.myHpPct >= PUSH_MIN_HP and ctx.myRazes >= 2
        and not R.heCanKillSoon and (ctx.enemyUnderHisTower or ctx.enemyDist > 1000) then
        want, reason = I.PUSH, "big advantage"
    elseif rv and ctx.enemyDistToWave <= ZONE_WAVE_DIST and R.edge >= ZONE_EDGE
        and not R.heCanKillSoon and ctx.myHpPct >= 0.35 then
        want, reason = I.ZONE, "stronger, enemy near wave"
    elseif rv and ctx.enemyDist <= 1000 and R.edge >= TRADE_EDGE and not R.heCanKillSoon then
        want, reason = I.TRADE, "trade ok"
    end

    if want ~= prev then
        local held = (I.since >= 0) and (now - I.since) or 999
        -- минимальное время в состоянии, если новое не приоритетнее
        local defensiveExit = ctx.defensive and (prev == I.ZONE or prev == I.TRADE or prev == I.PUSH)
        -- v2.6: срочные переходы НЕ задерживаются dwell: гарантированное добивание - сразу,
        -- смертельная угроза/низкий HP - сразу бежать (не дёргаться между боем и бегом).
        local urgent = (want == I.ALLIN and rv and R.canKillNow)
            or (want == I.RETREAT and ((rv and R.heCanKillNow) or reason == "low hp"
                or reason == "enemy tp incoming" or reason == "enemy burst lethal"))
        if held < (DWELL[prev] or 0) and (PRIO[want] or 0) <= (PRIO[prev] or 0)
            and not defensiveExit and not urgent then
            want = prev
            reason = "dwell"
        end
        -- гистерезис выхода
        if prev == I.RETREAT and want ~= I.ALLIN and rv and R.enBurstSoon >= R.myHp - 60 then
            want, reason = I.RETREAT, "retreat hysteresis"
        end
        -- v2.6: начали добивание - дожимаем, пока он остаётся добиваемым и мы не умираем прямо сейчас
        if prev == I.ALLIN and want == I.RETREAT and rv and R.canKillSoon
            and not R.heCanKillNow and ctx.enemyDist <= 900 and held < 1.2 then
            want, reason = I.ALLIN, "allin finish hysteresis"
        end
        if prev == I.PUSH and (want == I.FARM or want == I.TRADE or want == I.ZONE) and not defensiveExit then
            if ctx.enemyAbsent or (rv and R.edge >= PUSH_EDGE - 120 and ctx.myHpPct >= PUSH_KEEP_HP and not R.heCanKillSoon) then
                want, reason = I.PUSH, "push hysteresis"
            end
        end
        if prev == I.ZONE and (want == I.TRADE or want == I.FARM) and rv and not defensiveExit then
            if R.edge >= ZONE_EDGE - 80 and ctx.enemyDistToWave <= ZONE_WAVE_DIST + 200 and not R.heCanKillSoon then
                want, reason = I.ZONE, "zone hysteresis"
            end
        end
    end

    if want ~= prev then
        I.state = want
        I.since = now
    end
    I.reason = reason
    return I.state
end

function I.Reset()
    I.state = I.FARM
    I.since = -1
    I.reason = ""
end

return I
