-- POI - persistent point-of-interest memory.
--
-- The object manager only knows what is in RENDER RANGE right now. That is why
-- the quester could never travel to an objective it wasn't already standing next
-- to: the moment a quest giver or a kill target went out of range it ceased to
-- exist, and 3.3.5 exposes no coordinate database to look it up in.
--
-- So we build one from experience. Everything the client ever shows us - quest
-- givers, turn-in NPCs, quest objectives, vendors, repair, trainers, flight
-- masters, mailboxes - is remembered with its world position, per continent, in
-- SavedVariables. "Go to the nearest repair NPC" or "return to that quest
-- objective" then becomes a lookup plus a long-range path, instead of a shrug.
--
-- Storage is a flat per-map list of compact records (short keys - this is
-- serialized to disk every logout). Sightings de-duplicate onto a spatial grid so
-- re-seeing the same NPC updates one record instead of growing the file forever,
-- and the store is capped with least-recently-seen eviction.

local POI = {}

local floor, sqrt = math.floor, math.sqrt

POI.KINDS = {
    giver = true, turnin = true, objective = true, vendor = true, repair = true,
    trainer = true, flightmaster = true, mailbox = true, innkeeper = true,
    banker = true, herb = true, ore = true, corpse_spot = true,
    -- where a named creature actually spawns, so grinding can patrol real camps
    -- instead of wandering; and world things a quest may need us to interact with
    spawn = true, interact = true, transit = true, spirit_healer = true,
}

POI.GRID = 10.0        -- yd: sightings within one grid cell are the same thing
POI._cap = 2000        -- records per map before least-recently-seen eviction
POI._test_map = nil

local function now() return (GetTime and GetTime()) or 0 end
-- Persisted timestamps use WALL CLOCK. GetTime() is uptime, so after a relog a
-- record written last week carries a larger value than one written a minute ago
-- and least-recently-seen eviction throws away exactly the wrong records.
local function stamp() return (time and time()) or ((GetTime and GetTime()) or 0) end

local function root()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.poi = RaijinLabDB.poi or { version = 1 }
    return RaijinLabDB.poi
end

function POI.map_key()
    if POI._test_map then return POI._test_map end
    local WM = RaijinLab and RaijinLab.WorldMesh
    if WM and WM.map_key then return WM.map_key() end
    local c = GetCurrentMapContinent and GetCurrentMapContinent()
    if type(c) == "number" and c >= 0 then return "c" .. c end
    return (GetRealZoneText and GetRealZoneText()) or "world"
end

local function bucket()
    local r = root()
    local k = POI.map_key()
    local m = r[k]
    if not m then m = { list = {} }; r[k] = m end
    m.list = m.list or {}
    return m
end

-- Spatial+identity key: the same entry id, for the same quest, in the same 10yd
-- cell is one place - not a new one every time we walk past it.
local function rec_key(kind, entry, quest, x, y)
    return table.concat({
        kind or "?", tostring(entry or 0), tostring(quest or 0),
        floor((x or 0) / POI.GRID), floor((y or 0) / POI.GRID),
    }, "|")
end

-- LANDMARKS are irreplaceable: a vendor or flight master is discovered once, by
-- walking to it, and the errand goals cannot function without it. Everything else
-- (a mob spawn, an objective sighting) is re-learned for free just by being in the
-- area again. Patrol records a spawn for every visible NPC about once a second,
-- so a purely time-ordered eviction quietly deletes the town vendor to make room
-- for the boar you walked past - which is exactly backwards.
local LANDMARK = {
    vendor = true, repair = true, trainer = true, flightmaster = true,
    mailbox = true, innkeeper = true, banker = true, turnin = true, giver = true,
    transit = true,
}
POI.LANDMARK = LANDMARK
POI._spawn_cap = 600      -- spawns get their own budget, enforced first

