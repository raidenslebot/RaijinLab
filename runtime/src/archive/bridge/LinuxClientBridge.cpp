#include "LinuxClientBridge.h"
#include "API/API.h"
#include "API/ObjectManager.h"
#include "Functions.h"
#include "Console.h"
#include "Mem.h"

#include <Windows.h>
#include <cstdio>
#include <cstring>
#include <string>

struct lua_State;

using lua_gettop_t = int(__cdecl*)(lua_State*);
using lua_tolstring_t = const char*(__cdecl*)(lua_State*, int, size_t*);
using lua_tonumber_t = double(__cdecl*)(lua_State*, int);
using lua_pushnumber_t = void(__cdecl*)(lua_State*, double);
using lua_pushstring_t = void(__cdecl*)(lua_State*, const char*);
using lua_pushboolean_t = void(__cdecl*)(lua_State*, int);
using lua_pushnil_t = void(__cdecl*)(lua_State*);

#include "Offsets.h"

// Resolved from Ascension.exe static analysis (see notes/10).
static lua_gettop_t p_lua_gettop =
    reinterpret_cast<lua_gettop_t>(Offsets::Functions::lua_gettop);
static lua_tolstring_t p_lua_tolstring =
    reinterpret_cast<lua_tolstring_t>(Offsets::Functions::lua_tolstring);
static lua_tonumber_t p_lua_tonumber =
    reinterpret_cast<lua_tonumber_t>(Offsets::Functions::lua_tonumber);
static lua_pushnumber_t p_lua_pushnumber =
    reinterpret_cast<lua_pushnumber_t>(Offsets::Functions::lua_pushnumber);
static lua_pushstring_t p_lua_pushstring =
    reinterpret_cast<lua_pushstring_t>(Offsets::Functions::lua_pushstring);
static lua_pushboolean_t p_lua_pushboolean =
    reinterpret_cast<lua_pushboolean_t>(Offsets::Functions::lua_pushboolean);
static lua_pushnil_t p_lua_pushnil = nullptr; // optional

static const char* kVersion = "0.2.0-ascension-example-port";

static int PushString(lua_State* L, const char* s) {
    if (p_lua_pushstring) {
        p_lua_pushstring(L, s ? s : "");
        return 1;
    }
    return 0;
}

static int PushNumber(lua_State* L, double n) {
    if (p_lua_pushnumber) {
        p_lua_pushnumber(L, n);
        return 1;
    }
    return 0;
}

static int PushBool(lua_State* L, int v) {
    if (p_lua_pushboolean) {
        p_lua_pushboolean(L, v);
        return 1;
    }
    return PushNumber(L, v ? 1.0 : 0.0);
}

static int PushNil(lua_State* L) {
    if (p_lua_pushnil) {
        p_lua_pushnil(L);
        return 1;
    }
    return 0;
}

static const char* ArgString(lua_State* L, int idx) {
    if (p_lua_tolstring)
        return p_lua_tolstring(L, idx, nullptr);
    return nullptr;
}

static double ArgNumber(lua_State* L, int idx) {
    if (p_lua_tonumber)
        return p_lua_tonumber(L, idx);
    return 0.0;
}

