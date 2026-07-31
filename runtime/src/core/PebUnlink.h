#pragma once
#include <Windows.h>

namespace RL::Stealth {

// Remove this module from PEB loader lists so Process.Modules / DivxTac
// DetectHackModules does not enumerate it. x86 only (Ascension).
// Call once from DllMain after DisableThreadLibraryCalls, before CreateThread.
// Returns true if at least one list entry was unlinked.
bool UnlinkModuleFromPeb(HMODULE self);

// Zero DOS/NT headers in-memory after load (imports/relocs already applied).
// Breaks casual PE dumps / signature scans against our image base.
// Safe on x86 (stack SEH, no RUNTIME_FUNCTION table required).
bool WipePeHeaders(HMODULE self);

// Full attach stealth: PEB unlink + header wipe. Always-on by default;
// set RL_PEB_UNLINK=0 to skip unlink (headers still wiped unless RL_WIPE_PE=0).
bool ApplyLoadStealth(HMODULE self);

} // namespace RL::Stealth
