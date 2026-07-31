#include "Console.h"
#include <Windows.h>
#include <cstdio>
#include <cstdarg>
#include <iostream>

namespace Console {
namespace {
FILE* g_out = nullptr;
bool g_owned = false;
}

void Init() {
    if (g_out)
        return;
    if (AllocConsole()) {
        g_owned = true;
        freopen_s(&g_out, "CONOUT$", "w", stdout);
        SetConsoleTitleA("RaijinLab Runtime");
    } else {
        // already has console
        g_out = stdout;
    }
    std::cout << "[RaijinLab] console ready\n";
}

void Shutdown() {
    if (g_owned) {
        if (g_out && g_out != stdout)
            fclose(g_out);
        FreeConsole();
        g_owned = false;
    }
    g_out = nullptr;
}

void Log(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_out)
        fprintf(g_out, "%s\n", buf);
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
}
} // namespace Console
