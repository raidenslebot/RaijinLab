from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# extend the position-guard group: it already loads slices of API.lua
A = '''pg_fails = {}
local function pc(name, cond) if not cond then pg_fails[#pg_fails+1] = name end end'''
assert A in s, "pg helper not found"

N = A + '''

-- ---- TRI-STATE TRACELINE --------------------------------------------------
-- The runtime used to pack a THROWN raycast as blocked=1 with an unwritten hit
-- point: a broken probe read as a wall at garbage coordinates, and the navigator
-- detoured around nothing. blocked=-1 is the honest third state. These drive the
-- REAL wrapper extracted from API.lua below.
'''
s = s.replace(A, N, 1)

# extract the TraceLine wrapper into the same lua runtime, after the guard slice
OLD = '''    if i0 >= 0:
        j0 = src.find("function RaijinLab:ObjectPosition", i0)
        lua.execute(src[i0 - len("RaijinLab."):j0])'''
NEW = '''    if i0 >= 0:
        j0 = src.find("function RaijinLab:ObjectPosition", i0)
        lua.execute(src[i0 - len("RaijinLab."):j0])
    # Also extract the TraceLine wrapper (pure string parsing over RLCall) and
    # TraceGround, with RLCall mocked per-case. Loading whole API.lua would test
    # the harness, not the code - same reasoning as the guard slice above.
    t0 = src.find("function RaijinLab:TraceLine")
    t1 = src.find("function RaijinLab:TraceGround")
    t2 = src.find("\\nend", t1)
    assert t0 > 0 and t1 > t0 and t2 > t1, "TraceLine/TraceGround not found in API.lua"
    lua.execute("local function RLCall(...) return __trace_r end\\n"
                + src[t0:t2 + 4].replace("RLCall(", "RLCall(", 1))'''
assert OLD in s, "guard extraction not found"
s = s.replace(OLD, NEW, 1)

# the Lua body: cases
B = '''RaijinLab.GetCameraData = function() return { px = 0, py = 0, pz = 0 } end'''
assert B in s
CASES = '''__trace_r = "1|10.000|20.000|30.000"
local b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("blocked=1 parses as a real hit", b == true and hx == 10 and st == "blocked")
__trace_r = "0|1.000|1.000|1.000"
b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("blocked=0 is clear", b == false and st == "clear")
__trace_r = "-1|0.000|0.000|0.000"
b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("a thrown raycast is UNKNOWN, not a wall", b == false and st == "unknown")
pc("...and carries no coordinates", hx == nil and hz == nil)
-- TraceGround must refuse to answer from an unknown trace
__trace_r = "-1|0.000|0.000|0.000"
pc("TraceGround does not invent a floor from a failed ray",
   RaijinLab:TraceGround(0, 0, 50, 3, 30) == nil)
__trace_r = "1|0.000|0.000|42.500"
pc("TraceGround still reads a real floor",
   RaijinLab:TraceGround(0, 0, 50, 3, 30) == 42.5)

''' + B
s = s.replace(B, CASES, 1)
p.write_text(s, encoding="utf-8")
print("tri-state trace tests added to the position-guard group")