static int Dispatch(lua_State* L, const char* name) {
    if (!name)
        return PushNil(L);

    if (std::strcmp(name, "GetRuntimeVersion") == 0)
        return PushString(L, kVersion);
    if (std::strcmp(name, "Ping") == 0)
        return PushString(L, "pong");

    if (std::strcmp(name, "GetObjectCount") == 0) {
        API::RefreshObjects();
        return PushNumber(L, static_cast<double>(API::OM::Count()));
    }
    if (std::strcmp(name, "GetNpcCount") == 0) {
        API::RefreshObjects();
        return PushNumber(L, static_cast<double>(API::OM::CountByType(Types::Unit)));
    }
    if (std::strcmp(name, "GetPlayerCount") == 0) {
        API::RefreshObjects();
        return PushNumber(L, static_cast<double>(API::OM::CountByType(Types::Player)));
    }
    if (std::strcmp(name, "GetGameObjectCount") == 0) {
        API::RefreshObjects();
        return PushNumber(L, static_cast<double>(API::OM::CountByType(Types::GameObject)));
    }

    if (std::strcmp(name, "ObjectPosition") == 0) {
        Vec3 p = API::GetPlayerPosition();
        char buf[96];
        std::snprintf(buf, sizeof(buf), "%.4f,%.4f,%.4f", p.x, p.y, p.z);
        return PushString(L, buf);
    }

    if (std::strcmp(name, "GetCameraPosition") == 0) {
        Vec3 p = API::GetCameraPosition();
        char buf[96];
        std::snprintf(buf, sizeof(buf), "%.4f,%.4f,%.4f", p.x, p.y, p.z);
        return PushString(L, buf);
    }

    if (std::strcmp(name, "MoveTo") == 0) {
        // args: x,y,z if lua numbers resolved
        if (p_lua_tonumber) {
            Vec3 pos;
            pos.x = static_cast<float>(ArgNumber(L, 2));
            pos.y = static_cast<float>(ArgNumber(L, 3));
            pos.z = static_cast<float>(ArgNumber(L, 4));
            API::MoveTo(pos);
        }
        return PushBool(L, 1);
    }

    if (std::strcmp(name, "ResetAfk") == 0)
        return PushBool(L, 1);

    if (std::strcmp(name, "ObjectExists") == 0)
        return PushBool(L, API::IsLoggedIn() ? 1 : 0);

    if (std::strcmp(name, "GetWoWDirectory") == 0) {
        char path[MAX_PATH]{};
        GetModuleFileNameA(nullptr, path, MAX_PATH);
        char* slash = std::strrchr(path, '\\');
        if (slash)
            *slash = 0;
        return PushString(L, path);
    }

    if (std::strcmp(name, "GetAppDirectory") == 0 || std::strcmp(name, "GetAppStorageDirectory") == 0) {
        char path[MAX_PATH]{};
        GetModuleFileNameA(GetModuleHandleA("RaijinLabRuntime.dll"), path, MAX_PATH);
        char* slash = std::strrchr(path, '\\');
        if (slash)
            *slash = 0;
        return PushString(L, path);
    }

    if (std::strcmp(name, "FileExists") == 0) {
        // IsLinuxClient("FileExists", token, path) — path at arg 3 or 2
        const char* path = ArgString(L, 3);
        if (!path)
            path = ArgString(L, 2);
        if (path && GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES)
            return PushBool(L, 1);
        return PushBool(L, 0);
    }

    if (std::strcmp(name, "ReadFile") == 0) {
        const char* path = ArgString(L, 2);
        if (!path)
            return PushNil(L);
        HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE)
            return PushNil(L);
        DWORD size = GetFileSize(h, nullptr);
        if (size == INVALID_FILE_SIZE || size > 8 * 1024 * 1024) {
            CloseHandle(h);
            return PushNil(L);
        }
        std::string buf(size, '\0');
        DWORD read = 0;
        ReadFile(h, buf.data(), size, &read, nullptr);
        CloseHandle(h);
        buf.resize(read);
        return PushString(L, buf.c_str());
    }

    if (std::strcmp(name, "WriteFile") == 0) {
        const char* path = ArgString(L, 2);
        const char* content = ArgString(L, 3);
        if (!path || !content)
            return PushBool(L, 0);
        HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE)
            return PushBool(L, 0);
        DWORD written = 0;
        WriteFile(h, content, static_cast<DWORD>(std::strlen(content)), &written, nullptr);
        CloseHandle(h);
        return PushBool(L, 1);
    }

    if (std::strcmp(name, "TraceLine") == 0) {
        // limited without full numeric args — return true
        return PushBool(L, 1);
    }

    return PushNil(L);
}

static int __cdecl Lua_IsLinuxClient(lua_State* L) {
    const char* name = ArgString(L, 1);
    if (!name)
        return Dispatch(L, "GetRuntimeVersion");
    return Dispatch(L, name);
}

static int __cdecl Lua_RaijinLab_Runtime(lua_State* L) {
    return Lua_IsLinuxClient(L);
}

namespace Bridge {

const char* RuntimeVersion() {
    return kVersion;
}

bool RegisterLuaApi() {
    bool ok = false;
    __try {
        Functions::FrameScript_RegisterFunction("IsLinuxClient", reinterpret_cast<void*>(&Lua_IsLinuxClient));
        Functions::FrameScript_RegisterFunction("RaijinLab_Runtime", reinterpret_cast<void*>(&Lua_RaijinLab_Runtime));
        Console::Log("[RaijinLab] registered IsLinuxClient + RaijinLab_Runtime (%s)", kVersion);
        Functions::FrameScript_Execute(
            "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff7ec8e3RaijinLab|r runtime registered') end",
            "RaijinLab");
        ok = true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        Console::Log("[RaijinLab] RegisterLuaApi exception 0x%08lX", GetExceptionCode());
        ok = false;
    }
    return ok;
}

void OnPulse() {}

} // namespace Bridge
