#include <Windows.h>
#include <string>
#include <cstdio>
#include <cinttypes>
#include <cstdint>
#include <map>
#include <vector>
#include <algorithm>
#include "bridge/Ipc.h"
#include "core/Log.h"
#include "core/Config.h"
#include "core/Patterns.h"
#include "core/PebUnlink.h"
#include "game/Offsets.h"
#include "game/AddressDB.h"
#include "game/ObjectManager.h"
#include "game/MainThread.h"
#include "game/TaintPatch.h"
#include "game/LiveScan.h"
#include "game/Guard.h"
#include "lua/Lua.h"
#include "bridge/Dispatch.h"

// ---- Runtime Address Resolver — pattern-specific scanning -----------------
// Different taint globals have different access patterns:
//   cmp [addr], 0  (83 3D) → HardwareEventFlag (checked by gate code)
//   mov [addr], 0  (C7 05) → TaintContext (zeroed to clear taint)
//   inc [addr]     (FF 05) → ExecCounter (incremented on taint)
//   mov [addr], 1  (C7 05) → also HardwareEventFlag (set before cast)
// We track counts per pattern per address and resolve each global by its
// dominant pattern.

struct ResolvedAddrs {
    uintptr_t HardwareEventFlag = 0;
    uintptr_t TaintContext = 0;
    uintptr_t ExecCounter = 0;
    uintptr_t CombatLockdown = 0;
    uintptr_t EventHandlerPtr = 0;
};

static ResolvedAddrs g_resolved;

