-- Director - the top-level goal arbiter.
--
-- Every capability now exists (fight, quest, rest, vendor, train, recover from
-- death), but until now they were called in a fixed hardcoded cascade. That is
-- not decision-making: it cannot express "the bags are nearly full but this quest
-- is nearly done", it cannot resume what it abandoned, and a fixed order flaps
-- the moment two conditions sit near their thresholds.
--
-- So goals are arbitrated properly:
--
--   BANDS are a hard priority ordering. A lower band always wins - being dead
--   outranks being hungry, which outranks shopping. No amount of urgency lets a
--   lower-priority band jump the queue, because "I really want to go shopping"
--   must never beat "I am on fire".
--
--   URGENCY orders goals WITHIN a band, so two competing errands resolve sensibly
--   (nearly-full bags before mildly-worn armour).
--
--   HYSTERESIS stops oscillation. The classic failure is resting at 55% health,
--   standing up, dropping to 54%, sitting down again forever. A goal that has just
--   started is COMMITTED for a short time and can only be interrupted by a
--   strictly higher band - never by a same-band rival.
--
--   INTERRUPT/RESUME remembers what was abandoned, so after eating we go back to
--   the exact objective we left rather than re-deciding from scratch.
--
-- The decision function is pure, so all of this is testable without a client.

local Director = {}

local huge = math.huge

Director.BANDS = {
    recover  = 1,   -- dead / ghost: nothing else is possible
    survive  = 2,   -- about to die: flee, emergency heal
    combat   = 3,   -- something is hitting us
    rest     = 4,   -- hurt or out of resource, safe to recover
    errand   = 5,   -- bags full / broken gear / new ranks to learn
    progress = 6,   -- the actual job: quest, grind, gather
    idle     = 9,
}

-- Was 2.5s: live Deathknell flapped gather->progress->gather in 1.5-3s windows,
-- each switch cancelling a good pathfind mid-leg. 8s lets a walk to a turn-in
-- complete without an herb stealing the band.
Director.MIN_COMMIT = 8.0
Director._goals = {}
Director._cur = nil
Director._log = {}

local function now() return (GetTime and GetTime()) or 0 end

-- Register a goal.
--   name     unique key
--   band     Director.BANDS.* (lower = higher priority)
--   evaluate function() -> active(bool), urgency(0..1), reason(string)
--   run      function() -> status string (or nil if it turned out to have nothing to do)
function Director.register(name, band, evaluate, run, opts)
    opts = opts or {}
    Director._goals[name] = {
        name = name, band = band or Director.BANDS.progress,
        evaluate = evaluate, run = run,
        min_commit = opts.min_commit or Director.MIN_COMMIT,
        enabled = opts.enabled ~= false,
    }
    return Director._goals[name]
end

-- Unified act(dry): ONE function answers "can I?" and "do it".
--   act(true)  -> active, urgency, reason   (must NOT have side effects)
--   act(false) -> status string or nil      (may act)
-- Divergence between evaluate and run becomes impossible for goals registered
-- this way. Prefer this for every new goal; migrate old pairs over time.
function Director.register_unified(name, band, act, opts)
    opts = opts or {}
    local evaluate = function()
        local ok, a, u, r = pcall(act, true)
        if not ok then return false, 0, "eval_error" end
        return a and true or false, tonumber(u) or 0, r
    end
    local run = function()
        local ok, st = pcall(act, false)
        if not ok then return "act_error" end
        return st
    end
    local g = Director.register(name, band, evaluate, run, opts)
    g.act = act
    g.unified = true
    return g
end

-- Property helper for tests: if evaluate says active, run(dry path) of a unified
-- goal must not be structurally empty. For classic pairs, run() may still nil
-- under a different world - callers mock the world identically.
function Director.agreement_check(name)
    local g = Director._goals[name]
    if not g then return false, "missing" end
    local ok, active, urgency, reason = pcall(g.evaluate)
    if not ok then return false, "eval_error" end
    if not active then return true, "inactive" end
    if g.unified and g.act then
        local ok2, st = pcall(g.act, false)
        if not ok2 then return false, "act_error" end
        if st == nil then return false, "active_but_run_nil:" .. tostring(reason) end
        return true, st
    end
    local ok3, st = pcall(g.run)
    if not ok3 then return false, "run_error" end
    if st == nil then return false, "active_but_run_nil:" .. tostring(reason) end
    return true, st
end

function Director.set_enabled(name, on)
    local g = Director._goals[name]
    if g then g.enabled = on and true or false end
