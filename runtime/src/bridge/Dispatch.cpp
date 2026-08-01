#include "Ipc.h"
#include "Dispatch.h"
#include "lua/Lua.h"
#include "game/ObjectManager.h"
#include "game/Actions.h"
#include "game/TaintPatch.h"
#include "game/Offsets.h"
#include "game/AddressDB.h"
#include "game/MainThread.h"
#include "core/Config.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstring>
#include <string>
#include <cmath>
#include <atomic>

// Crash 2026-07-20: using 0x84F7A0 as lua_setfield was WRONG - that site is a
// taint/assert path (ERROR #134 / 0x85100086). Only FrameScript_RegisterFunction
// is safe for binding C functions (it uses pushcclosure + pushstring + insert + rawset).

namespace RL::Bridge {
namespace {

// Version string returned to addon only - keep short, no product brand.
// Bump whenever the live bridge behaviour changes so /raijin and inject logs
// prove which DLL is resident (1.8.9-objectfield still running = old inject).
const char* kVersion = "1.10.42-rebindfreeze";

using fnReg = void(__cdecl*)(const char*, void*);
using fnExec = void(__cdecl*)(const char*, const char*);

// Reject paths that would blow past MAX_PATH inside CreateFileA / attribute
// lookups, or contain path-traversal sequences. Also treated as a rejection
// when the caller did not pass a proper path argument (n<2 would previously
// hand `checkstring(L,1)`/`(L,0)` - the API name string or an invalid slot -
// to CreateFileA/GetFileAttributesA).
static bool IsSafePathArg(const char* s) {
    if (!s || !s[0]) return false;
    size_t len = std::strlen(s);
    if (len >= MAX_PATH) return false;
    if (std::strstr(s, "..\\") || std::strstr(s, "../")) return false;
    return true;
}

static int FS_FileExists(lua_State* L) {
    int n = RL::Lua::gettop(L);
    if (n < 2) return RL::Lua::PushBool(L, false);
    const char* path = nullptr;
    for (int i = n; i >= 2; --i) {
        const char* s = RL::Lua::checkstring(L, i);
        if (s && (std::strchr(s, ':') || std::strstr(s, "\\") || std::strstr(s, "/"))) {
            path = s;
            break;
        }
    }
    if (!path) path = RL::Lua::checkstring(L, n);
    if (!IsSafePathArg(path)) return RL::Lua::PushBool(L, false);
    return RL::Lua::PushBool(L, GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES);
}

static int FS_ReadFile(lua_State* L) {
    if (RL::Lua::gettop(L) < 2) return RL::Lua::PushNil(L);
    const char* path = RL::Lua::checkstring(L, 2);
    if (!IsSafePathArg(path)) return RL::Lua::PushNil(L);
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return RL::Lua::PushNil(L);
    DWORD sz = GetFileSize(h, nullptr);
    if (sz == INVALID_FILE_SIZE || sz > 16 * 1024 * 1024) { CloseHandle(h); return RL::Lua::PushNil(L); }
    std::string buf(sz, '\0');
    DWORD rd = 0;
    ReadFile(h, buf.data(), sz, &rd, nullptr);
    CloseHandle(h);
    buf.resize(rd);
    return RL::Lua::PushString(L, buf.c_str());
}

static int FS_WriteFile(lua_State* L) {
    if (RL::Lua::gettop(L) < 3) return RL::Lua::PushBool(L, false);
    const char* path = RL::Lua::checkstring(L, 2);
    const char* content = RL::Lua::checkstring(L, 3);
    if (!IsSafePathArg(path) || !content) return RL::Lua::PushBool(L, false);
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return RL::Lua::PushBool(L, false);
    DWORD wr = 0;
    WriteFile(h, content, (DWORD)std::strlen(content), &wr, nullptr);
    CloseHandle(h);
    return RL::Lua::PushBool(L, true);
}

// Append text to a file (create if absent). Cheap incremental logging: the dev
// log accumulates the full session on disk without rewriting. FILE_SHARE_READ so
// the log can be read live while the game holds it open.
static int FS_AppendFile(lua_State* L) {
    if (RL::Lua::gettop(L) < 3) return RL::Lua::PushBool(L, false);
    const char* path = RL::Lua::checkstring(L, 2);
    const char* content = RL::Lua::checkstring(L, 3);
    if (!IsSafePathArg(path) || !content) return RL::Lua::PushBool(L, false);
    HANDLE h = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return RL::Lua::PushBool(L, false);
    SetFilePointer(h, 0, nullptr, FILE_END);
    DWORD wr = 0;
    WriteFile(h, content, (DWORD)std::strlen(content), &wr, nullptr);
    CloseHandle(h);
    return RL::Lua::PushBool(L, true);
}

static int FS_DirExists(lua_State* L) {
    const char* path = RL::Lua::checkstring(L, 2);
    if (!path) path = RL::Lua::checkstring(L, 3);
    if (!path) return RL::Lua::PushBool(L, false);
    DWORD a = GetFileAttributesA(path);
    return RL::Lua::PushBool(L, a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY));
}

static int FS_CreateDir(lua_State* L) {
    const char* path = RL::Lua::checkstring(L, 2);
    if (!path) path = RL::Lua::checkstring(L, 3);
    if (!path) return RL::Lua::PushBool(L, false);
    return RL::Lua::PushBool(L, CreateDirectoryA(path, nullptr) || GetLastError() == ERROR_ALREADY_EXISTS);
}

static int FS_ListFiles(lua_State* L) {
    const char* pattern = RL::Lua::checkstring(L, 3);
    if (!pattern) pattern = RL::Lua::checkstring(L, 2);
    if (!pattern) return RL::Lua::PushNil(L);
    WIN32_FIND_DATAA fd{};
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return RL::Lua::PushString(L, "");
    std::string out;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
            if (!out.empty()) out.push_back('\n');
            out += fd.cFileName;
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return RL::Lua::PushString(L, out.c_str());
}

static int FS_ListDirs(lua_State* L) {
    const char* pattern = RL::Lua::checkstring(L, 3);
    if (!pattern) pattern = RL::Lua::checkstring(L, 2);
    if (!pattern) return RL::Lua::PushNil(L);
    WIN32_FIND_DATAA fd{};
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return RL::Lua::PushString(L, "");
    std::string out;
    do {
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            std::strcmp(fd.cFileName, ".") && std::strcmp(fd.cFileName, "..")) {
            if (!out.empty()) out.push_back('\n');
            out += fd.cFileName;
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return RL::Lua::PushString(L, out.c_str());
}

static std::string WowDir() {
    char path[MAX_PATH]{};
    GetModuleFileNameA(nullptr, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (slash) *slash = 0;
    return path;
}

// Parse a GUID from Lua stack slot `idx`.
// - Valid hex/decimal string or non-zero number -> that GUID
// - Absent / nil / empty -> 0 (caller may treat as "local player" for no-arg APIs)
// - Non-empty unparseable string -> 0, NEVER LocalGuid. Falling back to the local
//   player here made ObjectPosition("target") return the PLAYER position when
//   UnitGUID format failed to parse, so Distance was 0 and every spell looked
//   in-range from any distance.
static uint64_t GuidArg(lua_State* L, int idx) {
    int top = RL::Lua::gettop(L);
    if (idx < 1 || idx > top) return 0;
    const char* s = RL::Lua::checkstring(L, idx);
    if (s && s[0]) {
        // Skip the API name if someone passes the wrong index
        if (!std::strcmp(s, "ObjectPosition") || !std::strcmp(s, "ObjectFacing") ||
            !std::strcmp(s, "ObjectId") || !std::strcmp(s, "ObjectExists") ||
            !std::strcmp(s, "ObjectScale") || !std::strcmp(s, "ObjectTypeFlags") ||
            !std::strcmp(s, "ObjectDynamicFlags") || !std::strcmp(s, "ObjectIsType") ||
            !std::strcmp(s, "ObjectFlags") || !std::strcmp(s, "GameObjectBytes1") ||
            !std::strcmp(s, "IpcPoll") || !std::strcmp(s, "IpcReply") ||
            !std::strcmp(s, "ObjectCombatReach") || !std::strcmp(s, "ObjectBoundingRadius") ||
            !std::strcmp(s, "ObjectQuestGiverStatus") || !std::strcmp(s, "ObjectNpcFlags") ||
            !std::strcmp(s, "ObjectInstanceField") || !std::strcmp(s, "ObjectQuestGiverDiag")) {
            return 0;
        }
        // Unit token "player" is intentional local-player shorthand from Lua.
        if (!_stricmp(s, "player")) return RL::Game::OM::LocalGuid();
        // OTHER UNIT TOKENS ARE A KNOWN CASE, NOT A PARSE FAILURE.
        //
        // "target"/"focus"/... are not GUIDs and never will be; the caller is
        // expected to resolve them Lua-side (UnitGUID) before calling. Falling
        // through to the hex parser produced the right answer (0) but shouted
        // "GuidArg fail" about it, which buried real parse failures in noise -
        // and that noise is what had to be dug through to diagnose the live
        // facing failure. Return the same 0, quietly.
        if (!_stricmp(s, "target") || !_stricmp(s, "focus") ||
            !_stricmp(s, "mouseover") || !_stricmp(s, "pet") ||
            !_stricmp(s, "npc") || !_stricmp(s, "vehicle")) {
            return 0;
        }
        // Skip leading whitespace.
        while (*s == ' ' || *s == '\t') ++s;
        char* end = nullptr;
        unsigned long long g = strtoull(s, &end, 0);
        // Accept a full or prefix parse of a non-zero value.
        if (g && end && end != s) return static_cast<uint64_t>(g);
        // Pure hex without 0x prefix (some UnitGUID forms / OM variants).
        // base-0 treats bare digits as decimal and wrongly zeros high GUIDs.
        bool hexish = true;
        for (const char* p = s; *p; ++p) {
            char c = *p;
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
                hexish = false; break;
            }
        }
        if (hexish && std::strlen(s) >= 8) {
            g = strtoull(s, &end, 16);
            if (g && end && end != s) return static_cast<uint64_t>(g);
        }
        static int s_bad = 0;
        if (s_bad < 12) {
            RL::Log::Warn("GuidArg fail idx=%d s='%.48s'", idx, s);
            s_bad++;
        }
        return 0;
    }
    double n = RL::Lua::tonumber(L, idx);
    if (n != 0.0) return static_cast<uint64_t>(n);
    return 0;
}

// World-list snapshot (GetObjectCount / enum merge). Single-GUID field reads
// (ObjectPosition, ObjectQuestGiverStatus, ...) do NOT use this gate.
//
// Policy (1.8.13-om):
//   inject        -> om.enable forced 0 (cold; no world yet)
//   PEW arm       -> addon sets om.enable=1 (normal play: OM always on)
//   user kill     -> om.enable=0 via SetSystemVar / cfg
//   enum AV once  -> EnumIsDead(); list-only continues; enable stays 1
static bool OmEnabled() {
    return RL::Game::OM::IsEnabled();
}

// Single-return packed "x|y|z" - FrameScript multi-return is unreliable on this client
// (addon saw player=(0,0,0) while MainThread heartbeat had real coords).
static int PushPosPacked(lua_State* L, float x, float y, float z) {
    char buf[96];
    snprintf(buf, sizeof(buf), "%.3f|%.3f|%.3f", x, y, z);
    return RL::Lua::PushString(L, buf);
}

static RL::Game::Vec3 ResolveLocalPos() {
    // 1) Fresh pulse + snapshot (MainThread uses local-gated Position).
    RL::Game::MainThread::PulseFromMainThread();
    auto snap = RL::Game::MainThread::Get();
    // Reject half-null island snapshots (0, y) that used to poison navigation.
    if (std::fabs(snap.playerPos.x) >= 30.f && std::fabs(snap.playerPos.y) >= 30.f)
        return snap.playerPos;
    // 2) LocalPtr + local-gated multi-method read (camera agreement + fallback).
    uintptr_t lp = RL::Game::OM::LocalPtr();
    if (lp) {
        auto p = RL::Game::OM::PositionLocalFromPtr(lp);
        if (std::fabs(p.x) >= 30.f && std::fabs(p.y) >= 30.f) return p;
    }
    // 3) GUID path fallback (also local-gated via Position(guid)).
    uint64_t g = RL::Game::OM::LocalGuid();
    if (g) {
        auto p = RL::Game::OM::Position(g);
        if (std::fabs(p.x) >= 30.f && std::fabs(p.y) >= 30.f) return p;
    }
    return RL::Game::Vec3{};
}

// SEH-guarded single float read. Must live in its own function: __try cannot be
// used in a function that also needs C++ object unwinding (like Handle).
static float SafeReadFloatField(uintptr_t addr) {
    __try {
        return *reinterpret_cast<float*>(addr);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1.0f;
    }
}

// SEH-isolated raw ObjectPtr call for PosProbe (no C++ unwind objects).
static uintptr_t RawObjectPtrProbe(uint64_t guid) {
    using fn3 = uintptr_t(__cdecl*)(uint32_t, uint32_t, int);
    auto f = reinterpret_cast<fn3>(0x004D4DB0);
    uintptr_t rawPtr = 0;
    __try {
        rawPtr = f((uint32_t)guid, (uint32_t)(guid >> 32), -1);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        rawPtr = 0xFFFFFFFF;
    }
    return rawPtr;
}

// Read 3 floats at ptr+off under SEH for PosProbe diagnostics.
static int SafeReadXYZ(uintptr_t ptr, uintptr_t off, float* x, float* y, float* z) {
    *x = *y = *z = 0.f;
    if (!ptr) return 0;
    __try {
        float* v = reinterpret_cast<float*>(ptr + off);
        *x = v[0]; *y = v[1]; *z = v[2];
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

// SEH-isolated: MovementInfo* at +0xD8 and type dword at +0x14.
static void SafeReadObjMeta(uintptr_t ptr, uintptr_t* movPtr, uint32_t* type14) {
    *movPtr = 0;
    *type14 = 0;
    if (!ptr) return;
    __try {
        *movPtr = *reinterpret_cast<uintptr_t*>(ptr + 0xD8);
        *type14 = *reinterpret_cast<uint32_t*>(ptr + 0x14);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        *movPtr = 0;
        *type14 = 0;
    }
}

// SEH-isolated: descriptor pointer at object+0x08.
static uintptr_t SafeReadDescPtr(uintptr_t ptr) {
    if (!ptr) return 0;
    uintptr_t d = 0;
    __try {
        d = *reinterpret_cast<uintptr_t*>(ptr + 0x08);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        d = 0;
    }
    return d;
}

static int Handle(lua_State* L, const char* name) {
    // Verbose bridge trace (RL_LOG=1 -> Trace level). Skip ultra-hot pings by default.
    if (name && std::strcmp(name, "Ping") != 0 &&
        std::strcmp(name, "GetRuntimeVersion") != 0) {
        RL::Log::Trace("bridge call: %s", name);
    }
    using namespace RL::Game;
    using namespace RL::Lua;

    if (!name) return PushNil(L);

    if (!std::strcmp(name, "GetRuntimeVersion"))
        return PushString(L, kVersion);
    if (!std::strcmp(name, "Ping")) {
        // Lightweight main-thread pulse only (player GUID) - no Enum
        RL::Game::MainThread::PulseFromMainThread();
        return PushString(L, "pong");
    }

    if (!std::strcmp(name, "GetWoWDirectory")) return PushString(L, WowDir().c_str());
    if (!std::strcmp(name, "GetAppDirectory") || !std::strcmp(name, "GetAppStorageDirectory")) {
        char path[MAX_PATH]{};
        HMODULE self = nullptr;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)&Handle, &self);
        GetModuleFileNameA(self, path, MAX_PATH);
        char* slash = std::strrchr(path, '\\');
        if (slash) *slash = 0;
        return PushString(L, path);
    }
    if (!std::strcmp(name, "GetAppUsername")) {
        char user[256]{};
        DWORD n = 256;
        GetUserNameA(user, &n);
        return PushString(L, user);
    }
    if (!std::strcmp(name, "GetSystemVar")) {
        const char* key = checkstring(L, 2);
        if (!key) return PushNil(L);
        return PushString(L, RL::Config::Get(key).c_str());
    }
    if (!std::strcmp(name, "SetSystemVar")) {
        const char* key = checkstring(L, 2);
        const char* val = checkstring(L, 3);
        if (key) RL::Config::Set(key, val ? val : "");
        RL::Config::Flush();
        return PushBool(L, true);
    }
    if (!std::strcmp(name, "GetCurrentAccount")) return PushString(L, "");

    if (!std::strcmp(name, "FileExists")) return FS_FileExists(L);
    if (!std::strcmp(name, "ReadFile")) return FS_ReadFile(L);
    if (!std::strcmp(name, "WriteFile")) return FS_WriteFile(L);
    if (!std::strcmp(name, "AppendFile")) return FS_AppendFile(L);
    if (!std::strcmp(name, "DirectoryExists")) return FS_DirExists(L);
    if (!std::strcmp(name, "CreateDirectory")) return FS_CreateDir(L);
    if (!std::strcmp(name, "GetDirectoryFiles")) return FS_ListFiles(L);
    if (!std::strcmp(name, "GetDirectoryFolders")) return FS_ListDirs(L);
    if (!std::strcmp(name, "PlaySoundFile") || !std::strcmp(name, "LoadScript") ||
        !std::strcmp(name, "RunScript") || !std::strcmp(name, "SetCustomScript")) {
        // Intentionally no FrameScript_Execute from API for safety
        return PushBool(L, true);
    }

    // ---- OM (optional; can crash if mis-called - gated) ----
    if (!std::strcmp(name, "GetObjectCount")) {
        if (!OmEnabled()) return PushNumber(L, 0);
        // Cache TTL - do NOT force every frame (Manager OnUpdate was re-enuming at 40Hz)
        OM::Refresh(false);
        return PushNumber(L, (double)OM::Count());
    }
    // "Unit" and "Npc" are the same typed enumeration under two names. World.lua
    // asks for GetUnitCount/GetUnitWithIndex - the branch it calls "faster +
    // complete" - and the bridge only answered to GetNpc*. An unhandled command
    // returns nil, so `tonumber(nil or 0) or 0` was 0, `unit_n > 0` was false,
    // and the fast path never ran once: every scan silently took the slower,
    // less complete fallback. Accept both spellings.
    if (!std::strcmp(name, "GetNpcCount") || !std::strcmp(name, "GetUnitCount")) {
        if (!OmEnabled()) return PushNumber(L, 0);
        OM::Refresh(false);
        return PushNumber(L, (double)OM::Count(ObjectType::Unit));
    }
    if (!std::strcmp(name, "GetPlayerCount")) {
        if (!OmEnabled()) return PushNumber(L, 0);
        OM::Refresh(false);
        return PushNumber(L, (double)OM::Count(ObjectType::Player));
    }
    if (!std::strcmp(name, "GetGameObjectCount")) {
        if (!OmEnabled()) return PushNumber(L, 0);
        OM::Refresh(false);
        return PushNumber(L, (double)OM::Count(ObjectType::GameObject));
    }
    if (!std::strcmp(name, "GetDynamicObjectCount") || !std::strcmp(name, "GetAreaTriggerCount") ||
        !std::strcmp(name, "GetMissileCount"))
        return PushNumber(L, 0);

    auto pushGuid = [&](const OM::Object* o) -> int {
        if (!o) return PushNil(L);
        char buf[32];
        snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)o->guid);
        return PushString(L, buf);
    };

