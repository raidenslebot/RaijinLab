-- Obstacles - transient solid-entity layer.
--
-- The WorldMesh remembers TERRAIN, which is permanent. Creatures, players and
-- movable objects are not: they walk away. Writing them into the persistent map
-- would poison it forever - every mob you ever stood next to would become a
-- permanent hole in the navmesh. So living geometry lives here instead, in a
-- short-lived snapshot that is rebuilt from the object manager and never saved.
--
-- Two consumers:
--   * the planner asks `penalty()` / `blocks()` so a route prefers to go around a
--     stationary pack rather than through it;
--   * the steerer asks `nearest_intrusion()` so it can slide past something that
--     wandered into the corridor after the route was computed.
--
-- Entities are stored with their real collision size (combat reach / bounding
-- radius from the runtime) plus the character's own half-width, so "blocked"
-- means the BODY genuinely cannot fit - not merely that a centre point overlaps.

local Obstacles = {}

local sqrt, floor = math.sqrt, math.floor

Obstacles.BODY_HALF   = 0.45     -- our own half-width (matches Pathfinder capsule)
-- Faster refresh is free once radius is cached and positions use one OM pass.
Obstacles.REFRESH     = 0.12
Obstacles.RANGE       = 100      -- wider awareness at lower unit cost
Obstacles.SOFT_PAD    = 1.5      -- yd beyond the hard radius that costs extra
Obstacles.W_NEAR      = 2.5      -- cost factor added when brushing an entity

Obstacles._list = {}
Obstacles._t = 0
Obstacles._enabled = true
Obstacles._rad = {}              -- guid -> combat radius (stable for a unit type)

local function now() return (GetTime and GetTime()) or 0 end

-- Collision radius of a unit/object, falling back sanely when the runtime cannot
-- answer (an unknown size must not silently become zero - that would let the
-- planner route straight through it). Cached per GUID: reach does not change.
local function solid_radius(guid)
    local cached = Obstacles._rad[guid]
    if cached then return cached end
    local RL = RaijinLab
    local r = nil
    if RL and RL.ObjectCombatReach then
        local ok, v = pcall(RL.ObjectCombatReach, RL, guid)
        if ok and tonumber(v) and tonumber(v) > 0 then r = tonumber(v) end
    end
    if not r and RL and RL.ObjectBoundingRadius then
        local ok, v = pcall(RL.ObjectBoundingRadius, RL, guid)
        if ok and tonumber(v) and tonumber(v) > 0 then r = tonumber(v) end
    end
    r = r or 1.0
    Obstacles._rad[guid] = r
    return r
end

-- Rebuild the snapshot from the object manager. Positions from ObjectPosition
-- stay authoritative; radius is free after first query.
function Obstacles.refresh(force)
    if not Obstacles._enabled then Obstacles._list = {}; return 0 end
    local t = now()
    if not force and (t - (Obstacles._t or 0)) < Obstacles.REFRESH then return #Obstacles._list end
    Obstacles._t = t
    local RL = RaijinLab
    local om = RL and RL.om and RL.om.object_list
    local out = {}
    if not om then Obstacles._list = out; return 0 end
    local px, py, pz
    if RL.ObjectPosition then px, py, pz = RL:ObjectPosition("player") end
    if not px then Obstacles._list = out; return 0 end
    local myguid = UnitGUID and UnitGUID("player")
    local r2 = Obstacles.RANGE * Obstacles.RANGE
    local half = Obstacles.BODY_HALF

    local function consider(list, kind)
        for i = 1, #(list or {}) do
            local s = list[i]
            local guid = s and s.Guid
            if guid and guid ~= myguid then
                local dead = s.Info and s.Info.Unit and s.Info.Unit.Dead
                if not dead and RL.ObjectPosition then
                    local x, y, z = RL:ObjectPosition(guid)
                    if x then
                        local dx, dy = x - px, y - py
                        if (dx * dx + dy * dy) <= r2 then
                            out[#out + 1] = {
                                guid = guid, x = x, y = y, z = z,
                                r = solid_radius(guid) + half,
                                kind = kind, name = s.Name,
                            }
                        end
                    end
                end
            end
        end
    end
    consider(om.npcs, "unit")
    consider(om.players, "player")
    consider(om.gameobjects, "object")
    Obstacles._list = out
    -- Bound radius cache so long sessions do not grow forever.
    local nrad = 0
    for _ in pairs(Obstacles._rad) do nrad = nrad + 1 end
    if nrad > 2000 then Obstacles._rad = {} end
    return #out
