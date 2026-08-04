-- Quest discovery over the object manager (core/objects/*).
--
-- The engine needs three spatial questions answered from live world data:
--   * where is the nearest quest GIVER (yellow "!")            -> nearest_giver("available")
--   * where is the nearest TURN-IN npc  (yellow "?")           -> nearest_giver("complete")
--   * where is the nearest OBJECTIVE the client ties to one of  -> nearest_objective()
--     my active quests (mob to kill / object to use / item drop)
-- All three are pure queries over RaijinLab.om.object_list, which the object
-- manager repopulates ~30 Hz. The OM already computes Info.Quest.IsTiedToQuest
-- per object (client check + tooltip scan in API.lua), which is exactly the
-- "is this thing part of a quest I'm on" signal - so within render range we do
-- NOT need an external coordinate database to find objectives.
--
-- NOTE: the object manager must be running (RaijinLab.om populated). The engine
-- ensures that; these queries return empty/ nil when it isn't.

local QuestOM = {}

-- Forward declaration: _report_probe (defined above status_sets) calls this.
-- Without it the call resolved to a nil GLOBAL and threw, the error was
-- swallowed by the enclosing pcall, and BOTH the giver diagnostic and the
-- probe that feeds status_source_alive died silently.
local status_sets

-- 3.3.5 client DialogStatus (Trinity / Ascension GetQuestInteractType table).
-- ObjectQuestGiverStatus returns these per NPC from CGObject+0x90.
--   0 none, 1 unavailable
--   2 low-level !, 3 low-level ?, 4 low-level ! rep
--   5 incomplete (grey ? - in progress, not a turn-in target)
--   6 reward rep, 7 available rep, 8 available (yellow !)
--   9 reward2, 10 reward (yellow ?)
-- Yellow ! pickup = 7/8 (+ 2/4 grey). Yellow ? turn-in = 9/10 (+ 3/6 grey).
-- Incomplete (5) is intentionally NOT complete - that is "still working on it".
-- Overridable via RaijinLabDB.quest.giver_status.
local DEFAULT_AVAILABLE = { [2] = true, [4] = true, [7] = true, [8] = true }
local DEFAULT_COMPLETE  = { [3] = true, [6] = true, [9] = true, [10] = true }

-- Every status query and every non-zero answer. If asked is high and nonzero is
-- zero, the sensor is not reporting "no quest givers here" - it is not reporting.
QuestOM._status_asked = 0
QuestOM._status_nonzero = 0

-- WHICH statuses came back, not just how many were non-zero.
--
-- "asked=18694 nonzero=512" alongside "pick no_giver" is a contradiction the
-- counters cannot resolve: 512 real answers and not one giver. It matters
-- enormously whether those were 8s (available - a policy bug) or 1s and 5s
-- (unavailable / in-progress - correct, and the givers are simply elsewhere).
-- One histogram answers it; guessing cost a whole session.
QuestOM._st_hist = {}

function QuestOM.status_hist_str()
    local parts, n = {}, 0
    for st, c in pairs(QuestOM._st_hist) do
        parts[#parts + 1] = string.format("%d:%d", st, c)
        n = n + 1
    end
    if n == 0 then return "none" end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- Normalize GUID for the runtime (hex string). NEVER tostring(table) - that
-- produced GuidArg fail s='table: 74...' and zeroed every suite status scan.
local function guid_str(g)
    if g == nil then return nil end
    if type(g) == "table" then
        g = g.Guid or g.Object or g.guid or g.GUID
        if g == nil or type(g) == "table" then return nil end
    end
    if type(g) == "string" then
        g = g:match("^%s*(.-)%s*$") or g
        if g == "" or g == "nil" or g == "0" or g == "0x0" or g == "0X0" then
            return nil
        end
        if g:match("^table:") then return nil end
        if g:match("^0[xX]%x+$") then return g end
        if g:match("^%x+$") and #g >= 8 then return "0x" .. g end
        return g
    end
    if type(g) == "number" then
        if g == 0 then return nil end
        return string.format("0x%X", g)
    end
    return nil
end

-- Wrapper so exactly one place decides what a status value means.
-- Returns nil for "cannot tell", never 0-as-an-answer.
-- A QUEST GIVER'S "!" DOES NOT BLINK. THE READ DOES.
--
-- The client only answers GetQuestInteractType while an npc's quest status is
-- currently resolved client-side; the rest of the time it returns 0. Live:
-- asked=7154, nonzero=450 - a real, present, yellow-! giver reads as "nothing"
-- on ~94% of ticks.
--
-- Because 0 was treated as "not a giver", progress_step flipped between
-- `accept:to ? st=8 d=21` and `objective:searching` roughly three times a
-- second. Every flip handed the navigator a brand-new goal, so the character
-- jittered, never closed the last 21 yards to the npc, and never accepted the
-- quest standing next to it. That is the "mindless, sloppy, ignores the quest
-- right there" behaviour, and it is one unstable sensor read underneath.
--
-- So: remember POSITIVE readings only. A 0 is "no answer", never "no quest" -
-- the same rule this project has had to learn repeatedly. The memory is flushed
-- the moment the quest log changes, which is exactly when a status legitimately
-- changes (we accepted it, we turned it in), so a stale "!" cannot survive its
-- own quest.
local function now() return (GetTime and GetTime()) or 0 end

QuestOM._st_cache = {}
QuestOM._st_logn = nil
QuestOM.STATUS_TTL = 6.0
-- Re-query native status often enough for live !/? flips; C++ 128-slot cache
-- absorbs the burst so more revalidations stay cheap.
QuestOM.STATUS_REVALIDATE = 0.6

local function status_cache_epoch()
    -- Accepting or handing in a quest is what changes a giver's mark, and both
    -- change the log. Cheap to read, and it makes invalidation exact rather than
    -- a guess about timing.
    local n = GetNumQuestLogEntries and select(1, GetNumQuestLogEntries()) or 0
    if n ~= QuestOM._st_logn then
        QuestOM._st_logn = n
        QuestOM._st_cache = {}
    end
end

function QuestOM.forget_status(guid)
    local g = guid_str(guid)
    if g then QuestOM._st_cache[g] = nil end
end

function QuestOM.giver_status(obj)
    local f = RaijinLab and RaijinLab.ObjectQuestGiverStatus
    if not f then return nil end
    local g = guid_str(obj)
    if not g then return nil end
    status_cache_epoch()
    local t = now()
    -- Serve hot cache first. Live: every nearest_giver scan re-queried all NPCs
    -- every suite tick (gstat_asked 35k+) -> main lag source. TTL still allows
    -- re-validation so !/? changes are not stuck for the full window.
    local c = QuestOM._st_cache[g]
    local ttl = QuestOM.STATUS_TTL or 6.0
    local reval = QuestOM.STATUS_REVALIDATE or 1.5
    if c and c.st and (t - c.t) <= reval then
        return c.st
    end
    local ok, st = pcall(f, RaijinLab, g)
    if not ok then
        if c and (t - c.t) <= ttl then return c.st end
        return nil
    end
    QuestOM._status_asked = QuestOM._status_asked + 1
    st = tonumber(st)
    -- UNIT_NPC_FLAGS IS THE RELIABLE GIVER SIGNAL ON THIS BUILD (2026-08-03).
    --
    -- Measured live over 147 objects: ObjectNpcFlags found TEN quest givers
    -- (QUESTGIVER bit 0x2 set, e.g. nf=14) while ObjectQuestGiverStatus
    -- returned 0 for every single one - which is exactly the quester's
    -- "scan=33/status0/db0/spark0" and why it found no giver to walk to.
    -- CGObject+0x90 either is not the status field on this client or is only
    -- populated after the server answers a status query we never trigger.
    --
    -- The flag is a DESCRIPTOR field that is always present, so it answers
    -- "this NPC gives quests" with certainty. It cannot distinguish available
    -- (!) from turn-in (?) - the status byte's job - so the status value still
    -- wins whenever it is non-zero; the flag only rescues the case where the
    -- status is silent, instead of reporting "no giver" and standing still.
    if (not st or st == 0) and RaijinLab.ObjectNpcFlags then
        local okn, nf = pcall(RaijinLab.ObjectNpcFlags, RaijinLab, g)
        nf = okn and tonumber(nf) or nil
        if nf and math.floor(nf / 2) % 2 == 1 then
            QuestOM._giver_by_flag = (QuestOM._giver_by_flag or 0) + 1
            -- AVAILABLE_UNKNOWN: a giver we know exists but whose ! / ? state
            -- the client has not told us. Callers treat it as "worth
            -- approaching", which is the honest action.
            local FLAG_ST = QuestOM.STATUS_FLAG_ONLY or 7
            QuestOM._st_cache[g] = { st = FLAG_ST, t = t }
            return FLAG_ST
        end
    end
    if st and st ~= 0 then
        QuestOM._status_nonzero = QuestOM._status_nonzero + 1
        QuestOM._st_hist[st] = (QuestOM._st_hist[st] or 0) + 1
        QuestOM._st_cache[g] = { st = st, t = t }
        return st
    end
    -- No answer this tick: fall back to what this npc last actually told us.
    if c and (t - c.t) <= ttl then
        return c.st
    end
    return nil
end

-- IS THE STATUS SENSOR ALIVE? THREE-VALUED, AND PROOF BEATS STATISTICS.
--
-- The first version answered "dead" after 400 all-zero queries. That conflates
-- two very different worlds: a broken sensor, and a perfectly good sensor in an
-- area that genuinely has no quest givers. A bigger threshold is a bigger
-- number, not better evidence - and it was wrong enough to make three quest-
-- engine tests fail by sending the bot off to greet npcs instead of killing the
-- wolf it was sent to kill.
--
-- There is a proof available. When a quest frame OPENS for an npc, that npc is
-- definitively a quest giver - the client said so, no runtime read involved. If
-- the sensor reported nothing for that same npc, it is broken, and one such
-- observation settles it forever. No sample size, no false accusation.
--
-- witnessed_dead is therefore the primary signal. The counters remain only as a
-- weak secondary hint for the search path, which probes deliberately and can
-- afford to be wrong (its worst case is walking to an npc and saying hello).
QuestOM._witnessed_dead = false

-- Called from QuestFrame when a quest dialog opens: we KNOW this one is a giver.
function QuestOM.witness_giver(guid)
    if not guid then return end
    if QuestOM._witnessed_dead then return end
    local st = QuestOM.giver_status(guid)
    if st and st ~= 0 then
        -- sensor saw it too: it works, and that outranks any accumulated doubt
        QuestOM._status_nonzero = QuestOM._status_nonzero + 1
        return
    end
    QuestOM._witnessed_dead = true
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.warn then
        Tel.warn("quest", "giver_sensor_dead",
            { note = "a quest frame opened for an npc the status call reports as 0" })
    end
end

-- Deliberate probe of the npcs actually in front of us. Only the SEARCH path
-- calls this, because only the search path has earned the right to conclude
-- anything from a run of zeros: it is looking for a giver and finding none.
QuestOM.PROBE_ROUNDS = 6          -- consecutive all-zero sweeps before we accept it

function QuestOM.probe_sensor()
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not (om and om.npcs) then return end
    local seen, hit = 0, 0
    local dist = {}
    for i = 1, #om.npcs do
        local g = om.npcs[i] and om.npcs[i].Guid
        if g then
            seen = seen + 1
            -- raw value, NOT giver_status(): we need to see the 0s too, because
            -- "all zero" and "non-zero but unmatched" are different defects
            local raw = 0
            if RaijinLab.ObjectQuestGiverStatus then
                local ok, v = pcall(RaijinLab.ObjectQuestGiverStatus, RaijinLab, g)
                raw = (ok and tonumber(v)) or 0
            end
            dist[raw] = (dist[raw] or 0) + 1
            local st = QuestOM.giver_status(g)
            if st and st ~= 0 then hit = hit + 1 end
        end
    end
    if seen == 0 then
        -- An empty npc list is itself a finding: it means the object manager has
        -- nothing to offer and no amount of status-reading will help.
        QuestOM._diag_empty = (QuestOM._diag_empty or 0) + 1
        QuestOM._report_probe(0, 0, nil)
        return
    end
    QuestOM._report_probe(seen, hit, dist)
    if hit > 0 then
        QuestOM._probe_rounds = 0
        return
    end
    QuestOM._probe_rounds = (QuestOM._probe_rounds or 0) + 1
end

-- SELF-REPORTING, BECAUSE ASKING A HUMAN TO RUN A DIAGNOSTIC IS NOT A DIAGNOSTIC.
--
-- The engine sat in turnin:searching for hundreds of samples while nothing said
-- WHY: whether the npc list was empty, whether statuses came back zero, or
-- whether they came back non-zero but matched none of the configured code sets.
-- Those three have completely different fixes and were indistinguishable from
-- the log, so every diagnosis needed a human to run /raijin quest givers.
--
-- Now the search path prints the actual distribution on a slow cadence. One log
-- line separates "the runtime is blind", "the OM is empty" and "the codes are
-- wrong" - which are the only three things this can be.
function QuestOM._report_probe(seen, hit, dist)
    local DL = RaijinLab and RaijinLab.DevLog
    if not (DL and DL.log_every) then return end
    local parts = {}
    if dist then
        for st, n in pairs(dist) do parts[#parts + 1] = tostring(st) .. "x" .. tostring(n) end
        table.sort(parts)
    end
    local avail, comp = status_sets()
    local aset, cset = {}, {}
    for k in pairs(avail) do aset[#aset + 1] = tostring(k) end
    for k in pairs(comp) do cset[#cset + 1] = tostring(k) end
    table.sort(aset); table.sort(cset)
    DL.log_every("qg_probe", 5.0, "quest",
        "giver-probe npcs=%d nonzero=%d statuses={%s} want_avail={%s} want_complete={%s} verdict=%s",
        seen or 0, hit or 0,
        table.concat(parts, ","),
        table.concat(aset, ","), table.concat(cset, ","),
        tostring(QuestOM.status_source_alive()))
end

function QuestOM.status_source_alive()
    if QuestOM._status_nonzero > 0 then return true end     -- it answered once: it works
    if QuestOM._witnessed_dead then return false end        -- proven against a real giver
    if (QuestOM._probe_rounds or 0) >= QuestOM.PROBE_ROUNDS then return false end
    -- WEIGHT OF EVIDENCE, restored deliberately and set high.
    --
    -- The proof paths above are the strong signals, but both need something to
    -- happen first: a dialog needs us to walk up to an npc, and the probe rounds
    -- need the search path to run. Live, neither fired - so the verdict stayed
    -- "unknown" forever and the candidate fallback never opened, while the
    -- runtime had answered 0 to TEN THOUSAND queries in a row. Refusing to
    -- conclude from that is not caution, it is ignoring the evidence.
    --
    -- 500 is far above anything a legitimate quiet area produces in a single
    -- session, and far below what a live client reaches in seconds - which is
    -- why the engine tests (one tick, a handful of npcs) never trip it.
    if QuestOM._status_asked >= 500 and QuestOM._status_nonzero == 0 then
        return false
    end
    return nil                                              -- not enough to say
end

function status_sets()
    local c = (RaijinLabDB and RaijinLabDB.quest and RaijinLabDB.quest.giver_status) or {}
    return c.available or DEFAULT_AVAILABLE, c.complete or DEFAULT_COMPLETE
end

local function ppos()
    if RaijinLab and RaijinLab.ObjectPosition then return RaijinLab:ObjectPosition("player") end
end

local function unit_pos(guid)
    if not (guid and RaijinLab and RaijinLab.ObjectPosition) then return nil end
    local ok, x, y, z = pcall(RaijinLab.ObjectPosition, RaijinLab, guid)
    if not (ok and x and y) then return nil end
    -- DO NOT RE-JUDGE THE COORDINATE HERE. This carried its own copy of the
    -- "an axis under 30 is garbage" rule, which is only true because Azeroth's
    -- zones sit far from the origin - as an absolute test it makes every object
    -- near (0,0) invisible, so nearest_by_id and every objective lookup returned
    -- nil there.
    --
    -- ObjectPosition is already the single place that validates a reading (it
    -- cross-checks against the camera and refuses garbage). A second, weaker
    -- copy of that judgement downstream can only disagree with the authority -
    -- and here it did, silently discarding positions the guard had accepted.
    return x, y, z
end

local function dist_of(struct, px, py, pz)
    if not (px and struct and struct.Guid) then return nil end
    local x, y, z = unit_pos(struct.Guid)
    if not x then return nil end
    local dx, dy, dz = px - x, py - y, (pz or 0) - (z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Every npc + gameobject the client flags as an active-quest objective, nearest
-- first. opts: { name = only this Name, max_dist = yd cap, include_dead = bool }.
function QuestOM.list_objectives(opts)
    opts = opts or {}
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om then return {} end
    local px, py, pz = ppos()
    local out = {}
    local function consider(list, kind)
        for i = 1, #(list or {}) do
            local s = list[i]
            -- 0 IS TRUTHY IN LUA. The bridge's ObjectIsQuestObjective stub
            -- returns a hard 0, so a bare truthiness test here matched EVERY
            -- npc, chair, mailbox and campfire in render range, and
            -- nearest_objective handed the engine whatever was physically
            -- closest to walk into. Normalised at the source now, but this
            -- stays defensive: one stale cached struct must not resurrect it.
            local tied = s and s.Info and s.Info.Quest and s.Info.Quest.IsTiedToQuest
            tied = (tied and tied ~= 0) and true or false
            -- THE QUEST LOG IS AUTHORITATIVE. IsTiedToQuest IS NOT AVAILABLE.
            --
            -- The client flag was the ONLY way in, and it cannot answer: the
            -- bridge's ObjectIsQuestObjective is unimplemented (returns nil), the
            -- GameObject fallback only covers objects, and the tooltip scan needs
            -- a unit TOKEN so it cannot speak for an arbitrary GUID in the world.
            -- So `tied` is false for everything, list_objectives returned {} with
            -- 143 npcs in the snapshot, and the engine fell through to a
            -- belief-field sweep - "objective found=none" while the target stood
            -- in render range.
            --
            -- But when the caller passes opts.name it has read the objective out
            -- of the QUEST LOG - a perfect, local, always-available source that
            -- literally names the thing. A unit called "Scavenger" while the log
            -- says "Scavenger: 0/8" IS the objective, whatever a missing client
            -- flag thinks. Name match is therefore an INDEPENDENT source, not a
            -- filter applied after an unavailable sensor has emptied the set.
            --
            -- Same shape as the navmesh fix: an authoritative offline source was
            -- subordinated to a sensor that cannot answer.
            local name_match = false
            if opts.name and s and s.Name then
                name_match = (s.Name == opts.name)
                if not name_match then
                    -- "Scavenger" matches "Ragged Scavenger"; objective text is
                    -- often the bare noun while the mob carries a modifier.
                    name_match = (string.find(s.Name, opts.name, 1, true) ~= nil)
                end
            end
            if tied or name_match then
                local ok = true
                if kind == "unit" and s.Info.Unit and s.Info.Unit.Dead and not opts.include_dead then
                    ok = false
                end
                -- A named request still excludes anything that does not match it;
                -- an unnamed request keeps the old client-flag behaviour.
                if opts.name and not name_match then ok = false end
                if ok then
                    local d = dist_of(s, px, py, pz)
                    if (not opts.max_dist) or (d and d <= opts.max_dist) then
                        out[#out + 1] = {
                            struct = s, name = s.Name, id = s.Id, guid = s.Guid,
                            kind = kind, dist = d or math.huge,
                        }
                    end
                end
            end
        end
    end
    consider(om.npcs, "unit")
    consider(om.gameobjects, "object")
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

function QuestOM.nearest_objective(opts)
    return QuestOM.list_objectives(opts)[1]
end

-- Nearest quest giver whose dialog status is in `want` ("available"|"complete").
--
-- Status comes ONLY from the client field CGObject+0x90 (ObjectQuestGiverStatus
-- runtime). No name heuristics, no inventing "available" from NpcFlags.
-- Codes: 7/8 = available (!), 9/10 = reward (?). See QuestOM status constants.
--
-- ALSO scans GetNpcWithIndex as a second source: the OM filtered list has
-- been empty/stale while the runtime still had live units with st=8/10, which
-- is exactly how the suite fell into belief-field "random direction" search
-- next to a lit yellow ? it could not see.
-- Dual-result scan cache: progress_step asks complete then available back-to-back.
-- One world pass fills both winners so the second call is free (same accuracy).
QuestOM._giver_pair = nil
QuestOM.GIVER_PAIR_TTL = 0.40

function QuestOM.nearest_giver(want, opts)
    opts = opts or {}
    local tnow = now()
    local pair = QuestOM._giver_pair
    if pair and (tnow - pair.t) <= (QuestOM.GIVER_PAIR_TTL or 0.40)
        and not (opts and opts.allow_candidates)
        and not (opts and opts.no_cache) then
        if want == "complete" then return pair.complete end
        if want == "available" then return pair.available end
    end
    -- Refresh the snapshot before reading it. It had no producer at all, so
    -- every scan below iterated an empty table and the engine saw no npcs.
    if RaijinLab and RaijinLab.om and RaijinLab.om.refresh then
        pcall(RaijinLab.om.refresh)
    end
    local avail, complete = status_sets()
    local set = (want == "complete") and complete or avail
    local px, py, pz = ppos()
    -- Track BOTH live winners in one pass (more answers, half the world walks).
    local best_a, best_c = nil, nil
    local best_guid, best_name, best_id, bestd, best_st = nil, nil, nil, math.huge, nil
    local best_ev = nil        -- why the winner was promoted (status/db/flag)
    local best_x, best_y, best_z = nil, nil, nil
    local seen = {}

    -- WHY NOTHING WAS PICKED, not just that nothing was.
    -- "no_giver" with no numbers cost a round trip per hypothesis all session.
    QuestOM._scan = { seen = 0, status = 0, db = 0, spark = 0, nopos = 0, far = 0 }
    -- EVIDENCE IS PART OF THE ANSWER.
    --
    -- Three very different things can promote a candidate: the client's own
    -- dialog status ("status"), a database quest entry ("db"), or a dynamic-flag
    -- bit read while the SPARKLE/ACTIVATE mapping is still unproven ("flag").
    -- They deserve different treatment - a silent interact on a flag-only guess
    -- disproves it, while for a real giver it usually means range or timing -
    -- and a caller that cannot tell them apart must treat them all as certain.
    local function pack(g, name, id, d, st, x, y, z, evidence)
        return {
            guid = g, name = name, id = id, dist = d,
            status = st, x = x, y = y, z = z,
            evidence = evidence,
        }
    end
    local function consider_guid(guid, name, id, sx, sy, sz, kind, struct)
        local g = guid_str(guid)
        if not g or seen[g] then return end
        seen[g] = true
        QuestOM._scan.seen = QuestOM._scan.seen + 1
        local st = QuestOM.giver_status(g)
        local ok_status = st and set[st]
        local ok_avail = st and avail[st]
        local ok_comp = st and complete[st]
        local evidence = (ok_status or ok_avail or ok_comp) and "status" or nil
        if ok_status then QuestOM._scan.status = QuestOM._scan.status + 1 end

        -- THE DATABASE IS A SECOND, INDEPENDENT WITNESS.
        --
        -- giver_status reads the client's dialog flag at CGObject+0x90, which is
        -- a UNIT field: a quest-starting OBJECT - a scroll, a crate, a bulletin
        -- board - answers nothing and was silently skipped however close it was.
        -- It is also the read that only answers on ~6% of ticks even for npcs.
        --
        -- RaijinQuest states which entries OFFER each quest, so an entry that
        -- starts a quest we do not have and have not completed IS an available
        -- giver - no client call, and objects work exactly as well as npcs.
        -- Only for "available": a turn-in depends on quest STATE, which the
        -- database cannot know.
        -- OBJECTS ONLY. For an NPC the client's dialog status is the
        -- authority - it knows level, prerequisites and faction, none of which
        -- the database can judge. Promoting npcs from the tables meant any guard
        -- whose entry appears as a quest starter ANYWHERE became "available", so
        -- the bot walked up to a nameless city guard and tried to talk to it.
        -- Objects are different: their status field does not exist, so the
        -- database (and the sparkle below) is the only witness available.
        -- Dual-scan: always evaluate available-side witnesses so one pass can
        -- fill both complete and available winners (progress_step asks both).
        if not ok_avail and id and kind == "O" then
            local QDB = RaijinLab and RaijinLab.QuestDB
            if QDB and QDB.offers_new_quest then
                local okq, offers = pcall(QDB.offers_new_quest, id, kind or "U")
                if okq and offers then
                    QuestOM._scan.db = QuestOM._scan.db + 1
                    evidence = evidence or "db"
                    ok_avail = true; st = st or 8
                    if want == "available" then ok_status = true end
                end
            end
        end

        -- THIRD WITNESS: THE CLIENT'S OWN SPARKLE.
        --
        -- The database cannot know about a server's CUSTOM objects - Ascension
        -- ships world objects pfQuest has never heard of, and a lootable pouch
        -- that begins a quest is exactly that case. But the client marks objects
        -- it wants you to interact with: GO_DYNFLAG_LO_SPARKLE (0x20) is the
        -- sparkle you can see on screen, and ACTIVATE (0x04) means interaction is
        -- enabled.
        --
        -- So: a sparkling, activatable gameobject is worth approaching even when
        -- nothing in the tables mentions it. This is client TRUTH about this
        -- object right now, it needs no per-item knowledge, and it generalises to
        -- every quest in the game including ones that do not exist upstream.
        if not ok_avail and kind == "O" and struct then
            local dyn = struct.DynamicFlags and struct.DynamicFlags.value
            if type(dyn) == "number" then
                local G = RaijinLab.GOFlags
                if G then G.observe(dyn) end
                local interesting = G and G.worth_approaching(dyn) or false
                if interesting == true then
                    QuestOM._scan.spark = QuestOM._scan.spark + 1
                    -- Weakest of the three: a bit whose meaning is not settled.
                    evidence = evidence or "flag"
                    ok_avail = true
                    st = st or 8
                    if want == "available" then ok_status = true end
                end
            end
        end
        -- Dual winners: continue if this guid is useful for either role.
        if not ok_status and not ok_avail and not ok_comp then return end
        local d = math.huge
        local x, y, z = sx, sy, sz
        if not x and RaijinLab.ObjectPosition then
            local okp, xx, yy, zz = pcall(RaijinLab.ObjectPosition, RaijinLab, g)
            if okp and xx then x, y, z = xx, yy, zz end
        end
        if x and px then
            local dx, dy, dz = px - x, py - y, (pz or 0) - (z or 0)
            d = math.sqrt(dx * dx + dy * dy + dz * dz)
        else
            -- A GIVER WE CANNOT LOCATE IS NOT A GIVER. No fake dist=5.
            QuestOM._scan.nopos = QuestOM._scan.nopos + 1
            return
        end
        if ok_status and d < bestd then
            best_guid, best_name, best_id, bestd, best_st = g, name, id, d, st
            best_x, best_y, best_z = x, y, z
        end
        if ok_avail and (not best_a or d < best_a.dist) then
            best_a = pack(g, name, id, d, st, x, y, z)
        end
        if ok_comp and (not best_c or d < best_c.dist) then
            best_c = pack(g, name, id, d, st, x, y, z)
        end
    end

    -- 1) OM list (fast, named).
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if om then
        local function consider_list(list, kind)
            for i = 1, #(list or {}) do
                local s = list[i]
                if s then
                    consider_guid(s.Guid or s.Object, s.Name, s.Id, s.x, s.y, s.z, kind, s)
                end
            end
        end
        consider_list(om.npcs, "U")
        consider_list(om.gameobjects, "O")
    end

    -- 2) Direct unit index scan (authoritative when OM filter missed givers).
    if RaijinLab.GetNpcCount and RaijinLab.GetNpcWithIndex then
        local okc, n = pcall(function() return RaijinLab:GetNpcCount() end)
        n = (okc and tonumber(n)) or 0
        if n > 80 then n = 80 end   -- cap frame cost
        for i = 1, n do
            local okg, guid = pcall(function() return RaijinLab:GetNpcWithIndex(i) end)
            if okg and guid then consider_guid(guid, nil, nil, nil, nil, nil) end
        end
    end

    -- Prefer dual-pass winners; fall back to single-want best for this call.
    if want == "complete" and not best_c and best_guid then
        best_c = pack(best_guid, best_name, best_id, bestd, best_st, best_x, best_y, best_z, best_ev)
    end
    if want == "available" and not best_a and best_guid then
        best_a = pack(best_guid, best_name, best_id, bestd, best_st, best_x, best_y, best_z, best_ev)
    end
    QuestOM._giver_pair = {
        t = tnow, complete = best_c, available = best_a, scanned = true,
    }
    local result = (want == "complete") and best_c or best_a
    if not result and best_guid then
        result = pack(best_guid, best_name, best_id, bestd, best_st, best_x, best_y, best_z, best_ev)
    end
    if result then
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel and Tel.every then
            Tel.every("quest:live_giver", 3.0, "quest", 3, "live_giver",
                { want = tostring(want), st = result.status, dist = math.floor(result.dist or 0),
                  name = tostring(result.name or "?"), guid = tostring(result.guid) })
        end
        return result
    end

    -- FALLBACK: THE STATUS SENSOR IS DEAD, SO ASK THE NPC DIRECTLY.
    --
    -- ObjectQuestGiverStatus is `return PushNumber(L, 0)` in the runtime for
    -- every object, so the loop above can never match and this function returned
    -- nil forever. Observed live: the bot held a COMPLETED quest ("Rude
    -- Awakening"), entered turnin:searching, and swept belief-field legs across
    -- the zone hunting a turn-in npc it is structurally blind to - which reads as
    -- "it just ran off into the woods in a random direction". Meanwhile quest
    -- givers stood next to it unaccepted, and world memory stayed at poi=1
    -- because observe() only records what THIS function finds.
    --
    -- Detecting the dead sensor is not enough; questing has to work anyway. The
    -- client itself is the authority we still have: open a dialog and it tells
    -- us definitively. So when the sensor is provably dead, nominate the nearest
    -- npc we have not already ruled out and let the dialog adjudicate.
    -- QuestFrame records a giver/turnin POI the moment a quest frame opens, so
    -- every success permanently seeds the memory this fallback exists to
    -- bootstrap - it gets cheaper the longer it runs.
    --
    -- Guarded by status_source_alive() == false specifically: while the sensor
    -- works, or while we cannot yet tell, we must NOT go poking every npc in
    -- sight. false here is a measured verdict (400 queries, none non-zero), not
    -- an assumption.
    -- Deliberately NOT called from here by default. nearest_giver runs in
    -- PRIORITY position - the engine asks it before deciding to do anything
    -- else - so nominating a guess here made the bot walk off to greet a random
    -- npc instead of killing the wolf it had been sent to kill. Three quest-
    -- engine tests caught exactly that, and they were right to.
    --
    -- The fallback belongs at the point where the engine has genuinely run out
    -- of better ideas: the belief-field sweep. Suite asks for it explicitly
    -- there via opts.allow_candidates.
    --
    -- Caller already decided live status did not produce a target (Suite
    -- do_turnin / travel_to_memory). Always honour allow_candidates here -
    -- gating on sensor-dead / probe rounds left us belief-searching while a
    -- greetable QUESTGIVER NPC stood five yards away.
    if opts and opts.allow_candidates then
        return QuestOM.candidate_giver(px, py, pz)
    end
    return nil
end

-- NPCs we have interacted with that produced no quest frame. Without this the
-- fallback re-nominates the same closest npc forever and the bot stands in front
-- of one guard for the rest of the session.
QuestOM._ruled_out = {}
QuestOM.RULE_OUT_FOR = 900        -- secs; re-try eventually, quests do appear later
QuestOM.CANDIDATE_MAX = 60        -- yd; only npcs we could actually walk to and greet

local function _now()
    return (GetTime and GetTime()) or 0
end

function QuestOM.rule_out(guid, why)
    if not guid then return end
    QuestOM._ruled_out[tostring(guid)] = _now()
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.every then
        Tel.every("quest:ruleout", 10, "quest", 4, "ruled_out",
            { guid = tostring(guid), why = tostring(why or "no_quest") })
    end
end

function QuestOM.is_ruled_out(guid)
    local t = QuestOM._ruled_out[tostring(guid or "")]
    if not t then return false end
    if (_now() - t) > QuestOM.RULE_OUT_FOR then
        QuestOM._ruled_out[tostring(guid)] = nil
        return false
    end
    return true
end

-- ---- "would greeting this thing be a mistake?" ---------------------------
--
-- The reject rule here used to read s.Info.Unit.Hostile. The object manager
-- writes Dead / Hidden / Rare / Lootable onto Info.Unit and nothing else (see
-- core/objects/Manager.lua), so Hostile was nil for every npc that has ever
-- existed: a guard that could not fire, in front of the one decision that
-- walks the bot across the map. The fallback was free to nominate the nearest
-- wolf as a quest giver and go say hello to it.
--
-- There is no 3.3.5 api that takes a raw guid and answers "is this hostile".
-- UnitReaction / UnitIsFriend / UnitCanAttack all want a unit TOKEN, and the
-- only tokens that can name an arbitrary world object are the ones the client
-- is already pointing at. So the answer is three-valued - friendly, hostile,
-- or nil for "we could not ask" - and nil must never be spent as friendly.
local DISPOSITION_TOKENS = { "target", "mouseover", "focus", "npc" }

-- One sweep of the client's tokens, reused for the whole npc list; asking per
-- npc would repeat the same four api calls for every object in render range.
local function live_tokens()
    local map = {}
    if not UnitGUID then return map end
    for i = 1, #DISPOSITION_TOKENS do
        local t = DISPOSITION_TOKENS[i]
        local ok, g = pcall(UnitGUID, t)
        -- Case-insensitive: the struct guid is read by the injected runtime and
        -- the token guid by the client api; only the value is guaranteed to
        -- agree between the two producers.
        if ok and g then map[tostring(g):lower()] = t end
    end
    return map
end

-- "friendly" | "hostile" | nil (cannot tell), plus where the answer came from.
function QuestOM.disposition(s, tokens)
    local guid = s and s.Guid
    local tok = nil
    if guid then
        tokens = tokens or live_tokens()
        tok = tokens[tostring(guid):lower()]
    end
    if tok then
        -- NO ASSUMPTION IN THIS BRANCH: the client is answering about this exact
        -- unit, because we hold a token that names it.
        if UnitCanAttack then
            local ok, can = pcall(UnitCanAttack, "player", tok)
            -- 1/nil on 3.3.5, and a wrapper that hands back a numeric 0 means NO.
            if ok and can and can ~= 0 then return "hostile", "can_attack" end
        end
        if UnitIsFriend then
            local ok, fr = pcall(UnitIsFriend, "player", tok)
            if ok and fr and fr ~= 0 then return "friendly", "is_friend" end
        end
        if UnitReaction then
            local ok, r = pcall(UnitReaction, "player", tok)
            r = ok and tonumber(r) or nil
            if r and r <= 3 then return "hostile", "reaction" end
            if r and r >= 5 then return "friendly", "reaction" end
            -- Reaction 4 is NEUTRAL: attackable, yet plenty of genuine quest
            -- givers are neutral. Neither verdict is defensible, so say nothing
            -- rather than pick the convenient one.
            if r then return nil, "neutral" end
        end
    end
    -- ASSUMPTION: a unit the server flags as unattackable-by-players is not
    -- something combat would ever be sent at. This is the OM's own copy of the
    -- unit flag mask (Manager.lua fills Flags.list from RaijinLab.enums.
    -- UnitFlags), not an invented field, and it is the only disposition signal
    -- available without a token.
    local fl = s and s.Flags and s.Flags.list
    if fl and (fl.UNIT_FLAG_IMMUNE_TO_PC or fl.UNIT_FLAG_NON_ATTACKABLE
               or fl.UNIT_FLAG_NOT_ATTACKABLE_1) then
        return "friendly", "unit_flags"
    end
    return nil, "no_token"
end

-- Marks the object manager DOES populate that describe fight material or a unit
-- the client will not let us talk to. Cheap, token-free, and independent of
-- disposition - which matters because disposition is usually unknown.
local function unsuitable(s)
    local u = s and s.Info and s.Info.Unit
    if u then
        if u.Rare then return "rare" end            -- a rare spawn is a kill, not a giver
        if u.Lootable then return "lootable" end    -- something died here
        if u.Skinnable then return "skinnable" end
    end
    local fl = s and s.Flags and s.Flags.list
    if fl then
        if fl.UNIT_FLAG_IN_COMBAT then return "in_combat" end
        if fl.UNIT_FLAG_NOT_SELECTABLE then return "not_selectable" end
    end
    return nil
end

-- Names we have watched a quest dialog open for. QuestFrame records a giver /
-- turnin POI on every accept and turn-in, and that is the one giver signal in
-- this addon no stub can fake: the client showed the frame. Matching on it lets
-- an unknown-disposition npc be nominated on evidence instead of on hope.
local function dialog_names()
    local P = RaijinLab and RaijinLab.POI
    if not (P and P.list) then return nil end
    local set, found = {}, false
    local kinds = { "giver", "turnin" }
    for i = 1, #kinds do
        local ok, recs = pcall(P.list, kinds[i])
        if ok and type(recs) == "table" then
            for j = 1, #recs do
                local n = recs[j] and recs[j].n
                if n and n ~= "" then set[n] = true; found = true end
            end
        end
    end
    if not found then return nil end
    return set
end

-- REAL client capability bit (UNIT_NPC_FLAG_QUESTGIVER = 0x2). This is NOT a
-- status invent (we never map it to DialogStatus 6/7/8). It only answers "can
-- this unit open a quest dialog at all", which is the correct filter when the
-- DialogStatus field is empty and we must greet to learn ! vs ?.
local function npc_has_questgiver(s)
    if not (s and s.Guid and RaijinLab and RaijinLab.ObjectNpcFlags) then return nil end
    local ok, f = pcall(RaijinLab.ObjectNpcFlags, RaijinLab, s.Guid)
    if not ok then return nil end
    f = tonumber(f) or 0
    -- UNIT_NPC_FLAG_QUESTGIVER = 0x2  (no bitlib: test bit 1)
    return math.floor(f / 2) % 2 == 1
end

-- Nearest living npc worth greeting. Deliberately NOT "nearest object": a
-- gameobject or a critter is not something a quest dialog can come from, and
-- walking to one burns the same time as walking to a real candidate.
--
-- Tiers (highest first):
--   1. UNIT_NPC_FLAG_QUESTGIVER (real client capability bit) + friendly/known
--   2. friendly / previously dialoged name
--   3. QUESTGIVER flag alone
--   4. unverified last resort
function QuestOM.candidate_giver(px, py, pz)
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if RaijinLab and RaijinLab.om and RaijinLab.om.refresh then pcall(RaijinLab.om.refresh) end
    om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list or om
    if not (om and om.npcs) then return nil end
    if not px then px, py, pz = ppos() end
    if not px then return nil end
    local tokens = live_tokens()
    local known = dialog_names()
    local best, bestd, bestwhy = nil, math.huge, nil       -- evidence-backed
    local flagged, flagd = nil, math.huge                  -- QUESTGIVER bit
    local risky, riskyd = nil, math.huge                   -- last resort only
    local nopos_pick, nopos_why = nil, nil                 -- pos unreadable
    for i = 1, #om.npcs do
        local s = om.npcs[i]
        local ok = s and s.Guid ~= nil
        -- A corpse hands out nothing.
        if ok and s.Info and s.Info.Unit and s.Info.Unit.Dead then ok = false end
        if ok and QuestOM.is_ruled_out(s.Guid) then ok = false end
        if ok and unsuitable(s) then ok = false end
        -- AN OBJECTIVE IS NEVER THE GIVER. The client already marks objects tied
        -- to one of our quests, and a mob we were sent to kill is the single most
        -- likely npc to be standing nearby while we look for a turn-in. Without
        -- this the fallback nominated the quest's own target and the bot walked
        -- up to say hello to the wolf instead of killing it - which is exactly
        -- what three quest-engine tests caught.
        -- tied may still arrive as a number from an older cached struct; a
        -- numeric 0 must not read as "this is an objective".
        local tied = s and s.Info and s.Info.Quest and s.Info.Quest.IsTiedToQuest
        if ok and tied and tied ~= 0 then ok = false end
        local disp, why = nil, nil
        if ok then
            disp, why = QuestOM.disposition(s, tokens)
            if disp == "hostile" then ok = false end
        end
        if ok then
            local d = dist_of(s, px, py, pz)
            -- NPC ObjectPosition has been failing after pos-layout harden, which
            -- made d=nil for EVERY unit and zeroed the candidate list while 100+
            -- npcs sat in the OM. When distance is unknown, still accept a
            -- limited number of greets (prefer QUESTGIVER / friendly / named).
            if d and d <= QuestOM.CANDIDATE_MAX then
                local qg = npc_has_questgiver(s)
                if qg and (disp == "friendly" or (known and s.Name and known[s.Name])) then
                    if d < bestd then best, bestd, bestwhy = s, d, (why or "npcflag_qg") end
                elseif disp == "friendly" then
                    if d < bestd then best, bestd, bestwhy = s, d, why end
                elseif known and s.Name and known[s.Name] then
                    if d < bestd then best, bestd, bestwhy = s, d, "dialog_name" end
                elseif qg then
                    if d < flagd then flagged, flagd = s, d end
                elseif d < riskyd then
                    risky, riskyd = s, d
                end
            elseif not d then
                local qg = npc_has_questgiver(s)
                if not nopos_pick and (qg or disp == "friendly"
                    or (known and s.Name and known[s.Name])) then
                    nopos_pick, nopos_why = s, (qg and "npcflag_nopos") or (why or "friendly_nopos")
                elseif not nopos_pick and not qg and disp ~= "hostile" then
                    nopos_pick, nopos_why = s, "unverified_nopos"
                end
            end
        end
    end
    local pick, pickd, pickwhy = best, bestd, bestwhy
    if not pick and flagged then
        pick, pickd, pickwhy = flagged, flagd, "npcflag_questgiver"
    end
    if not pick and nopos_pick then
        -- No coordinates: still return the guid so the suite can Target/Interact.
        pick, pickd, pickwhy = nopos_pick, 5, nopos_why
    end
    if not pick then
        -- ASSUMPTION, and the only one left: nothing here is provably greetable,
        -- so we accept the nearest thing we could not rule out rather than stand
        -- still. The dialog adjudicates, and rule_out() stops it repeating.
        pick, pickd, pickwhy = risky, riskyd, "unverified"
        local Tel = RaijinLab and RaijinLab.Telemetry
        if pick and Tel and Tel.every then
            Tel.every("quest:unverified_candidate", 30, "quest", 3, "greet_unverified",
                { name = tostring(pick.Name), dist = math.floor(pickd or 0) })
        end
    end
    if not pick then return nil end
    return { struct = pick, name = pick.Name, id = pick.Id, guid = pick.Guid,
             dist = pickd, guessed = true, evidence = pickwhy }
end

-- Nearest world object/npc with a specific entry id (for quest scripts / routes
-- that name an exact spawn to visit).
function QuestOM.nearest_by_id(id)
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    local idx = om and om.indexes and om.indexes.id
    local list = idx and idx[id]
    if not list then return nil end
    local px, py, pz = ppos()
    local best, bestd = nil, math.huge
    for i = 1, #list do
        local d = dist_of(list[i], px, py, pz) or math.huge
        if d < bestd then best, bestd = list[i], d end
    end
    if best then
        return { struct = best, name = best.Name, id = best.Id, guid = best.Guid, dist = bestd }
    end
    return nil
end

-- ---- spatial memory ------------------------------------------------------
-- Everything above only sees RENDER RANGE, which is why the engine used to give
-- up with "travel needed" the moment an objective was out of sight. `observe()`
-- writes what we can currently see into the persistent POI store, so a place we
-- have been once can be navigated back to later from anywhere on the continent.
-- Cheap and idempotent: call it on the engine's normal scan cadence.
--
-- Objectives are keyed by NAME (+ entry id), not quest id, because the 3.3.5
-- client's IsTiedToQuest is only a boolean - but the quest log's objective text
-- yields the same name, so name is the reliable join between "what I must do"
-- and "where I saw it".
function QuestOM.observe(opts)
    opts = opts or {}
    local P = RaijinLab and RaijinLab.POI
    if not P then return 0 end
    local n = 0
    for _, o in ipairs(QuestOM.list_objectives({ include_dead = false, max_dist = opts.max_dist })) do
        if o.guid and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition(o.guid)
            if x then
                P.record("objective", { x = x, y = y, z = z, name = o.name, entry = o.id })
                n = n + 1
            end
        end
    end
    for _, want in ipairs({ "available", "complete" }) do
        local g = QuestOM.nearest_giver(want)
        if g and g.guid and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition(g.guid)
            if x then
                P.record(want == "complete" and "turnin" or "giver",
                    { x = x, y = y, z = z, name = g.name, entry = g.id })
                n = n + 1
            end
        end
    end
    return n
end

-- Nearest REMEMBERED objective. Three-valued: unknown = never looked / no POI
-- system; no = looked and nothing matches; yes = payload table.
function QuestOM.remembered_objective_k(name, opts)
    opts = opts or {}
    local Kn = RaijinLab and RaijinLab.Know
    if not name then
        if Kn then return Kn.no("no_name") end
        return nil
    end
    local P = RaijinLab and RaijinLab.POI
    if not P then
        if Kn then return Kn.unknown("no_poi") end
        return nil
    end
    local px, py, pz = ppos()
    if not px then
        if Kn then return Kn.unknown("no_pos") end
        return nil
    end
    local rec, d = P.nearest("objective", px, py, pz, { name = name, max_dist = opts.max_dist })
    if not rec then
        if Kn then return Kn.no("not_remembered") end
        return nil
    end
    local payload = { x = rec.x, y = rec.y, z = rec.z, name = rec.n, entry = rec.e, dist = d, rec = rec }
    if Kn then return Kn.yes(payload, "poi") end
    return payload
end

function QuestOM.remembered_objective(name, opts)
    local k = QuestOM.remembered_objective_k(name, opts)
    if type(k) == "table" and k.state then
        if k.state == "yes" then return k.value end
        return nil
    end
    return k
end

function QuestOM.remembered_giver_k(want, opts)
    opts = opts or {}
    local Kn = RaijinLab and RaijinLab.Know
    local P = RaijinLab and RaijinLab.POI
    if not P then
        if Kn then return Kn.unknown("no_poi") end
        return nil
    end
    local px, py, pz = ppos()
    if not px then
        if Kn then return Kn.unknown("no_pos") end
        return nil
    end
    local kind = (want == "complete") and "turnin" or "giver"
    local rec, d = P.nearest(kind, px, py, pz, { max_dist = opts.max_dist, name = opts.name })
    if not rec then
        if Kn then return Kn.no("not_remembered") end
        return nil
    end
    local payload = { x = rec.x, y = rec.y, z = rec.z, name = rec.n, entry = rec.e, dist = d, rec = rec }
    if Kn then return Kn.yes(payload, "poi") end
    return payload
end

function QuestOM.remembered_giver(want, opts)
    local k = QuestOM.remembered_giver_k(want, opts)
    if type(k) == "table" and k.state then
        if k.state == "yes" then return k.value end
        return nil
    end
    return k
end

if RaijinLab then RaijinLab.QuestOM = QuestOM end
return QuestOM
