#include "AddressDB.h"
#include <Windows.h>

namespace RL::Game::Addr {
namespace {

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
    // CRITICAL: stock/Ascension stores this as a BYTE (bool), NOT a 32-bit int.
    // Reading as int required value == 1 exactly; when adjacent bytes were
    // non-zero the int was e.g. 0x000001xx / garbage and registration NEVER
    // ran → BRIDGE ONLINE never logged → addon saw stock IsLinuxClient forever.
    // WowAutoSDK / proven injectors read uint8_t: any non-zero = in world.
    __try {
        uint8_t b = *reinterpret_cast<volatile uint8_t*>(g_InWorld);
        return b ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1; // unreadable
    }
}

} // namespace

bool InWorld() {
    // Primary: active player GUID non-zero (works when g_InWorld flag address is wrong)
    if (SafeGetActivePlayerGuid() != 0)
        return true;

    // Secondary: SDK flag (may be wrong on some Ascension builds)
    int flag = ReadInWorldFlag();
    if (flag > 0)
        return true;

    return false;
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
    return ReadInWorldFlag();  // pure read, SEH-guarded, -1 if unreadable
}

} // namespace RL::Game::Addr