end

-- Hard block: the body genuinely cannot occupy this point.
-- `opts.ignore` = { [guid]=true } so we can path TO something without it blocking
-- its own approach (you must be able to reach the mob you intend to hit).
function Obstacles.blocks(x, y, z, opts)
    opts = opts or {}
    if not Obstacles._enabled or not x then return false end
    local list = Obstacles._list
    for i = 1, #list do
        local o = list[i]
        if not (opts.ignore and opts.ignore[o.guid]) then
            -- Vertical separation matters: something on the floor below is not in
            -- the way, so only treat it as solid within body height.
            if not z or not o.z or math.abs(o.z - z) <= 3.0 then
                local dx, dy = x - o.x, y - o.y
                if (dx * dx + dy * dy) < (o.r * o.r) then return true, o end
            end
        end
    end
    return false
end

-- Soft cost: brushing past an entity is possible but undesirable, so the planner
-- naturally leaves a margin instead of clipping every mob on the way.
function Obstacles.penalty(x, y, z, opts)
    opts = opts or {}
    if not Obstacles._enabled or not x then return 0 end
    local list = Obstacles._list
    local worst = 0
    for i = 1, #list do
        local o = list[i]
        if not (opts.ignore and opts.ignore[o.guid]) then
            if not z or not o.z or math.abs(o.z - z) <= 3.0 then
                local dx, dy = x - o.x, y - o.y
                local d = sqrt(dx * dx + dy * dy)
                local soft = o.r + Obstacles.SOFT_PAD
                if d < soft then
                    local w = Obstacles.W_NEAR * (1 - (d - o.r) / Obstacles.SOFT_PAD)
                    if w < 0 then w = 0 end
                    if w > worst then worst = w end
                end
            end
        end
    end
    return worst
end

-- The nearest thing actually intruding on the segment we are about to walk.
-- Used by the steerer to sidestep something that moved in after planning.
function Obstacles.nearest_intrusion(ax, ay, bx, by, z, opts)
    opts = opts or {}
    if not Obstacles._enabled or not ax or not bx then return nil end
    local list = Obstacles._list
    local vx, vy = bx - ax, by - ay
    local seglen2 = vx * vx + vy * vy
    local best, bestd = nil, math.huge
    for i = 1, #list do
        local o = list[i]
        if not (opts.ignore and opts.ignore[o.guid]) then
            if not z or not o.z or math.abs(o.z - z) <= 3.0 then
                -- distance from the entity to the segment
                local t = 0
                if seglen2 > 1e-6 then
                    t = ((o.x - ax) * vx + (o.y - ay) * vy) / seglen2
                    if t < 0 then t = 0 elseif t > 1 then t = 1 end
                end
                local cx, cy = ax + vx * t, ay + vy * t
                local dx, dy = o.x - cx, o.y - cy
                local d = sqrt(dx * dx + dy * dy)
                if d < o.r and d < bestd then best, bestd = o, d end
            end
        end
    end
    if best then return best, bestd end
    return nil
end

function Obstacles.stats()
    return { enabled = Obstacles._enabled, n = #Obstacles._list,
             age = now() - (Obstacles._t or 0) }
end

function Obstacles.set_enabled(on) Obstacles._enabled = on and true or false end

if RaijinLab then RaijinLab.Obstacles = Obstacles end
return Obstacles
