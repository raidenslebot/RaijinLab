from pathlib import Path

# ---- 1. extract the floor decision so it can be tested at all --------------
n = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
t = n.read_text(encoding="utf-8")

OLD = """    -- Swimming is a definite, cheap, stock answer. Ask it before accusing.
    if gz == nil and IsSwimming and IsSwimming() then
        gz = pz              -- in water: floating is not falling
        a.airborne_t = nil
    end
    if gz == nil then"""
NEW = """    -- Swimming is a definite, cheap, stock answer. Ask it before accusing.
    -- Kept as a named pure function so it can be tested without a tick: the
    -- version inlined here first shipped with no test that could reach it, and
    -- the mutation harness reported it DECORATIVE - a fix nothing defends.
    if Navigator.floor_verdict(gz, IsSwimming and IsSwimming()) == "swimming" then
        gz = pz              -- in water: floating is not falling
        a.airborne_t = nil
    end
    if gz == nil then"""
if OLD in t:
    t = t.replace(OLD, NEW, 1)
else:
    assert "Navigator.floor_verdict(gz" in t, "swim gate missing AND not already patched"

# define it near the top-level helpers
ANCH = "local function set_forward("
DEF = '''-- WHAT A MISSING FLOOR ACTUALLY MEANS.
--
-- The downward trace spans 6yd and its flags carry no liquid bit, so it cannot
-- see a water surface at all. The planner routes through water on purpose, so
-- "the ray found nothing" is the NORMAL reading while swimming - and treating it
-- as falling aborted with "stopped: left the ground" in the middle of a lake,
-- then burned a false BLOCKED cell into the persistent mesh on the way out.
--
-- Three-valued on purpose. "unknown" is not "airborne": only a definite no-floor
-- with a definite not-swimming is grounds for the fall abort.
function Navigator.floor_verdict(gz, swimming)
    if gz ~= nil then return "grounded" end
    if swimming then return "swimming" end
    return "airborne"
end

local function set_forward('''
if "function Navigator.floor_verdict" not in t:
    assert ANCH in t, "set_forward anchor missing"
    t = t.replace(ANCH, DEF, 1)
n.write_text(t, encoding="utf-8")
print("Navigator.floor_verdict extracted")

# ---- 2. repair the stale mutation anchor + retarget the swim mutation ------
d = Path(r"C:\Ascension\Workspace\RaijinLab\tests\discriminate.py")
s = d.read_text(encoding="utf-8")
s = s.replace(
    "'    if not (c and c.px and c.py) then return true end',\n"
    "     '    if not (c and c.px and c.py) then return false end',",
    "'    if not (c and type(c.px) == \"number\" and type(c.py) == \"number\") then',\n"
    "     '    if false then',", 1)
s = s.replace(
    '"    if gz == nil and IsSwimming and IsSwimming() then",\n'
    '     "    if false then",',
    '\'    if swimming then return "swimming" end\',\n'
    '     \'    if swimming then return "airborne" end\',', 1)
d.write_text(s, encoding="utf-8")
print("discriminate: anchors repaired")

# ---- 3. tests that actually reach both fixes -------------------------------
p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
u = p.read_text(encoding="utf-8")

A2 = 'nc("norm negative wraps"'
assert A2 in u, "navigator test anchor not found"
NEW2 = '''-- ---- a missing floor is not automatically a fall ------------------------
-- Live symptom this defends: "stopped left the ground and not moving" while the
-- character floated in a pond. The trace cannot see water, so no-hit is the
-- normal reading when swimming.
nc("floor found -> grounded", Navigator.floor_verdict(12.5, false) == "grounded")
nc("floor found while swimming is still grounded",
   Navigator.floor_verdict(12.5, true) == "grounded")
nc("no floor + swimming -> swimming, NOT a fall",
   Navigator.floor_verdict(nil, true) == "swimming")
nc("no floor + not swimming -> airborne",
   Navigator.floor_verdict(nil, false) == "airborne")
-- a nil swim probe must not read as "definitely not swimming"... it is the same
-- absence-of-evidence trap, so it still reports airborne only on a real false
nc("no floor + unknown swim state -> airborne (explicit, not accidental)",
   Navigator.floor_verdict(nil, nil) == "airborne")

''' + A2
if "floor found -> grounded" not in u:
    u = u.replace(A2, NEW2, 1)

A3 = 'local function pc(name, cond) if not cond then pg_fails[#pg_fails+1] = name end end'
if A3 in u:
    NEW3 = '''-- An ALL-ZERO camera read is a FAILED read, not a witness at the world origin.
-- 0 is truthy in Lua, so `c.px and c.py` accepted it and the guard then trusted
-- garbage - the same shape as the quest-giver stub answering 0.
RaijinLab.GetCameraData = function() return { px = 0, py = 0, pz = 0 } end
pc("all-zero camera is not a witness (accepts the reading)",
    RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2) == true)
RaijinLab.GetCameraData = function() return { px = 1723.7, py = 1623.3, pz = 129.3 } end
pc("a real camera still rejects a far-away position",
    RaijinLab.PlausiblePlayerPos(0.0, 118.8, 0.0) == false)

'''
    if "all-zero camera is not a witness" not in u:
        u = u.replace(A3, A3 + chr(10) + NEW3, 1)
    print("position-guard tests added")
else:
    print("WARNING: position-guard anchor not found - camera test NOT added")

p.write_text(u, encoding="utf-8")
print("navigator tests added")
