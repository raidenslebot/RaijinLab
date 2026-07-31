#pragma once
#include <cstdint>
#include <Windows.h>
#include "Types.h"

// Game TLS/OM only valid on the client main thread.
// Lua C callbacks and FrameScript_Execute body run there.

namespace RL::Game::MainThread {

struct Snapshot {
    uint64_t playerGuid = 0;
    uintptr_t playerPtr = 0;
    size_t objectCount = 0;
    Vec3 playerPos{};
    bool valid = false;
    DWORD lastTick = 0;
};

// Call ONLY from game main thread (Lua callback / FrameScript path)
void PulseFromMainThread();

// Safe from any thread
Snapshot Get();
bool HasPlayer();
uint64_t PlayerGuid();

} // namespace RL::Game::MainThread
