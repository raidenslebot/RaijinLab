-- Fail - one failure taxonomy, one retry policy.
--
-- Every retry loop that has shipped was hand-rolled: mount retried a permanent
-- "no riding skill" every 120s all session; quest objectives retried forever;
-- nav stuck recoveries had no shared notion of fatal vs transient.
--
-- Three kinds, and only three:
--   transient  - may clear without an external event (network blip, GCD, lag)
--   persistent - stays true until a named event fires (level-up, trainer, zone)
--   fatal      - never retry this session / until hard reset
--
-- Consumers call Fail.record(...) when something goes wrong and Fail.may_retry
-- before trying again. Mount's escalating backoff is the reference instance of
-- this engine, not a special snowflake.

local Fail = {}

Fail.TRANSIENT  = "transient"
Fail.PERSISTENT = "persistent"
Fail.FATAL      = "fatal"

Fail._by_key = {}
Fail.DEFAULT_BACKOFF = 2.0
Fail.MAX_BACKOFF     = 1800.0

local function now() return (GetTime and GetTime()) or 0 end

-- key uniquely identifies the failing action ("mount:summon", "nav:goal:xyz").
-- kind is Fail.TRANSIENT | PERSISTENT | FATAL.
-- opts.invalidated_by = { "PLAYER_LEVEL_UP", ... } for persistent.
-- opts.why = human string.
-- opts.backoff = initial seconds (escalates on repeated persistent/transient).
function Fail.record(key, kind, opts)
    opts = opts or {}
    kind = kind or Fail.TRANSIENT
    local t = now()
    local prev = Fail._by_key[key]
    local count = (prev and prev.count or 0) + 1
    local base = tonumber(opts.backoff) or Fail.DEFAULT_BACKOFF
    local wait
    if kind == Fail.FATAL then
        wait = 1e12
    elseif kind == Fail.PERSISTENT then
        -- Persistent facts do NOT expire by wall clock - only by invalidated_by
        -- events (level-up, trainer, zone). A timed "permanent" is just a
        -- transient with a long backoff, which is how mount retried forever.
        wait = 1e12
    else
        wait = math.min(120.0, base * (1.5 ^ math.min(count - 1, 8)))
    end
    local rec = {
        key = key,
        kind = kind,
        why = opts.why or key,
        count = count,
        t = t,
        until_t = t + wait,
        invalidated_by = opts.invalidated_by or {},
        wait = wait,
    }
    Fail._by_key[key] = rec
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.every then
        -- A DIAGNOSTIC THAT PRINTS GARBAGE IS WORSE THAN SILENCE.
        --
        -- FATAL and PERSISTENT use wait = 1e12 to mean "never expires by clock",
        -- which is right. But the telemetry formatter renders it as a 32-bit
        -- integer, so the live log read `wait=-2147483648` (INT_MIN) 1215 times
        -- in one session. Anyone reading that reasonably concludes the backoff
        -- arithmetic has underflowed and the action is retrying immediately -
        -- the exact opposite of what the code does. Say what it means.
        local shown = wait
        if wait >= 1e11 then shown = "never" else shown = string.format("%.0f", wait) end
        Tel.every("fail:" .. key, 15, "fail", 3, kind, {
            why = rec.why, count = count, wait = shown,
        })
    end
    return rec
end

function Fail.clear(key)
    Fail._by_key[key] = nil
end

function Fail.clear_all()
    Fail._by_key = {}
end

-- Event-driven reconsider for persistent failures.
function Fail.on_event(event)
    if not event then return end
    local drop = {}
    for key, rec in pairs(Fail._by_key) do
        if rec.kind == Fail.PERSISTENT then
            for _, e in ipairs(rec.invalidated_by or {}) do
                if e == event then drop[#drop + 1] = key; break end
            end
        end
    end
    for _, key in ipairs(drop) do Fail._by_key[key] = nil end
    return #drop
end

function Fail.get(key)
    return Fail._by_key[key]
end

-- true if the caller may attempt again right now.
function Fail.may_retry(key)
    local rec = Fail._by_key[key]
    if not rec then return true end
    if rec.kind == Fail.FATAL then return false, rec end
    if now() >= (rec.until_t or 0) then return true, rec end
    return false, rec
end

-- Convenience: record permanent character facts (no riding skill, etc.).
function Fail.permanent(key, why, events)
    return Fail.record(key, Fail.PERSISTENT, {
        why = why,
        invalidated_by = events or { "PLAYER_LEVEL_UP", "TRAINER_SHOW", "SKILL_LINES_CHANGED" },
        backoff = 120,
    })
end

function Fail.report()
    local lines = {}
    local t = now()
    for key, rec in pairs(Fail._by_key) do
        local rem = math.max(0, (rec.until_t or 0) - t)
        lines[#lines + 1] = string.format("  fail %-24s %-10s x%d wait=%.0fs  %s",
            key, rec.kind, rec.count or 1, rem, tostring(rec.why or ""))
    end
    table.sort(lines)
    return lines
end

if RaijinLab then RaijinLab.Fail = Fail end
return Fail
