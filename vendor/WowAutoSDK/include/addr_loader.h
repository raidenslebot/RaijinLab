/**
 * addr_loader.h — Runtime address resolver for version-agnostic DLLs
 *
 * Loads addresses from a JSON config file at DLL init time instead of
 * compiling them in. This makes the DLLs portable across WoW builds
 * without recompilation — just update the JSON.
 *
 * Addresses are resolved in priority order:
 *   1. JSON file next to the game executable (e.g. Ascension.exe.addrs.json)
 *   2. Compile-time fallbacks from wow_addresses_XXXXX.h (if available)
 *   3. Zero (feature disabled, no crash)
 *
 * Header-only — include in exactly ONE translation unit with:
 *   #define ADDR_LOADER_IMPL
 *   #include "addr_loader.h"
 *
 * All other translation units just include without the define.
 *
 * Build: MSVC x86, /MT /EHa /O2
 */

#pragma once

#include <cstdint>

// ============================================================
// Address table — all resolved addresses live here
// ============================================================

namespace addr {

// Globals
extern uintptr_t g_luaState;
extern uintptr_t g_InWorld;
extern uintptr_t g_clientConnection;
extern uintptr_t g_localPlayer;
extern uintptr_t g_objectManager;
extern uintptr_t g_cameraBase;
extern uintptr_t g_gameTime;

// FrameScript
extern uintptr_t FrameScript_Execute;
extern uintptr_t FrameScript_RegisterFunction;
extern uintptr_t FrameScript_UnregisterFunction;
extern uintptr_t FrameScript_GetText;
extern uintptr_t FrameScript_SetGlobal;

// Lua C API
extern uintptr_t lua_gettop;
extern uintptr_t lua_settop;
extern uintptr_t lua_insert;
extern uintptr_t lua_type;
extern uintptr_t lua_tonumber;
extern uintptr_t lua_tolstring;
extern uintptr_t lua_pushnil;
extern uintptr_t lua_pushnumber;
extern uintptr_t lua_pushinteger;
extern uintptr_t lua_pushstring;
extern uintptr_t lua_pushlstring;
extern uintptr_t lua_pushboolean;
extern uintptr_t lua_pushcclosure;
extern uintptr_t lua_pushvalue;
extern uintptr_t lua_createtable;
extern uintptr_t lua_settable;
extern uintptr_t lua_setfield;
extern uintptr_t lua_getfield;
extern uintptr_t lua_gettable;
extern uintptr_t lua_rawset;
extern uintptr_t lua_rawseti;
extern uintptr_t lua_pcall;
extern uintptr_t lua_toboolean;
extern uintptr_t lua_touserdata;
extern uintptr_t lua_isnumber;
extern uintptr_t lua_isstring;
extern uintptr_t luaL_loadbuffer;

// Game functions
extern uintptr_t ClntObjMgrEnumVisObjs;
extern uintptr_t ClntObjMgrObjectPtr;
extern uintptr_t ClntObjMgrGetActivePlayer;
extern uintptr_t ClntObjMgrGetActivePlayerObj;
extern uintptr_t CGObject_GetPosition;
extern uintptr_t CGUnit_GetHealth;
extern uintptr_t CGUnit_GetMaxHealth;
extern uintptr_t CGUnit_GetHealthPct;
extern uintptr_t CGUnit_GetLevel;
extern uintptr_t Spell_C_CastSpell;
extern uintptr_t CGPlayer_ClickToMove;
extern uintptr_t Spell_C_GetSpellName;
extern uintptr_t CWorld_Intersect;
extern uintptr_t CGUnit_IsIndoors;
extern uintptr_t CGObject_GetObjectType;
extern uintptr_t ChatFrame_SendChatMessage;
extern uintptr_t CVar_LookupByName;
extern uintptr_t ConsoleExec;

// Taint system (lua_unlocker specific)
extern uintptr_t TaintContext;
extern uintptr_t ExecCounter;
extern uintptr_t CombatLockdown;
extern uintptr_t EventHandlerPtr;
extern uintptr_t EventHandlerSet;
extern uintptr_t VMTaintSkip1;
extern uintptr_t VMTaintSkip2;
extern uintptr_t TaintErrorReporter;
extern uintptr_t EventHandlerClear;
extern uintptr_t HardwareEventFlag;
extern uintptr_t issecure_JNE;
extern uintptr_t forceinsecure;
extern uintptr_t securecall_save;
extern uintptr_t securecall_inc;

// Movement handlers
extern uintptr_t MoveForwardStart;
extern uintptr_t MoveForwardStop;
extern uintptr_t MoveBackwardStart;
extern uintptr_t MoveBackwardStop;
extern uintptr_t TurnLeftStart;
extern uintptr_t TurnLeftStop;
extern uintptr_t TurnRightStart;
extern uintptr_t TurnRightStop;
extern uintptr_t StrafeLeftStart;
extern uintptr_t StrafeLeftStop;
extern uintptr_t StrafeRightStart;
extern uintptr_t StrafeRightStop;
extern uintptr_t JumpOrAscendStart;
extern uintptr_t AscendStop;

// Build info
extern int      buildNumber;
extern bool     loaded;

// Initialize — call once from DLL init. Returns true if addresses loaded.
// configDir: directory containing the JSON address files (can be nullptr for auto-detect)
bool Init(const char* configDir = nullptr);

// Get the resolved build number
int GetBuild();

// Check if a specific address was resolved (non-zero)
inline bool IsValid(uintptr_t a) { return a != 0; }

} // namespace addr


