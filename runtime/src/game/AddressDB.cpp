#include "AddressDB.h"
#include <Windows.h>

namespace RL::Game::Addr {
namespace {

// Stock 3.3.5 / Ascension globals used as pure-memory world signals.
constexpr uintptr_t kClientConnection = 0x00C79CE0;
constexpr uintptr_t kLocalPlayerPtr   = 0x00C7B098; // CGPlayer* when in world
constexpr uintptr_t kObjMgrGlobal     = 0x00CD87A8;
constexpr uintptr_t kObjMgrOff        = 0x2ED0;

static bool ReadablePtr(uintptr_t p) {
    return p >= 0x10000u && p < 0xFFF00000u;
}

uint64_t SafeGetActivePlayerGuid() {
    using fn = uint64_t(__cdecl*)();
    auto f = reinterpret_cast<fn>(ClntObjMgrGetActivePlayer);
    __try {
        return f();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

int ReadInWorldFlag() {
    // BYTE bool. On Ascension live this is often stuck at 0 while fully
    // in-world (heartbeat proof 2026-07-31: flag=0 for minutes). Keep as a
    // positive signal only — never the sole gate.
    __try {
        uint8_t b = *reinterpret_cast<volatile uint8_t*>(g_InWorld);
        return b ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

static int ReadWorldFrameOk() {
    __try {
        uintptr_t wf = *reinterpret_cast<volatile uintptr_t*>(g_WorldFrame);
        return ReadablePtr(wf) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

static int ReadClientConnOk() {
    __try {
        uintptr_t conn = *reinterpret_cast<volatile uintptr_t*>(kClientConnection);
        return ReadablePtr(conn) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

static int ReadObjMgrOk() {
    __try {
        uintptr_t conn = *reinterpret_cast<volatile uintptr_t*>(kClientConnection);
        if (!ReadablePtr(conn)) return 0;
        uintptr_t mgr = *reinterpret_cast<volatile uintptr_t*>(conn + kObjMgrOff);
        if (ReadablePtr(mgr)) return 1;
        // Alternate global
        mgr = *reinterpret_cast<volatile uintptr_t*>(kObjMgrGlobal);
        return ReadablePtr(mgr) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

static int ReadLocalPlayerOk() {
    __try {
        uintptr_t lp = *reinterpret_cast<volatile uintptr_t*>(kLocalPlayerPtr);
        return ReadablePtr(lp) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

} // namespace

bool InWorld() {
    return WorldReady(nullptr);
}

void* LuaState() {
    __try {
        return *reinterpret_cast<void**>(g_luaState);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}

uint64_t ActivePlayerGuid() {
    return SafeGetActivePlayerGuid();
}

int InWorldFlag() {
    return ReadInWorldFlag();
}

bool WorldReady(uint32_t* outBits) {
    // Multi-signal world readiness for FrameScript_RegisterFunction.
    // Live proof: g_InWorld stayed 0 for 60s while player was in world and
    // lua_State was valid — registration never fired. So we OR several
    // independent pure-memory (and one SEH-guarded GUID) signals.
    uint32_t bits = 0;
    int flag = ReadInWorldFlag();
    if (flag == 1) bits |= 1u;
    if (ReadWorldFrameOk()) bits |= 2u;
    if (ReadClientConnOk()) bits |= 4u;
    if (ReadObjMgrOk()) bits |= 8u;
    if (ReadLocalPlayerOk()) bits |= 16u;

    // Active player GUID: SEH-isolated. Prefer throttling callers; safe if AV.
    uint64_t guid = SafeGetActivePlayerGuid();
    if (guid != 0) bits |= 32u;

    if (outBits) *outBits = bits;

    // Strong signals: local player object or active GUID = definitely in world.
    if (bits & (16u | 32u))
        return true;

    // Medium: world frame + client connection + object manager all live
    // (character in world with OM). Flag alone is insufficient (often stuck 0).
    if ((bits & (2u | 4u | 8u)) == (2u | 4u | 8u))
        return true;

    // Weak positive: flag byte only (stock path when it works).
    if (flag == 1)
        return true;

    return false;
}

} // namespace RL::Game::Addr
