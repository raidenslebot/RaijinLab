/**
 * Ascension Launcher v2.0 - Complete DLL Injection Suite
 *
 * Architecture:
 *   ar_process.h   - process discovery, privileges, module queries
 *   ar_payload.h   - DLL extraction/validation/lifecycle
 *   ar_injection.h - 4-method injection engine with auto-fallback
 *
 * Injection chain:
 *   1. Enable SeDebugPrivilege
 *   2. Locate/extract both DLL payloads (resources -> exe-adjacent -> bin dir)
 *   3. Find or wait for Ascension.exe
 *   4. Wait for game initialization (D3D loaded)
 *   5. Inject lua_unlocker.dll  (multi-method, verify, retry)
 *   6. Wait for patches to apply
 *   7. Inject rotation_engine.dll (multi-method, verify, retry)
 *   8. Post-injection verification pass
 *   9. Monitor game until exit, cleanup
 *
 * Compile (MSVC x86 - from VS x86 Native Tools prompt):
 *   rc /fo ascension_launcher.res ascension_launcher.rc
 *   cl /O2 /GS- /EHsc /I..\include ascension_launcher.cpp ascension_launcher.res ^
 *      user32.lib kernel32.lib advapi32.lib shell32.lib /Fe:..\bin\AscensionLauncher.exe
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>

#include "ar_process.h"
#include "ar_payload.h"
#include "ar_injection.h"

// ============================================================
// Banner
// ============================================================

static void PrintBanner() {
    ar::SetClr(ar::CLR_CYAN);
    printf("\n");
    printf("  ===================================================\n");
    printf("  |   ASCENSION ALL-IN-ONE LAUNCHER  v2.0           |\n");
    printf("  |   Multi-Method Injection Engine                 |\n");
    printf("  |   Lua Unlocker + Rotation Engine                |\n");
    printf("  ===================================================\n");
    printf("\n");
    ar::SetClr(ar::CLR_DEFAULT);
}

static void PrintSummaryBox(bool unlockerOk, bool engineOk,
                             const ar::InjectionReport& rptU,
                             const ar::InjectionReport& rptE) {
    printf("\n");
    ar::SetClr(ar::CLR_CYAN);
    printf("  +--------------------------------------------------+\n");
    printf("  |  INJECTION SUMMARY                               |\n");
    printf("  +--------------------------------------------------+\n");

    ar::SetClr(unlockerOk ? ar::CLR_GREEN : ar::CLR_RED);
    printf("  |  Lua Unlocker:     %-30s |\n",
        unlockerOk ? (rptU.methodName ? rptU.methodName : "OK") : (rptU.lastError ? rptU.lastError : "FAIL"));

    ar::SetClr(engineOk ? ar::CLR_GREEN : ar::CLR_RED);
    printf("  |  Rotation Engine:  %-30s |\n",
        engineOk ? (rptE.methodName ? rptE.methodName : "OK") : (rptE.lastError ? rptE.lastError : "FAIL"));

    ar::SetClr(ar::CLR_CYAN);
    printf("  +--------------------------------------------------+\n");
    printf("\n");
    ar::SetClr(ar::CLR_DEFAULT);
}

// ============================================================
// Main
// ============================================================

int main(int argc, char* argv[]) {
    SetConsoleTitleA("Ascension Launcher v2.0");
    PrintBanner();

    // ── Parse args ──
    bool     waitMode      = true;
    bool     noCleanup     = false;
    bool     skipUnlocker  = false;
    bool     skipEngine    = false;
    bool     aggressive    = false;
    DWORD    targetPid     = 0;
    const char* processName = "Ascension.exe";

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) targetPid = atoi(argv[++i]);
        else if (strcmp(argv[i], "--no-wait") == 0)        waitMode = false;
        else if (strcmp(argv[i], "--no-cleanup") == 0)     noCleanup = true;
        else if (strcmp(argv[i], "--skip-unlocker") == 0)  skipUnlocker = true;
        else if (strcmp(argv[i], "--skip-engine") == 0)    skipEngine = true;
        else if (strcmp(argv[i], "--aggressive") == 0)     aggressive = true;
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: AscensionLauncher.exe [options]\n\n");
            printf("  --pid <pid>        Inject into specific process ID\n");
            printf("  --no-wait          Don't wait for game to start\n");
            printf("  --no-cleanup       Don't delete temp DLLs on exit\n");
            printf("  --skip-unlocker    Skip lua_unlocker injection\n");
            printf("  --skip-engine      Skip rotation_engine injection\n");
            printf("  --aggressive       Max retries, all methods\n");
            printf("  -h, --help         Show this help\n\n");
            return 0;
        }
    }

    int maxRetries = aggressive ? 12 : 8; // 8 = 2 full cycles through 4 methods
    int totalSteps = 7;
    int step = 0;

    // ── Step 1: Privileges ──
    step++;
    ar::Step(step, totalSteps, "Enabling debug privileges...");
    if (ar::EnableDebugPrivilege()) {
        ar::Ok("SeDebugPrivilege enabled");
    } else {
        ar::Warn("Could not enable SeDebugPrivilege - try running as Administrator");
    }

    // ── Step 2: Prepare payloads ──
    step++;
    ar::Step(step, totalSteps, "Locating DLL payloads...");

    ar::PayloadInfo unlockerPayload = {};
    ar::PayloadInfo enginePayload   = {};

    if (!skipUnlocker) {
        unlockerPayload = ar::PreparePayload(IDR_LUA_UNLOCKER, "lua_unlocker.dll");
        if (!unlockerPayload.ready) {
            ar::Err("lua_unlocker.dll not available - cannot proceed");
            printf("\nPlace lua_unlocker.dll next to this exe, or rebuild with embedded resources.\n");
            printf("Press Enter to exit...\n");
            getchar();
            return 1;
        }
    }

    if (!skipEngine) {
        enginePayload = ar::PreparePayload(IDR_ROTATION_ENGINE, "rotation_engine.dll");
        if (!enginePayload.ready) {
            ar::Warn("rotation_engine.dll not available - engine features disabled");
        }
    }

    // ── Step 3: Find game process ──
    step++;
    ar::Step(step, totalSteps, "Looking for game process...");

    if (targetPid == 0) {
        targetPid = ar::FindProcessByName(processName);

        if (targetPid == 0) {
            if (waitMode) {
                ar::SetClr(ar::CLR_YELLOW);
                printf("    Waiting for %s to start (launch the game now)...", processName);
                ar::SetClr(ar::CLR_DEFAULT);

                int dots = 0;
                while (targetPid == 0) {
                    Sleep(500);
                    targetPid = ar::FindProcessByName(processName);
                    printf(".");
                    dots++;
                    if (dots % 60 == 0) printf("\n    ");
                }
                printf("\n");
                ar::Ok("Game process detected!");
            } else {
                ar::Err("Game not found. Start the game first or use --no-wait.");
                return 1;
            }
        }
    }

    char pidMsg[128];
    sprintf_s(pidMsg, "Target: %s PID %lu", processName, targetPid);
    ar::Ok(pidMsg);

    if (!ar::IsProcess32Bit(targetPid)) {
        ar::Err("Target process is 64-bit - DLLs are 32-bit. Wrong process?");
        return 1;
    }

    // ── Step 4: Wait for game initialization ──
    step++;
    ar::Step(step, totalSteps, "Waiting for game initialization...");

    if (!ar::WaitForGameReady(targetPid, 30000)) {
        ar::Warn("Could not confirm game fully initialized - proceeding anyway");
    } else {
        ar::Ok("Game initialized (D3D module detected)");
    }

    ar::Info("Waiting 5s for Lua state initialization...");
    Sleep(5000);

    // ── Step 5: Inject lua_unlocker.dll ──
    step++;
    ar::Step(step, totalSteps, "Injecting Lua Unlocker...");

    ar::InjectionReport rptUnlocker = { false, 0, 0, "skipped", "skipped" };

    if (skipUnlocker) {
        ar::Info("Skipped (--skip-unlocker)");
        rptUnlocker.success = true;
    } else if (ar::IsModuleLoaded(targetPid, "lua_unlocker.dll")) {
        ar::Ok("lua_unlocker.dll already loaded - skipping");
        rptUnlocker.success = true;
        rptUnlocker.methodName = "already loaded";
    } else {
        ar::InjectionConfig cfg = {};
        cfg.pid           = targetPid;
        cfg.dllPath       = unlockerPayload.path;
        cfg.dllName       = "lua_unlocker.dll";
        cfg.label         = "Lua Unlocker";
        cfg.maxRetries    = maxRetries;
        cfg.verifyDelayMs = 2000;

        rptUnlocker = ar::InjectDLL(cfg);

        if (rptUnlocker.success) {
            ar::Info("Waiting 4s for unlocker initialization...");
            Sleep(4000);
        }
    }

    // ── Step 6: Inject rotation_engine.dll ──
    step++;
    ar::Step(step, totalSteps, "Injecting Rotation Engine...");

    ar::InjectionReport rptEngine = { false, 0, 0, "skipped", "skipped" };

    if (skipEngine || !enginePayload.ready) {
        ar::Info(skipEngine ? "Skipped (--skip-engine)" : "Skipped (DLL not available)");
    } else if (ar::IsModuleLoaded(targetPid, "rotation_engine.dll")) {
        ar::Ok("rotation_engine.dll already loaded - skipping");
        rptEngine.success = true;
        rptEngine.methodName = "already loaded";
    } else {
        if (!rptUnlocker.success) {
            ar::Warn("Unlocker not loaded - engine may fail to register Lua functions");
        }

        ar::InjectionConfig cfg = {};
        cfg.pid           = targetPid;
        cfg.dllPath       = enginePayload.path;
        cfg.dllName       = "rotation_engine.dll";
        cfg.label         = "Rotation Engine";
        cfg.maxRetries    = maxRetries;
        cfg.verifyDelayMs = 3000;

        rptEngine = ar::InjectDLL(cfg);
    }

    // ── Step 7: Post-injection verification ──
    step++;
    ar::Step(step, totalSteps, "Post-injection verification...");

    bool finalUnlocker = skipUnlocker || ar::IsModuleLoaded(targetPid, "lua_unlocker.dll");
    bool finalEngine   = skipEngine || !enginePayload.ready ||
                         ar::IsModuleLoaded(targetPid, "rotation_engine.dll");

    if (finalUnlocker && !rptUnlocker.success) {
        rptUnlocker.success = true;
        rptUnlocker.methodName = "late verification";
    }
    if (finalEngine && !rptEngine.success) {
        rptEngine.success = true;
        rptEngine.methodName = "late verification";
    }

    // Aggressive re-attempt if engine still missing
    if (!finalEngine && enginePayload.ready && !skipEngine) {
        ar::Warn("Engine not verified - attempting aggressive re-injection...");
        ar::InjectionConfig cfg = {};
        cfg.pid           = targetPid;
        cfg.dllPath       = enginePayload.path;
        cfg.dllName       = "rotation_engine.dll";
        cfg.label         = "Rotation Engine (retry)";
        cfg.maxRetries    = 4;
        cfg.verifyDelayMs = 5000;
        rptEngine = ar::InjectDLL(cfg);
    }

    PrintSummaryBox(rptUnlocker.success, rptEngine.success, rptUnlocker, rptEngine);

    if (rptUnlocker.success) {
        printf("  In-game commands:\n");
        ar::SetClr(ar::CLR_WHITE);
        printf("    /ar            - Show help\n");
        printf("    /ar toggle     - Enable/disable rotation\n");
        printf("    /ar gui        - Open configuration GUI\n");
        ar::SetClr(ar::CLR_DEFAULT);
        printf("\n");
    }

    // ── Monitor game ──
    printf("  Monitoring game process... (close this window or Ctrl+C to stop)\n\n");

    while (ar::IsProcessAlive(targetPid)) {
        Sleep(2000);
    }

    ar::Info("Game process exited.");

    if (!noCleanup) {
        ar::Info("Cleaning up temp files...");
        Sleep(500);
        ar::CleanupPayload(unlockerPayload);
        ar::CleanupPayload(enginePayload);
        ar::CleanupTempDir();
    }

    ar::SetClr(ar::CLR_GREEN);
    printf("\nDone. Goodbye!\n");
    ar::SetClr(ar::CLR_DEFAULT);

    return 0;
}