// ============================================================
// Implementation — define ADDR_LOADER_IMPL in exactly one .cpp
// ============================================================

#ifdef ADDR_LOADER_IMPL

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace addr {

// Storage
uintptr_t g_luaState = 0;
uintptr_t g_InWorld = 0;
uintptr_t g_clientConnection = 0;
uintptr_t g_localPlayer = 0;
uintptr_t g_objectManager = 0;
uintptr_t g_cameraBase = 0;
uintptr_t g_gameTime = 0;

uintptr_t FrameScript_Execute = 0;
uintptr_t FrameScript_RegisterFunction = 0;
uintptr_t FrameScript_UnregisterFunction = 0;
uintptr_t FrameScript_GetText = 0;
uintptr_t FrameScript_SetGlobal = 0;

uintptr_t lua_gettop = 0;
uintptr_t lua_settop = 0;
uintptr_t lua_insert = 0;
uintptr_t lua_type = 0;
uintptr_t lua_tonumber = 0;
uintptr_t lua_tolstring = 0;
uintptr_t lua_pushnil = 0;
uintptr_t lua_pushnumber = 0;
uintptr_t lua_pushinteger = 0;
uintptr_t lua_pushstring = 0;
uintptr_t lua_pushlstring = 0;
uintptr_t lua_pushboolean = 0;
uintptr_t lua_pushcclosure = 0;
uintptr_t lua_pushvalue = 0;
uintptr_t lua_createtable = 0;
uintptr_t lua_settable = 0;
uintptr_t lua_setfield = 0;
uintptr_t lua_getfield = 0;
uintptr_t lua_gettable = 0;
uintptr_t lua_rawset = 0;
uintptr_t lua_rawseti = 0;
uintptr_t lua_pcall = 0;
uintptr_t lua_toboolean = 0;
uintptr_t lua_touserdata = 0;
uintptr_t lua_isnumber = 0;
uintptr_t lua_isstring = 0;
uintptr_t luaL_loadbuffer = 0;

uintptr_t ClntObjMgrEnumVisObjs = 0;
uintptr_t ClntObjMgrObjectPtr = 0;
uintptr_t ClntObjMgrGetActivePlayer = 0;
uintptr_t ClntObjMgrGetActivePlayerObj = 0;
uintptr_t CGObject_GetPosition = 0;
uintptr_t CGUnit_GetHealth = 0;
uintptr_t CGUnit_GetMaxHealth = 0;
uintptr_t CGUnit_GetHealthPct = 0;
uintptr_t CGUnit_GetLevel = 0;
uintptr_t Spell_C_CastSpell = 0;
uintptr_t CGPlayer_ClickToMove = 0;
uintptr_t Spell_C_GetSpellName = 0;
uintptr_t CWorld_Intersect = 0;
uintptr_t CGUnit_IsIndoors = 0;
uintptr_t CGObject_GetObjectType = 0;
uintptr_t ChatFrame_SendChatMessage = 0;
uintptr_t CVar_LookupByName = 0;
uintptr_t ConsoleExec = 0;

uintptr_t TaintContext = 0;
uintptr_t ExecCounter = 0;
uintptr_t CombatLockdown = 0;
uintptr_t EventHandlerPtr = 0;
uintptr_t EventHandlerSet = 0;
uintptr_t VMTaintSkip1 = 0;
uintptr_t VMTaintSkip2 = 0;
uintptr_t TaintErrorReporter = 0;
uintptr_t EventHandlerClear = 0;
uintptr_t HardwareEventFlag = 0;
uintptr_t issecure_JNE = 0;
uintptr_t forceinsecure = 0;
uintptr_t securecall_save = 0;
uintptr_t securecall_inc = 0;

uintptr_t MoveForwardStart = 0;
uintptr_t MoveForwardStop = 0;
uintptr_t MoveBackwardStart = 0;
uintptr_t MoveBackwardStop = 0;
uintptr_t TurnLeftStart = 0;
uintptr_t TurnLeftStop = 0;
uintptr_t TurnRightStart = 0;
uintptr_t TurnRightStop = 0;
uintptr_t StrafeLeftStart = 0;
uintptr_t StrafeLeftStop = 0;
uintptr_t StrafeRightStart = 0;
uintptr_t StrafeRightStop = 0;
uintptr_t JumpOrAscendStart = 0;
uintptr_t AscendStop = 0;

int  buildNumber = 0;
bool loaded = false;

// ============================================================
// Minimal JSON parser — no dependencies required
// Parses the flat key-value structure of our address JSON files.
// ============================================================

static uintptr_t ParseHexOrDec(const char* s) {
    if (!s) return 0;
    while (*s == ' ' || *s == '\t' || *s == '"') s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        return (uintptr_t)strtoul(s, nullptr, 16);
    return (uintptr_t)strtoul(s, nullptr, 10);
}

// Find "key": "value" or "key": number in a JSON string.
// Returns pointer to the value start (after colon + whitespace).
static const char* JsonFindValue(const char* json, const char* key) {
    if (!json || !key) return nullptr;
    size_t klen = strlen(key);
    const char* p = json;
    while ((p = strstr(p, key)) != nullptr) {
        // Verify it's a quoted key
        if (p > json && *(p - 1) == '"') {
            const char* afterKey = p + klen;
            if (*afterKey == '"') {
                // Skip to colon
                afterKey++;
                while (*afterKey == ' ' || *afterKey == '\t') afterKey++;
                if (*afterKey == ':') {
                    afterKey++;
                    while (*afterKey == ' ' || *afterKey == '\t') afterKey++;
                    return afterKey;
                }
            }
        }
        p++;
    }
    return nullptr;
}

// Extract a hex/decimal value for a named address field
static uintptr_t JsonGetAddress(const char* json, const char* name) {
    const char* val = JsonFindValue(json, name);
    if (!val) return 0;
    // Value is either "0x..." (quoted) or a bare number
    if (*val == '"') return ParseHexOrDec(val + 1);
    return ParseHexOrDec(val);
}

// ============================================================
// Address name -> pointer mapping table
// ============================================================

struct AddrEntry {
    const char* jsonName;
    uintptr_t*  target;
};

static const AddrEntry g_addrMap[] = {
    // Globals
    { "g_luaState",                    &g_luaState },
    { "g_InWorld",                     &g_InWorld },
    { "g_clientConnection",            &g_clientConnection },
    { "g_localPlayer",                 &g_localPlayer },
    { "g_objectManager",               &g_objectManager },
    { "g_cameraBase",                  &g_cameraBase },
    { "g_gameTime",                    &g_gameTime },
    // FrameScript
    { "FrameScript_Execute",           &FrameScript_Execute },
    { "FrameScript_RegisterFunction",  &FrameScript_RegisterFunction },
    { "FrameScript_UnregisterFunction",&FrameScript_UnregisterFunction },
    { "FrameScript_GetText",           &FrameScript_GetText },
    { "FrameScript_SetGlobal",         &FrameScript_SetGlobal },
    // Lua C API
    { "lua_gettop",                    &lua_gettop },
    { "lua_settop",                    &lua_settop },
    { "lua_insert",                    &lua_insert },
    { "lua_type",                      &lua_type },
    { "lua_tonumber",                  &lua_tonumber },
    { "lua_tolstring",                 &lua_tolstring },
    { "lua_pushnil",                   &lua_pushnil },
    { "lua_pushnumber",                &lua_pushnumber },
    { "lua_pushinteger",               &lua_pushinteger },
    { "lua_pushstring",                &lua_pushstring },
    { "lua_pushlstring",               &lua_pushlstring },
    { "lua_pushboolean",               &lua_pushboolean },
    { "lua_pushcclosure",              &lua_pushcclosure },
    { "lua_pushvalue",                 &lua_pushvalue },
    { "lua_createtable",               &lua_createtable },
    { "lua_settable",                  &lua_settable },
    { "lua_setfield",                  &lua_setfield },
    { "lua_getfield",                  &lua_getfield },
    { "lua_gettable",                  &lua_gettable },
    { "lua_rawset",                    &lua_rawset },
    { "lua_rawseti",                   &lua_rawseti },
    { "lua_pcall",                     &lua_pcall },
    { "lua_toboolean",                 &lua_toboolean },
    { "lua_touserdata",                &lua_touserdata },
    { "lua_isnumber",                  &lua_isnumber },
    { "lua_isstring",                  &lua_isstring },
    { "luaL_loadbuffer",               &luaL_loadbuffer },
    // Game functions
    { "ClntObjMgrEnumVisObjs",         &ClntObjMgrEnumVisObjs },
    { "ClntObjMgrEnumVisibleObjects",  &ClntObjMgrEnumVisObjs },
    { "ClntObjMgrObjectPtr",           &ClntObjMgrObjectPtr },
    { "ClntObjMgrGetActivePlayer",     &ClntObjMgrGetActivePlayer },
    { "ClntObjMgrGetActivePlayerObj",  &ClntObjMgrGetActivePlayerObj },
    { "CGObject_GetPosition",          &CGObject_GetPosition },
    { "CGUnit_GetHealth",              &CGUnit_GetHealth },
    { "CGUnit_GetMaxHealth",           &CGUnit_GetMaxHealth },
    { "CGUnit_GetHealthPct",           &CGUnit_GetHealthPct },
    { "CGUnit_GetLevel",               &CGUnit_GetLevel },
    { "Spell_C_CastSpell",            &Spell_C_CastSpell },
    { "CGPlayer_ClickToMove",          &CGPlayer_ClickToMove },
    { "Spell_C_GetSpellName",          &Spell_C_GetSpellName },
    { "CWorld_Intersect",              &CWorld_Intersect },
    { "CGUnit_IsIndoors",              &CGUnit_IsIndoors },
    { "CGObject_GetObjectType",        &CGObject_GetObjectType },
    { "ChatFrame_SendChatMessage",     &ChatFrame_SendChatMessage },
    { "CVar_LookupByName",            &CVar_LookupByName },
    { "ConsoleExec",                   &ConsoleExec },
    // Taint system
    { "TaintContext",                  &TaintContext },
    { "ExecCounter",                   &ExecCounter },
    { "CombatLockdown",                &CombatLockdown },
    { "EventHandlerPtr",               &EventHandlerPtr },
    { "EventHandlerSet",               &EventHandlerSet },
    { "EventHandlerClear",             &EventHandlerClear },
    { "HardwareEventFlag",             &HardwareEventFlag },
    { "VMTaintSkip1",                  &VMTaintSkip1 },
    { "VMTaintSkip2",                  &VMTaintSkip2 },
    { "TaintErrorReporter",            &TaintErrorReporter },
    { "issecure_JNE",                  &issecure_JNE },
    { "forceinsecure",                 &forceinsecure },
    { "securecall_save",               &securecall_save },
    { "securecall_inc",                &securecall_inc },
    // Movement
    { "MoveForwardStart",              &MoveForwardStart },
    { "MoveForwardStop",               &MoveForwardStop },
    { "MoveBackwardStart",             &MoveBackwardStart },
    { "MoveBackwardStop",              &MoveBackwardStop },
    { "TurnLeftStart",                 &TurnLeftStart },
    { "TurnLeftStop",                  &TurnLeftStop },
    { "TurnRightStart",                &TurnRightStart },
    { "TurnRightStop",                 &TurnRightStop },
    { "StrafeLeftStart",               &StrafeLeftStart },
    { "StrafeLeftStop",                &StrafeLeftStop },
    { "StrafeRightStart",              &StrafeRightStart },
    { "StrafeRightStop",               &StrafeRightStop },
    { "JumpOrAscendStart",             &JumpOrAscendStart },
    { "AscendStop",                    &AscendStop },
    { nullptr, nullptr },
};

// ============================================================
// Build detection from PE version resource
// ============================================================

static int DetectBuildFromPE() {
    char exePath[MAX_PATH];
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);

    DWORD dummy;
    DWORD size = GetFileVersionInfoSizeA(exePath, &dummy);
    if (!size) return 0;

    char* buf = (char*)malloc(size);
    if (!buf) return 0;

    if (!GetFileVersionInfoA(exePath, 0, size, buf)) {
        free(buf);
        return 0;
    }

    VS_FIXEDFILEINFO* info = nullptr;
    UINT len = 0;
    if (!VerQueryValueA(buf, "\\", (LPVOID*)&info, &len) || !info) {
        free(buf);
        return 0;
    }

    int build = (int)(info->dwFileVersionLS & 0xFFFF);
    free(buf);
    return build;
}

