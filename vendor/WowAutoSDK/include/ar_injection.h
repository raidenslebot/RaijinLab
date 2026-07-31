/**
 * ar_injection.h - Multi-method DLL injection engine
 *
 * Four injection strategies with automatic fallback chain:
 *   1. CreateRemoteThread + LoadLibraryA  (standard)
 *   2. NtCreateThreadEx   + LoadLibraryA  (bypasses CRT hooks)
 *   3. QueueUserAPC to all threads        (alertable-wait based)
 *   4. Thread hijack via SetThreadContext  (most aggressive)
 *
 * Post-injection verification with retry across methods.
 * Header-only — include once from the main translation unit.
 */

#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

// Requires ar_process.h for helpers
#include "ar_process.h"

namespace ar {

// ============================================================
// NT internals (dynamically resolved)
// ============================================================

typedef LONG NTSTATUS;
#define NT_SUCCESS(s) ((s) >= 0)

typedef NTSTATUS (NTAPI *NtCreateThreadEx_t)(
    PHANDLE ThreadHandle, ACCESS_MASK DesiredAccess,
    PVOID ObjectAttributes, HANDLE ProcessHandle,
    PVOID StartRoutine, PVOID Argument,
    ULONG CreateFlags, SIZE_T ZeroBits,
    SIZE_T StackSize, SIZE_T MaxStackSize,
    PVOID AttributeList);

static NtCreateThreadEx_t pNtCreateThreadEx = nullptr;

static void ResolveNtApis() {
    if (pNtCreateThreadEx) return;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    if (ntdll) {
        pNtCreateThreadEx = (NtCreateThreadEx_t)GetProcAddress(ntdll, "NtCreateThreadEx");
    }
}

// ============================================================
// Shared: write DLL path into remote process
// ============================================================

struct RemotePath {
    HANDLE hProc;
    void*  remoteMem;
    bool   valid;
};

static RemotePath AllocRemotePath(DWORD pid, const char* dllPath) {
    RemotePath rp = { nullptr, nullptr, false };

    rp.hProc = OpenProcess(
        PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
        PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
        FALSE, pid);
    if (!rp.hProc) return rp;

    size_t pathLen = strlen(dllPath) + 1;
    rp.remoteMem = VirtualAllocEx(rp.hProc, nullptr, pathLen,
                                   MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!rp.remoteMem) { CloseHandle(rp.hProc); rp.hProc = nullptr; return rp; }

    if (!WriteProcessMemory(rp.hProc, rp.remoteMem, dllPath, pathLen, nullptr)) {
        VirtualFreeEx(rp.hProc, rp.remoteMem, 0, MEM_RELEASE);
        CloseHandle(rp.hProc); rp.hProc = nullptr; rp.remoteMem = nullptr;
        return rp;
    }

    rp.valid = true;
    return rp;
}

static void FreeRemotePath(RemotePath& rp) {
    if (rp.remoteMem && rp.hProc) VirtualFreeEx(rp.hProc, rp.remoteMem, 0, MEM_RELEASE);
    if (rp.hProc) CloseHandle(rp.hProc);
    rp = { nullptr, nullptr, false };
}

static FARPROC GetLoadLibraryAddr() {
    return GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA");
}

// ============================================================
// METHOD 1: CreateRemoteThread + LoadLibraryA
// ============================================================

enum InjectResult {
    INJ_OK            = 0,
    INJ_OPEN_FAIL     = 1,
    INJ_ALLOC_FAIL    = 2,
    INJ_WRITE_FAIL    = 3,
    INJ_THREAD_FAIL   = 4,
    INJ_LOAD_FAIL     = 5,  // LoadLibrary returned NULL
    INJ_TIMEOUT       = 6,
    INJ_UNKNOWN       = 7,
};

static const char* InjectResultStr(InjectResult r) {
    switch (r) {
        case INJ_OK:          return "success";
        case INJ_OPEN_FAIL:   return "OpenProcess failed";
        case INJ_ALLOC_FAIL:  return "VirtualAllocEx failed";
        case INJ_WRITE_FAIL:  return "WriteProcessMemory failed";
        case INJ_THREAD_FAIL: return "thread creation failed";
        case INJ_LOAD_FAIL:   return "LoadLibraryA returned NULL (DLL init failed)";
        case INJ_TIMEOUT:     return "thread timed out";
        default:              return "unknown error";
    }
}

static InjectResult Method_CreateRemoteThread(DWORD pid, const char* dllPath) {
    RemotePath rp = AllocRemotePath(pid, dllPath);
    if (!rp.valid) return rp.hProc ? INJ_ALLOC_FAIL : INJ_OPEN_FAIL;

    FARPROC pLoadLib = GetLoadLibraryAddr();
    HANDLE hThread = CreateRemoteThread(rp.hProc, nullptr, 0,
        (LPTHREAD_START_ROUTINE)pLoadLib, rp.remoteMem, 0, nullptr);

    if (!hThread) {
        InjectResult r = INJ_THREAD_FAIL;
        FreeRemotePath(rp);
        return r;
    }

    DWORD wait = WaitForSingleObject(hThread, 15000);
    if (wait == WAIT_TIMEOUT) {
        TerminateThread(hThread, 0);
        CloseHandle(hThread);
        FreeRemotePath(rp);
        return INJ_TIMEOUT;
    }

    DWORD exitCode = 0;
    GetExitCodeThread(hThread, &exitCode);
    CloseHandle(hThread);
    FreeRemotePath(rp);

    return (exitCode != 0) ? INJ_OK : INJ_LOAD_FAIL;
}

// ============================================================
// METHOD 2: NtCreateThreadEx + LoadLibraryA
// ============================================================

static InjectResult Method_NtCreateThreadEx(DWORD pid, const char* dllPath) {
    ResolveNtApis();
    if (!pNtCreateThreadEx) return INJ_THREAD_FAIL;

    RemotePath rp = AllocRemotePath(pid, dllPath);
    if (!rp.valid) return rp.hProc ? INJ_ALLOC_FAIL : INJ_OPEN_FAIL;

    FARPROC pLoadLib = GetLoadLibraryAddr();
    HANDLE hThread = nullptr;
    NTSTATUS status = pNtCreateThreadEx(
        &hThread, THREAD_ALL_ACCESS, nullptr, rp.hProc,
        (PVOID)pLoadLib, rp.remoteMem,
        0, 0, 0, 0, nullptr);

    if (!NT_SUCCESS(status) || !hThread) {
        FreeRemotePath(rp);
        return INJ_THREAD_FAIL;
    }

    DWORD wait = WaitForSingleObject(hThread, 15000);
    if (wait == WAIT_TIMEOUT) {
        TerminateThread(hThread, 0);
        CloseHandle(hThread);
        FreeRemotePath(rp);
        return INJ_TIMEOUT;
    }

    DWORD exitCode = 0;
    GetExitCodeThread(hThread, &exitCode);
    CloseHandle(hThread);
    FreeRemotePath(rp);

    return (exitCode != 0) ? INJ_OK : INJ_LOAD_FAIL;
}

// ============================================================
// METHOD 3: QueueUserAPC to all threads
// ============================================================

static InjectResult Method_QueueUserAPC(DWORD pid, const char* dllPath) {
    RemotePath rp = AllocRemotePath(pid, dllPath);
    if (!rp.valid) return rp.hProc ? INJ_ALLOC_FAIL : INJ_OPEN_FAIL;

    FARPROC pLoadLib = GetLoadLibraryAddr();

    DWORD tids[256];
    int threadCount = GetProcessThreads(pid, tids, 256);
    if (threadCount == 0) {
        FreeRemotePath(rp);
        return INJ_THREAD_FAIL;
    }

    int queued = 0;
    for (int i = 0; i < threadCount; i++) {
        HANDLE hThread = OpenThread(THREAD_SET_CONTEXT | THREAD_SUSPEND_RESUME, FALSE, tids[i]);
        if (hThread) {
            if (QueueUserAPC((PAPCFUNC)pLoadLib, hThread, (ULONG_PTR)rp.remoteMem)) {
                queued++;
            }
            CloseHandle(hThread);
        }
    }

    // Don't free remoteMem yet — APC executes asynchronously when a thread enters alertable wait.
    // We'll let it leak (tiny) since the target process owns it.
    CloseHandle(rp.hProc);
    rp.hProc = nullptr;

    if (queued == 0) return INJ_THREAD_FAIL;

    // Give APCs time to fire
    Sleep(3000);
    return INJ_OK; // We can't check exit code; verify module load separately
}

// ============================================================
// METHOD 4: Thread hijack via SetThreadContext
// ============================================================

#pragma pack(push, 1)
struct ShellcodePayload {
    uint8_t  pushfd;             // 9C
    uint8_t  pushad;             // 60
    uint8_t  push_arg;           // 68
    uint32_t arg_addr;           // <remote path address>
    uint8_t  mov_eax;            // B8
    uint32_t func_addr;          // <LoadLibraryA address>
    uint8_t  call_eax[2];        // FF D0
    uint8_t  popad;              // 61
    uint8_t  popfd;              // 9D
    uint8_t  push_ret;           // 68
    uint32_t original_eip;       // <original EIP to resume>
    uint8_t  ret;                // C3
};
#pragma pack(pop)

static InjectResult Method_ThreadHijack(DWORD pid, const char* dllPath) {
    RemotePath rp = AllocRemotePath(pid, dllPath);
    if (!rp.valid) return rp.hProc ? INJ_ALLOC_FAIL : INJ_OPEN_FAIL;

    FARPROC pLoadLib = GetLoadLibraryAddr();

    // Find a thread to hijack
    DWORD tids[256];
    int threadCount = GetProcessThreads(pid, tids, 256);
    if (threadCount == 0) { FreeRemotePath(rp); return INJ_THREAD_FAIL; }

    // Try each thread until one works
    for (int i = 0; i < threadCount && i < 8; i++) {
        HANDLE hThread = OpenThread(
            THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT,
            FALSE, tids[i]);
        if (!hThread) continue;

        if (SuspendThread(hThread) == (DWORD)-1) {
            CloseHandle(hThread);
            continue;
        }

        CONTEXT ctx = {};
        ctx.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(hThread, &ctx)) {
            ResumeThread(hThread);
            CloseHandle(hThread);
            continue;
        }

        // Build shellcode
        ShellcodePayload sc = {};
        sc.pushfd       = 0x9C;
        sc.pushad       = 0x60;
        sc.push_arg     = 0x68;
        sc.arg_addr     = (uint32_t)(uintptr_t)rp.remoteMem;
        sc.mov_eax      = 0xB8;
        sc.func_addr    = (uint32_t)(uintptr_t)pLoadLib;
        sc.call_eax[0]  = 0xFF;
        sc.call_eax[1]  = 0xD0;
        sc.popad        = 0x61;
        sc.popfd        = 0x9D;
        sc.push_ret     = 0x68;
        sc.original_eip = (uint32_t)ctx.Eip;
        sc.ret          = 0xC3;

        // Allocate shellcode in remote process
        void* remoteShell = VirtualAllocEx(rp.hProc, nullptr, sizeof(sc),
            MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (!remoteShell) {
            ResumeThread(hThread);
            CloseHandle(hThread);
            continue;
        }

        WriteProcessMemory(rp.hProc, remoteShell, &sc, sizeof(sc), nullptr);
        FlushInstructionCache(rp.hProc, remoteShell, sizeof(sc));

        // Redirect thread to our shellcode
        ctx.Eip = (DWORD)(uintptr_t)remoteShell;
        SetThreadContext(hThread, &ctx);
        ResumeThread(hThread);
        CloseHandle(hThread);

        // Wait for it to execute
        Sleep(2000);

        // Cleanup shellcode (best-effort, thread already resumed)
        VirtualFreeEx(rp.hProc, remoteShell, 0, MEM_RELEASE);
        FreeRemotePath(rp);
        return INJ_OK; // Verify with module check
    }

    FreeRemotePath(rp);
    return INJ_THREAD_FAIL;
}

// ============================================================
// Injection engine: try all methods with verification
// ============================================================

struct InjectionConfig {
    DWORD       pid;
    const char* dllPath;
    const char* dllName;       // e.g. "rotation_engine.dll" for module check
    const char* label;         // human-readable label
    int         maxRetries;    // total retry attempts across all methods
    int         verifyDelayMs; // delay before checking if module loaded
};

struct InjectionReport {
    bool        success;
    int         methodUsed;    // 1-4, 0 = none
    int         attempts;
    const char* methodName;
    const char* lastError;
};

typedef InjectResult (*InjectMethod_t)(DWORD pid, const char* dllPath);

struct MethodEntry {
    const char*    name;
    InjectMethod_t func;
};

static const MethodEntry g_methods[] = {
    { "CreateRemoteThread",  Method_CreateRemoteThread },
    { "NtCreateThreadEx",    Method_NtCreateThreadEx },
    { "QueueUserAPC",        Method_QueueUserAPC },
    { "ThreadHijack",        Method_ThreadHijack },
};
static const int NUM_METHODS = sizeof(g_methods) / sizeof(g_methods[0]);

static InjectionReport InjectDLL(const InjectionConfig& cfg) {
    InjectionReport report = { false, 0, 0, "none", "not attempted" };
    char msg[512];

    sprintf_s(msg, "Injecting %s into PID %lu ...", cfg.label, cfg.pid);
    Info(msg);

    // Check if already loaded
    if (IsModuleLoaded(cfg.pid, cfg.dllName)) {
        sprintf_s(msg, "%s already loaded — skipping injection", cfg.label);
        Ok(msg);
        report.success = true;
        report.methodName = "already loaded";
        return report;
    }

    // Try each method, retry on failure
    for (int attempt = 0; attempt < cfg.maxRetries; attempt++) {
        int methodIdx = attempt % NUM_METHODS;
        const MethodEntry& method = g_methods[methodIdx];

        report.attempts++;
        sprintf_s(msg, "  [attempt %d/%d] Method: %s",
            attempt + 1, cfg.maxRetries, method.name);
        Info(msg);

        InjectResult result = method.func(cfg.pid, cfg.dllPath);

        if (result == INJ_OK || result == INJ_LOAD_FAIL) {
            // Give DLL time to initialize
            Sleep(cfg.verifyDelayMs);

            // Verify the module is actually loaded
            if (IsModuleLoaded(cfg.pid, cfg.dllName)) {
                report.success = true;
                report.methodUsed = methodIdx + 1;
                report.methodName = method.name;

                uintptr_t base = GetRemoteModuleBase(cfg.pid, cfg.dllName);
                sprintf_s(msg, "%s injected via %s at 0x%08X (attempt %d)",
                    cfg.label, method.name, (unsigned)base, attempt + 1);
                Ok(msg);
                return report;
            } else {
                sprintf_s(msg, "  %s — DLL not found in module list after injection",
                    method.name);
                Warn(msg);
                report.lastError = "module not found post-injection";
            }
        } else {
            sprintf_s(msg, "  %s — %s (error %lu)",
                method.name, InjectResultStr(result), GetLastError());
            Warn(msg);
            report.lastError = InjectResultStr(result);
        }

        // Small pause between retries
        if (attempt + 1 < cfg.maxRetries) Sleep(500);
    }

    sprintf_s(msg, "FAILED to inject %s after %d attempts", cfg.label, report.attempts);
    Err(msg);
    return report;
}

} // namespace ar
