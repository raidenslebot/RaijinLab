#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace RL::Patterns {

struct Signature {
    const char* name;
    // IDA-style: "55 8B EC ?? ?? ?? 01" where ?? is wildcard
    const char* pattern;
    uintptr_t expectedFallback; // known good VA for this build
};

struct Resolved {
    std::string name;
    uintptr_t address = 0;
    bool matchedPattern = false;
    bool matchedFallback = false;
    bool prologueOk = false;
    uint8_t bytes[16]{};
};

// Scan module image for pattern; returns address in [moduleBase, moduleBase+size) or 0
uintptr_t FindPattern(uintptr_t moduleBase, size_t moduleSize, const char* idaPattern);

// When scanning a PE mapped at moduleBase with preferred image base (usually 0x400000),
// pass preferredBase so near-matching works. If 0, uses moduleBase as preferred.
std::vector<Resolved> ResolveAllEx(uintptr_t moduleBase, size_t moduleSize, uintptr_t preferredBase);

// Validate prologue at VA looks like real code
bool PrologueLooksValid(uintptr_t va);

// Resolve full Ascension signature set; writes report path
std::vector<Resolved> ResolveAll(uintptr_t moduleBase, size_t moduleSize);
bool WriteReport(const std::vector<Resolved>& results, const char* path);

// Module helpers
bool GetModuleInfo(const char* moduleName, uintptr_t* base, size_t* size);

} // namespace RL::Patterns