// ============================================================
// File loader — reads entire file into malloc'd buffer
// ============================================================

static char* ReadEntireFile(const char* path) {
    HANDLE hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ,
                               nullptr, OPEN_EXISTING, 0, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return nullptr;

    DWORD fileSize = GetFileSize(hFile, nullptr);
    if (fileSize == INVALID_FILE_SIZE || fileSize == 0) {
        CloseHandle(hFile);
        return nullptr;
    }

    // Cap at 4MB to prevent abuse
    if (fileSize > 4 * 1024 * 1024) {
        CloseHandle(hFile);
        return nullptr;
    }

    char* buf = (char*)malloc(fileSize + 1);
    if (!buf) { CloseHandle(hFile); return nullptr; }

    DWORD bytesRead;
    if (!ReadFile(hFile, buf, fileSize, &bytesRead, nullptr) || bytesRead != fileSize) {
        free(buf);
        CloseHandle(hFile);
        return nullptr;
    }

    buf[fileSize] = '\0';
    CloseHandle(hFile);
    return buf;
}

// ============================================================
// Load addresses from a single JSON array file (like globals.json)
// Format: [{ "name": "xxx", "address": "0xYYY", ... }, ...]
// ============================================================

static int LoadFromArrayJson(const char* json) {
    int count = 0;
    // Walk through looking for "name" and "address" pairs
    const char* p = json;
    while (p && *p) {
        // Find next "name"
        const char* nameKey = strstr(p, "\"name\"");
        if (!nameKey) break;

        // Extract name value
        const char* nameVal = nameKey + 6;
        while (*nameVal && *nameVal != '"') nameVal++;
        if (*nameVal != '"') break;
        nameVal++; // skip opening quote
        const char* nameEnd = strchr(nameVal, '"');
        if (!nameEnd) break;

        char name[128];
        size_t nameLen = nameEnd - nameVal;
        if (nameLen >= sizeof(name)) nameLen = sizeof(name) - 1;
        memcpy(name, nameVal, nameLen);
        name[nameLen] = '\0';

        // Find "address" after this name
        const char* addrKey = strstr(nameEnd, "\"address\"");
        if (!addrKey) break;

        // Check we haven't gone past the next entry
        const char* nextName = strstr(nameEnd + 1, "\"name\"");

        const char* addrVal = addrKey + 9;
        while (*addrVal && *addrVal != '"' && *addrVal != '0') addrVal++;
        uintptr_t address = ParseHexOrDec(addrVal);

        if (address != 0) {
            // Look up in our table
            for (int i = 0; g_addrMap[i].jsonName; i++) {
                if (strcmp(g_addrMap[i].jsonName, name) == 0) {
                    *g_addrMap[i].target = address;
                    count++;
                    break;
                }
            }
        }

        p = nextName ? nextName : (addrKey + 10);
    }
    return count;
}

