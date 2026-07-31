"""Real pitch control + retire the lying stubs.

SetPitch returned PushBool(true) while doing nothing - a success for a call with
no implementation, the same in-range-value-meaning-no-answer trap as the
quest-giver stub. Swim depth control (the water plan's ascend/descend axis)
needs REAL pitch input, and the handlers exist in the client:

    PitchUpStart   0x005FC8E0     PitchUpStop   0x005FC570
    PitchDownStart 0x005FC920     PitchDownStop 0x005FC5C0

verified against vendor/WowAutoSDK/include/AscensionLuaHandlers.h:1823-1826
(note: the same four addresses also back VehicleAimUp/Down - same natives).
Hold-style, exactly like MoveForward/TurnLeft: keyboard-input steering, NOT
click-to-move, and NOT a raw memory write to the pitch field.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. Actions: the four natives, hold-style ------------------------------
ac = R / "runtime/src/game/Actions.cpp"
s = ac.read_text(encoding="utf-8", errors="ignore")

A1 = "constexpr uintptr_t kMoveForwardStart   = 0x005FC200;"
N1 = A1 + """
// Swim/fly pitch (verified AscensionLuaHandlers.h:1823-1826; the same natives
// back VehicleAimUp/Down). Hold-style input like every other movement key.
constexpr uintptr_t kPitchUpStart       = 0x005FC8E0;
constexpr uintptr_t kPitchUpStop        = 0x005FC570;
constexpr uintptr_t kPitchDownStart     = 0x005FC920;
constexpr uintptr_t kPitchDownStop      = 0x005FC5C0;"""
assert A1 in s and "kPitchUpStart" not in s
s = s.replace(A1, N1, 1)

A2 = """bool MoveForward(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kMoveForwardStart : kMoveForwardStop)) > 0;
}"""
N2 = A2 + """

// Pitch is the swim/fly vertical AIM axis - with pitch held down-forward, plain
// MoveForward descends. This replaces a SetPitch stub that answered true while
// doing nothing, which made depth control look implemented for months.
// Mutually exclusive by construction: starting one direction stops the other,
// because holding both natives leaves the client's pitch state wedged.
bool PitchUp(bool start) {
    SoftHardwareUnlock();
    if (start) SafeVoid(At(kPitchDownStop));
    return SafeVoid(At(start ? kPitchUpStart : kPitchUpStop)) > 0;
}
bool PitchDown(bool start) {
    SoftHardwareUnlock();
    if (start) SafeVoid(At(kPitchUpStop));
    return SafeVoid(At(start ? kPitchDownStart : kPitchDownStop)) > 0;
}"""
assert A2 in s and "bool PitchUp" not in s
s = s.replace(A2, N2, 1)
ac.write_text(s, encoding="utf-8")
print("Actions.cpp: PitchUp/PitchDown implemented")

h = R / "runtime/src/game/Actions.h"
t = h.read_text(encoding="utf-8", errors="ignore")
A3 = "bool MoveForward(bool start);"
assert A3 in t
if "PitchUp" not in t:
    t = t.replace(A3, A3 + "\nbool PitchUp(bool start);\nbool PitchDown(bool start);", 1)
    h.write_text(t, encoding="utf-8")
    print("Actions.h: declared")

# ---- 2. Dispatch: real commands; the stubs stop lying -----------------------
d = R / "runtime/src/bridge/Dispatch.cpp"
u = d.read_text(encoding="utf-8", errors="ignore")

OLD = """    if (!std::strcmp(name, "SetPitch") ||
        !std::strcmp(name, "SetCameraDistanceMax") ||
        !std::strcmp(name, "SetNameplateDistanceMax") || !std::strcmp(name, "SetCVarEx"))
        return PushBool(L, true);"""
NEW = """    // Real pitch input (hold-style, keyboard semantics). Args: (start).
    if (!std::strcmp(name, "PitchUpStart") || !std::strcmp(name, "PitchUpStop"))
        return PushBool(L, Actions::PitchUp(name[7] == 'a'));   // "PitchUpSt[a]rt"
    if (!std::strcmp(name, "PitchDownStart") || !std::strcmp(name, "PitchDownStop"))
        return PushBool(L, Actions::PitchDown(name[9] == 'a'));

    // SetPitch is NOT IMPLEMENTED as an absolute setter - returning true made it
    // a lying stub: the addon got a success for a call that did nothing, so swim
    // depth control looked implemented while the character never pitched. nil is
    // the honest answer until an absolute setter exists; callers wanting pitch
    // use the hold-style PitchUp/Down commands above.
    if (!std::strcmp(name, "SetPitch")) return PushNil(L);
    // Same class of lying stub, kept only because ZERO callers exist today
    // (wrappers only) - do not add callers that trust this true.
    if (!std::strcmp(name, "SetCameraDistanceMax") ||
        !std::strcmp(name, "SetNameplateDistanceMax") || !std::strcmp(name, "SetCVarEx"))
        return PushBool(L, true);"""
assert OLD in u, "stub group not found"
assert "PitchUpStart\"" not in u.replace(OLD, "", 1), "pitch commands already present"
u = u.replace(OLD, NEW, 1)
import re
u = re.sub(r'const char\* kVersion = "[^"]+";',
           'const char* kVersion = "1.8.17-pitch";', u, count=1)
d.write_text(u, encoding="utf-8")
print("Dispatch.cpp: pitch commands wired, SetPitch honest, version 1.8.17-pitch")

# ---- 3. Lua wrappers next to the other movement primitives ------------------
al = R / "addon/core/Actions.lua"
v = al.read_text(encoding="utf-8")
A4 = """function A.StrafeLeft(start)"""
N4 = """-- Vertical aim while swimming/flying. Hold-style like every other move key;
-- the runtime stops the opposite direction on start so the pair cannot wedge.
-- SetPitch (absolute) is NOT implemented in the runtime - it returns nil now
-- instead of a fake true - so depth control composes these holds instead.
function A.PitchUp(start)
    if not A.ensure() then return false end
    return not not rt(start and "PitchUpStart" or "PitchUpStop")
end

function A.PitchDown(start)
    if not A.ensure() then return false end
    return not not rt(start and "PitchDownStart" or "PitchDownStop")
end

function A.StrafeLeft(start)"""
assert A4 in v and "A.PitchUp" not in v
v = v.replace(A4, N4, 1)
al.write_text(v, encoding="utf-8")
print("Actions.lua: PitchUp/PitchDown wrappers")
