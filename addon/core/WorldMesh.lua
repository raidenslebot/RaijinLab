-- Persistent world map: navmesh + exploration heatmap in ONE store (v2).
--
-- The world, remembered - not just its trouble spots. Every cell the character
-- physically TRAVERSES is recorded as confirmed-walkable and its visit count
-- grows (the heatmap: exactly where it has and has not been). Look-ahead raycasts
-- (Surveyor) fill in cells AHEAD as merely seen. Falls / water / repeated snags
-- downgrade cells; later clean passes heal them. It is self-expanding and
-- self-healing, persisted per continent in SavedVariables.
--
-- Storage is ONE packed Lua number per 4yd cell (46 bits, no sub-tables - compact
-- on disk + cheap for the GC). Bounded per map; when full, whole low-traffic
-- 64yd chunks are evicted so the well-travelled corridors always survive.
--
-- Query API (fast O(1) grid lookups) feeds the quality-cost pathfinder:
--   cost_factor(x,y,z) -> multiplicative terrain factor (>=1); observed_frac; heat;
--   is_walkable; is_blacklisted; ground_hint. Legacy penalty()/mark_stuck()/
--   mark_ramp() are preserved so existing callers keep working.

local WorldMesh = {}

-- PLANNING CELL SIZE, CHOSEN BY MEASUREMENT.
--
-- This was 4.0, which is WIDER THAN A DOORWAY (2-4yd): the planner could not
-- place a node inside one, so no route ever went through a door however good the
-- terrain data got. The NavGrid beneath it is now 0.5yd, and a graph four times
-- coarser than its own evidence throws that away.
--
-- Not simply "as fine as possible": the A* node budget is fixed, so halving the
-- cell size quarters the reachable radius. Measured against the scenario suite -
--   4.0 -> 15/15, but doorways are unrepresentable
--   2.0 -> 15/15   <-- doorways fit, long-range planning still reaches
--   1.0 -> 14/15   plans_around_walls_at_range fails: the budget runs out before
--                  the route gets round an 800yd wall
-- so 2.0 looked like the finest grid that keeps long-range planning intact.
--
-- REVERTED TO 4.0. The scenario suite passed at 2.0 but the UNIT suite did not:
-- 16 checks depend on this constant, and refining it without understanding that
-- coupling traded a theoretical gain (a doorway node) for a demonstrably broken
-- mesh layer. Refining this is a real piece of work - the mesh, HLP and their
-- tests have to move together - not a constant to nudge.
WorldMesh.MRES   = 2.0            -- nav + heatmap cell size (yd)
-- Vertical bucket. This MUST be smaller than a building storey, or two floors
-- collapse into one cell and the mesh believes the upstairs and the downstairs
-- are the same place - which is exactly how a bot walks confidently into a wall
-- indoors. A storey is typically 5-7yd, so 8.0 (the original value) conflated
-- them; 4.0 separates them and still represents z from -2048 to +2044yd, far more
-- than the world uses. Cell COUNT is unaffected: each (x,y) column still has one
-- ground height, so only genuinely stacked geometry gains cells - which is the
-- entire point.
WorldMesh.VBUCKET = 4.0           -- vertical bucket (stacked geometry -> distinct cells)
WorldMesh._cap   = 20000          -- max cells per map before chunk eviction
WorldMesh._blacklist_n = 3        -- stuck events in a cell before it's a hole
WorldMesh.EVICT_HALFLIFE_SESSIONS = 6   -- how fast old traffic fades for eviction
WorldMesh._test_map = nil         -- tests pin the map key here

-- back-compat fields some callers/tests read
WorldMesh._res = WorldMesh.MRES
WorldMesh._zres = WorldMesh.VBUCKET

local floor = math.floor
local function now() return (GetTime and GetTime()) or 0 end

-- ---- cell state / hazard enums ----
WorldMesh.UNKNOWN, WorldMesh.OPEN_RAYCAST, WorldMesh.OPEN_TRAVERSED, WorldMesh.BLOCKED = 0, 1, 2, 3
local HZ_CLIFF, HZ_WATER, HZ_STUCK, HZ_FELL = 1, 2, 4, 8

-- PRECISION BUDGET: the packed word must stay under 1e14 so that a
-- SavedVariables round-trip (which serialises with ~14 significant digits) is
-- EXACT. The current maximum is ~7.04e13 = 14 digits. Adding a field above the
-- `seen` shift pushes it to 16 digits, and the precision is lost from the LOW
-- bits - silently corrupting state/hazard/links on every reload. Anything that
-- does not fit belongs in a parallel sparse table (see m.slopes), not in here.
-- ---- packed cell: one number, fields at fixed bit shifts (arithmetic pack so it
-- works on Lua 5.1 in-game AND the 5.3 test harness - no bit library needed) ----
--   state 2 | hazard 4 | links 8 | visits 8 | stuck 3 | conf 4 | dz 7 | seen 10
local F = {
    state  = { sh = 1,           m = 4 },
    hazard = { sh = 4,           m = 16 },
    links  = { sh = 64,          m = 256 },
    visits = { sh = 16384,       m = 256 },
    stuck  = { sh = 4194304,     m = 8 },
    conf   = { sh = 33554432,    m = 16 },
    dz     = { sh = 536870912,   m = 128 },     -- signed via +64 bias, 0.25yd quant
    seen   = { sh = 68719476736, m = 1024 },
}
local function fget(w, f) local d = F[f]; return floor((w or 0) / d.sh) % d.m end
local function fset(w, f, v)
    local d = F[f]
    if v < 0 then v = 0 elseif v > d.m - 1 then v = d.m - 1 end
    local cur = floor((w or 0) / d.sh) % d.m
    return (w or 0) + (v - cur) * d.sh
end
WorldMesh._fget, WorldMesh._fset = fget, fset   -- exposed for tests

-- Largest value the packed word can hold across EVERY registered field. Tests
-- assert this still round-trips through 14 significant digits, so adding a field
-- that breaks the precision budget fails loudly instead of silently corrupting
-- state/hazard/links on the next reload.
function WorldMesh._max_word()
    local w = 0
    for _, d in pairs(F) do w = w + d.sh * (d.m - 1) end
    return w
end

