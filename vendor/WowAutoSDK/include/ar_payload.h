/**
 * ar_payload.h - DLL payload extraction and management
 *
 * Handles:
 *   - Embedded resource extraction (from .rc compiled payloads)
 *   - Fallback to DLLs next to the launcher exe
 *   - PE header validation
 *   - Temp file lifecycle
 *
 * Header-only — include once from the main translation unit.
 */

#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

#include "ar_process.h"

// Resource IDs (must match .rc file)
#define IDR_LUA_UNLOCKER      101
#define IDR_ROTATION_ENGINE   102
#define RT_RCDATA_DLL         "DLL_PAYLOAD"

namespace ar {

// ============================================================
// PE validation
// ============================================================

inline bool ValidatePE(const char* path) {
    HANDLE hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, 0, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return false;

    IMAGE_DOS_HEADER dos = {};
    DWORD read = 0;
    ReadFile(hFile, &dos, sizeof(dos), &read, nullptr);
    if (read != sizeof(dos) || dos.e_magic != IMAGE_DOS_SIGNATURE) {
        CloseHandle(hFile);
        return false;
    }

    SetFilePointer(hFile, dos.e_lfanew, nullptr, FILE_BEGIN);
    IMAGE_NT_HEADERS32 nt = {};
    ReadFile(hFile, &nt, sizeof(nt), &read, nullptr);
    CloseHandle(hFile);

    if (read < sizeof(IMAGE_NT_HEADERS32)) return false;
    if (nt.Signature != IMAGE_NT_SIGNATURE) return false;
    if (nt.FileHeader.Machine != IMAGE_FILE_MACHINE_I386) return false; // must be x86
    if (!(nt.FileHeader.Characteristics & IMAGE_FILE_DLL)) return false; // must be DLL

    return true;
}

inline DWORD GetFileSize32(const char* path) {
    HANDLE hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, 0, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return 0;
    DWORD size = GetFileSize(hFile, nullptr);
    CloseHandle(hFile);
    return size;
}

// ============================================================
// Resource extraction
// ============================================================

inline bool ExtractResource(int resourceId, const char* outputPath) {
    HRSRC hRes = FindResourceA(nullptr, MAKEINTRESOURCEA(resourceId), RT_RCDATA_DLL);
    if (!hRes) {
        // Fallback: try RCDATA
        hRes = FindResourceA(nullptr, MAKEINTRESOURCEA(resourceId), RT_RCDATA);
    }
    if (!hRes) return false;

    HGLOBAL hData = LoadResource(nullptr, hRes);
    if (!hData) return false;

    void* data = LockResource(hData);
    DWORD size = SizeofResource(nullptr, hRes);
    if (!data || size == 0) return false;

    HANDLE hFile = CreateFileA(outputPath, GENERIC_WRITE, 0, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return false;

    DWORD written;
    WriteFile(hFile, data, size, &written, nullptr);
    CloseHandle(hFile);

    return written == size;
}

// ============================================================
// Find DLL next to launcher exe
// ============================================================

inline bool FindDllNextToExe(const char* dllName, char* outPath, size_t outSize) {
    GetModuleFileNameA(nullptr, outPath, (DWORD)outSize);
    char* slash = strrchr(outPath, '\\');
    if (slash) *(slash + 1) = '\0';
    strcat_s(outPath, outSize, dllName);
    return GetFileAttributesA(outPath) != INVALID_FILE_ATTRIBUTES;
}

// Find DLL in the SDK bin directory (relative to exe: ..\bin\)
inline bool FindDllInBinDir(const char* dllName, char* outPath, size_t outSize) {
    GetModuleFileNameA(nullptr, outPath, (DWORD)outSize);
    char* slash = strrchr(outPath, '\\');
    if (slash) *(slash + 1) = '\0';
    // If we're already in bin, just look here
    strcat_s(outPath, outSize, dllName);
    if (GetFileAttributesA(outPath) != INVALID_FILE_ATTRIBUTES) return true;

    // Try parent\bin\ path
    GetModuleFileNameA(nullptr, outPath, (DWORD)outSize);
    slash = strrchr(outPath, '\\');
    if (slash) *(slash + 1) = '\0';
    strcat_s(outPath, outSize, "..\\bin\\");
    strcat_s(outPath, outSize, dllName);
    return GetFileAttributesA(outPath) != INVALID_FILE_ATTRIBUTES;
}

// ============================================================
// Payload management
// ============================================================

struct PayloadInfo {
    char path[MAX_PATH];
    bool ready;
    bool fromResource;       // true = extracted to temp, needs cleanup
    bool validated;
    DWORD sizeBytes;
};

// Attempt to locate or extract a DLL payload
inline PayloadInfo PreparePayload(int resourceId, const char* dllName) {
    PayloadInfo info = {};
    info.ready = false;
    info.fromResource = false;

    char msg[512];

    // Strategy 1: Extract from embedded resources
    char tempDir[MAX_PATH];
    GetTempPathA(MAX_PATH, tempDir);
    strcat_s(tempDir, "AscensionSDK\\");
    CreateDirectoryA(tempDir, nullptr);

    char tempPath[MAX_PATH];
    sprintf_s(tempPath, "%s%s", tempDir, dllName);

    if (ExtractResource(resourceId, tempPath)) {
        if (ValidatePE(tempPath)) {
            strcpy_s(info.path, tempPath);
            info.ready = true;
            info.fromResource = true;
            info.validated = true;
            info.sizeBytes = GetFileSize32(tempPath);

            sprintf_s(msg, "%s: extracted from resources (%lu bytes, PE valid)",
                dllName, info.sizeBytes);
            Ok(msg);
            return info;
        } else {
            DeleteFileA(tempPath);
            sprintf_s(msg, "%s: resource extraction failed PE validation", dllName);
            Warn(msg);
        }
    }

    // Strategy 2: Look next to the exe
    if (FindDllNextToExe(dllName, info.path, sizeof(info.path))) {
        if (ValidatePE(info.path)) {
            info.ready = true;
            info.fromResource = false;
            info.validated = true;
            info.sizeBytes = GetFileSize32(info.path);

            sprintf_s(msg, "%s: found next to launcher (%lu bytes, PE valid)",
                dllName, info.sizeBytes);
            Ok(msg);
            return info;
        } else {
            sprintf_s(msg, "%s: found next to launcher but FAILED PE validation", dllName);
            Warn(msg);
        }
    }

    // Strategy 3: Look in bin directory
    if (FindDllInBinDir(dllName, info.path, sizeof(info.path))) {
        if (ValidatePE(info.path)) {
            info.ready = true;
            info.fromResource = false;
            info.validated = true;
            info.sizeBytes = GetFileSize32(info.path);

            sprintf_s(msg, "%s: found in bin directory (%lu bytes, PE valid)",
                dllName, info.sizeBytes);
            Ok(msg);
            return info;
        } else {
            sprintf_s(msg, "%s: found in bin dir but FAILED PE validation", dllName);
            Warn(msg);
        }
    }

    sprintf_s(msg, "%s: NOT FOUND anywhere", dllName);
    Err(msg);
    return info;
}

inline void CleanupPayload(PayloadInfo& info) {
    if (info.fromResource && info.path[0]) {
        DeleteFileA(info.path);
        info.ready = false;
    }
}

inline void CleanupTempDir() {
    char tempDir[MAX_PATH];
    GetTempPathA(MAX_PATH, tempDir);
    strcat_s(tempDir, "AscensionSDK\\");
    RemoveDirectoryA(tempDir); // only succeeds if empty
}

} // namespace ar
