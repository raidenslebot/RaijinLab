-- Watchdog - the guarantee that the bot never silently wedges.
--
-- Fourteen interlocking modules now drive this character. Each one is individually
-- careful, but "careful" is not the same as "cannot possibly get stuck": a goal
-- can hold the slot while achieving nothing, a path can lead somewhere unreachable,
-- an NPC can despawn mid-interaction, a server can simply stop answering. The
-- failure that matters for unattended play is not a crash - a crash is obvious -
-- it is the bot that LOOKS busy for six hours and has done nothing.
--
-- So progress is measured, not assumed. Modules report real achievements
-- (movement, kills, loot, quest turn-ins, level-ups); when none arrive for long
-- enough the watchdog escalates through increasingly blunt recoveries rather than
-- waiting for a human to notice.
--
-- The escalation is deliberately graded: nudge first (cheap, usually enough),
-- then reset the service state machines, then stop and say so loudly. Never
-- silently, and never a hard stop as the first response.

local Watchdog = {}

local sqrt, floor = math.sqrt, math.floor

Watchdog.DEFAULTS = {
    enabled       = true,
    nudge_after   = 90,     -- s of no progress before a gentle re-plan
    reset_after   = 240,    -- s before resetting the service state machines
    stop_after    = 900,    -- s before giving up and reporting loudly
    move_epsilon  = 4.0,    -- yd: less than this is "not moving"
    sample_every  = 2.0,    -- s between position samples
    dead_grace    = 600,    -- s of leash while dead (corpse runs are legitimately slow)
}

Watchdog._last_progress = 0
Watchdog._last_sample = 0
Watchdog._pos = nil
Watchdog._level = 0          -- 0 none, 1 nudged, 2 reset, 3 stopped
Watchdog._counts = {}
Watchdog._log = {}

local function now() return (GetTime and GetTime()) or 0 end

function Watchdog.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.watchdog = RaijinLabDB.watchdog or {}
    local c = RaijinLabDB.watchdog
    for k, v in pairs(Watchdog.DEFAULTS) do if c[k] == nil then c[k] = v end end
    return c
end

-- Any module can report that something real happened. This is the ONLY thing
-- that resets the stall timer - deliberately, so "the tick ran" or "a goal was
-- chosen" never counts as progress. Doing nothing energetically is the exact
-- failure this exists to catch.
function Watchdog.note(kind)
    Watchdog._last_progress = now()
    if Watchdog._level > 0 then
        Watchdog._log[#Watchdog._log + 1] =
            { t = now(), event = "recovered", after = Watchdog._level, kind = kind }
        while #Watchdog._log > 20 do table.remove(Watchdog._log, 1) end
    end
    Watchdog._level = 0
    Watchdog._counts[kind or "?"] = (Watchdog._counts[kind or "?"] or 0) + 1
    -- Feed the outcome scorer so goal/nav holds can be judged by real progress.
    local Ou = RaijinLab and RaijinLab.Outcomes
    if Ou and Ou.signal then pcall(Ou.signal, kind or "progress") end
end

-- WHEN WAS THE LAST TIME ANYTHING ACTUALLY HAPPENED.
--
-- This used to answer 0 when _last_progress was still at its initial 0 - i.e.
-- "we have never once recorded progress" was reported as "progress happened this
-- very instant, everything is fine". So a bot that wedged BEFORE its first step
-- was invisible to the watchdog permanently, and the longer it sat there the
-- healthier it looked. The one component whose entire job is noticing that
-- nothing is happening had that exact blind spot.
--
-- Never-progressed is the WORST case, not the best. Measure from when the
-- watchdog armed: "running for N seconds and has not moved once" is precisely
-- the wedge, and it is detectable from the first tick.
function Watchdog.since_progress()
    if Watchdog._last_progress == 0 then
        local t0 = Watchdog._armed_t
        if not t0 then return 0 end        -- genuinely just started: not an accusation
        return now() - t0
    end
    return now() - Watchdog._last_progress
end

-- Arm the clock the first time the watchdog is asked to supervise anything.
-- Deliberately NOT set at file load: the addon loads at the character screen,
-- and counting from there would accuse a player who simply had not logged in.
function Watchdog.arm()
    if not Watchdog._armed_t then Watchdog._armed_t = now() end
end

-- A WATCHDOG DRIVEN BY THE THING IT WATCHES IS NOT A WATCHDOG.
--
-- Watchdog.tick() was called from exactly one place: inside Suite.tick. So it
-- supervised the suite only while the suite was already working, and the single
-- failure it exists to catch - the suite stopping - also stopped the supervisor.
--
-- Live cost: a step() exception hard-stopped the navigator (the ticker's error
-- handler calls stop() -> _stop_ticker()), the quest tick went with it, and the
-- heartbeat reported "accept:to ? st=8 d=20 (moving)" for FOURTEEN MINUTES,
-- 20 yards from the npc, with no nav step logged after step#12. Nothing was
-- watching, because the watcher was a passenger.
--
-- Its own OnUpdate frame at 1Hz, so it keeps running whatever else dies. A plain
-- frame rather than C_Timer on purpose: the C_Timer polyfill has frozen world
-- entry in this project before, and every other ticker here uses a frame.
function Watchdog.start()
    if Watchdog._frame then return end
    if not CreateFrame then return end
    local f = CreateFrame("Frame")
    local acc = 0
    f:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc < 1.0 then return end
        acc = 0
        pcall(Watchdog.tick)
    end)
    Watchdog._frame = f
end

function Watchdog.stop()
    if Watchdog._frame then
        Watchdog._frame:SetScript("OnUpdate", nil)
        Watchdog._frame = nil
    end
