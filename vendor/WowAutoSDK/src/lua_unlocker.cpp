/**
 * FrameScript Patch v5
 * WoW 3.3.5a Build 12340
 *
 * All addresses verified against the on-disk binary.
 * Uses ONLY binary patches - no Lua API calls, no function hooks.
 * This avoids crashes from incorrect/unverified function addresses.
 *
 * Compile (MSVC x86):
 *   cl /LD /O2 /GS- /EHa /MT lua_unlocker.cpp user32.lib kernel32.lib /Fe:lua_unlocker.dll
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <cstdio>

// ============================================================
// Addresses — runtime loaded from JSON, compile-time fallbacks
// ============================================================

// Include auto-generated addresses if available (compile-time fallbacks)
#if __has_include("wow_addresses_12340.h")
#include "wow_addresses_12340.h"
#endif

// Runtime address loader — resolves from wow_addresses.json next to exe
#define ADDR_LOADER_IMPL
#include "addr_loader.h"

// Backward-compatible aliases for this file's patch functions.
// These read from the runtime-loaded addr:: namespace, falling back to
// compile-time ADDR_* macros if runtime loading fails.
// Undefine compile-time macros first to avoid redefinition warnings.
#undef ADDR_TaintContext
#undef ADDR_ExecCounter
#undef ADDR_CombatLockdown
#undef ADDR_EventHandlerPtr
#undef ADDR_EventHandlerSet
#undef ADDR_VMTaintSkip1
#undef ADDR_VMTaintSkip2
#undef ADDR_TaintErrorReporter
#undef ADDR_issecure_JNE
#undef ADDR_forceinsecure
#undef ADDR_securecall_save
#undef ADDR_securecall_inc
#undef ADDR_EventHandlerClear
#undef ADDR_HardwareEventFlag
#define ADDR_TaintContext    addr::TaintContext
#define ADDR_ExecCounter     addr::ExecCounter
#define ADDR_CombatLockdown  addr::CombatLockdown
#define ADDR_EventHandlerPtr addr::EventHandlerPtr
#define ADDR_EventHandlerSet addr::EventHandlerSet
#define ADDR_VMTaintSkip1    addr::VMTaintSkip1
#define ADDR_VMTaintSkip2    addr::VMTaintSkip2
#define ADDR_TaintErrorReporter addr::TaintErrorReporter
#define ADDR_LuaState        addr::g_luaState
#define ADDR_issecure_JNE    addr::issecure_JNE
#define ADDR_forceinsecure   addr::forceinsecure
#define ADDR_securecall_save addr::securecall_save
#define ADDR_securecall_inc  addr::securecall_inc
#define ADDR_EventHandlerClear addr::EventHandlerClear
#define ADDR_HardwareEventFlag addr::HardwareEventFlag

// --- issecure / forceinsecure / securecall (binary patches only) ---
// NOTE: issecure/forceinsecure/securecall now resolved via addr:: macros above

// ============================================================
// Logging
// ============================================================

static FILE* g_log = nullptr;

static void Log(const char* fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fflush(g_log);
}

// ============================================================
// Memory helpers
// ============================================================

static bool WriteMem(uintptr_t addr, const void* data, size_t len) {
    DWORD old;
    if (!VirtualProtect((void*)addr, len, PAGE_EXECUTE_READWRITE, &old))
        return false;
    memcpy((void*)addr, data, len);
    VirtualProtect((void*)addr, len, old, &old);
    FlushInstructionCache(GetCurrentProcess(), (void*)addr, len);
    return true;
}

static bool NopRange(uintptr_t addr, size_t len) {
    DWORD old;
    if (!VirtualProtect((void*)addr, len, PAGE_EXECUTE_READWRITE, &old))
        return false;
    memset((void*)addr, 0x90, len);
    VirtualProtect((void*)addr, len, old, &old);
    FlushInstructionCache(GetCurrentProcess(), (void*)addr, len);
    return true;
}

// Saved original + patch bytes for Warden VEH restoration
struct Patch {
    uintptr_t addr;
    uint8_t   original[16];
    uint8_t   patched[16];
    size_t    len;
};
static Patch g_patches[2048];
static int   g_patchCount = 0;

static void SaveAndPatch(uintptr_t addr, const void* patchData, size_t len) {
    if (g_patchCount >= 2048) {
        Log("[!] g_patches FULL at %d, cannot save 0x%08X\n", g_patchCount, addr);
        return;
    }
    Patch& p = g_patches[g_patchCount++];
    p.addr = addr;
    p.len  = len;
    DWORD old;
    VirtualProtect((void*)addr, len, PAGE_EXECUTE_READWRITE, &old);
    memcpy(p.original, (void*)addr, len);
    memcpy(p.patched, patchData, len);
    memcpy((void*)addr, patchData, len);
    VirtualProtect((void*)addr, len, old, &old);
    FlushInstructionCache(GetCurrentProcess(), (void*)addr, len);
}

static void RestoreAll() {
    for (int i = g_patchCount - 1; i >= 0; --i) {
        WriteMem(g_patches[i].addr, g_patches[i].original, g_patches[i].len);
    }
    g_patchCount = 0;
}

// ============================================================
// Helper: get .text section bounds
// ============================================================

static bool GetTextSection(uintptr_t& start, uintptr_t& end) {
    HMODULE hBase = GetModuleHandleA(nullptr);
    if (!hBase) return false;

    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)hBase;
    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)((uintptr_t)hBase + dos->e_lfanew);
    PIMAGE_SECTION_HEADER sec = IMAGE_FIRST_SECTION(nt);

    for (int i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".text", 5) == 0) {
            start = (uintptr_t)hBase + sec[i].VirtualAddress;
            end = start + sec[i].Misc.VirtualSize;
            return true;
        }
    }
    // Fallback
    start = (uintptr_t)hBase + 0x1000;
    end = start + nt->OptionalHeader.SizeOfImage - 0x1000;
    return true;
}

// ============================================================
// PATCH 1: Zero taint globals
// ============================================================

static void PatchTaintGlobals() {
    DWORD zero = 0;
    WriteMem(ADDR_TaintContext, &zero, 4);
    WriteMem(ADDR_CombatLockdown, &zero, 4);
    WriteMem(ADDR_ExecCounter, &zero, 4);
    Log("[+] Taint globals zeroed\n");
}

// ============================================================
// PATCH 2: Kill event handler pointer [D413B0]
// ============================================================
// The taint system fires ADDON_ACTION_BLOCKED via [D413B0].
// Zero the pointer AND NOP the instruction that sets it.

static void PatchEventHandlerPtr() {
    DWORD zero = 0;
    WriteMem(ADDR_EventHandlerPtr, &zero, 4);

    // NOP: C7 05 B0 13 D4 00 50 A6 52 00 (10 bytes)
    // Verify expected bytes before patching
    uint8_t* p = (uint8_t*)ADDR_EventHandlerSet;
    if (p[0] == 0xC7 && p[1] == 0x05) {
        NopRange(ADDR_EventHandlerSet, 10);
        Log("[+] Event handler SET at 0x%08X NOP'd\n", ADDR_EventHandlerSet);
    } else {
        Log("[!] Event handler SET: unexpected bytes 0x%02X 0x%02X\n", p[0], p[1]);
    }

    // Also NOP the CLEAR instruction (10 bytes: C7 05 B0 13 D4 00 00 00 00 00)
    if (addr::IsValid(ADDR_EventHandlerClear)) {
        NopRange(ADDR_EventHandlerClear, 10);
        Log("[+] Event handler ptr zeroed + both SET/CLEAR NOP'd\n");
    } else {
        Log("[!] EventHandlerClear address not resolved, skipping CLEAR NOP\n");
    }
}

// ============================================================
// PATCH 3: Lua VM taint event JE -> JMP (two sites)
// ============================================================

static void PatchLuaVMTaintEvents() {
    uint8_t jmp = 0xEB;

    // Site 1: 0x857493 - expect 0x74 (JE)
    uint8_t b1 = *(uint8_t*)ADDR_VMTaintSkip1;
    if (b1 == 0x74) {
        SaveAndPatch(ADDR_VMTaintSkip1, &jmp, 1);
        Log("[+] VM taint site 1 @ 0x%08X: JE->JMP\n", ADDR_VMTaintSkip1);
    } else if (b1 == 0xEB) {
        Log("[=] VM taint site 1 already patched\n");
    } else {
        Log("[!] VM taint site 1: unexpected 0x%02X\n", b1);
    }

    // Site 2: 0x857317 - expect 0x74 (JE)
    uint8_t b2 = *(uint8_t*)ADDR_VMTaintSkip2;
    if (b2 == 0x74) {
        SaveAndPatch(ADDR_VMTaintSkip2, &jmp, 1);
        Log("[+] VM taint site 2 @ 0x%08X: JE->JMP\n", ADDR_VMTaintSkip2);
    } else if (b2 == 0xEB) {
        Log("[=] VM taint site 2 already patched\n");
    } else {
        Log("[!] VM taint site 2: unexpected 0x%02X\n", b2);
    }
}

// ============================================================
// PATCH 4: Stub TaintErrorReporter (0x513530)
// ============================================================

static void PatchTaintErrorReporter() {
    uint8_t b = *(uint8_t*)ADDR_TaintErrorReporter;
    if (b == 0x55) { // push ebp (verified)
        uint8_t stub[] = { 0x31, 0xC0, 0xC3 }; // xor eax,eax; ret
        SaveAndPatch(ADDR_TaintErrorReporter, stub, 3);
        Log("[+] TaintErrorReporter => no-op\n");
    } else {
        Log("[!] TaintErrorReporter: unexpected 0x%02X\n", b);
    }
}

// ============================================================
// PATCH 5: Hardware-event gates (scan for pattern)
// ============================================================
// Pattern: 83 3D [hwEventFlag] 00 / 74 xx  =>  change 74 to EB
// Also:    83 3D [hwEventFlag] 00 / 75 xx  =>  change 75 to two NOPs
// NOTE: This scans .text for instructions referencing the HW event flag (0xBEAF4C
// for build 12340). For new builds, this address may differ — the pattern scan
// will simply find 0 matches, which is safe. Future: add to address DB for
// runtime resolution.

static void PatchHardwareEventGates() {
    if (!addr::IsValid(ADDR_HardwareEventFlag)) {
        Log("[!] HardwareEventFlag address not resolved, skipping HW gate patches\n");
        return;
    }

    uintptr_t textStart, textEnd;
    if (!GetTextSection(textStart, textEnd)) return;

    // Build pattern dynamically: CMP DWORD PTR [addr], 0
    // Encoding: 83 3D [4-byte LE addr] 00
    uint8_t pattern[7];
    pattern[0] = 0x83;
    pattern[1] = 0x3D;
    memcpy(&pattern[2], &ADDR_HardwareEventFlag, 4);
    pattern[6] = 0x00;
    int patched = 0;

    uint8_t* p = (uint8_t*)textStart;
    uint8_t* e = (uint8_t*)(textEnd - 9);
    while (p < e) {
        if (memcmp(p, pattern, 7) == 0) {
            if (p[7] == 0x74) {
                uint8_t jmpb = 0xEB;
                SaveAndPatch((uintptr_t)(p + 7), &jmpb, 1);
                Log("[+] HW gate JE->JMP @ 0x%08X\n", (uintptr_t)(p + 7));
                patched++;
            } else if (p[7] == 0x75) {
                uint8_t nop2[] = { 0x90, 0x90 };
                SaveAndPatch((uintptr_t)(p + 7), nop2, 2);
                Log("[+] HW gate JNE->NOP @ 0x%08X\n", (uintptr_t)(p + 7));
                patched++;
            }
            p += 9;
        } else {
            p++;
        }
    }
    Log("[+] Patched %d hardware-event gate(s)\n", patched);
}

// ============================================================
// PATCH 6: Inline taint checks [D4139C] (scan for pattern)
// ============================================================

static void PatchInlineTaintChecks() {
    uintptr_t textStart, textEnd;
    if (!GetTextSection(textStart, textEnd)) return;

    if (!ADDR_TaintContext) {
        Log("[!] TaintContext not resolved, skipping inline taint patch\n");
        return;
    }

    int patchedA = 0, patchedB = 0, patchedC = 0;
    // Build pattern dynamically from runtime-resolved TaintContext address
    // Pattern: 83 3D [addr32LE] 00 = cmp dword ptr [TaintContext], 0
    uint8_t patA[7] = { 0x83, 0x3D, 0, 0, 0, 0, 0x00 };
    uint32_t taintAddr = (uint32_t)ADDR_TaintContext;
    memcpy(patA + 2, &taintAddr, 4);

    uint8_t* p = (uint8_t*)textStart;
    uint8_t* end = (uint8_t*)(textEnd - 10);

    while (p < end) {
        // Pattern A: cmp [0xD4139C], 0 followed by JE short
        if (memcmp(p, patA, 7) == 0 && p[7] == 0x74) {
            uint8_t jmpb = 0xEB;
            SaveAndPatch((uintptr_t)(p + 7), &jmpb, 1);
            patchedA++;
            p += 9;
            continue;
        }

        // Pattern A variant: cmp [0xD4139C], 0 followed by JNE short
        if (memcmp(p, patA, 7) == 0 && p[7] == 0x75) {
            uint8_t nop2[] = { 0x90, 0x90 };
            SaveAndPatch((uintptr_t)(p + 7), nop2, 2);
            patchedC++;
            p += 9;
            continue;
        }

        // Pattern A: cmp [0xD4139C], 0 followed by JE near (0F 84)
        if (memcmp(p, patA, 7) == 0 && p[7] == 0x0F && p[8] == 0x84) {
            // 0F 84 rel32 -> 90 E9 rel32 (nop + jmp near, same offset)
            uint8_t patch[] = { 0x90, 0xE9 };
            SaveAndPatch((uintptr_t)(p + 7), patch, 2);
            patchedA++;
            p += 13;
            continue;
        }

        // Pattern A: cmp [0xD4139C], 0 followed by JNE near (0F 85)
        if (memcmp(p, patA, 7) == 0 && p[7] == 0x0F && p[8] == 0x85) {
            uint8_t nop6[] = { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
            SaveAndPatch((uintptr_t)(p + 7), nop6, 6);
            patchedC++;
            p += 13;
            continue;
        }

        // Pattern B: cmp [TaintContext], reg followed by JE/JNE
        if (p[0] == 0x39 && (p[1] & 0xC7) == 0x05) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            if (addr == taintAddr) {
                if (p[6] == 0x74) {
                    uint8_t jmpb = 0xEB;
                    SaveAndPatch((uintptr_t)(p + 6), &jmpb, 1);
                    patchedB++;
                    p += 8;
                    continue;
                }
                if (p[6] == 0x75) {
                    uint8_t nop2[] = { 0x90, 0x90 };
                    SaveAndPatch((uintptr_t)(p + 6), nop2, 2);
                    patchedB++;
                    p += 8;
                    continue;
                }
            }
        }

        p++;
    }

    Log("[+] Inline taint checks: %d typeA, %d typeB, %d typeC\n",
        patchedA, patchedB, patchedC);
}

// ============================================================
// PATCH 7: NOP ALL writes to taint globals (binary scan)
// ============================================================
// Uses NopRange directly - does NOT consume g_patches slots.

static void ScanAndNopTaintWrites() {
    uintptr_t textStart, textEnd;
    if (!GetTextSection(textStart, textEnd)) return;

    Log("[*] Scanning 0x%08X - 0x%08X for taint writes\n", textStart, textEnd);

    // Use runtime-resolved addresses (no hardcoded hex)
    const uint32_t targets[] = {
        (uint32_t)ADDR_TaintContext,
        (uint32_t)ADDR_ExecCounter,
        (uint32_t)ADDR_CombatLockdown
    };
    // Skip if addresses not resolved
    if (targets[0] == 0 || targets[1] == 0 || targets[2] == 0) {
        Log("[!] Taint globals not resolved, skipping write NOP scan\n");
        return;
    }
    int nopsApplied = 0;
    uint8_t* p = (uint8_t*)textStart;
    uint8_t* end = (uint8_t*)(textEnd - 10);

    while (p < end) {
        uint32_t targetAddr = 0;
        int instrLen = 0;
        bool isWrite = false;

        // A3 xx xx xx xx = mov [imm32], eax (5 bytes)
        if (p[0] == 0xA3) {
            uint32_t addr;
            memcpy(&addr, p + 1, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 5; isWrite = true; break; }
            }
        }

        // 89 XX xx xx xx xx = mov [imm32], reg (6 bytes)
        if (!isWrite && p[0] == 0x89 && (p[1] & 0xC7) == 0x05) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 6; isWrite = true; break; }
            }
        }

        // C7 05 xx xx xx xx yy yy yy yy = mov [imm32], imm32 (10 bytes)
        if (!isWrite && p[0] == 0xC7 && p[1] == 0x05) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 10; isWrite = true; break; }
            }
        }

        // 83 XX xx xx xx xx yy = op [imm32], imm8 (7 bytes)
        if (!isWrite && p[0] == 0x83 && (p[1] == 0x05 || p[1] == 0x2D ||
                p[1] == 0x0D || p[1] == 0x25 || p[1] == 0x35)) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 7; isWrite = true; break; }
            }
        }

        // 01 XX xx xx xx xx = add [imm32], reg (6 bytes)
        if (!isWrite && p[0] == 0x01 && (p[1] & 0xC7) == 0x05) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 6; isWrite = true; break; }
            }
        }

        // 29 XX xx xx xx xx = sub [imm32], reg (6 bytes)
        if (!isWrite && p[0] == 0x29 && (p[1] & 0xC7) == 0x05) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 6; isWrite = true; break; }
            }
        }

        // FF 05/0D xx xx xx xx = inc/dec [imm32] (6 bytes)
        if (!isWrite && p[0] == 0xFF && (p[1] == 0x05 || p[1] == 0x0D)) {
            uint32_t addr;
            memcpy(&addr, p + 2, 4);
            for (auto t : targets) {
                if (addr == t) { targetAddr = addr; instrLen = 6; isWrite = true; break; }
            }
        }

        if (isWrite) {
            NopRange((uintptr_t)p, instrLen);
            nopsApplied++;
            p += instrLen;
        } else {
            p++;
        }
    }

    Log("[+] NOP'd %d taint write instructions\n", nopsApplied);
}

// ============================================================
// PATCH 8: issecure() always returns 1
// ============================================================

static void PatchIssecure() {
    uint8_t b = *(uint8_t*)ADDR_issecure_JNE;
    if (b == 0x75) {
        uint8_t nop2[] = { 0x90, 0x90 };
        SaveAndPatch(ADDR_issecure_JNE, nop2, 2);
        Log("[+] issecure: JNE->NOP @ 0x%08X\n", ADDR_issecure_JNE);
    } else {
        Log("[!] issecure: unexpected 0x%02X at 0x%08X\n", b, ADDR_issecure_JNE);
    }
}

// ============================================================
// PATCH 9: forceinsecure() => immediate return
// ============================================================

static void PatchForceInsecure() {
    uint8_t stub[] = { 0x33, 0xC0, 0xC3 }; // xor eax, eax; ret
    SaveAndPatch(ADDR_forceinsecure, stub, 3);
    Log("[+] forceinsecure => xor eax,eax; ret\n");
}

// ============================================================
// PATCH 10: securecall - disable taint tracking
// ============================================================

static void PatchSecurecall() {
    uint8_t b = *(uint8_t*)ADDR_securecall_save;
    if (b == 0xA1) {
        NopRange(ADDR_securecall_save, 5);
        Log("[+] securecall: context save NOP'd\n");
    } else {
        Log("[!] securecall save: unexpected 0x%02X\n", b);
    }

    b = *(uint8_t*)ADDR_securecall_inc;
    if (b == 0x01) {
        NopRange(ADDR_securecall_inc, 6);
        Log("[+] securecall: counter increment NOP'd\n");
    } else {
        Log("[!] securecall inc: unexpected 0x%02X\n", b);
    }
}

// ============================================================
// Continuous taint clearer thread
// ============================================================

static volatile bool g_running = true;

static DWORD WINAPI TaintClearerThread(LPVOID) {
    Log("[*] Taint clearer thread started\n");
    while (g_running) {
        volatile DWORD* pTaint    = (volatile DWORD*)ADDR_TaintContext;
        volatile DWORD* pLockdown = (volatile DWORD*)ADDR_CombatLockdown;
        volatile DWORD* pCounter  = (volatile DWORD*)ADDR_ExecCounter;
        volatile DWORD* pHandler  = (volatile DWORD*)ADDR_EventHandlerPtr;

        if (*pTaint != 0)    *pTaint = 0;
        if (*pLockdown != 0) *pLockdown = 0;
        if (*pCounter != 0)  *pCounter = 0;
        if (*pHandler != 0)  *pHandler = 0;

        Sleep(1);
    }
    return 0;
}

// ============================================================
// Patch verification thread
// ============================================================
// Every 5 seconds, verify critical SaveAndPatch patches are still
// applied. If Warden or something else reverted them, re-apply.

static DWORD WINAPI PatchVerifierThread(LPVOID) {
    Log("[*] Patch verifier thread started\n");
    while (g_running) {
        Sleep(5000);

        int reapplied = 0;
        for (int i = 0; i < g_patchCount; ++i) {
            // Check if current bytes match the patched version
            bool stillPatched = true;
            __try {
                if (memcmp((void*)g_patches[i].addr, g_patches[i].patched, g_patches[i].len) != 0) {
                    stillPatched = false;
                }
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                continue; // Can't read this address, skip
            }

            if (!stillPatched) {
                // Re-apply the patch
                WriteMem(g_patches[i].addr, g_patches[i].patched, g_patches[i].len);
                reapplied++;
            }
        }

        if (reapplied > 0) {
            Log("[!] Patch verifier: re-applied %d reverted patches\n", reapplied);
        }
    }
    return 0;
}

// ============================================================
// Hide DLL from PEB module list
// ============================================================

static void HideFromPEB(HMODULE hMod) {
#ifdef _MSC_VER
    __asm {
        mov eax, fs:[0x30]
        mov eax, [eax + 0x0C]
        mov esi, [eax + 0x0C]
        mov edx, esi
    next_mod:
        mov eax, [esi + 0x18]
        cmp eax, hMod
        je  found_mod
        mov esi, [esi]
        cmp esi, edx
        jne next_mod
        jmp done
    found_mod:
        mov eax, [esi]
        mov ecx, [esi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
        lea edi, [esi + 8]
        mov eax, [edi]
        mov ecx, [edi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
        lea edi, [esi + 16]
        mov eax, [edi]
        mov ecx, [edi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
    done:
    }
#endif
    Log("[+] Hidden from PEB\n");
}

// ============================================================
// Warden memory scan VEH bypass
// ============================================================

static LONG WINAPI WardenPageGuardHandler(PEXCEPTION_POINTERS pExInfo) {
    if (pExInfo->ExceptionRecord->ExceptionCode != STATUS_GUARD_PAGE_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;

    uintptr_t faultAddr = (uintptr_t)pExInfo->ExceptionRecord->ExceptionInformation[1];
    for (int i = 0; i < g_patchCount; ++i) {
        if (faultAddr >= g_patches[i].addr &&
            faultAddr < g_patches[i].addr + g_patches[i].len) {
            // Temporarily restore original bytes so Warden reads clean memory
            WriteMem(g_patches[i].addr, g_patches[i].original, g_patches[i].len);
            // Set single-step flag to re-apply after Warden's read completes
            pExInfo->ContextRecord->EFlags |= 0x100;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static LONG WINAPI WardenSingleStepHandler(PEXCEPTION_POINTERS pExInfo) {
    if (pExInfo->ExceptionRecord->ExceptionCode != STATUS_SINGLE_STEP)
        return EXCEPTION_CONTINUE_SEARCH;

    // Re-apply all patches that were restored for Warden scan
    for (int i = 0; i < g_patchCount; ++i) {
        if (memcmp((void*)g_patches[i].addr, g_patches[i].original, g_patches[i].len) == 0) {
            WriteMem(g_patches[i].addr, g_patches[i].patched, g_patches[i].len);
            // Re-enable PAGE_GUARD (it's consumed on each access)
            MEMORY_BASIC_INFORMATION mbi;
            if (VirtualQuery((void*)g_patches[i].addr, &mbi, sizeof(mbi))) {
                DWORD old;
                VirtualProtect((void*)g_patches[i].addr, g_patches[i].len,
                               mbi.Protect | PAGE_GUARD, &old);
            }
        }
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void InstallWardenBypass() {
    AddVectoredExceptionHandler(1, WardenPageGuardHandler);
    AddVectoredExceptionHandler(1, WardenSingleStepHandler);

    // Set PAGE_GUARD on all patched pages so the VEH fires when Warden reads them
    for (int i = 0; i < g_patchCount; ++i) {
        DWORD old;
        // PAGE_GUARD must be combined with the page's existing protection
        MEMORY_BASIC_INFORMATION mbi;
        if (VirtualQuery((void*)g_patches[i].addr, &mbi, sizeof(mbi))) {
            VirtualProtect((void*)g_patches[i].addr, g_patches[i].len,
                           mbi.Protect | PAGE_GUARD, &old);
        }
    }

    Log("[+] VEH bypass installed (%d patched regions guarded)\n", g_patchCount);
}

// ============================================================
// Main initialization
// ============================================================

static HMODULE g_selfModule = nullptr;
static HANDLE  g_clearerThread = nullptr;

static DWORD WINAPI InitThread(LPVOID hMod) {
    Log("[*] InitThread started\n");

    // Brief delay for process initialization (loader lock release, etc.)
    Sleep(2000);

    // -- Load addresses from runtime JSON first, fallback to compiled-in --
    if (addr::Init()) {
        Log("[+] Runtime address loader: OK (build %d, %d+ addresses)\n", addr::GetBuild(),
            (addr::g_luaState ? 1 : 0) + (addr::g_InWorld ? 1 : 0) +
            (addr::FrameScript_Execute ? 1 : 0) + (addr::TaintContext ? 1 : 0));
    } else {
        Log("[!] Runtime address loader: FAILED — using compile-time fallbacks only\n");
    }

    // Verify exe loaded at expected base (no ASLR for WoW 3.3.5a)
    uintptr_t exeBase = (uintptr_t)GetModuleHandleA(nullptr);
    Log("[*] Exe base check: 0x%08X (expect 0x00400000)\n", exeBase);
    if (exeBase != 0x00400000) {
        Log("[!] FATAL: Wrong exe base - ASLR or wrong process. Aborting.\n");
        return 1;
    }

    // Verify critical addresses are resolved
    if (!ADDR_VMTaintSkip1 || !ADDR_VMTaintSkip2 || !ADDR_TaintErrorReporter || !ADDR_issecure_JNE) {
        Log("[!] FATAL: Critical taint addresses not resolved. Cannot patch.\n");
        return 1;
    }

    // Verify binary identity: check known bytes at verified addresses
    uint8_t chk1 = *(uint8_t*)ADDR_VMTaintSkip1;   // expect 0x74 (JE)
    uint8_t chk2 = *(uint8_t*)ADDR_VMTaintSkip2;   // expect 0x74 (JE)
    uint8_t chk3 = *(uint8_t*)ADDR_TaintErrorReporter; // expect 0x55 (push ebp)
    uint8_t chk4 = *(uint8_t*)ADDR_issecure_JNE;   // expect 0x75 (JNE)
    Log("[*] Binary verify: VMT1=0x%02X VMT2=0x%02X TER=0x%02X ISS=0x%02X\n",
        chk1, chk2, chk3, chk4);
    Log("[*]    Expected:   VMT1=0x74   VMT2=0x74   TER=0x55   ISS=0x75\n");

    int verifyFails = 0;
    if (chk1 != 0x74 && chk1 != 0xEB) { Log("[!] VMTaintSkip1 MISMATCH\n"); verifyFails++; }
    if (chk2 != 0x74 && chk2 != 0xEB) { Log("[!] VMTaintSkip2 MISMATCH\n"); verifyFails++; }
    if (chk3 != 0x55 && chk3 != 0x31) { Log("[!] TaintErrorReporter MISMATCH\n"); verifyFails++; }
    if (chk4 != 0x75 && chk4 != 0x90) { Log("[!] issecure_JNE MISMATCH\n"); verifyFails++; }

    if (verifyFails > 2) {
        Log("[!] FATAL: Too many byte mismatches (%d). Wrong binary version?\n", verifyFails);
        return 1;
    }
    Log("[*] Binary verification passed (%d warnings)\n", verifyFails);

    // Log Lua state for debugging (informational only, not required)
    uintptr_t luaState = *(volatile uintptr_t*)ADDR_LuaState;
    Log("[*] Lua state @ 0x%08X = 0x%08X (info only)\n", ADDR_LuaState, luaState);

    // ---- TARGETED PATCHES (all addresses verified) ----

    PatchTaintGlobals();           // 1. Zero D4139C/A0/A4
    PatchEventHandlerPtr();        // 2. Kill [D413B0] event handler
    PatchLuaVMTaintEvents();       // 3. JE->JMP at two VM sites
    PatchTaintErrorReporter();     // 4. Stub error reporter
    PatchHardwareEventGates();     // 5. Scan: cmp [BEAF4C]; je -> jmp
    PatchInlineTaintChecks();      // 6. Scan: cmp [D4139C]; je/jne
    PatchIssecure();               // 7. issecure always 1
    PatchForceInsecure();          // 8. forceinsecure no-op
    PatchSecurecall();             // 9. securecall passthrough

    // ---- COMPREHENSIVE BINARY SCAN (NopRange, no g_patches) ----

    ScanAndNopTaintWrites();       // 10. NOP all writes to D4139C/A0/A4

    // ---- RUNTIME SAFETY ----

    g_clearerThread = CreateThread(nullptr, 0, TaintClearerThread, nullptr, 0, nullptr);
    CreateThread(nullptr, 0, PatchVerifierThread, nullptr, 0, nullptr);
    InstallWardenBypass();
    HideFromPEB((HMODULE)hMod);

    Log("[+] ============================================\n");
    Log("[+]  Module v7 - ACTIVE\n");
    Log("[+]  Event handler [D413B0] => zeroed + NOP'd\n");
    Log("[+]  VM taint events => always skipped (2 sites)\n");
    Log("[+]  TaintErrorReporter => stubbed\n");
    Log("[+]  HW-event gates => unconditional allow\n");
    Log("[+]  Inline taint checks => forced allow\n");
    Log("[+]  issecure => always 1\n");
    Log("[+]  forceinsecure => no-op\n");
    Log("[+]  securecall => passthrough\n");
    Log("[+]  ALL taint writes => NOP'd\n");
    Log("[+]  Taint clearer => 1000Hz\n");
    Log("[+]  Patch verifier => 5s interval\n");
    Log("[+]  Warden VEH => active\n");
    Log("[+]  PEB => hidden\n");
    Log("[+]  Tracked patches: %d / 2048\n", g_patchCount);
    Log("[+] ============================================\n");

    return 0;
}

// ============================================================
// DLL entry point
// ============================================================

BOOL APIENTRY DllMain(HMODULE hModule, DWORD dwReason, LPVOID lpReserved) {
    (void)lpReserved;
    switch (dwReason) {
    case DLL_PROCESS_ATTACH: {
        DisableThreadLibraryCalls(hModule);
        g_selfModule = hModule;

        char path[MAX_PATH];
        GetModuleFileNameA(NULL, path, MAX_PATH); // NULL = game exe
        char* lastSlash = strrchr(path, '\\');
        if (lastSlash) {
            strcpy(lastSlash + 1, "Logs\\fsc.log");
        }
        // Ensure Logs directory exists
        {
            char dir[MAX_PATH];
            GetModuleFileNameA(NULL, dir, MAX_PATH);
            char* ls = strrchr(dir, '\\');
            if (ls) { strcpy(ls + 1, "Logs"); CreateDirectoryA(dir, nullptr); }
        }
        g_log = fopen(path, "w");
        Log("[*] Module v7 loaded\n");
        Log("[*] Module base: 0x%08X\n", (uintptr_t)hModule);
        Log("[*] Exe base: 0x%08X\n", (uintptr_t)GetModuleHandleA(nullptr));
        Log("[*] Log path: %s\n", path);

        CreateThread(nullptr, 0, InitThread, (LPVOID)hModule, 0, nullptr);
        break;
    }
    case DLL_PROCESS_DETACH:
        g_running = false;
        if (g_clearerThread) {
            WaitForSingleObject(g_clearerThread, 2000);
            CloseHandle(g_clearerThread);
        }
        RestoreAll();
        if (g_log) { Log("[*] Clean detach\n"); fclose(g_log); g_log = nullptr; }
        break;
    }
    return TRUE;
}

// ============================================================
// Exports
// ============================================================

extern "C" __declspec(dllexport) void InitModule(void) {
    InitThread((LPVOID)g_selfModule);
}

extern "C" __declspec(dllexport) void ShutdownModule(void) {
    g_running = false;
    RestoreAll();
}

extern "C" __declspec(dllexport) int GetUnlockerVersion(void) {
    return 7;
}
