#include "Lua.h"
#include "game/AddressDB.h"
#include "game/Offsets.h"
#include "game/ObjectManager.h"
#include "game/Actions.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cmath>

namespace RL::Lua {
namespace {

using gettop_t = int(__cdecl*)(lua_State*);
using tolstring_t = const char*(__cdecl*)(lua_State*, int, size_t*);
using tonumber_t = double(__cdecl*)(lua_State*, int);
using pushnumber_t = void(__cdecl*)(lua_State*, double);
using pushstring_t = void(__cdecl*)(lua_State*, const char*);
using pushboolean_t = void(__cdecl*)(lua_State*, int);
using pushnil_t = void(__cdecl*)(lua_State*);
using toboolean_t = int(__cdecl*)(lua_State*, int);
using settop_t = void(__cdecl*)(lua_State*, int);
using pcall_t = int(__cdecl*)(lua_State*, int, int, int);
using getfield_t = void(__cdecl*)(lua_State*, int, const char*);

gettop_t p_gettop = nullptr;
tolstring_t p_tolstring = nullptr;
tonumber_t p_tonumber = nullptr;
pushnumber_t p_pushnumber = nullptr;
pushstring_t p_pushstring = nullptr;
pushboolean_t p_pushboolean = nullptr;
pushnil_t p_pushnil = nullptr;
toboolean_t p_toboolean = nullptr;
settop_t p_settop = nullptr;
pcall_t p_pcall = nullptr;
getfield_t p_getfield = nullptr;
bool g_ready = false;

}

void Init() {
    using namespace RL::Game::Addr;
    // Prefer AddressDB (full SDK table) over pattern table
    p_gettop = reinterpret_cast<gettop_t>(lua_gettop);
    p_tolstring = reinterpret_cast<tolstring_t>(lua_tolstring);
    p_tonumber = reinterpret_cast<tonumber_t>(lua_tonumber);
    p_pushnumber = reinterpret_cast<pushnumber_t>(lua_pushnumber);
    p_pushstring = reinterpret_cast<pushstring_t>(lua_pushstring);
    p_pushboolean = reinterpret_cast<pushboolean_t>(lua_pushboolean);
    p_pushnil = reinterpret_cast<pushnil_t>(lua_pushnil);
    p_toboolean = reinterpret_cast<toboolean_t>(lua_toboolean);
    p_settop = reinterpret_cast<settop_t>(lua_settop);
    p_pcall = reinterpret_cast<pcall_t>(lua_pcall);
    p_getfield = reinterpret_cast<getfield_t>(lua_getfield);
    g_ready = p_gettop && p_tolstring && p_pushstring && p_pushnumber && p_pushnil;
    RL::Log::Info("lua api ready=%d L*=%p gettop=%p pushnil=%p pcall=%p getfield=%p",
                  (int)g_ready, RL::Game::Addr::LuaState(), p_gettop, p_pushnil, p_pcall, p_getfield);
}

bool Ready() { return g_ready; }

int gettop(lua_State* L) { return p_gettop ? p_gettop(L) : 0; }
const char* tolstring(lua_State* L, int idx, size_t* len) {
    return p_tolstring ? p_tolstring(L, idx, len) : nullptr;
}
double tonumber(lua_State* L, int idx) { return p_tonumber ? p_tonumber(L, idx) : 0.0; }
void pushnumber(lua_State* L, double n) { if (p_pushnumber) p_pushnumber(L, n); }
void pushstring(lua_State* L, const char* s) { if (p_pushstring) p_pushstring(L, s ? s : ""); }
void pushboolean(lua_State* L, int b) { if (p_pushboolean) p_pushboolean(L, b); }
void pushnil(lua_State* L) {
    if (p_pushnil) p_pushnil(L);
    else if (p_pushnumber) p_pushnumber(L, 0);
}

const char* checkstring(lua_State* L, int idx) { return tolstring(L, idx, nullptr); }
double optnumber(lua_State* L, int idx, double def) {
    if (idx > gettop(L)) return def;
    return tonumber(L, idx);
}

uint64_t checkguid(lua_State* L, int idx) {
    const char* s = checkstring(L, idx);
    if (s && s[0]) return static_cast<uint64_t>(strtoull(s, nullptr, 0));
    return static_cast<uint64_t>(tonumber(L, idx));
}

int PushString(lua_State* L, const char* s) { pushstring(L, s); return 1; }
int PushNumber(lua_State* L, double n) { pushnumber(L, n); return 1; }
int PushBool(lua_State* L, bool v) {
    if (p_pushboolean) { pushboolean(L, v ? 1 : 0); return 1; }
    return PushNumber(L, v ? 1.0 : 0.0);
}
int PushNil(lua_State* L) { pushnil(L); return 1; }

int PushXYZ(lua_State* L, float x, float y, float z) {
    if (p_pushnumber) {
        pushnumber(L, x);
        pushnumber(L, y);
        pushnumber(L, z);
        return 3;
    }
    char buf[96];
    snprintf(buf, sizeof(buf), "%.6f,%.6f,%.6f", x, y, z);
    return PushString(L, buf);
}

// LUA_GLOBALSINDEX for Lua 5.1
static constexpr int kGlobals = -10002;

double SpellCooldownMs(lua_State* L, int spellId) {
    if (!L || !p_getfield || !p_pcall || !p_pushnumber || !p_tonumber || !p_settop || spellId <= 0)
        return -1.0; // sentinel: cannot determine

    static bool s_first = true;
    int top = 0;
    __try {
        top = p_gettop(L);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        if (s_first) { RL::Log::Warn("SpellCooldownMs: gettop AV"); s_first = false; }
        return -1.0;
    }

    // 1) GetSpellCooldown(spellId) → start, duration (game-time seconds)
    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "GetSpellCooldown");
        p_pushnumber(L, (double)spellId);
        rc = p_pcall(L, 1, 2, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        if (s_first) { RL::Log::Warn("SpellCooldownMs: getfield/pcall AV (func ptrs invalid for build)"); s_first = false; }
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return -1.0;
    }
    if (rc != 0) {
        if (s_first) { RL::Log::Warn("SpellCooldownMs: GetSpellCooldown pcall rc=%d", rc); s_first = false; }
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return -1.0;
    }

