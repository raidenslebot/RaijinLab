-- Frame-budgeted cooperative scheduler - the performance backbone.
--
-- Philosophy: never make the bot DO LESS to stay fast. Instead, let every
-- subsystem be as heavy and thorough as it wants (dense pathfinding, exhaustive
-- raycasting, whole-suite analysis) and spread that work across frames under a
-- hard per-frame time budget. The result: the frame NEVER spikes, so you can run
-- the entire suite at once with practically no FPS hit, while the heavy work
-- still completes - just amortized over a handful of frames.
--
-- A "job" is a plain function that does its work and periodically calls
-- Scheduler.yield() to hand the frame back; the scheduler resumes it next slice.
-- Jobs are coroutines under the hood, so a search can be written as straight-line
-- code with a yield() in its inner loop and it "just" becomes async + budgeted.
--
--   local job = Scheduler.run(function()
--       for i = 1, huge do
--           ...expensive step...
--           if Scheduler.over_budget() then Scheduler.yield() end
--       end
--       return result
--   end, Scheduler.PRIO.NORMAL, function(result) ... end)
--
-- debugprofilestop() is WoW's high-resolution (sub-ms) millisecond timer.

local Scheduler = {}
Scheduler.PRIO = { HIGH = 1, NORMAL = 2, LOW = 3 }
Scheduler._q = { {}, {}, {} }               -- one FIFO per priority
Scheduler._seq = 0
Scheduler._frame_start = 0
Scheduler._budget = 2.0                      -- default per-frame ms for background work
Scheduler._metrics = { last_ms = 0, ran = 0, alive = 0, peak_ms = 0, frames = 0 }

local function clock()
    if debugprofilestop then return debugprofilestop() end
    return (GetTime and GetTime() * 1000) or 0
end

local function perf()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.perf = RaijinLabDB.perf or {}
    return RaijinLabDB.perf
end

-- The per-frame compute budget. Adaptive by default: an explicit
-- RaijinLabDB.perf.budget_ms pins it; otherwise it's driven by update_frame()
-- to soak up whatever headroom the current frame rate allows.
local function budget_ms()
    local p = perf()
    if p.budget_ms then return tonumber(p.budget_ms) or Scheduler._budget end
    return Scheduler._adaptive or Scheduler._budget
end

