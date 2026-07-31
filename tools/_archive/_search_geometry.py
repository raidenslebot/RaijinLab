"""Close the search loop: geometry in, failure back.

Live evidence for why: 18 of 18 destination choices in the session were the
SAME cell (1840,1520) - straight into a building wall. best() picks by belief
mass alone, observe() only drains mass at places we REACH, and a failed leg just
cleared the goal. So: cannot reach -> mass survives -> same choice -> cannot
reach, forever. The field cannot tell "have not looked there yet" from "cannot
get there", and nothing ever told it.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. SearchField learns two things: geometry veto + failure drain -------
sf = R / "addon/core/SearchField.lua"
s = sf.read_text(encoding="utf-8")

OLD = "function SF:neighbourhood(x, y, r)"
NEW = """-- A LEG WE COULD NOT REACH MUST STOP BEING THE BEST LEG.
--
-- observe() drains mass where we ARRIVE and look around. But a destination
-- behind a wall is never arrived at, so its mass survived every failure and
-- best() re-chose the identical cell forever - live log: 18/18 destination
-- picks were the same spot, each one a march into the same building. Navigation
-- failure is evidence too: not "the target is not there", but "I cannot search
-- there from here", which for a SEARCH is operationally the same thing. Drain
-- it like a look, and the next best() moves on.
function SF:unreachable(x, y, radius)
    return self:observe(x, y, radius or (SF.CELL * 1.5))
end

-- GEOMETRY VETO for best(). The field itself stays pure belief - geometry is
-- the caller's knowledge - so best() accepts an oracle instead of importing
-- NavGrid here. Returning false vetoes a candidate cell; the mass is dropped so
-- ranking does not immediately resurface it. nil/absent oracle = no veto, so
-- existing callers and tests are untouched.
function SF:neighbourhood(x, y, r)"""
assert OLD in s
s = s.replace(OLD, NEW, 1)

# thread the oracle through best(): veto at the refinement step
OLD2 = """                if self.cells[key_of(cx, cy)] then
                    local mx, my = centre_of(cx, cy)
                    local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)"""
NEW2 = """                if self.cells[key_of(cx, cy)] then
                    local mx, my = centre_of(cx, cy)
                    if opts.oracle and opts.oracle(mx, my) == false then
                        -- geometry says no: not a place a character can stand.
                        -- Drop the mass so ranking cannot resurface it next call.
                        local k2 = key_of(cx, cy)
                        local dead = self.cells[k2]
                        if dead then
                            self.total = self.total - (dead.m or 0)
                            self.cells[k2] = nil
                            self.n = self.n - 1
                        end
                    end
                    local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
                    if opts.oracle and not self.cells[key_of(cx, cy)] then d = -1 end"""
assert OLD2 in s, "refinement step not found"
s = s.replace(OLD2, NEW2, 1)
sf.write_text(s, encoding="utf-8")
print("SearchField: unreachable() drain + geometry oracle in best()")

# ---- 2. Suite: supply the oracle and report failures back ------------------
su = R / "addon/modules/questing/Suite.lua"
t = su.read_text(encoding="utf-8")

# find where best() is called for search legs
import re
m = re.search(r"local bx, by[^\n]* = ([a-zA-Z_.]+):best\(px, py(, [^)]*)?\)", t)
assert m, "best() call not found in Suite"
call = m.group(0)
fld = m.group(1)
NEWCALL = (fld + ":best(px, py, { oracle = Suite.search_oracle })")
prefix = call.split(" = ")[0]
t = t.replace(call, prefix + " = " + NEWCALL, 1)

# the oracle + failure feedback helpers
ANCH = "function Suite.search_for(kind, label, q)"
HELPERS = """-- CAN A CHARACTER STAND THERE? The belief field is pure probability and knows
-- nothing about geometry, which is how 18 consecutive search legs pointed at
-- the inside of the same building. We have real client terrain (NavGrid tiles
-- extracted from the MPQs) - use it. Three-valued: only a definite "no" vetoes,
-- because an unloaded tile is ignorance, not a wall.
function Suite.search_oracle(x, y)
    local NG = RaijinLab.NavGrid
    if not (NG and NG.walkable) then return nil end
    local ok, verdict = pcall(NG.walkable, x, y)
    if not ok then return nil end
    -- NavGrid.walkable is Know-style three-valued: collapse only a proven no.
    local K = RaijinLab.Know
    if K and K.is_no and K.is_no(verdict) then return false end
    if verdict == false then return false end
    return nil
end

""" + ANCH
assert ANCH in t
t = t.replace(ANCH, HELPERS, 1)

# failure feedback: when a search leg dies, drain the field at the target
OLD3 = """    if st == "stuck" or st == "failed" or st == "fell" or st == "idle" then
        Suite._goal = nil
        Suite._goal_t = 0
    end"""
NEW3 = """    if st == "stuck" or st == "failed" or st == "fell" or st == "idle" then
        -- FAILURE IS EVIDENCE. Without this, the mass at an unreachable target
        -- survived and best() re-chose the identical cell forever - the bot ran
        -- at the same wall 18 times in one session. Draining it here is what
        -- makes the next choice a DIFFERENT place.
        local g = Suite._goal
        if g and g.x then
            for _, f in pairs(Suite._fields or {}) do
                if f and f.unreachable then pcall(f.unreachable, f, g.x, g.y) end
            end
        end
        Suite._goal = nil
        Suite._goal_t = 0
    end"""
assert OLD3 in t, "leg failure branch not found"
t = t.replace(OLD3, NEW3, 1)
su.write_text(t, encoding="utf-8")
print("Suite: oracle wired into best(); failed legs drain the field")