    double start = 0.0, duration = 0.0;
    __try {
        start    = p_tonumber(L, -2);
        duration = p_tonumber(L, -1);
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1.0;
    }
    if (duration <= 0.0) return 0.0; // no cooldown on this spell

    // 2) GetTime() → current game-time seconds (same clock as GetSpellCooldown)
    __try {
        p_getfield(L, kGlobals, "GetTime");
        rc = p_pcall(L, 0, 1, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return -1.0;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return -1.0; }

    double now = 0.0;
    __try {
        now = p_tonumber(L, -1);
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1.0;
    }

    double end = start + duration;
    if (now >= end) return 0.0; // cooldown expired
    double rem = (end - now) * 1000.0;
    if (s_first) {
        RL::Log::Info("SpellCooldownMs OK id=%d start=%.3f dur=%.3f now=%.3f rem=%.0fms",
                      spellId, start, duration, now, rem);
        s_first = false;
    }
    return rem; // remaining milliseconds
}

// ---- IsSpellInRange / IsSpellUsable — PURE C++ memory reads ---------------
// ZERO Lua pcall. Spell range passed from Lua's cached spell_meta.
// Only ObjectManager descriptor reads + SoftHardwareUnlock.

int IsSpellInRangeRuntime(lua_State* L, int spellId, float maxRange) {
    (void)L;
    if (spellId <= 0) return -1;

    // DIAG: disable SoftHardwareUnlock to isolate crash source
    // RL::Game::Actions::SoftHardwareUnlock();

    if (maxRange <= 0.f) maxRange = 5.0f;

    uint64_t localGuid = RL::Game::OM::LocalGuid();
    if (!localGuid) return -1;
    RL::Game::Vec3 pPos = RL::Game::OM::Position(localGuid);
    if (pPos.x == 0.f && pPos.y == 0.f && pPos.z == 0.f) return -1;

    uint64_t targetGuid = RL::Game::OM::UnitTargetGuid(localGuid);
    if (!targetGuid) return -1;
    RL::Game::Vec3 tPos = RL::Game::OM::Position(targetGuid);
    if (tPos.x == 0.f && tPos.y == 0.f && tPos.z == 0.f) return -1;

    float dx = pPos.x - tPos.x;
    float dy = pPos.y - tPos.y;
    float center = sqrtf(dx * dx + dy * dy);
    float pReach = RL::Game::OM::CombatReach(localGuid);
    if (pReach <= 0.f) pReach = 1.5f;
    float tReach = RL::Game::OM::CombatReach(targetGuid);
    if (tReach <= 0.f) tReach = 1.5f;
    float edge = center - pReach - tReach;
    if (edge < 0.f) edge = 0.f;

    return (edge <= maxRange + 0.05f) ? 1 : 0;
}

int IsSpellUsableRuntime(lua_State* L, int spellId, int* outNomana) {
    (void)L;
    if (outNomana) *outNomana = 0;
    if (spellId <= 0) return -1;

    // DIAG: disable SoftHardwareUnlock
    // RL::Game::Actions::SoftHardwareUnlock();

    uint64_t localGuid = RL::Game::OM::LocalGuid();
    if (!localGuid) return -1;

    // Check all power types for resource starvation
    for (int pt = 0; pt <= 7; ++pt) {
        int maxPower = RL::Game::OM::UnitMaxPower(localGuid, pt);
        if (maxPower > 0) {
            int curPower = RL::Game::OM::UnitPower(localGuid, pt);
            if (curPower == 0 && outNomana) { *outNomana = 1; break; }
        }
    }

    return 1;
}

double GameTimeFromLua(lua_State* L) {
    if (!L || !p_getfield || !p_pcall || !p_tonumber || !p_settop) return -1.0;
    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return -1.0; }

