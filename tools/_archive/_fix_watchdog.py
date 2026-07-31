from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Watchdog.lua")
s = p.read_text(encoding="utf-8")

OLD = """function Watchdog.since_progress()
    if Watchdog._last_progress == 0 then return 0 end
    return now() - Watchdog._last_progress
end"""
NEW = """-- WHEN WAS THE LAST TIME ANYTHING ACTUALLY HAPPENED.
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
end"""
assert OLD in s, "since_progress not found"
s = s.replace(OLD, NEW, 1)

# reset() must re-arm, or a reset leaves the never-progressed clock running
OLD2 = """    Watchdog._last_progress = now(); Watchdog._level = 0; Watchdog._pos = nil"""
NEW2 = """    Watchdog._last_progress = now(); Watchdog._level = 0; Watchdog._pos = nil
    Watchdog._armed_t = now()"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)
p.write_text(s, encoding="utf-8")
print("Watchdog: never-progressed is now the worst case, not the healthiest")

# ---- defend it -------------------------------------------------------------
d = Path(r"C:\Ascension\Workspace\RaijinLab\tests\discriminate.py")
t = d.read_text(encoding="utf-8")
A = """    # ---- Absence of evidence, found by the 2026-07-28 gate audit -------------"""
N = """    # ---- Absence of evidence, found by the 2026-07-28 gate audit -------------
    ("liveness", "addon/core/Watchdog.lua",
     "        if not t0 then return 0 end        -- genuinely just started: not an accusation\\n"
     "        return now() - t0",
     "        return 0",
     "never-having-progressed reads as perfectly healthy - the watchdog cannot "
     "see a bot that wedged before its first step"),"""
assert A in t
d.write_text(t.replace(A, N, 1), encoding="utf-8")
print("discriminate: watchdog entry added")
