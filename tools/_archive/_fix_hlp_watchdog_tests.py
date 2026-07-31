from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# ---- 1. plan_hier no longer claims a global no_path from mesh-local evidence
OLD = """-- proven-unreachable goal returns no_path (not a doomed search)
local _, istatus = PF.plan_hier(sxy, { x = 6000, y = 0, z = 0 }, {})
hc("plan_hier reports no_path for an unreachable goal", istatus == "no_path")"""
NEW = """-- CONTRACT CHANGED DELIBERATELY. This asserted that a coarse-flood miss is
-- "no_path". It is not: the flood only walks blocks WorldMesh has already
-- recorded, so unexplored ground is indistinguishable from a wall, and after a
-- resurrect/hearth/flight the mesh holds disconnected islands. Promoting that
-- mesh-local miss to a global verdict made the bot stand still forever for
-- places it could have walked to.
--
-- It now reports "coarse_miss" and the caller falls through to the tiers that
-- can actually see the world (TIER 2 reads NavGrid terrain extracted from the
-- client). Only a searcher with real visibility earns the right to say no.
local _, istatus = PF.plan_hier(sxy, { x = 6000, y = 0, z = 0 }, {})
hc("plan_hier reports coarse_miss, not a global no_path",
   istatus == "coarse_miss")
hc("plan_hier never claims no_path from mesh-only evidence",
   istatus ~= "no_path")"""
assert OLD in s, "hlp assertion not found"
s = s.replace(OLD, NEW, 1)

# ---- 2. defend the watchdog fix (mutation harness called it DECORATIVE) ----
A = 'local function wc(name, cond) if not cond then wd_fails[#wd_fails+1] = name end end'
j = s.find(A)
assert j > 0, "watchdog wc helper not found"
j = j + len(A) + 1
BLOCK = '''-- ---- NEVER-PROGRESSED IS THE WORST CASE, NOT THE HEALTHIEST ------------
-- since_progress() answered 0 while _last_progress was still at its initial 0,
-- so "we have never once recorded progress" read as "progress happened this
-- instant". A bot that wedged before its first step was invisible to the
-- watchdog permanently, and the longer it sat the healthier it looked.
Watchdog._last_progress = 0
Watchdog._armed_t = nil
wc("unarmed watchdog does not accuse", Watchdog.since_progress() == 0)
Watchdog._armed_t = __t - 300
wc("armed and never progressed = 300s, not 0s",
   math.abs(Watchdog.since_progress() - 300) < 0.01)
wc("...and that is long enough to trip any threshold",
   Watchdog.since_progress() > 60)
-- a real progress stamp still wins over the armed clock
Watchdog._last_progress = __t - 5
wc("recorded progress is measured from the stamp",
   math.abs(Watchdog.since_progress() - 5) < 0.01)
Watchdog._last_progress = 0; Watchdog._armed_t = nil

'''
s = s[:j] + BLOCK + s[j:]
p.write_text(s, encoding="utf-8")
print("tests updated: plan_hier coarse_miss + watchdog never-progressed")
