from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Instrument.lua")
s = p.read_text(encoding="utf-8")

OLD = """        RaijinLab._instr_t = C_Timer.NewTicker(1.0, function() pcall(heartbeat) end)"""
NEW = """        -- OFF THE MAIN THREAD'S CRITICAL PATH.
        --
        -- heartbeat() does a synchronous TraceGround raycast plus a full world /
        -- services / rotation snapshot, all inline, once a second. At 30fps a
        -- frame is 33ms, so any of that landing in one frame is a visible hitch -
        -- reported as "a kind of stutter every second or so", which is exactly
        -- the cadence of this ticker.
        --
        -- NOT reduced or throttled: the same work still happens, at the same 1Hz,
        -- with the same detail. It is submitted to the frame-budgeted Scheduler
        -- as a LOW-priority job instead, so it yields when the frame's budget is
        -- spent and resumes on the next one. Costly instrumentation becomes
        -- something the frame can absorb rather than something it must swallow
        -- whole.
        RaijinLab._instr_t = C_Timer.NewTicker(1.0, function()
            local S = RaijinLab.Scheduler
            if S and S.run then
                S.run(function()
                    -- heartbeat yields internally at its section boundaries
                    pcall(heartbeat)
                end, S.PRIO and S.PRIO.LOW or 3)
            else
                pcall(heartbeat)          -- no scheduler yet: better late than never
            end
        end)"""
assert OLD in s, "instrument ticker not found"
s = s.replace(OLD, NEW, 1)

# let the heartbeat yield between its sections so one frame never swallows it all
OLD2 = """    local Nv = RaijinLab.Navigator
    if Nv then"""
NEW2 = """    -- Section boundary: give the frame back if we have used our slice. Running
    -- as a Scheduler coroutine makes this a real yield; called directly it is a
    -- no-op, so the function stays correct either way.
    yield_if_spent()

    local Nv = RaijinLab.Navigator
    if Nv then"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)

OLD3 = """    local S = RaijinLab.Scheduler
    if S and S.stats then"""
NEW3 = """    yield_if_spent()

    local S = RaijinLab.Scheduler
    if S and S.stats then"""
assert OLD3 in s
s = s.replace(OLD3, NEW3, 1)

# define the helper above the heartbeat
OLD4 = "local function heartbeat("
NEW4 = """-- Yield the rest of this frame if the scheduler says our slice is spent.
-- Safe to call outside a coroutine: coroutine.yield only runs when we are in
-- one, and Scheduler.run always puts us in one.
local function yield_if_spent()
    local S = RaijinLab.Scheduler
    if not (S and S.over_budget and S.over_budget()) then return end
    if coroutine and coroutine.running and coroutine.running() then
        pcall(coroutine.yield)
    end
end

local function heartbeat("""
assert OLD4 in s, "heartbeat definition not found"
s = s.replace(OLD4, NEW4, 1)
p.write_text(s, encoding="utf-8")
print("Instrument: 1Hz heartbeat runs as a budgeted, yielding job")
