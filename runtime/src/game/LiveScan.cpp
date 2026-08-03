#include "LiveScan.h"
#include "Mem.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstring>

namespace RL::Game::Scan {

// PE section bounds (scan report, Ascension 12340)
static constexpr uintptr_t kTextStart = 0x00401000;
static constexpr uintptr_t kTextEnd   = 0x009DE3B3;
// Lua C API cluster (lua_gettop..lua_pushcclosure) — NOT internal functions.
static constexpr uintptr_t kLuaApiStart = 0x0084C000;
static constexpr uintptr_t kLuaApiEnd   = 0x00861000;

// Verified handler addresses (AscensionLuaHandlers.h — pattern-matched)
static constexpr uintptr_t kHandlerGetSpellCooldown = 0x00540E80;
static constexpr uintptr_t kHandlerGetTime          = 0x006081F0;
static constexpr uintptr_t kHandlerGetSpellInfo     = 0x00540A30;

bool IsValidFunction(uintptr_t addr) {
    if (addr < kTextStart || addr > kTextEnd) return false;
    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery((void*)addr, &mbi, sizeof(mbi))) return false;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return false;
    uint8_t b[3];
    // VirtualQuery-guarded read — no __try dependency (SEH broken under stealth).
    if (!Mem::detail::PageReadable(addr)) return false;
    memcpy(b, (void*)addr, 3);
    if (b[0] == 0x55) return true;
    if (b[0] == 0x8B && b[1] == 0xFF) return true;
    if (b[0] == 0x83 && b[1] == 0xEC) return true;
    return false;
}

static bool IsLuaApi(uintptr_t addr) {
    return addr >= kLuaApiStart && addr <= kLuaApiEnd;
}

// Minimal x86 instruction length for compiler-generated code.
// Returns bytes consumed by the instruction at buf[pos].
static int LengthOf(const uint8_t* buf, int pos, int size) {
    if (pos >= size) return 1;
    int i = pos;
    while (i < size) {
        uint8_t b = buf[i];
        if (b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E || b == 0x36 ||
            b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65 || b == 0x66 || b == 0x67) {
            ++i; continue;
        }
        break;
    }
    if (i >= size) return 1;
    uint8_t op = buf[i];

    switch (op) {
        case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55:
        case 0x56: case 0x57: case 0x58: case 0x59: case 0x5A: case 0x5B:
        case 0x5C: case 0x5D: case 0x5E: case 0x5F: case 0x90: case 0x91:
        case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
        case 0x98: case 0x99: case 0x9C: case 0x9D: case 0x9E: case 0x9F:
        case 0xAA: case 0xAB: case 0xAC: case 0xAD: case 0xAE: case 0xAF:
        case 0xCC: case 0xCE: case 0xCF: case 0xC3: case 0xC9:
        case 0xEB: case 0xEC: case 0xED: case 0xEE: case 0xEF:
        case 0xF4: case 0xF5: case 0xF8: case 0xF9: case 0xFA: case 0xFB:
        case 0xFC: case 0xFD:
            return i + 1 - pos;
        case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5:
        case 0xB6: case 0xB7: case 0xE4: case 0xE5: case 0xE6: case 0xE7:
            return i + 2 - pos;
        case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD:
        case 0xBE: case 0xBF: case 0xE8: case 0xE9:
            return i + 5 - pos;
        case 0x68: return i + 5 - pos;
        case 0x6A: return i + 2 - pos;
        case 0xA0: case 0xA1: case 0xA2: case 0xA3:
            return i + 5 - pos;
        case 0x0F:
            return i + 2 - pos;
        case 0xC0: case 0xC1: case 0xC6: case 0xC7: {
            int extra = 2;
            if (i + 1 < size) {
                uint8_t m = buf[i + 1];
                if ((m & 0xC0) == 0x40) extra += 1;
                else if ((m & 0xC0) == 0x80) extra += 4;
                else if ((m & 0xC0) == 0x00 && (m & 0x07) == 0x05) extra += 4;
            }
            int imm = (op == 0xC1 || op == 0xC6) ? 1 : (op == 0xC7 ? 4 : 1);
            return i + extra + imm - pos;
        }
        case 0xD0: case 0xD1: case 0xD2: case 0xD3:
            return i + 2 - pos;
        default: {
            if (i + 1 >= size) return 1;
            uint8_t m = buf[i + 1];
            int extra = 2;
            if ((m & 0xC0) == 0x40) extra += 1;
            else if ((m & 0xC0) == 0x80) extra += 4;
            else if ((m & 0xC0) == 0x00) {
                int rm = m & 0x07;
                if (rm == 0x04) extra += 1;
                else if (rm == 0x05) extra += 4;
            }
            return i + extra - pos;
        }
    }
}

