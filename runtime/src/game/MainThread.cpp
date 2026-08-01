#include "MainThread.h"
#include "ObjectManager.h"
#include "AddressDB.h"
#include "Offsets.h"
#include "Mem.h"
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

uint64_t SafeGuid() {
    using fn = uint64_t(__cdecl*)();
    auto f = reinterpret_cast<fn>(Addr::ClntObjMgrGetActivePlayer);
    __try {
        return f();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

uintptr_t SafePtr(uint64_t guid) {
    __try {
        return OM::Ptr(guid);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

int SafeRefreshOm() {
    __try {
        OM::Refresh(true);
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

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
    s.playerGuid = SafeGuid();
    // Prefer OM::LocalPtr (GetActivePlayerObj + ObjectPtr fallbacks).
    s.playerPtr = OM::LocalPtr();
    if (!s.playerPtr && s.playerGuid) s.playerPtr = SafePtr(s.playerGuid);
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

    // Do NOT auto-enum on every bridge pulse — that was the AV flood amplifier.
    // Enum only runs when an OM API (GetObjectCount / OmProbe / etc.) calls Refresh.
    // Still surface last known objectCount if OM already populated it.
    if (s.valid && OmWanted() && !OM::EnumIsDead()) {
        // Read cache only — Refresh(false) no-ops when TTL not expired and never
        // re-enters enum if dead. Avoid force-refresh here.
        s.objectCount = OM::Count();
    }

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
