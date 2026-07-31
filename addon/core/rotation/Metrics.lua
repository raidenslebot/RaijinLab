-- Rotation performance telemetry.
-- Tracks speed (tick cost, inter-cast gap), reaction time (ready->fire, free->fire,
-- fire->confirm/refuse), and consistency (stddev, refuse rate). Pure enough for
-- unit tests; disk/chat wiring is done by Executor + ChatHandler.

local Metrics = {}

local WINDOW = 64          -- ring buffer length for rolling stats
local LOG_EVERY = 10.0     -- seconds between DevLog summary lines

local function now()
    return (GetTime and GetTime()) or 0
end

local function push(buf, v, cap)
    cap = cap or WINDOW
    buf[#buf + 1] = v
    while #buf > cap do table.remove(buf, 1) end
end

local function stats(buf)
    local n = #buf
    if n == 0 then
        return { n = 0, avg = 0, min = 0, max = 0, p50 = 0, p95 = 0, std = 0 }
    end
    local sum, mn, mx = 0, buf[1], buf[1]
    for i = 1, n do
        local v = buf[i]
        sum = sum + v
        if v < mn then mn = v end
        if v > mx then mx = v end
    end
    local avg = sum / n
    local var = 0
    for i = 1, n do
        local d = buf[i] - avg
        var = var + d * d
    end
    var = var / n
    -- percentile via sorted copy (N is small)
    local sorted = {}
    for i = 1, n do sorted[i] = buf[i] end
    table.sort(sorted)
    local function pct(p)
        local idx = math.floor((p / 100) * (n - 1)) + 1
        if idx < 1 then idx = 1 end
        if idx > n then idx = n end
        return sorted[idx]
    end
    return {
        n = n,
        avg = avg,
        min = mn,
        max = mx,
        p50 = pct(50),
        p95 = pct(95),
        std = math.sqrt(var),
    }
end

function Metrics.reset()
    Metrics._session_t0 = now()
    Metrics._ticks = 0
    Metrics._attempts = 0
    Metrics._landed = 0
    Metrics._refused = 0
    Metrics._phantoms = 0          -- unconfirmed deadline releases
    Metrics._reaction = {}         -- ms: spell first-ready -> cast fire
    Metrics._free_react = {}       -- ms: GCD free -> cast fire
    Metrics._confirm = {}          -- ms: cast fire -> confirm
    Metrics._refuse_lat = {}       -- ms: cast fire -> refuse
    Metrics._intercast = {}        -- ms: landed -> next landed
    Metrics._tick_ms = {}          -- ms: tick wall time
    Metrics._ready_since = {}      -- [sid] = t first seen ready
    Metrics._gcd_free_since = nil  -- t when gcd_active last went false
    Metrics._was_gcd = false
    Metrics._last_landed_t = nil
    Metrics._last_summary_t = 0
    Metrics._last_line = ""
end

Metrics.reset()

-- Rising-edge ready tracker for one spell id.
function Metrics.note_ready(sid, is_ready, t)
    sid = tonumber(sid) or 0
    if sid == 0 then return end
    t = t or now()
    if is_ready then
        if Metrics._ready_since[sid] == nil then
            Metrics._ready_since[sid] = t
        end
    else
        Metrics._ready_since[sid] = nil
    end
end

-- GCD free edge: call each tick with current gcd_active boolean.
-- free_since stamps the first free moment after a lock; cleared on GCD lock
-- and consumed by note_attempt.
function Metrics.note_gcd_active(gcd_active, t)
    t = t or now()
    if gcd_active then
        Metrics._gcd_free_since = nil
    else
        if Metrics._gcd_free_since == nil then
            Metrics._gcd_free_since = t
        end
    end
end

-- Fired when we actually call CastSpell (attempt accepted by runtime path).
function Metrics.note_attempt(sid, t)
    t = t or now()
    sid = tonumber(sid) or 0
    Metrics._attempts = (Metrics._attempts or 0) + 1
    local rs = Metrics._ready_since[sid]
    if rs then
        local ms = (t - rs) * 1000
        if ms < 0 then ms = 0 end
        if ms < 10000 then push(Metrics._reaction, ms) end
        Metrics._ready_since[sid] = nil
    end
    local fs = Metrics._gcd_free_since
    if fs then
        local ms = (t - fs) * 1000
        if ms < 0 then ms = 0 end
        if ms < 10000 then push(Metrics._free_react, ms) end
        Metrics._gcd_free_since = nil
    end
end

function Metrics.note_landed(sid, cast_t, t)
    t = t or now()
    Metrics._landed = (Metrics._landed or 0) + 1
    if cast_t and cast_t > 0 then
        local ms = (t - cast_t) * 1000
        if ms >= 0 and ms < 5000 then push(Metrics._confirm, ms) end
    end
    if Metrics._last_landed_t then
        local gap = (t - Metrics._last_landed_t) * 1000
        if gap >= 0 and gap < 30000 then push(Metrics._intercast, gap) end
    end
    Metrics._last_landed_t = t
end

function Metrics.note_refused(sid, cast_t, t, reason)
    t = t or now()
    Metrics._refused = (Metrics._refused or 0) + 1
    if cast_t and cast_t > 0 then
        local ms = (t - cast_t) * 1000
        if ms >= 0 and ms < 5000 then push(Metrics._refuse_lat, ms) end
    end
end

function Metrics.note_phantom()
    Metrics._phantoms = (Metrics._phantoms or 0) + 1
end

function Metrics.note_tick(dt_ms)
    Metrics._ticks = (Metrics._ticks or 0) + 1
    dt_ms = tonumber(dt_ms) or 0
    if dt_ms >= 0 and dt_ms < 200 then
        push(Metrics._tick_ms, dt_ms)
    end
end

function Metrics.snapshot()
    local r = stats(Metrics._reaction)
    local f = stats(Metrics._free_react)
    local c = stats(Metrics._confirm)
    local ref = stats(Metrics._refuse_lat)
    local ic = stats(Metrics._intercast)
    local tk = stats(Metrics._tick_ms)
    local attempts = Metrics._attempts or 0
    local landed = Metrics._landed or 0
    local refused = Metrics._refused or 0
    local ticks = Metrics._ticks or 0
    local session = now() - (Metrics._session_t0 or now())
    if session < 0 then session = 0 end
    local refuse_rate = (attempts > 0) and (refused / attempts) or 0
    local land_rate = (attempts > 0) and (landed / attempts) or 0
    -- Consistency score 0-100: lower reaction std + lower refuse rate is better.
    -- Pure heuristic for at-a-glance comparison across sessions.
    local react_std = r.std or 0
    local consistency = 100
        - math.min(50, react_std)           -- punish jitter
        - math.min(40, refuse_rate * 100)   -- punish refuses
        - math.min(10, (Metrics._phantoms or 0) > 0 and 5 or 0)
    if consistency < 0 then consistency = 0 end
    return {
        session_s = session,
        ticks = ticks,
        attempts = attempts,
        landed = landed,
        refused = refused,
        phantoms = Metrics._phantoms or 0,
        refuse_rate = refuse_rate,
        land_rate = land_rate,
        reaction = r,       -- ready -> fire (ms)
        free_react = f,     -- GCD free -> fire (ms)
        confirm = c,        -- fire -> confirm (ms)
        refuse_lat = ref,   -- fire -> refuse (ms)
        intercast = ic,     -- landed -> landed (ms)
        tick = tk,          -- tick cost (ms)
        consistency = consistency,
    }
end

function Metrics.summary_line(s)
    s = s or Metrics.snapshot()
    return string.format(
        "sess=%.0fs ticks=%d att=%d land=%d ref=%d ph=%d | react_ms avg=%.1f p50=%.1f p95=%.1f std=%.1f | free_ms avg=%.1f p50=%.1f | conf_ms avg=%.1f | inter_ms avg=%.0f std=%.0f | tick_ms avg=%.2f max=%.2f | land%%=%.0f ref%%=%.0f score=%.0f",
        s.session_s, s.ticks, s.attempts, s.landed, s.refused, s.phantoms,
        s.reaction.avg, s.reaction.p50, s.reaction.p95, s.reaction.std,
        s.free_react.avg, s.free_react.p50,
        s.confirm.avg,
        s.intercast.avg, s.intercast.std,
        s.tick.avg, s.tick.max,
        s.land_rate * 100, s.refuse_rate * 100, s.consistency
    )
end

function Metrics.report_lines()
    local s = Metrics.snapshot()
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = string.format(fmt, ...)
    end
    add("session %.1fs | ticks=%d attempts=%d landed=%d refused=%d phantoms=%d",
        s.session_s, s.ticks, s.attempts, s.landed, s.refused, s.phantoms)
    add("rates: land=%.1f%% refuse=%.1f%% | consistency_score=%.0f/100",
        s.land_rate * 100, s.refuse_rate * 100, s.consistency)
    add("REACTION ready->cast (ms): n=%d avg=%.1f p50=%.1f p95=%.1f max=%.1f std=%.1f",
        s.reaction.n, s.reaction.avg, s.reaction.p50, s.reaction.p95, s.reaction.max, s.reaction.std)
    add("REACTION gcd_free->cast (ms): n=%d avg=%.1f p50=%.1f p95=%.1f max=%.1f std=%.1f",
        s.free_react.n, s.free_react.avg, s.free_react.p50, s.free_react.p95, s.free_react.max, s.free_react.std)
    add("CONFIRM fire->landed (ms): n=%d avg=%.1f p50=%.1f p95=%.1f max=%.1f",
        s.confirm.n, s.confirm.avg, s.confirm.p50, s.confirm.p95, s.confirm.max)
    add("REFUSE fire->refuse (ms): n=%d avg=%.1f p50=%.1f p95=%.1f max=%.1f",
        s.refuse_lat.n, s.refuse_lat.avg, s.refuse_lat.p50, s.refuse_lat.p95, s.refuse_lat.max)
    add("SPEED intercast landed->landed (ms): n=%d avg=%.0f p50=%.0f p95=%.0f std=%.0f",
        s.intercast.n, s.intercast.avg, s.intercast.p50, s.intercast.p95, s.intercast.std)
    add("SPEED tick cost (ms): n=%d avg=%.2f p50=%.2f max=%.2f std=%.2f",
        s.tick.n, s.tick.avg, s.tick.p50, s.tick.max, s.tick.std)
    add("one-liner: %s", Metrics.summary_line(s))
    return lines, s
end

-- Periodic DevLog emission (no-op if DevLog missing).
function Metrics.maybe_log(t)
    t = t or now()
    if (t - (Metrics._last_summary_t or 0)) < LOG_EVERY then return end
    Metrics._last_summary_t = t
    local line = Metrics.summary_line()
    Metrics._last_line = line
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then
        DL.log("rot.metrics", "%s", line)
    end
    -- Also append a dedicated metrics file when runtime Write/Append available.
    pcall(function()
        local dir = RaijinLab and RaijinLab.GetWoWDirectory and RaijinLab:GetWoWDirectory()
        if not dir then return end
        local path = dir .. "\\Logs\\raijinlab_rot_metrics.log"
        local chunk = string.format("%.3f %s\n", t, line)
        if RaijinLab.AppendFile then
            RaijinLab:AppendFile(path, chunk)
        elseif RaijinLab.WriteFile then
            -- best-effort rewrite of last line only is worse; skip without Append
        end
    end)
end

if RaijinLab then
    RaijinLab.RotationMetrics = Metrics
end

return Metrics