static ResolvedAddrs ScanAllTaintAddresses() {
    ResolvedAddrs out;
    HMODULE base = GetModuleHandleA(nullptr);
    if (!base) return out;
    auto dos = reinterpret_cast<PIMAGE_DOS_HEADER>(base);
    auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>(reinterpret_cast<uint8_t*>(base) + dos->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uintptr_t textS = 0, textE = 0;
    for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (memcmp(sec[i].Name, ".text", 5) == 0) {
            textS = reinterpret_cast<uintptr_t>(base) + sec[i].VirtualAddress;
            textE = textS + sec[i].Misc.VirtualSize;
            break;
        }
    }
    if (!textS) return out;

    // Per-pattern reference counts
    std::map<uintptr_t, int> cmpRefs;  // cmp [addr], 0 → HW flag
    std::map<uintptr_t, int> mov0Refs; // mov [addr], 0 → TaintContext
    std::map<uintptr_t, int> incRefs;  // inc [addr]    → ExecCounter
    std::map<uintptr_t, int> mov1Refs; // mov [addr], 1 → HW flag (alternate)

    auto isWritable = [](uintptr_t addr) -> bool {
        if (!addr || addr < 0x00400000 || addr > 0x07FFFFFF) return false;
        MEMORY_BASIC_INFORMATION mbi{};
        if (!VirtualQuery(reinterpret_cast<void*>(addr), &mbi, sizeof(mbi))) return false;
        if (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) return false;
        return (mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY)) != 0;
    };

    for (uintptr_t p = textS; p + 10 < textE; ++p) {
        uint8_t* bp = reinterpret_cast<uint8_t*>(p);
        uintptr_t addr = 0;
        if (bp[0] == 0x83 && bp[1] == 0x3D) {
            addr = *reinterpret_cast<uint32_t*>(bp + 2);
            if (isWritable(addr)) cmpRefs[addr]++;
        } else if (bp[0] == 0xC7 && bp[1] == 0x05) {
            addr = *reinterpret_cast<uint32_t*>(bp + 2);
            uint32_t imm = *reinterpret_cast<uint32_t*>(bp + 6);
            if (isWritable(addr)) {
                if (imm == 0) mov0Refs[addr]++;
                else if (imm == 1) mov1Refs[addr]++;
            }
        } else if (bp[0] == 0xFF && bp[1] == 0x05) {
            addr = *reinterpret_cast<uint32_t*>(bp + 2);
            if (isWritable(addr)) incRefs[addr]++;
        }
    }

    // HardwareEventFlag: most cmp-referenced writable address.
    // cmp [flag], 0 is the definitive gate-check pattern used by Spell_C_CastSpell.
    // mov1 is supplementary — not all builds set the flag via mov [addr], 1.
    {
        uintptr_t best = 0; int bestN = 0;
        for (auto& kv : cmpRefs) { if (kv.second > bestN) { bestN = kv.second; best = kv.first; } }
        if (best && bestN >= 3) out.HardwareEventFlag = best;
    }

    // TaintContext: must have BOTH mov0 AND inc refs.
    // If dual-pattern found nothing, fall back to most mov0-ref'd address
    // that is NOT the HardwareEventFlag and has ≥2 refs.

    // TaintContext + ExecCounter: prefer dual-pattern (mov0+inc).
    // Fall back to most mov0-ref'd address (≠HW flag, ≥2 refs) if no dual match.
    std::vector<std::pair<uintptr_t,int>> dualRefs;
    for (auto& kv : mov0Refs) {
        if (incRefs[kv.first] > 0) {
            dualRefs.push_back({kv.first, kv.second + incRefs[kv.first]});
        }
    }
    if (!dualRefs.empty()) {
        std::sort(dualRefs.begin(), dualRefs.end());
        uintptr_t bestTc = 0; int bestTcN = 0;
        for (auto& d : dualRefs) {
            if (d.second > bestTcN) { bestTcN = d.second; bestTc = d.first; }
        }
        if (bestTc && bestTcN >= 2) {
            out.TaintContext = bestTc;
            for (auto& d : dualRefs) {
                if (d.first != bestTc && std::abs((int64_t)(d.first - bestTc)) <= 0x10) {
                    out.ExecCounter = d.first; break;
                }
            }
        }
    }
    if (!out.TaintContext) {
        // Fallback: most mov0-ref'd writable address that's not the HW flag
        uintptr_t best = 0; int bestN = 0;
        for (auto& kv : mov0Refs) {
            if (kv.first != out.HardwareEventFlag && kv.second > bestN) { bestN = kv.second; best = kv.first; }
        }
        if (best && bestN >= 2) out.TaintContext = best;
    }

    // CombatLockdown + EventHandlerPtr: mov0-only near TaintContext (no inc refs)
    if (out.TaintContext) {
        std::vector<uintptr_t> nearby;
        for (auto& kv : mov0Refs) {
            if (kv.first != out.TaintContext && kv.first != out.ExecCounter
                && std::abs((int64_t)(kv.first - out.TaintContext)) <= 0x18
                && incRefs[kv.first] == 0) {
                nearby.push_back(kv.first);
            }
        }
        std::sort(nearby.begin(), nearby.end());
        if (nearby.size() >= 1) out.CombatLockdown = nearby[0];
        if (nearby.size() >= 2) out.EventHandlerPtr = nearby[1];
    }

    LOG_W("sys.scan", "hw=0x%08X(cmp=%d+m1=%d) tc=0x%08X(m0=%d+inc=%d) ec=0x%08X cl=0x%08X eh=0x%08X",
          (unsigned)out.HardwareEventFlag, (int)cmpRefs[out.HardwareEventFlag], (int)mov1Refs[out.HardwareEventFlag],
          (unsigned)out.TaintContext, (int)mov0Refs[out.TaintContext], (int)incRefs[out.TaintContext],
          (unsigned)out.ExecCounter, (unsigned)out.CombatLockdown, (unsigned)out.EventHandlerPtr);
    return out;
}

static volatile bool g_run = true;
static HANDLE g_mutex = nullptr;
static HMODULE g_self = nullptr;

