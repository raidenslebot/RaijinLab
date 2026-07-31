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

// Nested lua_pcall helpers. CRITICAL: when Dispatch is already inside a Lua C
// call (IsLinuxClient → RuntimeCall → CastSpell/Attack), FrameScript_Execute
// re-enters the VM from a second path and hard-crashes (ERROR #132 null EIP /
// post-cast death). Live proof 2026-07-31 13:51: AA FIRE then client dies —
// Attack/ClearTarget/TargetLastTarget all used FSExec while g_currentL set.
// Rule: if g_currentL is set, ONLY nested lua_pcall. Never FSExec.

static bool LuaGlobal0(lua_State* L, const char* fname) {
    if (!L || !fname || !fname[0]) return false;
    using namespace RL::Game::Addr;
    auto getfield = reinterpret_cast<fn_getfield>(lua_getfield);
    auto pcall = reinterpret_cast<fn_pcall>(lua_pcall);
    auto type = reinterpret_cast<fn_type>(lua_type);
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    if (!getfield || !pcall || !type || !settop || !gettop) return false;
    SoftHardwareUnlock();
    __try {
        int top = gettop(L);
        getfield(L, LUA_GLOBALSINDEX, fname);
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            return false;
        }
        int rc = pcall(L, 0, 0, 0);
        settop(L, top);
        return rc == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

static bool LuaGlobalS(lua_State* L, const char* fname, const char* arg) {
    if (!L || !fname || !fname[0] || !arg) return false;
    using namespace RL::Game::Addr;
    auto getfield = reinterpret_cast<fn_getfield>(lua_getfield);
    auto pcall = reinterpret_cast<fn_pcall>(lua_pcall);
    auto type = reinterpret_cast<fn_type>(lua_type);
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    auto pushstring = reinterpret_cast<fn_pushstring>(lua_pushstring);
    if (!getfield || !pcall || !type || !settop || !gettop || !pushstring) return false;
    SoftHardwareUnlock();
    __try {
        int top = gettop(L);
        getfield(L, LUA_GLOBALSINDEX, fname);
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            return false;
        }
        pushstring(L, arg);
        int rc = pcall(L, 1, 0, 0);
        settop(L, top);
        return rc == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

static bool LuaGlobalN(lua_State* L, const char* fname, double n) {
    if (!L || !fname || !fname[0]) return false;
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
        getfield(L, LUA_GLOBALSINDEX, fname);
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            return false;
        }
        pushnumber(L, n);
        int rc = pcall(L, 1, 0, 0);
        settop(L, top);
        return rc == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Nested lua_pcall CastSpellByID - safe when already inside Lua C.
static bool CastViaLuaPCall(lua_State* L, int spellId) {
    if (!L || spellId <= 0) return false;
    return LuaGlobalN(L, "CastSpellByID", (double)spellId);
}

// Run a tiny script ONLY when we are NOT already inside Lua.
// When g_currentL is set, FSExec is forbidden (nested VM re-entry crash).
static int SafeScript(const char* code) {
    if (!code || !code[0]) return 0;
    if (g_currentL) {
        // Prefer never reaching here; callers should use LuaGlobal*.
        RL::Log::Warn("SafeScript refused while in Lua C (would FSExec): %.48s", code);
        return 0;
    }
    return SafeFSExec(code);
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

// Forward decls — restore helpers are defined later in this file.
bool ClearTarget();
bool TargetGuid(uint64_t guid);
bool TargetLastTarget();

// Live client selection via UNIT_FIELD_TARGET on the local player descriptor.
// Used so multi-dot Spell_C can restore selection without Lua TargetUnit races.
static uint64_t ReadClientTargetGuid() {
    uintptr_t p = PlayerPtr();
    if (!p) return 0;
    __try {
        uintptr_t d = *reinterpret_cast<uintptr_t*>(p + Offsets::O().Descriptor);
        if (!d || d < 0x10000u) return 0;
        // UNIT_FIELD_TARGET = descriptor + 0x48 (proven in ObjectManager fill).
        return *reinterpret_cast<uint64_t*>(d + 0x48);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

// Write UNIT_FIELD_TARGET on the local player descriptor (no TargetUnit / no
// selection UI path). Melee Spell_C often resolves range/victim against this
// field even when a non-zero GUID is passed — that is why Plague Strike multi-
// dot hit the CURRENT target while Icy Touch (ranged) honoured the GUID.
// Restore immediately after Spell_C. SEH-guarded; returns false on fail.
static bool WriteClientTargetGuid(uint64_t guid) {
    uintptr_t p = PlayerPtr();
    if (!p) return false;
    __try {
        uintptr_t d = *reinterpret_cast<uintptr_t*>(p + Offsets::O().Descriptor);
        if (!d || d < 0x10000u) return false;
        *reinterpret_cast<uint64_t*>(d + 0x48) = guid;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Nested GetSpellCooldown readiness. Returns remaining seconds (>0 = not ready),
// or 0 if ready / undetermined. Never invents a long hold — just refuses wire
// when the client bar already says CD/GCD remaining. Awareness, not a sleep.
static float SpellCooldownRemaining(lua_State* L, int spellId) {
    if (!L || spellId <= 0) return 0.f;
    using namespace RL::Game::Addr;
    auto getfield = reinterpret_cast<fn_getfield>(lua_getfield);
    auto pcall = reinterpret_cast<fn_pcall>(lua_pcall);
    auto type = reinterpret_cast<fn_type>(lua_type);
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    auto pushnumber = reinterpret_cast<fn_pushnumber>(lua_pushnumber);
    auto tonumber = reinterpret_cast<double(__cdecl*)(lua_State*, int)>(lua_tonumber);
    if (!getfield || !pcall || !type || !settop || !gettop || !pushnumber || !tonumber)
        return 0.f;
    __try {
        int top = gettop(L);
        // GetTime()
        getfield(L, LUA_GLOBALSINDEX, "GetTime");
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            return 0.f;
        }
        if (pcall(L, 0, 1, 0) != 0) {
            settop(L, top);
            return 0.f;
        }
        double now = tonumber(L, -1);
        settop(L, top);
        // GetSpellCooldown(spellId) -> start, duration
        getfield(L, LUA_GLOBALSINDEX, "GetSpellCooldown");
        if (type(L, -1) != LUA_TFUNCTION) {
            settop(L, top);
            return 0.f;
        }
        pushnumber(L, (double)spellId);
        if (pcall(L, 1, 2, 0) != 0) {
            settop(L, top);
            return 0.f;
        }
        double start = tonumber(L, -2);
        double dur = tonumber(L, -1);
        settop(L, top);
        if (dur <= 0.0) return 0.f;
        float rem = (float)((start + dur) - now);
        if (rem < 0.f) rem = 0.f;
        return rem;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0.f;
    }
}

// Restore selection after Spell_C (which often sticks the cast victim as target).
static void RestoreSelectionAfterCast(uint64_t prevTarget, uint64_t castVictim) {
    // First restore the descriptor field (melee pin). Then fix UI selection
    // if Spell_C / client also mutated the live selection stack.
    WriteClientTargetGuid(prevTarget);
    uint64_t now = ReadClientTargetGuid();
    if (prevTarget == 0) {
        // Had no target: never leave sticky multi-dot victim selected.
        if (now != 0)
            ClearTarget();
        return;
    }
    if (now == prevTarget)
        return; // already correct
    // Prefer TargetLastTarget (native stack), then GUID restore.
    if (!TargetLastTarget()) {
        TargetGuid(prevTarget);
    }
    now = ReadClientTargetGuid();
    if (now != prevTarget) {
        WriteClientTargetGuid(prevTarget);
        if (ReadClientTargetGuid() != prevTarget) {
            ClearTarget();
            TargetGuid(prevTarget);
        }
    }
    (void)castVictim;
}

bool CastSpell(int spellId, uint64_t targetGuid) {
    if (spellId <= 0) return false;
    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    lua_State* L = g_currentL;
    RL::Log::Info("CastSpell enter id=%d guid=0x%llX L=%p hw=%d",
                  spellId, (unsigned long long)targetGuid, (void*)L,
                  (int)Taint::HardwareGatesApplied());

    // RUNTIME readiness: refuse Spell_C when client CD/GCD still remaining.
    // Stops Consecration / GCD spam ("spell is not ready yet") at the wire.
    if (L) {
        float rem = SpellCooldownRemaining(L, spellId);
        if (rem > 0.05f) {
            RL::Log::Info("CastSpell refuse not_ready id=%d rem=%.3f", spellId, rem);
            g_cast_fail++;
            return false;
        }
    }

    uint64_t prev = ReadClientTargetGuid();

    // RUNTIME AUTHORITY: any non-zero GUID cast is Spell_C(guid) + restore.
    // Never demote multi-dot / GUID casts to stock CastSpellByID (client target).
    // Melee: pin UNIT_FIELD_TARGET to the cast victim for the native call so
    // Plague Strike (and any melee) hits the aura_search GUID, not prev target.
    // Only guid==0 is self / ground / current-target (still prefer nested pcall).
    if (targetGuid != 0) {
        bool pinned = false;
        if (prev != targetGuid) {
            pinned = WriteClientTargetGuid(targetGuid);
            if (!pinned)
                RL::Log::Warn("CastSpell pin target failed id=%d guid=0x%llX",
                              spellId, (unsigned long long)targetGuid);
        }
        int nrc = SafeNativeCast(spellId, targetGuid);
        // Always restore pin (even on native fail) so selection never sticks.
        if (prev != targetGuid || pinned)
            RestoreSelectionAfterCast(prev, targetGuid);
        if (nrc > 0) {
            g_cast_ok++;
            RL::Log::Info("CastSpell path=runtime_guid id=%d guid=0x%llX prev=0x%llX pin=%d ok=%d",
                          spellId, (unsigned long long)targetGuid,
                          (unsigned long long)prev, pinned ? 1 : 0, g_cast_ok);
            return true;
        }
        if (nrc < 0)
            RL::Log::Warn("CastSpell native AV id=%d guid=0x%llX",
                          spellId, (unsigned long long)targetGuid);
        g_cast_fail++;
        RL::Log::Warn("CastSpell FAIL runtime_guid id=%d fail=%d", spellId, g_cast_fail);
        return false;
    }

    // guid==0: self / ground / current target via nested CastSpellByID (in Lua C).
    if (L && CastViaLuaPCall(L, spellId)) {
        g_cast_ok++;
        RL::Log::Info("CastSpell path=lua_self id=%d ok=%d", spellId, g_cast_ok);
        return true;
    }
    int nrc = SafeNativeCast(spellId, 0);
    if (nrc > 0) {
        g_cast_ok++;
        RL::Log::Info("CastSpell path=native_self id=%d ok=%d", spellId, g_cast_ok);
        return true;
    }
    if (nrc < 0)
        RL::Log::Warn("CastSpell native AV id=%d", spellId);
    if (!L) {
        char code[96];
        snprintf(code, sizeof(code), "CastSpellByID(%d)", spellId);
        if (SafeScript(code) > 0) {
            g_cast_ok++;
            return true;
        }
    }
    g_cast_fail++;
    RL::Log::Warn("CastSpell FAIL self id=%d fail=%d", spellId, g_cast_fail);
    return false;
}

void SetCurrentLuaState(void* L) { g_currentL = reinterpret_cast<lua_State*>(L); }

// Normalize angle delta into (-pi, pi].
static float NormPi(float d) {
    const float pi = 3.14159265f;
    const float two = 6.2831853f;
    while (d > pi) d -= two;
    while (d < -pi) d += two;
    return d;
}

// Returns: 1 = facing, 0 = not facing (measured), -1 = undetermined (no positions).
// Callers that must not spam "in front" only skip when result == 0.
// Undetermined must NOT block multi-dot GUID casts (was zero Icy Touch fires).
static int IsFacingGuidEx(uint64_t guid, float halfArcRad) {
    if (!guid) return -1;
    if (halfArcRad <= 0.f) halfArcRad = 1.5707963f;
    uint64_t me = ActiveGuid();
    if (!me) return -1;
    Vec3 pa = OM::Position(me);
    Vec3 pb = OM::Position(guid);
    if ((pa.x == 0.f && pa.y == 0.f) || (pb.x == 0.f && pb.y == 0.f))
        return -1; // cannot measure — do not invent "not facing"
    float face = PlayerFacing();
    if (face > 1e8f || face != face)
        face = OM::Facing(me);
    if (face != face || face < -0.01f || face > 12.f)
        return -1;
    float ang = std::atan2(pb.y - pa.y, pb.x - pa.x);
    float diff = NormPi(ang - face);
    return (std::fabs(diff) <= halfArcRad) ? 1 : 0;
}

bool IsFacingGuid(uint64_t guid, float halfArcRad) {
    // Legacy bool API: undetermined counts as facing so old callers don't soft-lock.
    int v = IsFacingGuidEx(guid, halfArcRad);
    return v != 0;
}

bool FaceTowardGuid(uint64_t guid) {
    if (!guid) return false;
    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    uint64_t me = ActiveGuid();
    if (!me) return false;
    Vec3 pa = OM::Position(me);
    Vec3 pb = OM::Position(guid);
    if ((pa.x == 0.f && pa.y == 0.f) || (pb.x == 0.f && pb.y == 0.f))
        return false;

    // Live facing (0x7AC), not stale 0x7A4.
    float face = PlayerFacing();
    if (face > 1e8f || face != face) {
        face = OM::Facing(me);
        if (face != face || face < -0.01f || face > 12.f)
            return false;
    }

    float ang = std::atan2(pb.y - pa.y, pb.x - pa.x);
    float diff = NormPi(ang - face);
    if (std::fabs(diff) <= 0.12f)
        return true; // already on-angle enough for cast cone

    // One TurnByDelta step (capped). Real client turn + CommitMovement.
    if (diff > 1.4f) diff = 1.4f;
    if (diff < -1.4f) diff = -1.4f;
    return TurnByDelta(diff);
}

static bool LosClear(uint64_t guid) {
    uint64_t me = ActiveGuid();
    if (!me || !guid) return true; // undetermined: do not hard-block
    Vec3 a = OM::Position(me);
    Vec3 b = OM::Position(guid);
    if ((a.x == 0.f && a.y == 0.f) || (b.x == 0.f && b.y == 0.f))
        return true;
    a.z += 2.f;
    b.z += 2.f;
    Vec3 hit{};
    // TraceLine returns true if BLOCKED on our OM API.
    bool blocked = OM::TraceLine(a, b, &hit, 0x100111u);
    return !blocked;
}

CastGateResult CanCast(int spellId, uint64_t targetGuid, uint32_t flags) {
    CastGateResult r{ false, "no_spell" };
    if (spellId <= 0) return r;
    uint64_t me = ActiveGuid();
    if (!me) { r.reason = "no_player"; return r; }

    // Live client CD/GCD: refuse before face/LoS so multi-dot does not spam.
    if (g_currentL) {
        float rem = SpellCooldownRemaining(g_currentL, spellId);
        if (rem > 0.05f) { r.reason = "not_ready"; return r; }
    }

    if (targetGuid != 0) {
        Vec3 pb = OM::Position(targetGuid);
        Vec3 pa = OM::Position(me);
        if ((pb.x != 0.f || pb.y != 0.f) && (pa.x != 0.f || pa.y != 0.f)) {
            float dx = pb.x - pa.x, dy = pb.y - pa.y;
            float dist = std::sqrt(dx * dx + dy * dy);
            if (dist > 45.f) { r.reason = "oor"; return r; }
        }

        int face = IsFacingGuidEx(targetGuid, 1.5707963f);
        if (face == 0 && (flags & kCastFaceIfNeeded)) {
            FaceTowardGuid(targetGuid);
            face = IsFacingGuidEx(targetGuid, 1.5707963f);
        }
        // Only refuse when MEASURED not-facing. Undetermined (-1) allows cast.
        if (face == 0) {
            r.reason = "facing";
            return r;
        }
        if (flags & kCastCheckLos) {
            if (!LosClear(targetGuid)) {
                r.reason = "los";
                return r;
            }
        }
    }

    r.ok = true;
    r.reason = "ok";
    return r;
}

CastGateResult CastSpellEx(int spellId, uint64_t targetGuid, uint32_t flags) {
    CastGateResult r{ false, "no_spell" };
    if (spellId <= 0) return r;

    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    // Readiness before face/wire — never call Spell_C on CD (Consecration spam).
    if (g_currentL) {
        float rem = SpellCooldownRemaining(g_currentL, spellId);
        if (rem > 0.05f) {
            r.reason = "not_ready";
            RL::Log::Info("CastSpellEx refuse not_ready id=%d rem=%.3f", spellId, rem);
            return r;
        }
    }

    // Face gate: only block when we MEASURE not-facing.
    // Undetermined → cast (client is authority). Was zero multi-dot fires.
    if (targetGuid != 0) {
        int face = IsFacingGuidEx(targetGuid, 1.5707963f);
        if (face == 0 && (flags & kCastFaceIfNeeded)) {
            FaceTowardGuid(targetGuid);
            face = IsFacingGuidEx(targetGuid, 1.5707963f);
        }
        if (face == 0 && (flags & kCastSkipIfNotFacing)) {
            r.reason = "facing";
            RL::Log::Info("CastSpellEx refuse facing id=%d guid=0x%llX",
                          spellId, (unsigned long long)targetGuid);
            return r;
        }
        // No default refuse when flags omit SKIP — just cast.
        if (flags & kCastCheckLos) {
            if (!LosClear(targetGuid)) {
                r.reason = "los";
                return r;
            }
        }
    }

    // Acquire-OFF multi-dot: NO_TARGET_CHANGE. CastSpell already restores when
    // prev != victim. When acquire is ON, Lua Targets first so prev==victim and
    // restore is a no-op — selection stays on the match.
    uint64_t prev = (targetGuid != 0) ? ReadClientTargetGuid() : 0;
    bool ok = CastSpell(spellId, targetGuid);
    if (ok) {
        // Explicit restore pass for NO_TARGET_CHANGE (double-ensure after native).
        if ((flags & kCastNoTargetChange) && targetGuid != 0) {
            RestoreSelectionAfterCast(prev, targetGuid);
        }
        r.ok = true;
        r.reason = "ok";
    } else {
        r.reason = "cast_fail";
    }
    return r;
}

bool MoveTo(float x, float y, float z) {
    // Forbidden: click-to-move. OM::MoveTo now refuses; kept for ABI only.
    (void)x; (void)y; (void)z;
    OM::MoveTo(Vec3{ x, y, z });
    return false;
}

bool FaceDirection(float radians) {
    SoftHardwareUnlock();
    // Write LIVE facing (0x7AC) AND orientation field (0x7A4). Old code only
    // wrote 0x7A4 which this client ignores for cast/movement.
    uintptr_t p = OM::LocalPtr();
    if (p) {
        __try {
            *reinterpret_cast<float*>(p + 0x7AC) = radians;
            *reinterpret_cast<float*>(p + 0x7A4) = radians;
        } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
    OM::FaceDirection(radians);
    CommitMovement();
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
    char hex[40];
    snprintf(hex, sizeof(hex), "0x%llX", (unsigned long long)guid);
    if (g_currentL && LuaGlobalS(g_currentL, "TargetUnit", hex))
        return true;
    if (g_currentL) {
        // Unprefixed form via nested call only.
        snprintf(hex, sizeof(hex), "%llX", (unsigned long long)guid);
        if (LuaGlobalS(g_currentL, "TargetUnit", hex))
            return true;
        return false; // never FSExec while in Lua C
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "TargetUnit(\"0x%llX\")", (unsigned long long)guid);
    if (SafeFSExec(buf) > 0) return true;
    snprintf(buf, sizeof(buf), "TargetUnit(\"%llX\")", (unsigned long long)guid);
    return SafeFSExec(buf) > 0;
}

bool TargetByName(const char* name) {
    if (!name || !name[0]) return false;
    SoftHardwareUnlock();
    if (g_currentL && LuaGlobalS(g_currentL, "TargetUnit", name))
        return true;
    if (g_currentL) return false;
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
    if (g_currentL && LuaGlobalS(g_currentL, "TargetUnit", unitToken))
        return true;
    if (g_currentL) return false;
    char buf[192];
    snprintf(buf, sizeof(buf),
             "if UnitExists(\"%s\") then TargetUnit(\"%s\") end",
             unitToken, unitToken);
    return SafeFSExec(buf) > 0;
}

bool ClearTarget() {
    SoftHardwareUnlock();
    if (g_currentL && LuaGlobal0(g_currentL, "ClearTarget"))
        return true;
    if (g_currentL) return false;
    return SafeFSExec("ClearTarget()") > 0;
}

bool TargetLastTarget() {
    SoftHardwareUnlock();
    if (g_currentL && LuaGlobal0(g_currentL, "TargetLastTarget"))
        return true;
    if (g_currentL) return false;
    return SafeFSExec("TargetLastTarget()") > 0;
}

bool AttackTarget() {
    SoftHardwareUnlock();
    // StartAttack while already in Lua C MUST be nested pcall, not FSExec.
    if (g_currentL) {
        if (LuaGlobal0(g_currentL, "StartAttack")) return true;
        if (LuaGlobal0(g_currentL, "AttackTarget")) return true;
        return false;
    }
    if (SafeFSExec("StartAttack()") > 0) return true;
    return SafeFSExec("AttackTarget()") > 0;
}

bool StopAttack() {
    SoftHardwareUnlock();
    if (g_currentL && LuaGlobal0(g_currentL, "StopAttack"))
        return true;
    if (g_currentL) return false;
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
