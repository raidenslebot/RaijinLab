-- Replay - re-execute decisions from Snapshot history.
--
-- Snapshots already write a once-per-second picture of the bot. This module
-- turns that stream into something queryable: "what did it know at T", "which
-- goals were held while stationary", "list every assumption made".
--
-- Full binary session re-execution against a simulator is the long-term form;
-- today we provide offline analysis of the in-memory ring + optional file dump
-- so a human (or the sim harness) can ask questions without the live client.

local Replay = {}

Replay.RING = 600          -- ~10 minutes at 1Hz
Replay._ring = {}
Replay._n = 0
Replay._file = nil

local function now() return (GetTime and GetTime()) or 0 end

function Replay.capture(frame)
    if type(frame) ~= "table" then return end
    frame.t = frame.t or now()
    local n = Replay._n + 1
    if n > Replay.RING then
        -- drop oldest by shifting index (keep ring dense for ipairs)
        table.remove(Replay._ring, 1)
        n = Replay.RING
    end
    Replay._n = n
    Replay._ring[n] = frame
end

-- Hook Snapshot: when a full snapshot is built, keep a copy.
function Replay.hook_snapshot()
    local S = RaijinLab and RaijinLab.Snapshot
    if not S or Replay._hooked then return end
    Replay._hooked = true
    local prev = S.emit
    if type(prev) ~= "function" then
        -- Snapshot may use a different entry; sample domains ourselves.
        return
    end
    S.emit = function(...)
        local ok, frame = pcall(function()
            return {
                t = now(),
                player = S.player and S.player() or nil,
                goal = S.goal and S.goal() or nil,
            }
        end)
        if ok and frame then Replay.capture(frame) end
        return prev(...)
    end
end

function Replay.sample_now()
    local S = RaijinLab and RaijinLab.Snapshot
    local frame = { t = now() }
    if S then
        if S.player then local ok, v = pcall(S.player); if ok then frame.player = v end end
        if S.goal then local ok, v = pcall(S.goal); if ok then frame.goal = v end end
        if S.nav then local ok, v = pcall(S.nav); if ok then frame.nav = v end end
    end
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assumptions then frame.assumptions = Kn.assumptions() end
    local F = RaijinLab and RaijinLab.Fail
    if F and F.report then frame.fails = #F.report() end
    Replay.capture(frame)
    return frame
end

function Replay.count() return Replay._n end

function Replay.at(i)
    return Replay._ring[i]
end

function Replay.latest()
    return Replay._ring[Replay._n]
end

-- Find frames where the character was essentially stationary while a goal ran.
function Replay.stationary_with_goal(min_secs)
    min_secs = min_secs or 30
    local out = {}
    local run_start, run_goal, last_xy = nil, nil, nil
    for i = 1, Replay._n do
        local f = Replay._ring[i]
        local p = f and f.player
        local g = f and f.goal and f.goal.goal
        local xy = p and p.x and { p.x, p.y } or nil
        local moved = false
        if xy and last_xy then
            local dx, dy = xy[1] - last_xy[1], xy[2] - last_xy[2]
            moved = (dx * dx + dy * dy) > 9
        end
        if g and g ~= "idle" and xy and not moved then
            if not run_start then run_start, run_goal = f.t, g end
        else
            if run_start and (f.t - run_start) >= min_secs then
                out[#out + 1] = { from = run_start, to = f.t, goal = run_goal,
                                  secs = f.t - run_start }
            end
            run_start, run_goal = nil, nil
        end
        if xy then last_xy = xy end
    end
    return out
end

function Replay.report()
    local lines = {}
    lines[#lines + 1] = string.format("  replay ring: %d frames", Replay._n)
    local late = Replay.latest()
    if late and late.player and late.player.x then
        lines[#lines + 1] = string.format("  last pos: %.1f, %.1f  goal=%s",
            late.player.x, late.player.y,
            tostring(late.goal and late.goal.goal or "?"))
    end
    local stuck = Replay.stationary_with_goal(30)
    if #stuck > 0 then
        local s = stuck[#stuck]
        lines[#lines + 1] = string.format(
            "  |cffff5555stationary %.0fs with goal=%s|r", s.secs, tostring(s.goal))
    end
    return lines
end

-- Compact dump for offline analysis / sim import. One frame per line, key=value.
-- Not full JSON (no cjson on 3.3.5); the sim can parse this line format.
function Replay.dump_lines(max_frames)
    max_frames = max_frames or Replay._n
    local out = {}
    local start = math.max(1, Replay._n - max_frames + 1)
    for i = start, Replay._n do
        local f = Replay._ring[i]
        if f then
            local p = f.player or {}
            local g = f.goal or {}
            out[#out + 1] = string.format(
                "t=%.1f x=%.1f y=%.1f z=%.1f hp=%s goal=%s combat=%s",
                f.t or 0, p.x or 0, p.y or 0, p.z or 0,
                tostring(p.hp or "?"),
                tostring(g.goal or "idle"),
                tostring(p.combat and 1 or 0))
        end
    end
    return out
end

-- Write dump to SavedVariables so it survives /reload for later export.
function Replay.persist_dump(max_frames)
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.replay_dump = {
        t = now(),
        n = Replay._n,
        lines = Replay.dump_lines(max_frames or 120),
    }
    return #(RaijinLabDB.replay_dump.lines or {})
end

function Replay.last_dump()
    return RaijinLabDB and RaijinLabDB.replay_dump
end

-- Start a 1Hz sampler if Snapshot is not emitting into us.
function Replay.start()
    if Replay._running then return end
    Replay._running = true
    Replay.hook_snapshot()
    if C_Timer and C_Timer.NewTicker then
        Replay._ticker = C_Timer.NewTicker(1.0, function()
            -- Idle suite: do not sample every second while the player is just
            -- standing around with master OFF.
            if RaijinLab and RaijinLab.Master and RaijinLab.Master.suppressed
                and RaijinLab.Master.suppressed() then
                return
            end
            pcall(Replay.sample_now)
        end)
    end
end

if RaijinLab then RaijinLab.Replay = Replay end
return Replay
