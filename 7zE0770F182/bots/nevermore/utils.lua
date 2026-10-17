-- scripts/vscripts/bots/nevermore/utils.lua

local C = require("bots/nevermore/constants")
local S = require("bots/nevermore/souls")

local U = {}

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

local function Clamp(v, minValue, maxValue)
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

function U.CanQuery(unit)
    if not unit then return false end
    if not unit:IsAlive() then return false end
    if unit.CanBeSeen and not unit:CanBeSeen() then return false end
    return true
end

function U.MergeLists(list1, list2)
    local result = {}
    if list1 then for _, v in pairs(list1) do table.insert(result, v) end end
    if list2 then for _, v in pairs(list2) do table.insert(result, v) end end
    return result
end

function U.DistanceBetweenLocations(a, b)
    if not a or not b then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function U.GetRazeLabelByDistance(dist, radius)
    radius = radius or C.RAZE.STRICT_RADIUS
    local candidates = {
        { label = "near", center = C.RAZE.NEAR_CENTER },
        { label = "mid",  center = C.RAZE.MID_CENTER  },
        { label = "far",  center = C.RAZE.FAR_CENTER  },
    }
    local bestLabel = nil
    local bestDiff = math.huge
    for _, v in ipairs(candidates) do
        local diff = math.abs(dist - v.center)
        if diff < bestDiff then
            bestDiff = diff
            bestLabel = v.label
        end
    end
    if bestDiff <= radius then
        return bestLabel, bestDiff
    end
    return nil, bestDiff
end

function U.GetRazeCenterByLabel(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid"  then return C.RAZE.MID_CENTER end
    if label == "far"  then return C.RAZE.FAR_CENTER end
    return nil
end

function U.CanAcceptSingleRazeTrade(bot, enemy)
    if not U.CanQuery(enemy) then return true end
    if not U.EnemyHasRaze(enemy) then return true end
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    local tol = (C.RAZE and C.RAZE.SINGLE_TRADE_LEVEL_TOLERANCE) or 1
    return eLvl <= (myLvl + tol)
end

function U.GetTeamFountain(team)
    return team == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function U.GetFountain(bot)
    return U.GetTeamFountain(bot:GetTeam())
end

-- Контекст предсказания HP цели (крипа) под ударами атакующих.
-- v3: дискретная модель ударов. Для каждого атакующего, который бьёт цель, берём время его
-- последнего удара (GetLastAttackTime) и период атаки (GetSecondsPerAttack): следующий удар
-- ляжет в lastAttack + spa (+ полёт снаряда у дальников/башен). Это убирает главный источник
-- ошибок "ударил слишком рано / слишком поздно" - усреднённый DPS, который размазывал
-- дискретные удары крипов (21 урона раз в секунду) по времени.
-- Если ритм атакующего неизвестен (только что подошёл/сменил цель, нет GetLastAttackTime) -
-- удар считается "неопределённым": в пессимистичной оценке (HP при моём попадании) он ложится
-- поздно, в оптимистичной (умрёт ли крип раньше моего попадания) - рано.
local function AttackerNextImpact(atk, target, now)
    -- возвращает tImpact (сек от now), period, certain(bool), travel
    local spa = atk:GetSecondsPerAttack()
    if not spa or spa <= 0 then spa = 1.0 end
    local travel = 0
    local ranged = false
    if atk:IsTower() then
        ranged = true
        travel = GetUnitToLocationDistance(target, atk:GetLocation()) / 750 + 0.07
    else
        local ps = atk.GetAttackProjectileSpeed and atk:GetAttackProjectileSpeed() or 0
        if ps and ps > 0 then
            ranged = true
            travel = GetUnitToLocationDistance(target, atk:GetLocation()) / ps
        elseif (atk:GetUnitName() or ""):find("siege") then
            ranged = true
            travel = GetUnitToLocationDistance(target, atk:GetLocation()) / 1100
        end
    end
    local last = nil
    if atk.GetLastAttackTime then
        local ok, v = pcall(atk.GetLastAttackTime, atk)
        if ok and type(v) == "number" and v > 0 then last = v end
    end
    local ap = (atk.GetAttackPoint and atk:GetAttackPoint()) or 0.5
    if last and (now - last) <= spa + 0.35 then
        local tNext = (last + spa) - now
        if tNext < 0.02 then tNext = 0.02 end
        return tNext + travel, spa, true, travel, ranged
    end
    -- ритм неизвестен: первый удар не раньше точки атаки, не позже полного цикла
    return ap + travel, spa, false, travel, ranged
end

function U.GetTargetPredictionContext(target, all_attackers)
    local now = GameTime()
    local ctx = {
        hp = target:GetHealth(),
        regen = target:GetHealthRegen() or 0,
        projs = target:GetIncomingTrackingProjectiles() or {},
        dps = 0,           -- запасная усреднённая модель (атакующие без данных)
        hits = {},         -- дискретные удары: { t, period, dmgLo, dmgHi, certain, slack }
        scheduled = {},    -- caster -> true: повторы его снарядов уже учтены в hits
        projDmg = {},      -- caster -> урон его летящего снаряда
    }

    local flying_casters = {}
    for _, p in pairs(ctx.projs) do
        if p.is_attack and p.caster and U.CanQuery(p.caster) then
            flying_casters[p.caster] = true
        end
    end

    if all_attackers then
        for _, atk in pairs(all_attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then
                local avgDmg = atk:GetAttackDamage() or 0
                if avgDmg > 0 then
                    local var = 0
                    if atk.GetBaseDamageVariance then
                        local ok, v = pcall(atk.GetBaseDamageVariance, atk)
                        if ok and type(v) == "number" then var = v end
                    end
                    local dmgLo = target:GetActualIncomingDamage(avgDmg - var, DAMAGE_TYPE_PHYSICAL)
                    local dmgHi = target:GetActualIncomingDamage(avgDmg + var, DAMAGE_TYPE_PHYSICAL)
                    if atk:IsTower() or ((atk:GetUnitName() or ""):find("siege")) then
                        -- башня/осадный: без разброса - средний урон
                        dmgLo = target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL)
                        dmgHi = dmgLo
                    end
                    ctx.projDmg[atk] = (dmgLo + dmgHi) * 0.5
                    local tImpact, period, certain, travel, ranged = AttackerNextImpact(atk, target, now)
                    -- атакующий сам при смерти (один удар крипа убьёт): его будущие удары могут
                    -- не состояться -> в пессимистичной оценке их не считаем
                    local fragile = (not atk:IsTower()) and ((atk:GetHealth() or 999) <= 30)
                    -- v2.5: вражеский герой - ненадёжный "атакующий" (отменяет замахи, уходит, бьёт
                    -- одиночными кликами): его урон не моделируем ни в одном режиме (иначе бот либо
                    -- рассчитывал бы на его удар, либо "уступал" ему спорного крипа). Вместо этого
                    -- помечаем цель как СПОРНУЮ (ctx.contested): ласт-хит по средней модели, а не по
                    -- пессимистичной - шанс 50/50 лучше гарантированного "он забрал".
                    local isHero = (atk.IsHero and atk:IsHero()) and true or false
                    if isHero then ctx.contested = true end
                    if flying_casters[atk] then
                        -- его снаряд уже летит (учтён в projs): следующий ЗАПУСК через period после
                        -- последнего удара -> первый "наш" удар = tImpact (он уже включает period)
                        if not certain then
                            tImpact = period + travel
                            certain = true -- снаряд в полёте = он в ритме атаки
                        end
                    end
                    ctx.scheduled[atk] = true
                    table.insert(ctx.hits, {
                        t = tImpact, period = period, dmgLo = dmgLo, dmgHi = dmgHi,
                        certain = certain, fragile = fragile, hero = isHero,
                        -- неопределённый удар: может лечь на slack позже (до конца цикла)
                        slack = certain and 0.0 or math.max(0, period - ((atk.GetAttackPoint and atk:GetAttackPoint()) or 0.5)),
                    })
                end
            end
        end
    end
    return ctx
end

-- mode: nil/"avg" - средний урон, неопределённые удары по номиналу;
--       "max"     - пессимистично для ласт-хита (крип останется с БОЛЬШИМ HP): неопределённые
--                   удары поздно, урон минимальный;
--       "min"     - крип умрёт РАНЬШЕ: неопределённые удары рано, урон максимальный.
function U.PredictHPWithContext(ctx, target, time_in_future, mode)
    if ctx.hp <= 0 then return 0 end
    mode = mode or "avg"
    local predicted_hp = ctx.hp + ((ctx.regen or 0) * time_in_future)
    if ctx.dps and ctx.dps > 0 then
        predicted_hp = predicted_hp - (ctx.dps * time_in_future)
    end

    -- летящие снаряды (в т.ч. мои): один удар каждый; повторы - только если кастер не в графике
    for _, p in pairs(ctx.projs) do
        if p.is_attack and p.caster and U.CanQuery(p.caster) then
            local caster = p.caster
            local speed = caster:GetAttackProjectileSpeed()
            local is_tower = caster:IsTower()
            if not speed or speed <= 0 then
                local name = caster:GetUnitName() or ""
                if is_tower then speed = 750
                elseif name:find("siege") then speed = 1100
                else speed = 900 end
            end
            local dist = GetUnitToLocationDistance(target, p.location)
            local t_impact = dist / speed
            if is_tower then t_impact = t_impact + 0.07 end
            if t_impact <= time_in_future then
                local dmg = ctx.projDmg and ctx.projDmg[caster]
                if not dmg then
                    local avgDmg = caster:GetAttackDamage() or 0
                    dmg = (avgDmg > 0) and target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL) or 0
                end
                if dmg > 0 then
                    predicted_hp = predicted_hp - dmg
                    if not (ctx.scheduled and ctx.scheduled[caster]) then
                        local bat = caster:GetSecondsPerAttack()
                        if bat and bat > 0 then
                            local next_impact = t_impact + bat
                            while next_impact <= time_in_future do
                                predicted_hp = predicted_hp - dmg
                                next_impact = next_impact + bat
                            end
                        end
                    end
                end
            end
        end
    end

    -- дискретные удары атакующих
    if ctx.hits then
        for _, h in ipairs(ctx.hits) do
            local dmg
            if mode == "max" then dmg = h.fragile and 0 or h.dmgLo
            elseif mode == "min" then dmg = h.dmgHi
            else dmg = (h.dmgLo + h.dmgHi) * 0.5 end
            if h.hero then dmg = 0 end -- v2.5: удар героя не моделируем (см. ctx.contested)
            local t = h.t
            if not h.certain then
                if mode == "max" then t = t + (h.slack or 0)
                elseif mode == "avg" then t = t + (h.slack or 0) * 0.5 end
            end
            while t <= time_in_future do
                predicted_hp = predicted_hp - dmg
                t = t + h.period
            end
        end
    end

    -- старый формат (virtual_projs) - на случай внешних вызовов
    if ctx.virtual_projs then
        for _, vp in pairs(ctx.virtual_projs) do
            if vp.t_impact <= time_in_future then
                predicted_hp = predicted_hp - vp.actualDmg
                local next_impact = vp.t_impact + vp.bat
                while next_impact <= time_in_future do
                    predicted_hp = predicted_hp - vp.actualDmg
                    next_impact = next_impact + vp.bat
                end
            end
        end
    end

    return predicted_hp
