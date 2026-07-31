"""Defend the two structure-planning guards the mutation run flagged UNDEFENDED.

A guard nothing tests is decoration: the full discriminate pass proved that
reverting the building cost to 1.8x, or flipping the footprint veto, changes no
test outcome. Fix by giving each a functional seam and driving it.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. extract the grid pricing into a pure, testable function ------------
pf = R / "addon/core/Pathfinder.lua"
s = pf.read_text(encoding="utf-8")

OLD = """                if code == NG.STRUCTURE then f = f * (NG.STRUCTURE_COST or 12.0) end"""
NEW = """                f = f * Pathfinder.grid_mult(code, NG)"""
assert OLD in s, "structure pricing line not found"
s = s.replace(OLD, NEW, 1)

# place the pure function near the top-level helpers (before first use)
ANCH = "function Pathfinder.plan_hier("
DEF = '''-- Pure grid-code price multiplier, extracted so it can be TESTED. The inline
-- version shipped as a comment with a number attached: the mutation harness
-- proved that reverting the building cost to 1.8x changed no test outcome, so
-- the whole go-around-buildings behaviour was one silent edit from vanishing.
--
-- STRUCTURE must dominate (>=10x): at 1.8x, cutting straight through a church
-- stays the shortest route and the wall is left to a 2.2yd raycast reflex.
-- It must NOT be infinite: the footprint box covers doorways and courtyards,
-- so a hard block would make every inn unreachable.
function Pathfinder.grid_mult(code, NG)
    if not (code and NG) then return 1.0 end
    if code == NG.STRUCTURE then return NG.STRUCTURE_COST or 12.0 end
    return 1.0
end

function Pathfinder.plan_hier('''
assert ANCH in s, "plan_hier anchor not found"
assert "function Pathfinder.grid_mult" not in s, "already extracted"
s = s.replace(ANCH, DEF, 1)
pf.write_text(s, encoding="utf-8")
print("Pathfinder: grid_mult extracted")

# ---- 2. tests that drive both seams ----------------------------------------
t = R / "tests" / "run_suite_tests.py"
u = t.read_text(encoding="utf-8")

# 2a. pathfinder group: find its check helper
import re
m = re.search(r"def test_pathfinder\(\).*?local function (\w+)\(name, cond\)", u, re.S)
assert m, "pathfinder check helper not found"
pfc = m.group(1)
# anchor: first use of that helper inside the group
m2 = re.search(r"def test_pathfinder\(\).*?\n(" + pfc + r"\(\")", u, re.S)
assert m2, "pathfinder first assertion not found"
i = m2.start(1)
BLOCK1 = f'''-- ---- buildings must dominate routing cost -------------------------------
-- The mutation harness proved this behaviour was UNDEFENDED: reverting the
-- structure multiplier to 1.8x changed no test outcome. At 1.8x the shortest
-- route is straight through the church.
local __NG = {{ STRUCTURE = 5, STRUCTURE_COST = 12.0 }}
{pfc}("structure routing cost dominates (>=10x)",
   Pathfinder.grid_mult(__NG.STRUCTURE, __NG) >= 10.0)
{pfc}("structure cost is finite (doorways must stay reachable)",
   Pathfinder.grid_mult(__NG.STRUCTURE, __NG) < 1000)
{pfc}("plain walk cells are not marked up",
   Pathfinder.grid_mult(1, __NG) == 1.0)
{pfc}("nil code prices neutral", Pathfinder.grid_mult(nil, __NG) == 1.0)

'''
u = u[:i] + BLOCK1 + u[i:]

# 2b. search group: drive Suite.search_oracle with a mocked NavGrid
m3 = re.search(r"def test_search_behavior\(\).*?local function (\w+)\(name, cond\)", u, re.S)
assert m3, "search check helper not found"
sc = m3.group(1)
m4 = re.search(r"def test_search_behavior\(\).*?\n(" + sc + r"\(\")", u, re.S)
assert m4, "search first assertion not found"
j = m4.start(1)
BLOCK2 = f'''-- ---- never aim a search leg inside a building ---------------------------
-- 18 consecutive live search legs pointed at the inside of the same church.
-- The footprint veto was UNDEFENDED: flipping it to accept changed no test.
RaijinLab.NavGrid = {{
    STRUCTURE = 5,
    at = function(x, y) return (x == 100) and 5 or 1 end,   -- structure at x=100
    walkable = function(x, y) return true end,
}}
{sc}("a building footprint cell is vetoed as a destination",
   Suite.search_oracle(100, 0) == false)
{sc}("open ground is still accepted", Suite.search_oracle(50, 0) == true)
RaijinLab.NavGrid = nil
{sc}("no navgrid = no verdict, not a veto", Suite.search_oracle(100, 0) == nil)

'''
u = u[:j] + BLOCK2 + u[j:]
t.write_text(u, encoding="utf-8")
print("tests: both seams driven")

# ---- 3. retarget the pathfinder mutation at the extracted seam --------------
d = R / "tests" / "discriminate.py"
v = d.read_text(encoding="utf-8")
OLD3 = '''     "if code == NG.STRUCTURE then f = f * (NG.STRUCTURE_COST or 12.0) end",
     "if code == NG.STRUCTURE then f = f * 1.8 end",'''
NEW3 = '''     "    if code == NG.STRUCTURE then return NG.STRUCTURE_COST or 12.0 end",
     "    if code == NG.STRUCTURE then return 1.8 end",'''
assert OLD3 in v, "pathfinder mutation entry not found"
v = v.replace(OLD3, NEW3, 1)
d.write_text(v, encoding="utf-8")
print("discriminate: mutation retargeted at grid_mult")