-- ---- cell id (exact double, < 2.8e11) + inverse ----
local BIAS = 8192          -- +/-8192 cells * 4yd = +/-32768 yd (a continent)
local ZBIAS = 512
function WorldMesh.cell_id(x, y, z)
    local cx = floor(x / WorldMesh.MRES) + BIAS
    local cy = floor(y / WorldMesh.MRES) + BIAS
    local cb = floor((z or 0) / WorldMesh.VBUCKET) + ZBIAS
    if cx < 0 then cx = 0 elseif cx > 16383 then cx = 16383 end
    if cy < 0 then cy = 0 elseif cy > 16383 then cy = 16383 end
    if cb < 0 then cb = 0 elseif cb > 1023 then cb = 1023 end
    return (cx * 16384 + cy) * 1024 + cb
end
function WorldMesh.cell_center(id)
    local cb = id % 1024
    local rest = floor(id / 1024)
    local cy = rest % 16384
    local cx = floor(rest / 16384)
    return (cx - BIAS + 0.5) * WorldMesh.MRES,
           (cy - BIAS + 0.5) * WorldMesh.MRES,
           (cb - ZBIAS + 0.5) * WorldMesh.VBUCKET
end

-- raw (biased) cell coords from an id, and id from raw coords
local function cell_coords(id)
    local cb = id % 1024
    local rest = floor(id / 1024)
    return floor(rest / 16384), rest % 16384, cb   -- cx, cy, cb (biased ints)
end
local function coords_id(cx, cy, cb) return (cx * 16384 + cy) * 1024 + cb end

-- 8-neighbour directions and their link-bit index (0..7)
local DIRS8 = { {1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1} }
local function dir_bit(dx, dy)
    for i = 1, 8 do if DIRS8[i][1] == dx and DIRS8[i][2] == dy then return i - 1 end end
    return nil
end
local function set_link(w, b)
    local links = fget(w, "links")
    local mask = 2 ^ b
    if floor(links / mask) % 2 == 0 then w = fset(w, "links", links + mask) end
    return w
end

-- ---- store ----
local function root()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.worldmesh = RaijinLabDB.worldmesh or { version = 2 }
    return RaijinLabDB.worldmesh
end

-- The key EVERY persistent store buckets on (POI, Traversability, TravelNet and
-- Death all delegate here), so it must describe where the PLAYER is.
--
-- GetCurrentMapContinent alone does not: it reports whatever the world-map UI is
-- currently showing. Opening the map and browsing another continent would silently
-- redirect every mesh cell, POI and danger sample into the wrong bucket - and the
-- data would look perfectly valid afterwards. So the UI map is pinned to the
-- player before reading it, and the result is cached against the player's actual
-- zone so this costs nothing on the hot path.
function WorldMesh.map_key()
    if WorldMesh._test_map then return WorldMesh._test_map end
    local zone = (GetRealZoneText and GetRealZoneText()) or ""
    if zone ~= "" and WorldMesh._mk_zone == zone and WorldMesh._mk then
        return WorldMesh._mk
    end
    local c = nil
    if GetCurrentMapContinent then
        -- Pin the map to us first; without this the reading describes the UI.
        if SetMapToCurrentZone then pcall(SetMapToCurrentZone) end
        local ok, v = pcall(GetCurrentMapContinent)
        if ok then c = v end
    end
    local key
    -- 0 is not a real continent on 3.3.5 (it means "no map"), so reject it as well
    -- as negatives rather than filing a whole run under "c0".
    if type(c) == "number" and c > 0 then
        key = "c" .. c
    elseif zone ~= "" then
        key = "z" .. zone
    else
        key = "world"
    end
    if zone ~= "" then WorldMesh._mk_zone, WorldMesh._mk = zone, key end
    return key
end

-- Legacy 2-yd key, kept because tests + older code call it.
function WorldMesh.key(x, y, z)
    return floor(x / 2.0 + 0.5) .. ":" .. floor(y / 2.0 + 0.5) .. ":" .. floor((z or 0) / 5.0 + 0.5)
end

local function migrate(m)
    -- v1 stored {stuck={key->{n,t}}, ramps={key->{n,t}}} at 2yd keys. Fold into cells:
    -- a stuck key -> STUCK hazard + stuck count; a ramp key -> a traversed, visited cell.
    if m._migrated or not (m.stuck or m.ramps) then return end
    -- v1 keys are "kx:ky:kz" in 2yd/5yd units -> world center -> new cell.
    local function keypos(k)
        local kx, ky, kz = k:match("^(-?%d+):(-?%d+):(-?%d+)$")
        if not kx then return nil end
        return tonumber(kx) * 2.0, tonumber(ky) * 2.0, tonumber(kz) * 5.0
    end
    m.cells = m.cells or {}
    for k, v in pairs(m.stuck or {}) do
        local x, y, z = keypos(k)
        if x then
            local id = WorldMesh.cell_id(x, y, z)
            local w = m.cells[id] or 0
            w = fset(w, "stuck", math.min(7, (v.n or 1)))
            local hz = fget(w, "hazard")
            if hz % (HZ_STUCK * 2) < HZ_STUCK then w = fset(w, "hazard", hz + HZ_STUCK) end
            m.cells[id] = w
        end
    end
    for k in pairs(m.ramps or {}) do
        local x, y, z = keypos(k)
        if x then
            local id = WorldMesh.cell_id(x, y, z)
            local w = m.cells[id] or 0
            if fget(w, "visits") < 2 then w = fset(w, "visits", 2) end
            w = fset(w, "state", WorldMesh.OPEN_TRAVERSED)
            m.cells[id] = w
        end
    end
    m.stuck, m.ramps, m._migrated = nil, nil, true
end

