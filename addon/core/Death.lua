-- Death - dying, and getting back up again.
--
-- For an unattended character this is the single most important recovery path:
-- every other system can retry, but a ghost that cannot find its corpse is a run
-- that has permanently ended. So the rules here are about never getting stuck:
--
--   * the death position is PERSISTED the moment we die, per character, so a
--     /reload, a relog or a missed tick while dead cannot lose it (the previous
--     in-memory-only version left the ghost stranded at "unknown pos");
--   * the corpse recovery delay is respected instead of spamming RetrieveCorpse;
--   * after enough failed attempts to reach the body we accept the spirit healer
--     and its resurrection sickness, because being alive and weakened beats being
--     a ghost forever;
--   * resurrection sickness is waited out rather than fought through.

local Death = {}

local sqrt, max = math.sqrt, math.max

Death.DEFAULTS = {
    release_delay   = 2.0,    -- s to wait as a corpse before releasing
    arrive          = 20.0,   -- yd from the corpse where retrieval works
    max_attempts    = 6,      -- failed approaches before accepting the spirit healer
    attempt_timeout = 60.0,   -- s per approach before counting it as failed
    use_spirit_healer = true, -- accept sickness rather than stay dead
}

local function now() return (GetTime and GetTime()) or 0 end
-- PERSISTED timestamps must use wall-clock, never GetTime(): GetTime is seconds
-- since the client started, so a value written last session is compared against a
-- clock that has since reset. That made the release delay never elapse (or elapse
-- instantly) after a relog while dead - the exact moment recovery matters most.
local function stamp() return (time and time()) or ((GetTime and GetTime()) or 0) end
-- Elapsed time that is immune to a clock discontinuity: a negative age can only
-- mean the clock restarted, which should reset the timer rather than freeze it.
local function elapsed(t0)
    if not t0 then return 0 end
    local dt = stamp() - t0
    if dt < 0 then return 0 end
    return dt
end

function Death.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.death = RaijinLabDB.death or {}
    local c = RaijinLabDB.death
    for k, v in pairs(Death.DEFAULTS) do if c[k] == nil then c[k] = v end end
    return c
end

-- Per-character persistence: two characters on one account must not inherit each
-- other's corpse.
local function key()
    local n = (UnitName and UnitName("player")) or "?"
    local r = (GetRealmName and GetRealmName()) or "?"
    return n .. "@" .. r
end

local function store()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.death = RaijinLabDB.death or {}
    RaijinLabDB.death.corpses = RaijinLabDB.death.corpses or {}
    return RaijinLabDB.death.corpses
end

-- ---- state ---------------------------------------------------------------

function Death.is_dead_k()
    local Kn = RaijinLab and RaijinLab.Know
    if not UnitIsDeadOrGhost then
        if Kn then return Kn.unknown("no_api") end
        return nil
    end
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    if not ok then
        if Kn then return Kn.unknown("error") end
        return nil
    end
    -- 3.3.5: nil/false = alive when the API exists.
    if dead then
        if Kn then return Kn.yes(true, "dead") end
        return true
    end
    if Kn then return Kn.no("alive") end
    return false
end

function Death.is_dead()
    local k = Death.is_dead_k()
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assume then
        return Kn.assume(k, false, "death:assume_alive_when_unknown")
    end
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

function Death.is_ghost_k()
    local Kn = RaijinLab and RaijinLab.Know
    if not UnitIsGhost then
        if Kn then return Kn.unknown("no_api") end
        return nil
    end
    local ok, ghost = pcall(UnitIsGhost, "player")
    if not ok then
        if Kn then return Kn.unknown("error") end
        return nil
    end
    if ghost then
        if Kn then return Kn.yes(true, "ghost") end
        return true
    end
    if Kn then return Kn.no("not_ghost") end
    return false
end

function Death.is_ghost()
    local k = Death.is_ghost_k()
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assume then
        return Kn.assume(k, false, "death:assume_not_ghost_when_unknown")
    end
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

-- Do we know where the corpse is? unknown = never looked / no store.
function Death.corpse_known_k()
    local Kn = RaijinLab and RaijinLab.Know
    local rec = store()[key()]
    if not rec then
        if Kn then return Kn.no("no_corpse_record") end
        return false
    end
    if not rec.x then
        if Kn then return Kn.unknown("incomplete_record") end
        return nil
    end
    if Kn then return Kn.yes(rec, "recorded") end
    return true
end

