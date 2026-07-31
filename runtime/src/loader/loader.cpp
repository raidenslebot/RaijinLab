// Silent injector — LoadLibrary path with random on-disk module name.
// Usage: loader.exe [--dll path] [--pid N] [--process Ascension.exe] [--wait] [--quiet]
//
// Random filename defeats exact-equality ModuleName bans (DivxTac DetectHackModules).
// Manual-map (no PEB) is a later step; this is the low-cost v1 stealth path.

#include <Windows.h>
#include <TlHelp32.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>
#include <vector>
#include <ctime>

static bool g_quiet = false;

// Always show critical lines; --quiet only suppresses verbose chatter.
static void say(const char* fmt, ...) {
    if (g_quiet) return;
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

static void say_always(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

static DWORD FindPid(const wchar_t* name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe{sizeof(pe)};
    DWORD pid = 0;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, name) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static bool EnableDebugPrivilege() {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
        return false;
    TOKEN_PRIVILEGES tp{};
    if (!LookupPrivilegeValueA(nullptr, "SeDebugPrivilege", &tp.Privileges[0].Luid)) {
        CloseHandle(tok);
        return false;
    }
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(tok, FALSE, &tp, sizeof(tp), nullptr, nullptr);
    bool ok = GetLastError() == ERROR_SUCCESS;
    CloseHandle(tok);
    return ok;
}

// Copy source DLL to %TEMP%\<random>.dll so Process.Modules sees a non-branded name.
static std::string StageRandomCopy(const char* srcPath) {
    char temp[MAX_PATH]{};
    GetTempPathA(MAX_PATH, temp);
    // Names resembling benign system-adjacent modules (exact-equality ban only)
    static const char* stems[] = {
        "msvcirt", "msvcp60", "atl71", "mfc71u", "winmmbase",
        "d3dx9_43", "xinput1_3", "DWrite", "dbghelp", "version",
    };
    srand((unsigned)(GetTickCount() ^ GetCurrentProcessId()));
    const char* stem = stems[rand() % (sizeof(stems) / sizeof(stems[0]))];
    char name[64];
    snprintf(name, sizeof(name), "%s_%04x.dll", stem, (unsigned)(rand() & 0xFFFF));
    std::string dest = std::string(temp) + name;
    if (!CopyFileA(srcPath, dest.c_str(), FALSE)) {
        say_always("[!] CopyFile failed err=%lu — using original path\n", GetLastError());
        return srcPath; // fall back to original path
    }
    // Best-effort hide from casual dir listing
    SetFileAttributesA(dest.c_str(), FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM);
    return dest;
}

static bool Inject(DWORD pid, const char* dllPath) {
    EnableDebugPrivilege();
    HANDLE proc = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
                                  PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ |
                                  PROCESS_QUERY_LIMITED_INFORMATION,
                              FALSE, pid);
    if (!proc) {
        say_always("[!] OpenProcess failed err=%lu (run as admin? process running?)\n", GetLastError());
        return false;
    }

    size_t len = std::strlen(dllPath) + 1;
    void* remote = VirtualAllocEx(proc, nullptr, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) {
        say_always("[!] VirtualAllocEx failed err=%lu\n", GetLastError());
        CloseHandle(proc);
        return false;
    }
    if (!WriteProcessMemory(proc, remote, dllPath, len, nullptr)) {
        say_always("[!] WriteProcessMemory failed err=%lu\n", GetLastError());
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        CloseHandle(proc);
        return false;
    }

    auto load = (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryA");
    HANDLE thr = CreateRemoteThread(proc, nullptr, 0, load, remote, 0, nullptr);
    if (!thr) {
        say_always("[!] CreateRemoteThread failed err=%lu\n", GetLastError());
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        CloseHandle(proc);
        return false;
    }
    WaitForSingleObject(thr, 15000);
    DWORD code = 0;
    GetExitCodeThread(thr, &code);
    CloseHandle(thr);
    VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
    CloseHandle(proc);

    if (!code) {
        say_always("[!] LoadLibrary returned NULL — wrong arch or blocked\n");
        return false;
    }
    say_always("[+] inject OK (module base 0x%lX)\n", code);
    return true;
}

int main(int argc, char** argv) {
    std::string dll;
    std::wstring procName = L"Ascension.exe";
    DWORD pid = 0;
    bool wait = false;
    bool noStage = false;

    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--help")) {
            std::printf("loader [--dll path] [--pid n] [--process name] [--wait] [--quiet] [--no-stage]\n");
            return 0;
        }
        if (!std::strcmp(argv[i], "--wait")) { wait = true; continue; }
        if (!std::strcmp(argv[i], "--quiet") || !std::strcmp(argv[i], "-q")) { g_quiet = true; continue; }
        if (!std::strcmp(argv[i], "--no-stage")) { noStage = true; continue; }
        if (!std::strcmp(argv[i], "--dll") && i + 1 < argc) { dll = argv[++i]; continue; }
        if (!std::strcmp(argv[i], "--process") && i + 1 < argc) {
            std::string n = argv[++i];
            procName.assign(n.begin(), n.end());
            continue;
        }
        if (!std::strcmp(argv[i], "--pid") && i + 1 < argc) { pid = (DWORD)atoi(argv[++i]); continue; }
        if (dll.empty()) dll = argv[i];
    }

    if (dll.empty()) {
        char path[MAX_PATH]{};
        GetModuleFileNameA(nullptr, path, MAX_PATH);
        char* slash = strrchr(path, '\\');
        if (slash) *(slash + 1) = 0;
        // Prefer build output then dist
        std::string a = std::string(path) + "RaijinLabRuntime.dll";
        std::string b = "C:\\Ascension\\Workspace\\RaijinLab\\runtime\\build_x86\\RaijinLabRuntime.dll";
        if (GetFileAttributesA(b.c_str()) != INVALID_FILE_ATTRIBUTES) dll = b;
        else dll = a;
    }

    char full[MAX_PATH]{};
    GetFullPathNameA(dll.c_str(), MAX_PATH, full, nullptr);
    if (GetFileAttributesA(full) == INVALID_FILE_ATTRIBUTES) {
        say_always("[!] DLL missing: %s\n", full);
        return 1;
    }

    std::string staged = noStage ? full : StageRandomCopy(full);
    say_always("[*] source  %s\n", full);
    say_always("[*] staged  %s\n", staged.c_str());
    say_always("[*] stealth  random stage name + runtime PEB unlink + PE wipe\n");

    if (!pid) {
        do {
            pid = FindPid(procName.c_str());
            if (!pid && wait) {
                say("[*] waiting for process...\n");
                Sleep(1000);
            }
        } while (!pid && wait);
    }
    if (!pid) {
        say_always("[!] Ascension.exe not found — start the client and enter the world first\n");
        return 1;
    }
    say_always("[*] pid %lu\n", pid);
    bool ok = Inject(pid, staged.c_str());
    if (ok) {
        say_always("[+] done — watch inject window for live runtime.log tail\n");
        say_always("[+] log: C:\\Ascension\\Workspace\\logs\\runtime.log\n");
    }
    return ok ? 0 : 2;
}