end

function Watchdog.is_running()
    return Watchdog._frame ~= nil
end

-- Movement counts as progress, but only real movement: standing still while
-- "travelling" is the classic wedge, and jitter around one spot is not travel.
local function sample_movement(c)
    local RL = RaijinLab
    if not (RL and RL.ObjectPosition) then return end
    local t = now()
    if (t - (Watchdog._last_sample or 0)) < (c.sample_every or 2) then return end
    Watchdog._last_sample = t
    local x, y, z = RL:ObjectPosition("player")
    if not x then return end
    local p = Watchdog._pos
    if p then
        local d = sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2 + ((z or 0) - (p.z or 0)) ^ 2)
        if d >= (c.move_epsilon or 4) then
            Watchdog.note("moved")
        end
    end
    Watchdog._pos = { x = x, y = y, z = z }
end

-- ---- recoveries ----------------------------------------------------------

-- L1: the cheapest thing that fixes most stalls - drop the current path and goal
-- so the next tick re-plans from where we actually are.
function Watchdog.nudge()
    local RL = RaijinLab
    if RL.Nav and RL.Nav.cancel then pcall(RL.Nav.cancel) end
    if RL.Navigator and RL.Navigator.stop then pcall(RL.Navigator.stop) end
    local S = RL.QuestSuite or (RL.Suite)
    if S then S._goal = nil; S._gather_node = nil; S._vendor_goal = nil end
    if RL.Director then RL.Director._cur = nil end
    return "nudge"
end

-- L2: something is genuinely wedged in a service. Reset the state machines that
-- hold cross-tick state, and unpark quests in case we parked everything.
function Watchdog.reset_services()
    local RL = RaijinLab
    Watchdog.nudge()
    if RL.Rest and RL.Rest.reset then pcall(RL.Rest.reset) end
    if RL.Mount then RL.Mount._pending = nil; RL.Mount._last_try = 0 end
    if RL.Patrol and RL.Patrol.reset_visits then pcall(RL.Patrol.reset_visits) end
    local S = RL.QuestSuite or RL.Suite
    if S then S._parked = nil; S._attempts = nil; S._flight_target = nil end
    if RL.Obstacles and RL.Obstacles.refresh then pcall(RL.Obstacles.refresh, true) end
    return "reset"
end

-- L3: we cannot fix it. Stop cleanly and say so - an unattended bot that keeps
-- flailing is worse than one that halts and reports.
function Watchdog.halt(reason)
    local RL = RaijinLab
    Watchdog.nudge()
    if RaijinLabDB and RaijinLabDB.modules then RaijinLabDB.modules.quest = false end
    local msg = "|cffff5555RaijinLab watchdog|r halted: no progress for "
        .. floor(Watchdog.since_progress()) .. "s (" .. tostring(reason or "stalled") .. ")"
    if print then print(msg) end
    local DL = RL and RL.DevLog
    if DL then DL.log("watchdog", "HALT after %ds", floor(Watchdog.since_progress())) end
    return "halt"
end

-- ---- the tick ------------------------------------------------------------

function Watchdog.tick()
    local c = Watchdog.cfg()
    if not c.enabled then return nil end
    -- Only supervise while something is actually meant to be running.
    local running = RaijinLabDB and RaijinLabDB.modules and RaijinLabDB.modules.quest
    if not running then
        Watchdog._last_progress = now()
        Watchdog._level = 0
        Watchdog._armed_t = nil          -- not supervising: the clock does not run
        return nil
    end
    -- Start the never-progressed clock at the moment supervision begins, not at
    -- file load. arm() was added and then not called, which would have left
    -- since_progress() answering 0 forever - the fix present but inert.
    Watchdog.arm()
    -- Death has its own long timers (corpse runs are slow, retrieval has a server
    -- delay), so it gets a MUCH longer leash - but not an unconditional one. The
    -- previous version reset the stall timer on every dead tick, which meant a
    -- ghost that could not reach its corpse and knew of no spirit healer was never
    -- supervised at all: the one situation that strands a run forever was the one
    -- the watchdog ignored.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        local dead_grace = c.dead_grace or 600
        if Watchdog.since_progress() < dead_grace then return nil end
        -- Past the leash: fall through and escalate like anything else.
    end
    sample_movement(c)

    local idle = Watchdog.since_progress()
    local lvl = Watchdog._level
    local action = nil
    if idle >= (c.stop_after or 900) and lvl < 3 then
        Watchdog._level = 3; action = Watchdog.halt("exhausted")
    elseif idle >= (c.reset_after or 240) and lvl < 2 then
        Watchdog._level = 2; action = Watchdog.reset_services()
    elseif idle >= (c.nudge_after or 90) and lvl < 1 then
        Watchdog._level = 1; action = Watchdog.nudge()
    end
    if action then
        Watchdog._log[#Watchdog._log + 1] =
            { t = now(), event = action, idle = floor(idle) }
        while #Watchdog._log > 20 do table.remove(Watchdog._log, 1) end
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then Tel.warn("watchdog", action, { idle = floor(idle), level = Watchdog._level }) end
        return action
    end
    return nil
end

function Watchdog.stats()
    return { enabled = Watchdog.cfg().enabled, idle = floor(Watchdog.since_progress()),
             level = Watchdog._level, counts = Watchdog._counts, log = Watchdog._log }
end

function Watchdog.reset()
    Watchdog._last_progress = now(); Watchdog._level = 0; Watchdog._pos = nil
    Watchdog._armed_t = now()
end

if RaijinLab then RaijinLab.Watchdog = Watchdog end
return Watchdog