// ============================================================
// Apply compile-time fallbacks for any addresses still zero
// ============================================================

static void ApplyCompileTimeFallbacks() {
    // Only apply if the compile-time header is available
#ifdef WOW_BUILD_NUMBER
    #ifdef ADDR_g_luaState
    if (!g_luaState) g_luaState = ADDR_g_luaState;
    #endif
    #ifdef ADDR_g_InWorld
    if (!g_InWorld) g_InWorld = ADDR_g_InWorld;
    #endif
    #ifdef ADDR_FrameScript_Execute
    if (!FrameScript_Execute) FrameScript_Execute = ADDR_FrameScript_Execute;
    #endif
    #ifdef ADDR_FrameScript_RegisterFunction
    if (!FrameScript_RegisterFunction) FrameScript_RegisterFunction = ADDR_FrameScript_RegisterFunction;
    #endif
    #ifdef ADDR_FrameScript_UnregisterFunction
    if (!FrameScript_UnregisterFunction) FrameScript_UnregisterFunction = ADDR_FrameScript_UnregisterFunction;
    #endif
    #ifdef ADDR_FrameScript_GetText
    if (!FrameScript_GetText) FrameScript_GetText = ADDR_FrameScript_GetText;
    #endif
    #ifdef ADDR_FrameScript_SetGlobal
    if (!FrameScript_SetGlobal) FrameScript_SetGlobal = ADDR_FrameScript_SetGlobal;
    #endif
    #ifdef ADDR_lua_gettop
    if (!lua_gettop) lua_gettop = ADDR_lua_gettop;
    #endif
    #ifdef ADDR_lua_settop
    if (!lua_settop) lua_settop = ADDR_lua_settop;
    #endif
    #ifdef ADDR_lua_insert
    if (!lua_insert) lua_insert = ADDR_lua_insert;
    #endif
    #ifdef ADDR_lua_type
    if (!lua_type) lua_type = ADDR_lua_type;
    #endif
    #ifdef ADDR_lua_tonumber
    if (!lua_tonumber) lua_tonumber = ADDR_lua_tonumber;
    #endif
    #ifdef ADDR_lua_tolstring
    if (!lua_tolstring) lua_tolstring = ADDR_lua_tolstring;
    #endif
    #ifdef ADDR_lua_pushnil
    if (!lua_pushnil) lua_pushnil = ADDR_lua_pushnil;
    #endif
    #ifdef ADDR_lua_pushnumber
    if (!lua_pushnumber) lua_pushnumber = ADDR_lua_pushnumber;
    #endif
    #ifdef ADDR_lua_pushinteger
    if (!lua_pushinteger) lua_pushinteger = ADDR_lua_pushinteger;
    #endif
    #ifdef ADDR_lua_pushstring
    if (!lua_pushstring) lua_pushstring = ADDR_lua_pushstring;
    #endif
    #ifdef ADDR_lua_pushlstring
    if (!lua_pushlstring) lua_pushlstring = ADDR_lua_pushlstring;
    #endif
    #ifdef ADDR_lua_pushboolean
    if (!lua_pushboolean) lua_pushboolean = ADDR_lua_pushboolean;
    #endif
    #ifdef ADDR_lua_pushcclosure
    if (!lua_pushcclosure) lua_pushcclosure = ADDR_lua_pushcclosure;
    #endif
    #ifdef ADDR_lua_pushvalue
    if (!lua_pushvalue) lua_pushvalue = ADDR_lua_pushvalue;
    #endif
    #ifdef ADDR_lua_createtable
    if (!lua_createtable) lua_createtable = ADDR_lua_createtable;
    #endif
    #ifdef ADDR_lua_settable
    if (!lua_settable) lua_settable = ADDR_lua_settable;
    #endif
    #ifdef ADDR_lua_setfield
    if (!lua_setfield) lua_setfield = ADDR_lua_setfield;
    #endif
    #ifdef ADDR_lua_getfield
    if (!lua_getfield) lua_getfield = ADDR_lua_getfield;
    #endif
    #ifdef ADDR_lua_gettable
    if (!lua_gettable) lua_gettable = ADDR_lua_gettable;
    #endif
    #ifdef ADDR_lua_rawset
    if (!lua_rawset) lua_rawset = ADDR_lua_rawset;
    #endif
    #ifdef ADDR_lua_rawseti
    if (!lua_rawseti) lua_rawseti = ADDR_lua_rawseti;
    #endif
    #ifdef ADDR_lua_pcall
    if (!lua_pcall) lua_pcall = ADDR_lua_pcall;
    #endif
    #ifdef ADDR_lua_toboolean
    if (!lua_toboolean) lua_toboolean = ADDR_lua_toboolean;
    #endif
    #ifdef ADDR_lua_touserdata
    if (!lua_touserdata) lua_touserdata = ADDR_lua_touserdata;
    #endif
    #ifdef ADDR_lua_isnumber
    if (!lua_isnumber) lua_isnumber = ADDR_lua_isnumber;
    #endif
    #ifdef ADDR_lua_isstring
    if (!lua_isstring) lua_isstring = ADDR_lua_isstring;
    #endif
    #ifdef ADDR_luaL_loadbuffer
    if (!luaL_loadbuffer) luaL_loadbuffer = ADDR_luaL_loadbuffer;
    #endif
#endif
}