end

function U.HasLasthitWindow(ctx, target, my_dmg, min_time)
    min_time = min_time or 0
    for t = 0.05, 3.0, 0.05 do
        local hp = U.PredictHPWithContext(ctx, target, t)
        if hp <= 0 then
            return false
        elseif hp <= my_dmg then
            if t >= min_time then return true end
        end
    end
    return false
end

-- Модель моего урона (v2.2). GetAttackDamage() в Bot API может возвращать либо среднее, либо
-- уже "брошенный" случайный урон (как GetAttackDamage в серверном API). Раньше из него
-- вычиталась ещё и дисперсия: при броске-минимуме порог занижался на весь разброс (до 6 HP
-- на 1 уровне - это треть удара крипа), и добивание систематически запаздывало именно в
-- начале игры, где разброс велик относительно урона. Снимаем семантику в рантайме по окну
-- последних значений: прыгают туда-сюда (немонотонно) -> броски: минимум окна = мой минимум;
-- постоянны -> среднее: минимум = среднее - полуразброс базового урона (SF 16-22 -> 3).
U._dmg = { buf = {}, n = 0, idx = 0, cap = 45, mode = "avg", reported = false }
local function MyDamageMinAvg(bot)
    local d = U._dmg
    local v = bot:GetAttackDamage() or 0
    d.idx = d.idx % d.cap + 1
    d.buf[d.idx] = v
    if d.n < d.cap then d.n = d.n + 1 end
    local lo, hi = math.huge, -math.huge
    local flips, prev, dir = 0, nil, 0
    for k = 1, d.n do
        local i = (d.idx - d.n + k - 1) % d.cap + 1
        local x = d.buf[i]
        if x < lo then lo = x end
        if x > hi then hi = x end
        if prev then
            local nd = 0
            if x > prev then nd = 1 elseif x < prev then nd = -1 end
            if nd ~= 0 then
                if dir ~= 0 and nd ~= dir then flips = flips + 1 end
                dir = nd
            end
        end
        prev = x
    end
    local half = (C.HERO and C.HERO.DAMAGE_HALF_RANGE) or 3
    local rolled = (hi - lo) >= 3 and flips >= 3
    local mode = rolled and "rolled" or "avg"
    local changed = (mode ~= d.mode)
    d.mode = mode
    -- один раз сообщаем в консоль, какая семантика у GetAttackDamage (для сверки в игре)
    if (not d.reported and d.n >= 25) or (changed and U.DEBUG) then
        d.reported = true
        local okV, bv = pcall(bot.GetBaseDamageVariance, bot)
        print(string.format("[SF-BOT] damage model: %s (window %.0f..%.0f, n=%d, api variance=%s, half-range used=%d)",
            mode, lo, hi, d.n, okV and tostring(bv) or "?", half))
    end
    if rolled then
        local est = lo
        if d.n < 25 then est = lo - 1 end -- окно ещё короткое: минимум мог не выпасть
        return est, (lo + hi) * 0.5
    end
    return v - half, v
end

function U.SFDamageRange(bot, target)
    local rawMin, rawAvg = MyDamageMinAvg(bot)
    local actualMin = target:GetActualIncomingDamage(rawMin, DAMAGE_TYPE_PHYSICAL)
    local actualAvg = target:GetActualIncomingDamage(rawAvg, DAMAGE_TYPE_PHYSICAL)

    if target and target:IsAlive() then
        local name = target:GetUnitName() or ""
        if name:find("siege") then
            actualMin = actualMin * 0.5
            actualAvg = actualAvg * 0.5
        end
    end

    return { min = actualMin, avg = actualAvg }
end

function U.GetEffectiveDamageAndMargin(bot, target, attackersCount)
    local range = U.SFDamageRange(bot, target)
    local base_margin = 0
    if attackersCount and attackersCount >= 3 then base_margin = 2 end
    return range.min, base_margin
end

-- Когда крип станет добиваемым моим ударом.
-- Возвращает t, tEnd, gamble:
--   t     = 0      - добиваем уже сейчас (HP <= порог);
--   t     > 0      - через t сек HP гарантированно (пессимистично) опустится до порога;
--   t     = -1     - крип умрёт от своих раньше, чем станет добиваемым (окна нет);
--   t     = 999    - в горизонте 5 с не станет добиваемым;
--   tEnd           - момент, когда крип может умереть и без меня (оптимистично): мой удар
--                    должен лечь в [t, tEnd);
--   gamble = true  - гарантированного окна нет, t взято по средней модели (шанс, а не гарантия).
function U.GetTimeToKillable(bot, target, attackers)
    local atkCount = 0
    if attackers then
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target
                and not (atk.IsHero and atk:IsHero()) then -- v2.5: герой не увеличивает запас
                atkCount = atkCount + 1
            end
        end
    end

    local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
    local kill_threshold = dmg - safety_margin
    local currentHP = target:GetHealth()
    if currentHP <= kill_threshold then return 0.0, 999, false end

    local ctx = U.GetTargetPredictionContext(target, attackers)
    -- v2.5: спорный крип (вражеский герой уже целится в него) - "безопасное" окно считаем по
    -- средней модели: ждать пессимистичного момента = отдать крипа ему
    local safeMode = ctx.contested and "avg" or "max"
    local tSafe, tDie = nil, nil
    for t = 0.05, 5.0, 0.05 do
        if not tDie then
            local lo = U.PredictHPWithContext(ctx, target, t, "min")
            if lo <= 0 then tDie = t end
        end
        if not tSafe then
            local hi = U.PredictHPWithContext(ctx, target, t, safeMode)
            if hi <= kill_threshold then tSafe = t end
        end
        if tSafe and tDie then break end
    end
    if tSafe and (not tDie or tSafe < tDie) then
        return tSafe, tDie or 999, ctx.contested and true or false
    end
    -- гарантированного окна нет: средняя модель (шанс)
    for t = 0.05, 5.0, 0.05 do
        local predHP = U.PredictHPWithContext(ctx, target, t, "avg")
        if predHP <= 0 then
            return -1, t, true
        elseif predHP <= kill_threshold then
            return t, tDie or 999, true
        end
    end
    return 999, 999, false
end

function U.GetActiveItemByName(bot, name)
    local slot = bot:FindItemSlot(name)
    if slot >= 0 and slot <= 5 then
        local item = bot:GetItemInSlot(slot)
        if item and item:IsFullyCastable() then return item end
    end
    return nil
end

local function TPFromHandle(item)
    if not item then return nil end
    local okN, nm = pcall(function() return item:GetName() end)
    if okN and type(nm) == "string" and nm:find("tpscroll") then return item end
    return nil
end

function U.GetTPScroll(bot)
    -- v2.7: свиток ТП в реальном API живёт в выделенном слоте, который GetItemInSlot/FindItemSlot
    -- видят не всегда (в enum Item_Slot_Types типа "TP" вообще нет). Пробуем все способы:
    -- FindItemSlot -> скан слотов -> GetAbilityByName (предметы в движке - те же хэндлы, что и способности).
    local ok, slot = pcall(function() return bot:FindItemSlot("item_tpscroll") end)
    if ok and type(slot) == "number" and slot >= 0 then
        local okI, item = pcall(function() return bot:GetItemInSlot(slot) end)
        if okI then
            local it = TPFromHandle(item)
            if it then return it, slot end
        end
    end
    for i = 0, 16 do
        local okI, item = pcall(function() return bot:GetItemInSlot(i) end)
        if okI then
            local it = TPFromHandle(item)
            if it then return it, i end
        end
    end
    local okA, ab = pcall(function() return bot:GetAbilityByName("item_tpscroll") end)
    if okA then
        local it = TPFromHandle(ab)
        if it then return it, -1 end
    end
    return nil, -1
end

-- v2.6: враг телепортируется (канал item_tpscroll). У СФ нет других каналов, поэтому
-- IsChanneling без имени активной способности тоже считаем ТП.
function U.IsEnemyTPChanneling(enemy)
    if not enemy then return false end
    local okC, ch = pcall(function() return enemy:IsChanneling() end)
    if not okC or not ch then return false end
    local okA, ab = pcall(function() return enemy:GetCurrentActiveAbility() end)
    if okA and ab then
        local okN, nm = pcall(function() return ab:GetName() end)
        if okN and nm ~= "item_tpscroll" then return false end
    end
    return true
end