    __try {
        p_getfield(L, kGlobals, "GetTime");
        int rc = p_pcall(L, 0, 1, 0);
        if (rc != 0) { p_settop(L, top); return -1.0; }
        double t = p_tonumber(L, -1);
        p_settop(L, top);
        return t;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return -1.0;
    }
}

void SpellInfoFromLua(lua_State* L, int spellId, float* outMaxRange, int* outCastMs, int* outPowerType) {
    *outMaxRange = -1.f; *outCastMs = -1; *outPowerType = -1;
    if (!L || !p_getfield || !p_pcall || !p_pushnumber || !p_tonumber || !p_settop || spellId <= 0)
        return;

    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return; }

    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "GetSpellInfo");
        p_pushnumber(L, (double)spellId);
        rc = p_pcall(L, 1, 9, 0); // name,rank,icon,cost,isFunnel,powerType,castTime,minRange,maxRange
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return; }

    __try {
        // Returns: 1=name 2=rank 3=icon 4=cost 5=isFunnel 6=powerType 7=castTime 8=minRange 9=maxRange
        // We want: castTime(7), minRange(8, in yards, -1 if no data), maxRange(9)
        // GetSpellInfo stack order after call: all 9 results on stack
        *outCastMs    = (int)(p_tonumber(L, -3) * 1000.0); // castTime (sec) → ms, at position -3
        *outMaxRange  = (float)p_tonumber(L, -1);            // maxRange at top of stack
        *outPowerType = (int)p_tonumber(L, -4);              // powerType
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
}

void PlayerCastInfo(int* outSpellId, int* outCastTotalMs) {
    *outSpellId = -1; *outCastTotalMs = 0;
    void* rawL = RL::Game::Addr::LuaState();
    if (!rawL || !p_getfield || !p_pcall || !p_pushstring || !p_tonumber || !p_settop) return;
    auto L = (lua_State*)rawL;

    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return; }

    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "UnitCastingInfo");
        p_pushstring(L, "player");
        rc = p_pcall(L, 1, 9, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return; }

    __try {
        // Stack: 1=name 2=text 3=icon 4=startMs 5=endMs 6=delay 7=castId 8=interrupt 9=spellId
        double endMs   = p_tonumber(L, -5);
        double startMs = p_tonumber(L, -6);
        if (endMs <= 0.0) { p_settop(L, top); return; }
        *outSpellId     = (int)p_tonumber(L, -1);
        *outCastTotalMs = (int)(endMs - startMs);
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
}