// ============================================================
// Main initialization
// ============================================================

bool Init(const char* configDir) {
    if (loaded) return true;

    // Step 1: Detect build
    buildNumber = DetectBuildFromPE();

    // Step 2: Determine JSON directory
    char jsonDir[MAX_PATH] = {};
    if (configDir && configDir[0]) {
        strncpy(jsonDir, configDir, MAX_PATH - 1);
    } else {
        // Default: look next to the game executable
        GetModuleFileNameA(nullptr, jsonDir, MAX_PATH);
        char* lastSlash = strrchr(jsonDir, '\\');
        if (lastSlash) *(lastSlash + 1) = '\0';
    }

    // Step 3: Try to load the flat address file first
    // Format: <exedir>\wow_addresses.json (single flat file with all addresses)
    {
        char path[MAX_PATH];
        snprintf(path, MAX_PATH, "%swow_addresses.json", jsonDir);
        char* json = ReadEntireFile(path);
        if (json) {
            LoadFromArrayJson(json);
            free(json);
        }
    }

    // Step 4: Load individual category files (override/supplement)
    static const char* categories[] = {
        "globals.json", "framescript.json", "lua-c-api.json",
        "game-functions.json", "object-manager.json", "network.json",
        "lua-handlers.json", "taint-system.json", "movement.json",
        nullptr
    };
    for (int i = 0; categories[i]; i++) {
        char path[MAX_PATH];
        snprintf(path, MAX_PATH, "%s%s", jsonDir, categories[i]);
        char* json = ReadEntireFile(path);
        if (json) {
            LoadFromArrayJson(json);
            free(json);
        }
    }

    // Step 5: Apply compile-time fallbacks for anything still unresolved
    ApplyCompileTimeFallbacks();

    // Step 6: Validate minimum required addresses
    loaded = (g_luaState != 0 && g_InWorld != 0 &&
              FrameScript_Execute != 0 && FrameScript_RegisterFunction != 0);

    return loaded;
}

int GetBuild() {
    return buildNumber;
}

} // namespace addr

#endif // ADDR_LOADER_IMPL
