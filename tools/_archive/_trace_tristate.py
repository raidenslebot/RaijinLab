from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. runtime: distinguish "threw" from "blocked" ------------------------
om = R / "runtime/src/game/ObjectManager.cpp"
s = om.read_text(encoding="utf-8", errors="ignore")
OLD = """bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags) {
    Vec3 s = start, e = end, h{};
    float dist = 1.f;
    int rc = SafeIntersect(&s, &e, &h, &dist, flags);
    if (rc < 0) return false;
    if (hit) *hit = h;
    return rc == 0;
}"""
NEW = """// Tri-state world raycast: 1 = clear, 0 = blocked, -1 = could not tell.
//
// The bool version folded "the intersect call raised an exception" into the same
// answer as "solid geometry is in the way", and returned before writing the hit
// point - so a failed raycast reported a WALL at garbage coordinates. Every
// consumer then treated a sensor failure as an obstacle: the navigator detours
// around nothing, and (worse) the same folding meant a genuine wall and a broken
// probe were indistinguishable while debugging a bot that kept hitting walls.
//
// This is the same defect family as the quest-giver stub answering 0: a value
// that is in-range and confident but means "no answer".
int TraceLineEx(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags) {
    Vec3 s = start, e = end, h{};
    float dist = 1.f;
    int rc = SafeIntersect(&s, &e, &h, &dist, flags);
    if (rc < 0) return -1;               // threw: we know nothing
    if (hit) *hit = h;
    return rc == 0 ? 1 : 0;              // 1 clear, 0 blocked
}

// Kept for existing callers that only need a boolean. Note the asymmetry: an
// unknown result answers "not clear", which is the SAFE direction for a
// line-of-sight question (do not claim a clear shot we could not verify) but the
// WRONG direction for an obstacle question. Obstacle callers must use
// TraceLineEx and handle -1 themselves.
bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags) {
    return TraceLineEx(start, end, hit, flags) == 1;
}"""
assert OLD in s, "TraceLine not found"
s = s.replace(OLD, NEW, 1)
om.write_text(s, encoding="utf-8")
print("ObjectManager.cpp: TraceLineEx tri-state")

h = R / "runtime/src/game/ObjectManager.h"
t = h.read_text(encoding="utf-8", errors="ignore")
A = "bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags);"
if "TraceLineEx" not in t:
    assert A in t, "TraceLine decl not found"
    t = t.replace(A, "int TraceLineEx(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags);\n" + A, 1)
    h.write_text(t, encoding="utf-8")
    print("ObjectManager.h: declared")

# ---- 2. Dispatch: emit the third state -------------------------------------
d = R / "runtime/src/bridge/Dispatch.cpp"
u = d.read_text(encoding="utf-8", errors="ignore")
OLD2 = """        Vec3 hit = e;
        bool clear = OM::TraceLine(s, e, &hit, flags);
        char buf[96];
        snprintf(buf, sizeof(buf), "%d|%.3f|%.3f|%.3f", clear ? 0 : 1, hit.x, hit.y, hit.z);
        return PushString(L, buf);"""
NEW2 = """        Vec3 hit = e;
        // blocked field is now tri-state: 0 clear, 1 blocked, -1 could not tell.
        // It used to pack a thrown raycast as blocked=1 with an unwritten hit
        // point, so a sensor failure was indistinguishable from a wall and the
        // coordinates were garbage.
        int rc = OM::TraceLineEx(s, e, &hit, flags);
        int blocked = (rc == 1) ? 0 : ((rc == 0) ? 1 : -1);
        char buf[96];
        snprintf(buf, sizeof(buf), "%d|%.3f|%.3f|%.3f", blocked, hit.x, hit.y, hit.z);
        return PushString(L, buf);"""
assert OLD2 in u, "TraceLine dispatch not found"
u = u.replace(OLD2, NEW2, 1)
import re
u = re.sub(r'const char\* kVersion = "[^"]+";',
           'const char* kVersion = "1.8.16-trace3";', u, count=1)
d.write_text(u, encoding="utf-8")
print("Dispatch.cpp: tri-state packing, version 1.8.16-trace3")

# ---- 3. Lua: surface the third state --------------------------------------
a = R / "addon/core/API.lua"
v = a.read_text(encoding="utf-8")
OLD3 = """    local b, hx, hy, hz = r:match("(%-?%d+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
    if not b then return false end
    return b == "1", tonumber(hx), tonumber(hy), tonumber(hz)"""
NEW3 = """    local b, hx, hy, hz = r:match("(%-?%d+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
    if not b then return false end
    -- THIRD RETURN IS THE HONEST ONE. blocked=-1 means the raycast threw, which
    -- the runtime used to pack as blocked=1 - so a broken probe read as a wall
    -- (at garbage coordinates). Existing callers keep the boolean contract, and
    -- for them an unknown answers "not blocked": inventing walls out of sensor
    -- failures is what makes a bot detour around nothing. Callers that must not
    -- guess check the 4th return.
    if b == "-1" then
        return false, nil, nil, nil, "unknown"
    end
    return b == "1", tonumber(hx), tonumber(hy), tonumber(hz), (b == "1") and "blocked" or "clear\""""
assert OLD3 in v, "TraceLine wrapper not found"
v = v.replace(OLD3, NEW3, 1)

# TraceGround must not report a floor from an unknown trace
OLD4 = """    local blocked, _, _, hz = RaijinLab:TraceLine(x, y, z + up, x, y, z - down, 0x100111)
    if blocked and hz then return hz end
    return nil"""
NEW4 = """    local blocked, _, _, hz, state = RaijinLab:TraceLine(x, y, z + up, x, y, z - down, 0x100111)
    -- An unknown trace is not "no floor" and not a floor either: return nil so
    -- the caller's own three-valued handling decides, rather than manufacturing
    -- a cliff out of a failed raycast.
    if state == "unknown" then return nil end
    if blocked and hz then return hz end
    return nil"""
assert OLD4 in v, "TraceGround body not found"
v = v.replace(OLD4, NEW4, 1)
a.write_text(v, encoding="utf-8")
print("API.lua: TraceLine returns a state, TraceGround refuses to guess")
