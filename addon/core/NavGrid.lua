-- NavGrid - the client's own terrain, as ground truth.
--
-- Everything the bot knows about the world it currently learns by raycasting what
-- it can see, so it cannot reason past render range and has to rediscover the
-- same hillside on every character. The client already holds the exact answer:
-- `tools/build_navgrid.py` reads it out of the MPQ archives offline and writes a
-- tile per ADT (~2.4KB of text; a whole continent is a couple of megabytes).
--
-- This loads those tiles on demand and answers two questions:
--     can I stand here?      what height is the ground?
--
-- THE ANSWER IS THREE-VALUED, DELIBERATELY. A tile that has not been generated,
-- or a coordinate outside any tile, is UNKNOWN - never "not walkable". Collapsing
-- that to false would make every unexported zone look like a wall, which is the
-- exact failure this project keeps hitting: an absence read as an answer. Callers
-- decide what to do with ignorance; the usual choice is to fall back to live
-- raycasts, which is what the bot did before this existed.

local NG = {}

NG.UNKNOWN, NG.WALK, NG.STEEP, NG.BLOCKED, NG.WATER, NG.STRUCTURE = 0, 1, 2, 3, 4, 5

-- TIGHT: real floor, within one body-radius of solid geometry.
--
-- A cell whose CENTRE is clear is not somewhere a body can stand - it has width.
-- The generator erodes walkable ground by the character's collision radius and
-- marks the band TIGHT, which is what stops a route scraping every doorway edge,
-- fence post and crate corner. It is NOT deleted, because it is genuinely floor;
-- it simply cannot be occupied, so the planner must refuse it.
NG.TIGHT = 6

-- Routing multiplier for a building footprint. Not a wall: the extracted box is
-- axis-aligned and includes doorways and courtyards, so a hard block would make
-- every inn unreachable. High enough that a route only crosses a building when
-- there is genuinely no way around it.
-- Was 12, then 40: still saw Deathknell church cut-throughs when the alternate
-- walk was only modestly longer. 90 makes "around the building" win almost
-- always while still allowing a true indoor entry when no exterior route exists.
NG.STRUCTURE_COST = 90.0

NG.TILE = 533.33333
NG.ORIGIN = 32.0 * NG.TILE
-- Tiles held in memory. A 4yd tile is ~18k cells across two arrays, so this is
-- the memory knob: 6 tiles covers a 3x3-tile neighbourhood at 533yd each, far
-- beyond render range, while keeping the resident set a few MB rather than ten.
NG.MAX_CACHED = 6

NG._cache = {}              -- "map:tx:ty" -> tile
NG._lru = {}
NG._misses = {}             -- tiles we already know are absent: do not retry the IO

local function K() return RaijinLab and RaijinLab.Know end

-- ---- coordinates ----------------------------------------------------------
-- A tile's X index runs along world -Y and its Y index along world -X. Reversing
-- this yields a mirrored world that still looks plausible, so it is asserted by
-- the generator against the client's own embedded chunk positions.

function NG.tile_of(x, y)
    local ty = math.floor((NG.ORIGIN - x) / NG.TILE)
    local tx = math.floor((NG.ORIGIN - y) / NG.TILE)
    return tx, ty
end

-- ---- loading --------------------------------------------------------------

-- WHERE THE TILES LIVE, IN THE ONLY FORM ReadFile ACCEPTS.
--
-- The runtime's ReadFile resolves RELATIVE TO THE CLIENT ROOT and wants forward
-- slashes. This returned an ABSOLUTE path built from GetWoWDirectory, with
-- backslashes - both of which it rejects SILENTLY, returning nil rather than
-- erroring. So every tile lookup missed, NavGrid.at() was nil everywhere, and
-- the 3,637 premapped tiles on disk were dead weight: the bot planned from
-- runtime raycasts alone and could not find a door out of a building it was
-- standing in.
--
-- Verified live: ReadFile("Logs/navgrid/Azeroth_29_28.lua") -> 57364 bytes;
-- the same path absolute, or with backslashes, -> nil.
NG.DIR = "Logs/navgrid"

function NG.dir()
    return NG.DIR
end

-- The absolute location, for tools and for anything shown to a human.
function NG.abs_dir()
    local d = RaijinLab and RaijinLab.GetWoWDirectory and RaijinLab:GetWoWDirectory()
    if not d or d == "" then return nil end
    return d .. "\\Logs\\navgrid"
end

