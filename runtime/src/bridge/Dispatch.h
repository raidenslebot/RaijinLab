#pragma once

struct lua_State;

namespace RL::Bridge {

// Full IsLinuxClient / RaijinLab_Runtime dispatcher (124 APIs + meta)
int Dispatch(lua_State* L);

// Register with FrameScript. force=true always re-pushes IsLinuxClient
// (required after /reload new lua_State).
bool Register(bool force = false);

// Clear the internal "already registered" latch. Call whenever the observed
// lua_State pointer changes (a /reload or char-select round-trip creates a
// fresh Lua VM whose _G no longer contains IsLinuxClient); without this the
// next Register() early-returns success without actually re-binding the
// global, and the addon sees the runtime as offline.
void ResetRegistrationState();

const char* Version();

// Dump the ring buffer of recent bridge calls (crash forensics). Called from
// the VEH CrashHandler in main.cpp so runtime.log always shows what ran last.
void DumpRecentBridgeCalls();

} // namespace RL::Bridge
