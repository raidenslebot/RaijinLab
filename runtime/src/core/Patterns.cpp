#include "Patterns.h"
#include "Log.h"
#include <Windows.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>
#include <cctype>

namespace RL::Patterns {
namespace {

struct BytePat {
    std::vector<uint8_t> bytes;
    std::vector<bool> mask; // true = must match
};

BytePat ParseIda(const char* ida) {
    BytePat bp;
    const char* p = ida;
    while (*p) {
        while (*p == ' ') ++p;
        if (!*p) break;
        if (p[0] == '?' && (p[1] == '?' || p[1] == ' ' || p[1] == 0)) {
            bp.bytes.push_back(0);
            bp.mask.push_back(false);
            p += (p[1] == '?') ? 2 : 1;
            continue;
        }
        if (std::isxdigit((unsigned char)p[0]) && std::isxdigit((unsigned char)p[1])) {
            char tmp[3] = {p[0], p[1], 0};
            bp.bytes.push_back(static_cast<uint8_t>(strtoul(tmp, nullptr, 16)));
            bp.mask.push_back(true);
            p += 2;
            continue;
        }
        ++p;
    }
    return bp;
}

// Curated signatures — primary resolution path; fallbacks from static RE of Ascension.exe
const Signature kSigs[] = {
    {"ClntObjMgrGetActivePlayer",
     "64 8B 0D 2C 00 00 00 A1 ?? ?? ?? ?? 8B 14 81 8B 4A 08",
     0x004D3790},
    {"ClntObjMgrObjectPtr",
     "55 8B EC 64 8B 0D 2C 00 00 00 A1 ?? ?? ?? ?? 8B 14 81",
     0x004D4DB0},
    {"ClntObjMgrEnumVisibleObjects",
     "55 8B EC A1 ?? ?? ?? ?? 64 8B 0D 2C 00 00 00 53",
     0x004D4B30},
    {"GetCamera",
     "A1 ?? ?? ?? ?? 85 C0 74 07 8B 80 ?? ?? 00 00 C3",
     0x004F5960},
    {"CGPlayer_C_ClickToMove",
     "55 8B EC 83 EC 18 53 8B D9 8B 43 08",
     0x00727400},
    {"CGWorldFrame_C_Intersect",
     "55 8B EC 83 EC 18 8B 45 18 83 05",
     0x007A3B70},
    {"FrameScript_Execute",
     "55 8B EC 51 83 05 ?? ?? ?? ?? 01 A1",
     0x00819210},
    {"FrameScript_RegisterFunction",
     "55 8B EC 8B 45 0C 56 8B 35 ?? ?? ?? ?? 6A 00 50",
     0x00817F90},
    {"lua_gettop",
     "55 8B EC 8B 4D 08 8B 41 0C 2B 41 08",
     0x0084DBD0},
    {"lua_tolstring",
     "55 8B EC 56 8B 75 08 57",
     0x0084E0E0},
    {"lua_pushstring",
     "55 8B EC 8B 55 0C 85 D2",
     0x0084E350},
};

} // namespace

uintptr_t FindPattern(uintptr_t moduleBase, size_t moduleSize, const char* idaPattern) {
    BytePat bp = ParseIda(idaPattern);
    if (bp.bytes.empty() || moduleSize < bp.bytes.size()) return 0;
    const auto* base = reinterpret_cast<const uint8_t*>(moduleBase);
    const size_t last = moduleSize - bp.bytes.size();
    for (size_t i = 0; i <= last; ++i) {
        bool ok = true;
        for (size_t j = 0; j < bp.bytes.size(); ++j) {
            if (bp.mask[j] && base[i + j] != bp.bytes[j]) { ok = false; break; }
        }
        if (ok) return moduleBase + i;
    }
    return 0;
}

// Prefer hit closest to expected VA (reduces false positives on short patterns)
static uintptr_t FindPatternNear(uintptr_t moduleBase, size_t moduleSize, const char* idaPattern,
                                 uintptr_t expectedVa, uintptr_t imagePreferredBase) {
    BytePat bp = ParseIda(idaPattern);
    if (bp.bytes.empty() || moduleSize < bp.bytes.size()) return 0;
    const auto* base = reinterpret_cast<const uint8_t*>(moduleBase);
    const size_t last = moduleSize - bp.bytes.size();
    uintptr_t best = 0;
    size_t bestDist = SIZE_MAX;
    uintptr_t expectedRva = expectedVa >= imagePreferredBase ? expectedVa - imagePreferredBase : expectedVa;
    for (size_t i = 0; i <= last; ++i) {
        bool ok = true;
        for (size_t j = 0; j < bp.bytes.size(); ++j) {
            if (bp.mask[j] && base[i + j] != bp.bytes[j]) { ok = false; break; }
        }
        if (!ok) continue;
        size_t dist = i > expectedRva ? i - expectedRva : expectedRva - i;
        if (dist < bestDist) {
            bestDist = dist;
            best = moduleBase + i;
            // exact-ish
            if (dist < 0x20) break;
        }
    }
    // reject if absurdly far from expected (> 256KB) — treat as no match
    if (best && bestDist > 0x40000) return 0;
    return best;
}

static bool SafeReadBytes(uintptr_t va, uint8_t* out, size_t n) {
    if (!va || !out) return false;
    __try {
        memcpy(out, reinterpret_cast<void*>(va), n);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool PrologueLooksValid(uintptr_t va) {
    uint8_t b[4]{};
    if (!SafeReadBytes(va, b, 4)) return false;
    if (b[0] == 0x55 && b[1] == 0x8B) return true;
    if (b[0] == 0x64 && b[1] == 0x8B) return true;
    if (b[0] == 0xA1) return true;
    if (b[0] == 0x8B) return true;
    if (b[0] == 0x56 || b[0] == 0x57 || b[0] == 0x53) return true;
    if (b[0] == 0x83 && b[1] == 0xEC) return true;
    return false;
}

std::vector<Resolved> ResolveAllEx(uintptr_t moduleBase, size_t moduleSize, uintptr_t preferredBase) {
    if (!preferredBase) preferredBase = 0x400000;
    // Restrict to classic .text window when scanning full PE image (VA 0x1000, ~6MB)
    // For live inject, moduleBase is process base and size is SizeOfImage — full scan OK with near-match.
    std::vector<Resolved> out;
    for (const auto& s : kSigs) {
        Resolved r;
        r.name = s.name;
        uintptr_t found = FindPatternNear(moduleBase, moduleSize, s.pattern, s.expectedFallback, preferredBase);
        if (found) {
            r.address = found;
            r.matchedPattern = true;
        } else {
            // live process: fallback is absolute VA already valid
            // offline map: caller converts
            r.address = s.expectedFallback;
            r.matchedFallback = true;
        }
        // For pattern hits inside mapped buffer, prologue check uses buffer ptr
        uintptr_t checkAddr = r.address;
        if (r.matchedPattern) {
            checkAddr = r.address; // in buffer space when offline
        } else if (r.address >= preferredBase && r.address - preferredBase < moduleSize) {
            checkAddr = moduleBase + (r.address - preferredBase);
        }
        r.prologueOk = PrologueLooksValid(checkAddr);
        if (!SafeReadBytes(checkAddr, r.bytes, 16)) {
            memset(r.bytes, 0, 16);
            r.prologueOk = false;
        }
        out.push_back(r);
        uintptr_t reportVa = r.matchedPattern ? preferredBase + (r.address - moduleBase) : r.address;
        RL::Log::Info("sig %-32s va=0x%08X pat=%d fb=%d prol=%d",
                      r.name.c_str(), (unsigned)reportVa,
                      (int)r.matchedPattern, (int)r.matchedFallback, (int)r.prologueOk);
    }
    return out;
}

std::vector<Resolved> ResolveAll(uintptr_t moduleBase, size_t moduleSize) {
    // Live inject: moduleBase is process image base (usually 0x400000)
    return ResolveAllEx(moduleBase, moduleSize, moduleBase);
}

bool WriteReport(const std::vector<Resolved>& results, const char* path) {
    std::ofstream out(path, std::ios::trunc);
    if (!out) return false;
    out << "# RaijinLab signature resolution report\n";
    for (auto& r : results) {
        out << r.name << "\t0x" << std::hex << r.address << std::dec
            << "\tpat=" << r.matchedPattern
            << "\tfb=" << r.matchedFallback
            << "\tprol=" << r.prologueOk << "\n";
    }
    return true;
}

bool GetModuleInfo(const char* moduleName, uintptr_t* base, size_t* size) {
    HMODULE mod = moduleName ? GetModuleHandleA(moduleName) : GetModuleHandleA(nullptr);
    if (!mod) return false;
    auto dos = reinterpret_cast<PIMAGE_DOS_HEADER>(mod);
    auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>((uint8_t*)mod + dos->e_lfanew);
    if (base) *base = reinterpret_cast<uintptr_t>(mod);
    if (size) *size = nt->OptionalHeader.SizeOfImage;
    return true;
}

} // namespace RL::Patterns
