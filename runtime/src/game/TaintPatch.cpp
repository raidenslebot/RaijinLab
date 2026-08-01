#include "TaintPatch.h"
#include "AddressDB.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstring>

namespace RL::Game::Taint {
namespace {

struct Patch {
    uintptr_t addr = 0;
    uint8_t original[16]{};
    uint8_t patched[16]{};
    size_t len = 0;
};

// Grew from 256 → 1024 so a build with many inlined HW-gate checks does not
// silently overflow the table. SaveAndPatch now also logs the very first
// overflow so we can spot the ceiling in the field instead of degrading
// invisibly on Restore().
Patch g_patches[1024];
int g_count = 0;
int g_overflow = 0;
bool g_applied = false;

bool WriteMem(uintptr_t addr, const void* data, size_t len) {
    DWORD old = 0;
    if (!VirtualProtect(reinterpret_cast<void*>(addr), len, PAGE_EXECUTE_READWRITE, &old))
        return false;
    memcpy(reinterpret_cast<void*>(addr), data, len);
    // Restore original protection. Must NOT reuse `old` as the new-protection
    // argument — otherwise we'd set the page to PAGE_EXECUTE_READWRITE
    // permanently (because after the first call `old` holds the value we just
    // installed). Use a separate throwaway to receive the previous value.
    DWORD prev = 0;
    VirtualProtect(reinterpret_cast<void*>(addr), len, old, &prev);
    FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(addr), len);
    return true;
}

bool SaveAndPatch(uintptr_t addr, const void* data, size_t len) {
    // Overflow is silent to callers by design (they only care per-site), but
    // we track & log first occurrence so a mismatched Restore() surface is
    // debuggable instead of "some patches were dropped, no idea which".
    if (g_count >= (int)(sizeof(g_patches) / sizeof(g_patches[0])) || len > 16) {
        if (g_overflow++ == 0)
            RL::Log::Error("taint: patch table overflow at addr=%08X len=%u count=%d",
                           (unsigned)addr, (unsigned)len, g_count);
        return false;
    }
    // Idempotency guard — a second Apply pass that saw the SAME address as
    // "already patched" would record the CURRENT (patched) bytes as
    // `original`, so Restore() would then write the patched bytes back and
    // never actually revert. Skip if we already own this site.
    for (int i = 0; i < g_count; ++i) {
        if (g_patches[i].addr == addr) return true;
    }
    __try {
        auto& p = g_patches[g_count];
        p.addr = addr;
        p.len = len;
        memcpy(p.original, reinterpret_cast<void*>(addr), len);
        memcpy(p.patched, data, len);
        if (!WriteMem(addr, data, len)) return false;
        ++g_count;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

uint8_t ReadByte(uintptr_t addr) {
    __try {
        return *reinterpret_cast<uint8_t*>(addr);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0xFF;
    }
}

void ZeroDword(uintptr_t addr) {
    // Validate address before blind write — a wrong offset in AddressDB
    // corrupts random client memory leading to ACCESS_VIOLATION crashes
    // (observed: 0x00000065 NULL vtable dereference from corrupted globals).
    if (!addr || addr < 0x00400000 || addr > 0x07FFFFFF) {
        RL::Log::Error("taint: ZeroDword REFUSED invalid addr 0x%08X", (unsigned)addr);
        return;
    }
    // Read existing value — if it looks like a valid pointer (>0x00400000),
    // this is probably NOT a taint counter and zeroing it would corrupt state.
    __try {
        DWORD cur = *reinterpret_cast<DWORD*>(addr);
        if (cur > 0x00400000 && cur < 0x07FFFFFF) {
            RL::Log::Warn("taint: ZeroDword SKIP addr 0x%08X contains pointer-like 0x%08X",
                          (unsigned)addr, (unsigned)cur);
            return;
        }
        RL::Log::Info("taint: ZeroDword 0x%08X old=0x%08X", (unsigned)addr, (unsigned)cur);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        RL::Log::Error("taint: ZeroDword unreadable addr 0x%08X", (unsigned)addr);
        return;
    }
    DWORD z = 0;
    WriteMem(addr, &z, 4);
}

bool GetTextSection(uintptr_t& start, uintptr_t& end) {
    HMODULE base = GetModuleHandleA(nullptr);
    if (!base) return false;
    auto dos = reinterpret_cast<PIMAGE_DOS_HEADER>(base);
    auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>(reinterpret_cast<uint8_t*>(base) + dos->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (memcmp(sec[i].Name, ".text", 5) == 0) {
            start = reinterpret_cast<uintptr_t>(base) + sec[i].VirtualAddress;
            end = start + sec[i].Misc.VirtualSize;
            return true;
        }
    }
    return false;
}

} // namespace

bool Apply() {
    if (g_applied) return true;
    using namespace RL::Game::Addr;

    RL::Log::Info("taint: applying FrameScript taint patches (lua_unlocker lineage)");

    // 1) Zero taint globals
    ZeroDword(TaintContext);
    ZeroDword(CombatLockdown);
    ZeroDword(ExecCounter);
    ZeroDword(EventHandlerPtr);

    // 2) NOP event handler SET if matches C7 05 ...
    uint8_t b0 = ReadByte(EventHandlerSet);
    uint8_t b1 = ReadByte(EventHandlerSet + 1);
    if (b0 == 0xC7 && b1 == 0x05) {
        uint8_t nops[10];
        memset(nops, 0x90, 10);
        SaveAndPatch(EventHandlerSet, nops, 10);
        RL::Log::Info("taint: EventHandlerSet NOP'd");
    } else {
        RL::Log::Warn("taint: EventHandlerSet unexpected bytes %02X %02X", b0, b1);
    }

    // 3) VM taint JE -> JMP
    uint8_t jmp = 0xEB;
    if (ReadByte(VMTaintSkip1) == 0x74) {
        SaveAndPatch(VMTaintSkip1, &jmp, 1);
        RL::Log::Info("taint: VMTaintSkip1 JE->JMP");
    }
    if (ReadByte(VMTaintSkip2) == 0x74) {
        SaveAndPatch(VMTaintSkip2, &jmp, 1);
        RL::Log::Info("taint: VMTaintSkip2 JE->JMP");
    }

    // 4) Stub TaintErrorReporter if push ebp
    if (ReadByte(TaintErrorReporter) == 0x55) {
        uint8_t stub[] = {0x31, 0xC0, 0xC3}; // xor eax,eax; ret
        SaveAndPatch(TaintErrorReporter, stub, 3);
        RL::Log::Info("taint: TaintErrorReporter stubbed");
    }

    // 5) Hardware event gates scan
    uintptr_t textS = 0, textE = 0;
    int hw = 0;
    if (GetTextSection(textS, textE) && HardwareEventFlag) {
        uint8_t pattern[7] = {0x83, 0x3D, 0, 0, 0, 0, 0x00};
        uint32_t flag = static_cast<uint32_t>(HardwareEventFlag);
        memcpy(pattern + 2, &flag, 4);
        for (uintptr_t p = textS; p + 9 < textE; ++p) {
            if (memcmp(reinterpret_cast<void*>(p), pattern, 7) == 0) {
                uint8_t op = ReadByte(p + 7);
                if (op == 0x74) {
                    SaveAndPatch(p + 7, &jmp, 1);
                    ++hw;
                } else if (op == 0x75) {
                    uint8_t n2[] = {0x90, 0x90};
                    SaveAndPatch(p + 7, n2, 2);
                    ++hw;
                }
            }
        }
        RL::Log::Info("taint: hardware-event gates patched=%d", hw);
    }

    g_applied = true;
    RL::Log::Info("taint: applied patches=%d", g_count);
    return true;
}

void Restore() {
    // Iterate strictly last-to-first so overlapping patches unwind LIFO.
    // Additionally, verify the current bytes still match what we installed —
    // if they don't, something else (or a second Apply pass we missed) has
    // touched this VA and blindly writing `original` risks tearing that
    // stranger's code. In that case skip and log.
    for (int i = g_count - 1; i >= 0; --i) {
        auto& p = g_patches[i];
        uint8_t cur[16]{};
        bool readOk = true;
        __try {
            memcpy(cur, reinterpret_cast<void*>(p.addr), p.len);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            readOk = false;
        }
        if (!readOk || memcmp(cur, p.patched, p.len) != 0) {
            RL::Log::Warn("taint: skip restore at %08X — bytes drifted", (unsigned)p.addr);
            continue;
        }
        WriteMem(p.addr, p.original, p.len);
    }
    g_count = 0;
    g_applied = false;
    RL::Log::Info("taint: restored");
}

bool IsApplied() { return g_applied; }
int PatchCount() { return g_count; }

namespace {
bool g_hw_only = false;
int g_hw_count = 0;
} // namespace

bool ApplyHardwareGatesOnly() {
    if (g_hw_only || g_applied) return true;
    using namespace RL::Game::Addr;

    uintptr_t textS = 0, textE = 0;
    if (!GetTextSection(textS, textE) || !HardwareEventFlag) {
        RL::Log::Warn("hwgates: no text section or flag");
        return false;
    }

    uint8_t pattern[7] = {0x83, 0x3D, 0, 0, 0, 0, 0x00};
    uint32_t flag = static_cast<uint32_t>(HardwareEventFlag);
    memcpy(pattern + 2, &flag, 4);
    uint8_t jmp = 0xEB;
    int hw = 0;
    // Match the full-taint Apply() loop verbatim — pattern is
    //     `cmp dword ptr [HardwareEventFlag], 0`  (7 bytes; last 4 are the
    //     exact VA of the flag global).
    // With those 4 bytes being a specific fixed VA the false-positive rate is
    // ~1 in 2^32; the earlier boundary-check heuristic that filtered by "prev
    // byte looks like a control-flow terminator" rejected almost every real
    // site (production dropped from ~30 patches to 2, and the 2 that landed
    // could be misaligned false positives — this broke manual casts too).
    // Trust the pattern; only bail via a sanity ceiling far above the real
    // count (~250+ patch attempts means the pattern itself is wrong, not
    // that we should silently install a partial set).
    constexpr int kHwGateSanityCap = 1000;

    for (uintptr_t p = textS; p + 9 < textE && hw < kHwGateSanityCap; ++p) {
        __try {
            if (memcmp(reinterpret_cast<void*>(p), pattern, 7) != 0)
                continue;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            continue;
        }
        uint8_t op = ReadByte(p + 7);
        if (op == 0x74) {
            if (SaveAndPatch(p + 7, &jmp, 1)) {
                ++hw;
                RL::Log::Trace("hwgate site va=%08X op=74->EB", (unsigned)(p + 7));
            }
        } else if (op == 0x75) {
            uint8_t n2[] = {0x90, 0x90};
            if (SaveAndPatch(p + 7, n2, 2)) {
                ++hw;
                RL::Log::Trace("hwgate site va=%08X op=75->NOP2", (unsigned)(p + 7));
            }
        }
    }
    if (hw >= kHwGateSanityCap)
        RL::Log::Warn("hwgates: hit sanity cap %d — investigate pattern quality",
                      kHwGateSanityCap);

    g_hw_count = hw;
    g_hw_only = hw > 0;
    // Soft-set flag as well
    __try {
        *reinterpret_cast<volatile uint32_t*>(HardwareEventFlag) = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    RL::Log::Warn("hwgates: patched=%d (HW-only, no full taint)", hw);
    return g_hw_only;
}

bool HardwareGatesApplied() { return g_hw_only || g_applied; }
int HardwareGateCount() { return g_hw_only ? g_hw_count : (g_applied ? g_count : 0); }

} // namespace RL::Game::Taint
