#include "PebUnlink.h"
#include "core/Log.h"
#include <atomic>

// Fully local PEB/LDR layout for x86 — do not depend on incomplete winternl PEB_LDR_DATA.
namespace RL::Stealth {
namespace {

struct ListEntry {
    ListEntry* Flink;
    ListEntry* Blink;
};

struct LdrDataTableEntry {
    ListEntry InLoadOrderLinks;            // +0x00
    ListEntry InMemoryOrderLinks;          // +0x08
    ListEntry InInitializationOrderLinks; // +0x10
    void* DllBase;                         // +0x18
    void* EntryPoint;                      // +0x1C
    ULONG SizeOfImage;                     // +0x20
    // UNICODE_STRING FullDllName @ +0x24, BaseDllName @ +0x2C on x86
    USHORT FullDllNameLen;                 // +0x24
    USHORT FullDllNameMax;                 // +0x26
    wchar_t* FullDllNameBuf;               // +0x28
    USHORT BaseDllNameLen;                 // +0x2C
    USHORT BaseDllNameMax;                 // +0x2E
    wchar_t* BaseDllNameBuf;               // +0x30
};

struct PebLdrData {
    ULONG Length;
    BOOLEAN Initialized;
    PVOID SsHandle;
    ListEntry InLoadOrderModuleList;       // +0x0C
    ListEntry InMemoryOrderModuleList;
    ListEntry InInitializationOrderModuleList;
};

struct PebX86 {
    BYTE Reserved1[0x0C];
    PebLdrData* Ldr;
};

static void UnlinkListEntry(ListEntry* e) {
    if (!e || !e->Flink || !e->Blink) return;
    e->Blink->Flink = e->Flink;
    e->Flink->Blink = e->Blink;
    e->Flink = e;
    e->Blink = e;
}

static void ScrubName(USHORT& len, USHORT& max, wchar_t* buf) {
    if (!buf || max == 0) return;
    // Overwrite base/full path so residual LDR row (if any) has no brand
    for (USHORT i = 0; i < max / sizeof(wchar_t) && i < 260; ++i)
        buf[i] = 0;
    len = 0;
}

} // namespace

bool UnlinkModuleFromPeb(HMODULE self) {
    if (!self) return false;
    bool any = false;
    __try {
        auto peb = reinterpret_cast<PebX86*>(__readfsdword(0x30));
        if (!peb || !peb->Ldr) return false;
        ListEntry* head = &peb->Ldr->InLoadOrderModuleList;
        for (ListEntry* cur = head->Flink; cur && cur != head; ) {
            ListEntry* next = cur->Flink;
            auto entry = reinterpret_cast<LdrDataTableEntry*>(cur);
            if (entry->DllBase == self) {
                // Scrub names first while entry is still valid
                ScrubName(entry->FullDllNameLen, entry->FullDllNameMax, entry->FullDllNameBuf);
                ScrubName(entry->BaseDllNameLen, entry->BaseDllNameMax, entry->BaseDllNameBuf);
                UnlinkListEntry(&entry->InLoadOrderLinks);
                UnlinkListEntry(&entry->InMemoryOrderLinks);
                UnlinkListEntry(&entry->InInitializationOrderLinks);
                any = true;
                break;
            }
            cur = next;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    return any;
}

bool WipePeHeaders(HMODULE self) {
    if (!self) return false;
    __try {
        auto dos = reinterpret_cast<PIMAGE_DOS_HEADER>(self);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
        auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>(
            reinterpret_cast<BYTE*>(self) + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return false;

        DWORD hdrSize = nt->OptionalHeader.SizeOfHeaders;
        if (hdrSize < 0x200) hdrSize = 0x1000;
        if (hdrSize > 0x2000) hdrSize = 0x1000;

        DWORD old = 0;
        if (!VirtualProtect(self, hdrSize, PAGE_READWRITE, &old))
            return false;
        SecureZeroMemory(self, hdrSize);
        VirtualProtect(self, hdrSize, old, &old);
        FlushInstructionCache(GetCurrentProcess(), self, hdrSize);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ApplyLoadStealth(HMODULE self) {
    if (!self) return false;

    // Short-circuit re-entry. A double DllMain (e.g. a re-inject that maps a
    // fresh copy but hits the same base) would otherwise walk the LDR list a
    // second time, treat our already-unlinked (self-looped) entry as live,
    // and corrupt the head sentinel — anti-cheat's EnumProcessModules would
    // then AV inside ntdll's list walker.
    static bool s_applied = false;
    if (s_applied) return true;
    s_applied = true;

    bool doUnlink = true;
    bool doWipe = true;
    char env[8]{};
    // Opt-out only: RL_PEB_UNLINK=0 disables unlink
    if (GetEnvironmentVariableA("RL_PEB_UNLINK", env, sizeof(env)) > 0 && env[0] == '0')
        doUnlink = false;
    if (GetEnvironmentVariableA("RL_WIPE_PE", env, sizeof(env)) > 0 && env[0] == '0')
        doWipe = false;

    bool ok = true;
    if (doUnlink)
        ok = UnlinkModuleFromPeb(self) && ok;
    if (doWipe)
        ok = WipePeHeaders(self) && ok;
    return ok;
}

// ---- Deferred stealth (2026-08-01) ---------------------------------------
// DllMain only remembers the module; the worker applies unlink+wipe after the
// world is fully loaded. This keeps absolute stealth while never mutating the
// process LDR lists / our headers during the game's fragile world-load Lua VM
// window (which crashes the game's Lua VM — see ApplyLoadStealth docs).
namespace {
HMODULE g_deferredSelf = nullptr;
std::atomic<bool> g_deferredApplied{false};
} // namespace

void RequestDeferredApply(HMODULE self) {
    g_deferredSelf = self;
    // Note: we deliberately do NOT apply here. ApplyDeferredStealth() does.
}

void ApplyDeferredStealth() {
    if (g_deferredApplied.load(std::memory_order_acquire)) return;
    if (!g_deferredSelf) return;
    bool expected = false;
    if (!g_deferredApplied.compare_exchange_strong(expected, true))
        return; // another thread won the race
    bool ok = ApplyLoadStealth(g_deferredSelf);
    if (!ok)
        RL::Log::Warn("stealth: deferred apply returned false (unlink/wipe skipped?)");
}

} // namespace RL::Stealth
