-- QuestDB - world knowledge from pfQuest, in WORLD coordinates.
--
-- WHY THIS EXISTS. The engine could only act on what it could currently SEE.
-- Asked to collect "Scavenger Paw" it looked for something of that name in
-- render range, found nothing (the paw is loot, not a mob), and fell through to
-- sweeping a probability field - which is how a bot ends up jogging into a
-- fence. It never had to search: pfQuest-ascension ships the server's own
-- tables. Which mob drops the paw, where that mob spawns, which npc starts the
-- quest and which one takes it back - all of it is on disk already.
--
-- So this module answers "where is X" from data, and only falls back to
-- perception when the data has nothing.
--
-- THE HARD PART IS COORDINATES, AND IT IS SOLVED BY MEASUREMENT.
--
-- pfQuest stores positions as zone PERCENTAGES plus a map id, because that is
-- all a map pin needs. The navigator steers in continent world units. The usual
-- fix is a hardcoded WorldMapArea table of zone bounds - hundreds of magic
-- numbers, wrong for any zone Ascension has altered, and unverifiable.
--
-- We already have both halves of the answer every frame: the runtime gives the
-- player's WORLD position, and GetPlayerMapPosition gives the same point as a
-- zone percentage. The mapping is affine, so two well-separated samples solve it
-- exactly and every later sample CHECKS it. The bot calibrates the zone it is
-- standing in simply by walking around, and a transform that stops predicting is
-- thrown away rather than trusted.
--
-- Axis note (3.3.5): the map is rotated relative to the world. Increasing map-x
-- moves along world -y, and increasing map-y moves along world -x. We do not
-- assume the sign; it falls out of the fit.

local QuestDB = {}
RaijinLab.QuestDB = QuestDB

local abs, huge = math.abs, math.huge

-- Per-map calibration: samples, solved transform, and its measured error.
QuestDB._cal = {}
QuestDB.MIN_SPREAD = 0.02      -- 2% of the zone: below this a pair is degenerate
QuestDB.MAX_ERR = 12.0         -- yards; a transform that predicts worse is wrong
QuestDB.SAMPLE_GAP = 1.0       -- seconds between samples

local function now() return (GetTime and GetTime()) or 0 end

-- The database is VENDORED as RaijinQuest (renamed pfQuest + the Ascension
-- pack), so a launcher update cannot overwrite it and we can extend it. The
-- upstream globals are accepted as a fallback if the stock addon is also
-- installed, but ours is preferred so behaviour never depends on load order.
-- Declared HERE, above every consumer: as a local it is only in scope for
-- closures created after this point - zone_rect sat above it and resolved
-- DBT as a GLOBAL, throwing at runtime.
local function DBT() return RaijinQuestDB or pfDB end


-- WE NEED THE DATA, NOT THE ADDON.
--
-- RaijinQuest's UI (map, tracker, browser, journal, config) is pure cost to us:
-- it threw a cascade of errors when vendored, and the client is 32-bit with a
-- 2GB address space that a crash dump showed at 1.8GB with 140MB of Lua. So the
-- code half is no longer loaded at all - only the tables.
--
-- That means we cannot call RaijinQuestDatabase:GetIDByName, so name->id is
-- resolved by inverting the locale tables ourselves, once, lazily.
function QuestDB.available()
    local db = DBT()
    return db ~= nil and db.units ~= nil
end

QuestDB._name_idx = nil

local function build_name_index()
    local db = DBT()
    if not db then return nil end
    local idx = { units = {}, objects = {}, items = {} }
    for kind, tbl in pairs(idx) do
        local loc = db[kind] and db[kind].loc
        if loc then
            for id, name in pairs(loc) do
                if type(name) == "string" and name ~= "" then
                    -- first id wins: the tables are ordered and duplicates are
                    -- rare renames, not distinct things
                    if idx[kind][name] == nil then idx[kind][name] = id end
                end
            end
        end
    end
    return idx
end

-- A SOLVED ZONE STAYS SOLVED, ACROSS SESSIONS.
--
-- The transform is measured, so a zone must be walked before its database
-- coordinates become usable - which is a real limit on "anywhere from anywhere":
-- the first time you need to travel INTO a zone is exactly when you have not
-- been there. Persisting it means each zone is solved once, ever, and the
-- world becomes progressively and permanently navigable.
--
-- Stored per map id with the error it achieved, so a bad fit is never resurrected
-- and a better one always wins. Verified on load the same way as a live fit: the
-- first sample that disagrees throws it away.
function QuestDB.save()
    if not RaijinLabDB then return end
    RaijinLabDB.questdb = RaijinLabDB.questdb or {}
    local out = RaijinLabDB.questdb.cal or {}
    for map, c in pairs(QuestDB._cal) do
        if c.t_solved then
            local prev = out[map]
            if not prev or (c.err or 0) <= (prev.err or math.huge) then
                out[map] = {
                    ax = c.t_solved.ax, bx = c.t_solved.bx,
                    ay = c.t_solved.ay, by = c.t_solved.by,
                    err = c.err or 0,
                }
            end
        end
    end
    RaijinLabDB.questdb.cal = out

    -- AND THE CLIENT-MAP TRANSFORMS, which matter most when they cannot be
    -- rebuilt. While the player is a GHOST every npc reads position (0,0,0), so
    -- the world-consensus fit has nothing to work with and the zone transform
    -- cannot be re-derived - yet that is exactly when the corpse's location is
    -- needed. Fitted while alive and walking, persisted, and simply there when
    -- death happens.
    local cout = RaijinLabDB.questdb.ccal or {}
    for mapid, c in pairs(QuestDB._ccal or {}) do
        if c.t_solved then
            local prev = cout[mapid]
            if not prev or (c.err or 0) <= (prev.err or math.huge) then
                cout[mapid] = {
                    ax = c.t_solved.ax, bx = c.t_solved.bx,
                    ay = c.t_solved.ay, by = c.t_solved.by,
                    err = c.err or 0,
                }
            end
        end
    end
    RaijinLabDB.questdb.ccal = cout