// ---- Corrupted-indirect-call skip (2026-08-01) ---------------------------
// The game's own exit / .NET-export dispatch (0x40D06E -> 0x40CEE4, mscoree
// CorExitProcess resolver; writable callback tables at 0x9E0AF8/0x9E0B08)
// occasionally holds a corrupted function pointer. The processor jumps to
// non-image memory (live: eip=0x66AAF090, AV_READ fault=0x3C) and faults on
// the first read — a classic "call through a garbage pointer" crash that the
// scoped Guard cannot cover because it happens on the GAME's async path, not
// inside one of our guarded calls.
//
// We ONLY act on that exact signature:
//   * exception is AV or illegal-instruction,
//   * NO Guard::Scope is armed on this thread (a guarded region must keep
//     using the longjmp guard — never skip its fault),
//   * EIP is NOT inside any image executable section (Ascension.exe, our DLL,
//     or system DLLs) -> a garbage / corrupted function pointer,
//   * the stack top (the return address the corrupted `call` pushed) points
//     back into Ascension.exe .text.
// Then we resume at that return address (Esp += 4) — the corrupted call is
// skipped exactly as if the target function had returned. Everything else
// falls through to Guard::Handler / CrashHandler unchanged.
static LONG WINAPI SkipCorruptCall(_EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    // A guarded region must use the longjmp guard, not this skip.
    if (RL::Game::Guard::g_top && RL::Game::Guard::g_top->armed)
        return EXCEPTION_CONTINUE_SEARCH;

    CONTEXT* ctx = ep->ContextRecord;
    uintptr_t ip = ctx->Eip;

    // EIP inside Ascension.exe .text? -> real game code, not a corrupt jump.
    if (ip >= 0x00401000u && ip < 0x009DE3B2u)
        return EXCEPTION_CONTINUE_SEARCH;
    // EIP inside our own DLL? -> our code; Guard / CrashHandler should own it.
    if (g_self) {
        uintptr_t lo = (uintptr_t)g_self;
        // Image size is unreliable after the header wipe; +0x40000 is ample.
        if (ip >= lo && ip < lo + 0x40000u)
            return EXCEPTION_CONTINUE_SEARCH;
    }
    // EIP inside a system DLL (kernel32/ntdll/user32 load at 0x7Cxxxxxx /
    // 0x77xxxxxx on this 32-bit client; anything >= 0x70000000 is system or
    // high-reserved)? -> not a corrupt jump to garbage; let the OS handle it.
    if (ip >= 0x70000000u)
        return EXCEPTION_CONTINUE_SEARCH;

    // The corrupted `call` pushed its return address on the stack. But the
    // garbage target (a freed .NET JIT region) may have EXECUTED a few
    // instructions before faulting, pushing more entries — so the return
    // address is not necessarily at [esp]. Scan a small window for the FIRST
    // value that points into Ascension.exe .text (0x401000-0x9DE3B2); data /
    // vtables live at 0x9E0000+ so they never match. Resume at that address.
    uintptr_t esp = ctx->Esp;
    if (esp < 0x10000u || (esp & 3)) return EXCEPTION_CONTINUE_SEARCH;
    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery((LPCVOID)esp, &mbi, sizeof(mbi)))
        return EXCEPTION_CONTINUE_SEARCH;
    static const DWORD kRW = PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & kRW) == 0)
        return EXCEPTION_CONTINUE_SEARCH;

    uintptr_t ret = 0;
    uintptr_t retEsp = esp;
    // Widen the scan (live: 0x66FBF090 crash had the game return at
    // [esp+0x58]) — cover [esp, esp+0x200) plus a small headroom below.
    for (uintptr_t a = esp - 0x40; a < esp + 0x200u; a += 4) {
        if (a < 0x10000u) break;
        uintptr_t v = *(uintptr_t*)a;
        if (v >= 0x00401000u && v < 0x009DE3B2u) { ret = v; retEsp = a; break; }
    }
    // Fallback: walk the EBP frame chain (same walk CrashHandler uses) — the
    // corrupted frame's caller often survives there even when the linear
    // [esp] window got clobbered by the garbage target's partial execution.
    if (!ret && ctx->Ebp >= 0x10000u) {
        uintptr_t* frame = (uintptr_t*)ctx->Ebp;
        for (int i = 0; i < 16 && frame && (uintptr_t)frame >= 0x10000u &&
                         IsBadReadPtr(frame, 8) == 0; ++i) {
            uintptr_t r = frame[1];
            if (r >= 0x00401000u && r < 0x009DE3B2u) { ret = r; retEsp = (uintptr_t)&frame[1]; break; }
            uintptr_t* next = (uintptr_t*)frame[0];
            if (!next || next <= frame) break;
            frame = next;
        }
    }
    if (!ret) return EXCEPTION_CONTINUE_SEARCH; // no game-code return addr found

    // Resume after the corrupted call (skip it entirely).
    RL::Log::Warn("skip corrupt call eip=0x%08X fault=0x%08X -> ret=0x%08X@+%u",
                  (unsigned)ip,
                  (unsigned)(code == EXCEPTION_ACCESS_VIOLATION
                                 ? ep->ExceptionRecord->ExceptionInformation[1] : 0),
                  (unsigned)ret, (unsigned)(retEsp - esp));
    ctx->Eip = ret;
    ctx->Esp = retEsp + 4;
    return EXCEPTION_CONTINUE_EXECUTION;
}

