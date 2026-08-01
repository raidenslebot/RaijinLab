#include "Lua.h"
#include "game/AddressDB.h"
#include "game/Offsets.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstdlib>
#include <cstring>
#include <cstdio>

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
        return 0.0;
    int top = p_gettop(L);

    // 1) GetSpellCooldown(spellId) → start, duration (game-time seconds)
    p_getfield(L, kGlobals, "GetSpellCooldown");
    p_pushnumber(L, (double)spellId);
    int rc = p_pcall(L, 1, 2, 0);
    if (rc != 0) { p_settop(L, top); return 0.0; }
    double start    = p_tonumber(L, -2);
    double duration = p_tonumber(L, -1);
    p_settop(L, top);
    if (duration <= 0.0) return 0.0; // no cooldown on this spell

    // 2) GetTime() → current game-time seconds (same clock as GetSpellCooldown)
    p_getfield(L, kGlobals, "GetTime");
    rc = p_pcall(L, 0, 1, 0);
    if (rc != 0) { p_settop(L, top); return 0.0; }
    double now = p_tonumber(L, -1);
    p_settop(L, top);

    double end = start + duration;
    if (now >= end) return 0.0; // cooldown expired
    return (end - now) * 1000.0; // remaining milliseconds
}

} // namespace RL::Lua
