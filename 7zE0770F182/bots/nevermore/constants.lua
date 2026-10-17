-- scripts/vscripts/bots/nevermore/constants.lua

local C = {}

C.HERO = {
    PROJECTILE_SPEED = 1200,
    DAMAGE_HALF_RANGE = 3,   -- SF 7.41f: базовый урон 16-22 -> полуразброс 3 (см. U.SFDamageRange)
}

C.LASTHIT = {
    NET_LATENCY       = 0.05,
    DENY_HP_THRESHOLD = 0.50,
    CANCEL_WINDOW     = 0.08,
    COMMIT_HP_BUFFER  = 8,
    -- v2.5: спорный крип (вражеский герой в радиусе атаки от него): неопределённые удары крипов
    -- считаем по середине цикла (а не по худшему случаю) - иначе бот с БОЛЬШИМ уроном бил крипа
    -- в тот же момент, что и враг с меньшим уроном, и терял его на денае.
    CONTEST_SLACK     = 0.45,
    CONTEST_RANGE_PAD = 150,
}

C.RAZE = {
    NEAR_CENTER         = 200,
    -- v2.4: политика рейзов с 1 очком (L1-L2): инициируем только вплотную / зеркалом / добиванием
    AGGRO_MIN_RAZE_LEVEL = 2,   -- с этого уровня рейза (2 очка, обычно герой L3) - агрессия без ограничений
    EARLY_CHAIN_DIST     = 360, -- враг ближе -> можно начать цепочку (ближний -> средний -> дальний)
    MIRROR_WINDOW        = 2.5, -- с: после его каста отвечаем своим (зеркало)
    NEAR_CHAIN_WINDOW    = 5.0, -- с: после ближнего наказания добивочные рейзы без резерва маны
    MID_CENTER          = 450,
    FAR_CENTER          = 700,
    HIT_RADIUS          = 250,
    STRICT_RADIUS       = 190,
    CAST_POINT          = 0.55,
    PREDICT_DELAY       = 0.62,
    EXTEND_AT           = 3.05,
    HARASS_MARGIN    = 90,    -- v2.5: харас-рейз только при робастной ошибке <= 250-90=160 (реагирующий враг у края выходит из круга)
    MAX_ANGLE_TO_CAST   = 6,    -- v2.5: каст только когда развёрнуты на точку наведения (было 8 и не проверялось в основном пути)
    TURN_STEP           = 40,   -- v2.5: шаг "доворота" (u): короче - движок может не повернуть героя
    MIRROR_INSTANT_SEC  = 0.7,  -- v2.5: его рейз попал по нам не позже этого - мгновенный ответ той же/любой полосой
    MIRROR_MIN_HP_LEFT  = 110,  -- v2.5: после его следующего рейза должно оставаться не меньше HP
    ENEMY_THREAT_RANGE  = 930,
    RETREAT_MIN_REMAIN  = 0.35,
    MISS_DETECT_WINDOW  = 0.75,
    MISS_ADVANTAGE_TIME = 6.0,
    -- v2.2: робастное наведение - круг рейза должен накрыть врага и в текущей, и в предсказанной
    -- точке (на случай "встал" / "пошёл"); допуск от края круга:
    ROBUST_MARGIN       = 30,
    -- добивание стака: второй/третий рейз сразу, пока враг в досягаемости (не ждём EXTEND_AT),
    -- если на нём свежий стак с остатком не меньше:
    FOLLOWUP_MIN_REMAIN = 1.2,
}

C.HARASS = {
    BASE_COOLDOWN          = 0.0,
    MISS_BONUS_COOLDOWN    = 0.0,
    APPROACH_DISTANCE      = 800,
    APPROACH_DISTANCE_MISS = 1100,
    MIN_HP_PCT             = 0.45,
    MIN_HP_PCT_MISS        = 0.35,
    INTERRUPT_APPROACH     = 1300,
}

-- 7.41f (npc_dota_hero_nevermore.txt): necromastery_damage_per_soul = 1, +0.8 каждые 6 уровней героя
C.NECROMASTERY = {
    BASE_DMG_PER_SOUL         = 1.0,
    DMG_PER_SOUL_PER_6_LEVELS = 0.8,
    MAX_SOULS                 = 20,
}

C.TP = {
    RETURN_DISTANCE_FROM_T1 = 3200,
    FOUNTAIN_RADIUS         = 400,
    RETURN_HP_PCT           = 0.50,
}