end

function Director.clear() Director._goals = {}; Director._cur = nil end

-- ---- the pure decision ---------------------------------------------------
-- candidates: { {name, band, urgency, active}, ... }
-- cur:        { name, band, since } or nil
-- Returns chosen(table|nil), reason(string).
function Director.choose(candidates, cur, t, opts)
    opts = opts or {}
    t = t or 0
    local best = nil
    for _, c in ipairs(candidates or {}) do
        if c.active then
            if not best then best = c
            elseif c.band < best.band then best = c
            elseif c.band == best.band and (c.urgency or 0) > (best.urgency or 0) then best = c
            end
        end
    end
    if not best then return nil, "nothing_active" end
    if not cur then return best, "start" end

    -- Is what we are doing still worth doing?
    local cur_still = nil
    for _, c in ipairs(candidates or {}) do
        if c.name == cur.name and c.active then cur_still = c end
    end
    if not cur_still then return best, "current_finished" end
    if best.name == cur.name then return best, "continue" end

    -- A strictly higher band always preempts, immediately.
    if best.band < cur_still.band then return best, "preempted" end

    -- Same or lower band: respect the commitment window so two goals sitting near
    -- their thresholds cannot ping-pong.
    local commit = opts.min_commit or Director.MIN_COMMIT
    if (t - (cur.since or 0)) < commit then
        return cur_still, "committed"
    end
    -- Past the window, only a CLEARLY more urgent same-band goal may take over.
    -- Margin was 0.15: gather at 0.33 stole progress at 0.10 mid-turnin every run.
    if best.band == cur_still.band and (best.urgency or 0) > (cur_still.urgency or 0) + (opts.margin or 0.35) then
        return best, "more_urgent"
    end
    if best.band < cur_still.band then return best, "higher_band" end
    return cur_still, "stay"
end

-- ---- the live tick -------------------------------------------------------

function Director.evaluate_all()
    local out = {}
    for _, g in pairs(Director._goals) do
        if g.enabled then
            local active, urgency, reason = false, 0, nil
            if g.evaluate then
                local ok, a, u, r = pcall(g.evaluate)
                if ok then active, urgency, reason = a and true or false, tonumber(u) or 0, r end
            end
            out[#out + 1] = { name = g.name, band = g.band, urgency = urgency,
                              active = active, reason = reason, goal = g }
        end
    end
    table.sort(out, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        return (a.urgency or 0) > (b.urgency or 0)
    end)
    return out
end