-- Record where we died. Called from PLAYER_DEAD (and defensively from the tick,
-- because a death during a loading screen can miss the event).
function Death.note_death(x, y, z)
    if not x and RaijinLab and RaijinLab.ObjectPosition then
        x, y, z = RaijinLab:ObjectPosition("player")
    end
    if not x then return nil end
    local s = store()
    s[key()] = { x = x, y = y, z = z, t = stamp(), attempts = 0,
                 map = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world" }
    return s[key()]
end

-- THE CLIENT ALREADY KNOWS WHERE THE CORPSE IS.
--
-- This only ever read a record written by note_death(), so a ghost whose death
-- the addon did not WITNESS had nowhere to walk: log in dead, /reload while
-- dead, or - live, and this is how it was found - die while the suite is stopped
-- and start it afterwards. Death was detected correctly (`state=death:recovering`)
-- and the character simply stood there, because the destination was nil.
--
-- GetCorpseMapPosition() answers regardless of who was watching. It returns ZONE
-- PERCENTAGES, so it needs the same transform everything else uses; that is now
-- fitted from world observations rather than the player's own map reading, so it
-- is available exactly when we need it.
function Death.corpse_pos()
    local rec = store()[key()]
    if rec then return rec.x, rec.y, rec.z, rec end

    if not (GetCorpseMapPosition and RaijinLab and RaijinLab.QuestDB) then return nil end
    local ok, mx, my = pcall(GetCorpseMapPosition)
    if not (ok and mx and my) then return nil end
    -- (0,0) is what the client returns when it has no corpse to report, and a
    -- corpse at the exact corner of a zone is not a thing worth walking to.
    if mx == 0 and my == 0 then return nil end
    -- THE CORPSE IS IN THE CLIENT MAP'S SPACE, NOT THE DATABASE ZONE'S.
    --
    -- GetCorpseMapPosition returns percentages of the map the client is showing
    -- (GetCurrentMapAreaID), exactly like GetPlayerMapPosition. Converting them
    -- with the zone-fitted transform (Deathknell is 13% x 18% of Tirisfal)
    -- rescaled the distance by roughly 7x, which is how the ghost ran straight
    -- past the body. Use the transform fitted in that same space.
    local Q = RaijinLab.QuestDB
    local wx, wy
    -- EXACT first: the client's own WorldMapArea rectangle. This is the only
    -- path that works while dead, because a ghost reads every npc at (0,0,0)
    -- and nothing can be fitted.
    if Q.map_to_world then
        local oke, a, b = pcall(Q.map_to_world, mx, my)
        if oke and a and b then wx, wy = a, b end
    end
    -- Fitted client-map transform, for any map the dbc does not place.
    local cmid = GetCurrentMapAreaID and GetCurrentMapAreaID()
    if not wx and cmid and Q.client_to_world then
        local okc, a, b = pcall(Q.client_to_world, cmid, mx, my)
        if okc and a and b then wx, wy = a, b end
    end
    if not wx then
        -- Not solved yet. Do NOT fall back to the zone transform: a wrong body
        -- location is worse than admitting we do not know one, because the ghost
        -- will walk confidently to the wrong place and stop.
        return nil
    end
    -- GROUND IT. A map percentage carries no height, and returning a nil z is
    -- not merely incomplete - callers do arithmetic on it and die
    -- ("attempt to perform arithmetic on local 'z'"). The premapped mesh stores a
    -- height per cell, which is exactly the question being asked; a live ground
    -- trace is the fallback, and our own feet are better than nothing.
    local z
    local NG = RaijinLab.NavGrid
    if NG and NG.at then
        local okz, _, h = pcall(NG.at, wx, wy)
        if okz and type(h) == "number" then z = h end
    end
    if not z and RaijinLab.TraceGround then
        local px, py, pz = RaijinLab:ObjectPosition("player")
        local okt, g = pcall(RaijinLab.TraceGround, RaijinLab, wx, wy, (pz or 0) + 50, 3, 200)
        if okt and type(g) == "number" then z = g end
    end
    if not z then
        local _, _, pz = RaijinLab:ObjectPosition("player")
        z = pz or 0
    end
    return wx, wy, z, { source = "client", mx = mx, my = my }
end

function Death.clear()
    store()[key()] = nil
end

-- Seconds until the corpse can be retrieved (0 when ready).
function Death.recovery_delay()
    if GetCorpseRecoveryDelay then
        local ok, d = pcall(GetCorpseRecoveryDelay)
        if ok then return tonumber(d) or 0 end
    end
    return 0
end

-- Are we suffering resurrection sickness? Fighting through it is a fast way to
-- die again, so the caller should simply wait.
function Death.has_sickness()
    if not UnitDebuff then return false end
    for i = 1, 16 do
        local ok, name = pcall(UnitDebuff, "player", i)
        if not ok or not name then break end
        local n = string.lower(tostring(name))
        if n:find("resurrection sickness", 1, true) then return true end
    end
    return false
end

-- ---- the recovery loop ---------------------------------------------------


-- Walk to a remembered spirit healer and accept the resurrection.
-- Returns a status string while working, or NIL when we know of no healer - which
-- matters enormously: the recover goal sits in band 1, so returning a string here
-- forever would hold every slot in the arbiter and freeze the entire bot as a
-- ghost. Returning nil lets the Director fall through and keep playing (as a
-- ghost we can still walk, which tends to carry us toward a graveyard anyway).
function Death.use_spirit_healer(ctx)
    ctx = ctx or {}
    local P = RaijinLab and RaijinLab.POI
    if not P then return nil end
    local px, py, pz
    if RaijinLab.ObjectPosition then px, py, pz = RaijinLab:ObjectPosition("player") end
    if not px then return nil end
    local rec, d = P.nearest("spirit_healer", px, py, pz)
    if not rec then return nil end
    if d and d <= 6 then
        -- In range: take the resurrection (and the sickness).
        local a = RaijinLab.Actions
        if a and a.Interact then pcall(a.Interact) end
        if AcceptXPLoss then pcall(AcceptXPLoss) end
        if RetrieveCorpse then pcall(RetrieveCorpse) end
        return "death:accepting spirit healer"
    end
    if ctx.goto_fn then ctx.goto_fn(rec.x, rec.y, rec.z, 5.0) end
    return string.format("death:to spirit healer (%.0fyd)", d or 0)
end

-- Remember a spirit healer we encounter, so the fallback has somewhere to go.
function Death.note_spirit_healer(x, y, z)
    local P = RaijinLab and RaijinLab.POI
    if not (P and x) then return nil end
    return P.record("spirit_healer", { x = x, y = y, z = z, name = "Spirit Healer" })
end

-- One step of dying/recovering. Returns a status string while it is in control,
-- or nil when we are alive and well (so the caller carries on).
-- ctx.goto_fn(x,y,z,arrive) supplies movement.
function Death.tick(ctx)
    ctx = ctx or {}
    local c = Death.cfg()

    if not Death.is_dead() then
        -- Alive. Clear the corpse record once we are properly back (not a ghost).
        if not Death.is_ghost() then
            if store()[key()] then Death.clear() end
            if Death.has_sickness() then
                -- Weakened: let it tick down rather than pulling something.
                return "death:waiting out resurrection sickness"
            end
        end
        return nil
    end

    -- DEAD AS A CORPSE: remember where, then release.
    if not Death.is_ghost() then
        local rec = select(4, Death.corpse_pos())
        if not rec then rec = Death.note_death() end
        if rec and elapsed(rec.t) < (c.release_delay or 2) then
            return "death:died (releasing shortly)"
        end
        if RepopMe then pcall(RepopMe) end
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then Tel.info("death", "release", {}) end
        return "death:releasing"
    end

    -- GHOST: walk back and retrieve.
    local x, y, z, rec = Death.corpse_pos()
    if not x then
        -- We never captured the position (died during a load screen, or the
        -- record was lost). Rather than stand still forever, take the spirit
        -- healer if we are allowed to - being alive with sickness beats being
        -- stuck as a ghost indefinitely.
        if c.use_spirit_healer then
            local st = Death.use_spirit_healer(ctx)
            if st then return st end
        end
        -- No healer known and no corpse: do NOT hold the band-1 slot with a
        -- status string forever - release so the rest of the stack keeps running.
        return nil
    end

    -- Too many failed approaches: the body is somewhere we cannot reach.
    if (rec.attempts or 0) >= (c.max_attempts or 6) and c.use_spirit_healer then
        local st = Death.use_spirit_healer(ctx)
        if st then return st end
        -- Nowhere to go: release the slot rather than deadlock the arbiter.
        return nil
    end

    local px, py, pz
    if RaijinLab and RaijinLab.ObjectPosition then px, py, pz = RaijinLab:ObjectPosition("player") end
    local d = nil
    if px then d = sqrt((px - x) ^ 2 + (py - y) ^ 2 + ((pz or 0) - (z or 0)) ^ 2) end

    -- Close enough: retrieve, once the server allows it.
    if d and d <= (c.arrive or 20) then
        local delay = Death.recovery_delay()
        if delay > 0 then
            return string.format("death:at corpse, waiting %.0fs", delay)
        end
        if RetrieveCorpse then
            local ok = pcall(RetrieveCorpse)
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel then Tel.info("death", "retrieve", { ok = ok }) end
            if ok then return "death:retrieving corpse" end
        end
        return "death:cannot retrieve"
    end

    -- Walk back. Count the attempt so an unreachable corpse eventually gives up.
    rec.started = rec.started or stamp()
    if elapsed(rec.started) > (c.attempt_timeout or 60) then
        rec.attempts = (rec.attempts or 0) + 1
        rec.started = stamp()
    end
    if ctx.goto_fn then ctx.goto_fn(x, y, z, c.arrive or 20) end
    return string.format("death:corpse run (%.0fyd%s)", d or 0,
        (rec.attempts or 0) > 0 and (", try " .. (rec.attempts + 1)) or "")
end

function Death.stats()
    local x, y, z, rec = Death.corpse_pos()
    return { dead = Death.is_dead(), ghost = Death.is_ghost(),
             has_corpse = x ~= nil, attempts = rec and rec.attempts or 0,
             delay = Death.recovery_delay(), sickness = Death.has_sickness() }
end

if RaijinLab then RaijinLab.Death = Death end
return Death
