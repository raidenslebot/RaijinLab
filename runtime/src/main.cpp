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

    // Registration state machine:
    //   Initial settle: 8 ticks (~400 ms) after seeing a new non-null lua_State
    //     before first Register - enough for the Lua VM to be fully constructed.
    //
    // NOTE (L1 exception, documented): The initial Register call happens from
    // this worker thread. It is the ONE unavoidable off-main-thread call into
    // FrameScript_RegisterFunction - without it, IsLinuxClient is never bound
    // to _G and Lua can never dispatch to us so the self-heal path can never
    // execute. Periodic re-register was previously also done here every 3 s;
    // it is REMOVED because those repeat pushcclosure allocations were racing
    // with main-thread Lua GC. Rely on Lua_IsLinuxClient's own
    // EnsureMainThreadRegister to re-bind if the global is ever stripped.
    bool registered = false;
    void* lastL = nullptr;
    int settle = 0;                     // ticks since this lua_State went stable
    int tick = 0;
    // Register once the lua_State has been UNCHANGED for kMinSettle AND the
    // world is loaded. "World loaded" is read PURELY from the g_InWorld flag
    // (a plain memory read) - the worker must NEVER call a client function like
    // ClntObjMgrGetActivePlayer, which can BLOCK the worker for seconds when
    // called cross-thread during a world load (that hang stalled registration
    // entirely in 1.7.4-1.7.6). If the flag address is wrong on this build it
    // reads !=1 forever, so a hard-timeout fallback registers anyway once the
    // state has been stable long enough that the load has certainly finished.
    constexpr int kMinSettle    = 30;   // ~1.5 s of stable state before we consider registering
    constexpr int kHardTimeout  = 120;  // ~6 s stable -> register even if the flag never trips

    while (g_run) {
        if (GetAsyncKeyState(VK_END) & 1) {
            RL::Log::Info("END key - worker shutdown requested");
            break;
        }

        void* L = RL::Game::Addr::LuaState();
        if (L != lastL) {
            RL::Log::Warn("lua_State %p -> %p", lastL, L);
            lastL = L;
            registered = false;
            settle = 0;
            // A new lua_State means /reload wiped _G - the runtime's own
            // "already registered" latch is now stale, so the next Register()
            // would early-return success without actually re-binding
            // IsLinuxClient into the new _G. Clear the latch so the next
            // Register() truly re-binds.
            RL::Bridge::ResetRegistrationState();
        }

        // One-shot bootstrap register only. Do NOT re-register periodically:
        // that was a prior racecondition - two threads doing pushcclosure
        // concurrently corrupted the Lua GC freelist.
        //
        // Register() calls FrameScript_RegisterFunction, which mutates the Lua
        // globals table + GC. Doing that during the char->world load (glue VM
        // torn down, in-world VM built) corrupts the half-built VM and the main
        // thread AVs (ERROR #132). So we wait until the state is settled AND the
        // world is loaded - using ONLY pure memory reads (never a client-function
        // call from this worker; that hangs during load).
        int flag = RL::Game::Addr::InWorldFlag();       // pure read: 1=in world, 0/-1 otherwise
        if (!secondary && L && !registered) {
            ++settle;
            bool worldReady = (flag == 1) || (settle >= kHardTimeout);
            if (settle >= kMinSettle && worldReady) {
                if (RL::Bridge::Register()) {
                    registered = true;
                    RL::Log::Warn("BRIDGE ONLINE ver=%s L=%p flag=%d settle=%d",
                                  RL::Bridge::Version(), L, flag, settle);
                } else {
                    RL::Log::Warn("Register failed - retry");
                    settle = kMinSettle / 2;
                }
            }
        }

        ++tick;
        // Frequent WRN heartbeat so a stalled registration is self-explanatory
        // (flag = in-world memory flag, settle = ticks on this stable state).
        if ((tick % 100) == 0) {   // ~5 s (was 2s WRN spam; still proves liveness)
            RL::Log::Info("heartbeat reg=%d sec=%d flag=%d settle=%d L=%p",
                          (int)registered, (int)secondary, flag, settle, L);
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
