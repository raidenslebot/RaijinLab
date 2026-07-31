/**
 * Ascension Lua Unlocker - DLL Injector
 * Injects lua_unlocker.dll into Ascension.exe
 *
 * Compile (MSVC x86):
 *   cl /O2 /GS- injector.cpp user32.lib kernel32.lib advapi32.lib /Fe:injector.exe
 *
 * Compile (MinGW 32-bit):
 *   i686-w64-mingw32-g++ -O2 -s -o injector.exe injector.cpp -luser32 -lkernel32 -ladvapi32
 *
 * Usage:
 *   injector.exe                  -- auto-find Ascension.exe and inject
 *   injector.exe --pid 1234       -- inject into specific PID
 *   injector.exe --dll path.dll   -- use specific DLL path
 *   injector.exe --wait           -- wait for Ascension.exe to start
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

static DWORD FindProcessByName(const char* name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;

    PROCESSENTRY32 pe = {};
    pe.dwSize = sizeof(pe);

    DWORD pid = 0;
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, name) == 0) {
                pid = pe.th32ProcessID;
                break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static bool EnableDebugPrivilege() {
    HANDLE hToken;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &hToken))
        return false;

    TOKEN_PRIVILEGES tp = {};
    LookupPrivilegeValueA(nullptr, "SeDebugPrivilege", &tp.Privileges[0].Luid);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(hToken, FALSE, &tp, sizeof(tp), nullptr, nullptr);

    bool ok = (GetLastError() == ERROR_SUCCESS);
    CloseHandle(hToken);
    return ok;
}

static bool InjectDLL(DWORD pid, const char* dllPath) {
    printf("[*] Opening process %lu...\n", pid);
    HANDLE hProc = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!hProc) {
        printf("[!] OpenProcess failed: %lu\n", GetLastError());
        return false;
    }

    // Allocate memory in target process for the DLL path
    size_t pathLen = strlen(dllPath) + 1;
    void* remoteMem = VirtualAllocEx(hProc, nullptr, pathLen, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remoteMem) {
        printf("[!] VirtualAllocEx failed: %lu\n", GetLastError());
        CloseHandle(hProc);
        return false;
    }

    // Write the DLL path into the target process
    if (!WriteProcessMemory(hProc, remoteMem, dllPath, pathLen, nullptr)) {
        printf("[!] WriteProcessMemory failed: %lu\n", GetLastError());
        VirtualFreeEx(hProc, remoteMem, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return false;
    }

    // Get LoadLibraryA address (it's the same in every process on the same OS)
    HMODULE hKernel32 = GetModuleHandleA("kernel32.dll");
    FARPROC pLoadLib = GetProcAddress(hKernel32, "LoadLibraryA");
    if (!pLoadLib) {
        printf("[!] Cannot find LoadLibraryA\n");
        VirtualFreeEx(hProc, remoteMem, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return false;
    }

    // Create remote thread calling LoadLibraryA(dllPath)
    printf("[*] Creating remote thread...\n");
    HANDLE hThread = CreateRemoteThread(hProc, nullptr, 0,
        (LPTHREAD_START_ROUTINE)pLoadLib, remoteMem, 0, nullptr);
    if (!hThread) {
        printf("[!] CreateRemoteThread failed: %lu\n", GetLastError());
        VirtualFreeEx(hProc, remoteMem, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return false;
    }

    // Wait for LoadLibraryA to complete
    WaitForSingleObject(hThread, 10000);

    DWORD exitCode = 0;
    GetExitCodeThread(hThread, &exitCode);

    CloseHandle(hThread);
    VirtualFreeEx(hProc, remoteMem, 0, MEM_RELEASE);
    CloseHandle(hProc);

    if (exitCode == 0) {
        printf("[!] LoadLibraryA returned NULL - injection failed\n");
        return false;
    }

    printf("[+] DLL injected at remote base: 0x%08lX\n", exitCode);
    return true;
}

int main(int argc, char* argv[]) {
    printf("=== Ascension Lua Unlocker Injector ===\n\n");

    const char* processName = "Ascension.exe";
    const char* dllName     = "lua_unlocker.dll";
    char dllFullPath[MAX_PATH] = {};
    DWORD targetPid = 0;
    bool waitMode   = false;

    // Parse args
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            targetPid = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--dll") == 0 && i + 1 < argc) {
            dllName = argv[++i];
        } else if (strcmp(argv[i], "--wait") == 0) {
            waitMode = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage:\n");
            printf("  injector.exe                 Auto-find and inject\n");
            printf("  injector.exe --pid <pid>     Inject into specific PID\n");
            printf("  injector.exe --dll <path>    Use specific DLL path\n");
            printf("  injector.exe --wait          Wait for process to start\n");
            return 0;
        }
    }

    // Resolve full DLL path
    if (dllFullPath[0] == '\0') {
        // Get directory of this exe
        GetModuleFileNameA(nullptr, dllFullPath, MAX_PATH);
        char* lastSlash = strrchr(dllFullPath, '\\');
        if (lastSlash) *(lastSlash + 1) = '\0';
        strcat(dllFullPath, dllName);
    }

    // Check DLL exists
    if (GetFileAttributesA(dllFullPath) == INVALID_FILE_ATTRIBUTES) {
        // Try next to the exe
        printf("[!] DLL not found at: %s\n", dllFullPath);
        printf("[!] Ensure %s is in the same directory as injector.exe\n", dllName);
        return 1;
    }

    printf("[*] DLL path: %s\n", dllFullPath);

    // Enable debug privilege for protected processes
    if (EnableDebugPrivilege()) {
        printf("[+] Debug privilege enabled\n");
    }

    // Find or wait for the process
    if (targetPid == 0) {
        targetPid = FindProcessByName(processName);

        if (targetPid == 0 && waitMode) {
            printf("[*] Waiting for %s to start...\n", processName);
            while (targetPid == 0) {
                Sleep(500);
                targetPid = FindProcessByName(processName);
            }
            printf("[+] Process found!\n");
            // Small delay to let it initialize
            Sleep(2000);
        }

        if (targetPid == 0) {
            printf("[!] %s not found. Use --wait to wait for it.\n", processName);
            return 1;
        }
    }

    printf("[*] Target PID: %lu\n", targetPid);

    // Inject
    if (InjectDLL(targetPid, dllFullPath)) {
        printf("\n[+] SUCCESS - Lua Unlocker injected!\n");
        printf("[+] Check lua_unlocker.log for status.\n");
        return 0;
    } else {
        printf("\n[!] FAILED - Injection unsuccessful.\n");
        return 1;
    }
}
