#include "Log.h"
#include <Windows.h>
#include <cstdio>
#include <mutex>
#include <cstring>

namespace RL::Log {
namespace {
std::mutex g_mu;
FILE* g_file = nullptr;
Level g_level = Level::Warn; // quiet default (stealth)
bool g_console = false;      // never AllocConsole unless RL_CONSOLE=1
bool g_dbgout = false;
bool g_status_mirror = false;
char g_path[MAX_PATH] = {};
}

void Init(const char* logPath) {
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_file) return;

        char env[16]{};
        // RL_LOG=1 → full verbose file log (inject.bat sets this)
        if (GetEnvironmentVariableA("RL_LOG", env, sizeof(env)) > 0 && env[0] == '1') {
            g_level = Level::Trace;
            g_dbgout = true;
            g_status_mirror = true;
        }
        // RL_CONSOLE=1 → AllocConsole inside game (optional; inject window is preferred)
        char con[8]{};
        if (GetEnvironmentVariableA("RL_CONSOLE", con, sizeof(con)) > 0 && con[0] == '1') {
            g_console = true;
        }

        if (logPath && logPath[0]) {
            CreateDirectoryA("C:\\Ascension\\Workspace\\logs", nullptr);
            strncpy_s(g_path, logPath, _TRUNCATE);
            g_file = _fsopen(logPath, "a+", _SH_DENYNO);
        }

        if (g_console && !GetConsoleWindow()) {
            if (AllocConsole()) {
                FILE* dummy = nullptr;
                freopen_s(&dummy, "CONOUT$", "w", stdout);
                // Neutral title — avoid branded strings AC title scanners care about
                SetConsoleTitleA("Host Diagnostic");
            }
        }
    }
    Write(Level::Info, "log init path=%s level=%d console=%d",
          logPath ? logPath : "(none)", (int)g_level, (int)g_console);
}

void Shutdown() {
    Write(Level::Info, "log shutdown");
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_file) { fclose(g_file); g_file = nullptr; }
}

void SetLevel(Level level) { g_level = level; }

void Write(Level level, const char* fmt, ...) {
    if (static_cast<int>(level) < static_cast<int>(g_level)) return;
    char msg[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    SYSTEMTIME st{};
    GetLocalTime(&st);
    const char* tag = "?";
    switch (level) {
    case Level::Trace: tag = "TRC"; break;
    case Level::Debug: tag = "DBG"; break;
    case Level::Info:  tag = "INF"; break;
    case Level::Warn:  tag = "WRN"; break;
    case Level::Error: tag = "ERR"; break;
    }
    char line[2400];
    snprintf(line, sizeof(line), "%02u:%02u:%02u.%03u %s %s\n",
             st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, tag, msg);

    std::lock_guard<std::mutex> lock(g_mu);
    if (g_console) {
        fputs(line, stdout);
        fflush(stdout);
    }
    if (g_file) {
        fputs(line, g_file);
        fflush(g_file);
    }
    if (g_dbgout) OutputDebugStringA(line);

    // Status mirror: only Warn/Error get spilled to the tiny runtime_status.txt
    // marker file. Previously every Info (bridge trace, OM heartbeat) opened
    // and closed the file under g_mu — 40+ syscalls per frame under RL_LOG=1
    // stalled the main thread badly enough to trigger downstream watchdogs.
    // Warn/Error are rare and worth mirroring; Info goes to the main log
    // only.
    if (g_status_mirror && static_cast<int>(level) >= static_cast<int>(Level::Warn)) {
        HANDLE h = CreateFileA("C:\\Ascension\\Workspace\\logs\\runtime_status.txt",
                               FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wr = 0;
            WriteFile(h, line, (DWORD)strlen(line), &wr, nullptr);
            CloseHandle(h);
        }
    }
}
} // namespace RL::Log
