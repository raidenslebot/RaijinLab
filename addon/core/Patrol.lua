-- Patrol - spawn-point aware area work.
--
-- When the job is "kill 12 of these", standing still is wrong and wandering
-- randomly is worse. A human learns where that mob actually spawns and walks a
-- circuit between those points, arriving as each one repopulates.
--
-- So we remember spawns as we kill/see them, and hand out the next point to
-- visit: near enough to be worth walking to, but NOT the one we just cleared -
-- weighted by how long ago we were there, so the route naturally becomes a
-- respawn-timed loop instead of an oscillation between two adjacent camps.

local Patrol = {}

local sqrt, huge = math.sqrt, math.huge

Patrol.RECENT = 90.0        -- s: a point cleared this recently is "cold"
Patrol.ARRIVE = 8.0         -- yd: close enough to count as visited
Patrol._visited = {}        -- [poi record] = last visit time (session only)

local function now() return (GetTime and GetTime()) or 0 end
local function P() return RaijinLab and RaijinLab.POI end

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

-- Record that `name` exists here. Called when we see (or kill) one.
function Patrol.note_spawn(name, x, y, z, entry)
    local poi = P()
    if not (poi and name and x) then return nil end
    return poi.record("spawn", { x = x, y = y, z = z, name = name, entry = entry })
end

-- Learn spawns from whatever the object manager can currently see.
function Patrol.observe(name_filter)
    local RL = RaijinLab
    local om = RL and RL.om and RL.om.object_list
    if not om then return 0 end
    local n = 0
    for i = 1, #(om.npcs or {}) do
        local s = om.npcs[i]
        local guid = s and s.Guid
        if guid and s.Name and RL.ObjectPosition then
            local dead = s.Info and s.Info.Unit and s.Info.Unit.Dead
            if not dead and (not name_filter or s.Name == name_filter) then
                local x, y, z = RL:ObjectPosition(guid)
                if x then Patrol.note_spawn(s.Name, x, y, z, s.Id); n = n + 1 end
            end
        end
    end
    return n
end

-- All remembered spawn points for `name`, optionally constrained to a work area.
function Patrol.points(name, cx, cy, radius)
    local poi = P()
    if not poi then return {} end
    local out = {}
    for _, r in ipairs(poi.list("spawn")) do
        if (not name) or r.n == name then
            if not (cx and radius) or d2(cx, cy, r.x, r.y) <= radius then
                out[#out + 1] = r
            end
        end
    end
    return out
end

-- Mark a point as worked (called on arrival / on a kill there).
-- Keyed by POI's STABLE key, not the record table: persisted tables are replaced
-- wholesale by a reload or a DB sanitize pass, which silently emptied a
-- table-keyed set and made the patrol forget everything it had just worked.
local function vkey(rec)
    local P = RaijinLab and RaijinLab.POI
    if P and P.key_of then return P.key_of(rec) end
    return rec
end
Patrol._vkey = vkey

function Patrol.mark_visited(rec)
    if rec then Patrol._visited[vkey(rec)] = now() end
end

-- The next place to go. Scores every known spawn by distance AND staleness, so
-- the circuit prefers somewhere that has had time to repopulate over the camp we
-- just emptied - which is what turns "wandering" into a real patrol.
-- Returns rec, distance, or nil when nothing is known yet.
function Patrol.next_point(name, px, py, pz, opts)
    opts = opts or {}
    local pts = Patrol.points(name, opts.center_x or px, opts.center_y or py, opts.radius)
    if #pts == 0 then return nil, nil, "no_known_spawns" end
    local t = now()
    local best, bestscore, bestd = nil, huge, nil
    for _, r in ipairs(pts) do
        local d = d2(px or 0, py or 0, r.x, r.y)
        if d > (opts.arrive or Patrol.ARRIVE) or #pts == 1 then
            local age = t - (Patrol._visited[vkey(r)] or -1e9)
            -- Distance is the base cost; a point visited recently is penalised in
            -- proportion to how recently, decaying to nothing once it has had time
            -- to respawn.
            local recent = 0
            local window = opts.recent or Patrol.RECENT
            if age < window then recent = (1 - age / window) * (opts.recent_weight or 220) end
            -- Slight preference for well-established spawns (seen many times) -
            -- those are real camps rather than a wanderer we saw once.
            local conf = -math.min(40, (r.c or 1) * 4)
            local score = d + recent + conf
            if score < bestscore then best, bestscore, bestd = r, score, d end
        end
    end
    if not best then return nil, nil, "all_recent" end
    return best, bestd, "ok"
end

-- Convenience: a full ordered circuit (nearest-neighbour tour) for display or for
-- a caller that wants to precompute the loop rather than ask point by point.
function Patrol.circuit(name, px, py, opts)
    opts = opts or {}
    local pts = Patrol.points(name, opts.center_x or px, opts.center_y or py, opts.radius)
    local out, used = {}, {}
    local cx, cy = px or 0, py or 0
    for _ = 1, #pts do
        local best, bestd = nil, huge
        for i, r in ipairs(pts) do
            if not used[i] then
                local d = d2(cx, cy, r.x, r.y)
                if d < bestd then best, bestd = i, d end
            end
        end
        if not best then break end
        used[best] = true
        out[#out + 1] = pts[best]
        cx, cy = pts[best].x, pts[best].y
    end
    return out
end

-- The natural centre + radius of a mob's territory, so a caller can say "work
-- this camp" without hardcoding coordinates.
function Patrol.area_of(name)
    local pts = Patrol.points(name)
    if #pts == 0 then return nil end
    local sx, sy, sz = 0, 0, 0
    for _, r in ipairs(pts) do sx = sx + r.x; sy = sy + r.y; sz = sz + (r.z or 0) end
    local n = #pts
    local cx, cy, cz = sx / n, sy / n, sz / n
    local rad = 0
    for _, r in ipairs(pts) do
        local d = d2(cx, cy, r.x, r.y)
        if d > rad then rad = d end
    end
    return { x = cx, y = cy, z = cz, radius = rad, points = n }
end

function Patrol.reset_visits() Patrol._visited = {} end

function Patrol.stats(name)
    local pts = Patrol.points(name)
    local t, recent = now(), 0
    for _, r in ipairs(pts) do
        if (t - (Patrol._visited[vkey(r)] or -1e9)) < Patrol.RECENT then recent = recent + 1 end
    end
    return { name = name, points = #pts, recently_worked = recent }
end

if RaijinLab then RaijinLab.Patrol = Patrol end
return Patrol
