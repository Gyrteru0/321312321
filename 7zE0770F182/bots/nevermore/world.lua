-- scripts/vscripts/bots/nevermore/world.lua
--
-- Снимок мира на тик: один раз собираем списки юнитов, врага, башни, присутствие врага
-- (жив / когда видели последний раз). Таблица W.s переиспользуется (без аллокаций в тике).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local W = {}

-- v2.3: буферы для отфильтрованных списков крипов (переиспользуются каждый тик)
local ENEMY_CREEPS_BUF, ALLY_CREEPS_BUF = {}, {}
local function FilterQueryable(list, buf)
    for i = #buf, 1, -1 do buf[i] = nil end
    if not list then return buf end
    local n = 0
    for _, u in pairs(list) do
        if U.CanQuery(u) then
            n = n + 1
            buf[n] = u
        end
    end
    return buf
end

W.s = {
    now = 0,
    bot = nil,
    enemy = nil,            -- видимый вражеский герой (queryable) или nil
    enemyAny = nil,         -- хэндл врага даже если не виден (может быть не queryable)
    enemyVisible = false,
    enemyAlive = true,
    enemyLastSeen = -1,     -- GameTime, когда видели последний раз
    enemyLastLoc = nil,
    enemyAbsentFor = 0,     -- секунд не видим (0 если видим)
    enemyDist = 99999,
    enemyCreeps = nil,
    allyCreeps = nil,
    enemyTowers = nil,
    allyTowers = nil,
    enemyT1 = nil,          -- хэндл вражеской Т1 (если жива и доступна)
    enemyT1Alive = true,
    allyT1 = nil,
    myKills = 0,
    myDeaths = 0,
    enemyKills = 0,
    enemyDeaths = 0,
}

local EMPTY = {}

local function FindT1(towers)
    for _, t in pairs(towers or EMPTY) do
        if t and t:IsAlive() then
            local name = t:GetUnitName() or ""
            if name:find("tower1") then return t end
        end
    end
    return nil
end

local function SafeGetTower(team, idx)
    if type(GetTower) ~= "function" then return nil end
    local ok, t = pcall(GetTower, team, idx)
    if ok then return t end
    return nil
end

function W.Update(bot)
    local s = W.s
    local now = GameTime()
    s.now = now
    s.bot = bot

    -- Враг: сначала по глобальному списку (видимость/присутствие), потом ближний список.
    local enemy = nil
    local enemyAny = nil
    if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_HEROES then
        local list = GetUnitList(UNIT_LIST_ENEMY_HEROES)
        for _, h in pairs(list or EMPTY) do
            if h then
                enemyAny = enemyAny or h
                if U.CanQuery(h) then
                    enemy = h
                    break
                end
            end
        end
    end
    if not enemy then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        for _, h in pairs(near or EMPTY) do
            if U.CanQuery(h) then
                enemy = h
                break
            end
        end
    end
    s.enemy = enemy
    s.enemyAny = enemyAny or enemy
    s.enemyVisible = enemy ~= nil
    if enemy then
        s.enemyLastSeen = now
        s.enemyLastLoc = enemy:GetLocation()
        s.enemyAbsentFor = 0
        s.enemyDist = GetUnitToLocationDistance(bot, s.enemyLastLoc)
        s.enemyAlive = enemy:IsAlive()
    else
        if s.enemyLastSeen >= 0 then
            s.enemyAbsentFor = now - s.enemyLastSeen
        else
            s.enemyAbsentFor = 0
        end
        s.enemyDist = 99999
        -- Жив ли невидимый враг
        local alive = true
        local h = s.enemyAny
        if h and h.GetPlayerID and type(IsHeroAlive) == "function" then
            local ok, pid = pcall(h.GetPlayerID, h)
            if ok and pid and pid >= 0 then
                local ok2, res = pcall(IsHeroAlive, pid)
                if ok2 and res ~= nil then alive = res end
            end
        end
        s.enemyAlive = alive
    end

    -- Счёт
    if s.enemyAny and s.enemyAny.GetPlayerID and type(GetHeroKills) == "function" then
        local ok, pid = pcall(s.enemyAny.GetPlayerID, s.enemyAny)
        if ok and pid and pid >= 0 then
            local ok1, k = pcall(GetHeroKills, pid)
            local ok2, d = pcall(GetHeroDeaths, pid)
            if ok1 and k then s.enemyKills = k end
            if ok2 and d then s.enemyDeaths = d end
        end
    end
    if type(GetHeroKills) == "function" then
        local pid = bot:GetPlayerID()
        local ok1, k = pcall(GetHeroKills, pid)
        local ok2, d = pcall(GetHeroDeaths, pid)
        if ok1 and k then s.myKills = k end
        if ok2 and d then s.myDeaths = d end
    end

    -- Юниты
    -- v2.3: GetNearbyLaneCreeps(..., true) может вернуть вражеских крипов в тумане (хэндл есть,
    -- опрашивать нельзя): каждый GetHealth/GetLocation по такому крипу - "[Developer] ... cannot be
    -- seen" в консоли, а ласт-хит/пуш по нему - приказ в пустоту. Фильтруем через CanQuery в две
    -- переиспользуемые таблицы (без аллокаций на тик).
    s.enemyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1200, true), ENEMY_CREEPS_BUF)
    s.allyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1200, false), ALLY_CREEPS_BUF)
    s.enemyTowers = bot:GetNearbyTowers(1200, true) or EMPTY
    s.allyTowers = bot:GetNearbyTowers(1200, false) or EMPTY

    -- Башни Т1 (через глобальный GetTower, если доступен; иначе из ближнего списка)
    local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local t1 = nil
    if TOWER_MID_1 ~= nil then
        t1 = SafeGetTower(enemyTeam, TOWER_MID_1)
    end
    if t1 then
        local okAlive, alive = pcall(t1.IsAlive, t1)
        if okAlive and alive == false then
            s.enemyT1Alive = false
            t1 = nil
        elseif okAlive and alive then
            local okLoc, loc = pcall(t1.GetLocation, t1)
            if okLoc and loc then
                s.enemyT1Alive = true
            else
                t1 = nil -- хэндл есть, но опрашивать нельзя: берём из ближнего списка
            end
        else
            t1 = nil
        end
    end
    if not t1 then
        local nearT1 = FindT1(s.enemyTowers)
        if nearT1 then
            t1 = nearT1
            s.enemyT1Alive = true
        end
    end
    s.enemyT1 = t1
    s.allyT1 = FindT1(s.allyTowers)

    return s
end

-- Враг "отсутствует": мёртв или не виден дольше absentSec.
function W.EnemyAbsent(absentSec)
    local s = W.s
    if not s.enemyAlive then return true end
    if s.enemyVisible then return false end
    return s.enemyAbsentFor >= (absentSec or 5.0)
end

-- Хук для utils (utils не может require world из-за цикла)
U._W = W

return W
