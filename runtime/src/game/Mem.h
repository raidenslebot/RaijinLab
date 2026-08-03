#pragma once
#include <cstdint>
#include <Windows.h>

namespace RL::Game::Mem {

// CRITICAL (2026-08-01, permanent):
// This DLL is injected with absolute stealth — PEB loader lists unlinked AND
// PE headers wiped (RL_PEB_UNLINK / RL_WIPE_PE). Under that configuration the
// OS cannot validate our module's SEH frames (RtlIsValidHandler fails for a
// module that is not in the loader's list), so ANY __try/__except in this DLL
// is a dead guard: an access violation is never caught and the process dies.
//   Live proof: rotation tick → ObjectPosition/ObjectCombatReach → a stale
//   descriptor pointer (0xBC00000C after a target despawn) → Mem::Read<uintptr_t>
//   AV'd inside its own __try → fatal DLL+0x6868, no post-crash heartbeat.
// The reliable non-faulting guard is VirtualQuery — a syscall on the target
// address that works regardless of module visibility. All client-memory reads
// must go through these helpers (never a raw deref in a __try block).

// Cheap first-pass filter. Reject only the NULL page.
//
// Do NOT cap at 0x7FFF0000 — Ascension is LARGEADDRESSAWARE and the object
// heap lives in the high 2GB (PosProbe: rawObjPtr=0xA1C7B050). That ceiling
// zeroed every ObjectPtr hit and made LocalPtr/positions always fail.
// The real crash guard is PageReadable() below.
inline bool Readable(uintptr_t p) {
    return p >= 0x10000u;
}

namespace detail {

static constexpr DWORD kReadableProt =
    PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
    PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;

// Per-thread last-page cache: dense reads (descriptor fields, position triples)
// hit the same page repeatedly, so the VirtualQuery syscall is amortized to one
// per page instead of one per read. A page that turns decommitted after being
// cached still risks a fault on the first read after the change — identical to
// the TOCTOU the old SEH design already had — but a stale/freed pointer that
// was NEVER committed is always rejected.
struct PageCache { uintptr_t page = 0; bool ok = false; };
inline PageCache& Cache() {
    static thread_local PageCache c;
    return c;
}

inline bool PageReadable(uintptr_t address) {
    if (!Readable(address)) return false;
    uintptr_t page = address & ~0xFFFu;
    PageCache& c = Cache();
    if (c.page == page) return c.ok;
    MEMORY_BASIC_INFORMATION mbi{};
    bool ok = false;
    if (VirtualQuery(reinterpret_cast<LPCVOID>(page), &mbi, sizeof(mbi)) == sizeof(mbi)) {
        if (mbi.State == MEM_COMMIT &&
            !(mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) &&
            (mbi.Protect & kReadableProt) != 0) {
            ok = true;
        }
    }
    c.page = page;
    c.ok = ok;
    return ok;
}

} // namespace detail

// Non-faulting raw read. Guarded by VirtualQuery (works under stealth), NOT
// by SEH (broken in this module — see header comment). Returns T{} on any
// unreadable page so callers can observe the miss and continue.
template <typename T>
inline T Read(uintptr_t address) {
    if (!detail::PageReadable(address)) return T{};
    return *reinterpret_cast<T*>(address);
}

// Non-faulting raw pointer read (the common uintptr_t case).
inline uintptr_t ReadPtr(uintptr_t address) {
    return Read<uintptr_t>(address);
}

// Non-faulting guarded byte-array copy (VirtualQuery, never raw deref).
// Copies at most `len` bytes starting at `address`; returns bytes actually
// copied (0 on unreadable). Callers must never touch `dst` past the return.
inline size_t ReadBytes(uintptr_t address, void* dst, size_t len) {
    if (!dst || len == 0) return 0;
    uint8_t* d = reinterpret_cast<uint8_t*>(dst);
    size_t done = 0;
    while (done < len) {
        uintptr_t cur = address + done;
        if (!detail::PageReadable(cur)) break;
        // Whole-page cap: never copy past the current page boundary in one go.
        size_t pageRem = 0x1000u - (size_t)(cur & 0xFFFu);
        size_t chunk = len - done;
        if (chunk > pageRem) chunk = pageRem;
        memcpy(d + done, reinterpret_cast<void*>(cur), chunk);
        done += chunk;
    }
    return done;
}

// Non-faulting raw write. Guarded by VirtualQuery (writeable page check).
template <typename T>
inline bool Write(uintptr_t address, const T& value) {
    if (!detail::PageReadable(address)) return false;
    *reinterpret_cast<T*>(address) = value;
    return true;
}

// Stronger one-shot check — confirms the containing page is MEM_COMMIT and
// not PAGE_NOACCESS/PAGE_GUARD. Callers that plan to hold a pointer across
// multiple derefs (WalkListIntoPods next-node, FillPod descriptor) should
// prefer this over Readable(). Costs a syscall per call — do not use in
// tight per-object loops without caching.
inline bool Committed(uintptr_t p) {
    return detail::PageReadable(p);
}

} // namespace RL::Game::Mem
