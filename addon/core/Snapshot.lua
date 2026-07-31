-- Snapshot - a complete picture of the bot's state, once a second.
--
-- Event logs tell you what changed; they do not tell you the CONTEXT a decision
-- was made in. When something goes wrong at 03:12 the question is always "what
-- did it know at the time" - what were its vitals, where was it, what goal was
-- running, what did the navigator think it was doing, how big were the stores.
-- Reconstructing that from scattered events is guesswork.
--
-- So once a second every subsystem's state is written as one structured line per
-- domain. A whole unattended session can then be replayed off disk: filter to a
-- domain to watch it evolve, or grep a timestamp to see everything at once.
--
-- Every read is pcall-guarded and every subsystem optional - a snapshot must
-- never be the thing that breaks the run.

local S = {}

-- 1Hz again: domains are cheap once Telemetry/Debug mirror is quiet and
-- collectors only read in-memory state (no extra TraceLine).
S.INTERVAL = 1.0
S._t = 0
S._running = false

local function now() return (GetTime and GetTime()) or 0 end
local function TT() return RaijinLab and RaijinLab.Telemetry end

local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

-- ---- per-domain collectors ----------------------------------------------

function S.player()
    local RL = RaijinLab
    local kv = {}
    if RL and RL.ObjectPosition then
        local x, y, z = safe(RL.ObjectPosition, RL, "player")
        if x then kv.x, kv.y, kv.z = x, y, z end
    end
    if UnitHealth and UnitHealthMax then
        local mx = UnitHealthMax("player") or 0
        if mx > 0 then kv.hp = math.floor((UnitHealth("player") or 0) / mx * 100) end
    end
    if UnitPowerMax then
        local ok, mx = pcall(UnitPowerMax, "player", 0)
        if ok and (tonumber(mx) or 0) > 0 then
            local _, cur = pcall(UnitPower, "player", 0)
            kv.mana = math.floor((tonumber(cur) or 0) / mx * 100)
        end
    end
    if UnitLevel then kv.lvl = UnitLevel("player") end
    if UnitAffectingCombat then kv.combat = UnitAffectingCombat("player") and true or false end
    if UnitIsDeadOrGhost then kv.dead = UnitIsDeadOrGhost("player") and true or false end
    if IsMounted then kv.mounted = IsMounted() and true or false end
    if IsSwimming then kv.swim = IsSwimming() and true or false end
    -- Facing is read from memory and has been seen returning garbage; flag it
    -- rather than printing 20 digits of noise.
    if RL and RL.Actions and RL.Actions.PlayerFacing then
        local f = safe(RL.Actions.PlayerFacing)
        if type(f) == "number" then
            if f ~= f or math.abs(f) > 100 then kv.facing = "BAD" else kv.facing = f end
        end
    end
    return kv
end

function S.goal()
    local D = RaijinLab and RaijinLab.Director
    local kv = {}
    if D then
        kv.goal = D.current() or "idle"
        if D._last then kv.why = D._last.why; kv.status = D._last.status end
        if D._cur then kv.band = D._cur.band; kv.held = now() - (D._cur.since or now()) end
    end
    local Q = RaijinLab and RaijinLab.QuestSuite
    if Q then kv.state = Q.state end
    return kv
end

function S.nav()
    local kv = {}
    local Nv = RaijinLab and RaijinLab.Navigator
    if Nv then
        kv.state = Nv.state
        kv.active = Nv._active ~= nil
        if Nv._active and Nv._active.poly then
            kv.node = Nv._active.idx
            kv.nodes = #Nv._active.poly
        end
    end
    local Q = RaijinLab and RaijinLab.QuestSuite
    if Q and Q._goal then kv.gx, kv.gy = Q._goal.x, Q._goal.y end
    local OB = RaijinLab and RaijinLab.Obstacles
    if OB and OB.stats then
        local st = safe(OB.stats)
        if st then kv.obstacles = st.n end
    end
    return kv
end

function S.world()
    local kv = {}
    local WM = RaijinLab and RaijinLab.WorldMesh
    if WM and WM.stats then
        local st = safe(WM.stats)
        if st then
            kv.map = st.map; kv.cells = st.cells
            kv.traversed = st.traversed; kv.seen = st.seen; kv.hazard = st.hazard
        end
    end
    local P = RaijinLab and RaijinLab.POI
    if P and P.stats then
        local st = safe(P.stats)
        if st then kv.poi = st.total end
    end
    local TV = RaijinLab and RaijinLab.Traversability
    if TV and TV.stats then
        local st = safe(TV.stats)
        if st then kv.tvcells = st.cells; kv.roads = st.road_cells end
    end
    local H = RaijinLab and RaijinLab.HLP
    if H and H.stats then
        local st = safe(H.stats)
        if st and st.built then kv.l1 = st.l1; kv.l2 = st.l2 end
    end
    return kv