// ---- Vectored Exception Handler — crash diagnostics ----------------------
// Captures FULL register + stack context on ANY access violation and logs
// to runtime.log BEFORE the process terminates. This is the "black box"
// that answers "what crashed and why" for every ERROR #132.
static LONG WINAPI CrashHandler(_EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION
        && code != EXCEPTION_STACK_OVERFLOW && code != EXCEPTION_IN_PAGE_ERROR)
        return EXCEPTION_CONTINUE_SEARCH;

    CONTEXT* ctx = ep->ContextRecord;
    uintptr_t ip = ctx->Eip;
    uintptr_t faultAddr = 0;
    char faultType[32] = "?";

    if (code == EXCEPTION_ACCESS_VIOLATION) {
        faultAddr = (uintptr_t)ep->ExceptionRecord->ExceptionInformation[1];
        DWORD op = ep->ExceptionRecord->ExceptionInformation[0];
        snprintf(faultType, sizeof(faultType), "AV_%s", op == 0 ? "READ" : op == 1 ? "WRITE" : op == 8 ? "EXEC" : "?");
    } else if (code == EXCEPTION_ILLEGAL_INSTRUCTION) {
        snprintf(faultType, sizeof(faultType), "ILLEGAL");
    } else if (code == EXCEPTION_STACK_OVERFLOW) {
        snprintf(faultType, sizeof(faultType), "STACK_OVF");
    } else {
        snprintf(faultType, sizeof(faultType), "PAGE_ERR");
    }

    // 2026-08-02 (15:10 CRASH — 0x512B07 CRASH SHIELD, 1.10.79): the client's
    // cast-feedback walk (0x856370 -> 0x512B00 GUID resolver) can pass a
    // garbage GUID-struct pointer -> AV_READ at `mov eax,[esi+4]` (0x512B07)
    // / `mov ecx,[esi]` (0x512B0A). Instead of dying, point ESI at a runtime
    // zero-GUID and re-execute: ObjectPtr(0,0,8) returns 0 -> the walk's
    // `test edi,edi; je` branch SKIPS the unresolved target and continues.
    // The process NEVER dies from this AV. Belt-and-suspenders on top of the
    // 1.10.79 GUIDCAST cast-path fix (register + Spell_C(GUID) = the game's
    // own proven path). Rate-limited log so a recurrence is visible.
    if (code == EXCEPTION_ACCESS_VIOLATION &&
        (ip == 0x00512B07 || ip == 0x00512B0A)) {
        static uint64_t s_resolverZeroGuid = 0;   // valid 8-byte zero GUID struct
        static volatile LONG s_shieldCount = 0;
        LONG n = InterlockedIncrement(&s_shieldCount);
        if (n <= 4 || (n & 63) == 1)
            RL::Log::Warn("0x512B07 SHIELD: recovered resolver AV (count=%ld) "
                          "esi=0x%08X", (long)n, (unsigned)ctx->Esi);
        ctx->Esi = (uintptr_t)&s_resolverZeroGuid;
        ctx->Eax = 0;
        ctx->Ecx = 0;
        if (ip == 0x00512B0A)
            ctx->Eip = 0x00512B0D;  // skip both movs; eax/ecx already zeroed
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    // Stack walk: read return addresses from current stack frame
    uintptr_t stack[32] = {};
    int stackN = 0;
    uintptr_t* frame = (uintptr_t*)ctx->Ebp;
    for (int i = 0; i < 32 && frame && IsBadReadPtr(frame, 8) == 0; ++i) {
        uintptr_t ret = frame[1]; // return address is at [ebp+4]
        if (ret > 0x00400000 && ret < 0x07FFFFFF) {
            stack[stackN++] = ret;
        }
        uintptr_t* next = (uintptr_t*)frame[0]; // [ebp+0] = saved ebp
        if (!next || next <= frame) break;
        frame = next;
    }

    LOG_E("crash.fatal", "code=0x%08X type=%s eip=0x%08X fault=0x%08X eax=0x%08X ebx=0x%08X ecx=0x%08X edx=0x%08X esi=0x%08X edi=0x%08X ebp=0x%08X esp=0x%08X",
          code, faultType, (unsigned)ip, (unsigned)faultAddr,
          (unsigned)ctx->Eax, (unsigned)ctx->Ebx, (unsigned)ctx->Ecx, (unsigned)ctx->Edx,
          (unsigned)ctx->Esi, (unsigned)ctx->Edi, (unsigned)ctx->Ebp, (unsigned)ctx->Esp);

    for (int i = 0; i < stackN; ++i) {
        LOG_E("crash.stack", "frame=%d ret=0x%08X", i, (unsigned)stack[i]);
    }

    // 2026-08-02 (0x512B07 diagnostics): dump the client's action-state globals
    // at the fault so a recurring crash is immediately attributable — a bare
    // zero (d4139c=0, d413a0=0, d413a4=0) vs intact save/zero/restore
    // bookkeeping. These are always-mapped client globals; plain reads.
    // 2026-08-02 (1.10.78): also dump the cast-commit state [0xD3F4E0] and the
    // cast-record pointer [0xD3F4E4] — non-zero commit state at the fault
    // proves the client was STILL committing the cast when the walk crashed
    // (i.e. a too-short selection restore raced the commit).
    LOG_E("crash.state",
          "d4139c=0x%08X d413a0=0x%08X d413a4=0x%08X bd07b0=0x%08X bd07b4=0x%08X d3f4e0=0x%08X d3f4e4=0x%08X",
          (unsigned)(*(volatile uint32_t*)0x00D4139C),
          (unsigned)(*(volatile uint32_t*)0x00D413A0),
          (unsigned)(*(volatile uint32_t*)0x00D413A4),
          (unsigned)(*(volatile uint32_t*)0x00BD07B0),
          (unsigned)(*(volatile uint32_t*)0x00BD07B4),
          (unsigned)(*(volatile uint32_t*)0x00D3F4E0),
          (unsigned)(*(volatile uint32_t*)0x00D3F4E4));

    // Crash forensics: dump the last bridge calls that ran before the fault.
    // This turns every crash into "the last N things the addon asked the
    // runtime" — the fastest possible path to the culprit.
    RL::Bridge::DumpRecentBridgeCalls();

    // Crash forensics: dump every guarded game call that AV'd (VEH longjmp
    // recovery) before the fault — the "Guard::Scope longjmp-recovery crash
    // vector" measured. If the closure-table crash follows a guard catch, this
    // names the exact AV site.
    RL::Game::Guard::DumpGuardCatches();

    // Flush log to disk before the process dies
    RL::Log::Shutdown();
    return EXCEPTION_CONTINUE_SEARCH;
}