function Director.tick()
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    local t = now()
    -- LIVENESS BEAT AT THE ENTRY, NOT AT AN EXIT. This function has three return
    -- paths and the first attempt instrumented two of them - the one actually
    -- being taken stayed silent, so the director still looked dead while running
    -- 179 times a minute. A proof-of-life placed at an exit is only as complete
    -- as your memory of the exits; placed at the entry it cannot be bypassed.
    local Tel0 = RaijinLab and RaijinLab.Telemetry
    if Tel0 then
        Tel0.every("director:hb", 10, "director", 4, "alive",
            { goal = (Director._cur and Director._cur.name) or "none",
              held = t - ((Director._cur and Director._cur.since) or t) })
    end
    -- Remember what was running BEFORE arbitration, so the fall-through loop can
    -- tell "still the same goal" from "genuinely switched" and keep the original
    -- commitment timestamp rather than resetting it every tick.
    Director._prev_name = Director._cur and Director._cur.name or nil
    Director._prev_since = Director._cur and Director._cur.since or nil
    local cands = Director.evaluate_all()
    -- Per-goal commit: use the longer of global MIN_COMMIT and the current goal's
    -- own min_commit so turn-ins (12s) are not interrupted after the default.
    local commit_opts = nil
    if Director._cur then
        local cg = Director._goals[Director._cur.name]
        local mc = (cg and cg.min_commit) or Director.MIN_COMMIT
        if mc < Director.MIN_COMMIT then mc = Director.MIN_COMMIT end
        commit_opts = { min_commit = mc }
    end
    local chosen, why = Director.choose(cands, Director._cur, t, commit_opts)
    if not chosen then
        Director._cur = nil
        Director._last = { goal = "idle", why = why, t = t }
        return nil, "idle"
    end

    -- Switching goals: remember what we were doing so it can be resumed, and log
    -- the transition (this is the record that explains the bot's behaviour).
    if not Director._cur or Director._cur.name ~= chosen.name then
        if Director._cur then
            Director._interrupted = { name = Director._cur.name, t = t }
            -- Score the interrupted goal's hold: short holds that achieved nothing
            -- score poorly; long holds that ran are neutral until Outcomes.settle.
            local Ou = RaijinLab and RaijinLab.Outcomes
            if Ou and Director._outcome then
                -- Score by real progress during the hold, not a flat 0.
                if Ou.settle_progress then
                    Ou.settle_progress(Director._outcome, "switch:" .. tostring(why))
                else
                    Ou.settle(Director._outcome, 0.0, "interrupted:" .. tostring(why))
                end
                Director._outcome = nil
            end
        end
        Director._cur = { name = chosen.name, band = chosen.band, since = t }
        Director._log[#Director._log + 1] = {
            t = t, goal = chosen.name, why = why, reason = chosen.reason,
            urgency = chosen.urgency,
        }
        while #Director._log > 20 do table.remove(Director._log, 1) end
        local Ou = RaijinLab and RaijinLab.Outcomes
        if Ou and Ou.begin then
            Director._outcome = Ou.begin("goal", {
                goal = chosen.name, why = why, reason = chosen.reason,
            })
        end
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then
            Tel.info("director", "switch", { goal = chosen.name, band = chosen.band,
                why = why, reason = chosen.reason, urgency = chosen.urgency,
                from = Director._prev_name })
            -- On a switch, record what every candidate looked like: the decision
            -- is only reviewable if the alternatives are visible too.
            for _, c in ipairs(cands) do
                Tel.debug("director", "cand", { goal = c.name, band = c.band,
                    active = c.active, urgency = c.urgency, reason = c.reason })
            end
        end
    end

    -- Run it. A goal can claim to be applicable and then turn out to have nothing
    -- to do (the vendor is needed but none is known yet). Clearing the slot alone
    -- is not enough - it would simply be chosen again next tick and starve
    -- everything beneath it forever. So we FALL THROUGH to the next candidate in
    -- priority order, exactly like a cascade, while keeping the arbitration.
    local status, ran_name = nil, nil
    local skipped = {}
    local guard = 0
    local cand = chosen
    while cand and guard < 8 do
        guard = guard + 1
        local g = cand.goal or Director._goals[cand.name]
        if g and g.run then
            local ok, s = pcall(g.run)
            if ok then status = s end
        end
        if status ~= nil then ran_name = cand.name; break end
        -- nothing to do: remember and take the next-best active candidate
        skipped[cand.name] = true
        do
            local Tel = RaijinLab and RaijinLab.Telemetry
            -- A goal that claims to be applicable and then does nothing is the
            -- classic silent stall; make every one of them visible.
            -- Counted, not just logged: a contract watches the RATE of this.
            -- A goal that claims work and then does nothing is churn, and churn
            -- at 3Hz destroyed interrupt/resume for a whole session unnoticed.
            Director._fallthrough_n = (Director._fallthrough_n or 0) + 1
            if Tel then Tel.debug("director", "fallthrough", { goal = cand.name, band = cand.band }) end
        end
        Director._cur = nil
        cand = nil
        for _, c in ipairs(cands) do
            if c.active and not skipped[c.name] then cand = c; break end
        end
        if cand then
            -- Preserve `since` when we fall back into the SAME goal we were
            -- already running. Re-stamping it every tick would mean the
            -- commitment window never expires, so a same-band rival could never
            -- take over - a higher-priority goal that keeps returning nil (bags
            -- full with no vendor known, say) would then starve every goal
            -- beneath it indefinitely.
            local keep = (Director._prev_name == cand.name) and Director._prev_since or t
            Director._cur = { name = cand.name, band = cand.band, since = keep }
        end
    end

    if status == nil then
        Director._cur = nil
        Director._last = { goal = "idle", why = "all_idle", t = t }
        return nil, "idle"
    end
    Director._last = { goal = ran_name, why = why, status = status, t = t }
    return status, ran_name
end

function Director.current() return Director._cur and Director._cur.name or nil end

function Director.explain()
    local out = {}
    local cands = Director.evaluate_all()
    for _, c in ipairs(cands) do
        out[#out + 1] = string.format("%-9s band=%d %s urgency=%.2f%s",
            c.name, c.band, c.active and "ACTIVE " or "idle   ", c.urgency or 0,
            c.reason and ("  " .. tostring(c.reason)) or "")
    end
    return out, Director.current()
end

function Director.history() return Director._log end

if RaijinLab then RaijinLab.Director = Director end
return Director