end

function S.services()
    local kv = {}
    local R = RaijinLab and RaijinLab.Rest
    if R and R.stats then
        local st = safe(R.stats)
        if st then kv.rest = st.state; kv.food = st.food; kv.drink = st.drink end
    end
    local V = RaijinLab and RaijinLab.Vendor
    if V and V.stats then
        local st = safe(V.stats)
        if st then kv.bags = st.free_slots; kv.dur = math.floor(st.durability or 100)
            kv.junk = st.junk; kv.errand = st.reason end
    end
    local M = RaijinLab and RaijinLab.Mount
    if M and M.stats then
        local st = safe(M.stats)
        if st then kv.mounts = st.known; kv.riding = st.mounted end
    end
    return kv
end

function S.perf()
    local kv = {}
    local Sch = RaijinLab and RaijinLab.Scheduler
    if Sch and Sch.stats then
        local st = safe(Sch.stats)
        if st then kv.sched_ms = st.last_ms; kv.jobs = st.alive; kv.peak = st.peak_ms end
    end
    if GetFramerate then kv.fps = math.floor(GetFramerate() or 0) end
    local W = RaijinLab and RaijinLab.Watchdog
    if W and W.stats then
        local st = safe(W.stats)
        if st then kv.idle = st.idle; kv.escalation = st.level end
    end
    return kv
end

function S.rotation()
    local kv = {}
    local Ex = RaijinLab and RaijinLab.RotationExecutor
    if Ex then
        kv.running = Ex._frame ~= nil
        kv.casts = Ex._cast_count
        kv.gcd_src = Ex._gcd_src
        if Ex._gcd_obs then kv.gcd = Ex._gcd_obs end
        kv.last_err = Ex._last_err
    end
    return kv
end

-- ---- the tick ------------------------------------------------------------

local DOMAINS = {
    { "player",   S.player },
    { "goal",     S.goal },
    { "nav",      S.nav },
    { "world",    S.world },
    { "services", S.services },
    { "perf",     S.perf },
    { "rotation", S.rotation },
}

function S.tick(force)
    local t = now()
    -- Master OFF: rare snapshots only (full domain emit is disk + CPU waste).
    local gap = S.INTERVAL
    if not force and RaijinLab and RaijinLab.Master and RaijinLab.Master.suppressed
        and RaijinLab.Master.suppressed() then
        gap = 5.0
    end
    -- UI open / OOC: amortize snapshot domains (major hitch when opening menu).
    if not force then
        local Menu = RaijinLab and RaijinLab.Menu
        local ui = (Menu and Menu.frame and Menu.frame.IsShown and Menu.frame:IsShown())
            or (RaijinLab and RaijinLab._ui_open_hint)
        if ui then
            gap = 2.5
        elseif not (UnitAffectingCombat and UnitAffectingCombat("player")) then
            gap = 1.5
        end
    end
    if not force and (t - (S._t or 0)) < gap then return end
    S._t = t
    local Tel = TT()
    if not Tel then return end
    -- When UI open: only player+perf+rotation (drop world mesh dumps).
    local Menu = RaijinLab and RaijinLab.Menu
    local ui = (Menu and Menu.frame and Menu.frame.IsShown and Menu.frame:IsShown())
    local domains = DOMAINS
    if ui and not force then
        domains = {
            { "player", S.player },
            { "perf", S.perf },
            { "rotation", S.rotation },
        }
    end
    for _, d in ipairs(domains) do
        local name, fn = d[1], d[2]
        local ok, kv = pcall(fn)
        if ok and kv and next(kv) then
            Tel.emit("snap", 3, name, kv)
        end
    end
end

function S.start()
    if S._running then return end
    S._running = true
    if C_Timer and C_Timer.NewTicker then
        S._ticker = C_Timer.NewTicker(S.INTERVAL, function() pcall(S.tick) end)
    end
end

function S.stop()
    if S._ticker then S._ticker:Cancel(); S._ticker = nil end
    S._running = false
end

-- One-shot full dump (used by /raijin snap and on interesting transitions).
function S.dump() S.tick(true) end

if RaijinLab then RaijinLab.Snapshot = S end
return S