-- Adaptive controller: measures real frame time (EMA) and grows the budget when
-- the frame has headroom (FPS above target) or shrinks it fast when the frame is
-- already expensive (FPS below target). Because the EMA includes our own work,
-- it's a self-regulating feedback loop that converges on "use all the spare
-- frame time, never a millisecond more" - so heavy background work speeds up
-- when the game is idle and yields instantly when combat gets busy. Never drops
-- FPS to do bot work; never wastes idle frames either.
Scheduler._adaptive = 1.5
Scheduler._ema_ms = nil
function Scheduler.update_frame(dt_ms)
    dt_ms = tonumber(dt_ms) or 0
    if dt_ms <= 0 or dt_ms > 1000 then return end     -- ignore first frame / hitch spikes
    local a = 0.1
    Scheduler._ema_ms = Scheduler._ema_ms and (Scheduler._ema_ms * (1 - a) + dt_ms * a) or dt_ms
    local p = perf()
    if p.budget_ms then return end                    -- pinned budget: don't adapt
    local maxb = tonumber(p.max_budget) or 8.0
    local minb = tonumber(p.min_budget) or 0.3
    local ema = Scheduler._ema_ms
    local b = Scheduler._adaptive or 1.5

    -- THE TARGET MUST BE WHAT THIS MACHINE ACTUALLY DOES, NOT 60 FPS.
    --
    -- This compared the frame time against a hardcoded 1000/60 = 16.7ms. The
    -- client here runs at a stable 30 fps (33.3ms/frame), so `ema > target` was
    -- true on EVERY frame forever, the controller ran `b = b*0.8 - 0.05` every
    -- frame, and the budget collapsed to the 0.3ms floor and stayed pinned there
    -- for the entire session.
    --
    -- What that cost: the pathfinder got 0.3ms per frame - about 9ms per second -
    -- so every A* hit its node cap and returned best-so-far. Live log: 149 of 151
    -- plans came back "partial waypoints=2" for goals ~80yd away, the 2-node stub
    -- ended inside the 18yd arrive radius, the route completed without the
    -- character moving, and the bot spent the session re-planning and drifting.
    -- It looked like a navigation bug. It was a budget bug.
    --
    -- The controller could not tell "this game runs at 30 fps" from "we are making
    -- frames slow", and assumed the latter - absence of headroom against an
    -- invented target read as evidence of our own guilt.
    --
    -- So: learn the baseline. Frames where we did essentially no work show what
    -- the machine costs WITHOUT us; the target is that plus a small allowance.
    -- Now the loop measures our actual impact instead of the machine's speed.
    local spent = Scheduler._last_spent_ms or 0
    if spent <= 0.2 then
        -- our own cost is negligible this frame: this is what the game costs alone
        -- DELIBERATELY SLOW (0.01). The baseline is "what this machine costs
        -- without us", and it must not chase a sudden slowdown - otherwise a
        -- degradation we caused gets accepted as the new normal within a few
        -- frames and the controller happily keeps growing. Lagging here means a
        -- real slowdown is attributed to US first, which is the safe default;
        -- a genuinely slower machine is still accepted, just over ~hundreds of
        -- frames instead of ~dozens.
        Scheduler._baseline_ms = Scheduler._baseline_ms
            and (Scheduler._baseline_ms * 0.99 + dt_ms * 0.01) or dt_ms
    end

    local target
    if Scheduler._baseline_ms then
        -- 15% over what the game costs on its own, floored so an already-slow
        -- machine still gets a usable slice rather than being starved further.
        target = math.max(Scheduler._baseline_ms * 1.15, Scheduler._baseline_ms + 2.0)
    else
        -- No baseline yet. Fall back to the configured fps target, but honour a
        -- measured frame time over the assumption if we already have one.
        target = 1000 / (tonumber(p.target_fps) or 60)
        if ema and ema > target then target = ema + 2.0 end
    end
    Scheduler._target_ms = target

    -- NO DEAD ZONE. The previous form grew only below target*0.85 and shrank only
    -- above target, leaving a band in between where the controller did NOTHING.
    -- Observed live: the first frames after a reload are slow (54.6ms, fps 18)
    -- so the budget collapsed to the 0.30 floor; fps then settled to a steady 30
    -- (33.3ms), which sits inside that dead band - so it froze at 0.30 for the
    -- rest of the session and could never climb back. A controller that can fall
    -- but not rise is a ratchet, not a controller.
    --
    -- Now: at or under target we grow, over target we back off. The hysteresis
    -- comes from the asymmetric rates (slow additive growth, fast multiplicative
    -- decay), not from a band where nothing happens.
    if ema > target then
        b = b * 0.8 - 0.05                            -- over budget -> back off fast
    else
        b = b + 0.15                                  -- at or under target -> do more
    end
    if b < minb then b = minb elseif b > maxb then b = maxb end
    Scheduler._adaptive = b
end

-- Called from inside a job to check whether this frame's budget is spent.
function Scheduler.over_budget()
    return (clock() - Scheduler._frame_start) >= budget_ms()
end

-- How much of THIS frame we consumed. update_frame() uses it to recognise the
-- frames where we did nothing, which are the only honest measurement of what the
-- game costs without us.
function Scheduler.note_spent()
    -- tick() already records this; kept so an external caller cannot silently
    -- diverge from it.
    Scheduler._last_spent_ms = clock() - (Scheduler._frame_start or clock())
end

-- Re-export so jobs can `Scheduler.yield()` without pulling in coroutine.
Scheduler.yield = coroutine.yield

-- Submit a job. fn runs as a coroutine; its return value is passed to on_done.
-- Returns a handle you can Scheduler.cancel(). prio defaults to NORMAL.
function Scheduler.run(fn, prio, on_done)
    if type(fn) ~= "function" then return nil end
    prio = prio or Scheduler.PRIO.NORMAL
    if prio < 1 or prio > 3 then prio = 2 end
    Scheduler._seq = Scheduler._seq + 1
    local job = {
        id = Scheduler._seq, co = coroutine.create(fn),
        prio = prio, on_done = on_done, cancelled = false, done = false,
    }
    table.insert(Scheduler._q[prio], job)
    return job
end

function Scheduler.cancel(job)
    if job then job.cancelled = true end
end

function Scheduler.is_active(job)
    return job and not job.done and not job.cancelled
end

