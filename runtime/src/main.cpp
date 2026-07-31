#include <Windows.h>
#include <string>
#include <cstdio>
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

static volatile bool g_run = true;
static HANDLE g_mutex = nullptr;
static HMODULE g_self = nullptr;

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

    // Cold inject defaults. om.enable stays 0 until PEW arm (addon ArmRuntimeSystems)
    // - Refresh already no-ops without an active player, but char-select Lua can
    // still spam GetObjectCount; keep the list path quiet until fully in-world.
    // After arm, om.enable=1 for the whole session (normal play). User may set 0
    // to kill the world list; single-GUID reads keep working either way.
    RL::Config::Set("om.enable", "0");
    // Taint stays ENTIRELY enabled for the session. The patches themselves are
    // applied from the MAIN THREAD (see Dispatch's ArmUnlock) - never from this
    // worker, which is what froze clients before. This flag only records intent.
    RL::Config::Set("taint.patch", "1");
    RL::Config::Flush();

    RL::Log::Info("worker boot self=%p", self);
    RL::Log::Info("env RL_LOG set (verbose file) + load-stealth applied in DllMain");

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
    RL::Log::Info("offsets ready Spell_C_CastSpell=0x%08X ObjectPtr=0x%08X",
                  (unsigned)RL::Game::Offsets::F().Spell_C_CastSpell,
                  (unsigned)RL::Game::Offsets::F().ClntObjMgrObjectPtr);

    RL::Lua::Init();
    RL::Log::Info("lua api init done");

    // Control channel. Safe to open this early: the pipe thread only queues
    // strings - it never touches Lua or the object manager. The ADDON drains the
    // queue from its OnUpdate, i.e. on the game's main thread, which is the only
    // place client state may be touched at all.
    RL::Ipc::Start();

    RL::Log::Warn("worker %s start om=0 taint=0", RL::Bridge::Version());

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
    int inWorldStreak = 0;   // consecutive ticks with flag==1
    int failBackoff = 0;     // ticks to wait after a failed Register
    int tick = 0;
    // First bind of the session: conservative (crash lesson #132).
    constexpr int kMinSettleFirst    = 60;  // ~3 s
    constexpr int kInWorldStreakFirst = 40; // ~2 s
    // Rebind after /reload: IsLinuxClient is wiped from _G but the world is
    // already live. Wait only long enough for the new VM to finish ADDON_LOADED.
    // (Log proof 2026-07-31: BRIDGE ONLINE then L changes — addon went blind
    // until a full 5s settle; users checked status immediately → "no runtime".)
    constexpr int kMinSettleRebind    = 24; // ~1.2 s
    constexpr int kInWorldStreakRebind = 16; // ~0.8 s
    constexpr int kFailBackoff       = 60;  // ~3 s after failed Register

    while (g_run) {
        if (GetAsyncKeyState(VK_END) & 1) {
            RL::Log::Info("END key - worker shutdown requested");
            break;
        }

        void* L = RL::Game::Addr::LuaState();
        if (L != lastL) {
            RL::Log::Warn("lua_State %p -> %p%s", lastL, L,
                          everRegistered ? " (need REBIND after /reload)" : "");
            lastL = L;
            registered = false;
            settle = 0;
            inWorldStreak = 0;
            failBackoff = 0;
            // /reload wiped _G — latch must clear so Register truly rebinds.
            RL::Bridge::ResetRegistrationState();
        }

        // Pure memory only — never call client functions from this worker.
        int flag = RL::Game::Addr::InWorldFlag(); // 1=in world, 0=not, -1=unreadable
        if (flag == 1)
            ++inWorldStreak;
        else
            inWorldStreak = 0;

        if (failBackoff > 0)
            --failBackoff;

        if (!secondary && L && !registered) {
            ++settle;
            const int needSettle = everRegistered ? kMinSettleRebind : kMinSettleFirst;
            const int needWorld  = everRegistered ? kInWorldStreakRebind : kInWorldStreakFirst;
            // STRICT: flag must be 1 for needWorld consecutive ticks.
            // Never register on glue / load screen (flag!=1).
            const bool worldReady = (flag == 1) && (inWorldStreak >= needWorld);
            if (settle >= needSettle && worldReady && failBackoff == 0) {
                if (RL::Bridge::Register()) {
                    registered = true;
                    everRegistered = true;
                    RL::Log::Warn("BRIDGE ONLINE ver=%s L=%p flag=%d settle=%d inWorldStreak=%d rebind=%d",
                                  RL::Bridge::Version(), L, flag, settle, inWorldStreak,
                                  everRegistered && settle <= kMinSettleRebind + 5 ? 1 : 0);
                } else {
                    RL::Log::Warn("Register failed - backoff %d ticks (flag=%d)",
                                  kFailBackoff, flag);
                    failBackoff = kFailBackoff;
                    inWorldStreak = 0;
                }
            }
        }

        ++tick;
        // Heartbeat every ~2.5s so a stuck rebind is obvious in the inject tail.
        if ((tick % 50) == 0) {
            RL::Log::Info("heartbeat reg=%d ever=%d sec=%d flag=%d settle=%d inWorld=%d L=%p",
                          (int)registered, (int)everRegistered, (int)secondary, flag, settle,
                          inWorldStreak, L);
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
