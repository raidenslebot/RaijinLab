#pragma once

struct lua_State;

namespace RL::Bridge {

// Full IsLinuxClient / RaijinLab_Runtime dispatcher (124 APIs + meta)
int Dispatch(lua_State* L);

// Register with FrameScript
bool Register();

// Clear the internal "already registered" latch. Call whenever the observed
// lua_State pointer changes (a /reload or char-select round-trip creates a
// fresh Lua VM whose _G no longer contains IsLinuxClient); without this the
// next Register() early-returns success without actually re-binding the
// global, and the addon sees the runtime as offline.
void ResetRegistrationState();

const char* Version();

} // namespace RL::Bridge