end

function QuestDB.load()
    if not (RaijinLabDB and RaijinLabDB.questdb and RaijinLabDB.questdb.cal) then return 0 end
    local n = 0
    for map, t in pairs(RaijinLabDB.questdb.cal) do
        if t and t.ax and t.ay then
            local c = QuestDB._cal[map]
            if not c then c = { samples = {}, t = 0 }; QuestDB._cal[map] = c end
            if not c.t_solved then
                c.t_solved = { ax = t.ax, bx = t.bx, ay = t.ay, by = t.by }
                c.err = t.err
                c.restored = true
                n = n + 1
            end
        end
    end
    for mapid, t in pairs((RaijinLabDB.questdb and RaijinLabDB.questdb.ccal) or {}) do
        if t and t.ax and t.ay then
            QuestDB._ccal = QuestDB._ccal or {}
            local c = QuestDB._ccal[mapid]
            if not c then c = { samples = {} }; QuestDB._ccal[mapid] = c end
            if not c.t_solved then
                c.t_solved = { ax = t.ax, bx = t.bx, ay = t.ay, by = t.by }
                c.err, c.restored = t.err, true
                n = n + 1
            end
        end
    end
    return n
end

-- THE ZONE ID MUST BE THE DATABASE'S, NOT THE CLIENT'S.
--
-- The spawn tables key coordinates by RaijinQuest's own zone id (Tirisfal = 85).
-- Calibration was keyed on GetCurrentMapAreaID(), which returns the client's
-- WorldMapArea id - live: **1240**. So the transform was stored under 1240 while
-- every lookup asked for 85, found nothing, and reported "no known location" for
-- an objective whose coordinates were on disk and whose zone WAS solved
-- (`qdb map=1240 solved=true` next to `no_known_location` every tick).
--
-- Resolve by zone NAME: GetRealZoneText() is what the database's own locale
-- table is keyed by, and it needs no SetMapToCurrentZone (which re-points the
-- player's world map and fires events). GetMapID() is the fallback.
-- THE ZONE ID MUST BE THE DATABASE'S OWN.
--
-- Spawns are keyed by RaijinQuest zone id (Tirisfal Glades = 85), NOT by the
-- client's WorldMapArea id (live: 1240). Solving the transform under 1240 while
-- every lookup asked for 85 is why `qdb map=1240 solved=true` once sat on the
-- same log line as `no_known_location`.
--
-- This used to go through RaijinQuestMap:GetMapIDByName, but that lives in the
-- pfQuest UI, which we no longer load. So resolve it here: the zone locale table
-- is a flat id -> name map, and inverting it once is the whole job.
--
-- Names are NOT unique (Westfall is 40 and 206; Thandol Span is 330, 880, 881).
-- Only ids present in zones.data have the rect a coordinate transform needs, so
-- those win; ties go to the lowest id for determinism. Returns nil rather than
-- guessing when nothing resolves - an unresolved zone must never be mistaken
-- for zone 0.
QuestDB._zone_idx = nil

local function build_zone_index()
    local db = DBT()
    local zones = db and db.zones
    local loc = zones and (zones.loc or zones.enUS)
    if not loc then return nil end
    local data = zones.data or {}
    local idx = {}
    for id, name in pairs(loc) do
        if type(name) == "string" and name ~= "" then
            local prev = idx[name]
            if prev == nil then
                idx[name] = id
            else
                local a_real, b_real = data[id] ~= nil, data[prev] ~= nil
                if a_real ~= b_real then
                    if a_real then idx[name] = id end
                elseif id < prev then
                    idx[name] = id
                end
            end
        end
    end
    return idx
end

function QuestDB.current_zone()
    if not (GetRealZoneText and QuestDB.available()) then return nil end
    local ok, name = pcall(GetRealZoneText)
    if not (ok and name and name ~= "") then return nil end
    if not QuestDB._zone_idx then QuestDB._zone_idx = build_zone_index() end
    local idx = QuestDB._zone_idx
    return idx and tonumber(idx[name]) or nil
end

-- ---- calibration ---------------------------------------------------------

local function cal_for(map)
    local c = QuestDB._cal[map]
    if not c then
        c = { samples = {}, t = 0 }
        QuestDB._cal[map] = c
    end
    return c
end

-- Solve world = a * pct + b on each axis from two samples.
-- Returns nil when the pair is degenerate (too close to separate the axes).
function QuestDB.solve(s1, s2)
    local dxp, dyp = s2.xp - s1.xp, s2.yp - s1.yp
    if abs(dxp) < QuestDB.MIN_SPREAD or abs(dyp) < QuestDB.MIN_SPREAD then
        return nil
    end
    -- world x varies with map y, world y varies with map x (3.3.5 rotation).
    local ax = (s2.wx - s1.wx) / dyp
    local ay = (s2.wy - s1.wy) / dxp
    return {
        ax = ax, bx = s1.wx - ax * s1.yp,
        ay = ay, by = s1.wy - ay * s1.xp,
    }
end

function QuestDB.apply(t, xp, yp)
    if not t then return nil end
    return t.ax * yp + t.bx, t.ay * xp + t.by
end

-- Feed one observation. Cheap enough to call every tick; self-throttled.
-- ---- EXACT map -> world, from the client's own data ----------------------
--
-- WorldMapArea.dbc stores the world rectangle of every map the client can show.
-- With it, a map percentage converts EXACTLY and immediately:
--
--   * no calibration walk, and no degenerate-pair refusals (a 71-yard run due
--     north leaves the other axis flat and a fitted transform is rightly
--     rejected);
--   * it works WHILE DEAD, which fitting cannot: a ghost reads every npc at
--     (0,0,0), so the world-consensus fit has nothing to work with at exactly
--     the moment the corpse's position is wanted;
--   * zero error instead of a few yards - verified against a live sample at
--     0.02yd.
--
-- Resolved by GetMapInfo() NAME rather than GetCurrentMapAreaID(): live, the id
-- came back 1240 while the matching row was 1239. Encoding an off-by-one nobody
-- can verify is how a wrong answer gets shipped confidently; the name is exact.
function QuestDB.map_bounds()
    local T = RaijinLab and RaijinLab.WorldMapAreas
    if not (T and GetMapInfo) then return nil end
    local ok, name = pcall(GetMapInfo)
    if not (ok and type(name) == "string" and name ~= "") then return nil end
    return T[string.lower(name)], name
end

-- (mapX, mapY) as fractions 0..1 -> world x, y. nil when this map has no
-- placement, which is honest: some maps genuinely have no world rectangle.
function QuestDB.map_to_world(mx, my)
    if type(mx) ~= "number" or type(my) ~= "number" then return nil end
    local b = QuestDB.map_bounds()
    if not b then return nil end
    local left, right, top, bottom = b[1], b[2], b[3], b[4]
    if not (left and right and top and bottom) then return nil end
    -- 3.3.5 axes are rotated: world X comes from the map's Y.
    return top + my * (bottom - top), left + mx * (right - left)
end

-- ---- the CLIENT MAP's own percentage space -------------------------------
--
-- TWO PERCENTAGE SPACES EXIST AND THEY ARE NOT INTERCHANGEABLE.
--
-- Database spawns are stored as percentages of a RaijinQuest zone (Deathknell =
-- 154). GetPlayerMapPosition and GetCorpseMapPosition return percentages of the
-- map the CLIENT is currently showing (GetCurrentMapAreaID = 1240, Tirisfal).
-- Deathknell is 13% x 18% of Tirisfal, so a transform fitted in one space
-- rescales any delta expressed in the other by roughly 7x.
--
-- That is exactly what sent the bot past the body: the corpse's client-map
-- percentage was converted with the zone-fitted transform, and the resulting
-- point was both displaced and the wrong distance away.
--
-- So keep a SECOND transform, fitted from the only pairing that is honest here -
-- the player's own client-map percentage against the player's world position.
-- Same solver, same degeneracy rules, same prediction test; different space.
QuestDB._ccal = {}

function QuestDB.observe_client(mapid, xp, yp, wx, wy)
    if not (mapid and xp and yp and wx and wy) then return end
    if xp <= 0 and yp <= 0 then return end
    local c = QuestDB._ccal[mapid]
    if not c then c = { samples = {} }; QuestDB._ccal[mapid] = c end
    local s = { xp = xp, yp = yp, wx = wx, wy = wy }

    if c.t_solved then
        local px, py = QuestDB.apply(c.t_solved, xp, yp)
        local err = px and math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2) or huge
        c.err = err
        if err > QuestDB.MAX_ERR then
            c.t_solved, c.samples = nil, { s }   -- stopped predicting: refit
        end
        return
    end

    c.samples[#c.samples + 1] = s
    if #c.samples > 6 then table.remove(c.samples, 1) end
    local best, bestspread = nil, 0
    for i = 1, #c.samples do
        for j = i + 1, #c.samples do
            local a, b = c.samples[i], c.samples[j]
            local spread = abs(b.xp - a.xp) + abs(b.yp - a.yp)
            if spread > bestspread then
                local t = QuestDB.solve(a, b)
                if t then best, bestspread = t, spread end
            end
        end
    end
    if best then c.t_solved, c.err = best, 0 end
end

-- Client-map percentage -> world. Returns nil when that map is not yet solved,
-- which is honest: walking a few yards solves it, and a guessed corpse location
-- is worse than none.
function QuestDB.client_to_world(mapid, xp, yp)
    local c = mapid and QuestDB._ccal[mapid]
    if not (c and c.t_solved) then return nil end
    return QuestDB.apply(c.t_solved, xp, yp)
end

function QuestDB.observe(map, xp, yp, wx, wy)
    if not (map and xp and yp and wx and wy) then return end
    if xp <= 0 and yp <= 0 then return end          -- off-map / no position
    -- Calibrate the zone we are STANDING IN, not its root. Root space compresses
    -- local movement into a fraction of a percent and every pair comes out
    -- degenerate; to_world descends into this transform when a spawn is keyed to
    -- an ancestor zone.
    -- SAMPLES MUST ALL BE MEASURED AGAINST THE SAME MAP.
    --
    -- GetPlayerMapPosition returns percentages of whatever map the client is
    -- CURRENTLY SHOWING, which changes on its own (zoning, opening the world
    -- map, a subzone transition). Live: six samples stored under zone 154
    -- (Deathknell, from GetRealZoneText) while GetCurrentMapAreaID said 1240
    -- (Tirisfal) - so percentages from one space were fitted as though they
    -- belonged to another and the transform came out 145 YARDS wrong. A fit that
    -- wrong is not a worse answer, it is a different place.
    --
    -- Stamp every sample with the map it was measured against and throw the set
    -- away when that changes. Fewer samples that agree beat more that do not.
    local ref = GetCurrentMapAreaID and GetCurrentMapAreaID() or nil
    local c = cal_for(map)
    if c.ref ~= ref then
        c.samples, c.t_solved, c.err, c.bootstrapped = {}, nil, nil, nil
        c.ref = ref
    end
    -- THE FIRST SAMPLE IS NEVER THROTTLED. `c.t` starts at 0 and now() is 0 when
    -- GetTime is unavailable, so `now() - c.t < GAP` was true forever and the
    -- module silently never sampled at all - it would have shipped looking
    -- healthy and calibrating nothing.
    if c.n and (now() - c.t) < QuestDB.SAMPLE_GAP then return end
    c.t, c.n = now(), (c.n or 0) + 1
    local s = { xp = xp, yp = yp, wx = wx, wy = wy, ref = ref }

    -- A SOLVED TRANSFORM MUST KEEP EARNING IT. Every new sample is a prediction
    -- test: if the fit stops matching the world (zone changed, bad sample, a
    -- teleport mid-pair) it is discarded rather than quietly steering us wrong.
    if c.t_solved then
        -- A WORLD-FITTED TRANSFORM IS NOT JUDGED BY THE PLAYER'S MAP READING.
        --
        -- fit_from_world derives the transform from N independent npc
        -- observations and requires consensus among them; GetPlayerMapPosition is
        -- the single measurement we KNOW is unreliable here (it is relative to
        -- whatever map the client shows, which disagreed with the zone by a whole
        -- parent map). Testing the good fit against the bad sample threw it away
        -- on the very next tick, so `locate` returned a target one moment and nil
        -- the next and the engine could never commit to anything.
        --
        -- Re-validate it against the evidence that produced it instead.
        if c.bootstrapped == "world" then
            -- RE-FIT RARELY, AND ONLY FOR A BETTER ANSWER.
            --
            -- Re-fitting every tick made the transform WOBBLE: the visible npc
            -- set changes constantly, so each fit differed slightly and a fixed
            -- point in the world moved tens of yards between ticks (measured on
            -- the corpse: 201, 226, 170, 192, 171 yards away on consecutive
            -- reads). Nothing downstream can commit to a destination that moves.
            --
            -- A solved transform is kept until a fit with STRICTLY MORE
            -- agreement appears; equal consensus is not a reason to churn.
            local last = c.refit_t or 0
            if (now() - last) < (QuestDB.REFIT_GAP or 20) then return end
            c.refit_t = now()
            local t2, _, agree, err2 = QuestDB.fit_from_world(map)
            if t2 and agree and agree > (c.consensus or 0) then
                c.t_solved, c.consensus, c.err = t2, agree, err2 or c.err
            end
            return
        end
        local px, py = QuestDB.apply(c.t_solved, xp, yp)
        local err = math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2)
        c.err = err
        if err > QuestDB.MAX_ERR then
            c.t_solved, c.samples = nil, { s }
            return
        end
        return
    end

    -- No transform yet: try to solve it standing still, from a uniquely-placed
    -- npc, before falling back to needing the character to walk.
    if QuestDB.bootstrap(map, xp, yp, wx, wy) then return end


    c.samples[#c.samples + 1] = s
    if #c.samples > 6 then table.remove(c.samples, 1) end
    -- try the widest-separated pair we hold
    local best, bestspread = nil, 0
    for i = 1, #c.samples do
        for j = i + 1, #c.samples do
            local a, b = c.samples[i], c.samples[j]
            local spread = abs(b.xp - a.xp) + abs(b.yp - a.yp)
            if spread > bestspread then
                local t = QuestDB.solve(a, b)
                if t then best, bestspread = t, spread end
            end
        end
    end
    if best then c.t_solved = best end
end

-- CALIBRATE WITHOUT MOVING.
--
-- The transform is measured from (zone%, world) pairs, which the player supplies
-- one per sample - so two well-separated samples need the character to WALK. But
-- the engine correctly refuses to walk to an unknown location, and the location
-- is unknown until the zone is calibrated. Each half is right and together they
-- deadlock: live, the bot sat at (1844.7, 1599.0) logging "no_known_location"
-- forever, never moving, so it could never calibrate.
--
-- Break it with a second pair that costs no movement. Any npc in the object
-- manager whose database entry has EXACTLY ONE spawn in this zone is an
-- unambiguous correspondence: we know its world position (OM) and its zone
-- percentage (database). One player pair + one such npc solves the zone
-- instantly, standing still.
--
-- Ambiguity is refused, not guessed: an npc with several spawns tells us
-- nothing about WHICH one we are looking at.
-- WHICH MAP ARE THESE PERCENTAGES ACTUALLY OF?
--
-- GetPlayerMapPosition is relative to the map the CLIENT IS SHOWING, and we have
-- no way to ask which database zone that is: GetMapNameByID(1240) returns nil on
-- this build. Live, GetRealZoneText said "Deathknell" (154) while the shown map
-- was 1240 (Tirisfal, zone 85), so percentages of one map were fitted as another
-- and the transform came out 145 yards wrong.
--
-- We do not have to guess. A candidate zone is a HYPOTHESIS, and a hypothesis
-- that is right predicts our own position: solve from a uniquely-placed npc, then
-- ask where that transform says WE are. The wrong zone misses by hundreds of
-- yards. So try the zone we think we are in and then each ancestor, and accept
-- the first that predicts the player to within MAX_ERR.
-- FIT THE ZONE FROM THE WORLD, NOT FROM OUR OWN MAP READING.
--
-- Every calibration path so far leaned on GetPlayerMapPosition - the ONE
-- measurement proven unreliable here (it is relative to whatever map the client
-- shows: live it reported Tirisfal percentages while GetRealZoneText said
-- Deathknell). Fitting from it produced transforms 145 yards wrong, and the
-- hypothesis test then correctly rejected every one, leaving the bot with no
-- coordinates at all.
--
-- But we do not need it. Every npc we can SEE that the database places at
-- exactly one spot in this zone is an independent (zone%, world) correspondence,
-- measured entirely from the runtime. A dozen of them are usually in range.
--
-- CONSENSUS, NOT PROBABILITY. Enumerate every pair (deterministic - no sampling,
-- no randomness), solve the affine transform each pair implies, and count how
-- many OTHER correspondences that transform predicts within MAX_ERR. The true
-- transform explains nearly all of them; a transform built from a misidentified
-- npc explains almost none. Require agreement from at least MIN_CONSENSUS
-- independent observations before believing anything, so a single wrong npc can
-- never place the whole zone.
QuestDB.MIN_CONSENSUS = 3
QuestDB.REFIT_GAP = 20     -- s: a solved world fit is not recomputed more often

function QuestDB.correspondences(map)
    local RL = RaijinLab
    local L = RL and RL.om and RL.om.object_list
    local npcs = L and L.npcs
    if not npcs then return {} end
    local out = {}
    for i = 1, #npcs do
        local st = npcs[i]
        local id = st and tonumber(st.Id)
        if id and id > 0 then
            local raw = QuestDB.unit_spawns_raw(id)
            local here, n = nil, 0
            for _, sp in ipairs(raw or {}) do
                local sx, sy = sp.xp, sp.yp
                if sp.zone ~= map then
                    sx, sy = QuestDB.to_zone(map, sp.zone, sp.xp, sp.yp)
                    if sx and (sx < 0 or sx > 1 or sy < 0 or sy > 1) then sx = nil end
                end
                if sx then n = n + 1; here = { xp = sx, yp = sy } end
            end
            -- exactly one placement, or we cannot say which one we are looking at
            if n == 1 and here and RL.ObjectPosition then
                local ok, ux, uy = pcall(RL.ObjectPosition, RL, st.Guid)
                if ok and ux and uy and not (ux == 0 and uy == 0) then
                    out[#out + 1] = { xp = here.xp, yp = here.yp, wx = ux, wy = uy }
                end
            end
        end
    end
    return out
end

function QuestDB.fit_from_world(map)
    local pts = QuestDB.correspondences(map)
    if #pts < QuestDB.MIN_CONSENSUS then return nil, #pts, 0 end
    local best, bestn, bestres = nil, 0, huge
    for i = 1, #pts do
        for j = i + 1, #pts do
            local t = QuestDB.solve(pts[i], pts[j])
            if t then
                local n, res = 0, 0
                for k = 1, #pts do
                    local px, py = QuestDB.apply(t, pts[k].xp, pts[k].yp)
                    if px then
                        local e = math.sqrt((px - pts[k].wx) ^ 2 + (py - pts[k].wy) ^ 2)
                        if e <= QuestDB.MAX_ERR then n = n + 1; res = res + e end
                    end
                end
                -- most agreement wins; ties break on total error, so the answer
                -- is a function of the data alone and never of iteration order
                if n > bestn or (n == bestn and n > 0 and res < bestres) then
                    best, bestn, bestres = t, n, res
                end
            end
        end
    end
    if best and bestn >= QuestDB.MIN_CONSENSUS then
        return best, #pts, bestn, bestres / bestn
    end
    return nil, #pts, bestn
end

function QuestDB.zone_candidates(map)
    local out, z, guard = { map }, map, 0
    while guard < 6 do
        local parent = QuestDB.zone_rect(z)
        if not parent then break end
        out[#out + 1] = parent
        z = parent
        guard = guard + 1
    end
    return out
end

function QuestDB.bootstrap(map, xp, yp, wx, wy)
    if QuestDB.transform(map) then return false end
    if not (map and xp and yp and wx and wy) then return false end
    -- FIRST: fit from the world itself. This needs no map reading of our own, so
    -- it works exactly where the player-percentage path fails, and its consensus
    -- count is stronger evidence than a single pair could ever be.
    local cands = QuestDB.zone_candidates(map)
    for i = 1, #cands do
        local cz = cands[i]
        if not QuestDB.transform(cz) then
            local t, npts, agree, mean_err = QuestDB.fit_from_world(cz)
            if t then
                local c = cal_for(cz)
                c.t_solved, c.err, c.bootstrapped = t, mean_err or 0, "world"
                c.consensus, c.points = agree, npts
                return true
            end
        end
    end

    -- Otherwise fall back to the single-npc pair, verified against our own
    -- position (see zone_candidates).

    if #cands > 1 then
        for i = 1, #cands do
            local cz = cands[i]
            if not QuestDB.transform(cz)
                and QuestDB._bootstrap_one(cz, xp, yp, wx, wy) then
                local t = QuestDB.transform(cz)
                local px, py = QuestDB.apply(t, xp, yp)
                local err = px and math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2) or huge
                if err <= QuestDB.MAX_ERR then
                    local c = cal_for(cz)
                    c.err = err
                    return true
                end
                -- wrong hypothesis: discard it rather than steer by it
                local c = cal_for(cz)
                c.t_solved, c.err, c.bootstrapped = nil, nil, nil
            end
        end
        return false
    end
    return QuestDB._bootstrap_one(map, xp, yp, wx, wy)
end

function QuestDB._bootstrap_one(map, xp, yp, wx, wy)
    local RL = RaijinLab
    local L = RL and RL.om and RL.om.object_list
    local npcs = L and L.npcs
    if not npcs then return false end

    for i = 1, #npcs do
        local s = npcs[i]
        local id = s and tonumber(s.Id)
        if id and id > 0 then
            local raw = QuestDB.unit_spawns_raw(id)
            -- Exactly one spawn IN THIS ZONE, or we cannot say which one we are
            -- looking at. Spawns are compared in ROOT space: `map` is now the
            -- root (see observe), while an npc standing in Deathknell has its
            -- spawn keyed to 154. Comparing those raw meant no candidate ever
            -- matched and the zone could only be solved by walking.
            local here, n = nil, 0
            for _, sp in ipairs(raw or {}) do
                -- Same zone, or an ancestor whose point lands inside this one.
                local sx, sy = sp.xp, sp.yp
                if sp.zone ~= map then
                    sx, sy = QuestDB.to_zone(map, sp.zone, sp.xp, sp.yp)
                    if sx and (sx < 0 or sx > 1 or sy < 0 or sy > 1) then
                        sx = nil            -- outside: not the npc we can see
                    end
                end
                if sx then n = n + 1; here = { xp = sx, yp = sy } end
            end
            if n == 1 and here and RL.ObjectPosition then
                local okp, ux, uy = pcall(RL.ObjectPosition, RL, s.Guid)
                if okp and ux and uy then
                    local t = QuestDB.solve(
                        { xp = xp, yp = yp, wx = wx, wy = wy },
                        { xp = here.xp, yp = here.yp, wx = ux, wy = uy })
                    if t then
                        local c = cal_for(map)
                        c.t_solved, c.err, c.bootstrapped = t, 0, true
                        return true
                    end
                end
            end
        end
    end
    return false
end

function QuestDB.transform(map)
    local c = QuestDB._cal[map]
    return c and c.t_solved or nil
end

-- A ZONE IS A RECTANGLE ON ITS PARENT MAP, AND THAT IS ENOUGH.
--
-- Calibration is measured, so only zones we have STOOD IN get a transform. That
-- capped "anywhere from anywhere" at "anywhere I have already been": an
-- objective one zone over could not be placed, so it read as unknown and the
-- engine parked.
--
-- But the database states each zone's geometry on its parent:
--   zones.data[id] = { parentZone, width, height, centreX, centreY }
-- all in PARENT percent (confirmed against SearchZoneID, which unpacks exactly
-- that and treats x,y as the centre). So a point inside a zone converts to a
-- point on the continent with arithmetic alone - and ONE calibrated continent
-- places every zone on it, including ones never visited.
function QuestDB.zone_rect(zone)
    local db = DBT()
    local z = db and db.zones and db.zones.data and db.zones.data[zone]
    if not z then return nil end
    local parent, w, h, cx, cy = z[1], z[2], z[3], z[4], z[5]
    if not (parent and parent > 0 and w and h and cx and cy) then return nil end
    return parent, w, h, cx, cy
end

-- Three-valued: nil = cannot place it (do not guess), else world x,y.
-- WALK A POINT UP TO ITS ROOT ZONE.
--
-- pfQuest stores a zone either as a ROOT (no row in zones.data - its percentages
-- ARE the map's own) or as a CHILD carrying {parent, w, h, cx, cy} in percent OF
-- THE PARENT. Live, the player stood in Deathknell (154) while the objective's
-- spawns were keyed to Tirisfal Glades (85), and 85 is a root with no rect - so
-- a transform solved for 154 could never place them, and the engine reported
-- no_known_location for coordinates that were sitting on disk.
--
-- Worse, the samples themselves were in two different spaces: five taken while
-- the world map showed Deathknell and one while it showed Tirisfal (its xp was
-- 0.3437 - the parent's own centreX). Averaged together those describe no map at
-- all, which is why six samples never solved.
--
-- Both problems are the same problem. Normalise everything - samples AND spawns
-- - into the ROOT zone's space, and one transform per continent-level map serves
-- every subzone under it.
function QuestDB.to_root(zone, xp, yp, _depth)
    _depth = (_depth or 0) + 1
    if _depth > 6 then return zone, xp, yp end
    local parent, w, h, cx, cy = QuestDB.zone_rect(zone)
    if not parent then return zone, xp, yp end      -- already the root
    local pxp = (cx + (xp - 0.5) * w) / 100
    local pyp = (cy + (yp - 0.5) * h) / 100
    return QuestDB.to_root(parent, pxp, pyp, _depth)
end

-- EXPRESS A POINT FROM AN ANCESTOR ZONE IN A DESCENDANT'S SPACE.
--
-- The inverse of to_root, and the one that actually matters for calibration.
-- Normalising everything up to the root looks tidy and RUINS the fit: Deathknell
-- is 13% x 18% of Tirisfal, so two points 17 yards apart differ by 0.0008 in
-- root percent - degenerate on that axis, and solve() rightly refuses it. Live,
-- all 20 bootstrap candidates failed for exactly this reason.
--
-- So calibrate in the SUBZONE, where percent spread is large, and bring the
-- spawn down to meet it. Both directions are exact affine maps; only the
-- conditioning differs, and this is the well-conditioned one.
function QuestDB.to_zone(target, from, xp, yp)
    if target == from then return xp, yp end
    local chain, z, guard = {}, target, 0
    while z ~= from and guard < 8 do
        local parent, w, h, cx, cy = QuestDB.zone_rect(z)
        if not parent then return nil end
        chain[#chain + 1] = { w = w, h = h, cx = cx, cy = cy }
        z = parent
        guard = guard + 1
    end
    if z ~= from then return nil end       -- not an ancestor: no relation
    local x, y = xp, yp
    for i = #chain, 1, -1 do
        local r = chain[i]
        if not (r.w and r.w > 0 and r.h and r.h > 0) then return nil end
        x = 0.5 + (x * 100 - r.cx) / r.w
        y = 0.5 + (y * 100 - r.cy) / r.h
    end
    return x, y
end

-- Is the map the client is SHOWING the same space as this database zone?
--
-- The dbc gives an exact rectangle for the displayed map, and database spawns
-- are percentages of a RaijinQuest zone. When those are the same area, the dbc
-- transform converts spawns exactly - no calibration, no walking, no waiting.
--
-- We do not assume it: the player's own map percentage run through the dbc must
-- land on the player's actual world position. That is a free, continuous check
-- with a known answer, and it fails loudly when the displayed map is a different
-- area (a subzone, a parent, an instance overlay).
function QuestDB.dbc_matches_zone(zone)
    if zone ~= (QuestDB.current_zone and QuestDB.current_zone()) then return false end
    if not (GetPlayerMapPosition and RaijinLab.ObjectPosition and QuestDB.map_to_world) then
        return false
    end
    local ok, mx, my = pcall(GetPlayerMapPosition, "player")
    if not (ok and mx and my) or (mx == 0 and my == 0) then return false end
    local px, py = RaijinLab:ObjectPosition("player")
    if not px then return false end
    local okw, wx, wy = pcall(QuestDB.map_to_world, mx, my)
    if not (okw and wx and wy) then return false end
    return math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2) <= (QuestDB.MAX_ERR or 12)
end

function QuestDB.to_world(map, xp, yp, _depth)
    -- EXACT FIRST. The fitted transform needs two well-separated samples, which
    -- means the character must WALK on both axes before it can know where
    -- anything is - and the chain diagnostic sat on "map 154 NOT solved, walk a
    -- little" while the client already knew the answer exactly.
    if not _depth and QuestDB.dbc_matches_zone(map) then
        local ok, wx, wy = pcall(QuestDB.map_to_world, xp, yp)
        if ok and wx and wy then return wx, wy end
    end
    return QuestDB._to_world_fitted(map, xp, yp, _depth)
end

function QuestDB._to_world_fitted(map, xp, yp, _depth)
    local t = QuestDB.transform(map)
    if t then return QuestDB.apply(t, xp, yp) end

    -- Not calibrated here, but a SUBZONE of here may be - and that is the normal
    -- case: spawns are keyed to the continent-level zone (Tirisfal, 85) while the
    -- character is standing in a subzone (Deathknell, 154) which is where the
    -- transform could actually be solved. Bring the point down into it.
    for z, c in pairs(QuestDB._cal) do
        if c.t_solved and z ~= map then
            local dx, dy = QuestDB.to_zone(z, map, xp, yp)
            if dx then
                -- only trust it if the point really lands inside that subzone;
                -- outside it the extrapolation is unbounded
                if dx >= -0.05 and dx <= 1.05 and dy >= -0.05 and dy <= 1.05 then
                    return QuestDB.apply(c.t_solved, dx, dy)
                end
            end
        end
    end

    -- Not calibrated here: express the point on the parent map and try there.
    -- Bounded depth - a malformed table must not recurse forever, and the real
    -- chain is only ever zone -> continent.
    _depth = (_depth or 0) + 1
    if _depth > 4 then return nil end
    local parent, w, h, cx, cy = QuestDB.zone_rect(map)
    if not parent then return nil end
    local pxp = (cx + (xp - 0.5) * w) / 100
    local pyp = (cy + (yp - 0.5) * h) / 100
    return QuestDB.to_world(parent, pxp, pyp, _depth)
end

-- ---- lookups -------------------------------------------------------------

-- READ THE RAW TABLES. The Search* API IS NOT A QUERY.
--
-- `SearchMobID` returns `maps[zone] = <priority count>` - a NUMBER - and pushes
-- the actual coordinates into RaijinQuestMap:AddNode() as a SIDE EFFECT, because
-- it exists to draw map pins, not to answer questions. So spawns_to_world() was
-- iterating an integer and yielding nothing, on every call, regardless of
-- calibration: "no_known_location" for a mob whose coordinates were on disk.
--
-- The database tables themselves are plain and total:
--   units.data[id].coords = { {x, y, zone, respawn}, ... }   x/y are PERCENT
--   items.data[id].U      = { [unitId] = dropRate, ... }     who drops it
-- Read those.

function QuestDB.name_to_id(name, kind)
    if not (name and QuestDB.available()) then return nil end
    if not QuestDB._name_idx then QuestDB._name_idx = build_name_index() end
    local idx = QuestDB._name_idx
    local tbl = idx and idx[kind or "units"]
    return tbl and tonumber(tbl[name]) or nil
end

-- Every spawn of this unit id, as {xp, yp, zone} with xp/yp in 0..1.
function QuestDB.unit_spawns_raw(unit_id)
    local db = DBT()
    local u = db and db.units and db.units.data and db.units.data[unit_id]
    local coords = u and u.coords
    if not coords then return nil end
    local out = {}
    for _, e in pairs(coords) do
        local x, y, zone = e[1], e[2], e[3]
        if x and y and zone and zone > 0 then
            out[#out + 1] = { xp = x / 100, yp = y / 100, zone = zone }
        end
    end
    return out
end

-- Convert raw spawns to world points, dropping any zone we cannot place.
function QuestDB.to_world_points(raw)
    local out, unplaced = {}, 0
    for _, s in ipairs(raw or {}) do
        local wx, wy = QuestDB.to_world(s.zone, s.xp, s.yp)
        if wx then
            out[#out + 1] = { x = wx, y = wy, map = s.zone }
        else
            unplaced = unplaced + 1
        end
    end
    return out, unplaced
end

function QuestDB.mob_spawns(name)
    if not (QuestDB.available() and name) then return nil end
    local id = QuestDB.name_to_id(name, "units")
    if not id then return nil end
    return QuestDB.to_world_points(QuestDB.unit_spawns_raw(id))
end

-- Where does this ITEM come from? The question perception can never answer:
-- "Scavenger Paw" is loot, so no unit carries that name. items.data[id].U names
-- the units that drop it; their spawns are where to go.
function QuestDB.item_sources(name)
    if not (QuestDB.available() and name) then return nil end
    local id = QuestDB.name_to_id(name, "items")
    if not id then return nil end
    local db = DBT()
    local item = db and db.items and db.items.data and db.items.data[id]
    local droppers = item and item.U
    if not droppers then return nil end
    local all = {}
    for unit_id in pairs(droppers) do
        for _, s in ipairs(QuestDB.unit_spawns_raw(unit_id) or {}) do
            all[#all + 1] = s
        end
    end
    return QuestDB.to_world_points(all)
end

-- THE NAME OF AN ENTRY, WHEN THE CLIENT CANNOT TELL US.
--
-- On 3.3.5 no Lua API turns a GUID into an npc name: UnitName takes a unit
-- TOKEN. The object manager therefore called UnitName(guid), got nil every
-- time, and stored "<0xF13...>" as the name of EVERY object in the world -
-- which is what the live log shows. Anything matching by name (the quest log's
-- objective text, most obviously) could never match.
--
-- But the object manager knows each object's ENTRY id, and the database is
-- keyed by exactly that: units.loc[id] / objects.loc[id] hold the localised
-- name. So the name is available - just from data rather than from the client.
function QuestDB.entry_name(id, kind)
    if not (QuestDB.available() and id) then return nil end
    local db = DBT()
    id = tonumber(id)
    if not id then return nil end
    local units = db.units and db.units.loc
    local objects = db.objects and db.objects.loc
    -- Try the stated kind first, then the other: the object manager names a
    -- struct BEFORE it classifies it, so `kind` is often unknown there. Entry id
    -- spaces do not overlap in practice, so the second look is safe.
    local first = (kind == "O") and objects or units
    local second = (kind == "O") and units or objects
    local n = first and first[id]
    if not (type(n) == "string" and n ~= "") then n = second and second[id] end
    if type(n) == "string" and n ~= "" then return n end
    return nil
end

-- WHO STARTS A QUEST - FROM DATA, NOT FROM A CLIENT FLAG.
--
-- Giver discovery asks the client for a dialog status (CGObject+0x90). That is a
-- UNIT field, so a quest-starting OBJECT - a scroll, a crate, a bulletin board -
-- answers nothing and is silently ignored, however close it is. It is also the
-- flaky read that only answers ~6% of ticks even for npcs.
--
-- The database states it outright: quests.data[qid].start.U / .start.O list the
-- npc and object entries that OFFER each quest. Invert that once and any entry
-- in the object manager can be classified with a table lookup - no client call,
-- no flakiness, and objects work exactly as well as npcs.
QuestDB._starts = nil

local function build_starts()
    local db = DBT()
    local quests = db and db.quests and db.quests.data
    if not quests then return nil end
    -- THREE KINDS START QUESTS, NOT TWO. Measured in the shipped data:
    --   U = 7379 npcs, O = 443 objects, I = 173 ITEMS.
    -- Items were missing entirely, which is the whole "a lootable that starts a
    -- quest" case: you loot a pouch, the ITEM begins the quest. An object that
    -- CONTAINS such an item is therefore worth interacting with even though the
    -- object itself starts nothing.
    local u, o, i = {}, {}, {}
    for qid, q in pairs(quests) do
        local st = q and q["start"]
        if st then
            for _, e in pairs(st["U"] or {}) do
                u[e] = u[e] or {}; u[e][#u[e] + 1] = qid
            end
            for _, e in pairs(st["O"] or {}) do
                o[e] = o[e] or {}; o[e][#o[e] + 1] = qid
            end
            for _, e in pairs(st["I"] or {}) do
                i[e] = i[e] or {}; i[e][#i[e] + 1] = qid
            end
        end
    end

    -- Objects that CONTAIN a quest-starting item, from items.data[item].O.
    -- Inverted here so the hot path is a single table read.
    local db2 = DBT()
    local items = db2 and db2.items and db2.items.data
    if items then
        for item_id, qids in pairs(i) do
            local entry = items[item_id]
            for obj_id in pairs((entry and entry.O) or {}) do
                o[obj_id] = o[obj_id] or {}
                for _, qid in ipairs(qids) do o[obj_id][#o[obj_id] + 1] = qid end
            end
            -- DROPPING IS NOT OFFERING. A unit that drops a quest-starting
            -- item is worth KILLING, not talking to - putting it in the giver
            -- index made the engine walk up to a city guard and try to chat.
            -- That belongs to objective selection, not giver discovery, so it
            -- is deliberately not indexed here.
        end
    end
    return { U = u, O = o, I = i }
end

-- Quest ids this entry offers, or nil. kind = "U" (npc) | "O" (object).
function QuestDB.quests_started_by(entry, kind)
    if not (QuestDB.available() and entry) then return nil end
    if not QuestDB._starts then QuestDB._starts = build_starts() end
    local idx = QuestDB._starts
    if not idx then return nil end
    return idx[kind or "U"][tonumber(entry)]
end

-- Does this entry offer a quest we could actually take right now? Excludes ones
-- already in the log or already completed - "available" must mean available.
function QuestDB.offers_new_quest(entry, kind)
    local qids = QuestDB.quests_started_by(entry, kind)
    if not qids then return false end
    for _, qid in ipairs(qids) do
        local have = false
        if RaijinLab.QuestLog and RaijinLab.QuestLog.has_quest then
            have = RaijinLab.QuestLog.has_quest(qid) and true or false
        end
        local done = false
        if IsQuestFlaggedCompleted then
            local okc, v = pcall(IsQuestFlaggedCompleted, qid)
            done = okc and v and true or false
        end
        if not have and not done then return true, qid end
    end
    return false
end

-- Nearest known world point for an objective, by name. Tries mob first (kill
-- objectives name the mob), then item (collect objectives name the drop).
-- `seen` is a list of points already visited for this objective. A mob is not
-- always standing on the first spawn we walk to, and a database point that
-- yielded nothing must not be chosen again forever - that is a deterministic
-- dead end exactly as bad as a guessed one. Skipping them walks the spawn list
-- in nearest-first order until perception finds the target.
function QuestDB.locate(name, px, py, seen)
    if not name then return nil end
    local best, bestd = nil, huge
    local function visited(p)
        for _, v in ipairs(seen or {}) do
            if math.sqrt((p.x - v.x) ^ 2 + (p.y - v.y) ^ 2) < (QuestDB.SPAWN_SAME or 25) then
                return true
            end
        end
        return false
    end
    local function consider(list)
        for _, p in ipairs(list or {}) do
            if not visited(p) then
                local d = (px and py) and math.sqrt((p.x - px) ^ 2 + (p.y - py) ^ 2) or 0
                if d < bestd then best, bestd = p, d end
            end
        end
    end
    consider(QuestDB.mob_spawns(name))
    if not best then consider(QuestDB.item_sources(name)) end
    if not best then return nil end
    best.dist = bestd
    return best
end

return QuestDB