void MapInfoFromLua(char* buf, size_t bufSize) {
    if (!buf || bufSize < 8) return;
    buf[0] = '\0';
    void* rawL = RL::Game::Addr::LuaState();
    if (!rawL || !p_getfield || !p_pcall || !p_gettop || !p_settop || !p_tonumber || !p_tolstring) return;
    auto L = (lua_State*)rawL;

    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return; }

    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "GetMapInfo");
        rc = p_pcall(L, 0, 6, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return; }

    __try {
        // Stack: 1=mapFile 2=mapName 3=mapDesc 4=zoneId 5=zoneName 6=zoneDesc
        int mapId = (int)p_tonumber(L, -6);
        const char* mapName = p_tolstring(L, -5, nullptr);
        int zoneId = (int)p_tonumber(L, -3);
        const char* zoneName = p_tolstring(L, -2, nullptr);
        snprintf(buf, bufSize, "mapId=%d|mapName=%s|zoneId=%d|zoneName=%s",
                 mapId, mapName ? mapName : "?", zoneId, zoneName ? zoneName : "?");
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
}

void ShapeshiftFormFromLua(int* outForm) {
    *outForm = -1;
    void* rawL = RL::Game::Addr::LuaState();
    if (!rawL || !p_getfield || !p_pcall || !p_gettop || !p_settop || !p_tonumber) return;
    auto L = (lua_State*)rawL;

    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return; }

    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "GetShapeshiftForm");
        rc = p_pcall(L, 0, 1, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return; }

    __try {
        *outForm = (int)p_tonumber(L, -1);
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
}

// Spell school from Lua — reads GetSpellInfo powerType as a proxy, plus spell name heuristic
int SpellSchoolFromLua(lua_State* L, int spellId) {
    if (!L || !p_getfield || !p_pcall || !p_pushnumber || !p_tolstring || !p_tonumber || !p_settop || spellId <= 0)
        return -1;

    int top = 0;
    __try { top = p_gettop(L); } __except (EXCEPTION_EXECUTE_HANDLER) { return -1; }

    int rc = -1;
    __try {
        p_getfield(L, kGlobals, "GetSpellInfo");
        p_pushnumber(L, (double)spellId);
        rc = p_pcall(L, 1, 9, 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return -1;
    }
    if (rc != 0) { __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {} return -1; }

    int school = -1;
    __try {
        // Spell name at position -9 (first return)
        const char* name = p_tolstring(L, -9, nullptr);
        if (name) {
            // Heuristic: school from common spell name patterns
            // This is crude — proper school read needs DBC access
            if (strstr(name, "Frost") || strstr(name, "Ice") || strstr(name, "Chill"))
                school = 16;  // SPELL_SCHOOL_FROST
            else if (strstr(name, "Fire") || strstr(name, "Flame") || strstr(name, "Burn"))
                school = 4;   // SPELL_SCHOOL_FIRE
            else if (strstr(name, "Shadow") || strstr(name, "Dark"))
                school = 32;  // SPELL_SCHOOL_SHADOW
            else if (strstr(name, "Holy") || strstr(name, "Light") || strstr(name, "Smite"))
                school = 2;   // SPELL_SCHOOL_HOLY
            else if (strstr(name, "Nature") || strstr(name, "Lightning") || strstr(name, "Thunder"))
                school = 8;   // SPELL_SCHOOL_NATURE
            else if (strstr(name, "Arcane") || strstr(name, "Mana"))
                school = 64;  // SPELL_SCHOOL_ARCANE
            else if (strstr(name, "Physical") || strstr(name, "Strike") || strstr(name, "Slash")
                     || strstr(name, "Attack") || strstr(name, "Hit") || strstr(name, "Stab"))
                school = 1;   // SPELL_SCHOOL_PHYSICAL
        }
        p_settop(L, top);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        __try { p_settop(L, top); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
    return school;
}

} // namespace RL::Lua