function U.GetConsumableManaBurst(unit)
    if not unit then return 0 end
    local burst = 0
    burst = burst + U.GetMangoMana(unit) -- v2.5: по зарядам
    return burst
end

function U.GetStickCharges(unit)
    if not unit then return 0 end
    local best = 0
    for i = 0, 8 do
        local item = unit:GetItemInSlot(i)
        if item then
            local name = item:GetName()
            if name == "item_magic_wand" or name == "item_magic_stick" then
                local charges = (item.GetCurrentCharges and item:GetCurrentCharges()) or 0
                if charges > best then best = charges end
            end
        end
    end
    return best
end

-- v2.5: манго стакаются зарядами в одном слоте: считаем ЗАРЯДЫ (каждый = +100 маны, съедается
-- мгновенно), а не "есть предмет = +100". Только основной инвентарь (0-5): из рюкзака не съесть.
-- Для чужого героя - тот же обход слотов (Bot API отдаёт предметы видимого героя).
function U.GetMangoCharges(unit)
    if not unit then return 0 end
    local total = 0
    for i = 0, 5 do
        local okI, item = pcall(unit.GetItemInSlot, unit, i)
        if okI and item then
            local okN, name = pcall(item.GetName, item)
            if okN and name == "item_enchanted_mango" then
                local ch = 1
                if item.GetCurrentCharges then
                    local okC, c = pcall(item.GetCurrentCharges, item)
                    if okC and type(c) == "number" and c > 0 then ch = c end
                end
                total = total + ch
            end
        end
    end
    if total > 4 then total = 4 end
    return total
end

function U.GetMangoMana(unit)
    return U.GetMangoCharges(unit) * 100
end

function U.GetPotentialManaForRaze(unit)
    if not unit then return 0 end
    local mana = unit:GetMana() or 0
    mana = mana + U.GetConsumableManaBurst(unit)
    local charges = U.GetStickCharges(unit)
    if charges > 0 then
        mana = mana + charges * 15
    end
    return mana
end

function U.HasBoots(unit)
    if not unit then return false end
    return U.HasItem(unit, "item_boots") or U.HasItem(unit, "item_power_treads")
end

function U.HasItem(unit, item_name)
    if not unit then return false end
    if not U.CanQuery(unit) and not unit:IsBot() then return false end
    for i = 0, 8 do -- инвентарь + рюкзак (стэш/TP-слот не считаем)
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then return true end
    end
    return false
end

function U.GetItemCount(unit, item_name)
    if not unit then return 0 end
    if not U.CanQuery(unit) and not unit:IsBot() then return 0 end
    local count = 0
    for i = 0, 8 do
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then
            count = count + 1
        end
    end
    return count
end

function U.GetLaneItemPower(unit)
    if not unit then return 0 end
    local score = 0
    score = score + U.GetItemCount(unit, "item_bracer") * 0.90
    score = score + U.GetItemCount(unit, "item_magic_wand") * 0.35
    score = score + U.GetItemCount(unit, "item_magic_stick") * 0.20
    if U.HasItem(unit, "item_boots") then score = score + 0.25 end
    if U.HasItem(unit, "item_power_treads") then score = score + 0.50 end
    if U.HasItem(unit, "item_kaya") then score = score + 1.00 end
    if U.HasItem(unit, "item_dragon_lance") then score = score + 0.90 end
    return score
end

function U.ManageInventorySlots(bot)
    for bpSlot = 6, 8 do
        local bpItem = bot:GetItemInSlot(bpSlot)
        if bpItem then
            local bpPrio = C.ITEM_PRIORITY[bpItem:GetName()] or 0
            if bpItem:GetName() == "item_ward_observer" then bpPrio = 999 end
            local worstSlot = -1
            local worstPrio = 999
            local hasEmptySlot = false
            for invSlot = 0, 5 do
                local invItem = bot:GetItemInSlot(invSlot)
                if not invItem then
                    hasEmptySlot = true
                    worstSlot = invSlot
                    break
                else
                    local invPrio = C.ITEM_PRIORITY[invItem:GetName()] or 0
                    if invPrio < worstPrio then
                        worstPrio = invPrio
                        worstSlot = invSlot
                    end
                end
            end
            if hasEmptySlot or bpPrio > worstPrio then
                bot:ActionImmediate_SwapItems(bpSlot, worstSlot)
                return
            end
        end
    end
end

function U.GetSafeClosestTree(bot, enemyTowers)
    local trees = bot:GetNearbyTrees(1200)
    if not trees or #trees == 0 then return nil end
    if not enemyTowers or #enemyTowers == 0 then return trees[1] end
    for _, tree in ipairs(trees) do
        local treeLoc = GetTreeLocation(tree)
        local isSafe = true
        for _, tower in pairs(enemyTowers) do
            if tower:IsAlive() and GetUnitToLocationDistance(tower, treeLoc) < 850 then
                isSafe = false
                break
            end
        end
        if isSafe then return tree end
    end
    return nil
end

function U.IsEnemyCastingRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if (r1 and r1:IsInAbilityPhase()) or
       (r2 and r2:IsInAbilityPhase()) or
       (r3 and r3:IsInAbilityPhase()) then
        return true
    end
    return false
end

function U.EnemyHasRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    if r1 and r1:GetLevel() > 0 then return true end
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    if r2 and r2:GetLevel() > 0 then return true end
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if r3 and r3:GetLevel() > 0 then return true end
    return false
end

U._razeTracker = {
    enemies = {},
    lastMissTime = -math.huge,
    lastMissEntindex = nil,
}

local function _getEnemyRazeTrackerEntry(enemy)
    if not enemy then return nil end
    local key = (enemy.GetPlayerID and enemy:GetPlayerID()) or tostring(enemy)
    if key == nil or (type(key) == "number" and key < 0) then key = tostring(enemy) end
    local entry = U._razeTracker.enemies[key]
    if not entry then
        entry = {
            wasCasting = false,
            lastPhaseEndTime = -math.huge,
            pendingMissCheck = false,
            pendingLabel = nil,
            prevDebuffStacks = 0,
            prevDebuffRemain = 0,
            lastHitLabel = nil,
            lastHitTime = -math.huge,
        }
        U._razeTracker.enemies[key] = entry
    end
    return entry
end

function U.UpdateEnemyRazeMissTracker(bot, enemy)
    if not U.CanQuery(enemy) then return end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return end

    local now = GameTime()
    local casting = U.IsEnemyCastingRaze(enemy)

    if entry.wasCasting and not casting then
        entry.lastPhaseEndTime = now
        entry.pendingMissCheck = true
        entry.prevDebuffStacks = U.GetShadowrazeDebuff(bot) or 0
        local castDist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        entry.pendingLabel = U.GetRazeLabelByDistance(castDist, C.RAZE.HIT_RADIUS)
    end

    entry.wasCasting = casting

    if entry.pendingMissCheck then
        local stacksNow = U.GetShadowrazeDebuff(bot) or 0
        if stacksNow > entry.prevDebuffStacks then
            entry.pendingMissCheck = false
            entry.lastHitLabel = entry.pendingLabel
                or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
            entry.lastHitTime = now
            entry.pendingLabel = nil
        elseif (now - entry.lastPhaseEndTime) >= C.RAZE.MISS_DETECT_WINDOW then
            entry.pendingMissCheck = false
            U._razeTracker.lastMissTime = now
            U._razeTracker.lastMissEntindex = (enemy.GetPlayerID and enemy:GetPlayerID()) or nil
            entry.pendingLabel = nil
        end
    end
end

function U.HasEnemyMissedRazeRecently()
    return (GameTime() - (U._razeTracker.lastMissTime or -math.huge)) <= C.RAZE.MISS_ADVANTAGE_TIME
end

function U.GetEnemyMissAge()
    return GameTime() - (U._razeTracker.lastMissTime or -math.huge)
end

function U.GetRecentEnemyRazeHitLabel(enemy)
    if not enemy then return nil end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return nil end
    return entry.lastHitLabel
end

function U.GetRecentEnemyRazeHitAge(enemy)
    if not enemy then return math.huge end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return math.huge end
    return GameTime() - (entry.lastHitTime or -math.huge)
end

function U.IsSecondStackDangerActive(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 or rem_time <= C.RAZE.RETREAT_MIN_REMAIN then
        return false, nil
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemy)
    if not hitLabel then return false, nil end
    return true, hitLabel
end

function U.IsForbiddenSecondStackBand(bot, enemy, dist)
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if not active then return false, nil, nil end
    local radius = (C.RAZE and C.RAZE.SECOND_STACK_AVOID_RADIUS) or C.RAZE.STRICT_RADIUS or 190
    local currentBand = U.GetRazeLabelByDistance(dist, radius)
    if currentBand and currentBand ~= hitLabel then
        return true, hitLabel, currentBand
    end
    return false, hitLabel, currentBand
end

