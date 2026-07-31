-- Shared, TTL'd ground-height cache.
--
-- TraceGround is the single hottest raycast in the whole system: the pathfinder
-- calls it for every candidate neighbor AND every ~1.5yd sample along every edge
-- it validates, and the navigator's terrain probe calls it ~10x/second. Terrain
-- is static, so we cache each result by grid cell. Re-searches over the same
-- ground become near-free, which is exactly what lets the pathfinder be
-- exhaustive and high-resolution without the raycasts ever adding up to a cost.
--
-- A cached value of `false` means "verified: no ground here" (a real cliff/gap),
-- which is just as valuable to cache as a hit. Cells carry a timestamp and a
-- coarse elevation "level" so stacked geometry (a bridge over ground) doesn't
-- collapse into one cell. The table is capped and wiped wholesale when it grows
-- too large (a search area is bounded; an occasional wipe is cheaper than LRU
-- bookkeeping on the hot path).

local GroundCache = {}
GroundCache._cells = {}
GroundCache._count = 0
-- 1.5yd cells: denser coverage of the same TraceGround budget -> more hits for
-- pathfinder edge samples (was 1.0; still accurate enough for walk heights).
GroundCache._res = 1.5
GroundCache._ttl = 45           -- terrain is static; longer TTL = more free hits
GroundCache._cap = 80000        -- larger map before wipe; wipe still O(1) wholesale
GroundCache._hits = 0
GroundCache._misses = 0

-- Shared spans. Walkability and discovery used to disagree (6 vs 14), which is
-- how water 7-13yd deep was green-lit ahead and reclassified as airborne on
-- arrival. One source of truth; every caller picks a named span, not a magic.
GroundCache.WALK_DOWN = 6.0          -- max drop a standing character tolerates
GroundCache.DISCOVERY_DOWN = 14.0    -- pathfinder z-hint recovery only

local floor = math.floor
local function now() return (GetTime and GetTime()) or 0 end

function GroundCache.clear()
    GroundCache._cells = {}
    GroundCache._count = 0
end

-- Is this XY water on the MAP (priced, not forbidden)? Geographic only.
-- NEVER fold the player's IsSwimming() into this - that made every look-ahead
-- cell "water" while swimming, so shore_intent could never see dry land ahead
-- and climb-out only worked when the final goal happened to be dry.
-- Returns: true / false / nil (nil = no map data for this cell).
function GroundCache.is_water(x, y)
    local NG = RaijinLab and RaijinLab.NavGrid
    if NG and NG.at and NG.WATER then
        local code = NG.at(x, y)
        if code == nil then return nil end
        if code == NG.WATER then return true end
        return false
    end
    return nil
end

-- Turn a TraceGround hit (or nil) into a ROUTE height.
--
-- Lake beds found 10yd under the travel band are NOT walkable ground and are
-- NOT good path nodes either - swimming happens near the current altitude, not
-- at the mud. Deep dry drops are cliffs. Named, pure, and tested: this is the
-- policy pathfinder and terrain_probe must share or they disagree at the shore.
--
-- Returns: route_z or nil, kind in {"walk","wade","swim","void","cliff"}
function GroundCache.route_z(zh, hit, is_water)
    local walk = GroundCache.WALK_DOWN or 6.0
    if hit == nil then
        -- No solid within the probe. Water is still crossable (the liquid
        -- surface has no collision bit); dry air is a void/cliff.
        if is_water then return zh, "swim" end
        return nil, "void"
    end
    local band = zh or hit
    local depth = band - hit
    if depth <= walk + 0.01 then
        if is_water and depth > 1.5 then return hit, "wade" end
        return hit, "walk"
    end
    if is_water then
        -- Keep the altitude band. A path node on the lake bed would make the
        -- character dive the moment it stepped off the shore.
        return band, "swim"
    end
    return nil, "cliff"
end

-- Ground Z under (x, y) near the z-hint, or nil when there's no floor. On a miss
-- calls `probe(x, y, zh)` (defaults to RaijinLab:TraceGround). Pass an explicit
-- probe in tests to run without a client.
--
-- up/down are the TraceGround spans. DEFAULT DOWN IS WALK_DOWN (6yd), NOT 14.
-- Callers that need discovery pass DISCOVERY_DOWN explicitly; the cache key
-- includes the span so a 14yd hit never answers a 6yd walkability question.
function GroundCache.ground(x, y, zh, probe, up, down)
    up = up or 3.0
    down = down or GroundCache.WALK_DOWN or 6.0
    local res = GroundCache._res
    local lvl = floor((zh or 0) / 10)         -- elevation bucket for stacked geometry
    -- Numeric key (no string concat on the hot path). Packs x,y,lvl,down into one
    -- number; range is fine for Azeroth coords at 1.5yd resolution.
    local ix = floor(x / res + 0.5)
    local iy = floor(y / res + 0.5)
    local idn = floor(down + 0.5)
    -- Cantor-ish mix; keep in number range Lua handles as int.
    local key = ix * 73856093 + iy * 19349663 + lvl * 83492791 + idn
    local c = GroundCache._cells[key]
    local t = now()
    if c and (t - c.t) < GroundCache._ttl then
        GroundCache._hits = GroundCache._hits + 1
        if c.z == false then return nil end
        return c.z
    end
    GroundCache._misses = GroundCache._misses + 1
    local z
    if probe then
        z = probe(x, y, zh)
    elseif RaijinLab and RaijinLab.TraceGround then
        z = RaijinLab:TraceGround(x, y, zh or 0, up, down)
    end
    if GroundCache._count > GroundCache._cap then GroundCache.clear() end
    if not GroundCache._cells[key] then GroundCache._count = GroundCache._count + 1 end
    -- Reuse cell table when present to cut GC churn on thrashing edges.
    if c then
        c.z = (z ~= nil and z) or false
        c.t = t
    else
        GroundCache._cells[key] = { z = (z ~= nil and z) or false, t = t }
    end
    return z
end

function GroundCache.stats()
    local h, m = GroundCache._hits, GroundCache._misses
    return {
        hits = h, misses = m, count = GroundCache._count,
        rate = (h + m) > 0 and (h / (h + m)) or 0,
    }
end

if RaijinLab then RaijinLab.GroundCache = GroundCache end
return GroundCache