    if (!std::strcmp(name, "GetObjectWithIndex")) {
        if (!OmEnabled()) return PushNil(L);
        return pushGuid(OM::At((size_t)optnumber(L, 2, 1)));
    }
    if (!std::strcmp(name, "GetNpcWithIndex") || !std::strcmp(name, "GetUnitWithIndex")) {
        if (!OmEnabled()) return PushNil(L);
        return pushGuid(OM::AtType(ObjectType::Unit, (size_t)optnumber(L, 2, 1)));
    }
    if (!std::strcmp(name, "GetPlayerWithIndex")) {
        if (!OmEnabled()) return PushNil(L);
        return pushGuid(OM::AtType(ObjectType::Player, (size_t)optnumber(L, 2, 1)));
    }
    if (!std::strcmp(name, "GetGameObjectWithIndex")) {
        if (!OmEnabled()) return PushNil(L);
        return pushGuid(OM::AtType(ObjectType::GameObject, (size_t)optnumber(L, 2, 1)));
    }
    if (!std::strcmp(name, "GetDynamicObjectWithIndex") ||
        !std::strcmp(name, "GetAreaTriggerWithIndex") ||
        !std::strcmp(name, "GetMissileWithIndex"))
        return PushNil(L);

    if (!std::strcmp(name, "GetObject") || !std::strcmp(name, "GetObjectWithGUID"))
        return PushBool(L, OM::Exists(checkguid(L, 2)));
    if (!std::strcmp(name, "ObjectExists"))
        return PushBool(L, OM::Exists(GuidArg(L, 2)));
    if (!std::strcmp(name, "ObjectPosition")) {
        // Packed "x|y|z" only (FrameScript multi-return is unreliable here).
        //
        // PLAYER path (no arg / "player" / local GUID):
        //   Always ResolveLocalPos() via MainThread snapshot. Do NOT require
        //   LocalGuid()!=0 first - GuidArg("player")->LocalGuid() returning 0
        //   used to short-circuit to 0|0|0 and made /raijin dist show
        //   "player pos: nil" even with a live bridge.
        //
        // OTHER GUIDs: ClntObjMgrObjectPtr (no OM enum). Unparseable -> 0|0|0
        // (Lua nil). NEVER substitute the player for a bad target GUID.
        int top = RL::Lua::gettop(L);
        const char* arg = (top >= 2) ? RL::Lua::checkstring(L, 2) : nullptr;
        bool want_player = (top < 2) || !arg || !arg[0] || !_stricmp(arg, "player");

        uint64_t local = OM::LocalGuid();
        uint64_t g = 0;
        if (!want_player) {
            g = GuidArg(L, 2);
            if (g && local && g == local) want_player = true;
        }

        Vec3 p{};
        if (want_player) {
            p = ResolveLocalPos();
            return PushPosPacked(L, p.x, p.y, p.z);
        }

        if (!g) {
            // Present arg but not a parseable GUID -> failure (not player).
            return PushPosPacked(L, 0.f, 0.f, 0.f);
        }
        p = OM::Position(g);
        return PushPosPacked(L, p.x, p.y, p.z);
    }
    // Diagnostic: how position resolution is failing (for /raijin dist).
    if (!std::strcmp(name, "PosProbe")) {
        RL::Game::MainThread::PulseFromMainThread();
        uint64_t lg = OM::LocalGuid();
        uintptr_t lp = OM::LocalPtr();
        uintptr_t rawPtr = lg ? RawObjectPtrProbe(lg) : 0;
        // Prefer raw ObjectPtr if LocalPtr still lags; multi-method pos read.
        uintptr_t usePtr = lp ? lp : rawPtr;
        Vec3 multiPos = usePtr ? OM::PositionFromPtr(usePtr) : Vec3{};
        Vec3 lpPos = lg ? OM::Position(lg) : multiPos;
        if ((lpPos.x == 0.f && lpPos.y == 0.f) && (multiPos.x != 0.f || multiPos.y != 0.f))
            lpPos = multiPos;
        uint64_t tg = 0;
        if (RL::Lua::gettop(L) >= 2) tg = GuidArg(L, 2);
        uintptr_t tp = tg ? OM::Ptr(tg) : 0;
        Vec3 tpPos = tg ? OM::Position(tg) : Vec3{};
        float rx = 0, ry = 0, rz = 0;
        if (usePtr) SafeReadXYZ(usePtr, 0x798, &rx, &ry, &rz);
        float mx = 0, my = 0, mz = 0;
        if (usePtr) SafeReadXYZ(usePtr, 0xD8 + 0x0C, &mx, &my, &mz);
        uintptr_t movPtr = 0;
        uint32_t type14 = 0;
        SafeReadObjMeta(usePtr, &movPtr, &type14);
        char layout[64]{};
        OM::PosLayoutDiag(layout, sizeof(layout));
        float pReach = usePtr ? OM::CombatReachFromPtr(usePtr) : 0.f;
        float pBound  = usePtr ? OM::BoundingRadiusFromPtr(usePtr) : 0.f;
        float tReach = tp ? OM::CombatReachFromPtr(tp) : 0.f;
        float u7d0 = usePtr ? SafeReadFloatField(usePtr + 0x7D0) : -1.f;
        float u7d4 = usePtr ? SafeReadFloatField(usePtr + 0x7D4) : -1.f;
        uintptr_t desc = SafeReadDescPtr(usePtr);
        float d108 = desc ? SafeReadFloatField(desc + 0x108) : -1.f;
        float d10c = desc ? SafeReadFloatField(desc + 0x10C) : -1.f;
        char buf[960];
        snprintf(buf, sizeof(buf),
            "lg=0x%llX|lp=0x%lX|raw=0x%lX|type14=0x%X|movPtr=0x%lX|"
            "pos=%.2f,%.2f,%.2f|raw798=%.2f,%.2f,%.2f|inlMov=%.2f,%.2f,%.2f|"
            "%s|reach=%.2f|bound=%.2f|u7d0=%.2f|u7d4=%.2f|d108=%.2f|d10c=%.2f|"
            "tg=0x%llX|tp=0x%lX|tpos=%.2f,%.2f,%.2f|tReach=%.2f",
            (unsigned long long)lg, (unsigned long)lp, (unsigned long)rawPtr,
            (unsigned)type14, (unsigned long)movPtr,
            lpPos.x, lpPos.y, lpPos.z, rx, ry, rz, mx, my, mz,
            layout, pReach, pBound, u7d0, u7d4, d108, d10c,
            (unsigned long long)tg, (unsigned long)tp,
            tpPos.x, tpPos.y, tpPos.z, tReach);
        RL::Log::Warn("PosProbe %s", buf);
        return PushString(L, buf);
    }
    // Combat reach / bounding radius (hitbox radius, yards).
    // Descriptor-authoritative (UNIT_FIELD_*); Trinity defaults when field is 0.
    // Same GUID rules as ObjectPosition. "player" / missing GUID -> local unit.
    if (!std::strcmp(name, "ObjectCombatReach") || !std::strcmp(name, "ObjectBoundingRadius")) {
        int top = RL::Lua::gettop(L);
        const char* arg = (top >= 2) ? RL::Lua::checkstring(L, 2) : nullptr;
        uint64_t g = 0;
        bool want_player = (top < 2 || !arg || !arg[0] || !_stricmp(arg, "player"));
        if (want_player) {
            g = OM::LocalGuid();
        } else {
            g = GuidArg(L, 2);
        }
        uintptr_t ptr = 0;
        if (want_player) {
            ptr = OM::LocalPtr();
            if (!ptr && g) ptr = OM::Ptr(g);
        } else if (g) {
            ptr = OM::Ptr(g);
        }
        if (!ptr) return PushNumber(L, -1.0);
        // Correct today, but the same fragile shape as the PitchUp/PitchDown
        // off-by-two below: say what is meant, so a renamed command cannot
        // silently flip the branch.
        bool combat = std::strstr(name, "CombatReach") != nullptr;
        float r = combat ? OM::CombatReachFromPtr(ptr) : OM::BoundingRadiusFromPtr(ptr);
        return PushNumber(L, (double)r);
    }
    // One-shot diagnostic: everything /raijin om needs in a single string return.
    if (!std::strcmp(name, "OmProbe") || !std::strcmp(name, "GetOmStatus")) {
        // Never force om.enable=1 during post-reload hard freeze — it would
        // immediately unblock SoftRefresh/Refresh the instant the freeze
        // expires, before FrameXML has finished settling.
        if (OM::IsEnabled()) {
            RL::Config::Set("om.enable", "1");
        } else {
            RL::Log::Info("OmProbe deferring om.enable=1 (OM frozen)");
        }
        RL::Config::Flush();
        RL::Game::MainThread::PulseFromMainThread();
        auto snap = RL::Game::MainThread::Get();
        Vec3 p = ResolveLocalPos();
        if (p.x == 0.f && p.y == 0.f && snap.playerGuid)
            p = OM::Position(snap.playerGuid);

        size_t objs = 0, units = 0, players = 0, gobs = 0;
        // Always Refresh when we have a player: list-only still populates counts
        // after enumvis has latched dead (1.8.13 fix).
        if (snap.playerGuid || snap.playerPtr) {
            OM::Refresh(true);
            objs = OM::Count();
            units = OM::Count(ObjectType::Unit);
            players = OM::Count(ObjectType::Player);
            gobs = OM::Count(ObjectType::GameObject);
            OM::LogTypeSamples(8);
        }
        const char* enumState = "ok";
        if (!snap.playerGuid && !snap.playerPtr) enumState = "no-player";
        else if (OM::EnumIsDead()) enumState = "list-only";
        std::string st = OM::StatusPacked();
        char buf[512];
        snprintf(buf, sizeof(buf),
                 "player=%.3f,%.3f,%.3f|guid=0x%llX|ptr=0x%lX|objects=%zu|npcs=%zu|"
                 "players=%zu|gameobjects=%zu|enum=%s|enable=%s|%s",
                 p.x, p.y, p.z,
                 (unsigned long long)snap.playerGuid,
                 (unsigned long)snap.playerPtr,
                 objs, units, players, gobs, enumState,
                 OmEnabled() ? "1" : "0", st.c_str());
        RL::Log::Info("OmProbe %s", buf);
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "NearbyUnits")) {
        // NEVER gate on OmEnabled — rotation multi-dot must see units with no
        // client target even while suite freezes om.enable. Soft list-only inside.
        float range = (float)optnumber(L, 2, 80.0);
        double maxN = optnumber(L, 3, 12.0);
        if (range < 5.f) range = 5.f;
        if (range > 200.f) range = 200.f;
        if (maxN < 1) maxN = 1;
        if (maxN > 32) maxN = 32;
        auto s = OM::NearbyUnitsPacked(range, (size_t)maxN);
        return PushString(L, s.c_str());
    }
    // Rotation hostiles: one call, snapshot fields, no nameplates / Unit*.
    // Format: n|0xGUID:entry:x:y:z:center:edge:flags:hp:mhp|...
    // CRITICAL: do NOT gate on OmEnabled — that made multi-dot blind and forced
    // mouseover/target Unit* crutches (instant only while hovering).
    if (!std::strcmp(name, "NearbyHostiles") || !std::strcmp(name, "GetNearbyHostiles")) {
        float range = (float)optnumber(L, 2, 40.0);
        double maxN = optnumber(L, 3, 32.0);
        if (range < 3.f) range = 3.f;
        if (range > 100.f) range = 100.f;
        if (maxN < 1) maxN = 1;
        if (maxN > 48) maxN = 48;
        auto s = OM::NearbyHostilesPacked(range, (size_t)maxN);
        return PushString(L, s.c_str());
    }
    // Runtime-first multi-dot: units that pass basic castability + aura filter.
    // Args: range, spellId, state(0=missing 1=present), maxN
    // Format: n|0xGUID:entry:center:edge:face:hp:mhp|...
    if (!std::strcmp(name, "AuraSearch") || !std::strcmp(name, "FindAuraSearch")) {
        float range = (float)optnumber(L, 2, 40.0);
        int spellId = (int)optnumber(L, 3, 0.0);
        int state = (int)optnumber(L, 4, 0.0); // 0 missing, 1 present
        double maxN = optnumber(L, 5, 8.0);
        if (range < 3.f) range = 3.f;
        if (range > 100.f) range = 100.f;
        if (maxN < 1) maxN = 1;
        if (maxN > 16) maxN = 16;
        auto s = OM::AuraSearchPacked(range, spellId, state == 0, (size_t)maxN);
        return PushString(L, s.c_str());
    }
    // CLEU / cast evidence → runtime aura table (GUID authority for multi-dot).
    if (!std::strcmp(name, "NoteUnitAura")) {
        uint64_t g = GuidArg(L, 2);
        int spellId = (int)optnumber(L, 3, 0.0);
        int stacks = (int)optnumber(L, 4, 1.0);
        float dur = (float)optnumber(L, 5, 21.0);
        if (g && spellId > 0) OM::NoteUnitAura(g, spellId, stacks, dur);
        return PushBool(L, true);
    }
    if (!std::strcmp(name, "ClearUnitAura")) {
        uint64_t g = GuidArg(L, 2);
        int spellId = (int)optnumber(L, 3, 0.0);
        if (g && spellId > 0) OM::ClearUnitAura(g, spellId);
        return PushBool(L, true);
    }
    if (!std::strcmp(name, "HasUnitAura")) {
        uint64_t g = GuidArg(L, 2);
        int spellId = (int)optnumber(L, 3, 0.0);
        int stacks = 0;
        bool has = g && spellId > 0 && OM::HasUnitAura(g, spellId, &stacks);
        if (!has) return PushNumber(L, 0);
        return PushNumber(L, stacks > 0 ? stacks : 1);
    }
    if (!std::strcmp(name, "ObjectFacing"))
        // Facing needs NO OM enumeration, exactly like ObjectPosition: OM::Facing
        // resolves via OM::Ptr -> SafeObjectPtr -> ClntObjMgrObjectPtr (the direct
        // GUID->ptr hash, SEH + page-commit checked), independent of the periodic
        // OM visible-object walk. The old `OmEnabled() ? ... : 0` gate short-circuited
        // to a literal 0 with OM off, which made steering run fully open-loop (the
        // Navigator could never read the character's true heading to close the turn
        // loop). Now every caller gets the real angle whether OM is on or off.
        return PushNumber(L, OM::Facing(GuidArg(L, 2)));
    if (!std::strcmp(name, "TraceLine")) {
        // World collision raycast against the client's own geometry (OM::TraceLine
        // -> CGWorldFrame_C_Intersect at Offsets::F().WorldIntersect). Args:
        // x1,y1,z1, x2,y2,z2, [flags]. Default flags = TRACE_LOS (terrain|WMO|M2).
        // Returns a packed "blocked|hx|hy|hz" string (multi-return is unreliable
        // on this client - see ObjectPosition): blocked=1 when solid geometry lies
        // between the endpoints; hx,hy,hz is the hit point (the endpoint when clear).
        Vec3 s{ (float)optnumber(L, 2, 0.0), (float)optnumber(L, 3, 0.0), (float)optnumber(L, 4, 0.0) };
        Vec3 e{ (float)optnumber(L, 5, 0.0), (float)optnumber(L, 6, 0.0), (float)optnumber(L, 7, 0.0) };
        uint32_t flags = (uint32_t)optnumber(L, 8, (double)Offsets::TRACE_LOS);
        Vec3 hit = e;
        // blocked field is now tri-state: 0 clear, 1 blocked, -1 could not tell.
        // It used to pack a thrown raycast as blocked=1 with an unwritten hit
        // point, so a sensor failure was indistinguishable from a wall and the
        // coordinates were garbage.
        int rc = OM::TraceLineEx(s, e, &hit, flags);
        int blocked = (rc == 1) ? 0 : ((rc == 0) ? 1 : -1);
        char buf[96];
        snprintf(buf, sizeof(buf), "%d|%.3f|%.3f|%.3f", blocked, hit.x, hit.y, hit.z);
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "GetCameraData")) {
        // Raw camera fields for a Lua world->screen projection. Packed
        // "px|py|pz|fx|fy|fz|rx|ry|rz|ux|uy|uz|fov" (position, view-matrix rows,
        // FOV). Nil when the camera isn't readable.
        OM::CamData c = OM::CameraData();
        if (!c.ok) return PushNil(L);
        char buf[256];
        snprintf(buf, sizeof(buf),
            "%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.5f|%.5f|%.5f|%.5f|%.5f|%.5f|%.6f",
            c.pos.x, c.pos.y, c.pos.z,
            c.fwd.x, c.fwd.y, c.fwd.z,
            c.right.x, c.right.y, c.right.z,
            c.up.x, c.up.y, c.up.z, c.fov);
        return PushString(L, buf);
    }
    // ObjectPtr field reads - never gate on om.enable (enum is a separate path).
    if (!std::strcmp(name, "ObjectId"))
        return PushNumber(L, (double)OM::Entry(GuidArg(L, 2)));
    if (!std::strcmp(name, "ObjectScale"))
        return PushNumber(L, (double)OM::Scale(GuidArg(L, 2)));
    // AN ENUM IS NOT A BITMASK.
    //
    // This returned OM::Type() - the ObjectType ENUM (3 = Unit, 5 = GameObject) -
    // for ObjectTypeFlags, which the addon reads as the FLAGS bitmask in
    // RaijinLab.enums.ObjectTypeFlags (API.lua): Object=1, Unit=32, Player=64,
    // GameObject=256.
    //
    // So every npc answered 3, and RunObjectManager's classifier computed
    // band(3,64)=0 (not player), band(3,256)=0 (not gameobject), band(3,32)=0
    // (NOT A UNIT EITHER). Every object fell through unclassified and
    // object_list.npcs stayed empty forever - "95 units from the bridge but the
    // engine snapshot is EMPTY (armed=true om_frame=true)". Questing was blind:
    // no givers, no objectives, fall through to a belief-field beeline.
    //
    // A value that is in range and confident and means something else entirely -
    // the same trap as a stub answering 0. Return the mask the caller's own enum
    // defines. Players carry Unit too, so `Unit and not Player` still selects
    // npcs exactly as the classifier intends.
    if (!std::strcmp(name, "ObjectTypeFlags")) {
        int mask = 1;                                   // Object
        switch (OM::Type(GuidArg(L, 2))) {
            case ObjectType::Item:          mask |= 2;            break;
            case ObjectType::Container:     mask |= 2 | 4;        break;
            case ObjectType::Unit:          mask |= 32;           break;
            case ObjectType::Player:        mask |= 32 | 64;      break;
            case ObjectType::GameObject:    mask |= 256;          break;
            case ObjectType::DynamicObject: mask |= 512;          break;
            case ObjectType::Corpse:        mask |= 1024;         break;
            default:                                              break;
        }
        return PushNumber(L, (double)mask);
    }
    // ObjectIsType keeps the RAW enum - different question, different answer.
    if (!std::strcmp(name, "ObjectIsType"))
        return PushNumber(L, (double)(int)OM::Type(GuidArg(L, 2)));
    if (!std::strcmp(name, "ObjectDynamicFlags"))
        return PushNumber(L, (double)OM::DynamicFlags(GuidArg(L, 2)));
    // ObjectFlags reads the FLAGS field for whatever type this object is
    // (GAMEOBJECT_FLAGS vs UNIT_FIELD_FLAGS - different offsets, see Offsets.h).
    // The addon previously derived gameobject flags from a descriptor-name table
    // that is nil unless the client exposes it, so the value was simply absent.
    if (!std::strcmp(name, "ObjectFlags"))
        return PushNumber(L, (double)OM::ObjectFlags(GuidArg(L, 2)));
    // GAMEOBJECT_BYTES_1: [0]=state [1]=type [2]=artKit [3]=animProgress.
    // The TYPE byte identifies chests/goobers/questgivers with no dependence on
    // GAMEOBJECT_DYNAMIC, so it still answers if this server never sets it.
    if (!std::strcmp(name, "GameObjectBytes1"))
        return PushNumber(L, (double)OM::GameObjectBytes1(GuidArg(L, 2)));
    // IPC PUMP. The pipe thread only ever queues strings; these two run on the
    // GAME'S MAIN THREAD because the addon calls them from its OnUpdate. That is
    // what makes driving the client from outside safe - nothing off-thread ever
    // touches Lua or the object manager.
    if (!std::strcmp(name, "IpcPoll")) {
        unsigned id = 0;
        std::string code = RL::Ipc::Poll(&id);
        if (id == 0) return PushNil(L);
        PushNumber(L, (double)id);
        RL::Lua::pushstring(L, code.c_str());
        return 2;
    }
    if (!std::strcmp(name, "IpcReply")) {
        unsigned id = (unsigned)RL::Lua::tonumber(L, 2);
        const char* txt = RL::Lua::tolstring(L, 3, nullptr);
        RL::Ipc::Reply(id, txt ? txt : "");
        return PushBool(L, true);
    }
    // ObjectField = descriptor field (update-fields). NOT CGObject instance layout.
    // DialogStatus is on the instance at +0x90 - use ObjectInstanceField / ObjectQuestGiverStatus.
    //
    // CRITICAL: these are ObjectPtr + memory reads. They must NOT gate on OmEnabled().
    // Inject forces om.enable=0 (enum is the crash vector); ArmRuntimeSystems also
    // forces 0. Gating status behind OmEnabled made every giver read as 0 and diag
    // print err=om_off while standing next to a lit ! NPC (live 1.8.11 repro).
    if (!std::strcmp(name, "ObjectField"))
        return PushNumber(L, (double)OM::Field(
            GuidArg(L, 2), (uint32_t)RL::Lua::optnumber(L, 3, 0)));
    if (!std::strcmp(name, "ObjectInstanceField"))
        return PushNumber(L, (double)OM::InstanceField(
            GuidArg(L, 2), (uint32_t)RL::Lua::optnumber(L, 3, 0)));

    // REAL client field CGObject+0x90 (SetQuestGiverStatus / SMSG_QUESTGIVER_STATUS).
    // Not a heuristic. See ObjectManager.cpp::QuestGiverStatus for the RE chain.
    // No OmEnabled gate - ObjectPtr works with enum off.
    if (!std::strcmp(name, "ObjectQuestGiverStatus"))
        return PushNumber(L, (double)OM::QuestGiverStatus(GuidArg(L, 2)));
    if (!std::strcmp(name, "ObjectQuestGiverDiag")) {
        char prefix[48];
        snprintf(prefix, sizeof(prefix), "om=%s|", OmEnabled() ? "on" : "off");
        std::string d = prefix;
        d += OM::QuestGiverDiag(GuidArg(L, 2));
        return PushString(L, d.c_str());
    }
    if (!std::strcmp(name, "ObjectNpcFlags") || !std::strcmp(name, "UnitNpcFlags"))
        return PushNumber(L, (double)OM::NpcFlags(GuidArg(L, 2)));

    // STILL UNIMPLEMENTED - AND THEY SAY SO, IN THE ONLY WAY LUA UNDERSTANDS.
    //
    // These used to answer a hardcoded 0 with a comment asking callers to "treat
    // 0 as unknown, never as no". That instruction cannot be followed: **0 is
    // TRUTHY in Lua**, so `if RaijinLab:ObjectIsQuestObjective(o) then` is TRUE
    // for every object in the world. A comment cannot fix a value that lies -
    // this exact shape has produced five separate live defects in this project,
    // ObjectQuestGiverStatus being the one that made questing impossible.
    //
    // nil is the honest answer for "not implemented": it is falsy, so every
    // truth test reads correctly as "no answer", and any arithmetic on it fails
    // LOUDLY at the call site instead of silently computing with a fake zero.
    if (!std::strcmp(name, "ObjectDescriptor") ||
        !std::strcmp(name, "GameObjectType") || !std::strcmp(name, "ObjectIsQuestObjective"))
        return PushNil(L);
    // IMPLEMENTED IN C++ ALL ALONG, STUBBED AT THE BRIDGE.
    //
    // OM::IsFacing / IsBehind / Distance / DistancePos / CameraPosition are all
    // real, working functions in ObjectManager.cpp. The dispatch nevertheless
    // answered `false` / `0` for every one of them, so every Lua caller got a
    // confident wrong answer instead of the value sitting one call away. The
    // rotation's "am I behind the target?" checks and every distance query
    // routed through the bridge have been reading these zeros.
    if (!std::strcmp(name, "ObjectIsFacing") || !std::strcmp(name, "IsFacingGuid")
        || !std::strcmp(name, "UnitIsInFront")) {
        // a = viewer (default player), b = target, [half-angle radians]
        // Default half-angle π/2 = WotLK HasInArc(M_PI) unit-target face check
        // (full 180° front hemisphere). NOT a narrow 90° aim cone.
        uint64_t a = GuidArg(L, 2), b = GuidArg(L, 3);
        if (!a) a = OM::LocalGuid();
        // Allow ObjectIsFacing(targetGuid) with single arg = player->that unit.
        if (!b && a && a != OM::LocalGuid()) {
            b = a;
            a = OM::LocalGuid();
        }
        if (!a || !b) return PushNil(L);          // no answer, not "not facing"
        double arc = RL::Lua::optnumber(L, 4, 1.5707963267948966); // π/2
        return PushBool(L, OM::IsFacing(a, b, (float)arc));
    }
    if (!std::strcmp(name, "ObjectIsBehind")) {
        uint64_t a = GuidArg(L, 2), b = GuidArg(L, 3);
        if (!a) a = OM::LocalGuid();
        if (!a || !b) return PushNil(L);
        return PushBool(L, OM::IsBehind(a, b));
    }
    if (!std::strcmp(name, "GetDistanceBetweenObjects")) {
        uint64_t a = GuidArg(L, 2), b = GuidArg(L, 3);
        if (!a) a = OM::LocalGuid();
        if (!a || !b) return PushNil(L);
        return PushNumber(L, (double)OM::Distance(a, b));
    }
    if (!std::strcmp(name, "GetDistanceBetweenPositions")) {
        Vec3 p{ (float)RL::Lua::optnumber(L, 2, 0), (float)RL::Lua::optnumber(L, 3, 0),
                (float)RL::Lua::optnumber(L, 4, 0) };
        Vec3 q{ (float)RL::Lua::optnumber(L, 5, 0), (float)RL::Lua::optnumber(L, 6, 0),
                (float)RL::Lua::optnumber(L, 7, 0) };
        return PushNumber(L, (double)OM::DistancePos(p, q));
    }
    if (!std::strcmp(name, "GetAnglesBetweenObjects")) {
        uint64_t a = GuidArg(L, 2), b = GuidArg(L, 3);
        if (!a) a = OM::LocalGuid();
        if (!a || !b) return PushNil(L);
        Vec3 pa = OM::Position(a), pb = OM::Position(b);
        double yaw = std::atan2((double)pb.y - pa.y, (double)pb.x - pa.x);
        if (yaw < 0) yaw += 6.283185307179586;
        double dxy = std::sqrt(((double)pb.x - pa.x) * ((double)pb.x - pa.x) +
                               ((double)pb.y - pa.y) * ((double)pb.y - pa.y));
        double pitch = std::atan2((double)pb.z - pa.z, dxy);
        pushnumber(L, yaw);
        pushnumber(L, pitch);
        return 2;
    }
    if (!std::strcmp(name, "GetCameraPosition")) {
        Vec3 c = OM::CameraPosition();
        return PushXYZ(L, c.x, c.y, c.z);
    }
    // Pure geometry. Convention matches the unlocked-API family these names come
    // from: "between" walks `dist` yards from the first point toward the second
    // (clamped to the segment); "from" walks `dist` yards along `angle`.
    if (!std::strcmp(name, "GetPositionBetweenPositions") ||
        !std::strcmp(name, "GetPositionBetweenObjects")) {
        Vec3 p, q; double dist;
        if (!std::strcmp(name, "GetPositionBetweenObjects")) {
            uint64_t a = GuidArg(L, 2), b = GuidArg(L, 3);
            if (!a) a = OM::LocalGuid();
            if (!a || !b) return PushNil(L);
            p = OM::Position(a); q = OM::Position(b);
            dist = RL::Lua::optnumber(L, 4, 0);
        } else {
            p = Vec3{ (float)RL::Lua::optnumber(L, 2, 0), (float)RL::Lua::optnumber(L, 3, 0),
                      (float)RL::Lua::optnumber(L, 4, 0) };
            q = Vec3{ (float)RL::Lua::optnumber(L, 5, 0), (float)RL::Lua::optnumber(L, 6, 0),
                      (float)RL::Lua::optnumber(L, 7, 0) };
            dist = RL::Lua::optnumber(L, 8, 0);
        }
        double len = (double)OM::DistancePos(p, q);
        if (len < 1e-6) return PushXYZ(L, p.x, p.y, p.z);
        double t = dist / len;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        return PushXYZ(L, (float)(p.x + (q.x - p.x) * t),
                          (float)(p.y + (q.y - p.y) * t),
                          (float)(p.z + (q.z - p.z) * t));
    }
    if (!std::strcmp(name, "GetPositionFromPosition")) {
        double x = RL::Lua::optnumber(L, 2, 0), y = RL::Lua::optnumber(L, 3, 0);
        double z = RL::Lua::optnumber(L, 4, 0);
        double dist = RL::Lua::optnumber(L, 5, 0), ang = RL::Lua::optnumber(L, 6, 0);
        double pitch = RL::Lua::optnumber(L, 7, 0);
        double horiz = dist * std::cos(pitch);
        return PushXYZ(L, (float)(x + horiz * std::cos(ang)),
                          (float)(y + horiz * std::sin(ang)),
                          (float)(z + dist * std::sin(pitch)));
    }
    if (!std::strcmp(name, "GetAllSpanningCircles"))
        return PushNil(L);   // genuinely unimplemented: nil, never a fake 0,0,0

    // Same rule as above: unimplemented numerics answer nil, not a fake 0.
    // UnitCasting/UnitChannel are the sharpest of these - a 0 there reads to the
    // rotation as "casting spell 0", i.e. permanently busy, because 0 is truthy.
    if (!std::strcmp(name, "UnitFlags") || !std::strcmp(name, "UnitCreator") ||
        !std::strcmp(name, "UnitTarget") || !std::strcmp(name, "UnitCasting") ||
        !std::strcmp(name, "UnitChannel") || !std::strcmp(name, "UnitPitch") ||
        !std::strcmp(name, "UnitMovementFlags") || !std::strcmp(name, "UnitCreatureTypeId") ||
        !std::strcmp(name, "UnitCreatureFamilyId") || !std::strcmp(name, "UnitCreatureField") ||
        !std::strcmp(name, "UnitCastingTarget") || !std::strcmp(name, "UnitTransport") ||
        !std::strcmp(name, "GetAuraCount") || !std::strcmp(name, "GetNoClipModes") ||
        !std::strcmp(name, "ReadMemory") || !std::strcmp(name, "GetMemoryOffset"))
        return PushNil(L);
    if (!std::strcmp(name, "UnitBoundingRadius")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        float r = OM::BoundingRadius(g);
        return PushNumber(L, r > 0.f ? (double)r : 0.5);
    }
    if (!std::strcmp(name, "UnitCombatReach")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        float r = OM::CombatReach(g);
        return PushNumber(L, r > 0.f ? (double)r : 1.5);
    }
    // Object-manager unit fields by GUID (no unit token / nameplate required).
    // Critical for multi-dot and enemies_in_range when nameplateN tokens do not
    // exist on this client unless the cursor is over the unit.
    if (!std::strcmp(name, "ObjectUnitFlags")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) return PushNumber(L, 0.0);
        return PushNumber(L, (double)OM::UnitFlags(g));
    }
    if (!std::strcmp(name, "ObjectHealth")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) return PushNumber(L, 0.0);
        return PushNumber(L, (double)OM::Health(g));
    }
    if (!std::strcmp(name, "ObjectMaxHealth")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) return PushNumber(L, 0.0);
        return PushNumber(L, (double)OM::MaxHealth(g));
    }
    // ---- Unit power / combat from descriptor (no Lua/Blizzard API) ---------
    if (!std::strcmp(name, "UnitPower")) {
        uint64_t g = GuidArg(L, 2);
        int pt = (int)optnumber(L, 3, 0.0);
        if (!g) g = OM::LocalGuid();
        return PushNumber(L, (double)OM::UnitPower(g, pt));
    }
    if (!std::strcmp(name, "UnitMaxPower")) {
        uint64_t g = GuidArg(L, 2);
        int pt = (int)optnumber(L, 3, 0.0);
        if (!g) g = OM::LocalGuid();
        return PushNumber(L, (double)OM::UnitMaxPower(g, pt));
    }
    if (!std::strcmp(name, "UnitPowerType")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        return PushNumber(L, (double)OM::UnitPowerType(g));
    }
    if (!std::strcmp(name, "UnitInCombat")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        int v = OM::UnitCombatState(g);
        if (v < 0) return PushNil(L);
        return PushBool(L, v == 1);
    }
    if (!std::strcmp(name, "PlayerCastState")) {
        int sid = -1, total = 0, elapsed = 0;
        OM::PlayerCastState(&sid, &total, &elapsed);
        if (sid < 0) return PushString(L, "0|0|0");
        char buf[48];
        snprintf(buf, sizeof(buf), "%d|%d|%d", sid, total, elapsed);
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "IsUnitMounted")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        int v = OM::IsUnitMounted(g);
        if (v < 0) return PushNil(L);
        return PushBool(L, v == 1);
    }
    if (!std::strcmp(name, "UnitMovementImpairing")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        int v = OM::UnitMovementImpairing(g);
        return PushNumber(L, (double)v);
    }
    if (!std::strcmp(name, "PlayerState")) {
        auto s = OM::PlayerStatePacked();
        return PushString(L, s.c_str());
    }
    // Unit target GUID from descriptor UNIT_FIELD_TARGET (verified 0x48)
    if (!std::strcmp(name, "UnitTargetGuid")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) g = OM::LocalGuid();
        uint64_t tgt = OM::UnitTargetGuid(g);
        if (!tgt) return PushNil(L);
        char buf[24];
        snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)tgt);
        return PushString(L, buf);
    }
    // Shapeshift form (0=normal, 1=bear, 2=aquatic, 3=cat, 4=travel, 5=moonkin, 6=flight)
    if (!std::strcmp(name, "ShapeshiftForm") || !std::strcmp(name, "GetShapeshiftForm")) {
        int form = OM::ShapeshiftForm();
        return PushNumber(L, (double)form);
    }
    // Unit relationship (faction-based): "self","friendly","hostile","neutral","unknown"
    if (!std::strcmp(name, "UnitRelationship")) {
        uint64_t g = GuidArg(L, 2);
        if (!g) return PushString(L, "unknown");
        return PushString(L, OM::UnitRelationship(g));
    }
    // Spell info packed: "maxRange=F|castMs=N|powerType=N|school=N"
    if (!std::strcmp(name, "SpellInfo") || !std::strcmp(name, "GetSpellInfo")) {
        int spellId = (int)optnumber(L, 2, 0);
        auto s = OM::SpellInfoPacked(spellId);
        return PushString(L, s.c_str());
    }
    // Map/zone info via Lua GetMapInfo pcall (cached 500ms — map rarely changes)
    if (!std::strcmp(name, "GetCurrentMapInfo")) {
        static char s_mapBuf[128] = {};
        static ULONGLONG s_mapAt = 0;
        ULONGLONG now = GetTickCount64();
        if (!s_mapAt || (now - s_mapAt) > 500ull) {
            s_mapAt = now;
            RL::Lua::MapInfoFromLua(s_mapBuf, sizeof(s_mapBuf));
        }
        return PushString(L, s_mapBuf[0] ? s_mapBuf : "mapId=?|mapName=?|zoneId=?|zoneName=?");
    }
    if (!std::strcmp(name, "UnitIsLootable") || !std::strcmp(name, "UnitIsSkinnable") ||
        !std::strcmp(name, "UnitIsMounted") ||
        !std::strcmp(name, "StopFalling") || !std::strcmp(name, "CancelPendingSpell") ||
        !std::strcmp(name, "IsAoEPending") || !std::strcmp(name, "EnableFlyingMode") ||
        !std::strcmp(name, "IsFlyingModeEnabled") || !std::strcmp(name, "SetNoClipModes") ||
        !std::strcmp(name, "SetClimbAngle") || !std::strcmp(name, "IsMapLoaded") ||
        !std::strcmp(name, "MapExists") || !std::strcmp(name, "IsPacketLoggerEnabled"))
        return PushBool(L, false);
    if (!std::strcmp(name, "GetAuraWithIndex")) return PushNil(L);

    // nil, not (0,0): a fake screen coordinate is indistinguishable from a real
    // one at the top-left corner, so anything that trusted it would draw there.
    // The addon does its own projection (Drawing.lua) and has no caller here.
    if (!std::strcmp(name, "WorldToScreen")) return PushNil(L);
    // CTM / ClickToMove FORBIDDEN project-wide. Keyboard Navigator only.
    if (!std::strcmp(name, "MoveTo") || !std::strcmp(name, "ClickPosition") ||
        !std::strcmp(name, "ClickToMove")) {
        RL::Log::Warn("MoveTo/CTM refused (forbidden); use keyboard Navigator");
        return PushBool(L, false);
    }
    // ---- ALL protected-ish actions: runtime only (never FrameScript from addon Lua) ----
    // ONE PARSER, NOT TWO.
    //
    // This lambda re-implemented GuidArg with different token handling: GuidArg
    // maps "player" to the local GUID, this mapped it to 0. Two parsers for the
    // same argument in the same dispatch file is how a caller ends up getting a
    // different answer depending on which branch it landed in - and it is why
    // `interact_honest` passed live while `facing_wired` failed on the SAME bad
    // input: this one turned the token into 0 and fell through to
    // InteractTarget(), which happened to be right, while GuidArg's 0 correctly
    // refused to answer. A green check for the wrong reason is worse than a red.
    //
    // Delegate the parsing. The token policy stays explicit and unchanged here:
    // interact deliberately treats "player"/"target" as "use the current
    // target", which is NOT what an object query should do.
    auto parseGuidArg = [&](int idx) -> uint64_t {
        const char* gs = checkstring(L, idx);
        if (gs && gs[0]) {
            if (!_stricmp(gs, "target") || !_stricmp(gs, "player") ||
                !_stricmp(gs, "focus") || !_stricmp(gs, "mouseover") ||
                !_stricmp(gs, "pet")) {
                return 0; // token - interact falls through to InteractTarget()
            }
        }
        return GuidArg(L, idx);
    };

    // True when stack arg looks like an intentional GUID that FAILED to parse.
    // Never demote those to guid=0 (current-target) cast.
    // CRITICAL: lua may tostring number 0 → "0". That is intentional no-guid
    // (Consecration / ground), NOT a bad GUID. Live 2026-07-31: s='0' refused
    // every Consecration wire (CastSpellEx refuse bad_guid id=26573).
    auto guidArgWasIntended = [&](int idx) -> bool {
        const char* gs = checkstring(L, idx);
        if (!gs || !gs[0]) {
            double n = optnumber(L, idx, 0.0);
            return n != 0.0;
        }
        if (!_stricmp(gs, "target") || !_stricmp(gs, "player") ||
            !_stricmp(gs, "focus") || !_stricmp(gs, "mouseover") ||
            !_stricmp(gs, "pet") || !_stricmp(gs, "npc") ||
            !_stricmp(gs, "vehicle")) {
            return false; // token → 0 is intentional
        }
        // Explicit zero forms ("0", "0x0", "0x000...") = no unit, not a failure.
        char* end = nullptr;
        unsigned long long v = strtoull(gs, &end, 0);
        if (end && end != gs && *end == '\0' && v == 0ull)
            return false;
        bool hexish = true;
        for (const char* p = gs; *p; ++p) {
            char c = *p;
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                  (c >= 'A' && c <= 'F') || c == 'x' || c == 'X')) {
                hexish = false;
                break;
            }
        }
        if (hexish) {
            const char* body = gs;
            if (body[0] == '0' && (body[1] == 'x' || body[1] == 'X')) body += 2;
            v = strtoull(body, &end, 16);
            if (end && end != body && v == 0ull)
                return false;
        }
        return true; // non-zero-looking or unparseable garbage
    };

    if (!std::strcmp(name, "CastSpell") || !std::strcmp(name, "CastSpellByID") ||
        !std::strcmp(name, "SpellCast")) {
        int spellId = (int)optnumber(L, 2, 0);
        if (spellId <= 0) return PushBool(L, false);
        uint64_t g = parseGuidArg(3);
        // Multi-dot / melee: refuse rather than cast on current target when a
        // GUID was supplied but failed to parse.
        if (g == 0 && guidArgWasIntended(3)) {
            RL::Log::Warn("CastSpell refuse bad_guid id=%d", spellId);
            return PushBool(L, false);
        }
        RL::Log::Info("CastSpell request id=%d guid=0x%llX",
                      spellId, (unsigned long long)g);
        RL::Game::MainThread::PulseFromMainThread();
        Actions::SetCurrentLuaState(L);
        bool ok = Actions::CastSpell(spellId, g);
        Actions::SetCurrentLuaState(nullptr);
        RL::Log::Info("CastSpell result id=%d ok=%d", spellId, (int)ok);
        return PushBool(L, ok);
    }
    // Structured cast path: "1|ok" or "0|facing|los|oor|not_ready|cast_fail|..."
    // flags: 1=FACE_IF_NEEDED, 4=SKIP_IF_NOT_FACING, 8=CHECK_LOS
    if (!std::strcmp(name, "CastSpellEx") || !std::strcmp(name, "CastSpellGuid")) {
        int spellId = (int)optnumber(L, 2, 0);
        uint64_t g = parseGuidArg(3);
        uint32_t flags = (uint32_t)optnumber(L, 4, 0.0);
        if (spellId <= 0) return PushString(L, "0|no_spell");
        if (g == 0 && guidArgWasIntended(3)) {
            RL::Log::Warn("CastSpellEx refuse bad_guid id=%d", spellId);
            return PushString(L, "0|bad_guid");
        }
        RL::Game::MainThread::PulseFromMainThread();
        Actions::SetCurrentLuaState(L);
        auto r = Actions::CastSpellEx(spellId, g, flags);
        Actions::SetCurrentLuaState(nullptr);
        char buf[80];
        if (!r.ok && r.reason && !std::strcmp(r.reason, "cooldown") && r.cooldownMs > 0.0) {
            snprintf(buf, sizeof(buf), "0|cooldown|%.0f", r.cooldownMs);
        } else {
            snprintf(buf, sizeof(buf), "%d|%s", r.ok ? 1 : 0, r.reason ? r.reason : "?");
        }
        // Trace-only success; Warn refuses (was Info every cast → I/O lag under RL_LOG).
        if (!r.ok) {
            static int s_refuseLog = 0;
            if (s_refuseLog < 24) {
                RL::Log::Info("CastSpellEx refuse id=%d guid=0x%llX -> %s",
                              spellId, (unsigned long long)g, buf);
                s_refuseLog++;
            }
        } else {
            RL::Log::Trace("CastSpellEx id=%d guid=0x%llX flags=%u -> %s",
                           spellId, (unsigned long long)g, (unsigned)flags, buf);
        }
        return PushString(L, buf);
    }
    // Precise spell cooldown remaining (ms) from C++ → Lua GetSpellCooldown pcall.
    // Returns "remaining_ms|duration_ms" or "0|0" when ready. Never triggers
    // client error frames. Read-only — no cast attempt.
    if (!std::strcmp(name, "SpellCooldownMs")) {
        int spellId = (int)optnumber(L, 2, 0);
        if (spellId <= 0) return PushString(L, "0|0");
        double rem = RL::Lua::SpellCooldownMs(L, spellId);
        char buf[48];
        snprintf(buf, sizeof(buf), "%.0f", rem);
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "CanCast")) {
        int spellId = (int)optnumber(L, 2, 0);
        uint64_t g = parseGuidArg(3);
        uint32_t flags = (uint32_t)optnumber(L, 4, 0.0);
        auto r = Actions::CanCast(spellId, g, flags);
        char buf[64];
        snprintf(buf, sizeof(buf), "%d|%s", r.ok ? 1 : 0, r.reason ? r.reason : "?");
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "FaceTowardGuid") || !std::strcmp(name, "FaceGuid")) {
        uint64_t g = parseGuidArg(2);
        return PushBool(L, g && Actions::FaceTowardGuid(g));
    }
    if (!std::strcmp(name, "IsFacingGuid")) {
        uint64_t g = parseGuidArg(2);
        float arc = (float)optnumber(L, 3, 1.5707963);
        return PushBool(L, g && Actions::IsFacingGuid(g, arc));
    }
    // Diagnostic: player guid/ptr for cast debugging
    if (!std::strcmp(name, "DiagPlayer")) {
        RL::Game::MainThread::PulseFromMainThread();
        auto s = RL::Game::MainThread::Get();
        char buf[128];
        snprintf(buf, sizeof(buf), "guid=0x%llX ptr=0x%p valid=%d",
                 (unsigned long long)s.playerGuid, (void*)s.playerPtr, (int)s.valid);
        return PushString(L, buf);
    }
    if (!std::strcmp(name, "Target") || !std::strcmp(name, "TargetGuid") ||
        !std::strcmp(name, "TargetUnit") || !std::strcmp(name, "TargetToken")) {
        const char* raw = checkstring(L, 2);
        // Unit tokens first (nameplate1, target, boss1, ...) — most reliable.
        if (raw && raw[0]) {
            bool looks_token = false;
            if (!std::strcmp(raw, "target") || !std::strcmp(raw, "focus")
                || !std::strcmp(raw, "mouseover") || !std::strcmp(raw, "pet")
                || !std::strcmp(raw, "player") || !std::strcmp(raw, "npc"))
                looks_token = true;
            else if (std::strncmp(raw, "nameplate", 9) == 0
                     || std::strncmp(raw, "boss", 4) == 0
                     || std::strncmp(raw, "party", 5) == 0
                     || std::strncmp(raw, "raid", 4) == 0
                     || std::strncmp(raw, "arena", 5) == 0)
                looks_token = true;
            else if (std::strstr(raw, "target") != nullptr) // targettarget etc.
                looks_token = true;
            if (looks_token)
                return PushBool(L, Actions::TargetToken(raw));
        }
        uint64_t g = parseGuidArg(2);
        if (!g) {
            const char* nm = checkstring(L, 2);
            if (nm && nm[0])
                return PushBool(L, Actions::TargetByName(nm));
            return PushBool(L, Actions::ClearTarget());
        }
        // GUID path: also try as hex TargetUnit if token path not used.
        return PushBool(L, Actions::TargetGuid(g));
    }
    if (!std::strcmp(name, "TargetByName")) {
        const char* nm = checkstring(L, 2);
        return PushBool(L, nm && Actions::TargetByName(nm));
    }
    if (!std::strcmp(name, "TargetToken")) {
        const char* tok = checkstring(L, 2);
        return PushBool(L, tok && Actions::TargetToken(tok));
    }
    if (!std::strcmp(name, "ClearTarget"))
        return PushBool(L, Actions::ClearTarget());
    if (!std::strcmp(name, "TargetLastTarget"))
        return PushBool(L, Actions::TargetLastTarget());
    if (!std::strcmp(name, "Attack") || !std::strcmp(name, "AttackTarget") ||
        !std::strcmp(name, "StartAttack"))
        return PushBool(L, Actions::AttackTarget());
    if (!std::strcmp(name, "StopAttack"))
        return PushBool(L, Actions::StopAttack());
    if (!std::strcmp(name, "Interact") || !std::strcmp(name, "ObjectInteract") ||
        !std::strcmp(name, "InteractUnit")) {
        uint64_t g = parseGuidArg(2);
        if (g) return PushBool(L, Actions::InteractGuid(g));
        return PushBool(L, Actions::InteractTarget());
    }
    if (!std::strcmp(name, "InteractTarget"))
        return PushBool(L, Actions::InteractTarget());
    if (!std::strcmp(name, "Jump"))
        return PushBool(L, Actions::Jump());
    // Held swim-up: must NOT share "Jump" - Jump is a one-shot land hop.
    if (!std::strcmp(name, "AscendStart") || !std::strcmp(name, "JumpOrAscendStart"))
        return PushBool(L, Actions::Ascend(true));
    if (!std::strcmp(name, "AscendStop"))
        return PushBool(L, Actions::Ascend(false));
    if (!std::strcmp(name, "DescendStart") || !std::strcmp(name, "SitStandOrDescendStart"))
        return PushBool(L, Actions::Descend(true));
    if (!std::strcmp(name, "DescendStop"))
        return PushBool(L, Actions::Descend(false));
    if (!std::strcmp(name, "StopMoving"))
        return PushBool(L, Actions::StopMoving());
    if (!std::strcmp(name, "MoveForwardStart")) return PushBool(L, Actions::MoveForward(true));
    if (!std::strcmp(name, "MoveForwardStop"))  return PushBool(L, Actions::MoveForward(false));
    if (!std::strcmp(name, "MoveBackwardStart")) return PushBool(L, Actions::MoveBackward(true));
    if (!std::strcmp(name, "MoveBackwardStop"))  return PushBool(L, Actions::MoveBackward(false));
    if (!std::strcmp(name, "StrafeLeftStart")) return PushBool(L, Actions::StrafeLeft(true));
    if (!std::strcmp(name, "StrafeLeftStop"))  return PushBool(L, Actions::StrafeLeft(false));
    if (!std::strcmp(name, "StrafeRightStart")) return PushBool(L, Actions::StrafeRight(true));
    if (!std::strcmp(name, "StrafeRightStop"))  return PushBool(L, Actions::StrafeRight(false));
    if (!std::strcmp(name, "TurnLeftStart")) return PushBool(L, Actions::TurnLeft(true));
    if (!std::strcmp(name, "TurnLeftStop"))  return PushBool(L, Actions::TurnLeft(false));
    if (!std::strcmp(name, "TurnRightStart")) return PushBool(L, Actions::TurnRight(true));
    if (!std::strcmp(name, "TurnRightStop"))  return PushBool(L, Actions::TurnRight(false));
    // Mouselook / camera-yaw analog steering (the human turn).
    if (!std::strcmp(name, "MouselookStart")) return PushBool(L, Actions::MouselookStart());
    if (!std::strcmp(name, "MouselookStop"))  return PushBool(L, Actions::MouselookStop());
    if (!std::strcmp(name, "IsMouselooking")) return PushNumber(L, Actions::IsMouselooking());
    if (!std::strcmp(name, "CameraYaw"))      return PushNumber(L, Actions::CameraYaw());
    if (!std::strcmp(name, "CameraTargetYaw")) return PushNumber(L, Actions::CameraTargetYaw());
    if (!std::strcmp(name, "SetCameraYaw"))   return PushBool(L, Actions::SetCameraYaw((float)optnumber(L, 2, 0)));
    if (!std::strcmp(name, "CommitMovement")) return PushBool(L, Actions::CommitMovement());
    if (!std::strcmp(name, "MouseMove"))
        return PushBool(L, Actions::MouseMove((int)optnumber(L, 2, 0), (int)optnumber(L, 3, 0)));
    // In-process yaw turn (no OS mouse / cursor capture). + = left/CCW, radians.
    if (!std::strcmp(name, "TurnByDelta")) return PushBool(L, Actions::TurnByDelta((float)optnumber(L, 2, 0)));
    if (!std::strcmp(name, "PlayerFacing")) return PushNumber(L, Actions::PlayerFacing());
    if (!std::strcmp(name, "SpellStopCasting") || !std::strcmp(name, "StopCasting"))
        return PushBool(L, Actions::SpellStopCasting());
    if (!std::strcmp(name, "ArmUnlock") || !std::strcmp(name, "UnlockActions")) {
        // FULL taint bypass, applied HERE and kept applied for the session.
        //
        // This was hardware-gates only, with the note "never full Taint::Apply
        // (that froze clients)". The freeze was about WHERE, not WHAT: the
        // earlier attempts ran from the WORKER thread, binary-patching code the
        // main thread was executing at that moment - a race, and it hung.
        // Dispatch::Handle is invoked from Lua, so it IS the main thread;
        // patching from here cannot race the interpreter that is calling us.
        //
        // Half a bypass is its own bug: with only the hardware gates the addon
        // still taints the execution context, the client reports "RaijinLab
        // tainted the call of the secure function", and protected calls the bot
        // legitimately needs are refused. Apply() is idempotent; Restore() runs
        // on unload.
        Actions::ArmUnlock();
        if (!RL::Game::Taint::IsApplied()) {
            bool ok = RL::Game::Taint::Apply();
            RL::Log::Info("taint: full bypass %s (%d patches)",
                          ok ? "APPLIED" : "FAILED", RL::Game::Taint::PatchCount());
        }
        return PushBool(L, true);
    }
    if (!std::strcmp(name, "ExecSecure") || !std::strcmp(name, "RunSecure")) {
        const char* code = checkstring(L, 2);
        return PushBool(L, code && Actions::ExecSecure(code));
    }
    if (!std::strcmp(name, "FaceDirection")) {
        return PushBool(L, Actions::FaceDirection((float)optnumber(L, 2, 0)));
    }
    if (!std::strcmp(name, "ResetAfk")) {
        OM::ResetAfk();
        return PushBool(L, true);
    }
    // Real pitch input (hold-style, keyboard semantics). Args: (start).
    // NEVER DISCRIMINATE START/STOP BY A MAGIC CHARACTER INDEX.
    //
    // This read `name[7] == 'a'` for PitchUp, intending the 'a' of "St[a]rt" -
    // but that 'a' is at index 9, and index 7 is 'S' in BOTH "PitchUpStart" and
    // "PitchUpStop". So both spellings passed `false` and **PitchUp could never
    // be started**; PitchDown had the identical off-by-two at index 9 ('S' in
    // both). Swim depth control has therefore never worked, while every layer
    // above it - Navigator.swim_control, swim_hold_plan, the edge-tracked pitch
    // holds - was correct and testable and green.
    //
    // The index is invisible in review and silently wrong for any name whose
    // length changes. Match the suffix instead: it states the intent, and it
    // cannot drift.
    const bool wantStart = std::strstr(name, "Start") != nullptr;
    if (!std::strcmp(name, "PitchUpStart") || !std::strcmp(name, "PitchUpStop"))
        return PushBool(L, Actions::PitchUp(wantStart));
    if (!std::strcmp(name, "PitchDownStart") || !std::strcmp(name, "PitchDownStop"))
        return PushBool(L, Actions::PitchDown(wantStart));

    // SetPitch is NOT IMPLEMENTED as an absolute setter - returning true made it
    // a lying stub: the addon got a success for a call that did nothing, so swim
    // depth control looked implemented while the character never pitched. nil is
    // the honest answer until an absolute setter exists; callers wanting pitch
    // use the hold-style PitchUp/Down commands above.
    if (!std::strcmp(name, "SetPitch")) return PushNil(L);
    // Same class of lying stub, kept only because ZERO callers exist today
    // (wrappers only) - do not add callers that trust this true.
    if (!std::strcmp(name, "SetCameraDistanceMax") ||
        !std::strcmp(name, "SetNameplateDistanceMax") || !std::strcmp(name, "SetCVarEx"))
        return PushBool(L, true);
    if (!std::strcmp(name, "GetKeyState"))
        return PushBool(L, OM::GetKeyState((int)optnumber(L, 2, 0)));

    // tables / nav / net stubs
    if (!std::strcmp(name, "LoadMap") || !std::strcmp(name, "UnloadMap") || !std::strcmp(name, "FindPath") ||
        !std::strcmp(name, "GetClosestPositionOnMesh") || !std::strcmp(name, "GetClosestMeshPolygon") ||
        !std::strcmp(name, "GetMeshPolygons") || !std::strcmp(name, "GetMeshPolygonFlags") ||
        !std::strcmp(name, "SetMeshPolygonFlags") || !std::strcmp(name, "GetMeshPolygonVertices") ||
        !std::strcmp(name, "GetMeshTile") || !std::strcmp(name, "GetCurrentMapInfo") ||
        !std::strcmp(name, "SendHttpRequest") || !std::strcmp(name, "ReceiveHttpRequest") ||
        !std::strcmp(name, "ConnectWebsocket") || !std::strcmp(name, "CloseWebSocket") ||
        !std::strcmp(name, "SendWebsocketData") || !std::strcmp(name, "EnablePacketLogger") ||
        !std::strcmp(name, "GetPacketOpcodes") || !std::strcmp(name, "GetObjectDescriptorsTable") ||
        !std::strcmp(name, "GetObjectFieldsTable") || !std::strcmp(name, "GetObjectTypeFlagsTable") ||
        !std::strcmp(name, "GetObjectQuestGiverStatusesTable") || !std::strcmp(name, "GetUnitMovementFlagsTable") ||
        !std::strcmp(name, "GetValueTypesTable"))
        return PushNil(L);

    return PushNil(L);
}