function U.IsEnemyRegenerating(enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local mods = {
        "modifier_flask_healing",
        "modifier_clarity_potion",
        "modifier_tango_heal",
        "modifier_bottle_regeneration",
    }
    for _, m in ipairs(mods) do
        if enemy:HasModifier(m) then return true, m end
    end
    return false, nil
end

function U.IsEnemyHighValueRegen(enemy)
    if not U.CanQuery(enemy) then return false end
    if enemy:HasModifier("modifier_flask_healing") then return true end
    if enemy:HasModifier("modifier_clarity_potion") then return true end
    if enemy:HasModifier("modifier_bottle_regeneration") then return true end
    return false
end

function U.GetPlaystyle(bot, enemy, allyCreeps, enemyCreeps)
    if not U.CanQuery(enemy) then return "NEUTRAL" end

    local score = 0
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    score = score + (myLvl - eLvl) * 1.5

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    local myRazeLvl = q and q:GetLevel() or 0
    local eRazeLvl = eq and eq:GetLevel() or 0
    if myRazeLvl > eRazeLvl then score = score + 2.5 end
    if myRazeLvl < eRazeLvl then score = score - 2.5 end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local eHpPct = enemy:GetHealth() / enemy:GetMaxHealth()
    score = score + (myHpPct - eHpPct) * 3.2
    if bot:GetHealth() < 400 then score = score - 2.0 end
    if enemy:GetHealth() < 350 then score = score + 0.8 end

    local eHasMango = U.HasItem(enemy, "item_enchanted_mango")
    local myHasMango = U.HasItem(bot, "item_enchanted_mango")
    local eTotalMana = enemy:GetMana() + (eHasMango and 100 or 0)
    local myTotalMana = bot:GetMana() + (myHasMango and 100 or 0)
    if myTotalMana >= 150 and eTotalMana < 75 then score = score + 2.0 end
    if eTotalMana >= 150 and myTotalMana < 75 then score = score - 1.5 end

    local soulDmgDiff = S.GetSoulDamageBonus(bot) - S.GetSoulDamageBonus(enemy)
    score = score + Clamp(soulDmgDiff / 14.0, -2.5, 2.5)

    local itemPowerDiff = U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemy)
    score = score + Clamp(itemPowerDiff, -2.0, 2.0)

    local allyCount = allyCreeps and #allyCreeps or 0
    local enemyCount = enemyCreeps and #enemyCreeps or 0
    score = score + ((allyCount - enemyCount) * 0.25)

    if U.HasEnemyMissedRazeRecently() then score = score + 3.5 end
    if U.HasItem(bot, "item_power_treads") and not U.HasBoots(enemy) then
        score = score + 2.5
    end

    if score <= -2.0 then
        return "PASSIVE"
    elseif score >= 0.8 then
        return "AGGRESSIVE"
    else
        return "NEUTRAL"
    end
end

function U.GetShadowrazeDebuff(unit)
    if not unit then return 0, 0, -1 end
    local numModifiers = unit:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = unit:GetModifierName(i)
            if modName == "modifier_nevermore_shadowraze_debuff" then
                local stacks = unit:GetModifierStackCount(i) or 0
                local remaining = unit:GetModifierRemainingDuration(i) or 0
                return stacks, remaining, i
            end
        end
    end
    return 0, 0, -1
end

-- Предсказание позиции по РЕАЛЬНОЙ скорости (GetVelocity), а не "facing x макс. скорость".
-- Старый вариант считал, что стоящий на месте враг (например, добивающий крипа) за 0.62 с
-- сместится на ~190 юнитов в сторону взгляда -> рейзы по стоящему врагу систематически мазали.
function U.PredictPosition(unit, delay)
    local loc = unit:GetLocation()
    if not loc then return loc end
    delay = delay or 0
    local vel = nil
    if unit.GetVelocity then
        local ok, v = pcall(unit.GetVelocity, unit)
        if ok and v and v.x then vel = v end
    end
    if vel then
        local sp = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if sp < 40 then return loc end
        local maxSp = unit:GetCurrentMovementSpeed() or 0
        local vx, vy = vel.x, vel.y
        if maxSp > 0 and sp > maxSp * 1.05 then
            vx, vy = vx / sp * maxSp, vy / sp * maxSp
        end
        local stability = 1
        if unit.GetMovementDirectionStability then
            stability = unit:GetMovementDirectionStability() or 1
        end
        if stability < 0.5 then delay = delay * 0.5 end
        -- v2.8: редкие промахи (1 из 10-15) - цель РАЗВОРАЧИВАЕТСЯ во время каста.
        -- Один слот истории скорости (без таблиц на юнита - память ограничена): если за
        -- последние <=0.35 с направление изменилось больше чем на ~45 градусов, цель
        -- непредсказуема - урезаем упреждение и берём сглаженную скорость.
        local hist = U._velHist
        local nowT = GameTime()
        if hist and hist.unit == unit and (nowT - hist.t) <= 0.35 and (nowT - hist.t) > 0.001 then
            local pmag = math.sqrt(hist.vx * hist.vx + hist.vy * hist.vy)
            local cmag = math.sqrt(vx * vx + vy * vy)
            if pmag > 40 and cmag > 40 then
                local cosang = (hist.vx * vx + hist.vy * vy) / (pmag * cmag)
                if cosang < 0.7 then
                    delay = delay * 0.6
                    vx = vx * 0.6 + hist.vx * 0.4
                    vy = vy * 0.6 + hist.vy * 0.4
                end
            end
            hist.t = nowT; hist.vx = vel.x; hist.vy = vel.y
        else
            U._velHist = { unit = unit, t = nowT, vx = vel.x, vy = vel.y }
        end
        return Vector(loc.x + vx * delay, loc.y + vy * delay, loc.z)
    end
    -- запасной путь (нет GetVelocity): старое поведение
    local stability = 1
    if unit.GetMovementDirectionStability then
        stability = unit:GetMovementDirectionStability() or 1
    end
    if stability < 0.5 then return loc end
    local speed = unit:GetCurrentMovementSpeed() or 0
    local facingRad = math.rad(unit:GetFacing() or 0)
    return Vector(
        loc.x + math.cos(facingRad) * speed * delay,
        loc.y + math.sin(facingRad) * speed * delay,
        loc.z
    )
end

function U.GetAngleDifference(bot, targetLoc)
    local botLoc = bot:GetLocation()
    local facing = bot:GetFacing()
    local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
    if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
    local diff = math.abs(facing - angleToTarget)
    if diff > 180 then diff = 360 - diff end
    return diff
end

function U.GetRazeAbilityData(ability)
    if not ability then return nil end
    local name = ability:GetName()
    if name == "nevermore_shadowraze1" then return { center = C.RAZE.NEAR_CENTER, label = "near" } end
    if name == "nevermore_shadowraze2" then return { center = C.RAZE.MID_CENTER,  label = "mid" } end
    if name == "nevermore_shadowraze3" then return { center = C.RAZE.FAR_CENTER,  label = "far" } end
    return nil
end

function U.GetFacingVector(unit)
    local rad = math.rad(unit:GetFacing() or 0)
    return Vector(math.cos(rad), math.sin(rad), 0)
end

function U.GetRazeCircleCenter(bot, centerDistance)
    local loc = bot:GetLocation()
    local forward = U.GetFacingVector(bot)
    return Vector(
        loc.x + forward.x * centerDistance,
        loc.y + forward.y * centerDistance,
        loc.z
    )
end

function U.GetRazeHitErrorWithCurrentFacing(bot, targetLoc, centerDistance)
    local center = U.GetRazeCircleCenter(bot, centerDistance)
    return U.DistanceBetweenLocations(center, targetLoc)
end

function U.GetRazeHitErrorWithDesiredFacing(bot, targetLoc, centerDistance)
    local dist = GetUnitToLocationDistance(bot, targetLoc)
    return math.abs(dist - centerDistance)
end

function U.IsRazeAbilityCastable(bot, ability)
    if not ability or not ability:IsFullyCastable() then return false end
    return bot:GetMana() >= 75
end

-- Робастное наведение рейза (v2.2). Круг рейза (R=250) должен накрыть врага И там, где он
-- СЕЙЧАС, И там, где окажется через delay, если продолжит движение. Наводимся на середину
-- отрезка между этими точками. Одна предсказанная точка давала систематические промахи:
-- враг встал - промах "вперёд" (рейз лёг туда, куда он "должен был дойти"), враг пошёл/ускорился
-- после нашего решения - промах "назад".
-- Возвращает: errAim (худшая из двух ошибок при идеальном повороте на aim), errFacing (то же
-- при ТЕКУЩЕМ развороте - рейз летит туда, куда смотрим), aim (точка наведения), pPred.
function U.RobustRazeErrors(bot, target, center, delay)
    local botLoc = bot:GetLocation()
    local pNow = target:GetLocation()
    local pPred = U.PredictPosition(target, delay or C.RAZE.PREDICT_DELAY) or pNow
    local aim = Vector((pNow.x + pPred.x) * 0.5, (pNow.y + pPred.y) * 0.5, pNow.z)
    local dx, dy = aim.x - botLoc.x, aim.y - botLoc.y
    local d = math.sqrt(dx * dx + dy * dy)
    local ux, uy
    if d < 1 then
        local f = U.GetFacingVector(bot)
        ux, uy = f.x, f.y
    else
        ux, uy = dx / d, dy / d
    end
    local function worst(cx, cy)
        local e1 = math.sqrt((pNow.x - cx) * (pNow.x - cx) + (pNow.y - cy) * (pNow.y - cy))
        local e2 = math.sqrt((pPred.x - cx) * (pPred.x - cx) + (pPred.y - cy) * (pPred.y - cy))
        return math.max(e1, e2)
    end
    local errAim = worst(botLoc.x + ux * center, botLoc.y + uy * center)
    local f = U.GetFacingVector(bot)
    local errFacing = worst(botLoc.x + f.x * center, botLoc.y + f.y * center)
    return errAim, errFacing, aim, pPred
end

-- Попадёт ли рейз при ТЕКУЩЕМ развороте (робастно: и по текущей, и по предсказанной точке).
-- Третье значение - точка наведения (для поворота), а не "предсказанная позиция", как раньше.
function U.WillRazeHit(bot, ability, target, delay, strict)
    if not ability or not target or not target:IsAlive() then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, delay or C.RAZE.CAST_POINT)
    local limit = strict and C.RAZE.STRICT_RADIUS or (C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30))
    return errFacing <= limit, errFacing, aim, errAim
end