C.POSITIONS = {
    MID_LANE_CENTER      = Vector(503.58, -1010.36, 1124.97),
    MIDLANE_CENTER       = Vector(503.58, -1010.36, 1124.97),
    MID_FOUNTAIN_RADIANT = Vector(-6848, -6336, 384),
    MID_FOUNTAIN_DIRE    = Vector(6656, 6080, 384),
    RADIANT_T1           = Vector(-1544.00, -2008.00, 1144.05),
    RADIANT_T1_CLOSE     = Vector(-1395.18, -1859.83, 1144.00), -- v2.3: ~210 от Т1 по линии (было ~460)
    RADIANT_FLANK_TOP    = Vector(-1417.84, -1061.84, 1123.81),
    RADIANT_FLANK_BOT    = Vector(-591.38, -1812.09, 1138.51),
    WARD_RADIANT         = Vector(-304.583435, -1010.216370, 128.000000),
    DIRE_T1              = Vector(521.28, 48.31, 1146.80),
    DIRE_T1_CLOSE        = Vector(372.46, -99.86, 1146.00),   -- v2.3: ~210 от Т1 по линии (было ~370)
    DIRE_FLANK_TOP       = Vector(-425.08, -37.47, 1123.98),
    DIRE_FLANK_BOT       = Vector(423.34, -847.56, 1117.69),
    WARD_DIRE            = Vector(-514.736816, 293.893494, 128.000000),
}

C.ITEM_PRIORITY = {
    ["item_kaya"]              = 100,
    ["item_dragon_lance"]      = 90,
    ["item_power_treads"]      = 80,
    ["item_boots"]             = 76,
    ["item_staff_of_wizardry"] = 75,
    ["item_blade_of_alacrity"] = 74,
    ["item_belt_of_strength"]  = 73,
    ["item_robe"]              = 72,
    ["item_bracer"]            = 70,
    ["item_magic_wand"]        = 60,
    ["item_magic_stick"]       = 50,
    ["item_circlet"]           = 40,
    ["item_gauntlets"]         = 35,
    ["item_faerie_fire"]       = 30,
    ["item_enchanted_mango"]   = 25,
    ["item_flask"]             = 20,
    ["item_tango"]             = 15,
    ["item_branches"]          = 10,
    ["item_ward_observer"]     = 5,
}

C.EMERGENCY = {
    RAZE_KILL_FACTOR     = 1.15,
    SINGLE_RAZE_FACTOR   = 1.05,
    MIN_HP_ABSOLUTE      = 180,
    COURIER_SEARCH_RANGE = 3000,
    COURIER_MEET_RANGE   = 1500,
}

C.GLYPH = {
    AVAILABLE_AT        = 180,
    COOLDOWN            = 300,
    T1_HP_PCT_THRESHOLD = 0.15,
    T1_HP_ABS_THRESHOLD = 400,
    KILL_DIVE_RANGE     = 900,
    -- v2.5: глиф "под дайв" только при идущем добивании (бурст прямо сейчас убивает, мы атакуем/целимся)
    DIVE_REQUIRE_KILL_NOW = true,
}

C.T1_SAFETY = {
    LAST_CREEP_HP_LOSS_CHECK = true,
    RETREAT_BUFFER           = 250,
    CREEP_DRIFT_START        = 620,
    CREEP_DRIFT_HARD         = 700,
    CREEP_DRIFT_DELTA        = 22,
}

C.FORCED_SALVE = {
    HP_PCT_THRESHOLD = 0.50,
}

C.SALVE_AUTOBUY = {
    HP_PCT_THRESHOLD = 0.40,
    MIN_GOLD         = 110,
    BUY_COOLDOWN     = 8.0,
}