// Bind policy (1.10.40-reloadsafe):
//   Worker Register() is the ONLY FrameScript_RegisterFunction call.
//   First Lua_IsLinuxClient only marks sealed — we are ALREADY the bound
//   function. 1.10.39 force-re-reg on seal ~20ms after seed mid-/reload =
//   hard client death (log ends at SEAL).
//   g_noRegUntil blocks ANY Register during FrameXML rebind quiet.
static std::atomic<bool> g_main_sealed{false};
static ULONGLONG g_noRegUntil = 0;
static CRITICAL_SECTION g_regCs;
static std::atomic<bool> g_regCsInit{false};
static int __cdecl Lua_IsLinuxClient(lua_State* L); // forward

static void EnsureRegCs() {
    bool expected = false;
    if (g_regCsInit.compare_exchange_strong(expected, true)) {
        InitializeCriticalSection(&g_regCs);
    }
}

static int SafeRegisterNative() {
    EnsureRegCs();
    EnterCriticalSection(&g_regCs);
    ULONGLONG now = GetTickCount64();
    if (g_noRegUntil && now < g_noRegUntil) {
        LeaveCriticalSection(&g_regCs);
        return -2; // rebind quiet — not AV
    }
    auto reg = reinterpret_cast<fnReg>(RL::Game::Offsets::F().FrameScript_RegisterFunction);
    if (!reg) reg = reinterpret_cast<fnReg>(0x00817F90);
    if (!reg) {
        LeaveCriticalSection(&g_regCs);
        return 0;
    }
    int rc;
    __try {
        reg("IsLinuxClient", (void*)&Lua_IsLinuxClient);
        rc = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        rc = -(int)GetExceptionCode();
    }
    LeaveCriticalSection(&g_regCs);
    return rc;
}