function U.GetBestRaze(bot, target, mode, isLethalChase, forceExtend)
    if bot:GetMana() < 75 then return nil, nil, nil end
    if not U.CanQuery(target) then return nil, nil, nil end

    isLethalChase = isLethalChase or false
    forceExtend = forceExtend or false

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")

    local stacks, rem_time = U.GetShadowrazeDebuff(target)
    local lowHpFinish = target:GetHealth() <= 380
    local lethalWithTwo = U.GetTwoRazeDamage(bot, target) >= target:GetHealth() * 0.95
    -- v2.2: "летально двумя" - только по РЕАЛЬНО доступным рейзам (кулдауны/мана), иначе
    -- "режим добивания" включался с одним оставшимся рейзом и давал рискованные касты
    local Rk = U._K and U._K._race
    if Rk and Rk.valid then lethalWithTwo = Rk.canKillSoon end
    local interruptRegen = U.IsEnemyHighValueRegen(target)
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local mustKillNow = lethalWithTwo or lowHpFinish or isLethalChase or forceExtend

    -- v2.2: правило "один стак и до истечения > EXTEND_AT -> не кастуем" УБРАНО. Оно откладывало
    -- второй рейз на ~3 с ради "продления" стака, а уходящий враг за это время покидал все
    -- полосы: второй стак (бесплатный, он не отвечает) терялся. Теперь второй/третий рейз идёт
    -- сразу, если робастно накрывает; дисциплина маны - у вызывающего (HarassManaOK/followUp).

    local predLoc = U.PredictPosition(target, C.RAZE.PREDICT_DELAY)
    local myDist = GetUnitToLocationDistance(bot, predLoc)
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)
    local robustMargin = C.RAZE.ROBUST_MARGIN or 30
    local targetStationary = true
    if target.GetVelocity then
        local okV, tv = pcall(target.GetVelocity, target)
        if okV and tv and tv.x then
            targetStationary = math.sqrt(tv.x * tv.x + tv.y * tv.y) < 60
        end
    end

    local candidates = {
        { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" },
        { ability = w, center = C.RAZE.MID_CENTER,  label = "mid"  },
        { ability = e, center = C.RAZE.FAR_CENTER,  label = "far"  },
    }

    local best = nil
    local bestScore = math.huge

    for _, candidate in ipairs(candidates) do
        local ability = candidate.ability
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local allow = true

            if secondStackActive and safeReplyLabel and data.label ~= safeReplyLabel then
                allow = false
            end

            if data.label == "far" and mode == "NEUTRAL" and stacks == 0
               and not secondStackActive
               and not U.IsEnemyCastingRaze(target)
               and not interruptRegen and not enemyMissed and not mustKillNow then
                allow = false
            end

            if allow then
                -- Робастная ошибка: худшая из двух точек (сейчас / через PREDICT_DELAY) при наведении
                -- на их середину. Лимит - радиус круга минус допуск; для добивания/продления/ответа
                -- допуск меньше (важнее не упустить), для хараса - больше (важнее не промахнуться).
                local errAim, errFacing, aimLoc = U.RobustRazeErrors(bot, target, data.center, C.RAZE.PREDICT_DELAY)
                local plannedError = errAim
                local limit = C.RAZE.HIT_RADIUS - robustMargin
                if targetStationary then
                    -- стоящий враг может начать движение во время каста: нужен запас от края круга
                    -- (100 u ~ 0.33 с его хода); у края полосы такого врага не трогаем
                    limit = C.RAZE.HIT_RADIUS - 100
                    -- v2.3: добивание стака (враг уже бит, стак >= 1.2 с) - допуск мягче (60 u):
                    -- ценность попадания выше, а "робастная" ошибка и так учитывает обе точки
                    if stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then
                        limit = C.RAZE.HIT_RADIUS - 60
                    end
                end
                -- v2.5: "чистый" харас (не добивание, не ответ на его рейз, не стак): реагирующий враг
                -- выходит из круга за каст (0.55 с ~ 150 u), если до края круга < ~110 u. Поэтому для
                -- хараса требуем errAim <= 160 (он ближе к центру полосы), а не 220 "у края".
                local followUpStack = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
                if not (mustKillNow or forceExtend or interruptRegen or secondStackActive or followUpStack) then
                    limit = math.min(limit, C.RAZE.HIT_RADIUS - (C.RAZE.HARASS_MARGIN or 90))
                end
                if mustKillNow or forceExtend or interruptRegen or secondStackActive then
                    limit = C.RAZE.HIT_RADIUS - 10
                    -- v2.5: СТОЯЩИЙ враг у края полосы реагирует на анимацию каста (0.55 с = 150+ u
                    -- хода): если этот рейз сам по себе его не убивает, запас от края сохраняем -
                    -- иначе цикл "каст у края -> он шагнул -> отмена -> каст" (и промах в игре).
                    local killNow = Rk and Rk.valid and Rk.canKillNow
                    if targetStationary and not killNow and not forceExtend and not isLethalChase and not secondStackActive then
                        limit = math.min(limit, C.RAZE.HIT_RADIUS - 70)
                    end
                end
                local gamble = false
                -- v2.5: ставка "по предсказанию" только когда этот рейз реально решает (убивает
                -- сейчас / летальная погоня / продление стака), а не просто "у него мало HP":
                -- иначе бот кидал рейз в край круга по стоящему врагу с 380 HP и промахивался.
                local gambleWorth = isLethalChase or forceExtend or (Rk and Rk.valid and Rk.canKillNow)
                if plannedError > limit and gambleWorth then
                    -- добивание: робастно не накрываем - допускаем ставку на предсказание (как раньше)
                    local predOnly = U.GetRazeHitErrorWithDesiredFacing(bot, predLoc, data.center)
                    if predOnly <= C.RAZE.HIT_RADIUS then
                        plannedError = predOnly
                        limit = C.RAZE.HIT_RADIUS
                        aimLoc = predLoc
                        errFacing = U.GetRazeHitErrorWithCurrentFacing(bot, predLoc, data.center)
                        gamble = true
                    end
                end

                if data.label == "near" and not isLethalChase and not forceExtend then
                    local realDist = GetUnitToLocationDistance(bot, aimLoc)
                    if realDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                        plannedError = math.huge
                    end
                end

                if data.label == "near" and not mustKillNow then
                    if U.HasStackAndShouldFearNear(bot, target) then
                        plannedError = math.huge
                    end
                end

                if plannedError <= limit then
                    local score = plannedError
                    if gamble then score = score + 60 end

                    if secondStackActive and safeReplyLabel and data.label == safeReplyLabel then
                        score = score - 140
                    elseif stacks == 0 and not mustKillNow then
                        if mode == "AGGRESSIVE" then
                            -- открываемся дальним: кастуем из-за пределов его автоатаки и его
                            -- ближних полос; подойдёт - его встретит средний, отойдёт - он уже бит
                            if data.label == "far" then score = score - 60 end
                            if data.label == "mid" then score = score - 40 end
                            if data.label == "near" then score = score + 10 end
                        else
                            if data.label == "mid" then score = score - 60 end
                            if data.label == "far" then score = score + 20 end
                            if data.label == "near" then score = score + 10 end
                        end
                    else
                        local distDiff = math.abs(myDist - data.center)
                        score = score - math.max(0, 80 - distDiff * 0.5)
                        if stacks >= C.FINISH.MIN_STACKS_FOR_CLOSE and data.label == "near" then
                            score = score - 80
                        end
                    end

                    if forceExtend and bootsAdvantage then
                        if data.label == "far" then score = score + 120 end
                        if data.label == "mid" then score = score - 90 end
                    elseif forceExtend and not bootsAdvantage then
                        if data.label == "mid" then score = score - 30 end
                    end

                    if mustKillNow then
                        score = score - 200
                        local distDiff2 = math.abs(myDist - data.center)
                        if distDiff2 < 80 then score = score - 50 end
                    elseif forceExtend then
                        score = score - 150
                    elseif stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6 then
                        score = score - 110
                    elseif stacks >= 2 then
                        score = score - 45
                    end

                    if interruptRegen then score = score - 130 end
                    if enemyMissed then score = score - 55 end

                    if score < bestScore then
                        bestScore = score
                        best = { ability = ability, data = data, aimLoc = aimLoc, limit = limit, errFacing = errFacing }
                    end
                end
            end
        end
    end

    if best then
        -- Рейз летит туда, куда смотрим: если при текущем развороте круг накрывает обе точки
        -- (с небольшим запасом) - кастуем сразу, иначе доворачиваемся на точку наведения.
        -- v2.3: порог каста = порогу кандидата (иначе "мёртвая зона": после доворота
        -- errFacing == plannedError в (limit-15, limit] -> TURN каждый тик, каста нет - бот трясётся)
        if best.errFacing <= best.limit then
            return best.ability, "CAST", best.aimLoc
        end
        return best.ability, "TURN", best.aimLoc
    end

    return nil, nil, nil
end

function U.GetRazeSetupPosition(bot, target)
    if not U.CanQuery(target) then return nil end

    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local myDist = GetUnitToLocationDistance(bot, targetLoc)
    local stacks = U.GetShadowrazeDebuff(target)
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local bestCenter = nil
    local bestScore = math.huge
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)

    if secondStackActive and safeReplyLabel then
        local forcedAbility = nil
        if safeReplyLabel == "near" then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze1") end
        if safeReplyLabel == "mid"  then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze2") end
        if safeReplyLabel == "far"  then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze3") end
        if forcedAbility and U.IsRazeAbilityCastable(bot, forcedAbility) then
            bestCenter = U.GetRazeCenterByLabel(safeReplyLabel)
        end
    end

    if not bestCenter then
        local abilities = {
            bot:GetAbilityByName("nevermore_shadowraze2"),
            bot:GetAbilityByName("nevermore_shadowraze3"),
            bot:GetAbilityByName("nevermore_shadowraze1"),
        }
        for _, ability in ipairs(abilities) do
            local data = U.GetRazeAbilityData(ability)
            if data and U.IsRazeAbilityCastable(bot, ability) then
                local distDiff = math.abs(myDist - data.center)
                local score = distDiff
                if stacks == 0 then
                    if data.label == "mid" then score = score - 80 end
                    if data.label == "far" then score = score + 30 end
                    if data.label == "near" then score = score + 20 end
                else
                    if data.label == "mid" then score = score - 15 end
                end
                if data.label == "near" and U.HasStackAndShouldFearNear(bot, target) then
                    score = score + 9999
                end
                if bootsAdvantage then
                    if data.label == "far" then score = score + 80 end
                    if data.label == "mid" then score = score - 50 end
                end
                if score < bestScore then
                    bestScore = score
                    bestCenter = data.center
                end
            end
        end
    end

    if not bestCenter then bestCenter = C.RAZE.MID_CENTER end

    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * bestCenter
