#include "MainThread.h"
#include "ObjectManager.h"
#include "AddressDB.h"
#include "Offsets.h"
#include "Mem.h"
#include "Actions.h"
#include "core/Log.h"
#include "core/Config.h"
#include <Windows.h>
#include <cmath>

namespace RL::Game::MainThread {
namespace {
Snapshot g_snap{};
CRITICAL_SECTION g_cs;
bool g_csInit = false;
bool g_enumDisabled = false;
bool g_omWanted = false;
bool g_omWantedInit = false;

void EnsureCs() {
    if (!g_csInit) {
        InitializeCriticalSection(&g_cs);
        g_csInit = true;
    }
}

// CRASH RULE (permanent, 2026-08-02): __try/__except is a DEAD guard in this
// stealth module — an AV inside it propagates into the game's Lua protected-call
// wrapper 0x858A16 and corrupts the Lua closure table (the garbage-eip crash
// family, frame=0 ret=0x00858A16). The old SafeGuid()/SafePtr()/SafeRefreshOm()
// wrappers here were exactly that: dead-SEH GAME calls (GetActivePlayer /
// ObjectPtr) executed on EVERY bridge call from PulseFromMainThread. They are
// deleted. Pulse now reads ONLY:
//   - OM::SafeGetActive()  — rate-limited (~120ms TTL), VEH (Guard::Scope)
//                            guarded, never dead-SEH, never per-bridge-call.
//   - OM::LocalPtr()       — snapshot-first + pure-memory 0xC7B098, VEH-guarded
//                            cold fallback, no dead SEH.
//   - OM::Position(guid)   — snapshot-only (pure memory) after fix 2026-08-02.
// SafeRefreshOm is gone too: Refresh is only ever called from OM handlers
// (which own their walk cadence), never from Pulse.

// Multi-method position read (0x798 is often cold NaN on Ascension).
// Local-gated: camera agreement + camera fallback (PositionLocalFromPtr).
bool SafeReadPos(uintptr_t ptr, float* x, float* y, float* z) {
    *x = *y = *z = 0.f;
    if (!ptr) return false;
    Vec3 p = OM::PositionLocalFromPtr(ptr);
    if (std::fabs(p.x) < 30.f || std::fabs(p.y) < 30.f) return false;
    *x = p.x; *y = p.y; *z = p.z;
    return true;
}

bool OmWanted() {
    // Always re-read: SetSystemVar must take effect immediately.
    // Default "1": after PEW arm the suite expects a live world list. Inject still
    // forces 0 until ArmRuntimeSystems / Master turns it on; cold inject never
    // enums without an active player (Refresh no-ops).
    g_omWanted = OM::IsEnabled();
    g_omWantedInit = true;
    return g_omWanted;
}

} // namespace

void PulseFromMainThread() {
    EnsureCs();
    Snapshot s{};
    // 2026-08-02 (CRASH FIX): OM::LocalGuid -> SafeGetActive is rate-limited
    // (~120ms TTL) and VEH-guarded, so the GetActivePlayer game call runs
    // ~8/sec — never once per bridge call (the post-cast burst was 30+ calls
    // in 15ms). The old SafeGuid() here was a DEAD-`__try` call on EVERY call.
    s.playerGuid = OM::LocalGuid();
    // OM::LocalPtr is snapshot-first + pure-memory (no dead SEH, no hot
    // ObjectPtr game call).
    s.playerPtr = OM::LocalPtr();
    s.valid = (s.playerGuid != 0) || (s.playerPtr != 0);
    s.lastTick = GetTickCount();
    s.objectCount = 0;

    if (s.playerPtr || s.playerGuid) {
        Vec3 pos{};
        // Prefer raw ptr multi-method first (works even when 0x798 is NaN).
        if (s.playerPtr) {
            float x, y, z;
            if (SafeReadPos(s.playerPtr, &x, &y, &z)) {
                pos.x = x; pos.y = y; pos.z = z;
            }
        }
        if ((pos.x == 0.f && pos.y == 0.f) && s.playerGuid)
            pos = OM::Position(s.playerGuid);
        if (pos.x != 0.f || pos.y != 0.f) {
            s.playerPos = pos;
        } else {
            EnterCriticalSection(&g_cs);
            s.playerPos = g_snap.playerPos;
            LeaveCriticalSection(&g_cs);
        }
    }

    // CRASH RULE (permanent, 2026-08-01): PulseFromMainThread is a PURE player
    // snapshot cache. It NEVER triggers OM::Count()/Refresh() — object
    // enumeration (EnumVisibleObjects / list walk) must never run from inside
    // a Lua C closure (Pulse is called from the bridge entry). OM handlers
    // (GetObjectCount / NearbyHostiles / OmProbe) call Refresh themselves and
    // are the only OM-walk entry points. This removed the "enum inside the
    // Lua VM" corruption path (crash family: Lua closure corruption).
    // s.objectCount is left 0 here; OM callers read the real count directly.

    // 2026-08-02 ("cast without targeting"): apply the delayed client-selection
    // restore for NOTGT / acquire-OFF GUID casts. Spell_C selects the victim
    // ASYNC (next frame); the immediate post-cast restore misses it. This runs
    // on the next bridge call (~the same frame the async pick lands) and reverts
    // the selection, so the aura-search victim never stays targeted.
    RL::Game::Actions::PulseSelectionRestore();

    EnterCriticalSection(&g_cs);
    g_snap = s;
    LeaveCriticalSection(&g_cs);
}

Snapshot Get() {
    EnsureCs();
    EnterCriticalSection(&g_cs);
    Snapshot s = g_snap;
    LeaveCriticalSection(&g_cs);
    return s;
}

bool HasPlayer() { return Get().playerGuid != 0; }
uint64_t PlayerGuid() { return Get().playerGuid; }

} // namespace RL::Game::MainThread