C.SAFE_DISTANCE = {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

C.FINISH = {
    MIN_STACKS_FOR_CLOSE = 2,
    CLOSE_APPROACH_RANGE = 600,
    MIN_HP_PCT_FOR_CLOSE = 0.30,
}

C.BOOT_FEAR = {
    MID_RAZE_RADIUS       = 220,
    RETREAT_DURATION      = 0.95,
    RETREAT_DISTANCE_BONUS = 140,
    TWO_RAZE_MANA_COST    = 150,
    STICK_CHARGES_THREAT  = 10,
}

C.NEAR_REPLY = {
    WAIT_AFTER_HIT   = 1.0,
    HOLD_DISTANCE    = 215,
    HOLD_MIN_DISTANCE = 150,
    HOLD_MAX_DISTANCE = 250,
    HOLD_TOLERANCE    = 25,
}

C.FORCE_EXTEND = {
    PREFER_MID_WITH_BOOTS = true,
    FAR_DOWNGRADE_TO_MID  = true,
    FAR_CANCEL_TOLERANCE  = 60,
}

C.PUSH = {
    TREADS_ADVANTAGE_PUSH = true,
    PUSH_ATTACK_RANGE     = 700,
    T1_ATTACK_RANGE       = 900,
    MIN_CREEPS_TO_TANK    = 2,
    MIN_HP_PCT_TO_PUSH    = 0.50,
    TOWER_SAFE_CREEP_HP   = 200,
}

C.REGEN = {
    ENEMY_SAFE_DISTANCE = 1100,
    FLASK_SAFE_DISTANCE = 1150,
}

C.FOUNTAIN = {
    GO_HP_CRITICAL_PCT  = 0.15,
    GO_HP_WITH_MANA_PCT = 0.0,
    GO_MANA_WITH_HP_PCT = 0.0,
    STICK_CHARGES_ENOUGH = 10,
    WAIT_FULL_HP_PCT    = 0.98,
    WAIT_FULL_MANA_PCT  = 0.98,
    AT_FOUNTAIN_RADIUS  = 500,
}

C.STACK_NEAR_FEAR = {
    MIN_DISTANCE   = 470,
    RETREAT_BUFFER = 60,
}

-------------------------------------------------------------------------------
-- v2: мир / бой / намерения (world.lua, combat.lua, lane.lua, intent.lua)
-------------------------------------------------------------------------------
C.RAZE.COOLDOWN                     = 9.0   -- 7.41f: все три рейза
C.RAZE.DAMAGE_PER_SOUL              = 2     -- +2 урона рейза за душу
C.RAZE.SINGLE_TRADE_LEVEL_TOLERANCE = 1
C.RAZE.SECOND_STACK_AVOID_RADIUS    = 190

C.LASTHIT.ALLY_DPS_FACTOR = 0.70   -- только запасная усреднённая модель (атакующие без данных)
C.LASTHIT.IMPACT_LEAD = 0.06       -- моё попадание не раньше чем через 0.06 с после момента "крип добиваем"
C.LASTHIT.PREHIT_ANYWHERE = false  -- "формирование HP" пред-ударом вне своей башни (эксперимент: в харнессе ухудшал CS)

-- Прокачка (без Feast of Souls / nevermore_frenzy - по правилам лобби не берём вообще).
-- Индекс = уровень героя. Пропуски = очко остаётся неистраченным (альтернатива только Frenzy).
-- Таланты 7.41f: 10 = +30 урона за стак рейза (special_bonus_unique_nevermore_7),
-- 15 = -1.5 брони от Presence (_3), 20 = +5 душ (_1), 25 = рейзы наносят удар с руки (_raze_procsattacks).
C.SKILL = {
    ALLOW_FRENZY = false,
    -- v2.5: Реквием НЕ изучаем (по требованию): чередуем рейзы и пассивку (Presence of the Dark Lord),
    -- таланты на 10/15/20/25. Уровни без записи (9, 11-14, 16-19, 21-24) - очко остаётся в запасе.
    ORDER = {
        [1]  = "nevermore_shadowraze1",
        [2]  = "nevermore_dark_lord",
        [3]  = "nevermore_shadowraze1",
        [4]  = "nevermore_dark_lord",
        [5]  = "nevermore_shadowraze1",
        [6]  = "nevermore_dark_lord",
        [7]  = "nevermore_shadowraze1",
        [8]  = "nevermore_dark_lord",
        [10] = "special_bonus_unique_nevermore_7",
        [15] = "special_bonus_unique_nevermore_3",
        [20] = "special_bonus_unique_nevermore_1",
        [25] = "special_bonus_unique_nevermore_raze_procsattacks",
    },
}

C.TOWER = {
    ATTACK_RANGE      = 700,  -- T1 дальность атаки
    SAFE_RADIUS       = 780,  -- радиус, внутри которого считаем себя "под башней"
    CHASE_LEASH       = 820,  -- не преследуем в точку ближе этого к вражеской Т1 без щита из крипов
    MIN_SHIELD_TO_HIT = 2,    -- минимум своих крипов под башней, чтобы бить Т1
    DIVE_MAX_TIME     = 1.0,  -- v2.3: максимум подряд в радиусе Т1 "по герою" (преследование/рейз по нему)
    BURN_SEC          = 2.5,  -- v2.3: после выхода из-под Т1 столько секунд без дайвов и атак башни
    BURN_REPEAT_SEC   = 6.0,  -- v2.3: повторный выход из-под Т1 в течение REPEAT_WINDOW с -> ожог длиннее
    REPEAT_WINDOW     = 10,
}

C.INTENT = {
    ENEMY_ABSENT_SEC = 5.0,   -- враг мёртв / не виден дольше -> PUSH
    PUSH_EDGE        = 260,   -- преимущество по бурсту (абс. HP) для PUSH при живом враге
    ZONE_EDGE        = 70,    -- преимущество для ZONE
    TRADE_EDGE       = -30,   -- допустимый минус для TRADE
    LOW_HP_PCT       = 0.22,
    PUSH_MIN_HP_PCT  = 0.55,
    PUSH_KEEP_HP_PCT = 0.45,
    ZONE_WAVE_DIST   = 900,   -- враг ближе этого к волне -> есть кого зонировать
    -- v2.5: "охота": большой перевес по абсолютным HP и враг добиваем моим бурстом в горизонте
    -- HUNT_HORIZON с (рейзы, которые будут готовы, + манго/стик + 1 удар) -> ALLIN даже при малой мане
    HUNT_HP_EDGE     = 250,   -- мои HP - его HP не меньше
    HUNT_MIN_HP_PCT  = 0.40,
    HUNT_HORIZON     = 4.0,   -- с: рейзы с остатком кулдауна не больше этого считаем доступными
    HUNT_MAX_DIST    = 1100,
    HUNT_SAFETY_HP   = 80,    -- его бурст с дистанции средней полосы должен оставлять мне >= этого
}

C.ZONE = {
    HOLD_DIST        = 520,   -- держимся на дистанции удара с руки, не ближе minSafeDist
    MAX_FROM_WAVE    = 520,   -- не отходим от волны дальше этого ради зонинга
    ATTACK_RANGE_PAD = 40,
}

C.TANGO = {
    USE_HP_PCT     = 0.80,    -- есть танго раньше (просьба пользователя): уже при < 80% HP
    MIN_MISSING_HP = 100,     -- танго лечит 112 за 16 с: ниже 100 недостающих HP - не тратим
    SEARCH_RADIUS  = 900,
    COMMIT_TIME    = 8.0,     -- держимся выбранного дерева (защита от метаний между деревьями)
    STUCK_TIME     = 4.0,     -- нет прогресса к дереву -> дерево в чёрный список на 20 с
    ENEMY_MIN_DIST = 650,
    TOWER_MIN_DIST = 1125,
}

C.MANA = {
    RESERVE_FOR_PRESSURE = 75, -- давим рейзами, только если после каста остаётся мана ещё на один
    -- Ранние уровни: харас-рейз (не добивание, не ласт-хит) только если ПОСЛЕ каста остаётся
    -- резерв на ласт-хиты/ответ. На 1-2 уровне (291 маны, реген ~0.9/с) - один харас-рейз,
    -- потом только CS/ответ/добивание; иначе бот уходит в ноль, а враг спокойно регенит.
    EARLY_RESERVE_L2 = 150,
    EARLY_RESERVE_L4 = 112,
    EARLY_LEVEL_L2   = 2,
    EARLY_LEVEL_L4   = 4,
    -- Добивание стака (на враге свежий стак, он ещё в досягаемости): резерв не нужен -
    -- первые 75 маны уже потрачены, второй/третий рейз бьёт с бонусом стака. Оставляем лишь:
    FOLLOWUP_KEEP    = 60,
    FOLLOWUP_KEEP_L2 = 130,  -- v2.3: на L1-L2 после добивочного рейза по стаку оставляем >= 130 (цепочка <= 2 рейзов)
}

-- Оборонительная поза "я слабее": авто-атаки + бурст + пул HP обеих сторон (см. K.Race).
C.DEFENSE = {
    WEAKER_EDGE      = 120,  -- проекция размена на 6 с хуже на столько абсолютных HP -> я слабее
    EXIT_EDGE        = 40,   -- выход из обороны: проекция лучше, чем -40 (гистерезис)
    MIN_HOLD_SEC     = 2.0,
    KITE_PAD         = 140,  -- отходим за его радиус атаки + столько
    SUPPORT_CREEPS   = 2,    -- столько моих крипов бьют его -> можно отвечать и в обороне
    CONTEST_PAD      = 80,   -- оборона: ласт-хит не берём, если позиция удара в его радиусе атаки + это
    SUSTAINED_TTK_RATIO = 0.8, -- "слабее надолго": он убивает меня с руки быстрее, чем я его, в 1/0.8 раз
}

-- Покупки расходников из боевого кода (не билд!): без спама "out of stock" и без разорения билда.
C.CONSUMABLE_BUY = {
    KEEP_GOLD_FOR_BUILD = 210, -- после манго/сальвы должно остаться не меньше (рецепт брейсера)
    MANGO_COOLDOWN      = 60,
    FLASK_COOLDOWN      = 45,
}

return C