// Worker: register IsLinuxClient ONLY. Never Execute from worker, never full Taint::Apply,
// never OM enum from worker thread (TLS empty).

static DWORD WINAPI MainThread(LPVOID param) {
    HMODULE self = (HMODULE)param;
    g_self = self;

    char cfgPath[MAX_PATH]{};
    char local[MAX_PATH]{};
    if (GetEnvironmentVariableA("LOCALAPPDATA", local, MAX_PATH) > 0) {
        snprintf(cfgPath, sizeof(cfgPath), "%s\\Microsoft\\Crypto\\Keys\\~cfg.dat", local);
        CreateDirectoryA((std::string(local) + "\\Microsoft\\Crypto\\Keys").c_str(), nullptr);
    } else {
        CreateDirectoryA("C:\\Ascension\\Workspace\\logs", nullptr);
        snprintf(cfgPath, sizeof(cfgPath), "%s", "C:\\Ascension\\Workspace\\logs\\raijinlab_vars.cfg");
    }
    RL::Log::Init("C:\\Ascension\\Workspace\\logs\\runtime.log");
    RL::Config::Init(cfgPath);

    // Install crash diagnostics FIRST — before any client memory is touched.
    // This captures EIP, registers, and stack trace on any AV/illegal instruction
    // and logs them to runtime.log before the process terminates.
    AddVectoredExceptionHandler(1, CrashHandler);
    // Corrupted-indirect-call skip (registered AFTER CrashHandler so it runs
    // before it at same priority). Guard::Handler registers later on first
    // Scope use and therefore runs before this one — armed guards always win.
    AddVectoredExceptionHandler(1, SkipCorruptCall);
    LOG_W("sys.crash", "handler installed (crash + skipcorrupt)");

    RL::Config::Set("om.enable", "0");
    // EnumVisibleObjects is guarded by a VEH longjmp guard (SafeEnumVisibleAt)
    // so it is crash-safe from inside the Lua VM — full unit discovery stays
    // enabled. om.enum defaults to 1 in ObjectManager.
    RL::Config::Set("taint.patch", "1");
    RL::Config::Flush();

    LOG_W("sys.boot", "self=%p ver=%s hwflag=0x%08X",
          self, RL::Bridge::Version(), (unsigned)RL::Game::Addr::HardwareEventFlag);

    RL::Config::Set("om.enable", "0");
    RL::Config::Set("taint.patch", "1");
    RL::Config::Flush();

    // Single-instance guard. The previous code used an ANONYMOUS mutex, which
    // can never detect a second instance (each injection made its own unnamed
    // mutex), so injecting twice spawned two workers that both registered into
    // _G and raced each other - corruption + flaky runtime detection. Use a
    // session-local NAMED mutex (GUID-looking, innocuous): the second injection
    // sees ERROR_ALREADY_EXISTS and does NOT register, leaving the first
    // instance as the sole owner of the bridge.
    bool secondary = false;
    g_mutex = CreateMutexA(nullptr, FALSE, "Local\\{7A9F2C4E-1D6B-4E8A-9C31-5F0A2B7D6E14}");
    if (g_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        secondary = true;
        RL::Log::Warn("secondary instance detected - this worker will NOT register (bridge already owned)");
    }

    RL::Game::Offsets::InitFromPatterns();
    LOG_I("sys.offsets", "Spell_C=0x%08X ObjPtr=0x%08X",
          (unsigned)RL::Game::Offsets::F().Spell_C_CastSpell,
          (unsigned)RL::Game::Offsets::F().ClntObjMgrObjectPtr);

    RL::Lua::Init();
    LOG_I("sys.lua", "api=%s", RL::Lua::Ready() ? "1" : "0");

    // Live-scan internal client functions (cooldown/time/spell-info) from the
    // RUNNING process by walking verified handler bytecode. Self-updating every
    // inject. Resolved addresses feed pure-C++ SpellCooldownMs/ValidateCast.
    if (!secondary) {
        auto resolved = RL::Game::Scan::ResolveInternals();
        RL::Lua::SetResolvedInternals(
            resolved.getCooldownInternal, resolved.getTimeInternal,
            resolved.getSpellInfoInternal,
            resolved.cooldownOk, resolved.timeOk, resolved.spellInfoOk);
    }

    RL::Ipc::Start();

    LOG_W("sys.worker", "start ver=%s om=0 taint=0", RL::Bridge::Version());

    // Registration state machine (CRASH LESSON — permanent):
    //
    // 2026-07-31 ERROR #132 @ 0x00857D05, crash time == "Register failed":
    // worker called FrameScript_RegisterFunction during ADDON_LOADED (Details
    // loading) because kHardTimeout registered after ~6s WITHOUT g_InWorld==1.
    // SEH "caught" the worker AV but left the Lua VM corrupt; main thread then
    // fatally AVd (null [eax] in FrameScript). Hard-timeout bypass is DELETED.
    //
    // Rules:
    //   1) Register ONLY when g_InWorld flag is 1 for a sustained window.
    //   2) Never register on glue / char-select / load-screen (flag==0).
    //   3) No hard-timeout fallback that ignores the flag.
    //   4) Worker uses pure memory reads only (never GetActivePlayer cross-thread).
    //   5) One-shot bootstrap only (no periodic re-register).
    //
    // NOTE (L1 exception): initial Register is still off main-thread — without
    // it IsLinuxClient is never bound. That is acceptable ONLY after in-world.
    bool registered = false;
    bool everRegistered = false; // after first success, /reload can rebind faster
    void* lastL = nullptr;
    int settle = 0;          // ticks since this lua_State went stable
    int strongStreak = 0;    // consecutive strong (flag|local|guid)
    int mediumStreak = 0;    // consecutive medium (wf|conn|mgr) — Ascension normal
    int failBackoff = 0;     // ticks to wait after a failed Register
    int tick = 0;
    // Registration policy:
    //   STRONG (flag|local|guid): modest settle.
    //   MEDIUM (0xE only): ~8s continuous — Ascension often never gets strong.
    //   NEVER treat lua_State=NULL as a finished rebind target: brief null
    //   glitches (zone /reload) used to wipe registration and demand another
    //   20s medium wait, leaving the addon on stock IsLinuxClient forever if
    //   the user didn't wait — live "runtime=NO" after rebind (2026-07-31).
    constexpr int kSettleFirst        = 80;  // ~4 s L stable (strong min first)
    constexpr int kStrongFirst        = 30;  // ~1.5 s strong
    constexpr int kMediumStreak       = 100; // ~5 s continuous medium
    constexpr int kSettleMedium       = 160; // ~8 s medium Register (first+rebind)
    constexpr int kSettleRebindStrong = 40;  // ~2 s strong rebind
    constexpr int kStrongRebind       = 20;  // ~1 s
    constexpr int kFailBackoff        = 60;  // ~3 s after Register AV (was 6s)
    constexpr int kFailMedExtra       = 20;  // smaller medium penalty after AV

    int mediumFailPenalty = 0;
    bool pendingRebind = false; // saw L go null or change after a successful bind

    while (g_run) {
        if (GetAsyncKeyState(VK_END) & 1) {
            RL::Log::Info("END key - worker shutdown requested");
            break;
        }

        void* L = RL::Game::Addr::LuaState();

        // Transient NULL: do not spin settle, do not "Register" against nothing.
        // Mark offline once so we force a real rebind when L returns.
        if (!L) {
            if (registered) {
                LOG_W("br.offline", "reason=null_L");
                registered = false;
                pendingRebind = everRegistered;
                RL::Bridge::ResetRegistrationState();
                RL::Config::Set("om.enable", "0");
                RL::Game::OM::OnLuaReload();
            }
            lastL = nullptr;
            settle = 0;
            strongStreak = 0;
            mediumStreak = 0;
            Sleep(50);
            ++tick;
            if ((tick % 40) == 0) {
                RL::Log::Warn(
                    "heartbeat reg=0 ever=%d bits=0x%X settle=0 str=0 med=0 L=null waiting=1",
                    (int)everRegistered, (unsigned)RL::Game::Addr::WorldReadyBits());
            }
            continue;
        }

        if (L != lastL) {
            const bool rebind = everRegistered || pendingRebind;
            LOG_W("br.rebind", "old=%p new=%p rebind=%s",
                  lastL, L, rebind ? "1" : "0");
            lastL = L;
            registered = false;
            settle = 0;
            strongStreak = 0;
            mediumStreak = 0;
            failBackoff = 0;
            pendingRebind = false;
            RL::Bridge::ResetRegistrationState();
            // Freeze OM across rebind — FrameXML load + list walk = crash.
            if (rebind || everRegistered) {
                RL::Config::Set("om.enable", "0");
                RL::Game::OM::OnLuaReload();
                LOG_W("om.frozen", "reason=rebind");
            }
        }

        uint32_t wbits = RL::Game::Addr::WorldReadyBits();
        const bool strong = RL::Game::Addr::WorldReadyStrong(wbits);
        const bool medium = RL::Game::Addr::WorldReadyMedium(wbits);
        if (strong) ++strongStreak; else strongStreak = 0;
        if (medium) ++mediumStreak; else mediumStreak = 0;

        if (failBackoff > 0)
            --failBackoff;

        if (!secondary && L && !registered) {
            ++settle;
            const bool first = !everRegistered;
            const int needSettleStrong = first ? kSettleFirst : kSettleRebindStrong;
            const int needStrong = first ? kStrongFirst : kStrongRebind;
            // Same medium bar first and rebind — safety is OM freeze + force
            // re-push IsLinuxClient, not a 20s blackout that looks "undetected".
            const int needMedStr = kMediumStreak;
            const int needMedSet = kSettleMedium + mediumFailPenalty;

            // Strong requires a real character (localPlayer|guid), never flag alone.
            // Medium (wf|conn|mgr for 8s) is the Ascension fallback when strong never lights.
            const bool pathStrong = strong && strongStreak >= needStrong
                                    && settle >= needSettleStrong
                                    && (wbits & (16u | 32u)) == (16u | 32u);
            const bool pathMedium = medium && mediumStreak >= needMedStr
                                    && settle >= needMedSet;

            // 2026-08-02 (CRASH FIX — "inject at any point"): NEVER Register
            // unless a real player GUID is present via PURE MEMORY. During
            // character load the ClntObjMgr has no active player yet ([mgr+0xC0]
            // == 0) even though wf|conn|mgr (medium bits 0xE) are already lit —
            // FrameScript_RegisterFunction from the worker then races the
            // main thread's loading Lua VM and crashes it (documented load-crash
            // family; live 15:31 heap corruption during load, seq 0). The pure
            // GUID only becomes non-zero once the player spawns in-world.
            const bool playerUp = (RL::Game::Addr::ActiveGuidPure() != 0);
            if ((pathStrong || pathMedium) && !playerUp) {
                // Diagnostic (rate-limited): registration is path-ready but the
                // pure player GUID is 0. During load this is EXPECTED (wait);
                // if it persists long after the world is loaded, the pure-memory
                // guid sources (mgr global / 0xC7B098) are unreliable on this
                // client and need re-verification — never Register mid-load.
                static ULONGLONG s_lastNoPlayerLog = 0;
                if (settle > 0 && (settle % 100) == 0
                    && GetTickCount64() - s_lastNoPlayerLog > 5000ull) {
                    s_lastNoPlayerLog = GetTickCount64();
                    RL::Log::Warn(
                        "br.no.player bits=0x%X settle=%d via=%s pureguid=0 (holding register)",
                        (unsigned)wbits, settle, pathStrong ? "strong" : "medium");
                }
            }

            if ((pathStrong || pathMedium) && playerUp && failBackoff == 0) {
                // DEFERRED STEALTH: world is confirmed fully loaded and stable
                // here — NOW is the safe moment to unlink from the PEB loader
                // lists and wipe our headers (never during the load window).
                RL::Stealth::ApplyDeferredStealth();
                if (RL::Bridge::Register(true)) {
                    registered = true;
                    everRegistered = true;
                    pendingRebind = false;
                    mediumFailPenalty = 0;
                    LOG_W("br.online", "ver=%s L=%p bits=0x%X settle=%d str=%d med=%d via=%s",
                          RL::Bridge::Version(), L, (unsigned)wbits, settle,
                          strongStreak, mediumStreak,
                          pathStrong ? "strong" : "medium");
                    // 2026-08-02 (0x512B07 ROOT-CAUSE FIX): the native frame-tick
                    // hook is installed from the BRIDGE DISPATCH (main thread) —
                    // see Lua_IsLinuxClient in Dispatch.cpp. Installing here from
                    // the worker would race the game main thread executing
                    // 0x7E5120 every frame (torn patch). The bridge install is
                    // idempotent and happens on the first dispatch, which is
                    // guaranteed to precede any OM-capable call.
                } else {
                    LOG_W("br.regfail", "bits=0x%X settle=%d backoff=%d via=%s",
                          (unsigned)wbits, settle, kFailBackoff,
                          pathStrong ? "strong" : "medium");
                    failBackoff = kFailBackoff;
                    strongStreak = 0;
                    mediumStreak = 0;
                    if (!pathStrong)
                        mediumFailPenalty += kFailMedExtra;
                }
            }
        }

        // Heartbeat is diagnostics-only; Trace level so it never floods the
        // shipped runtime.log (Info filtered, Warn/Err shown). Re-enable LOG_W
        // in debug builds when the worker state needs continuous visibility.
        if ((tick % 40) == 0) {
            LOG_T("hb.worker", "reg=%d ever=%d bits=0x%X settle=%d str=%d med=%d L=%p wait=%d",
                  (int)registered, (int)everRegistered, (unsigned)wbits, settle,
                  strongStreak, mediumStreak, L,
                  (!registered && L) ? 1 : 0);
        }

        Sleep(50);
    }

    if (RL::Game::Taint::IsApplied()) {
        RL::Log::Info("restoring full taint patches");
        RL::Game::Taint::Restore();
    }
    if (g_mutex) {
        ReleaseMutex(g_mutex);
        CloseHandle(g_mutex);
    }
    RL::Log::Warn("worker exit");
    RL::Config::Shutdown();
    RL::Log::Shutdown();
    // DO NOT FreeLibraryAndExitThread here:
    //   (1) PEB is already unlinked and PE headers are wiped, so ntdll's
    //       LdrUnloadDll would read a zeroed SizeOfImage and VirtualFree the
    //       wrong pages - including pages still referenced by
    //       FrameScript_RegisterFunction's cached &Lua_IsLinuxClient pointer.
    //   (2) There is no reliable main-thread unregister path (FrameScript
    //       unregister must run from the main thread and we're on a worker),
    //       so any subsequent Lua/AC dispatch after unload jumps into
    //       unmapped memory.
    // Safer: leave the DLL mapped until the process exits. The worker just
    // stops running.
    (void)self;
    ExitThread(0);
    return 0;
}

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        // DEFERRED stealth (2026-08-01): PEB unlink + PE header wipe are NOT
        // applied here — mutating the process LDR lists / our headers during
        // the game's world-load Lua VM window crashes the game's Lua VM
        // (eip=0x0085C47A, NULL+0x28; worker never even registered). The
        // worker applies them once the world is confirmed fully loaded, so
        // absolute stealth is preserved at the safe moment.
        RL::Stealth::RequestDeferredApply(h);
        HANDLE t = CreateThread(nullptr, 0, MainThread, h, 0, nullptr);
        if (t) CloseHandle(t);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_run = false;
    }
    return TRUE;
}
