#include "Log.h"
#include <Windows.h>
#include <cstdio>
#include <mutex>
#include <cstring>

namespace RL::Log {
namespace {
std::mutex g_mu;
FILE* g_file = nullptr;
Level g_level = Level::Warn;
bool g_console = false;
bool g_dbgout = false;
bool g_status_mirror = false;
char g_path[MAX_PATH] = {};

// Level chars for structured format: TDIWE
static const char kLevelTags[] = "TDIWE";
// 3-char tags for legacy format
static const char* kTags3[] = { "TRC", "DBG", "INF", "WRN", "ERR" };

void EmitLine(const char* line, int len, Level level) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_console) { fputs(line, stdout); fflush(stdout); }
    if (g_file)    { fputs(line, g_file); fflush(g_file); }
    if (g_dbgout)  { OutputDebugStringA(line); }

    if (g_status_mirror && static_cast<int>(level) >= static_cast<int>(Level::Warn)) {
        HANDLE h = CreateFileA("C:\\Ascension\\Workspace\\logs\\runtime_status.txt",
                               FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wr = 0;
            WriteFile(h, line, len, &wr, nullptr);
            CloseHandle(h);
        }
    }
}
} // anon namespace

void Init(const char* logPath) {
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_file) return;

        char env[16]{};
        if (GetEnvironmentVariableA("RL_LOG", env, sizeof(env)) > 0 && env[0] == '1') {
            g_level = Level::Trace;
            g_dbgout = true;
            g_status_mirror = true;
        }
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
                SetConsoleTitleA("Host Diagnostic");
            }
        }
    }
    Structured(Level::Info, "", 0, "sys.init",
               "path=%s level=%d console=%d dbgout=%d",
               logPath ? logPath : "(none)", (int)g_level, (int)g_console, (int)g_dbgout);
}

void Shutdown() {
    // One final session-separator in legacy format for grep friendliness
    Write(Level::Info, "log shutdown");
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_file) { fclose(g_file); g_file = nullptr; }
}

void SetLevel(Level level) { g_level = level; }
Level GetLevel() { return g_level; }

// ---- Structured write ----------------------------------------------------
void Structured(Level level, const char* file, int line,
                const char* cat_sub, const char* fmt, ...) {
    if (static_cast<int>(level) < static_cast<int>(g_level)) return;

    char body[1920];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    SYSTEMTIME st{};
    GetLocalTime(&st);
    char tag = kLevelTags[static_cast<int>(level)];

    const char* fname = file;
    if (fname && fname[0]) {
        const char* s = strrchr(fname, '\\');
        if (!s) s = strrchr(fname, '/');
        if (s) fname = s + 1;
    } else { fname = "?"; }

    // HH:MM:SS.mmm|L|cat.sub|src:line|body
    char buf[2400];
    int n = snprintf(buf, sizeof(buf), "%02u:%02u:%02u.%03u|%c|%s|%s:%d|%s\n",
                     st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                     tag, cat_sub ? cat_sub : "?",
                     fname, line, body);
    (void)n;
    EmitLine(buf, (int)strlen(buf), level);
}

// ---- Legacy free-form write -----------------------------------------------
void Write(Level level, const char* fmt, ...) {
    if (static_cast<int>(level) < static_cast<int>(g_level)) return;

    char body[1920];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    SYSTEMTIME st{};
    GetLocalTime(&st);

    char line[2400];
    int len = snprintf(line, sizeof(line), "%02u:%02u:%02u.%03u %s %s\n",
                       st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                       kTags3[static_cast<int>(level)], body);
    (void)len;
    EmitLine(line, (int)strlen(line), level);
}
} // namespace RL::Log