end

-- Есть ли у врага рейз, готовый в ближайшие horizon сек (по трекеру фаз каста) и мана на него.
-- IsFullyCastable для чужих способностей кулдаун не видит, поэтому доверяем только трекеру;
-- если трекер не подключён - считаем, что рейз есть (консервативно).
function U.EnemyCanUseRaze(enemy, horizon)
    if not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    if U._K then
        local n = U._K.EnemyReadyRazeCount(enemy, horizon or 1.0, true)
        return n > 0
    end
    local totalMana = enemy:GetMana() + U.GetMangoMana(enemy)
    return totalMana >= 75
end

function U.GetRetreatPositionFromEnemySF(bot, enemy)
    local botLoc = bot:GetLocation()
    local enemyLoc = enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if U.DistanceBetweenLocations(botLoc, enemyLoc) < 1 then
        away = fountain - botLoc
    end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    return botLoc + away * 680 + toFountain * 360
end

-- Нужно ли отступать из-за стаков рейза на мне. Решение по доступному бурсту врага
-- (трекер кулдаунов + мана + досягаемость полос) и абсолютным HP, а не "по умолчанию".
-- Возвращает shouldRetreat, retreatLoc, reason.
function U.ShouldRetreatFromEnemyRazeStack(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    if not U.EnemyHasRaze(enemy) then return false, nil end
    local K = U._K
    if not K then
        -- запасной путь без трекера: старое поведение
        local dist0 = GetUnitToLocationDistance(enemy, bot:GetLocation())
        local stacks0, rem0 = U.GetShadowrazeDebuff(bot)
        if stacks0 >= 2 and rem0 > C.RAZE.RETREAT_MIN_REMAIN and dist0 <= (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS) then
            return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "legacy"
        end
        return false, nil
    end

    local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
    local hp = bot:GetHealth()
    local R = K._race
    if not (R and R.valid) then R = K.Race(bot, enemy, false) end

    -- 1) его доступный бурст убивает меня, а я его "сейчас" - нет -> уходим
    if R.heCanKillSoon and not R.canKillNow then
        return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "lethal burst"
    end

    -- 2) я стою глубоко в его ГОТОВОЙ полосе: один его рейз съест заметный кусок HP, а размен
    --    не в мою пользу -> отходим к "увернительному" краю полосы (не к фонтану и не за все полосы).
    --    v2.3: условия страха ужесточены в FearBandPredicate (стак на мне или >= 45 % HP за рейз);
    --    и не отступаем, уже стоя у своей Т1 (дальше отходить некуда - башня его накажет).
    local nearOwnT1 = false
    local ownT1 = (U._W and U._W.s and U._W.s.allyT1) or nil
    if ownT1 then
        local okL, tl = pcall(ownT1.GetLocation, ownT1)
        if okL and tl and U.DistanceBetweenLocations(tl, bot:GetLocation()) <= 400 then nearOwnT1 = true end
    end
    -- v2.4: скорость сближения врага (>0 - идёт на меня). При равной скорости бега он не догонит
    -- УХОДЯЩЕГО бота, но догонит СТОЯЩЕГО: порог отхода и длина шага растут на его скорость
    -- сближения (раньше: шаг 60-100 u, бот останавливался, враг подходил вплотную к полосе и
    -- клал 2-й/3-й рейз - "бот не спешил отходить").
    local approach = U.EnemyApproachSpeed(bot, enemy)
    local band = K.EnemyReadyBandAt(enemy, dist, 1.0) or K.EnemyReadyBandAt(enemy, dist - approach * 0.7, 1.0)
    -- 2b) v2.3: на мне свежий стак, он стоит в своей ГОТОВОЙ полосе и размен не в мою пользу ->
    --     не даём накопить 2-й/3-й/4-й стак: выходим за край его готовых полос до истечения стака
    --     (6 с). Исключение - выгодный размен или гарантированное убийство.
    --     v2.4: "выгодный размен" только если я реально могу ответить (мана >= 75 и рейз готов):
    --     раньше бот с 66 маны считал размен выгодным, стоял и собирал 3 стака.
    --     v2.4: исключение "у своей Т1" снято для 2b - за башню отойти можно всегда.
    local stackedFresh = false
    do
        local st, rem = U.GetShadowrazeDebuff(bot)
        stackedFresh = (st or 0) >= 1 and (rem or 0) >= 1.0
    end
    if band and stackedFresh and not R.canKillSoon and not U.IsStackTradeFavorable(bot, R) then
        local safe = K.EnemyMinSafeDistance(enemy, 1.0)
        local trigger = safe + approach * 0.7
        if safe > 0 and dist < trigger - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            if approach > 60 and need < 300 then need = 300 end
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "stacked, in ready band"
        end
    end
    if band and not nearOwnT1 and U.FearBandPredicate(bot, enemy, R) then
        local safe = K.EnemyDodgeableDistance(enemy, 1.0)
        if dist < safe + approach * 0.7 - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "in ready band"
        end
    end

    return false, nil
end