static int __cdecl Lua_IsLinuxClient(lua_State* L) {
    // Already our cclosure — binding works. NEVER RegisterFunction here.
    if (!g_main_sealed.load(std::memory_order_acquire)) {
        g_main_sealed.store(true, std::memory_order_release);
        RL::Log::Warn("bridge SEAL (no re-reg) L=%p ver=%s", (void*)L, kVersion);
    }

    const char* name = RL::Lua::checkstring(L, 1);
    if (!name || !std::strcmp(name, "Ping") || !std::strcmp(name, "GetRuntimeVersion") ||
        !std::strcmp(name, "CastSpell") || !std::strcmp(name, "CastSpellByID") ||
        !std::strcmp(name, "ArmUnlock")) {
        RL::Game::MainThread::PulseFromMainThread();
    } else if (OmEnabled()) {
        RL::Game::MainThread::PulseFromMainThread();
    }
    if (!name) return Handle(L, "GetRuntimeVersion");
    return Handle(L, name);
}

} // namespace

void ResetRegistrationState() {
    EnsureRegCs();
    EnterCriticalSection(&g_regCs);
    g_main_sealed.store(false, std::memory_order_release);
    // Block seed until FrameXML settles after L change /reload.
    g_noRegUntil = GetTickCount64() + 2500ull;
    LeaveCriticalSection(&g_regCs);
}

int Dispatch(lua_State* L) { return Lua_IsLinuxClient(L); }

const char* Version() { return kVersion; }

bool Register(bool force) {
    (void)force;
    int rc = SafeRegisterNative();
    if (rc == 1) {
        RL::Log::Warn("Register OK seed L=%p ver=%s",
                      RL::Game::Addr::LuaState(), kVersion);
        return true;
    }
    if (rc == -2) {
        RL::Log::Info("Register deferred (rebind quiet)");
        return false;
    }
    RL::Log::Warn("Register seed failed rc=%d", rc);
    return false;
}

} // namespace RL::Bridge
