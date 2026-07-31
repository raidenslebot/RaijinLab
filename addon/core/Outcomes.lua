-- Outcomes - did that decision help?
--
-- Without scoring, neither the bot nor a human can tell whether a change to the
-- director, nav, or mount policy made a run better. This is a light ring buffer
-- of (decision, context, later result), filled by services and summarized by
-- /raijin check.
--
-- Progress-aware scoring: begin() snapshots Watchdog progress counts + player
-- position; settle_progress() scores by whether real progress arrived during the
-- hold (Watchdog.note kinds, distance moved). That is how a goal that thrashes
-- the director for 166 minutes without moving scores poorly instead of neutral.

local Outcomes = {}

Outcomes.RING = 200
Outcomes._ring = {}
Outcomes._n = 0
Outcomes._pending = {}
Outcomes._signals = {}       -- kind -> count of progress signals this session

local function now() return (GetTime and GetTime()) or 0 end

local function snapshot_progress()
    local snap = { t = now(), signals = {}, x = nil, y = nil, z = nil }
    local W = RaijinLab and RaijinLab.Watchdog
    if W and W._counts then
        for k, v in pairs(W._counts) do snap.signals[k] = v end
    end
    -- Capture Outcomes.signal counters at begin so settle_progress only
    -- credits increments during THIS hold, not every prior kill this session.
    for k, v in pairs(Outcomes._signals) do
        snap.signals["out:" .. k] = v
    end
    local RL = RaijinLab
    if RL and RL.ObjectPosition then
        local ok, x, y, z = pcall(RL.ObjectPosition, RL, "player")
        if ok and x then snap.x, snap.y, snap.z = x, y, z end
    end
    return snap
end

local function signal_delta(before, after)
    if not before or not after then return 0 end
    local n = 0
    local seen = {}
    for k, v in pairs(after.signals or {}) do
        local b = (before.signals and before.signals[k]) or 0
        if (tonumber(v) or 0) > b then
            n = n + ((tonumber(v) or 0) - b)
            seen[k] = true
        end
    end
    return n
end

local function moved_yd(before, after)
    if not (before and after and before.x and after.x) then return 0 end
    local dx = after.x - before.x
    local dy = after.y - before.y
    local dz = (after.z or 0) - (before.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Open a decision. Returns an id used to settle later.
-- kind: "mount" | "nav" | "goal" | "gather" | "cast" | ...
function Outcomes.begin(kind, meta)
    local id = (Outcomes._seq or 0) + 1
    Outcomes._seq = id
    Outcomes._pending[id] = {
        id = id,
        kind = kind or "?",
        meta = meta or {},
        t0 = now(),
        settled = false,
        progress0 = snapshot_progress(),
    }
    return id
end

-- External modules call this when something unambiguously good happens
-- (quest turn-in, kill, loot, level). Feeds Watchdog-independent scoring.
function Outcomes.signal(kind)
    kind = kind or "progress"
    Outcomes._signals[kind] = (Outcomes._signals[kind] or 0) + 1
    -- Mirror into pending progress0 so signal_delta sees them if we also
    -- stamp progress0.signals at settle from _signals - actually progress0 is
    -- a snapshot at begin; at settle we read current _signals + watchdog.
    local W = RaijinLab and RaijinLab.Watchdog
    if W and W.note then
        -- Do not double-count if caller already noted; Outcomes.signal is the
        -- scorer's own counter for kinds Watchdog does not see.
    end
end

-- Settle with an explicit score in [-1, 1].
function Outcomes.settle(id, score, note)
    local p = Outcomes._pending[id]
    if not p then return end
    p.settled = true
    p.score = tonumber(score) or 0
    p.note = note
    p.t1 = now()
    p.dt = p.t1 - p.t0
    Outcomes._pending[id] = nil
    local n = Outcomes._n + 1
    if n > Outcomes.RING then
        table.remove(Outcomes._ring, 1)
        n = Outcomes.RING
    end
    Outcomes._n = n
    Outcomes._ring[n] = p
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.every then
        Tel.every("outcome:" .. tostring(p.kind), 20, "outcome", 4,
            p.score >= 0.25 and "ok" or (p.score <= -0.25 and "bad" or "neutral"),
            { kind = p.kind, score = p.score, dt = p.dt, note = note })
    end
    return p
end

-- Settle using progress snapshot: real signals / movement => positive;
-- long hold with no progress => negative; short hold => near zero.
function Outcomes.settle_progress(id, note, opts)
    opts = opts or {}
    local p = Outcomes._pending[id]
    if not p then return end
    -- snapshot_progress already merges Watchdog counts AND out:* signal counters.
    local now_snap = snapshot_progress()
    if not p.progress0 then p.progress0 = { signals = {}, t = p.t0 or now() } end
    if not p.progress0.signals then p.progress0.signals = {} end

    local sig = signal_delta(p.progress0, now_snap)
    local dist = moved_yd(p.progress0, now_snap)
    local dt = now() - (p.t0 or now())
    local min_move = opts.min_move or 8
    local long_s = opts.long_hold or 45

    local score = 0
    if sig > 0 then
        score = math.min(1.0, 0.4 + 0.2 * sig)
    end
    if dist >= min_move then
        score = math.max(score, math.min(1.0, 0.3 + dist / 100))
    end
    if score == 0 and dt >= long_s then
        score = -0.8                              -- thrashed without progress
    elseif score == 0 and dt >= (long_s * 0.5) then
        score = -0.3
    end
    if opts.force_score ~= nil then score = opts.force_score end

    local detail = string.format("%s sig=%d moved=%.0f dt=%.0f",
        tostring(note or "progress"), sig, dist, dt)
    return Outcomes.settle(id, score, detail)
end

function Outcomes.mean(kind)
    local s, n = 0, 0
    for i = 1, Outcomes._n do
        local e = Outcomes._ring[i]
        if e and (not kind or e.kind == kind) then
            s = s + (e.score or 0)
            n = n + 1
        end
    end
    if n == 0 then return nil, 0 end
    return s / n, n
end

function Outcomes.bad_streak(kind, threshold)
    threshold = threshold or -0.25
    local n = 0
    for i = Outcomes._n, 1, -1 do
        local e = Outcomes._ring[i]
        if e and (not kind or e.kind == kind) then
            if (e.score or 0) <= threshold then n = n + 1 else break end
        end
    end
    return n
end

function Outcomes.report()
    local lines = {}
    lines[#lines + 1] = string.format("  outcomes: %d settled, %d open",
        Outcomes._n, (function()
            local c = 0; for _ in pairs(Outcomes._pending) do c = c + 1 end; return c
        end)())
    for _, kind in ipairs({ "mount", "nav", "goal", "gather", "cast" }) do
        local m, n = Outcomes.mean(kind)
        if n and n > 0 then
            local bad = Outcomes.bad_streak(kind)
            lines[#lines + 1] = string.format("    %-8s mean=%+.2f n=%d bad_streak=%d",
                kind, m, n, bad)
        end
    end
    return lines
end

if RaijinLab then RaijinLab.Outcomes = Outcomes end
return Outcomes
