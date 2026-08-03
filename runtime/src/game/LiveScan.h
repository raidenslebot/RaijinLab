#pragma once
#include <cstdint>

namespace RL::Game::Scan {

// Result of scanning verified Lua handlers for internal call targets.
// Internal = client C++ functions called BY the Lua handler (NOT Lua API fns).
struct ResolvedInternal {
    uintptr_t getCooldownInternal = 0; // InternalGetCooldown(spellId, tableType, &dur, &start, &unk)
    uintptr_t getTimeInternal = 0;     // InternalGetTime() -> uint32_t gameTimeMs
    uintptr_t getSpellInfoInternal = 0;// InternalGetSpellInfo(...) -> range/cast/power
    bool cooldownOk = false;
    bool timeOk = false;
    bool spellInfoOk = false;
};

// Verify a function address: in .text + valid prologue + readable.
bool IsValidFunction(uintptr_t addr);

// Walk a handler's x86 instructions (variable-length) collecting call targets.
// Lua API cluster = 0x0084xxxx (excluded). Returns internal targets found.
int ScanHandlerInternalCalls(uintptr_t handlerAddr, uintptr_t* outTargets, int maxTargets);

// Resolve all internal function addresses from live process handler bytecode.
// Self-updating every inject. Zero hardcoded internal addresses.
ResolvedInternal ResolveInternals();

} // namespace RL::Game::Scan
