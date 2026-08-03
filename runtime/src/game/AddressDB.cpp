#include "AddressDB.h"
#include "Mem.h"
#include "Guard.h"
#include "Offsets.h"
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
    if (!f) return 0;
    // 2026-08-02 (CRASH FIX): __try/__except is DEAD SEH in this stealth module
    // — an AV here propagated into the game's Lua protected-call wrapper and
    // corrupted the closure table. Use the VEH longjmp guard instead.
    // NOTE: still used on the MAIN thread only (bridge/OM paths); the WORKER
    // uses ActiveGuidPure() exclusively (never execute game code from the
    // worker during load).
    RL::Game::Guard::Scope g;
    if (!g.Caught()) {
        return f();
    }
    return 0;
}

int ReadInWorldFlag() {
    // BYTE bool. On Ascension live this is often stuck at 0 while fully
    // in-world (heartbeat proof 2026-07-31: flag=0 for minutes). Keep as a
    // positive signal only — never the sole gate.
    // VirtualQuery-guarded read — no __try dependency.
    return Mem::Read<uint8_t>(g_InWorld) ? 1 : 0;
}

static int ReadWorldFrameOk() {
    uintptr_t wf = Mem::Read<uintptr_t>(g_WorldFrame);
    return ReadablePtr(wf) ? 1 : 0;
}

static int ReadClientConnOk() {
    uintptr_t conn = Mem::Read<uintptr_t>(kClientConnection);
    return ReadablePtr(conn) ? 1 : 0;
}

static int ReadObjMgrOk() {
    uintptr_t conn = Mem::Read<uintptr_t>(kClientConnection);
    if (!ReadablePtr(conn)) return 0;
    uintptr_t mgr = Mem::Read<uintptr_t>(conn + kObjMgrOff);
    if (ReadablePtr(mgr)) return 1;
    // Alternate global
    mgr = Mem::Read<uintptr_t>(kObjMgrGlobal);
    return ReadablePtr(mgr) ? 1 : 0;
}

static int ReadLocalPlayerOk() {
    uintptr_t lp = Mem::Read<uintptr_t>(kLocalPlayerPtr);
    return ReadablePtr(lp) ? 1 : 0;
}

} // namespace

// PURE-MEMORY active player GUID (no game call, safe on ANY thread).
//
// 2026-08-02 (CRASH FIX — "inject during load"): the worker thread polled
// WorldReadyBits every ~50ms and SafeGetActivePlayerGuid() EXECUTED the game's
// ClntObjMgrGetActivePlayer (0x4D3790) on the non-main worker thread DURING the
// game's world-load window. Concurrent game-code execution from a foreign thread
// while the game is loading corrupted its heap -> AV_WRITE in the CRT memcpy at
// 0x40CB6A (Lua VM frames, seq 0, worker never registered — live 15:31). The
// worker must NEVER execute game functions; it reads only.
//
// This mirrors the game's own GetActivePlayer read: guid low/high at
// [ClntObjMgr + 0xC0]/[+0xC4] (disasm 0x4D3790: TLS->slot->mgr->[+0xC0/+0xC4]).
// Sources tried (any thread): (1) the mgr GLOBAL 0xCD87A8 (worker TLS is empty
// so the TLS path is unusable there), (2) the local player ptr 0xC7B098
// descriptor UNIT_FIELD_GUID (desc+0x00).
uint64_t ActiveGuidPure() {
    uintptr_t mgr = Mem::Read<uintptr_t>(kObjMgrGlobal);
    if (ReadablePtr(mgr) && Mem::Readable(mgr + 0xC4)) {
        uint64_t lo = Mem::Read<uint32_t>(mgr + 0xC0);
        uint64_t hi = Mem::Read<uint32_t>(mgr + 0xC4);
        uint64_t g = (hi << 32) | lo;
        if (g != 0 && hi != 0) return g; // WGUID: high dword must be non-zero
    }
    uintptr_t lp = Mem::Read<uintptr_t>(kLocalPlayerPtr);
    if (ReadablePtr(lp) && Mem::Readable(lp)) {
        uintptr_t d = Mem::Read<uintptr_t>(lp + RL::Game::Offsets::O().Descriptor);
        if (ReadablePtr(d) && Mem::Readable(d + 7)) {
            uint64_t g = Mem::Read<uint64_t>(d + 0x00); // UNIT_FIELD_GUID
            if (g != 0 && (g >> 32) != 0) return g;
        }
    }
    return 0;
}

bool InWorld() {
    return WorldReady(nullptr);
}

void* LuaState() {
    return reinterpret_cast<void*>(Mem::Read<uintptr_t>(g_luaState));
}

uint64_t ActivePlayerGuid() {
    return SafeGetActivePlayerGuid();
}

int InWorldFlag() {
    return ReadInWorldFlag();
}

uint32_t WorldReadyBits() {
    uint32_t bits = 0;
    int flag = ReadInWorldFlag();
    if (flag == 1) bits |= 1u;
    if (ReadWorldFrameOk()) bits |= 2u;
    if (ReadClientConnOk()) bits |= 4u;
    if (ReadObjMgrOk()) bits |= 8u;
    if (ReadLocalPlayerOk()) bits |= 16u;
    // 2026-08-02 (CRASH FIX): pure-memory active GUID — NEVER the game function
    // from the worker thread (concurrent game-code execution during the world-
    // load window corrupted the game's heap -> AV_WRITE, live 15:31). Worker
    // TLS is empty anyway, so the game call was returning 0 on the worker while
    // being a crash risk; ActiveGuidPure reads the same [mgr+0xC0/+0xC4] field.
    uint64_t guid = ActiveGuidPure();
    if (guid != 0) bits |= 32u;
    return bits;
}

bool WorldReadyStrong(uint32_t bits) {
    // MUST have a real local character — never flag alone.
    // Live crash 2026-07-31 15:00: Register via=strong with bits=0xF (flag|wf|
    // conn|mgr) and NO localPlayer/guid → client died ~2s after PEW arm.
    // Bug was `(bits & mask) != 0` which is OR of any bit (flag alone passes).
    //
    // Accept:
    //   A) localPlayer + activeGuid (Ascension: g_InWorld flag often stuck 0)
    //   B) full triple flag|localPlayer|guid
    const uint32_t playerish = 16u | 32u; // localPlayer | activeGuid
    if ((bits & playerish) == playerish) return true;
    if ((bits & (1u | playerish)) == (1u | playerish)) return true;
    return false;
}

bool WorldReadyMedium(uint32_t bits) {
    // worldFrame + clientConn + objMgr (Ascension often stuck here for minutes)
    return (bits & (2u | 4u | 8u)) == (2u | 4u | 8u);
}

bool WorldReady(uint32_t* outBits) {
    // Strong-only default. main.cpp may use medium via WorldReadyMedium after
    // a long continuous streak (Ascension: flag flickers, localPlayer often 0).
    uint32_t bits = WorldReadyBits();
    if (outBits) *outBits = bits;
    return WorldReadyStrong(bits);
}

} // namespace RL::Game::Addr
