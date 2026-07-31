#pragma once

// Registers IsLinuxClient + RaijinLab_Runtime with FrameScript.
// Call from main thread after world/UI is up (or retry until RegisterFunction works).

namespace Bridge {
bool RegisterLuaApi();
const char* RuntimeVersion();
void OnPulse(); // optional periodic OM refresh
} // namespace Bridge
