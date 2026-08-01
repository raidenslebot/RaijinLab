#include <Windows.h>
#include <string>
#include <cstdio>
#include <cinttypes>
#include <map>
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
#include "lua/Lua.h"
#include "bridge/Dispatch.h"

// ---- Runtime HardwareEventFlag resolver ----------------------------------
// The hardcoded address from AddressDB (0x00BEAF4C) is wrong for this Ascension
// build — writes to it corrupt executable code causing ILLEGAL_INSTRUCTION.
// Instead, scan .text for 'cmp [addr], 0' patterns, filter for addresses in
// writable data sections, and pick the most-referenced one. This is the
// definitive HardwareEventFlag for THIS build.
static uintptr_t ScanHardwareEventFlag() {
    HMODULE base = GetModuleHandleA(nullptr);
    if (!base) return RL::Game::Addr::HardwareEventFlag; // fallback

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
    if (!textS) return RL::Game::Addr::HardwareEventFlag;

    // Collect all cmp [disp32], 0 addresses
    std::map<uintptr_t, int> refCounts;
    uint8_t pattern[7] = {0x83, 0x3D, 0, 0, 0, 0, 0x00}; // cmp [disp32], 0
    for (uintptr_t p = textS; p + 7 < textE; ++p) {
        if (memcmp(reinterpret_cast<void*>(p), pattern, 3) == 0) { // match opcode bytes
            uintptr_t addr = *reinterpret_cast<uint32_t*>(p + 2); // displacement
            // Verify it's a writable data address (not executable code)
            MEMORY_BASIC_INFORMATION mbi{};
            if (VirtualQuery(reinterpret_cast<void*>(addr), &mbi, sizeof(mbi))) {
                if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE))) {
                    if (mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY)) {
                        refCounts[addr]++;
                    }
                }
            }
        }
    }

    // Pick most-referenced writable address
    uintptr_t best = 0;
    int bestN = 0;
    for (auto& kv : refCounts) {
        if (kv.second > bestN) {
            bestN = kv.second;
            best = kv.first;
        }
    }

    if (best && bestN >= 3) {
        LOG_I("sys.scan", "HardwareEventFlag resolved: 0x%08X (refs=%d, was 0x%08X)",
              (unsigned)best, bestN, (unsigned)RL::Game::Addr::HardwareEventFlag);
        return best;
    }
    LOG_W("sys.scan", "HardwareEventFlag scan FAILED (best=0x%08X refs=%d), using fallback 0x%08X",
          (unsigned)best, bestN, (unsigned)RL::Game::Addr::HardwareEventFlag);
    return RL::Game::Addr::HardwareEventFlag;
}

static volatile bool g_run = true;
static HANDLE g_mutex = nullptr;
static HMODULE g_self = nullptr;

// Mutable HardwareEventFlag — resolved at runtime by scanner, not hardcoded.
namespace RL::Game::Addr {
    uintptr_t HardwareEventFlag = 0x00BEAF4C; // fallback, overwritten by scanner
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
    LOG_I("sys.crash", "handler installed");

    // Resolve HardwareEventFlag dynamically — the hardcoded address in
    // AddressDB is wrong for this Ascension build. Scanner finds the real
    // flag by looking for 'cmp [addr], 0' references in .text and picking
    // the most-referenced writable data address.
    RL::Game::Addr::HardwareEventFlag = ScanHardwareEventFlag();
    LOG_I("sys.boot", "self=%p ver=%s om=0 taint=0 hwflag=0x%08X",
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

            if ((pathStrong || pathMedium) && failBackoff == 0) {
                if (RL::Bridge::Register(true)) {
                    registered = true;
                    everRegistered = true;
                    pendingRebind = false;
                    mediumFailPenalty = 0;
                    LOG_W("br.online", "ver=%s L=%p bits=0x%X settle=%d str=%d med=%d via=%s",
                          RL::Bridge::Version(), L, (unsigned)wbits, settle,
                          strongStreak, mediumStreak,
                          pathStrong ? "strong" : "medium");
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

        if ((tick % 40) == 0) {
            LOG_W("hb.worker", "reg=%d ever=%d bits=0x%X settle=%d str=%d med=%d L=%p wait=%d",
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
        // Always-on load stealth: PEB unlink + PE header wipe (opt-out via env)
        RL::Stealth::ApplyLoadStealth(h);
        HANDLE t = CreateThread(nullptr, 0, MainThread, h, 0, nullptr);
        if (t) CloseHandle(t);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_run = false;
    }
    return TRUE;
}