-- Expand "<letter><count>" runs into a flat code array, and the parallel
-- per-run quantised heights into a flat height array.
-- Base-32 digit -> value, by arithmetic rather than a lookup table: the
-- alphabet is "0123456789ABCDEFGHIJKLMNOPQRSTUV", so bytes 48..57 are 0..9 and
-- 65..86 are 10..31. Two compares beat a table index on the hot path.
function NG._parse_layers(lay)
    if type(lay) ~= "string" or lay == "" then return nil end
    local layers = {}
    for cell, qz in lay:gmatch("(%d+):(-?%d+)") do
        local ci = tonumber(cell)
        local zz = tonumber(qz) / 4.0
        local l = layers[ci]
        if l then l[#l + 1] = zz else layers[ci] = { zz } end
    end
    return layers
end

local function b32(byte)
    if byte <= 57 then return byte - 48 end
    return byte - 55
end
NG._b32 = b32

function NG.decode(t)
    if type(t) ~= "table" then return nil end

    -- THE INDEXED FORMAT: NOTHING TO DECODE.
    --
    -- `cd` is one letter per cell and `zq` two base-32 digits per cell, both
    -- fixed-width, so cell i is a byte offset and the whole "decode" is two
    -- length checks. The previous format made the client rebuild the tile at
    -- load: 338ms of the 400ms went on re-deriving 1,138,489 per-cell heights
    -- from deltas, which is what put the game under 1 fps. That work now happens
    -- once, offline, in the generator.
    if type(t.cd) == "string" then
        local want = (t.n or 0) * (t.n or 0)
        if want <= 0 or #t.cd ~= want then return nil, "size_mismatch" end
        if type(t.zq) ~= "string" or #t.zq ~= want * 2 then
            return nil, "height_count_mismatch"
        end
        if type(t.zmin) ~= "number" or type(t.zstep) ~= "number" then
            return nil, "height_scale_missing"
        end
        t.codes = t.cd
        -- Upper floors stay a STRING and are binary-searched on demand. Building
        -- a table here cost ~29ms on a church tile once nothing else needed a
        -- pass - the last per-load loop, for data most queries never touch.
        if type(t.lay) == "string" and #t.lay >= 7 and (#t.lay % 7) == 0 then
            t.lrec = t.lay
            t.lnum = #t.lay / 7
        else
            t.layers = NG._parse_layers(t.lay)
        end
        return t
    end

    if type(t.runs) ~= "string" then return nil end
    -- DECODING IS THE FRAME KILLER, SO IT IS BUDGETED.
    --
    -- At 0.5yd a tile is 1,138,489 cells and a full decode measures ~400ms. Doing
    -- that inline froze the client for four tenths of a second EVERY TIME the bot
    -- crossed a tile boundary - and the pathfinder samples across boundaries
    -- constantly, so the game sat below 1 fps. At 4yd the same code was 17,956
    -- cells and nobody noticed.
    --
    -- The work is unavoidable but it does not have to happen in one frame. It is
    -- handed to the frame-budget Scheduler in chunks; until it finishes the tile
    -- reports UNKNOWN, which every caller already handles (it is what an
    -- unexported zone looks like). A slightly late map beats a frozen client.

    -- STORE CELLS AS STRINGS, NOT LUA ARRAYS.
    --
    -- A 1yd tile is 534x534 = 285,156 cells. As a Lua array that is ~25 MB PER
    -- TILE (measured live: 6 resident tiles took Lua from 165 MB to 290 MB) - and
    -- this client is 32-bit and already died once at 140 MB of Lua. The same
    -- cells as a string are ~285 KB, indexed in O(1) with string.byte, which is
    -- how this format can be 1yd at all.
    --
    -- Built in chunks because concatenating per cell is quadratic: table.concat
    -- of a few thousand pieces keeps it linear.
    local parts, np = {}, 0
    local i = 1
    -- WoW 3.3.5 is Lua 5.1, which HAS NO coroutine.isyieldable (5.2+). Testing
    -- for it yielded nil, so `budgeted` was always false and this loop never gave
    -- the frame back - the 400ms decode simply moved inside the Scheduler job and
    -- stalled exactly as hard. coroutine.running() is the 5.1 way: nil on the
    -- main thread, the coroutine otherwise.
    local S = RaijinLab and RaijinLab.Scheduler
    local budgeted = (S and S.over_budget and coroutine.running() ~= nil) and true or false
    local since = 0
    for letter, count in t.runs:gmatch("(%a)(%d+)") do
        local n2 = tonumber(count)
        np = np + 1
        parts[np] = string.rep(letter, n2)
        i = i + n2
        -- Yield to the frame when this job is running under the Scheduler. Checked
        -- every 4096 runs so the check itself is not the cost.
        since = since + 1
        if budgeted and since >= 4096 then
            since = 0
            if S.over_budget() then coroutine.yield() end
        end
    end
    local codes = table.concat(parts)
    -- PER-CELL heights, delta encoded. The previous format stored one average per
    -- RUN, which measured 20% of points within 3yd against the client's own
    -- raycasts: a run spans row-major cells and can cross an entire hillside, so
    -- its average is wrong by the relief across it.
    -- Heights the same way: two bytes per cell, quarter-yards, biased so the
    -- value is always positive. 285k Lua numbers is another ~12 MB; this is 570 KB.
    local hp, nh = {}, 0
    local j, acc = 1, 0
    for d in tostring(t.zd or ""):gmatch("(-?%d+)") do
        acc = acc + tonumber(d)
        local q = acc + NG.H_BIAS            -- quarter-yards, biased positive
        if q < 0 then q = 0 elseif q > 65535 then q = 65535 end
        nh = nh + 1
        hp[nh] = string.char(math.floor(q / 256), q % 256)
        j = j + 1
    end
    local heights = table.concat(hp)
    if t.zd and (j - 1) ~= (i - 1) then
        return nil, "height_count_mismatch"
    end
    -- UPPER FLOORS: "cell:quarterYards ..." for every standable surface ABOVE
    -- the base layer. Sparse on purpose - only multi-storey cells appear - so a
    -- single-storey tile costs nothing and a church costs a few thousand entries.
    t.layers = NG._parse_layers(t.lay)

    local want = (t.n or 0) * (t.n or 0)
    if want > 0 and (i - 1) ~= want then
        -- A truncated or malformed tile must be REFUSED, not half-used: a grid
        -- that is wrong about where the ground is, is worse than no grid.
        return nil, "size_mismatch"
    end
    t.codes, t.heights = codes, heights
    return t
end

local function touch(key)
    for i = 1, #NG._lru do
        if NG._lru[i] == key then table.remove(NG._lru, i); break end
    end
    NG._lru[#NG._lru + 1] = key
    while #NG._lru > NG.MAX_CACHED do
        local drop = table.remove(NG._lru, 1)
        NG._cache[drop] = nil
    end
end

-- PARSE A RAW TILE. No loadstring, no chunk, no environment.
--
-- The Lua tile form costs ~11ms per load purely because loadstring must scan
-- 3.3MB of source - the payload is two enormous string literals and the parser
-- reads every byte. A walkability grid has no reason to be executable.
--
-- The raw form is a header line of small numbers followed by `key:payload`
-- lines, so loading is a few string.find/string.sub calls: microseconds, and a
-- data file can no longer BE code, which is strictly safer than the empty
-- environment the Lua loader needed.
function NG.parse_raw(text)
    if type(text) ~= "string" or text:sub(1, 6) ~= "RLNAV2" then return nil end
    local NLC = string.char(10)
    local nl = text:find(NLC, 1, true)
    if not nl then return nil end
    local t = {}
    for k, v in text:sub(1, nl - 1):gmatch("(%w+)=([^%s]+)") do
        t[k] = tonumber(v) or v
    end
    if type(t.n) ~= "number" or t.n <= 0 then return nil end
    if type(t.cdlen) ~= "number" or type(t.zqlen) ~= "number" then return nil end

    -- Computed offsets, not searches. Each block starts where the previous one
    -- ended plus its newline, and its length is in the header - so this is three
    -- slices of known extent and nothing scans the payload.
    -- OFFSETS ARE ANCHORED TO THE ACTUAL NEWLINES, NOT COMPUTED BLIND.
    --
    -- Pure arithmetic put the `lay` slice ONE BYTE EARLY, so every 7-char record
    -- was shifted: the first cell decoded to -37,945,344 (a newline read as a
    -- base-32 digit gives 10-48), the last to 9,438,295 against a maximum of
    -- 1,138,489, and 9,828 of 31,220 records came out non-monotonic - which
    -- silently broke the binary search, so `_ups` returned nil for cells whose
    -- floors were sitting right there in the file. The mesh looked single-storey
    -- and the bot walked into walls indoors.
    --
    -- Each block ends at a newline. Finding it costs one search from a known
    -- position and cannot drift; the declared lengths are then a CHECK rather
    -- than the source of truth.
    -- CRLF. The tiles were written through Python's text mode on Windows, so
    -- every separator is a carriage return plus a newline, not a bare
    -- newline. Searching for the newline lands one byte PAST the carriage
    -- return, so every block came out one byte long and the 7-char layer
    -- -37,945,344 (a control byte read as a base-32 digit), 9,828 of 31,220
    -- records were non-monotonic, the binary search failed, and `_ups` returned
    -- nil for cells whose floors were sitting in the file. The mesh looked
    -- single-storey everywhere and the bot walked into walls indoors.
    --
    -- Trim the stray return here rather than trusting either the arithmetic or
    -- the writer's line-ending policy - this reads both LF and CRLF tiles.
    local function trim(str)
        if str:sub(-1) == string.char(13) then return str:sub(1, -2) end
        return str
    end
    local p1 = nl + 1
    local e1 = text:find(NLC, p1 + t.cdlen, true) or (p1 + t.cdlen + 1)
    t.cd = trim(text:sub(p1, e1 - 1))
    local p2 = e1 + 1
    local e2 = text:find(NLC, p2 + t.zqlen, true) or (p2 + t.zqlen + 1)
    t.zq = trim(text:sub(p2, e2 - 1))
    local laylen = tonumber(t.laylen) or 0
    if laylen > 0 then
        local p3 = e2 + 1
        local e3 = text:find(NLC, p3 + laylen, true) or (#text + 1)
        t.lay = trim(text:sub(p3, e3 - 1))
    else
        t.lay = nil
    end
    -- The declared lengths must match what was actually sliced, or the file is
    -- not what its header claims and nothing below can be trusted.
    if #t.cd ~= t.cdlen or #t.zq ~= t.zqlen then return nil end
    if t.lay and #t.lay ~= laylen then return nil end
    return t
end

function NG.load(map, tx, ty)
    local key = tostring(map) .. ":" .. tx .. ":" .. ty
    local hit = NG._cache[key]
    if hit then touch(key); return hit end
    if NG._misses[key] then return nil end

    local dir = NG.dir()
    local R = RaijinLab
    if not (dir and R and R.ReadFile) then NG._misses[key] = true; return nil end
    local stem = dir .. "/" .. tostring(map) .. "_" .. tx .. "_" .. ty
    -- Prefer the raw tile; fall back to the Lua one so a half-regenerated tree
    -- keeps working during a rollout.
    -- Prefer the raw tile, but the FALLBACK IS DECIDED BY PARSING, not by
    -- whether the read returned bytes. Treating any non-empty answer as raw
    -- meant a missing/corrupt .dat - or a ReadFile that answers every path -
    -- returned nil instead of falling back to the .lua tile beside it.
    local ok, text = pcall(R.ReadFile, R, stem .. ".dat")
    if ok and type(text) == "string" and text ~= "" then
        local t = NG.parse_raw(text)
        if t then
            local decoded = NG.decode(t)
            if decoded then
                NG._cache[key] = decoded
                touch(key)
                return decoded
            end
        end
    end
    ok, text = pcall(R.ReadFile, R, stem .. ".lua")
    if not ok or type(text) ~= "string" or text == "" then
        NG._misses[key] = true
        return nil
    end
    -- Run in an EMPTY environment: a data file must never be able to execute
    -- anything against the addon, however it got onto disk.
    local env = {}
    local chunk
    if loadstring then
        chunk = loadstring(text)
        if chunk and setfenv then setfenv(chunk, env) end
    elseif load then
        chunk = load(text, "navgrid", "t", env)   -- "t": text only, never bytecode
    end
    if not chunk then NG._misses[key] = true; return nil end
    local ran, t = pcall(chunk)
    if not ran or type(t) ~= "table" then NG._misses[key] = true; return nil end

    -- NEVER DECODE ON THE FRAME. ~400ms of work at 0.5yd resolution, and NG.at
    -- is called from ordinary frame code as well as from the pathfinder's
    -- coroutine - so doing it inline dropped the client under 1 fps whenever the
    -- bot crossed a tile boundary. Hand it to the frame-budget Scheduler and
    -- report UNKNOWN until it lands, which is a state every caller already
    -- handles. Being briefly without the map is not a defect; freezing is.
    local S = RaijinLab and RaijinLab.Scheduler
    if S and S.run and coroutine.running() == nil then
        if not NG._loading then NG._loading = {} end
        if NG._loading[key] then return nil end       -- already on its way
        NG._loading[key] = true
        S.run(function()
            local decoded = NG.decode(t)
            NG._loading[key] = nil
            if decoded then
                NG._cache[key] = decoded
                touch(key)
            else
                NG._misses[key] = true
            end
        -- Scheduler.run takes a NUMERIC priority (1..3); a string here made
        -- `prio < 1` compare a string with a number, which throws in Lua 5.1 -
        -- on every single tile load. Map data is background work: LOW.
        end, (S.PRIO and S.PRIO.LOW) or 3)
        return nil
    end

    local decoded = NG.decode(t)
    if not decoded then NG._misses[key] = true; return nil end
    NG._cache[key] = decoded
    touch(key)
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel then Tel.info("navgrid", "loaded",
        { map = map, tx = tx, ty = ty, walk = t.walk, steep = t.steep }) end
    return decoded
end

-- ---- queries --------------------------------------------------------------

-- The ADT map NAME, which is what tiles are filed under - and which is NOT what
-- the rest of the addon uses. WorldMesh.map_key() returns "c2" or "z<Zone>",
-- deliberately, because it only needs a stable bucket. Tiles are named for the
-- client's own map directory ("Azeroth", "Kalimdor", ...), so plugging one into
-- the other looks up files that cannot exist and the whole pipeline is silently
-- inert - built, deployed, and doing nothing.
--
-- LOADING THE WRONG MAP WOULD BE FAR WORSE THAN LOADING NONE: it would confidently
-- report walls and cliffs that are not there. So an unresolved map returns nil,
-- which makes every query unknown, which makes the bot fall back to live sensing.
NG.CONTINENT_MAP = {
    [1] = "Kalimdor",
    [2] = "Azeroth",          -- Eastern Kingdoms
    [3] = "Expansion01",      -- Outland
    [4] = "Northrend",
}

-- RESOLVING THE MAP IS MEMOIZED, AND NO QUERY EVER TOUCHES THE WORLD MAP.
-- NG.at and NG.height resolve the map on every call, and resolving used to mean
-- SetMapToCurrentZone + GetCurrentMapContinent: two FrameXML calls, the first of
-- which re-points the player's world map and fires WORLD_MAP_UPDATE. One plan asks
-- thousands of times, so the pathfinder was paying for a global UI mutation per
-- cell - a measured cause of the reported stutter, and a way for a background
-- search to yank the map out from under a player who was reading it.
NG._map = nil            -- memoized ADT map name; nil is a legitimate answer
NG._map_key = nil        -- what it was resolved FROM: override string or continent
NG._map_ready = false    -- "memo is filled", which nil alone cannot express
NG._map_distrust = nil   -- a continent read already rejected: do not re-check it
NG._syncing = false      -- true only inside NG.sync_map, see there

-- Drop the memo. Costs nothing and touches no UI, so the event layer can call it
-- from ZONE_CHANGED_NEW_AREA / PLAYER_ENTERING_WORLD freely.
function NG.invalidate_map()
    NG._map, NG._map_key, NG._map_ready, NG._map_distrust = nil, nil, false, nil
end

-- Is the world map currently showing the player's OWN zone? GetPlayerMapPosition
-- reports 0,0 for the player when it is not, and asking costs nothing and changes
-- nothing. Returns nil for "cannot tell". Without this, dropping the forced
-- SetMapToCurrentZone would let a player who browsed the map to another continent
-- make us load THAT continent's tiles, which is the exact failure this file is
-- built around: a wrong map reports walls and cliffs that are not there.
local function map_shows_player()
    if type(GetPlayerMapPosition) ~= "function" then return nil end
    local ok, mx, my = pcall(GetPlayerMapPosition, "player")
    if not ok or type(mx) ~= "number" or type(my) ~= "number" then return nil end
    return not (mx == 0 and my == 0)
end

-- The ONE place allowed to re-point the world map, so the memo can be rebuilt from
-- a map that is guaranteed to be showing the player. Called from the zone events
-- below, never from a query.
function NG.sync_map()
    NG.invalidate_map()
    -- Never re-point a map the player is actually reading. Skipping only leaves
    -- the memo empty, and an empty memo answers nil, which means live sensing:
    -- degraded, not wrong.
    local wm = WorldMapFrame
    local synced = false
    if not (wm and type(wm.IsVisible) == "function" and wm:IsVisible()) then
        if SetMapToCurrentZone then synced = pcall(SetMapToCurrentZone) end
    end
    -- SetMapToCurrentZone has just guaranteed the map shows the player, so accept
    -- the read even where GetPlayerMapPosition cannot confirm it. Ascension's
    -- custom maps can report 0,0 for the player permanently, and refusing there
    -- would leave the memo empty forever - the grid built, deployed, and inert.
    NG._syncing = synced
    local name = NG.map_name()
    NG._syncing = false
    return name
end

function NG.map_name()
    -- An explicit override wins: Ascension ships custom maps whose continent
    -- index tells us nothing (shialannd, AzzarArchipelago, NewNerub, ...).
    local cfg = RaijinLabDB and RaijinLabDB.navgrid
    if cfg and type(cfg.map) == "string" and cfg.map ~= "" then
        if NG._map_key ~= cfg.map then
            NG._map, NG._map_key, NG._map_ready = cfg.map, cfg.map, true
            NG._map_distrust = nil
        end
        return NG._map
    end

    local c
    if GetCurrentMapContinent then
        local ok, v = pcall(GetCurrentMapContinent)
        if ok and type(v) == "number" then c = v end
    end
    -- Steady state, and the path the pathfinder takes: the world map still reports
    -- what the memo was built from, so answer from the memo and resolve nothing.
    -- Continent 0 is a real value here, so this compares against nil explicitly
    -- rather than leaning on truthiness.
    if NG._map_ready and c ~= nil then
        if NG._map_key == c or NG._map_distrust == c then return NG._map end
    end

    if c ~= nil then
        -- We are about to change our mind about which continent we are standing
        -- on. That is the expensive mistake, so it is the one moment worth
        -- corroborating - and the rejection is remembered, or a player browsing
        -- the map would put a GetPlayerMapPosition call back in the inner loop.
        if not (NG._syncing or map_shows_player() ~= false) then
            NG._map_distrust = c
            return NG._map_ready and NG._map or nil
        end
        NG._map, NG._map_key, NG._map_ready = NG.CONTINENT_MAP[c], c, true
        NG._map_distrust = nil
        if NG._map then return NG._map end
    end
    return nil                 -- unknown map -> every query unknown -> live sensing
end

-- The memo is refreshed HERE rather than by waiting for some other module to
-- remember: a memo nobody invalidates is a stale map, and a stale map is the
-- confidently-wrong terrain this file exists to prevent. CreateFrame is absent
-- outside the client (the test harness loads this file bare), so it is optional.
if type(CreateFrame) == "function" then
    local ok, f = pcall(CreateFrame, "Frame")
    if ok and type(f) == "table" and f.RegisterEvent and f.SetScript then
        f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:SetScript("OnEvent", function() NG.sync_map() end)
        NG._map_watcher = f
    end
end

-- Returns (code, height) or nil when the covering tile is not available.
function NG.at(x, y, map)
    map = map or NG.map_name()
    if not map then return nil end
    local tx, ty = NG.tile_of(x, y)
    local t = NG.load(map, tx, ty)
    if not t then return nil end
    local gx = math.floor((x - t.x0) / t.res)
    local gy = math.floor((y - t.y0) / t.res)
    if gx < 0 or gy < 0 or gx >= t.n or gy >= t.n then return nil end
    local i = gy * t.n + gx + 1
    local code = string.byte(t.codes, i)
    if not code then return nil end
    code = code - 97
    local h
    if t.zq then
        -- two byte reads and a multiply-add; no per-cell state, no allocation
        local a, b = string.byte(t.zq, i * 2 - 1, i * 2)
        if a then h = t.zmin + (b32(a) * 32 + b32(b)) * t.zstep end
    elseif t.heights and #t.heights >= i * 2 then
        local hi, lo = string.byte(t.heights, i * 2 - 1, i * 2)
        h = ((hi * 256 + lo) - NG.H_BIAS) / 4.0
    end
    return code, h, t.res
end

-- WHICH FLOOR ARE YOU ON?
--
-- The base layer is the LOWEST standable surface in a cell, which for a
-- multi-storey building is its ground floor. A character upstairs asking about
-- its own cell used to be told about the ground plan - so the planner routed it
-- into walls that were not on its floor, and it had, in the user's words, "no
-- idea it's inside a building on the second floor".
--
-- Given a height, pick the surface nearest it. Nothing is guessed: the surfaces
-- are the ones the generator actually found, and if a cell has only one, this
-- returns exactly what it always did.
-- Upper floors for one cell, found by BINARY SEARCH over fixed-width records.
-- Each record is 7 base-32 chars: 5 of cell index, 2 of height on the tile's own
-- zmin/zstep scale. Records are sorted by cell, so this is ~14 probes into a
-- string with no allocation and no load-time work.
function NG._ups(t, i)
    -- A nil tile is "no data", not a crash. Indexing it took down whole test
    -- groups (and would take down a frame) when a caller passed a tile that
    -- failed to decode.
    if type(t) ~= "table" or type(i) ~= "number" then return nil end
    if t.layers then return t.layers[i] end
    local rec, num = t.lrec, t.lnum
    if not (rec and num and num > 0) then return nil end
    local function cell_at(k)                      -- k is 0-based record index
        local o = k * 7 + 1
        local a, b, c, d, e = rec:byte(o, o + 4)
        return ((((b32(a) * 32 + b32(b)) * 32 + b32(c)) * 32 + b32(d)) * 32) + b32(e)
    end
    local lo, hi = 0, num - 1
    local first = nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local cv = cell_at(mid)
        if cv < i then
            lo = mid + 1
        else
            if cv == i then first = mid end
            hi = mid - 1
        end
    end
    if not first then return nil end
    local out = {}
    local k = first
    while k < num and cell_at(k) == i do
        local o = k * 7 + 6
        local h1, h2 = rec:byte(o, o + 1)
        out[#out + 1] = t.zmin + (b32(h1) * 32 + b32(h2)) * t.zstep
        k = k + 1
    end
    return out
end

function NG.at_z(x, y, z, map)
    local code, h, res = NG.at(x, y, map)
    if code == nil then return nil end
    if type(z) ~= "number" then return code, h, res end
    map = map or NG.map_name()
    local tx, ty = NG.tile_of(x, y)
    local t = map and NG.load(map, tx, ty)
    if not t then return code, h, res end
    if not (t.layers or t.lrec) then return code, h, res end
    local gx = math.floor((x - t.x0) / t.res)
    local gy = math.floor((y - t.y0) / t.res)
    local i = gy * t.n + gx + 1
    local ups = NG._ups(t, i)
    if not ups then return code, h, res end
    local best, bestd = h, (h and math.abs(z - h)) or math.huge
    for k = 1, #ups do
        local d = math.abs(z - ups[k])
        if d < bestd then best, bestd = ups[k], d end
    end
    -- THE LAYER CHOOSES THE HEIGHT. IT DOES NOT GRANT PERMISSION.
    --
    -- This used to return WALK whenever an upper floor was selected, on the
    -- reasoning that "a floor you can stand on is walkable". That is wrong at
    -- the cell level: floor records are spread across a building's footprint,
    -- including the cells its WALLS occupy, so every wall inside a building
    -- reported walkable and the mesh had no objection to anything. Measured
    -- live, standing indoors: 0 of 12 directions around the character blocked.
    --
    -- Whether a body can occupy a cell is what `cd` says - wall, tight, steep,
    -- blocked. Which storey it is standing on is what the layers say. Keep them
    -- separate: the height comes from the nearest surface, the verdict never
    -- changes.
    return code, best, res
end

-- Every standable surface in a cell, base first. Callers that must reason about
-- floors (a planner linking storeys) need the set, not just the nearest.
function NG.surfaces(x, y, map)
    local code, h = NG.at(x, y, map)
    if code == nil then return nil end
    local out = { h }
    map = map or NG.map_name()
    local tx, ty = NG.tile_of(x, y)
    local t = map and NG.load(map, tx, ty)
    if t and (t.layers or t.lrec) then
        local gx = math.floor((x - t.x0) / t.res)
        local gy = math.floor((y - t.y0) / t.res)
        local ups = NG._ups(t, gy * t.n + gx + 1)
        for k = 1, #(ups or {}) do out[#out + 1] = ups[k] end
    end
    return out
end

-- FINE ENOUGH TO BE BELIEVED?
--
-- At 4yd sampling a "structure" cell was a building's axis-aligned BOUNDING BOX:
-- it covered the courtyard and the floor as well as the walls, and a doorway
-- (2-4yd) fell between samples entirely - so it could not be treated as a wall
-- without sealing every building shut. At 1yd the same class is rasterised WMO
-- geometry: walls are walls and the gaps in them are real doorways (measured:
-- 1352 wall-adjacent openings on one tile, versus none at 4yd).
--
-- So the answer depends on the data, and each tile carries the resolution it was
-- built at. Fine tiles are authoritative; coarse ones stay a hint.
NG.H_BIAS = 2000       -- quarter-yards added so packed heights stay positive
NG.FINE_RES = 1.5

function NG.fine_at(x, y, map)
    local _, _, res = NG.at(x, y, map)
    return type(res) == "number" and res <= NG.FINE_RES
end

-- THREE-VALUED. unknown means "no data here", which is not the same as "no".
function NG.walkable(x, y, map)
    local Know = K()
    local code = NG.at(x, y, map)
    if code == nil then
        if Know then return Know.unknown("no_tile") end
        return nil
    end
    if code == NG.WALK then
        return Know and Know.yes(true, "navgrid") or true
    end
    if code == NG.STRUCTURE then
        -- On a FINE tile this is rasterised geometry, so it is a wall and we say
        -- so - no raycast needed, and the doorways are walkable cells beside it.
        -- On a COARSE tile it is only a bounding box (floor and courtyard
        -- included), which cannot be called a wall without sealing the building.
        if NG.fine_at(x, y, map) then
            return Know and Know.no("structure") or false
        end
        return Know and Know.unknown("structure") or nil
    end
    if code == NG.TIGHT then
        -- Floor a body does not fit on. A definite no: this is measured
        -- geometry, not a guess, and routing through it is what snags.
        return Know and Know.no("too_tight") or false
    end
    if code == NG.WATER then
        -- WATER IS REACHABLE, JUST EXPENSIVE. You swim it. The generator says so
        -- explicitly ("priced, not forbidden - refusing water turns every river
        -- into a wall") and this half was contradicting it by falling through to
        -- the refusal branch, which would have made a lake a cliff. Cost belongs
        -- to the planner; passability is what this answers.
        return Know and Know.yes(true, "water") or true
    end
    return Know and Know.no(code == NG.STEEP and "too_steep" or "blocked") or false
end

-- Walkability ON A GIVEN FLOOR. Same three-valued contract as NG.walkable, but
-- the cell is resolved against the height you are actually at, so a character
-- upstairs is told about its own floor rather than the ground plan below it.
function NG.walkable_z(x, y, z, map)
    local Know = K()
    local code = NG.at_z(x, y, z, map)
    if code == nil then
        if Know then return Know.unknown("no_tile") end
        return nil
    end
    if code == NG.WALK then return Know and Know.yes(true, "navgrid") or true end
    if code == NG.STRUCTURE then
        if NG.fine_at(x, y, map) then return Know and Know.no("structure") or false end
        return Know and Know.unknown("structure") or nil
    end
    if code == NG.TIGHT then return Know and Know.no("too_tight") or false end
    if code == NG.WATER then return Know and Know.yes(true, "water") or true end
    return Know and Know.no(code == NG.STEEP and "too_steep" or "blocked") or false
end

-- BILINEAR, not nearest-cell. Verified residual after the estimator fix was
-- median 0.84 / mean 1.84 with a signed bias of +0.30 - symmetric, i.e. genuine
-- SAMPLING error rather than a wrong convention. Nearest-cell throws away the
-- fact that we hold the corners of the cell the point sits in, and interpolating
-- between them costs nothing to store and removes most of that error. Falls back
-- to the plain cell whenever a neighbour is missing or non-ground, so a cliff
-- edge is never smoothed into a ramp that does not exist.
function NG.height(x, y, map)
    map = map or NG.map_name()
    if not map then return nil end
    local tx, ty = NG.tile_of(x, y)
    local t = NG.load(map, tx, ty)
    if not t then return nil end

    local fx = (x - t.x0) / t.res - 0.5
    local fy = (y - t.y0) / t.res - 0.5
    local gx, gy = math.floor(fx), math.floor(fy)
    local sx, sy = fx - gx, fy - gy

    local function cell(ax, ay)
        if ax < 0 or ay < 0 or ax >= t.n or ay >= t.n then return nil end
        local i = ay * t.n + ax + 1
        local c = t.codes[i]
        if c == nil or c == NG.UNKNOWN then return nil end
        return t.heights[i]
    end

    local h00 = cell(gx, gy)
    if h00 == nil then
        local code, h = NG.at(x, y, map)
        if code == nil or code == NG.UNKNOWN then return nil end
        return h
    end
    local h10, h01, h11 = cell(gx + 1, gy), cell(gx, gy + 1), cell(gx + 1, gy + 1)
    if h10 == nil or h01 == nil or h11 == nil then return h00 end
    return (h00 * (1 - sx) + h10 * sx) * (1 - sy)
         + (h01 * (1 - sx) + h11 * sx) * sy
end

-- ---- proof against reality --------------------------------------------------
--
-- Everything upstream of this is checked against ITSELF: the extractor against
-- the client's declared bounding boxes, the loader against the extractor, the
-- planner against a simulator I also wrote. None of that can catch a shared
-- wrong assumption - a mirrored world, a half-tile offset, the wrong map - and
-- every one of those failures looks completely normal from the inside.
--
-- The client is the only independent witness. It will happily raycast the ground
-- under any point we name, so: sample points around the player, ask BOTH, and
-- report the disagreement. Matching heights mean the archives, the coordinate
-- convention, the tile indexing and the map resolution are all right at once.
-- A constant offset means a systematic error; scatter means the wrong tile.
function NG.verify(n, radius)
    n = n or 60
    radius = radius or 120
    local R = RaijinLab
    if not (R and R.TraceGround and R.ObjectPosition) then
        return nil, "no runtime"
    end
    local px, py, pz = R:ObjectPosition("player")
    if not px then return nil, "no position" end
    -- Resync rather than read the memo: this is a hand-run diagnostic, so the one
    -- place a stale map name would be most misleading is the instrument that is
    -- supposed to catch a wrong map. It is not a query path, so it may sync.
    local map = NG.sync_map()
    if not map then return nil, "map unresolved (see NG.CONTINENT_MAP / RaijinLabDB.navgrid.map)" end

    local checked, matched, missing, worst = 0, 0, 0, 0
    local overhead, no_ground = 0, 0
    local sum, bias, errs = 0.0, 0.0, {}
    local by_code = {}
    local worst_x, worst_y, worst_grid, worst_live
    for i = 1, n do
        local a = (i / n) * 2 * math.pi * 3.7      -- spiral, deterministic
        local r = radius * (i / n)
        local x, y = px + math.cos(a) * r, py + math.sin(a) * r
        local gh = NG.height(x, y, map)
        if gh == nil then
            missing = missing + 1
        else
            -- TRACE FROM WHERE THE GRID SAYS THE GROUND IS, not from high above.
            --
            -- Starting 40yd up and casting down finds the first surface from
            -- ABOVE - which over a building is its ROOF. The worst outlier here
            -- was exactly that: the Duskwood Mausoleum, collision top 140.3, and
            -- the client duly reported 140.1 while the grid correctly reported the
            -- ground beside it at 123.6. Nothing was wrong with the extraction; the
            -- instrument was asking a different question than the one that matters.
            --
            -- The navigable question is "is there ground where the grid says", so
            -- probe a window around that height. A roof overhead is still recorded
            -- separately rather than quietly dropped - hiding a disagreement to
            -- make a number look better is how an instrument stops being worth
            -- having.
            local live = R:TraceGround(x, y, gh + 4.0, 5.0, 14.0)
            if not live then
                local far = R:TraceGround(x, y, pz + 40, 45.0, 120.0)
                if far then
                    overhead = overhead + 1
                    if math.abs(far - gh) > 3.0 then no_ground = no_ground + 1 end
                end
            end
            if live then
                checked = checked + 1
                local signed = live - gh
                local e = math.abs(signed)
                sum = sum + e
                bias = bias + signed
                errs[#errs + 1] = e
                if e > worst then
                    worst = e
                    -- KEEP WHERE IT WAS. At 99% within 3yd the residual is a
                    -- handful of individual samples, and an aggregate cannot say
                    -- anything useful about one point. Recording the coordinate
                    -- turns the last error from a statistic into somewhere you
                    -- can go and stand, which is the only way it gets diagnosed
                    -- rather than guessed at.
                    worst_x, worst_y = x, y
                    worst_grid, worst_live = gh, live
                end
                if e <= 3.0 then matched = matched + 1 end
                -- CLASSIFY THE RESIDUAL RATHER THAN NARRATING IT. The report used
                -- to assert that large outliers are WMO floors and water - a claim
                -- nobody had measured, and this project's record on confident
                -- unmeasured explanations is poor. Bucket every error by what the
                -- grid says that cell IS, and the data answers: outliers piled on
                -- STRUCTURE/WATER cells confirm the story, outliers on plain WALK
                -- ground refute it and point somewhere else entirely.
                local code = NG.at(x, y, map) or NG.UNKNOWN
                local b = by_code[code]
                if not b then b = { n = 0, sum = 0, big = 0 }; by_code[code] = b end
                b.n = b.n + 1
                b.sum = b.sum + e
                if e > 3.0 then b.big = b.big + 1 end
            end
        end
    end
    table.sort(errs)
    local median = (#errs > 0) and errs[math.max(1, math.floor(#errs / 2))] or 0
    return {
        map = map, sampled = n, compared = checked, no_tile = missing,
        within_3yd = matched,
        pct = (checked > 0) and (100.0 * matched / checked) or 0,
        mean_err = (checked > 0) and (sum / checked) or 0,
        median_err = median, worst_err = worst,
        -- MEAN SIGNED error. |error| cannot tell a systematic offset from
        -- resolution noise; the sign can. A bias near zero with a nonzero mean
        -- means scatter; a bias close to the mean means everything is off the
        -- same way, which is a convention or an estimator problem, not noise.
        bias = (checked > 0) and (bias / checked) or 0,
        by_code = by_code,
        worst_x = worst_x, worst_y = worst_y,
        worst_grid = worst_grid, worst_live = worst_live,
        -- points where the grid's ground could not be confirmed locally but a
        -- surface exists elsewhere in the column (roof, overhang, bridge)
        overhead = overhead, no_ground = no_ground,
    }
end

function NG.stats()
    local n = 0
    for _ in pairs(NG._cache) do n = n + 1 end
    local miss = 0
    for _ in pairs(NG._misses) do miss = miss + 1 end
    return { cached = n, absent = miss, dir = NG.dir() }
end

if RaijinLab then RaijinLab.NavGrid = NG end
return NG
