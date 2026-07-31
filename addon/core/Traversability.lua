-- Traversability - the "how pleasant is it to move through here" field.
--
-- Distance is the WRONG objective. A human crossing a zone does not walk the
-- shortest line; they take the road, because the road is fast, flat, safe and
-- has no cliffs to fall off - and they leave it the moment the detour stops
-- paying. That judgement is what this layer models, as a living heatmap the
-- planner multiplies into its cost.
--
-- Three learned signals, none of them hardcoded (this is a custom server, so any
-- shipped road table would be wrong exactly where it matters):
--
--   TRAFFIC - where OTHER PLAYERS are. Players travel on roads. Watching the
--     world for a few minutes therefore draws the road network for free, on any
--     continent, including custom ones no map data exists for. Our own
--     successful travel counts too, more weakly.
--   DANGER  - where hostile creatures are, weighted by level and elite status.
--     A route through a dense camp is not "shorter", it is a fight.
--   FRICTION - things that slow the body down: water, steep ground, known snags.
--
-- Everything DECAYS. A camp cleared an hour ago should not haunt the map forever,
-- and a road stays a road, so traffic decays far more slowly than danger. The
-- store is coarse (16yd) because these are regional facts, not per-step ones,
-- which also keeps it small enough to persist.

local Traversability = {}
local T = Traversability

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

T.RES = 16.0                  -- yd per traversability cell (regional, not per-step)
T.DANGER_HALFLIFE = 300.0     -- s: a cleared camp fades within minutes
T.TRAFFIC_HALFLIFE = 21600.0  -- s: roads persist (6h) - they are structural
T._cap = 8000          -- cells per map: the hard bound this store previously lacked
T.MAX_DANGER = 40.0
T.MAX_TRAFFIC = 60.0

-- How strongly each signal bends the route. Kept as named weights so behaviour is
-- tunable per character rather than baked into the maths.
T.W = {
    ROAD_DISCOUNT = 0.45,   -- max fraction of the *above-floor* cost a road removes
    DANGER        = 2.20,   -- full-danger cost multiplier addition
    WATER         = 3.00,   -- swimming is slow and cannot be fought from
    FLOOR         = 1.00,
}

local function now() return (GetTime and GetTime()) or 0 end

local function root()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.traverse = RaijinLabDB.traverse or { version = 1 }
    return RaijinLabDB.traverse
end

function T.map_key()
    if T._test_map then return T._test_map end
    local WM = RaijinLab and RaijinLab.WorldMesh
    if WM and WM.map_key then return WM.map_key() end
    return "world"
end

local function bucket()
    local r = root()
    local k = T.map_key()
    local m = r[k]
    if not m then m = { cells = {} }; r[k] = m end
    m.cells = m.cells or {}
    return m
end

function T.cell_key(x, y)
    return floor((x or 0) / T.RES) * 65536 + floor((y or 0) / T.RES) + 2147483648
end

-- Exponential decay applied lazily on read/write: we never sweep the whole map,
-- we just age a cell the moment we touch it. O(1) and exact.
local function aged(v, t0, t, halflife)
    if not v or v == 0 then return 0 end
    local dt = (t or 0) - (t0 or 0)
    -- A NEGATIVE delta means the clock restarted (GetTime resets every session),
    -- and returning the value untouched would freeze decay forever. Treat an
    -- unknown age as one half-life rather than as no time at all.
    if dt < 0 then return v * 0.5 end
    if dt == 0 then return v end
    return v * (0.5 ^ (dt / halflife))
end

