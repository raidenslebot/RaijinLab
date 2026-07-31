"""Use the building data we already extracted, instead of discovering walls by
running into them.

We have 3,637 NavGrid tiles carved out of the client's own MPQ archives, and
building placements land in them as STRUCTURE cells. Two things then threw that
away:

  * NavGrid.walkable() returns UNKNOWN for STRUCTURE, because the footprint is an
    axis-aligned box that covers the courtyard and doorways as well as the walls.
    That is the right answer to "is this exact square passable" and the wrong one
    to "should I aim here" - and UNKNOWN meant the search happily targeted the
    middle of a church.
  * Pathfinder priced STRUCTURE at 1.8x, so cutting straight through a building
    stayed the shortest route. The wall was then left entirely to a 2.2 yard
    raycast, which is a reflex, not a plan.

The distinction that fixes it: a coarse footprint is weak evidence about a single
square and strong evidence about where to POINT. So it vetoes destinations and
dominates routing cost, while the raycast keeps its real job - the last two yards.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. never AIM inside a building footprint -----------------------------
su = R / "addon/modules/questing/Suite.lua"
s = su.read_text(encoding="utf-8")
OLD = """    local ok, verdict = pcall(NG.walkable, x, y)
    if not ok then return nil end"""
NEW = """    -- A DESTINATION INSIDE A BUILDING IS ALWAYS WRONG, even though the same cell
    -- may well be walkable. walkable() answers UNKNOWN for STRUCTURE because the
    -- footprint is an axis-aligned box that also covers the courtyard - correct
    -- for "can I stand on this square", useless for "should I walk 80 yards to
    -- stand there". For choosing where to AIM, a footprint is strong evidence:
    -- there is no reason to pick the middle of a church as a search waypoint.
    if NG.at then
        local okc, code = pcall(NG.at, x, y)
        if okc and code == NG.STRUCTURE then return false end
    end
    local ok, verdict = pcall(NG.walkable, x, y)
    if not ok then return nil end"""
assert OLD in s, "search oracle body not found"
s = s.replace(OLD, NEW, 1)
su.write_text(s, encoding="utf-8")
print("Suite: search oracle vetoes building footprints")

# ---- 2. route AROUND buildings, not through them --------------------------
pf = R / "addon/core/Pathfinder.lua"
t = pf.read_text(encoding="utf-8")
OLD2 = "                if code == NG.STRUCTURE then f = f * 1.8 end"
NEW2 = """                -- 1.8x made a building a speed bump: cutting straight through
                -- stayed the shortest route, so the planner routed into the
                -- church and left the wall to a 2.2yd raycast - a reflex standing
                -- in for a plan. We have the footprint; use it to go AROUND.
                --
                -- Deliberately a heavy cost rather than a hard block. The box
                -- covers doorways and courtyards too, so forbidding it outright
                -- would wall off buildings we are supposed to enter (inns, quest
                -- interiors). A large multiplier means "only through here if
                -- there is genuinely no way round", which is exactly the truth.
                if code == NG.STRUCTURE then f = f * (NG.STRUCTURE_COST or 12.0) end"""
assert OLD2 in t, "structure cost line not found"
t = t.replace(OLD2, NEW2, 1)
pf.write_text(t, encoding="utf-8")
print("Pathfinder: buildings are routed around, not shrugged at")

# ---- 3. name the constant where the rest of the grid tuning lives ---------
ng = R / "addon/core/NavGrid.lua"
u = ng.read_text(encoding="utf-8")
A = "NG.UNKNOWN, NG.WALK, NG.STEEP, NG.BLOCKED, NG.WATER, NG.STRUCTURE = 0, 1, 2, 3, 4, 5"
N = (A + """

-- Routing multiplier for a building footprint. Not a wall: the extracted box is
-- axis-aligned and includes doorways and courtyards, so a hard block would make
-- every inn unreachable. High enough that a route only crosses a building when
-- there is genuinely no way around it.
NG.STRUCTURE_COST = 12.0""")
assert A in u
u = u.replace(A, N, 1)
ng.write_text(u, encoding="utf-8")
print("NavGrid: STRUCTURE_COST named")