// Scan handler for E8 call instructions; collect internal (non-Lua-API) targets.
int ScanHandlerInternalCalls(uintptr_t handlerAddr, uintptr_t* outTargets, int maxTargets) {
    if (!outTargets || maxTargets <= 0) return 0;

    struct CallInfo { uintptr_t target; };
    CallInfo calls[48];
    int nCalls = 0;

    uint8_t buf[600];
    // VirtualQuery-guarded copy — no __try dependency (SEH broken under stealth).
    if (!Mem::detail::PageReadable(handlerAddr) ||
        !Mem::detail::PageReadable(handlerAddr + sizeof(buf) - 1)) {
        RL::Log::Warn("LiveScan: unreadable handler at 0x%08X", (unsigned)handlerAddr);
        return 0;
    }
    memcpy(buf, (void*)handlerAddr, sizeof(buf));

    int pos = 0;
    while (pos + 5 < (int)sizeof(buf) && nCalls < 48) {
        uint8_t op = buf[pos];
        if (op == 0xE8) {
            int32_t rel = *(int32_t*)(buf + pos + 1);
            uintptr_t target = handlerAddr + pos + 5 + (uintptr_t)(intptr_t)rel;
            calls[nCalls].target = target;
            ++nCalls;
            pos += 5;
            continue;
        }
        int len = LengthOf(buf, pos, (int)sizeof(buf));
        if (len < 1) len = 1;
        pos += len;
    }

    int found = 0;
    for (int i = 0; i < nCalls && found < maxTargets; ++i) {
        uintptr_t t = calls[i].target;
        if (!IsLuaApi(t) && IsValidFunction(t)) {
            bool dup = false;
            for (int j = 0; j < found; ++j) if (outTargets[j] == t) { dup = true; break; }
            if (!dup) outTargets[found++] = t;
        }
    }
    return found;
}

ResolvedInternal ResolveInternals() {
    ResolvedInternal r{};

    {
        uintptr_t targets[16]{};
        int n = ScanHandlerInternalCalls(kHandlerGetSpellCooldown, targets, 16);
        RL::Log::Info("LiveScan: GetSpellCooldown internal calls=%d", n);
        if (n > 0) {
            r.getCooldownInternal = targets[n - 1];
            r.cooldownOk = true;
            RL::Log::Info("LiveScan: InternalGetCooldown=0x%08X", (unsigned)r.getCooldownInternal);
        } else {
            RL::Log::Warn("LiveScan: no internal calls in GetSpellCooldown handler");
        }
    }

    {
        uintptr_t targets[8]{};
        int n = ScanHandlerInternalCalls(kHandlerGetTime, targets, 8);
        RL::Log::Info("LiveScan: GetTime internal calls=%d", n);
        if (n > 0) {
            r.getTimeInternal = targets[0];
            r.timeOk = true;
            RL::Log::Info("LiveScan: InternalGetTime=0x%08X", (unsigned)r.getTimeInternal);
        } else {
            RL::Log::Warn("LiveScan: no internal calls in GetTime handler");
        }
    }

    {
        uintptr_t targets[16]{};
        int n = ScanHandlerInternalCalls(kHandlerGetSpellInfo, targets, 16);
        RL::Log::Info("LiveScan: GetSpellInfo internal calls=%d", n);
        if (n > 0) {
            r.getSpellInfoInternal = targets[n - 1];
            r.spellInfoOk = true;
            RL::Log::Info("LiveScan: InternalGetSpellInfo=0x%08X", (unsigned)r.getSpellInfoInternal);
        } else {
            RL::Log::Warn("LiveScan: no internal calls in GetSpellInfo handler");
        }
    }

    return r;
}

} // namespace RL::Game::Scan
