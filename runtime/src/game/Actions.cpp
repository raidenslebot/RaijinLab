#include "Actions.h"
#include "ObjectManager.h"
#include "MainThread.h"
#include "AddressDB.h"
#include "Offsets.h"
#include "TaintPatch.h"
#include "core/Log.h"
#include "lua/Lua.h"
#include <Windows.h>
#include <cstdio>
#include <cstring>
#include <cmath>

// Cast rules:
// - Never full Taint::Apply from here (freezes)
// - HardwareEvent gate patches only (safe) via ArmUnlock
// - Native Spell_C_CastSpell @ 0x80DA40: __cdecl(spellId, itemId, guidLo, guidHi, isTrade)
// - Also FrameScript_Execute CastSpellByID with origin "*" (3-arg FS)
// - Nested lua_pcall CastSpellByID when L is available from Dispatch

namespace RL::Game::Actions {
namespace {

using fnVoid = void(__cdecl*)();
using fnFSExec3 = void(__cdecl*)(const char* code, const char* name, int taintArg);
// Real client cast used by FrameScript CastSpellByID / CastSpellByName
using fnCastSpell = int(__cdecl*)(int spellId, int itemId,
                                  uint32_t guidLo, uint32_t guidHi, int isTrade);
// ObjectPtr(guidLo, guidHi, typeMask)
using fnObjectPtr3 = uintptr_t(__cdecl*)(uint32_t lo, uint32_t hi, int typeMask);
using fnGetActive = uint64_t(__cdecl*)();

// lua extras for nested pcall
using fn_getfield = void(__cdecl*)(lua_State*, int, const char*);
using fn_pcall = int(__cdecl*)(lua_State*, int, int, int);
using fn_type = int(__cdecl*)(lua_State*, int);
using fn_settop = void(__cdecl*)(lua_State*, int);
using fn_gettop = int(__cdecl*)(lua_State*);
using fn_pushnumber = void(__cdecl*)(lua_State*, double);
using fn_pushstring = void(__cdecl*)(lua_State*, const char*);

static constexpr int LUA_GLOBALSINDEX = -10002;
static constexpr int LUA_TFUNCTION = 6;

static fnVoid At(uintptr_t addr) {
    return addr ? reinterpret_cast<fnVoid>(addr) : nullptr;
}

static int SafeVoid(fnVoid fn) {
    if (!fn) return 0;
    __try {
        fn();
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

static int SafeFSExec(const char* code) {
    if (!code || !code[0]) return 0;
    uintptr_t addr = Addr::FrameScript_Execute ? Addr::FrameScript_Execute : 0x00819210;
    __try {
        volatile uint32_t* hw = reinterpret_cast<volatile uint32_t*>(Addr::HardwareEventFlag);
        if (hw) *hw = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    __try {
        volatile uint32_t* tc = reinterpret_cast<volatile uint32_t*>(Addr::TaintContext);
        if (tc) *tc = 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    // FrameScript_Execute(code, source, taintOverride) - 3 args on this build
    __try {
        reinterpret_cast<fnFSExec3>(addr)(code, "*", 0);
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

static int SafeNativeCast(int spellId, uint64_t targetGuid) {
    uintptr_t castAddr = Offsets::F().Spell_C_CastSpell;
    if (!castAddr) castAddr = Addr::Spell_C_CastSpell;
    if (!castAddr) castAddr = 0x0080DA40;
    uint32_t lo = (uint32_t)targetGuid;
    uint32_t hi = (uint32_t)(targetGuid >> 32);
    __try {
        auto fn = reinterpret_cast<fnCastSpell>(castAddr);
        fn(spellId, 0, lo, hi, 0);
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

constexpr uintptr_t kJumpOrAscendStart  = 0x005FBF80;
constexpr uintptr_t kAscendStop         = 0x005FC0A0;
// SitStandOrDescendStart: on land sit/stand; in water = swim down.
// Address from AscensionLuaHandlers (FrameScript command table).
constexpr uintptr_t kSitStandOrDescendStart = 0x0051B1D0;
constexpr uintptr_t kDescendStop        = 0x005FC140;  // adjacent to AscendStop
constexpr uintptr_t kMoveForwardStart   = 0x005FC200;
// Swim/fly pitch (verified AscensionLuaHandlers.h:1823-1826; the same natives
// back VehicleAimUp/Down). Hold-style input like every other movement key.
constexpr uintptr_t kPitchUpStart       = 0x005FC8E0;
constexpr uintptr_t kPitchUpStop        = 0x005FC570;
constexpr uintptr_t kPitchDownStart     = 0x005FC920;
constexpr uintptr_t kPitchDownStop      = 0x005FC5C0;
constexpr uintptr_t kMoveForwardStop    = 0x005FC250;
constexpr uintptr_t kMoveBackwardStart  = 0x005FC290;
constexpr uintptr_t kMoveBackwardStop   = 0x005FC2E0;
constexpr uintptr_t kTurnLeftStart      = 0x005FC320;
constexpr uintptr_t kTurnLeftStop       = 0x005FC360;
constexpr uintptr_t kTurnRightStart     = 0x005FC3B0;
constexpr uintptr_t kTurnRightStop      = 0x005FC3F0;
constexpr uintptr_t kStrafeLeftStart    = 0x005FC440;
constexpr uintptr_t kStrafeLeftStop     = 0x005FC490;
constexpr uintptr_t kStrafeRightStart   = 0x005FC4D0;
constexpr uintptr_t kStrafeRightStop    = 0x005FC520;

// --- Mouselook / camera-yaw steering (RE-verified 2026-07-23) ---
// The ONLY analog/variable turn in the engine is mouselook: hold it, and the
// camera+character yaw follow mouse-X continuously (with the client's own easing).
// The keyboard TurnLeft/Right just set a flag integrated at ONE fixed rate.
constexpr uintptr_t kMouselookStart     = 0x005FCC10;  // cdecl, no args (reads globals)
constexpr uintptr_t kMouselookStop      = 0x005FC890;  // cdecl, no args
constexpr uintptr_t kMovementApply      = 0x005FBBC0;  // __thiscall(ctrl, [0xB499A4], 1)
constexpr uintptr_t kInputCtrlPtr       = 0x00C24954;  // *ptr = input controller
constexpr uintptr_t kInputTimePtr       = 0x00B499A4;  // arg the native handlers push
constexpr uintptr_t kWorldFramePtr      = 0x00B7436C;  // *(*+0x7E20) = camera object
constexpr uintptr_t kCamPtrOffset       = 0x7E20;
constexpr uintptr_t kInputFlagsOff      = 0x04;        // ctrl+4: mouselook bits live here
constexpr uint32_t  kMouselookBits      = 0x2000001;   // (0x1 | 0x2000000)
constexpr uintptr_t kCamAppliedYaw      = 0x120;       // smoothed/current camera yaw (rad)
constexpr uintptr_t kCamTargetYaw       = 0x230;       // target yaw the client eases toward
constexpr uintptr_t kCamAppliedPitch    = 0x11C;
constexpr uintptr_t kCamTargetPitch     = 0x260;

// --- In-process yaw turn (RE-verified 2026-07-23) - the CLEAN way to rotate the
// character without touching the OS mouse or capturing the cursor. This is the
// exact per-frame function the keyboard turn keys call; it reads the current
// facing, adds our delta, commits via the real SetFacing path (renders + sends
// MSG_MOVE_SET_FACING to the server). MUST be called on the game/main thread.
constexpr uintptr_t kTurnByDelta        = 0x005FB4B0;  // __thiscall(ctrl, token, float deltaRad); +delta = left/CCW
constexpr uintptr_t kCtrlFacingValid    = 0x4C;        // ctrl+0x4C != 0 => ctrl+0x50 is the cached (stale) facing
constexpr uintptr_t kCtrlFacing         = 0x50;
constexpr uintptr_t kVtblGetFacing      = 0x14C;       // player vtable[0x14C] = GetFacing() -> float (st0)
constexpr uintptr_t kPlayerFacingLive   = 0x7AC;       // CMovement+0x24: the LIVE local-player facing (rad)

using fnApply = int(__thiscall*)(void* ecx, void* p, int a);
using fnTurnByDelta = void(__thiscall*)(void* ctrl, int token, float deltaRad);
using fnGetFacing = float(__thiscall*)(void* self);

static bool g_armed = false;
static int g_cast_ok = 0;
static int g_cast_fail = 0;
// thread_local so a stale write from a previous main-thread call cannot leak
// into an unrelated worker-thread bridge invocation, and vice-versa. Only
// the main-thread setter / reader pair inside Dispatch::CastSpell should
// ever see a non-null value.
static thread_local lua_State* g_currentL = nullptr;

static void SoftHardwareUnlock() {
    __try {
        volatile uint32_t* hw = reinterpret_cast<volatile uint32_t*>(Addr::HardwareEventFlag);
        if (hw) *hw = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    __try {
        volatile uint32_t* tc = reinterpret_cast<volatile uint32_t*>(Addr::TaintContext);
        if (tc) *tc = 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}

static uint64_t ActiveGuid() {
    auto fn = reinterpret_cast<fnGetActive>(Addr::ClntObjMgrGetActivePlayer);
    if (!fn) return 0;
    __try {
        return fn();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

static uintptr_t ObjectPtr3(uint64_t guid, int mask) {
    auto fn = reinterpret_cast<fnObjectPtr3>(Addr::ClntObjMgrObjectPtr);
    if (!fn || !guid) return 0;
    uint32_t lo = (uint32_t)guid;
    uint32_t hi = (uint32_t)(guid >> 32);
    __try {
        return fn(lo, hi, mask);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

static uintptr_t PlayerPtr() {
    // A) Main-thread snapshot
    auto snap = MainThread::Get();
    if (snap.playerPtr) return snap.playerPtr;

    // B) GetActivePlayer + ObjectPtr(lo,hi,mask)
    uint64_t g = ActiveGuid();
    if (g) {
        uintptr_t p = ObjectPtr3(g, -1);
        if (p) return p;
        p = ObjectPtr3(g, 0x18); // UNIT|PLAYER
        if (p) return p;
        p = ObjectPtr3(g, 0x10); // PLAYER only
        if (p) return p;
    }

    // Path C removed: the literal 0x00C7B098 was documented as "common 3.3.5
    // player ptr" but was NEVER verified for Ascension Live. Any garbage
    // above 0x10000 at that address would be accepted as a valid CGPlayer*
    // and passed to CTM/InteractGuid, dereferencing an attacker-controlled
    // vtable slot. Fall through to OM::LocalPtr which routes via the
    // verified GetActivePlayer + ObjectPtr commit-checked path.
    return OM::LocalPtr();
}

// Nested lua_pcall CastSpellByID - safe relative to FrameScript_Execute
static bool CastViaLuaPCall(lua_State* L, int spellId) {
    if (!L || spellId <= 0) return false;
    // Route through AddressDB constants (single source of truth) instead of
    // duplicating raw VAs here. If a future hotfix shifts any of these, the
    // rest of the runtime already picks it up via Addr::* - this local list
    // must not diverge.
    using namespace RL::Game::Addr;
    auto getfield = reinterpret_cast<fn_getfield>(lua_getfield);
    auto pcall = reinterpret_cast<fn_pcall>(lua_pcall);
    auto type = reinterpret_cast<fn_type>(lua_type);
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    auto pushnumber = reinterpret_cast<fn_pushnumber>(lua_pushnumber);
    if (!getfield || !pcall || !type || !settop || !gettop || !pushnumber) return false;

    SoftHardwareUnlock();
    __try {
        int top = gettop(L);
        getfield(L, LUA_GLOBALSINDEX, "CastSpellByID");
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            // try CastSpellByName via GetSpellInfo
            getfield(L, LUA_GLOBALSINDEX, "GetSpellInfo");
            if (type(L, -1) != LUA_TFUNCTION) {
                settop(L, top);
                return false;
            }
            pushnumber(L, (double)spellId);
            if (pcall(L, 1, 1, 0) != 0) {
                settop(L, top);
                return false;
            }
            // name on stack
            getfield(L, LUA_GLOBALSINDEX, "CastSpellByName");
            if (type(L, -1) != LUA_TFUNCTION) {
                settop(L, top);
                return false;
            }
            // stack: name, CastSpellByName - need name on top after func
            // rearrange: push value of name under function
            // simpler: use FSExec only as last resort for name
            settop(L, top);
            return false;
        }
        pushnumber(L, (double)spellId);
        int rc = pcall(L, 1, 0, 0);
        settop(L, top);
        return rc == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

} // namespace

void ArmUnlock() {
    SoftHardwareUnlock();
    // HW-only binary patches - required for cast without real mouse/key event
    if (!Taint::HardwareGatesApplied()) {
        RL::Log::Info("ArmUnlock: applying HW event gates...");
        Taint::ApplyHardwareGatesOnly();
    }
    if (!g_armed) {
        g_armed = true;
        RL::Log::Warn("Actions: armed hw_gates=%d", Taint::HardwareGateCount());
    } else {
        RL::Log::Trace("ArmUnlock: already armed hw_gates=%d", Taint::HardwareGateCount());
    }
}

bool CastSpell(int spellId, uint64_t targetGuid) {
    if (spellId <= 0) return false;
    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    RL::Log::Trace("CastSpell enter id=%d guid=0x%llX L=%p hw=%d",
                   spellId, (unsigned long long)targetGuid, (void*)g_currentL,
                   (int)Taint::HardwareGatesApplied());

    // HARD RULE: when a target GUID is supplied, native Spell_C_CastSpell is
    // the ONLY correct path. CastSpellByID / FSExec ignore the unit and use
    // the client's current target — that forced TargetUnit for every multi-dot
    // and made casts look "mouseover/target only". Never call those with a GUID.
    if (targetGuid != 0) {
        int nrc = SafeNativeCast(spellId, targetGuid);
        if (nrc > 0) {
            g_cast_ok++;
            RL::Log::Info("CastSpell path=native_guid id=%d guid=0x%llX ok_total=%d",
                          spellId, (unsigned long long)targetGuid, g_cast_ok);
            return true;
        }
        if (nrc < 0)
            RL::Log::Warn("CastSpell native AV id=%d guid=0x%llX",
                          spellId, (unsigned long long)targetGuid);
        g_cast_fail++;
        RL::Log::Warn("CastSpell FAIL native_guid id=%d fail_total=%d", spellId, g_cast_fail);
        return false;
    }

    // No GUID: self / ground / current-target spells. Lua path is fine here.
    lua_State* L = g_currentL;
    if (L && CastViaLuaPCall(L, spellId)) {
        g_cast_ok++;
        RL::Log::Info("CastSpell path=lua_pcall id=%d ok_total=%d", spellId, g_cast_ok);
        return true;
    }

    int nrc = SafeNativeCast(spellId, 0);
    if (nrc > 0) {
        g_cast_ok++;
        RL::Log::Info("CastSpell path=native_self id=%d ok_total=%d", spellId, g_cast_ok);
        return true;
    }
    if (nrc < 0)
        RL::Log::Warn("CastSpell native AV id=%d", spellId);

    // FrameScript_Execute ONLY when we are NOT already inside Lua.
    if (!g_currentL) {
        char code[96];
        snprintf(code, sizeof(code), "CastSpellByID(%d)", spellId);
        int frc = SafeFSExec(code);
        if (frc > 0) {
            g_cast_ok++;
            RL::Log::Info("CastSpell path=fsexec id=%d ok_total=%d", spellId, g_cast_ok);
            return true;
        }
    }

    g_cast_fail++;
    RL::Log::Warn("CastSpell FAIL id=%d fail_total=%d", spellId, g_cast_fail);
    return false;
}

void SetCurrentLuaState(void* L) { g_currentL = reinterpret_cast<lua_State*>(L); }

bool MoveTo(float x, float y, float z) {
    // Forbidden: click-to-move. OM::MoveTo now refuses; kept for ABI only.
    (void)x; (void)y; (void)z;
    OM::MoveTo(Vec3{ x, y, z });
    return false;
}

bool FaceDirection(float radians) {
    SoftHardwareUnlock();
    OM::FaceDirection(radians);
    return true;
}

bool Jump() {
    SoftHardwareUnlock();
    // One-shot: same native as ascend-start. Land hops and a single key tap.
    // Continuous swim-up MUST use Ascend(true/false) so AscendStop can release.
    return SafeVoid(At(kJumpOrAscendStart)) > 0;
}

bool Ascend(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kJumpOrAscendStart : kAscendStop)) > 0;
}

bool Descend(bool start) {
    SoftHardwareUnlock();
    // FrameScript table: SitStandOrDescendStart @ 0x0051B1D0 (not in the
    // 0x005FC movement block - sit/stand wrapper that descends while swimming).
    // DescendStop @ 0x005FC140 releases.
    return SafeVoid(At(start ? kSitStandOrDescendStart : kDescendStop)) > 0;
}

bool StopMoving() {
    SoftHardwareUnlock();
    SafeVoid(At(kMoveForwardStop));
    SafeVoid(At(kMoveBackwardStop));
    SafeVoid(At(kStrafeLeftStop));
    SafeVoid(At(kStrafeRightStop));
    SafeVoid(At(kTurnLeftStop));
    SafeVoid(At(kTurnRightStop));
    SafeVoid(At(kAscendStop));
    SafeVoid(At(kDescendStop));
    return true;
}

bool MoveForward(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kMoveForwardStart : kMoveForwardStop)) > 0;
}

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
}
bool MoveBackward(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kMoveBackwardStart : kMoveBackwardStop)) > 0;
}
bool StrafeLeft(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kStrafeLeftStart : kStrafeLeftStop)) > 0;
}
bool StrafeRight(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kStrafeRightStart : kStrafeRightStop)) > 0;
}
bool TurnLeft(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kTurnLeftStart : kTurnLeftStop)) > 0;
}
bool TurnRight(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kTurnRightStart : kTurnRightStop)) > 0;
}

// ---- Mouselook / camera-yaw steering (the human, analog turn) ----
static uintptr_t CameraPtr() {
    __try {
        uintptr_t wf = *reinterpret_cast<uintptr_t*>(kWorldFramePtr);
        if (!wf) return 0;
        return *reinterpret_cast<uintptr_t*>(wf + kCamPtrOffset);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
}

bool MouselookStart() { SoftHardwareUnlock(); return SafeVoid(At(kMouselookStart)) > 0; }
bool MouselookStop()  { SoftHardwareUnlock(); return SafeVoid(At(kMouselookStop))  > 0; }

int IsMouselooking() {
    __try {
        uintptr_t c = *reinterpret_cast<uintptr_t*>(kInputCtrlPtr);
        if (!c) return 0;
        return (*reinterpret_cast<uint32_t*>(c + kInputFlagsOff) & kMouselookBits) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
}

// Current (smoothed) camera yaw in radians, or a large sentinel on failure.
float CameraYaw() {
    uintptr_t cam = CameraPtr();
    if (!cam) return 1e9f;
    __try { return *reinterpret_cast<float*>(cam + kCamAppliedYaw); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return 1e9f; }
}
float CameraTargetYaw() {
    uintptr_t cam = CameraPtr();
    if (!cam) return 1e9f;
    __try { return *reinterpret_cast<float*>(cam + kCamTargetYaw); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return 1e9f; }
}
// Set the camera's TARGET yaw; the client eases the applied yaw toward it. In
// mouselook this may or may not carry the player - the addon verifies live.
bool SetCameraYaw(float rad) {
    uintptr_t cam = CameraPtr();
    if (!cam) return false;
    __try { *reinterpret_cast<float*>(cam + kCamTargetYaw) = rad; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Push the current movement/heading state to the server (the native flag
// handlers call this after every change). __thiscall(ctrl, [0xB499A4], 1).
bool CommitMovement() {
    __try {
        uintptr_t c = *reinterpret_cast<uintptr_t*>(kInputCtrlPtr);
        if (!c) return false;
        void* p = *reinterpret_cast<void**>(kInputTimePtr);
        reinterpret_cast<fnApply>(kMovementApply)(reinterpret_cast<void*>(c), p, 1);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Synthesize a RELATIVE mouse move (genuine OS input). The client reads the OS
// cursor via GetCursorPos (no DirectInput), so while mouselook is active this
// feeds the exact native turn pipeline - camera+player yaw + the client's own
// easing - indistinguishable from a hand on the mouse. dx/dy are raw mickeys.
bool MouseMove(int dx, int dy) {
    INPUT in;
    ZeroMemory(&in, sizeof(in));
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    return SendInput(1, &in, sizeof(INPUT)) == 1;
}

// Rotate the character by a yaw delta (radians, + = left/CCW) THIS frame - fully
// in-process, server-synced, no OS mouse, no cursor capture, no click-to-move.
// The user's physical mouse stays free while the bot steers. Game-thread only.
bool TurnByDelta(float deltaRad) {
    __try {
        uintptr_t ctrl = *reinterpret_cast<uintptr_t*>(kInputCtrlPtr);
        if (!ctrl) return false;
        // Force TurnByDelta to read the LIVE facing (GetFacing -> player+0x7AC) as its
        // base instead of the stale cached [ctrl+0x50] - clearing the valid bit at
        // [ctrl+0x4C] selects the GetFacing branch (0x5FB4DE). Without this it
        // accumulated on a stale base and the turn drifted.
        *reinterpret_cast<uint32_t*>(ctrl + kCtrlFacingValid) = 0;
        int token = *reinterpret_cast<int*>(kInputTimePtr);
        reinterpret_cast<fnTurnByDelta>(kTurnByDelta)(reinterpret_cast<void*>(ctrl), token, deltaRad);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
    // COMMIT, OR THE TURN NEVER HAPPENED.
    //
    // CommitMovement's own comment says it: "the native flag handlers call this
    // after every change". TurnByDelta did not, so the rotation was set
    // in-process and nothing pushed it - the client's next movement apply
    // recomputed facing from an unchanged input state and the real facing never
    // moved. Live proof: "TurnByDelta ineffective (real facing not moving) ->
    // keyboard turn", after which every single turn in the session logged
    // m=keyboard. The smooth variable-rate turn was dead and the character was
    // steered by the stiff fixed-rate fallback all session - the "sloppy
    // control" report.
    //
    // Separate __try above so a throwing turn cannot skip straight past this,
    // and CommitMovement is itself SEH-guarded.
    CommitMovement();
    return true;
}

// The local player's LIVE facing (radians), CAMERA-INDEPENDENT (so free-look does
// not corrupt it). Mirrors what TurnByDelta reads: the input-controller cache
// [ctrl+0x50] when valid, else the player's GetFacing vtable[0x14C]. 1e9 on fail.
float PlayerFacing() {
    __try {
        // The LIVE local-player facing = CMovement+0x24 = player+0x7AC (RE-verified:
        // GetFacing @0x6E6FC0 is just `fld [ecx+0x7AC]; ret`, single writer is the
        // movement apply 0x6EAA08). NOT the dead 0x7A4, NOT the stale input cache.
        uintptr_t player = OM::LocalPtr();
        if (!player) return 1e9f;
        float f = *reinterpret_cast<float*>(player + kPlayerFacingLive);
        if (f != f || f < -0.01f || f > 6.30f) return 1e9f;   // NaN / out of [0,2pi)
        return f;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return 1e9f; }
}

bool TargetGuid(uint64_t guid) {
    if (!guid) return ClearTarget();
    SoftHardwareUnlock();
    char buf[128];
    // Try classic hex form first, then unprefixed (some private servers).
    snprintf(buf, sizeof(buf), "TargetUnit(\"0x%llX\")", (unsigned long long)guid);
    if (SafeFSExec(buf) > 0) return true;
    snprintf(buf, sizeof(buf), "TargetUnit(\"%llX\")", (unsigned long long)guid);
    return SafeFSExec(buf) > 0;
}

bool TargetByName(const char* name) {
    if (!name || !name[0]) return false;
    SoftHardwareUnlock();
    char buf[256];
    snprintf(buf, sizeof(buf), "TargetUnit([[%s]])", name);
    return SafeFSExec(buf) > 0;
}

bool TargetToken(const char* unitToken) {
    if (!unitToken || !unitToken[0]) return false;
    // Reject anything that looks like a GUID — those use TargetGuid.
    if (unitToken[0] == '0' && (unitToken[1] == 'x' || unitToken[1] == 'X'))
        return false;
    // Only allow safe unit-token characters (no quotes / injection).
    for (const char* p = unitToken; *p; ++p) {
        char c = *p;
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_';
        if (!ok) return false;
    }
    SoftHardwareUnlock();
    char buf[192];
    // Unit tokens (nameplateN, target, focus, bossN) — stock TargetUnit path.
    // C-origin "*" + SoftHardwareUnlock avoids addon taint.
    // MSVC snprintf has no %q — tokens are validated above.
    snprintf(buf, sizeof(buf),
             "if UnitExists(\"%s\") then TargetUnit(\"%s\") end",
             unitToken, unitToken);
    return SafeFSExec(buf) > 0;
}

bool ClearTarget() {
    SoftHardwareUnlock();
    return SafeFSExec("ClearTarget()") > 0;
}

bool TargetLastTarget() {
    SoftHardwareUnlock();
    // Stock client API: restore previous selection after a cast/swap.
    // More reliable than TargetUnit("0xGUID") for post-Spell_C restore.
    return SafeFSExec("TargetLastTarget()") > 0;
}

bool AttackTarget() {
    SoftHardwareUnlock();
    if (SafeFSExec("StartAttack()") > 0) return true;
    return SafeFSExec("AttackTarget()") > 0;
}

bool StopAttack() {
    SoftHardwareUnlock();
    return SafeFSExec("StopAttack()") > 0;
}

// CLICK-TO-MOVE IS DELETED FROM THE INTERACT PATH ON PURPOSE.
// CtmInteract() lived here and called Offsets::F().ClickToMove with action 5
// ("move-to + interact"), which steers the character - forbidden project-wide,
// and already refused by name in Dispatch.cpp. It is removed rather than left
// unused so it cannot quietly come back. Interact now goes through the Lua
// handler directly; see InteractUnitDirect below.

// InteractUnit's Lua handler, called DIRECTLY. See
// vendor/WowAutoSDK/include/AscensionLuaHandlers.h:1643
//   #define HANDLER_InteractUnit 0x00527F00
// Signature is the standard Lua C closure: int __cdecl f(lua_State*).
static constexpr uintptr_t kHandlerInteractUnit = 0x00527F00;

// INTERACT WITHOUT CLICK-TO-MOVE AND WITHOUT TAINT.
//
// Two problems this solves at once.
//
// 1. CTM IS A HARD PROJECT CONSTRAINT VIOLATION. The old path called
//    Offsets::F().ClickToMove with action 5/7. Type 5 is literally "move-to +
//    interact": it steers the character with click-to-move, which is forbidden
//    outright in this project. The Lua-side guard never caught it because it
//    only scans addon/**/*.lua - the violation lived in C++.
//
// 2. `InteractUnit('target')` through FrameScript_Execute is a PROTECTED call
//    from an insecure context, so it no-ops. That is why the live log showed
//    `interact ok=1 target=1 face=1 frame=0` - we reported success and no
//    dialog ever opened.
//
// Protection is enforced by the Lua BINDING layer, not by the handler itself.
// Pushing the unit token and calling the handler function directly therefore
// performs the real interact with no CTM movement and no taint check. The stack
// is restored unconditionally so a throwing handler cannot corrupt the VM.
static bool InteractUnitDirect(lua_State* L, const char* token) {
    if (!L || !token) return false;
    using namespace RL::Game::Addr;
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    auto pushstring = reinterpret_cast<fn_pushstring>(lua_pushstring);
    if (!settop || !gettop || !pushstring) return false;
    using fnHandler = int(__cdecl*)(lua_State*);
    auto h = reinterpret_cast<fnHandler>(kHandlerInteractUnit);
    SoftHardwareUnlock();

    // A LUA C FUNCTION READS ITS FIRST ARGUMENT AT INDEX 1.
    //
    // The first version of this pushed the token on top of whatever the bridge
    // dispatch already had on the stack, so the token landed at index top+1 and
    // index 1 still held the RuntimeCall COMMAND NAME. The handler would have
    // resolved the unit token "InteractGuid", found no such unit, and done
    // nothing - the identical `ok=1, frame=0` symptom this function exists to
    // fix, just one layer deeper. Verified __cdecl against the shipped binary
    // (0x105 bytes, terminates ff 59 c3, no C2 anywhere), so the convention is
    // right; only the frame was wrong.
    //
    // Clearing to 0 first gives the handler exactly the stack Lua itself would:
    // its arguments and nothing else. Discarding what was below is safe because
    // Lua takes a C function's results from the TOP of the stack - the old
    // `settop(L, top)` restore was doing nothing useful.
    //
    // CONSTRAINT this creates: any `const char*` previously obtained from the
    // Lua stack (e.g. the dispatch's `name`) loses its stack reference here and
    // must NOT be used after this call. Today Handle() has finished its strcmp
    // chain and only returns a pushed bool, which satisfies that.
    __try {
        settop(L, 0);
        pushstring(L, token);
        h(L);
        settop(L, 0);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { settop(L, 0); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return false;
    }
}

bool InteractGuid(uint64_t guid) {
    SoftHardwareUnlock();
    ArmUnlock();
    if (!guid) return InteractTarget();

    // Face the target first - interact often requires facing.
    {
        uint64_t meG = ActiveGuid();
        Vec3 me = meG ? OM::Position(meG) : Vec3{};
        Vec3 them = OM::Position(guid);
        if ((them.x != 0.f || them.y != 0.f) && (me.x != 0.f || me.y != 0.f)) {
            float ang = std::atan2(them.y - me.y, them.x - me.x);
            FaceDirection(ang);
        }
    }

    TargetGuid(guid);
    SoftHardwareUnlock();

    // 3.3.5 high-guid type (top of high dword):
    //   F1 3x = creature/unit, F1 1x = gameobject, F1 5x = pet, etc.
    uint32_t hi32 = (uint32_t)(guid >> 32);
    uint32_t kind = (hi32 >> 20) & 0xF; // nibble after F1
    bool isUnit = true;
    if ((hi32 & 0xFF000000u) == 0xF1000000u) {
        // F11 = GO, F13 = creature, F14 = pet, F15 = vehicle-ish
        isUnit = (kind != 0x1); // F11xxxx = gameobject
    }

    // Direct handler call. No CTM: the character does not get steered, so this
    // cannot violate the keyboard-only movement constraint. Navigation is the
    // navigator's job - by the time we interact we are already in range.
    bool ok = InteractUnitDirect(g_currentL, "target");

    // Last resort ONLY when we are not already inside Lua. This is the protected
    // path that no-ops from an insecure context; it is kept because it costs
    // nothing when it fails, but it is explicitly NOT counted as success.
    if (!ok && !g_currentL)
        ok = SafeFSExec("if UnitExists('target') then InteractUnit('target') end") > 0;

    // RETURN WHAT ACTUALLY HAPPENED. This used to `return true` unconditionally,
    // whatever the interact did - which is why the suite saw `ok=1 frame=0` and
    // sat in turnin:interact forever waiting for a dialog that was never asked
    // for. A confident value that means "no answer" is the single most expensive
    // bug pattern in this project; do not reintroduce it here.
    RL::Log::Info("InteractGuid g=0x%llX unit=%d L=%p ok=%d",
                  (unsigned long long)guid, (int)isUnit, (void*)g_currentL, (int)ok);
    return ok;
}

bool InteractTarget() {
    SoftHardwareUnlock();
    ArmUnlock();
    // Same direct-handler path as InteractGuid, and the same honest return: the
    // unconditional `return true` here was the other half of `ok=1 frame=0`.
    bool ok = InteractUnitDirect(g_currentL, "target");
    if (!ok && !g_currentL)
        ok = SafeFSExec("if UnitExists('target') then InteractUnit('target') end") > 0;
    return ok;
}

bool SpellStopCasting() {
    SoftHardwareUnlock();
    return SafeFSExec("SpellStopCasting()") > 0;
}

bool ExecSecure(const char* luaCode) {
    SoftHardwareUnlock();
    return SafeFSExec(luaCode) > 0;
}

} // namespace RL::Game::Actions