-- Resume one job for a slice. Returns true if still alive (keep it queued).
local function step(job)
    if job.cancelled then return false end
    local ok, res = coroutine.resume(job.co)
    if not ok then
        -- The job errored; surface it but never let it wedge the scheduler.
        job.done = true
        Scheduler._last_err = tostring(res)
        if print and RaijinLabDB and RaijinLabDB.perf and RaijinLabDB.perf.debug then
            print("|cffff5555RaijinLab sched|r job error: " .. tostring(res))
        end
        return false
    end
    if coroutine.status(job.co) == "dead" then
        job.done = true
        if job.on_done then pcall(job.on_done, res) end
        return false
    end
    return true
end

-- Run one frame's worth of work: highest priority first, round-robin within a
-- priority so no single job starves its peers, stopping the instant the budget
-- is spent. High-priority jobs may overspend by at most one slice (they matter).
function Scheduler.tick()
    -- Empty queues: zero work (skip clock/budget bookkeeping noise every frame).
    local a1 = #Scheduler._q[1]
    local a2 = #Scheduler._q[2]
    local a3 = #Scheduler._q[3]
    if (a1 + a2 + a3) == 0 then
        Scheduler._last_spent_ms = 0
        local m = Scheduler._metrics
        m.last_ms = 0
        m.ran = 0
        m.alive = 0
        m.frames = m.frames + 1
        return
    end
    Scheduler._frame_start = clock()
    local budget = budget_ms()
    local ran = 0
    for p = 1, 3 do
        local q = Scheduler._q[p]
        if #q > 0 then
            -- Rotate the queue start each frame for fairness (round-robin).
            local n = #q
            local processed = 0
            local i = 1
            while processed < n do
                if p ~= 1 and (clock() - Scheduler._frame_start) >= budget then break end
                local job = q[i]
                if not job then break end
                if step(job) then
                    i = i + 1
                else
                    table.remove(q, i)
                    n = n - 1
                    if n <= 0 then break end
                end
                processed = processed + 1
                ran = ran + 1
                if i > #q then i = 1 end
            end
        end
        if (clock() - Scheduler._frame_start) >= budget then break end
    end
    local used = clock() - Scheduler._frame_start
    -- Feed the baseline learner: frames where `used` is ~0 are the only honest
    -- measurement of what the game costs without us, and the adaptive target is
    -- built from those rather than an assumed 60fps.
    Scheduler._last_spent_ms = used
    local m = Scheduler._metrics
    m.last_ms = used
    m.ran = ran
    m.alive = #Scheduler._q[1] + #Scheduler._q[2] + #Scheduler._q[3]
    if used > m.peak_ms then m.peak_ms = used end
    m.frames = m.frames + 1
end

function Scheduler.stats()
    local m = Scheduler._metrics
    return {
        last_ms = m.last_ms, peak_ms = m.peak_ms, alive = m.alive,
        ran = m.ran, budget = budget_ms(),
        adaptive = Scheduler._adaptive, frame_ms = Scheduler._ema_ms,
        fps = (Scheduler._ema_ms and Scheduler._ema_ms > 0) and (1000 / Scheduler._ema_ms) or nil,
    }
end

-- Own OnUpdate frame - fires every rendered frame; self-limits via the budget.
function Scheduler.start()
    if Scheduler._frame then return end
    if not CreateFrame then return end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetScript("OnUpdate", function(_, e)
        -- 2026-08-02 (idle FPS): when the suite is OFF and no jobs are queued,
        -- this OnUpdate fires every rendered frame but must cost ~nothing. The
        -- empty-queue path in tick() is cheap, but update_frame() still runs
        -- the EMA + adaptive-budget math every frame - pointless when nothing
        -- is being scheduled. Skip both; the heartbeat instrumentation calls
        -- Scheduler.run, which sets a job, which wakes tick() up naturally.
        local q1, q2, q3 = #Scheduler._q[1], #Scheduler._q[2], #Scheduler._q[3]
        if (q1 + q2 + q3) == 0 then
            local M = RaijinLab and RaijinLab.Master
            if M and M.suppressed and M.suppressed() then
                return
            end
        end
        Scheduler.update_frame((e or 0) * 1000)     -- adapt the budget to real frame time
        local ok, err = pcall(Scheduler.tick)
        if not ok then Scheduler._last_err = "tick:" .. tostring(err) end
    end)
    Scheduler._frame = f
end

function Scheduler.stop()
    if Scheduler._frame then
        Scheduler._frame:SetScript("OnUpdate", nil)
        Scheduler._frame = nil
    end
end

if RaijinLab then RaijinLab.Scheduler = Scheduler end
return Scheduler