-- Re-key an existing map when the vertical resolution changes. Without this a
-- VBUCKET change silently invalidates every stored cell_id and the character
-- appears to forget the entire world; with it, the learned map survives.
local function migrate_vbucket(m)
    local cur = WorldMesh.VBUCKET
    -- Stores written before this field existed used the original 8yd bucket.
    local old = tonumber(m.vbucket) or 8.0
    if old == cur then m.vbucket = cur; return end
    local lo, hi = WorldMesh.dz_window(old)
    local out, n = {}, 0
    for id, w in pairs(m.cells or {}) do
        local cx, cy, cb = cell_coords(id)
        -- recover the approximate world height under the OLD bucketing
        local oldcz = (cb - ZBIAS + 0.5) * old
        local q = fget(w, "dz")
        local z = oldcz
        if q >= lo and q <= hi then z = oldcz + (q - 64) * 0.25 end
        local ncb = floor(z / cur) + ZBIAS
        if ncb < 0 then ncb = 0 elseif ncb > 1023 then ncb = 1023 end
        local nid = coords_id(cx, cy, ncb)
        -- re-encode the residual against the NEW cell centre
        local ncz = (ncb - ZBIAS + 0.5) * cur
        local nq = floor((z - ncz) / 0.25 + 0.5) + 64
        if nq < 0 then nq = 0 elseif nq > 127 then nq = 127 end
        local nw = fset(w, "dz", nq)
        local prev = out[nid]
        -- Two old cells can land in one new bucket; keep the better-evidenced one.
        if prev == nil or fget(nw, "visits") > fget(prev, "visits") then
            out[nid] = nw
        end
        n = n + 1
    end
    m.cells = out
    -- Slopes are keyed by cell id, so a re-key invalidates them. They are cheap to
    -- re-measure from the height field, so drop rather than mis-map them.
    m.slopes = {}
    m.vbucket = cur
    m._vmigrated = n
    WorldMesh._gen = (WorldMesh._gen or 0) + 1
end

