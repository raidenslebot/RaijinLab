#pragma once
#include <cstdint>
#include <Windows.h>

namespace RL::Game::Mem {

// Cheap first-pass filter. Reject only the NULL page.
//
// Do NOT cap at 0x7FFF0000 — Ascension is LARGEADDRESSAWARE and the object
// heap lives in the high 2GB (PosProbe: rawObjPtr=0xA1C7B050). That ceiling
// zeroed every ObjectPtr hit and made LocalPtr/positions always fail.
// Real crash guard is the SEH wrapper on the actual dereference below.
inline bool Readable(uintptr_t p) {
    return p >= 0x10000u;
}

// SEH-wrapped raw read.
// Why: Read<T>() is invoked pervasively during OM enum on descriptor pointers,
// unit position fields, and next-node walks. Any of those may point at a page
// that passed Readable()'s coarse range check but was decommitted or turned
// PAGE_GUARD between the check and the deref (unit despawn during enum,
// heap trim during world entry, etc.). Prior to this guard, a stale pointer
// AV'd the caller and unwound out of a mid-iteration OM walker, corrupting
// state. Returning T{} lets the caller observe the miss and continue.
template <typename T>
inline T Read(uintptr_t address) {
    if (!Readable(address)) return T{};
    T out{};
    __try {
        out = *reinterpret_cast<T*>(address);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        out = T{};
    }
    return out;
}

// SEH-wrapped raw write. Symmetric hardening to Read<T>() — a stale target
// pointer that happens to fall in-range would otherwise AV mid-write.
template <typename T>
inline bool Write(uintptr_t address, const T& value) {
    if (!Readable(address)) return false;
    __try {
        *reinterpret_cast<T*>(address) = value;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Stronger check — actually confirms the containing page is MEM_COMMIT and
// not PAGE_NOACCESS/PAGE_GUARD. Callers that plan to hold a pointer across
// multiple derefs (WalkListIntoPods next-node, FillPod descriptor) should
// prefer this over Readable(). Costs a syscall per call — do not use in
// tight per-object loops without caching.
inline bool Committed(uintptr_t p) {
    if (!Readable(p)) return false;
    MEMORY_BASIC_INFORMATION mbi{};
    if (VirtualQuery(reinterpret_cast<LPCVOID>(p), &mbi, sizeof(mbi)) != sizeof(mbi))
        return false;
    if (mbi.State != MEM_COMMIT) return false;
    DWORD prot = mbi.Protect;
    if (prot & (PAGE_NOACCESS | PAGE_GUARD)) return false;
    return (prot & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                    PAGE_EXECUTE | PAGE_EXECUTE_READ |
                    PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

} // namespace RL::Game::Mem
