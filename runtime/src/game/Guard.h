#pragma once
#include <csetjmp>
#include <Windows.h>
#include <atomic>
#include "core/Log.h"

// ===========================================================================
// VEH longjmp guard for game-function calls from the bridge.
//
// WHY (2026-08-01, permanent): SEH (__try/__except) is a DEAD guard in this
// stealth module — the PEB loader lists are unlinked and PE headers wiped, so
// RtlIsValidHandler cannot validate our frames and an AV inside a __try is
// never caught; it propagates into the game's Lua protected-call wrapper
// (0x858A16), which corrupts the Lua closure table and produces the
// garbage-eip crash family (Lua VM executing a corrupted function pointer).
//
// A Vectored Exception Handler runs BEFORE SEH and works regardless of loader
// visibility. While a Guard::Scope is armed, an AV anywhere in the guarded
// game call is caught, the stack is restored via longjmp to the scope's
// checkpoint (the faulting instruction never lands, so no memory corruption),
// and EXCEPTION_CONTINUE_EXECUTION is returned — the exception is fully
// consumed by us and the game's Lua wrapper NEVER sees it.
//
// USAGE (the guarded call MUST be inside `if (!g.Caught())`):
//   {
//       RL::Game::Guard::Scope g;
//       if (!g.Caught()) {
//           Spell_C_CastSpell(spellId, ...);   // game call that may AV
//       }
//       if (g.Caught()) {
//           RL::Log::Warn("AV 0x%08X", (unsigned)g.Code());
//           return -1;
//       }
//       return 1;
//   }
//
// RULES:
//   - Do NOT use __try/__except in any function that also arms a Guard::Scope
//     (MSVC forbids mixing setjmp and SEH in one frame).
//   - Do NOT place C++ objects with destructors BETWEEN the Scope construction
//     and the guarded call — longjmp will not unwind them.
//   - Guards nest (a Scope inside another Scope's guarded region is fine).
// ===========================================================================

namespace RL::Game::Guard {

struct Region {
    jmp_buf jmp;
    volatile LONG armed;   // 1 while the guarded call may run
    int rc;                // exception code when caught
    Region* prev;          // outer scope on this thread
};

inline thread_local Region* g_top = nullptr;
inline bool g_installed = false;

// ---- Guard-catch forensics (2026-08-02, DIAG) -----------------------------
// The game Lua-VM closure-corruption crash family (eip in data, frame=0 ret
// 0x858A16) happens right after a guarded game call. Record EVERY guard catch
// (VEH longjmp recovery) into a small ring so CrashHandler can dump which
// guarded calls AV'd in the seconds before the fatal fault — the fastest path
// to the exact AV site. This is the "Guard::Scope longjmp-recovery crash
// vector" the project's own comments name; here we finally measure it.
struct CatchRec {
    uint32_t seq; uint32_t t_ms; uint32_t code;
    uintptr_t eip;    // faulting instruction (game function that AV'd)
    uintptr_t caller; // return address at [faultEsp] -> our guarded call site
};
inline CatchRec g_catches[64] = {};
inline std::atomic<uint32_t> g_catchSeq{0};

inline void RecordCatch(uint32_t code, uintptr_t eip, uintptr_t caller) {
    uint32_t s = g_catchSeq.fetch_add(1) + 1;
    CatchRec& c = g_catches[s % 64];
    c.seq = s;
    c.t_ms = (uint32_t)(GetTickCount() & 0xFFFFFFFFu);
    c.code = code;
    c.eip = eip;
    c.caller = caller;
}

inline void DumpGuardCatches() {
    uint32_t s = g_catchSeq.load();
    if (s == 0) return;
    RL::Log::Warn("guard.catches total=%u", s);
    int printed = 0;
    for (uint32_t i = 0; i < 64 && printed < 24; ++i) {
        uint32_t idx = (s - i) % 64;
        const CatchRec& c = g_catches[idx];
        if (c.seq == 0) continue;
        RL::Log::Warn("guard.catch +%ums #%u code=0x%08X eip=0x%08X caller=0x%08X",
                      (int)((uint32_t)(GetTickCount() & 0xFFFFFFFFu) - c.t_ms),
                      (unsigned)c.seq, c.code, (unsigned)c.eip, (unsigned)c.caller);
        ++printed;
    }
}

inline LONG WINAPI Handler(_EXCEPTION_POINTERS* ep) {
    Region* r = g_top;
    if (!r || !r->armed) return EXCEPTION_CONTINUE_SEARCH;
    // 2026-08-02 (hardening): if a faulting game call corrupted OUR stack
    // frame, longjmp into the saved checkpoint double-faults in the Scope
    // constructor's recovery path (live: 1.10.69 RVA 0x788A — the saved `this`
    // at [ebp-4] read as 0). Detect a corrupt checkpoint: the setjmp point is
    // SHALLOWER than the faulting call, so its saved ESP (_JUMP_BUFFER.Esp at
    // jmp+0x10) must be ABOVE the faulting ESP by a plausible depth. If it is
    // 0 / garbage / not deeper, do NOT longjmp — fall through so CrashHandler
    // logs the REAL fault instead of the recovery double-fault.
    CONTEXT* c = ep->ContextRecord;
    uintptr_t faultEsp = c ? (uintptr_t)c->Esp : 0;
    uintptr_t savedEsp = *(uintptr_t*)((uint8_t*)r->jmp + 0x10);
    if (savedEsp < 0x10000u || faultEsp < 0x10000u
        || savedEsp <= faultEsp || savedEsp > faultEsp + 0x200000u) {
        r->armed = 0;
        return EXCEPTION_CONTINUE_SEARCH;
    }
    r->armed = 0;
    r->rc = (int)ep->ExceptionRecord->ExceptionCode;
    uintptr_t callRet = 0;
    if (faultEsp >= 0x10000u && faultEsp < 0x10000000u)
        callRet = *(uintptr_t*)faultEsp; // return addr on the faulting frame
    RecordCatch((uint32_t)r->rc, c ? (uintptr_t)c->Eip : 0u, callRet);
    longjmp(r->jmp, 1);
    return EXCEPTION_CONTINUE_EXECUTION; // never reached (longjmp above)
}

inline void Install() {
    if (g_installed) return;
    g_installed = true;
    // FIRST=1 -> runs before CrashHandler and before the game's handlers, so
    // a guarded AV is fully consumed here and never reaches the Lua wrapper.
    AddVectoredExceptionHandler(1, Handler);
}

class Scope {
public:
    int caught; // 0 = completed normally, else the exception code

    Scope() : caught(0) {
        Install();
        r_.prev = g_top;
        r_.armed = 0;
        r_.rc = 0;
        g_top = &r_;
        if (setjmp(r_.jmp) == 0) {
            r_.armed = 1; // normal entry — guarded call runs next
        } else {
            // longjmp returned: an AV occurred inside the guarded region.
            r_.armed = 0;
            caught = r_.rc;
        }
    }
    ~Scope() {
        g_top = r_.prev;
    }
    bool Caught() const { return caught != 0; }
    int Code() const { return caught; }

private:
    Region r_;
};

} // namespace RL::Game::Guard
