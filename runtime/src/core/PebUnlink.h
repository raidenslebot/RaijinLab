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

// DEFERRED stealth (2026-08-01, default):
//   Injecting during world load is fatal to the game's Lua VM (crash
//   signature eip=0x0085C47A fault=NULL+0x28 — game Lua stack corruption;
//   proven: our worker never even registered). The LDR-list mutation + header
//   wipe racing the game's world-load Lua work is the interference vector.
//   So DllMain only REMEMBERS the module; the actual unlink+wipe is applied
//   by the worker once the world is confirmed fully loaded (post-load, game
//   stable). Absolute stealth is preserved — just applied at the safe moment.
//   The random on-disk temp name still hides us by name during the load
//   window. RL_PEB_UNLINK=0 / RL_WIPE_PE=0 opt-outs still honored.
void RequestDeferredApply(HMODULE self);

// Apply the deferred stealth now (idempotent, thread-safe). Call only when
// the game is confirmed in-world and stable.
void ApplyDeferredStealth();

} // namespace RL::Stealth