-- v2.4: скорость сближения врага со мной (u/с, > 0 - идёт на меня; 0 - стоит/уходит/вбок).
function U.EnemyApproachSpeed(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return 0 end
    local okV, v = pcall(enemy.GetVelocity, enemy)
    if not okV or not v then return 0 end
    local vx, vy = v.x or 0, v.y or 0
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 60 then return 0 end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return 0 end
    local ax, ay = (botLoc.x - enLoc.x) / d, (botLoc.y - enLoc.y) / d
    local toward = vx * ax + vy * ay
    if toward <= 0 then return 0 end
    return toward
end

-- v2.4: "выгодный размен со стаком на мне": перевес >= 60, мои HP >= его И я реально могу ответить
-- рейзом (мана >= 75, хотя бы один мой рейз готов в ближайшие ~2.5 с и достаёт его).
function U.IsStackTradeFavorable(bot, R)
    if not (R and R.valid) then return false end
    if R.canKillSoon then return true end
    if R.edge < 60 or R.myHp < R.enHp then return false end
    if (bot:GetMana() or 0) < 75 then return false end
    if (R.myRazesSoon or 0) < 1 then return false end
    return true
end

-- Единый предикат "страха полосы": один его рейз >= 30% моих HP, размен не в мою пользу,
-- и я не могу убить его в ответ одним рейзом.
function U.FearBandPredicate(bot, enemy, R)
    local K = U._K
    if not K or not (R and R.valid) then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local canKillBack = myOneRaze >= enemy:GetHealth() and K.MyReadyRazeCount(bot, true) > 0
    if canKillBack then return false end
    if R.edge >= 0 then return false end
    local hp = bot:GetHealth()
    -- v2.3: без стака на мне один его рейз - неприятный, но не критичный размен; "страх полосы"
    -- (отход за край его дальней полосы = за ~900 от него) без стака выгонял более слабого бота
    -- с линии от любого шага врага вперёд и давал дёрганье "к башне и обратно". Теперь страх
    -- только со стаком (следующий рейз с бонусом) или если один рейз снимает >= 45 % HP.
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local stackedMe = (myStacks or 0) >= 1 and (myRem or 0) >= 1.0
    if stackedMe then return oneRaze >= hp * 0.30 end
    return oneRaze >= hp * 0.45
end

-- Минимальная дистанция до врага, которую сейчас требует наш "страх" (0 = ограничений нет).
-- Тот же предикат используют: отход из полосы, подход к врагу, позиция для ласт-хитов и
-- итоговая позиция - чтобы разные обработчики не тянули бота в разные стороны (осцилляция).
-- v2.3: "страх средней полосы" (сухая мана против его рейза / он взял 2-й уровень первым / он
-- быстрее по ботинкам) - флаг ставит RealThink каждый тик. Пока он активен, минимальная дистанция
-- до врага = внешний край его средней полосы: за крипом в полосу не заходим ПРОАКТИВНО, а не
-- "зашёл за крипом -> испугался -> отбежал на 1000 -> вернулся за крипом" по кругу.
U._midFear = false
U.MID_FEAR_DIST = C.RAZE.MID_CENTER + 210 + 40   -- 700

function U.GetFearMinDist(bot, enemy)
    local K = U._K
    if not K or not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local R = K._race
    local best = U._midFear and U.MID_FEAR_DIST or 0
    if not (R and R.valid) then return best end
    if R.heCanKillSoon and not R.canKillNow then return math.max(best, K.EnemyMinSafeDistance(enemy, 1.0)) end
    if U.FearBandPredicate(bot, enemy, R) then return math.max(best, K.EnemyDodgeableDistance(enemy, 1.0)) end
    return best
end

-- Короткий выход за край его средней полосы (вместо отхода на ~1000 к фонтану из
-- GetRetreatPositionFromEnemySF): шаг только на нужную длину, чуть в сторону фонтана.
function U.GetMidBandExitPosition(bot, enemy)
    local botLoc, enemyLoc = bot:GetLocation(), enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local toFountain = (fountain - botLoc):Normalized()
    local away = (dist > 1) and (botLoc - enemyLoc):Normalized() or toFountain
    local dir = (away * 0.75 + toFountain * 0.25):Normalized()
    local need = (U.MID_FEAR_DIST + 60) - dist + 40
    if need < 120 then need = 120 end
    return botLoc + dir * need
end

function U.SwitchTreadsIfNeeded(bot, targetStat)
    local treadsSlot = bot:FindItemSlot("item_power_treads")
    if treadsSlot < 0 or treadsSlot > 5 then return end
    local pt = bot:GetItemInSlot(treadsSlot)
    if not pt or not pt:IsFullyCastable() then return end

    if not bot._pt_state then bot._pt_state = 0 end

    local current = bot._pt_state
    if type(pt.GetPowerTreadsStat) == "function" then
        current = pt:GetPowerTreadsStat()
        bot._pt_state = current
    end

    if current ~= targetStat then
        if GameTime() > (bot._lastTreadSwitchTime or 0) + 0.15 then
            bot:Action_UseAbility(pt)
            bot._pt_state = (bot._pt_state + 1) % 3
            bot._lastTreadSwitchTime = GameTime()
        end
    end
end

function U.GetRazeSetupPositionForAbility(bot, target, centerDistance)
    if not target then return bot:GetLocation() end
    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * centerDistance
end

-- Сырой урон рейза: база + стаки*бонус + души*2 (7.41f). Талант +30 к стаку уже внутри
-- GetSpecialValueInt("stack_bonus_damage"), если талант изучен.
function U.GetRazeRawDamage(ability, stacks, souls)
    if not ability or ability:GetLevel() == 0 then return 0 end
    local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = ability:GetSpecialValueInt("stack_bonus_damage") or 0
    local perSoul = ability:GetSpecialValueInt("damage_per_soul") or 0
    if not perSoul or perSoul <= 0 then perSoul = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2 end
    return baseDmg + (stacks or 0) * stackDmg + (souls or 0) * perSoul
end

function U.GetNRazeDamage(bot, target, razeCount)
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    if not target or not target:IsAlive() then return 0 end
    local stacks = U.GetShadowrazeDebuff(target) or 0
    local souls = S.GetSouls(bot)
    local totalDmg = 0
    for i = 1, (razeCount or 1) do
        local rawDmg = U.GetRazeRawDamage(q, stacks + (i - 1), souls)
        totalDmg = totalDmg + target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.GetTwoRazeDamage(bot, target)
    return U.GetNRazeDamage(bot, target, 2)
end

function U.CanKillEnemyWithTwoRazes(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    return U.GetTwoRazeDamage(bot, enemy) >= enemy:GetHealth()
end

function U.EnemyHasTwoRazeManaThreat(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local manaThreat = U.GetPotentialManaForRaze(enemy)
    if manaThreat >= ((C.BOOT_FEAR and C.BOOT_FEAR.TWO_RAZE_MANA_COST) or 150) then
        return true
    end
    local charges = U.GetStickCharges(enemy)
    if charges >= ((C.BOOT_FEAR and C.BOOT_FEAR.STICK_CHARGES_THREAT) or 10) then
        return true
    end
    return false
end

function U.ShouldFearBootsMidRaze(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    if U.HasBoots(bot) then return false end
    if not U.HasBoots(enemy) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemy) then return false end
    if not U.EnemyHasTwoRazeManaThreat(enemy) then return false end
    return true
end

-- Бурст рейзов врага по мне. razeCount = nil -> столько, сколько у него реально доступно
-- (по трекеру кулдаунов + мана, горизонт 2.5 с, с учётом досягаемости полос).
function U.GetEnemyRazeBurstDamage(bot, enemy, razeCount)
    if not U.CanQuery(enemy) then return 0 end
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not eq or eq:GetLevel() == 0 then return 0 end
    if razeCount == nil then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
            local dmg = U._K.EnemyBurstVs(bot, enemy, dist, 2.5, false)
            return dmg
        end
        razeCount = 2
    end
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local souls = S.GetSouls(enemy)
    local totalDmg = 0
    for i = 1, razeCount do
        local rawDmg = U.GetRazeRawDamage(eq, myStacks + (i - 1), souls)
        totalDmg = totalDmg + bot:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.HasAnyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    if U.HasItem(bot, "item_flask") then return true end
    if U.HasItem(bot, "item_tango") then return true end
    return false
end

function U.IsActivelyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    return false
end

function U.IsCourierBringSalve(bot)
    local courier = GetCourier(0)
    if not courier then return false, nil end
    if not courier:IsAlive() then return false, nil end
    local hasSalve = false
    for i = 0, 8 do
        local item = courier:GetItemInSlot(i)
        if item and item:GetName() == "item_flask" then
            hasSalve = true
            break
        end
    end
    if not hasSalve then return false, nil end
    local courierLoc = courier:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, courierLoc)
    if dist <= C.EMERGENCY.COURIER_SEARCH_RANGE then
        return true, courierLoc
    end
    return false, nil
end

function U.GetEmergencyRetreatReason(bot, enemyHero)
    local hp = bot:GetHealth()
    if U.HasAnyHealing(bot) then return nil end
    -- Экстренный отход (фонтан/курьер) - только если угроза НЕ временная: его доступный бурст
    -- убивает меня даже без стаков на мне, либо стаки держатся ещё долго. Временные стаки
    -- (истекают через пару секунд) решаются выходом из его полос, а не походом на фонтан.
    local threatAvail, threatBase = 0, 0
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if enemyHero and U.CanQuery(enemyHero) then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            threatAvail = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
            threatBase = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false, 0)
        else
            threatAvail = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
            threatBase = threatAvail
        end
    end
    local isInKillRange = false
    local hpPct = hp / math.max(1, bot:GetMaxHealth())
    -- При высоком HP "теоретически летальный" бурст из трёх рейзов - не повод бежать на фонтан:
    -- три полосы подряд по двигающейся цели он не положит, а мы теряем волну. Экстренный отход -
    -- только когда HP уже просели (<=55%) и его доступный бурст нас убивает.
    if threatBase > 0 and hp <= threatBase * C.EMERGENCY.SINGLE_RAZE_FACTOR and hpPct <= 0.55 then isInKillRange = true end
    if threatAvail > 0 and hp <= threatAvail * C.EMERGENCY.SINGLE_RAZE_FACTOR and (myStacks or 0) > 0 and (myRemain or 0) > 4.0
        and hpPct <= 0.60 then
        isInKillRange = true
    end
    if hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then isInKillRange = true end
    if not isInKillRange then return nil end
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc then
        local dist = U.DistanceBetweenLocations(bot:GetLocation(), courierLoc)
        if dist <= C.EMERGENCY.COURIER_MEET_RANGE then
            return "COURIER", courierLoc
        end
    end
    -- На фонтан - только при действительно низких HP; в диапазоне 40-55% остаёмся на линии
    -- на безопасной дистанции (RETREAT + "страх полосы"), не отдавая опыт и волну.
    -- На ранних уровнях поход на фонтан = потеря волны и уровня (40 с туда-обратно без ТП).
    -- До 5 уровня - только при <= 30% (или абсолютном минимуме), с 6-го - при <= 40%.
    local lvl = bot:GetLevel() or 1
    local goPct = (lvl >= 6) and 0.40 or 0.30
    if hpPct <= goPct or hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then
        return "FOUNTAIN", nil
    end
    return nil
end

-- Угроза смерти от доступного бурста врага (трекер кулдаунов + мана + досягаемость полос).
function U.IsInEnemyRazeKillThreat(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    if U._K then
        local R = U._K._race
        if R and R.valid then
            return R.heCanKillSoon
        end
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local dmg = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
        return dmg > 0 and hp <= dmg
    end
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local threat2 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
    if threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.SINGLE_KILL_FACTOR then return true end
    if threat2 > 0 and hp <= threat2 * SAFE_DISTANCE.KILL_THREAT_FACTOR then return true end
    return false
end

function U.GetSafeDistancePosition(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return nil end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if U._K then
        -- вне всех его готовых полос
        local safe = U._K.EnemyMinSafeDistance(enemyHero, 2.5)
        if safe > minDist then minDist = safe end
    end
    if isCritical then
        minDist = math.max(minDist, SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950)
    end
    if dist >= minDist then return nil end
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if dist < 1 then away = fountain - botLoc end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    local moveAmount = minDist - dist + 80
    -- v2.8: уход строго ОТ врага. Уклон в сторону фонтана допустим только когда фонтан
    -- примерно там же, куда мы и так бежим (dot > 0.2). Иначе (фонтан за спиной врага -
    -- нас отрезали) примесь фонтана тянула траекторию К врагу: бег выходил кривой,
    -- зигзагом "к крипам и обратно".
    local dot = away.x * toFountain.x + away.y * toFountain.y
    if dot > 0.2 then
        local awayWeight = isCritical and 0.5 or 0.7
        local fountainWeight = isCritical and 0.5 or 0.3
        return botLoc + away * moveAmount * awayWeight + toFountain * moveAmount * fountainWeight
    end
    return botLoc + away * moveAmount
end

function U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    if bot:GetMana() < 75 then return false, nil end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false, nil end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false, nil end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < C.FINISH.MIN_HP_PCT_FOR_CLOSE then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks < C.FINISH.MIN_STACKS_FOR_CLOSE then return false, nil end
    if rem_time <= 0.3 then return false, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false, nil end
    local baseDmg = q:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = q:GetSpecialValueInt("stack_bonus_damage") or 0
    local razeDmg = baseDmg + (stacks * stackDmg)
    local actualDmg = enemyHero:GetActualIncomingDamage(razeDmg, DAMAGE_TYPE_MAGICAL)
    local enemyHP = enemyHero:GetHealth()
    local atkDmg = bot:GetAttackDamage() or 0
    local actualAtk = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHP * 0.85 or (actualDmg + actualAtk) >= enemyHP then
        local botLoc = bot:GetLocation()
        local enemyLoc = enemyHero:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
        if dist <= C.FINISH.CLOSE_APPROACH_RANGE then
            local dir = (enemyLoc - botLoc):Normalized()
            local approachLoc = enemyLoc - dir * C.RAZE.NEAR_CENTER
            return true, approachLoc
        end
    end
    return false, nil
end

function U.ShouldForceSalve(bot)
    if bot:HasModifier("modifier_flask_healing") then return false end
    if bot:HasModifier("modifier_tango_heal") then return false end
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    if hpPct > C.FORCED_SALVE.HP_PCT_THRESHOLD then return false end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if not flask then return false end
    return true
end

U._lastAllyCreepHP = {}

function U.UpdateAllyCreepHealthTracking(allyCreeps)
    local newTracker = {}
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local key = tostring(c)
            newTracker[key] = {
                hp = c:GetHealth(),
                prevHp = (U._lastAllyCreepHP[key] and U._lastAllyCreepHP[key].hp) or c:GetHealth(),
                unit = c,
            }
        end
    end
    U._lastAllyCreepHP = newTracker
end

function U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not enemyTowers or #enemyTowers == 0 then return false end
    if not allyCreeps or #allyCreeps == 0 then return false end
    local t1Tower = nil
    for _, tower in pairs(enemyTowers) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                t1Tower = tower
                break
            end
        end
    end
    if not t1Tower then
        t1Tower = enemyTowers[1]
        if not t1Tower or not t1Tower:IsAlive() then return false end
    end
    local botDist = GetUnitToLocationDistance(bot, t1Tower:GetLocation())
    if botDist > 1000 then return false end
    local towerAggroRadius = 800
    local allyNearTower = {}
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= towerAggroRadius then
                    table.insert(allyNearTower, c)
                end
            end
        end
    end
    if #allyNearTower == 1 then
        local creep = allyNearTower[1]
        local key = tostring(creep)
        local tracked = U._lastAllyCreepHP[key]
        if tracked then
            if creep:GetHealth() < tracked.prevHp then
                if enemyHero and U.CanQuery(enemyHero) then
                    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                    local atkDmg = bot:GetAttackDamage() or 0
                    local enemyHp = enemyHero:GetHealth()
                    if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                        return false
                    end
                end
                return true
            end
        end
        if creep:GetHealth() < 200 then
            if enemyHero and U.CanQuery(enemyHero) then
                local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                local atkDmg = bot:GetAttackDamage() or 0
                local enemyHp = enemyHero:GetHealth()
                if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                    return false
                end
            end
            return true
        end
    end
    if #allyNearTower == 0 and botDist < 850 then
        return true
    end
    return false
end

U._lastGlyphTime = -math.huge

function U.IsGlyphAvailable(bot)
    local now = GameTime()
    if now < C.GLYPH.AVAILABLE_AT then return false end
    if GetGlyphCooldown and type(GetGlyphCooldown) == "function" then
        local cd = GetGlyphCooldown()
        if cd and cd > 0 then return false end
    else
        if (now - U._lastGlyphTime) < C.GLYPH.COOLDOWN then return false end
    end
    return true
end

function U.UseGlyph(bot)
    if bot.ActionImmediate_Glyph then
        bot:ActionImmediate_Glyph()
    elseif Glyph then
        Glyph()
    end
    U._lastGlyphTime = GameTime()
end

function U.ShouldUseGlyphDefensive(bot, allyTowers)
    if not U.IsGlyphAvailable(bot) then return false end
    for _, tower in pairs(allyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                local hp = tower:GetHealth()
                local maxHp = tower:GetMaxHealth()
                local hpPct = hp / maxHp
                if hpPct <= C.GLYPH.T1_HP_PCT_THRESHOLD or hp <= C.GLYPH.T1_HP_ABS_THRESHOLD then
                    local projs = tower:GetIncomingTrackingProjectiles()
                    local isUnderAttack = (projs and #projs > 0)
                    if not isUnderAttack then
                        local nearbyEnemies = tower:GetNearbyLaneCreeps(900, true)
                        if nearbyEnemies and #nearbyEnemies > 0 then isUnderAttack = true end
                        if not isUnderAttack then
                            local nearbyHeroes = tower:GetNearbyHeroes(900, true, BOT_MODE_NONE)
                            if nearbyHeroes and #nearbyHeroes > 0 then isUnderAttack = true end
                        end
                    end
                    if isUnderAttack then return true end
                end
            end
        end
    end
    return false
end

function U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
    local atkDmg = bot:GetAttackDamage() or 0
    local enemyHp = enemyHero:GetHealth()
    if not ((twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() >= 150) then
        return false
    end
    -- v2.5: только при ИДУЩЕМ добивании: доступный прямо сейчас бурст (готовые рейзы + удар) убивает,
    -- и мы реально атакуем/целимся в него. "Два рейза по формуле" при случайном заходе под башню
    -- (башня била нашего крипа) сжигали глиф без попытки убийства.
    if not (C.GLYPH and C.GLYPH.DIVE_REQUIRE_KILL_NOW == false) then
        local K = U._K
        local R = K and K._race
        if not (R and R.valid and R.canKillNow) then return false end
        local engaged = false
        local okT, tgt = pcall(bot.GetAttackTarget, bot)
        if okT and tgt == enemyHero then engaged = true end
        if not engaged and bot:IsUsingAbility() then engaged = true end
        if not engaged and U._engagedCheck and U._engagedCheck(bot, enemyHero) then engaged = true end
        if not engaged then return false end
    end
    local enemyLoc = enemyHero:GetLocation()
    local t1Tower = nil
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                if GetUnitToLocationDistance(tower, enemyLoc) <= C.GLYPH.KILL_DIVE_RANGE then
                    t1Tower = tower
                    break
                end
            end
        end
    end
    if not t1Tower then return false end
    local hasAllyCreepUnderT1 = false
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= 750 then
                hasAllyCreepUnderT1 = true
                break
            end
        end
    end
    if not hasAllyCreepUnderT1 then
        return false
    end
    local botDist = GetUnitToLocationDistance(bot, enemyLoc)
    if botDist > 1100 then return false end
    local botUnderTower = false
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) <= 880 then
            botUnderTower = true
            break
        end
    end
    if not botUnderTower then return false end
    return true
end

function U.HasTreadsAdvantage(bot, enemy)
    if not bot then return false end
    if not U.HasItem(bot, "item_power_treads") then return false end
    if enemy and U.CanQuery(enemy) and U.HasBoots(enemy) then return false end
    return true
end

function U.ShouldPushWave(bot, enemy, allyCreeps, enemyCreeps)
    if not U.HasTreadsAdvantage(bot, enemy) then return false end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < (C.PUSH.MIN_HP_PCT_TO_PUSH or 0.50) then return false end
    if not enemyCreeps or #enemyCreeps == 0 then return false end
    return true
end

-- Бояться ближней полосы (не подходить на near-дистанцию), если на мне стаки и его NEAR-рейз
-- готов (трекер) и есть мана; при этом его near-рейз должен быть ощутимым (>= 25% HP) либо
-- размен не в мою пользу.
function U.HasStackAndShouldFearNear(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 then return false end
    if rem_time <= C.RAZE.RETREAT_MIN_REMAIN then return false end
    local K = U._K
    if K then
        if not K.EnemyRazeReady("near", 1.2) then return false end
        if K.EnemyManaBudget(enemy, true) < 75 then return false end
        local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
        local R = K._race
        local edge = (R and R.valid) and R.edge or 0
        if oneRaze < bot:GetHealth() * 0.25 and edge >= 0 then return false end
        return true
    end
    if not U.EnemyCanUseRaze(enemy) then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if stacks == 1 and secondStackActive and hitLabel == "near" then
        return false
    end
    return true
end

function U.GetMinDistWithStack(bot, enemy)
    local fear = U.GetFearMinDist(bot, enemy)
    -- v2.3: со свежим стаком (и невыгодным разменом) позиция - вне ВСЕХ его готовых полос,
    -- а не только вне ближней (см. правило 2b в ShouldRetreatFromEnemyRazeStack)
    local K = U._K
    if K and U.CanQuery(enemy) then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local R = K._race
            local favorable = U.IsStackTradeFavorable(bot, R)
            if not favorable then
                local outOfBands = K.EnemyMinSafeDistance(enemy, 1.0)
                if outOfBands > fear then fear = outOfBands end
            end
        end
    end
    if not U.HasStackAndShouldFearNear(bot, enemy) then return fear end
    return math.max(fear, (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470)
end

function U.ClampMinDistFromEnemy(bot, enemy, loc)
    if not enemy or not U.CanQuery(enemy) then return loc end
    local minDist = U.GetMinDistWithStack(bot, enemy)
    if minDist <= 0 then return loc end
    local enemyLoc = enemy:GetLocation()
    local dist = U.DistanceBetweenLocations(loc, enemyLoc)
    if dist >= minDist then return loc end
    local dir = loc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    return enemyLoc + dir * (minDist + ((C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.RETREAT_BUFFER) or 60))
end

function U.CanOneShotEnemyHero(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local atkDmg = bot:GetAttackDamage() or 0
    local actualDmg = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHero:GetHealth() then
        return true, "ATTACK"
    end
    return false, nil
end

function U.CanKillEnemyWithOneRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
            if willHit and oneRazeDmg >= enemyHero:GetHealth() then
                return true, c.label
            end
        end
    end
    return false, nil
end

function U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit, _, predLoc = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            if willHit then
                local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
                if oneRazeDmg >= enemyHero:GetHealth() then
                    local angleDiff = U.GetAngleDifference(bot, predLoc)
                    -- v2.8: доворот быстрый, а рейз бьёт дальше удара с руки: порог 110,
                    -- иначе при угле 46+ бот "тычковал" и давал врагу убежать
                    if angleDiff <= 110 then
                        return true, c.label
                    end
                end
            end
        end
    end
    return false, nil
end

function U.IsAggressivePlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if not bot or not enemyHero then return false end
    local style = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    return style == "AGGRESSIVE"
end

U.DEBUG = false

function U.Log(...)
end

return U