-- Drop the least-significant cells once a map exceeds the cap. Checked only when
-- a NEW cell appears, so the O(n) pass is rare - the same amortized pattern the
-- WorldMesh uses. Without any cap this was the largest unbounded store in the DB.
local function enforce_cap(m, t)
    local n = 0
    for _ in pairs(m.cells) do n = n + 1 end
    if n <= T._cap then return end
    local scored = {}
    for k, c in pairs(m.cells) do
        local d = aged(c.d, c.t, t, T.DANGER_HALFLIFE)
        local r = aged(c.r, c.t, t, T.TRAFFIC_HALFLIFE)
        -- Roads are the durable, expensive-to-relearn signal, so weight them above
        -- danger (which regenerates the moment we walk past a camp again).
        scored[#scored + 1] = { k = k, v = r * 2 + d }
    end
    table.sort(scored, function(a, b) return a.v > b.v end)
    for i = math.floor(T._cap * 0.9) + 1, #scored do m.cells[scored[i].k] = nil end
end

local function touch(m, key, t)
    local c = m.cells[key]
    if not c then
        c = { d = 0, r = 0, t = t }
        m.cells[key] = c
        -- Check interval SCALES with the cap: a fixed 256 would let a small cap
        -- overshoot by more than the cap itself before the sweep ever ran.
        m._adds = (m._adds or 0) + 1
        local every = math.max(32, math.floor(T._cap * 0.1))
        if m._adds % every == 0 then enforce_cap(m, t) end
        return c
    end
    c.d = aged(c.d, c.t, t, T.DANGER_HALFLIFE)
    c.r = aged(c.r, c.t, t, T.TRAFFIC_HALFLIFE)
    c.t = t
    return c
end

-- ---- feeding the field ---------------------------------------------------

-- A hostile creature is here. Weight by how much trouble it actually is.
function T.add_danger(x, y, amount)
    if not x then return end
    local m = bucket()
    local t = now()
    local c = touch(m, T.cell_key(x, y), t)
    c.d = min(T.MAX_DANGER, c.d + (amount or 1))
end

-- Someone walked here. This is the road signal.
function T.add_traffic(x, y, amount)
    if not x then return end
    local m = bucket()
    local t = now()
    local c = touch(m, T.cell_key(x, y), t)
    c.r = min(T.MAX_TRAFFIC, c.r + (amount or 1))
end

-- Threat weight of a unit: elites and higher-level mobs dominate the decision.
function T.threat_weight(level, elite, plevel)
    local w = 1.0
    level = tonumber(level) or 0
    plevel = tonumber(plevel) or level
    if elite then w = w + 2.0 end
    local d = level - plevel
    if d > 0 then w = w + min(3.0, d * 0.4) end
    if d < -8 then w = w * 0.25 end          -- trivial greys barely matter
    return w
end

-- Sample the world: hostiles become danger, players become road traffic.
-- Throttled by the caller (Navigator/Suite tick); cheap and idempotent.
function T.observe_world(opts)
    opts = opts or {}
    local RL = RaijinLab
    local om = RL and RL.om and RL.om.object_list
    if not om then return 0 end
    local plevel = (UnitLevel and UnitLevel("player")) or 0
    local myguid = UnitGUID and UnitGUID("player")
    local n = 0

    for i = 1, #(om.npcs or {}) do
        local s = om.npcs[i]
        local guid = s and s.Guid
        if guid and RL.ObjectPosition then
            local u = s.Info and s.Info.Unit
            local dead = u and u.Dead
            -- Only things that would actually fight us.
            local hostile = true
            if u and u.Reaction ~= nil then hostile = (tonumber(u.Reaction) or 4) <= 3 end
            if not dead and hostile then
                local x, y = RL:ObjectPosition(guid)
                if x then
                    T.add_danger(x, y, T.threat_weight(u and u.Level, u and u.Elite, plevel))
                    n = n + 1
                end
            end
        end
    end

    -- PLAYERS DRAW THE ROADS. This is the whole trick: we never need map data,
    -- because the population is continuously demonstrating the good routes.
    for i = 1, #(om.players or {}) do
        local s = om.players[i]
        local guid = s and s.Guid
        if guid and guid ~= myguid and RL.ObjectPosition then
            local x, y = RL:ObjectPosition(guid)
            if x then T.add_traffic(x, y, 1.0); n = n + 1 end
        end
    end
    return n
end

-- Our own successful travel is weaker evidence than a crowd, but it is evidence.
function T.note_self_travel(x, y)
    T.add_traffic(x, y, 0.35)
end

-- ---- querying ------------------------------------------------------------

function T.sample(x, y)
    local m = bucket()
    local c = m.cells[T.cell_key(x, y)]
    if not c then return 0, 0 end
    local t = now()
    return aged(c.d, c.t, t, T.DANGER_HALFLIFE), aged(c.r, c.t, t, T.TRAFFIC_HALFLIFE)
end

function T.danger_at(x, y) local d = T.sample(x, y); return d end
function T.traffic_at(x, y) local _, r = T.sample(x, y); return r end

-- The multiplicative factor the planner applies. ALWAYS >= FLOOR so the search
-- heuristic stays admissible: a road can only ever pull the cost DOWN toward the
-- floor, never below it, and danger only ever pushes it up.
--
-- opts.danger_tolerance (0..1) lets a caller say "I am strong here, mobs matter
-- less" - which is exactly how a high-level character treats a low-level zone.
function T.factor(x, y, z, opts)
    opts = opts or {}
    local d, r = T.sample(x, y)
    local W = T.W

    -- Off-road ground carries a standing premium, and a road REMOVES it. Stated
    -- the other way round (start at the floor and discount roads) the discount
    -- would just clamp away and a road would never actually be preferred - the
    -- premium has to exist before it can be earned back.
    -- The floor is still 1.0, so the search heuristic stays admissible.
    local f = W.FLOOR + W.ROAD_DISCOUNT
    if r > 0 then
        local road = min(1, r / 12.0)
        f = f - W.ROAD_DISCOUNT * road
    end

    -- DANGER PUSH
    if d > 0 then
        local tol = 1 - (tonumber(opts.danger_tolerance) or 0)
        local dn = min(1, d / 12.0)
        f = f + W.DANGER * dn * max(0, tol)
    end

    if f < W.FLOOR then f = W.FLOOR end
    return f
end

-- Is this route worth leaving the road for? Human logic: stay on the road unless
-- the shortcut saves real time AND is not more dangerous.
function T.prefer_road(road_len, shortcut_len, road_danger, shortcut_danger)
    road_len = road_len or 0; shortcut_len = shortcut_len or 0
    local risk = (shortcut_danger or 0) - (road_danger or 0)
    -- a shortcut must beat the road by more than the risk it adds
    local threshold = 1.0 + max(0, risk) * 0.08
    return shortcut_len * threshold >= road_len
end

function T.stats()
    local m = bucket()
    local n, dsum, rsum, hot = 0, 0, 0, 0
    local t = now()
    for _, c in pairs(m.cells) do
        n = n + 1
        local d = aged(c.d, c.t, t, T.DANGER_HALFLIFE)
        local r = aged(c.r, c.t, t, T.TRAFFIC_HALFLIFE)
        dsum = dsum + d; rsum = rsum + r
        if r >= 8 then hot = hot + 1 end
    end
    return { map = T.map_key(), cells = n, danger = dsum, traffic = rsum, road_cells = hot }
end

-- Drop cells that have decayed to irrelevance (called on logout).
-- Prune EVERY map, not just the one we are standing in: the others are exactly
-- the ones that will never be visited again this session and so would otherwise
-- never be cleaned.
function T.prune()
    local t = now()
    local total = 0
    for _, m in pairs(root()) do
        if type(m) == "table" and type(m.cells) == "table" then
            local kept = {}
            for k, c in pairs(m.cells) do
                local d = aged(c.d, c.t, t, T.DANGER_HALFLIFE)
                local r = aged(c.r, c.t, t, T.TRAFFIC_HALFLIFE)
                if d > 0.2 or r > 0.2 then
                    kept[k] = { d = d, r = r, t = t }
                    total = total + 1
                end
            end
            m.cells = kept
            enforce_cap(m, t)
        end
    end
    return total
end

if RaijinLab then RaijinLab.Traversability = T end
return T