local function evict_if_full(m)
    local n = #m.list
    -- Enforce the spawn sub-cap independently, so a busy area cannot crowd out
    -- everything else before the global cap is even reached.
    local spawns = 0
    for i = 1, n do if m.list[i].k == "spawn" then spawns = spawns + 1 end end
    if spawns > POI._spawn_cap then
        local drop = spawns - floor(POI._spawn_cap * 0.9)
        -- oldest spawns first
        local idxs = {}
        for i = 1, n do if m.list[i].k == "spawn" then idxs[#idxs + 1] = i end end
        table.sort(idxs, function(a, b) return (m.list[a].t or 0) < (m.list[b].t or 0) end)
        local kill = {}
        for i = 1, math.min(drop, #idxs) do kill[idxs[i]] = true end
        local out = {}
        for i = 1, n do if not kill[i] then out[#out + 1] = m.list[i] end end
        m.list = out
        m.index = nil
        n = #m.list
    end
    if n <= POI._cap then return end
    -- Global cap: landmarks sort last (survive), then most-recently-seen first.
    table.sort(m.list, function(a, b)
        local la, lb = LANDMARK[a.k] and 1 or 0, LANDMARK[b.k] and 1 or 0
        if la ~= lb then return la > lb end
        return (a.t or 0) > (b.t or 0)
    end)
    local keep = floor(POI._cap * 0.9)
    for i = #m.list, keep + 1, -1 do m.list[i] = nil end
    m.index = nil
end

local function index_of(m)
    if m.index then return m.index end
    local idx = {}
    for i = 1, #m.list do
        local r = m.list[i]
        idx[rec_key(r.k, r.e, r.q, r.x, r.y)] = i
    end
    m.index = idx
    return idx
end

-- Record (or refresh) a sighting.
--   kind  - one of POI.KINDS
--   opts  - { x, y, z, name, entry (npc/object entry id), quest (quest id), guid }
-- Returns the stored record.
function POI.record(kind, opts)
    opts = opts or {}
    if not POI.KINDS[kind] then return nil, "bad_kind" end
    local x, y, z = tonumber(opts.x), tonumber(opts.y), tonumber(opts.z)
    if not (x and y) then return nil, "no_pos" end
    local m = bucket()
    local key = rec_key(kind, opts.entry, opts.quest, x, y)
    local idx = index_of(m)
    local i = idx[key]
    if i and m.list[i] then
        local r = m.list[i]
        -- Smooth the remembered position toward the newest sighting so a patrolling
        -- NPC settles on its actual beat instead of jittering between records.
        r.x = r.x + (x - r.x) * 0.25
        r.y = r.y + (y - r.y) * 0.25
        r.z = z or r.z
        r.t = stamp()
        r.c = (r.c or 1) + 1
        if opts.name and opts.name ~= "" then r.n = opts.name end
        return r
    end
    local r = {
        k = kind, n = opts.name, e = tonumber(opts.entry) or 0,
        q = tonumber(opts.quest) or 0,
        x = x, y = y, z = z or 0, t = stamp(), c = 1,
    }
    m.list[#m.list + 1] = r
    idx[key] = #m.list
    evict_if_full(m)
    return r
end

-- Nearest remembered POI of `kind`. opts: { max_dist, quest, entry, name,
-- min_seen (only well-established places), exclude = {rec=true} }.
function POI.nearest(kind, x, y, z, opts)
    opts = opts or {}
    local m = bucket()
    -- The store keys quest ids as NUMBERS with 0 = "id unknown" (record() does
    -- tonumber(opts.quest) or 0). The filter must compare on the same
    -- normalization or the join silently never matches: a string "123" from a
    -- caller fails against a stored 123 forever, and a stubbed 0 (0 is truthy
    -- in Lua) would "filter" down to only the records whose id was never
    -- learned. An unknown filter key cannot discriminate, so it must mean
    -- "no filter", not "match other unknowns".
    local wantq = tonumber(opts.quest)
    if wantq == 0 then wantq = nil end
    local best, bestd = nil, math.huge
    for i = 1, #m.list do
        local r = m.list[i]
        if (kind == nil or r.k == kind)
            and (not wantq or r.q == wantq)
            and (not opts.entry or r.e == opts.entry)
            and (not opts.name or r.n == opts.name)
            and (not opts.min_seen or (r.c or 1) >= opts.min_seen)
            and not (opts.exclude and opts.exclude[r]) then
            local dx, dy = (x or 0) - r.x, (y or 0) - r.y
            local dz = (z or 0) - (r.z or 0)
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d < bestd and (not opts.max_dist or d <= opts.max_dist) then
                best, bestd = r, d
            end
        end
    end
    if best then return best, bestd end
    return nil
end

-- All remembered locations tied to a quest (its objectives / its giver).
function POI.for_quest(questId, kind)
    local m = bucket()
    local out = {}
    questId = tonumber(questId) or 0
    for i = 1, #m.list do
        local r = m.list[i]
        if r.q == questId and (kind == nil or r.k == kind) then out[#out + 1] = r end
    end
    return out
end

function POI.list(kind)
    local m = bucket()
    if not kind then return m.list end
    local out = {}
    for i = 1, #m.list do
        if m.list[i].k == kind then out[#out + 1] = m.list[i] end
    end
    return out
end

-- Stable identity for a record that does NOT depend on the Lua table itself.
-- Anything persisted can be replaced by a fresh table (a DB sanitize pass, a
-- reload), so callers that remember records must key on this, not on the table.
function POI.key_of(rec)
    if type(rec) ~= "table" then return nil end
    return rec_key(rec.k, rec.e, rec.q, rec.x, rec.y)
end

-- Forget a place we could not actually use (despawned, unreachable). Keeps the
-- memory honest instead of routing to a ghost forever. Matches by identity first,
-- then by stable key, so it still works on a record that was re-created.
function POI.forget(rec)
    local m = bucket()
    local want = POI.key_of(rec)
    for i = 1, #m.list do
        local r = m.list[i]
        if r == rec or (want and POI.key_of(r) == want) then
            table.remove(m.list, i)
            m.index = nil
            return true
        end
    end
    return false
end

function POI.stats()
    local m = bucket()
    local by = {}
    for i = 1, #m.list do
        local k = m.list[i].k
        by[k] = (by[k] or 0) + 1
    end
    return { map = POI.map_key(), total = #m.list, by_kind = by }
end

if RaijinLab then RaijinLab.POI = POI end
return POI