local function bucket()
    local wm = root()
    local mk = WorldMesh.map_key()
    -- On a map change, forget the "previous cell": linking the first cell of the new
    -- map to a cell id from the old one would fabricate a bogus edge. The per-map
    -- heal set is reset too (heal-once is scoped to the map you're actually on).
    if WorldMesh._cur_map ~= mk then
        WorldMesh._cur_map = mk
        WorldMesh._last_id = nil
        WorldMesh._heal_id = nil
        WorldMesh._healed  = {}
    end
    local m = wm[mk]
    if not m then
        m = { cells = {}, chunks = {}, session = 1, t0 = now() }
        wm[mk] = m
    end
    m.cells = m.cells or {}
    m.chunks = m.chunks or {}
    -- Slope is stored OUTSIDE the packed word (precision budget, see above) and is
    -- sparse: only cells whose gradient was actually measured appear here.
    m.slopes = m.slopes or {}
    m.session = m.session or 1
    migrate(m)
    migrate_vbucket(m)
    return m
end

-- new session index each load, so decay/heal can tell "this run" from history
function WorldMesh.new_session()
    local m = bucket()
    m.session = (m.session or 0) + 1
    if m.session >= 1024 then m.session = 1 end
    WorldMesh._session = m.session
    WorldMesh._healed = {}      -- heal-once-per-cell is scoped to this session
    WorldMesh._last_id = nil    -- no link across the session boundary (respawn/teleport)
    WorldMesh._heal_id = nil
    return m.session
end
local function session(m) return WorldMesh._session or m.session or 1 end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- Evict whole low-traffic 64yd chunks when over cap (well-travelled corridors survive).
local function evict_if_full(m)
    if count(m.cells) <= WorldMesh._cap then return end
    -- Score each 64yd chunk by its PEAK per-cell visits (tie-break by total), then
    -- drop the lowest-scoring chunks until under 90% cap. Peak (not sum) is what
    -- keeps a compact high-traffic chokepoint alive against a large low-traffic
    -- sprawl: a corridor cell hit 200 times outranks 400 wander cells hit once.
    -- AGE the score by how long ago the chunk was last seen. `visits` only ever
    -- grows, so an un-aged score meant a freshly explored chunk (1 visit) was
    -- always the lowest scorer and got evicted the moment it appeared - once a
    -- continent reached cap the map FROZE and could never learn new ground again.
    -- Discounting by session distance lets long-dead territory fade and lets a
    -- genuinely-used new zone win its place.
    local cur_sess = session(m)
    local HALF = WorldMesh.EVICT_HALFLIFE_SESSIONS or 6
    local traffic = {}
    for id, w in pairs(m.cells) do
        local rest = floor(id / 1024)
        local ck = floor(floor(rest / 16384) / 16) * 65536 + floor((rest % 16384) / 16)
        local v = fget(w, "visits")
        local seen = fget(w, "seen")
        local t = traffic[ck]
        if not t then t = { peak = 0, sum = 0, seen = 0 }; traffic[ck] = t end
        if v > t.peak then t.peak = v end
        if seen > t.seen then t.seen = seen end
        t.sum = t.sum + v
    end
    -- Never evict the ground we are standing on, whatever it scores.
    local here = nil
    if WorldMesh._last_id then
        local rest = floor(WorldMesh._last_id / 1024)
        here = floor(floor(rest / 16384) / 16) * 65536 + floor((rest % 16384) / 16)
    end
    local order = {}
    for ck, t in pairs(traffic) do
        if ck ~= here then
            -- Session indices wrap at 1024; a negative age means a wrap, so treat
            -- it as "very old" rather than "from the future".
            local age = cur_sess - (t.seen or 0)
            if age < 0 then age = HALF * 4 end
            local score = (t.peak or 0) * (0.5 ^ (age / HALF))
            order[#order + 1] = { ck = ck, score = score, sum = t.sum }
        end
    end
    table.sort(order, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.sum < b.sum
    end)
    WorldMesh._gen = (WorldMesh._gen or 0) + 1   -- eviction removes cells
    local target = floor(WorldMesh._cap * 0.9)
    local di = 1
    while count(m.cells) > target and di <= #order do
        local ck = order[di].ck; di = di + 1
        local cxk, cyk = floor(ck / 65536), ck % 65536
        for id in pairs(m.cells) do
            local rest = floor(id / 1024)
            if floor(floor(rest / 16384) / 16) == cxk and floor((rest % 16384) / 16) == cyk then
                m.cells[id] = nil
                if m.slopes then m.slopes[id] = nil end   -- keep the parallel store in step
            end
        end
    end
end

-- Amortized cap guard: every creator of a NEW cell calls this so growth from any
-- source (traversal, Surveyor mark_seen, hazards) is bounded - the O(n) sweep only
-- actually runs once every 128 new cells, so it stays cheap.
local function bump_adds(m)
    WorldMesh._adds = (WorldMesh._adds or 0) + 1
    -- A new cell can add/extend a pyramid block, so invalidate the derived pyramid.
    -- Over-invalidating is harmless (it only forces a rebuild); under-invalidating
    -- would let the planner reason about a stale map, so this errs on the safe side.
    WorldMesh._gen = (WorldMesh._gen or 0) + 1
    if WorldMesh._adds % 128 == 0 then evict_if_full(m) end
end

-- ================= UPDATE =================

-- Record the character being at (x,y,z). `moving` true = it TRAVERSED here (bump the
-- heatmap on cell ENTRY, mark confirmed-walkable). Arithmetic-only, safe every tick.
function WorldMesh.observe(x, y, z, moving)
    if not x then return end
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local existed = m.cells[id] ~= nil
    local w = m.cells[id] or 0
    local entered = (id ~= WorldMesh._last_id)
    if moving and entered then
        w = fset(w, "visits", math.min(255, fget(w, "visits") + 1))
        -- First clean body-traversal of a snaggy cell this session heals one stuck
        -- point. Dedup on a per-session set (NOT `seen`, which the Surveyor also
        -- writes ahead of the body - that would suppress every heal), and NOT a
        -- single global id (which only blocked re-healing the immediately-prior cell).
        WorldMesh._healed = WorldMesh._healed or {}
        if fget(w, "stuck") > 0 and not WorldMesh._healed[id] then
            w = fset(w, "stuck", fget(w, "stuck") - 1)
            WorldMesh._healed[id] = true
        end
    end
    if moving then w = fset(w, "state", WorldMesh.OPEN_TRAVERSED) end
    w = fset(w, "conf", 15)
    w = fset(w, "seen", session(m))
    -- dz = fine ground-Z residual measured from THIS cell's centre (so ground_hint,
    -- which decodes cz + residual, inverts exactly). +64 bias, 0.25yd quant.
    local _, _, cz = WorldMesh.cell_center(id)
    local q = floor(((z or 0) - cz) / 0.25 + 0.5) + 64
    if q < 0 then q = 0 elseif q > 127 then q = 127 end
    w = fset(w, "dz", q)
    if m.slopes then m.slopes[id] = nil end   -- new height: recompute the gradient
    -- LINK: walking from the previous cell into this adjacent one proves a walkable
    -- connection - record it on BOTH cells (symmetric) so the mesh planner has edges.
    -- The link bit is 2D (dx,dy); a one-bucket Z change (ramp/stairs) still links, and
    -- neighbours() resolves the actual cb - so slopes stay connected in the mesh graph.
    if moving and entered and WorldMesh._last_id then
        local cx, cy, cb = cell_coords(id)
        local pcx, pcy, pcb = cell_coords(WorldMesh._last_id)
        local dx, dy = cx - pcx, cy - pcy
        if math.abs(cb - pcb) <= 2 and (dx ~= 0 or dy ~= 0)
            and math.abs(dx) <= 1 and math.abs(dy) <= 1 then
            local bcur = dir_bit(-dx, -dy)   -- this cell -> prev
            local bprev = dir_bit(dx, dy)    -- prev cell -> this
            if bcur then w = set_link(w, bcur) end
            local pw = m.cells[WorldMesh._last_id]
            if pw and bprev then m.cells[WorldMesh._last_id] = set_link(pw, bprev) end
        end
    end
    m.cells[id] = w
    WorldMesh._last_id = id
    if not existed then bump_adds(m) end
end

-- Explicit eviction (called on logout / idle, and by tests).
function WorldMesh.evict() evict_if_full(bucket()) end

-- Look-ahead raycast saw walkable ground here (merely SEEN, not traversed).
function WorldMesh.mark_seen(x, y, z, walkable)
    if not x then return end
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local existed = m.cells[id] ~= nil
    local w = m.cells[id] or 0
    if walkable then
        if fget(w, "state") < WorldMesh.OPEN_TRAVERSED then w = fset(w, "state", WorldMesh.OPEN_RAYCAST) end
    else
        -- A raycast "blocked" must NEVER clobber a cell the BODY already proved
        -- walkable - lived experience outranks a look-ahead ray that may have
        -- clipped a doodad or a transient object.
        if fget(w, "state") ~= WorldMesh.OPEN_TRAVERSED then
            if fget(w, "state") ~= WorldMesh.BLOCKED then WorldMesh._gen = (WorldMesh._gen or 0) + 1 end
            w = fset(w, "state", WorldMesh.BLOCKED)
        end
    end
    if fget(w, "conf") < 8 then w = fset(w, "conf", 8) end
    w = fset(w, "seen", session(m))
    -- Record the fine ground-Z residual for a raycast-seen floor exactly like
    -- observe() does. Without this a Surveyor-mapped cell kept dz=0, which decodes
    -- to cz-16yd - garbage that made ground_hint lie and would make any z-step gate
    -- reject perfectly flat ground. Only meaningful when we actually saw a floor.
    if walkable then
        local _, _, cz = WorldMesh.cell_center(id)
        local q = floor(((z or 0) - cz) / 0.25 + 0.5) + 64
        if q < 0 then q = 0 elseif q > 127 then q = 127 end
        w = fset(w, "dz", q)
        if m.slopes then m.slopes[id] = nil end   -- new height: recompute gradient
    end
    m.cells[id] = w
    if not existed then bump_adds(m) end
end

local function add_hazard(x, y, z, bit)
    if not x then return end
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local existed = m.cells[id] ~= nil
    local w = m.cells[id] or 0
    local hz = fget(w, "hazard")
    if hz % (bit * 2) < bit then w = fset(w, "hazard", hz + bit) end
    m.cells[id] = w
    if not existed then bump_adds(m) end
end
function WorldMesh.mark_cliff(x, y, z) add_hazard(x, y, z, HZ_CLIFF) end
function WorldMesh.mark_water(x, y, z) add_hazard(x, y, z, HZ_WATER) end
function WorldMesh.mark_fell(x, y, z)  add_hazard(x, y, z, HZ_FELL) end

-- LEGACY (kept so Navigator/tests keep working): a physical snag here.
function WorldMesh.mark_stuck(x, y, z)
    if not x then return end
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local existed = m.cells[id] ~= nil
    local w = m.cells[id] or 0
    w = fset(w, "stuck", math.min(7, fget(w, "stuck") + 1))
    local hz = fget(w, "hazard"); if hz % (HZ_STUCK * 2) < HZ_STUCK then w = fset(w, "hazard", hz + HZ_STUCK) end
    if fget(w, "stuck") >= WorldMesh._blacklist_n then
        if fget(w, "state") ~= WorldMesh.BLOCKED then WorldMesh._gen = (WorldMesh._gen or 0) + 1 end
        w = fset(w, "state", WorldMesh.BLOCKED)
    end
    m.cells[id] = w
    if not existed then bump_adds(m) end
end
-- LEGACY: a recovery/ascent succeeded here (a proven seam) -> treat as traversed.
function WorldMesh.mark_ramp(x, y, z)
    if not x then return end
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local existed = m.cells[id] ~= nil
    local w = m.cells[id] or 0
    if fget(w, "visits") < 3 then w = fset(w, "visits", 3) end
    w = fset(w, "state", WorldMesh.OPEN_TRAVERSED)
    m.cells[id] = w
    if not existed then bump_adds(m) end
end

-- ================= QUERY =================

function WorldMesh.get(x, y, z)
    local m = bucket()
    return m.cells[WorldMesh.cell_id(x, y, z)] or 0
end
-- Mesh graph: neighbouring cell ids reachable from `id` by a recorded walkable link
-- (raycast-free - this is what the mesh planner walks). Returns {id, x, y, z} entries.
function WorldMesh.neighbours(id)
    local m = bucket()
    local w = m.cells[id]
    local out = {}
    if not w then return out end
    local links = fget(w, "links")
    if links == 0 then return out end
    local cx, cy, cb = cell_coords(id)
    for i = 1, 8 do
        if floor(links / (2 ^ (i - 1))) % 2 == 1 then
            -- The link is a 2D direction; the connected cell may sit one Z bucket up
            -- or down (a ramp/stairs). Resolve same-level first, then +/- one bucket,
            -- and emit the first walkable match so slopes stay traversable.
            for _, ob in ipairs({ 0, 1, -1 }) do
                local nid = coords_id(cx + DIRS8[i][1], cy + DIRS8[i][2], cb + ob)
                local nw = m.cells[nid]
                if nw then
                    local st = fget(nw, "state")
                    if st ~= WorldMesh.BLOCKED and st ~= WorldMesh.UNKNOWN
                        and fget(nw, "stuck") < WorldMesh._blacklist_n then
                        local nx, ny, nz = WorldMesh.cell_center(nid)
                        out[#out + 1] = { id = nid, x = nx, y = ny, z = nz }
                        break
                    end
                end
            end
        end
    end
    return out
end

-- ---- state graph (the planner's real adjacency) --------------------------
-- `neighbours` only walks links the BODY physically traversed, so everything the
-- Surveyor maps ahead (OPEN_RAYCAST, hundreds of yards of it) is invisible to the
-- planner. `state_neighbours` derives adjacency from CELL STATE instead: any two
-- grid-adjacent open cells are connected, provided the height step between them is
-- walkable. That makes look-ahead perception first-class routing data.
--
-- Edges are THREE-VALUED: PROVEN (a recorded body link - we know it works),
-- OBSERVED (both ends seen open by raycast), and implicitly UNKNOWN (never
-- emitted: an UNKNOWN or BLOCKED endpoint is not a neighbour, so the planner can
-- never route through unproven ground).
WorldMesh.EDGE_OBSERVED, WorldMesh.EDGE_PROVEN = 1, 2
WorldMesh.EDGE_JUMP = 3        -- reachable only by jumping (parkour)

-- ---- movement model ------------------------------------------------------
-- These are the character's real locomotion limits, kept in ONE place so every
-- consumer (edge gating, cost, parkour) agrees on what the body can actually do.
-- A step you can simply WALK up is small; anything taller needs a jump; past the
-- jump height it is a wall. Slope matters independently of step height: on ground
-- steeper than the slide angle the character cannot hold position at all, which is
-- exactly the "which part of this hill can I run up" question.
WorldMesh.STEP_UP      = 0.9    -- yd: walk straight up (curb / small root)
WorldMesh.JUMP_UP      = 1.7    -- yd: ledge height a jump can gain
WorldMesh.STEP_DOWN    = 3.5    -- yd: drop taken in stride
WorldMesh.SAFE_DROP    = 8.0    -- yd: drop taken deliberately without real damage
WorldMesh.MAX_SLOPE    = 50.0   -- deg: steeper than this and you slide back down
WorldMesh.RUN_SLOPE    = 35.0   -- deg: beyond this you climb slowly - cost it
WorldMesh.JUMP_GAP     = 5.0    -- yd: horizontal gap a running jump clears

local DEG = 180 / math.pi
-- slope <-> bucket (1..63 == 0..90 deg; 0 == unmeasured)
local function slope_bucket(deg)
    if deg < 0 then deg = 0 elseif deg > 90 then deg = 90 end
    return floor(deg / 90 * 62 + 0.5) + 1
end
local function bucket_slope(b)
    if not b or b <= 0 then return nil end
    return (b - 1) * 90 / 62
end
WorldMesh._slope_bucket, WorldMesh._bucket_slope = slope_bucket, bucket_slope

-- Precise ground Z for a cell, or nil when the residual was never recorded.
-- Valid residuals are within +/- VBUCKET/2, i.e. q in [48,80]; anything else is an
-- unwritten field, not a real height.
-- The stored residual can only ever be within +/- VBUCKET/2 of the cell centre,
-- quantised at 0.25yd around a +64 bias - so the valid window is 64 +/- VBUCKET*2.
-- Deriving it (rather than hardcoding [48,80] for the old 8yd bucket) means the
-- "never written" test stays correct if the resolution changes again.
function WorldMesh.dz_window(vb)
    local h = (vb or WorldMesh.VBUCKET) * 2
    return 64 - h, 64 + h
end

function WorldMesh.ground_z(id, w)
    local m = bucket()
    w = w or m.cells[id]
    if not w then return nil end
    local q = fget(w, "dz")
    local lo, hi = WorldMesh.dz_window()
    if q < lo or q > hi then return nil end
    local _, _, cz = WorldMesh.cell_center(id)
    return cz + (q - 64) * 0.25
end

local function open_state(st)
    return st == WorldMesh.OPEN_TRAVERSED or st == WorldMesh.OPEN_RAYCAST
end

-- ---- terrain gradient ----------------------------------------------------
-- The real steepness of the ground at a cell, from a central difference over its
-- measured neighbour heights. This is what distinguishes "the gentle side of the
-- hill I can run up" from "the cliff face two yards away" - a per-step height
-- check alone cannot tell those apart, because both look like the same climb over
-- one cell.
-- Returns degrees, or nil when there is not enough measured ground around it.
function WorldMesh.compute_slope(id)
    local m = bucket()
    local w = m.cells[id]
    if not w then return nil end
    local z0 = WorldMesh.ground_z(id, w)
    if not z0 then return nil end
    local cx, cy, cb = cell_coords(id)
    local res = WorldMesh.MRES

    -- Sample the four axis neighbours, allowing one vertical bucket either way so
    -- a slope that crosses a bucket boundary still reads as one surface.
    local function h_at(ox, oy)
        -- Search +/-2 buckets: the window must be a distance in YARDS, not a
        -- bucket count. With VBUCKET at 4 a single bucket only reaches 4yd, which
        -- made genuinely steep faces unmeasurable (their neighbours sit 2 buckets
        -- away) and silently reported them as "unknown slope".
        for _, ob in ipairs({ 0, 1, -1, 2, -2 }) do
            local nid = coords_id(cx + ox, cy + oy, cb + ob)
            local nw = m.cells[nid]
            if nw and open_state(fget(nw, "state")) then
                local z = WorldMesh.ground_z(nid, nw)
                if z then return z end
            end
        end
        return nil
    end
    local e, we = h_at(1, 0), h_at(-1, 0)
    local n, s  = h_at(0, 1), h_at(0, -1)

    -- Central difference where both sides are known, one-sided where only one is.
    local gx, gy
    if e and we then gx = (e - we) / (2 * res)
    elseif e then gx = (e - z0) / res
    elseif we then gx = (z0 - we) / res end
    if n and s then gy = (n - s) / (2 * res)
    elseif n then gy = (n - z0) / res
    elseif s then gy = (z0 - s) / res end
    if not (gx or gy) then return nil end
    gx, gy = gx or 0, gy or 0
    local deg = math.atan(math.sqrt(gx * gx + gy * gy)) * DEG
    -- Only CACHE a gradient derived from a real central difference. At the edge of
    -- explored ground only one side is known, and a one-sided reading there can
    -- easily look like a cliff - caching that would permanently mark walkable
    -- ground as too steep, long after the neighbours became known. So a partial
    -- measurement is returned for immediate use but never persisted.
    local central = (e and we) or (n and s)
    if central then m.slopes[id] = slope_bucket(deg) end
    return deg
end

-- Cached slope in degrees (computes once on demand). nil = not determinable yet.
function WorldMesh.slope_deg(id)
    local m = bucket()
    local w = m.cells[id]
    if not w then return nil end
    local b = m.slopes[id]
    if b and b > 0 then return bucket_slope(b) end
    return WorldMesh.compute_slope(id)
end

function WorldMesh.slope_at(x, y, z) return WorldMesh.slope_deg(WorldMesh.cell_id(x, y, z)) end

-- New height evidence for a cell changes the gradient of its whole neighbourhood,
-- so drop the cached slopes there and let them be recomputed from better data.
function WorldMesh.invalidate_slope(id)
    local m = bucket()
    if not m.slopes then return end
    m.slopes[id] = nil
    local cx, cy, cb = cell_coords(id)
    for i = 1, 8 do
        for _, ob in ipairs({ 0, 1, -1 }) do
            m.slopes[coords_id(cx + DIRS8[i][1], cy + DIRS8[i][2], cb + ob)] = nil
        end
    end
end

-- Can the body traverse from height z0 to z1 over `run` yards of ground?
-- Returns walkable(bool), kind("walk"|"jump"|nil), reason.
function WorldMesh.step_kind(z0, z1, run)
    if not (z0 and z1) then return true, "walk" end     -- unmeasured: let the fine search decide
    local climb = z1 - z0
    run = math.max(run or WorldMesh.MRES, 0.01)
    if climb < 0 then
        -- Descending: a modest drop is taken in stride, a big one is a deliberate
        -- (survivable) drop, past that it is a cliff we must not walk off.
        if -climb <= WorldMesh.STEP_DOWN then return true, "walk" end
        if -climb <= WorldMesh.SAFE_DROP then return true, "jump", "drop" end
        return false, nil, "cliff"
    end
    -- ASCENDING. Slope is the primary test, not a fixed step height: over a 4yd
    -- cell a 1yd rise is a 14-degree ramp you simply run up, while the same 1yd as
    -- an abrupt riser would be a hop. At this resolution the gradient is the honest
    -- signal, so anything within the slide limit is walkable ground.
    local deg = math.atan(climb / run) * DEG
    if deg <= WorldMesh.MAX_SLOPE then return true, "walk" end
    -- Too steep to run up, but a short riser is still a jumpable ledge.
    if climb <= WorldMesh.JUMP_UP then return true, "jump", "ledge" end
    return false, nil, "wall"
end

-- Returns { {id,x,y,z,edge,climb}, ... } for `id`. opts.traversed_only restricts to
-- body-proven ground (useful when we want a guaranteed-safe corridor).
function WorldMesh.state_neighbours(id, opts)
    opts = opts or {}
    local m = bucket()
    local w = m.cells[id]
    local out = {}
    if not w then return out end
    if not open_state(fget(w, "state")) then return out end
    local cx, cy, cb = cell_coords(id)
    local links = fget(w, "links")
    local gz = WorldMesh.ground_z(id, w)
    for i = 1, 8 do
        local dx, dy = DIRS8[i][1], DIRS8[i][2]
        local proven = floor(links / (2 ^ (i - 1))) % 2 == 1
        local found = false
        -- Resolve the neighbour at this level first, then one bucket up/down so
        -- ramps and stairs stay connected (mirrors neighbours()).
        -- +/-2 buckets keeps the vertical reach at ~8yd (SAFE_DROP) now that a
        -- bucket is 4yd; step_kind still decides whether the step is legal.
        for _, ob in ipairs({ 0, 1, -1, 2, -2 }) do
            local nid = coords_id(cx + dx, cy + dy, cb + ob)
            local nw = m.cells[nid]
            if nw then
                local st = fget(nw, "state")
                if open_state(st) and fget(nw, "stuck") < WorldMesh._blacklist_n then
                    if not (opts.traversed_only and st ~= WorldMesh.OPEN_TRAVERSED) then
                        -- Full movement model. A recorded body link is PROOF the
                        -- step works, so it always passes; otherwise the step must
                        -- be walkable (or jumpable) AND the destination ground must
                        -- not be steeper than the character can hold.
                        local ngz = WorldMesh.ground_z(nid, nw)
                        local run = (dx ~= 0 and dy ~= 0) and (WorldMesh.MRES * 1.4142) or WorldMesh.MRES
                        local climb = (gz and ngz) and (ngz - gz) or nil
                        local ok, kind, why = WorldMesh.step_kind(gz, ngz, run)
                        -- Ground too steep to stand on is not traversable however
                        -- small the step looks (the hillside problem).
                        local nslope = WorldMesh.slope_deg(nid)
                        if ok and nslope and nslope > WorldMesh.MAX_SLOPE and not proven then
                            ok, why = false, "slide"
                        end
                        -- THE PREMAPPED WORLD IS PART OF THE MOVEMENT MODEL.
                        --
                        -- This accepted a neighbour on state + slope + step
                        -- height alone and NEVER consulted NavGrid, so the graph
                        -- itself contained edges through buildings and fences -
                        -- every tier that walks it inherits them. plan_hier did
                        -- not route badly; it was handed a graph that says the
                        -- fence is not there, and the bot met it with a 1.2yd
                        -- whisker. 3637 tiles of extracted WMO + doodad geometry
                        -- sat unused while the planner guessed from footprints.
                        --
                        -- A PROVEN body link still wins: if we have physically
                        -- walked it, it is a doorway and experience outranks the
                        -- map. Everything else must respect known structure.
                        local nx, ny, nz = WorldMesh.cell_center(nid)
                        if ok and not proven then
                            local NG = RaijinLab and RaijinLab.NavGrid
                            if NG and NG.at and NG.STRUCTURE and nx then
                                local okc, code = pcall(NG.at, nx, ny)
                                if okc and code == NG.STRUCTURE then
                                    ok, why = false, "structure"
                                end
                            end
                        end
                        if ok or proven then
                            local e
                            if proven then e = WorldMesh.EDGE_PROVEN
                            elseif kind == "jump" then e = WorldMesh.EDGE_JUMP
                            else e = WorldMesh.EDGE_OBSERVED end
                            out[#out + 1] = {
                                id = nid, x = nx, y = ny, z = ngz or nz,
                                edge = e, climb = climb, slope = nslope,
                                jump = (kind == "jump") or nil, why = why,
                            }
                            found = true
                            break
                        end
                    end
                end
            end
        end

        -- PARKOUR: nothing adjacent in this direction. At 4yd resolution a real
        -- ledge is always a ramp, so the meaningful jump is clearing a GAP - a
        -- chasm, a broken bridge, the space between two platforms. Scan on along
        -- the same heading up to the jump distance and, if solid ground resumes at
        -- a height a jump can reach, offer it as an explicit JUMP edge.
        if not found and not opts.no_jump and gz then
            local maxc = floor((WorldMesh.JUMP_GAP or 5.0) / WorldMesh.MRES)
            for step = 2, math.max(2, maxc) do
                local blocked_by_wall = false
                -- the ground we would fly over must be absent, not a wall
                for k = 1, step - 1 do
                    for _, ob in ipairs({ 0, 1, -1 }) do
                        local mid = m.cells[coords_id(cx + dx * k, cy + dy * k, cb + ob)]
                        if mid and fget(mid, "state") == WorldMesh.BLOCKED then
                            blocked_by_wall = true
                        end
                    end
                end
                if blocked_by_wall then break end
                local landed = false
                for _, ob in ipairs({ 0, 1, -1 }) do
                    local nid = coords_id(cx + dx * step, cy + dy * step, cb + ob)
                    local nw = m.cells[nid]
                    if nw and open_state(fget(nw, "state"))
                        and fget(nw, "stuck") < WorldMesh._blacklist_n then
                        local ngz = WorldMesh.ground_z(nid, nw)
                        local climb = (ngz and gz) and (ngz - gz) or 0
                        -- A jump gains little height but can drop a long way.
                        if climb <= WorldMesh.JUMP_UP and climb >= -WorldMesh.SAFE_DROP then
                            local nx, ny, nz = WorldMesh.cell_center(nid)
                            out[#out + 1] = {
                                id = nid, x = nx, y = ny, z = ngz or nz,
                                edge = WorldMesh.EDGE_JUMP, climb = climb,
                                jump = true, gap = step * WorldMesh.MRES, why = "gap",
                            }
                            landed = true
                            break
                        end
                    end
                end
                if landed then break end
            end
        end
    end
    return out
end

-- Raw (biased) cell coords <-> id, exposed so the hierarchical planner can address
-- blocks without duplicating the packing scheme.
WorldMesh.cell_coords, WorldMesh.coords_id = cell_coords, coords_id

-- Live cell table for the derived hierarchical pyramid. `_gen` bumps whenever the
-- map changes in a way that could alter a block summary (a new cell, or a cell
-- crossing into/out of open), so the pyramid can cheaply tell "still valid" from
-- "rebuild me" and can never silently drift out of sync with the mesh.
WorldMesh._gen = 0
function WorldMesh._cells_for_planner() return bucket().cells end
function WorldMesh.touch() WorldMesh._gen = (WorldMesh._gen or 0) + 1 end

-- Nearest WALKABLE cell to (x,y,z) within `radius` yd (spiral search) - the mesh
-- entry point for planning start/goal. Returns id,x,y,z or nil.
function WorldMesh.nearest_known(x, y, z, radius)
    local m = bucket()
    radius = radius or 24
    local r = WorldMesh.MRES
    local rings = math.floor(radius / r)
    for ring = 0, rings do
        for ox = -ring, ring do
            for oy = -ring, ring do
                if math.max(math.abs(ox), math.abs(oy)) == ring then   -- ring shell only
                    local cx, cy = x + ox * r, y + oy * r
                    -- try this z bucket and +/- one (ramps/stairs)
                    for _, oz in ipairs({ 0, WorldMesh.VBUCKET, -WorldMesh.VBUCKET }) do
                        local id = WorldMesh.cell_id(cx, cy, (z or 0) + oz)
                        local w = m.cells[id]
                        if w then
                            local st = fget(w, "state")
                            if (st == WorldMesh.OPEN_TRAVERSED or st == WorldMesh.OPEN_RAYCAST)
                                and fget(w, "stuck") < WorldMesh._blacklist_n then
                                local nx, ny, nz = WorldMesh.cell_center(id)
                                return id, nx, ny, nz
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- true if this cell was mapped confidently THIS session (Surveyor skips it = 0 rays wasted)
function WorldMesh.conf_fresh(x, y, z)
    local m = bucket()
    local w = m.cells[WorldMesh.cell_id(x, y, z)]
    if not w then return false end
    return fget(w, "seen") == session(m) and fget(w, "conf") >= 8
end
function WorldMesh.state(x, y, z) return fget(WorldMesh.get(x, y, z), "state") end
function WorldMesh.heat(x, y, z) return fget(WorldMesh.get(x, y, z), "visits") end

function WorldMesh.is_blacklisted(x, y, z)
    if not x then return false end
    local w = WorldMesh.get(x, y, z)
    return fget(w, "state") == WorldMesh.BLOCKED or fget(w, "stuck") >= WorldMesh._blacklist_n
end
function WorldMesh.is_walkable(x, y, z)
    local s = WorldMesh.state(x, y, z)
    return s == WorldMesh.OPEN_TRAVERSED or s == WorldMesh.OPEN_RAYCAST
end
-- fraction of this cell's neighbourhood we have any observation for (0..1)
function WorldMesh.observed_frac(x, y, z)
    local m = bucket()
    local seen = 0
    for ox = -1, 1 do for oy = -1, 1 do
        local id = WorldMesh.cell_id(x + ox * WorldMesh.MRES, y + oy * WorldMesh.MRES, z)
        if (m.cells[id] and fget(m.cells[id], "state") ~= WorldMesh.UNKNOWN) then seen = seen + 1 end
    end end
    return seen / 9
end

-- ---- QUALITY cost: multiplicative terrain factor (>= 1, admissible) ----
WorldMesh.W = { F_FLOOR = 1.00, W_BASE = 1.35, V_TRUST = 4, W_UNK = 0.80,
                W_CLIFF = 2.50, W_WATER = 4.00, W_STUCK = 0.60,
                -- steep-but-walkable ground is slower and far easier to snag on, so
                -- a route prefers the gentle side of a hill even if it is longer
                W_SLOPE = 1.60 }
function WorldMesh.cost_factor(x, y, z)
    if not x then return WorldMesh.W.W_BASE end
    local W = WorldMesh.W
    local w = WorldMesh.get(x, y, z)
    local st = fget(w, "state")
    if st == WorldMesh.BLOCKED or fget(w, "stuck") >= WorldMesh._blacklist_n then return 1e6 end
    local visits = fget(w, "visits")
    local hz = fget(w, "hazard")
    local f = W.W_BASE
    -- travel reward: proven, heavily-used ground sinks the factor toward the floor
    f = f - (W.W_BASE - W.F_FLOOR) * math.min(1, visits / W.V_TRUST)
    -- uncertainty: unexplored ground costs more (finite -> still pioneers)
    f = f + W.W_UNK * (1 - WorldMesh.observed_frac(x, y, z))
    -- hazards
    if hz % 2 >= HZ_CLIFF then f = f + W.W_CLIFF end
    if hz % 4 >= HZ_WATER then f = f + W.W_WATER end
    f = f + W.W_STUCK * fget(w, "stuck")
    -- Steepness: free up to the comfortable running angle, then ramping to a full
    -- penalty at the slide limit. This is what makes the planner pick the shallow
    -- approach up a hill instead of the face of it.
    local sb = bucket().slopes[WorldMesh.cell_id(x, y, z)]
    if sb and sb > 0 then
        local deg = bucket_slope(sb) or 0
        if deg > WorldMesh.RUN_SLOPE then
            local t = (deg - WorldMesh.RUN_SLOPE) / math.max(1e-3, WorldMesh.MAX_SLOPE - WorldMesh.RUN_SLOPE)
            if t > 1 then t = 1 end
            f = f + W.W_SLOPE * t
        end
    end
    if f < W.F_FLOOR then f = W.F_FLOOR end
    return f
end

-- LEGACY additive penalty (deprecated; kept so the current Pathfinder + tests pass
-- until the multiplicative step_cost lands in Phase 2b).
function WorldMesh.penalty(x, y, z)
    if not x then return 0 end
    local w = WorldMesh.get(x, y, z)
    local n = fget(w, "stuck")
    if fget(w, "state") == WorldMesh.BLOCKED or n >= WorldMesh._blacklist_n then return 1e6 end
    return 15 * n
end

-- coarse ground-Z hint from the stored cell (nil if never observed)
function WorldMesh.ground_hint(x, y, z)
    local m = bucket()
    local id = WorldMesh.cell_id(x, y, z)
    local w = m.cells[id]
    if not w or fget(w, "state") == WorldMesh.UNKNOWN then return nil end
    local _, _, cz = WorldMesh.cell_center(id)
    return cz + (fget(w, "dz") - 64) * 0.25
end

function WorldMesh.stats()
    local m = bucket()
    local cells, traversed, seen, haz = 0, 0, 0, 0
    for _, w in pairs(m.cells) do
        cells = cells + 1
        local s = fget(w, "state")
        if s == WorldMesh.OPEN_TRAVERSED then traversed = traversed + 1
        elseif s == WorldMesh.OPEN_RAYCAST then seen = seen + 1 end
        if fget(w, "hazard") > 0 then haz = haz + 1 end
    end
    return { map = WorldMesh.map_key(), cells = cells, traversed = traversed,
             seen = seen, hazard = haz, session = session(m),
             -- legacy keys some callers read
             stuck = haz, ramps = traversed }
end

if RaijinLab then RaijinLab.WorldMesh = WorldMesh end
return WorldMesh
