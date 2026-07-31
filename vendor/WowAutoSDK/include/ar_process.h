/**
 * ar_process.h - Process utilities for Ascension Launcher
 *
 * Process discovery, privilege escalation, module queries, architecture checks.
 * Header-only — include once from the main translation unit.
 */

#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <cstdio>
#include <cstring>

namespace ar {

// ============================================================
// Console colours
// ============================================================
enum Color : int {
    CLR_DEFAULT = 0x07,
    CLR_WHITE   = 0x0F,
    CLR_CYAN    = 0x0B,
    CLR_GREEN   = 0x0A,
    CLR_YELLOW  = 0x0E,
    CLR_RED     = 0x0C,
};

inline void SetClr(int c) { SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), (WORD)c); }

inline void Ok  (const char* m) { SetClr(CLR_GREEN);  printf("[+] "); SetClr(CLR_DEFAULT); printf("%s\n", m); }
inline void Info(const char* m) { SetClr(CLR_CYAN);   printf("[*] "); SetClr(CLR_DEFAULT); printf("%s\n", m); }
inline void Warn(const char* m) { SetClr(CLR_YELLOW); printf("[!] "); SetClr(CLR_DEFAULT); printf("%s\n", m); }
inline void Err (const char* m) { SetClr(CLR_RED);    printf("[X] "); SetClr(CLR_DEFAULT); printf("%s\n", m); }

inline void Step(int cur, int total, const char* m) {
    SetClr(CLR_CYAN); printf("[%d/%d] ", cur, total); SetClr(CLR_WHITE); printf("%s\n", m); SetClr(CLR_DEFAULT);
}

// ============================================================
// Privilege escalation
// ============================================================

inline bool EnableDebugPrivilege() {
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

// ============================================================
// Process discovery
// ============================================================

inline DWORD FindProcessByName(const char* name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe = {}; pe.dwSize = sizeof(pe);
    DWORD pid = 0;
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, name) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

inline DWORD WaitForProcess(const char* name, int timeoutMs = 120000) {
    DWORD pid = 0;
    int elapsed = 0;
    while (pid == 0 && elapsed < timeoutMs) {
        pid = FindProcessByName(name);
        if (!pid) { Sleep(250); elapsed += 250; }
    }
    return pid;
}

inline bool IsProcessAlive(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return false;
    DWORD code; GetExitCodeProcess(h, &code);
    CloseHandle(h);
    return code == STILL_ACTIVE;
}

inline bool IsProcess32Bit(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return true;
    BOOL wow64 = FALSE;
    IsWow64Process(h, &wow64);
    CloseHandle(h);
    return wow64 != FALSE;
}

// ============================================================
// Module queries
// ============================================================

inline bool IsModuleLoaded(DWORD pid, const char* moduleName) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return false;
    MODULEENTRY32 me = {}; me.dwSize = sizeof(me);
    bool found = false;
    if (Module32First(snap, &me)) {
        do {
            if (_stricmp(me.szModule, moduleName) == 0) { found = true; break; }
        } while (Module32Next(snap, &me));
    }
    CloseHandle(snap);
    return found;
}

inline uintptr_t GetRemoteModuleBase(DWORD pid, const char* moduleName) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32 me = {}; me.dwSize = sizeof(me);
    uintptr_t base = 0;
    if (Module32First(snap, &me)) {
        do {
            if (_stricmp(me.szModule, moduleName) == 0) { base = (uintptr_t)me.modBaseAddr; break; }
        } while (Module32Next(snap, &me));
    }
    CloseHandle(snap);
    return base;
}

// Get all thread IDs for a process
inline int GetProcessThreads(DWORD pid, DWORD* outTids, int maxTids) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    THREADENTRY32 te = {}; te.dwSize = sizeof(te);
    int count = 0;
    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID == pid && count < maxTids) {
                outTids[count++] = te.th32ThreadID;
            }
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return count;
}

// ============================================================
// Wait for game to be "ready" (main window + base modules)
// ============================================================

inline bool WaitForGameReady(DWORD pid, int timeoutMs = 30000) {
    int elapsed = 0;
    while (elapsed < timeoutMs) {
        // Check kernel32 is loaded (should always be true)
        if (IsModuleLoaded(pid, "kernel32.dll")) {
            // Check for the game's main D3D module as a readiness signal
            if (IsModuleLoaded(pid, "d3d9.dll") || IsModuleLoaded(pid, "opengl32.dll") ||
                IsModuleLoaded(pid, "d3d11.dll") || IsModuleLoaded(pid, "dxgi.dll")) {
                return true;
            }
        }
        Sleep(250);
        elapsed += 250;
    }
    // Even if no D3D detected, kernel32 is enough to inject
    return IsModuleLoaded(pid, "kernel32.dll");
}

} // namespace ar
