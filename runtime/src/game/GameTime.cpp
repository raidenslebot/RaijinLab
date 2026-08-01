#include "GameTime.h"
#include "AddressDB.h"
#include "Offsets.h"
#include "lua/Lua.h"
#include "core/Log.h"
#include <Windows.h>

namespace RL::Game::GameTime {
namespace {

double g_baseGameTime = 0.0;
LARGE_INTEGER g_baseQpc = {};
LARGE_INTEGER g_qpcFreq = {};
bool g_inited = false;

// Spell cooldown cache: avoid Lua pcall on every CastSpellEx
struct CdCache { int spellId; double expireGameTime; };
static CdCache g_cdCache[64] = {};
static int g_cdCacheN = 0;

double RawLuaGetTime() {
    void* L = RL::Game::Addr::LuaState();
    if (!L) return -1.0;
    double t = RL::Lua::GameTimeFromLua((lua_State*)L);
    return t;
}

} // namespace

void Init() {
    QueryPerformanceFrequency(&g_qpcFreq);
    QueryPerformanceCounter(&g_baseQpc);

    double t = RawLuaGetTime();
    if (t >= 0.0) {
        g_baseGameTime = t;
        g_inited = true;
        LOG_I("gt.init", "base=%.6f freq=%lld", g_baseGameTime, (long long)g_qpcFreq.QuadPart);
    } else {
        LOG_W("gt.init", "failed — Lua state not available");
    }
}

double Now() {
    if (!g_inited) {
        double t = RawLuaGetTime();
        if (t >= 0.0) return t;
        return (double)GetTickCount64() * 0.001; // fallback: system uptime (wrong clock but better than crash)
    }
    LARGE_INTEGER nowQpc;
    QueryPerformanceCounter(&nowQpc);
    double elapsed = (double)(nowQpc.QuadPart - g_baseQpc.QuadPart) / (double)g_qpcFreq.QuadPart;
    return g_baseGameTime + elapsed;
}

void Resync() {
    if (!g_inited) { Init(); return; }
    double t = RawLuaGetTime();
    if (t < 0.0) return;
    QueryPerformanceCounter(&g_baseQpc);
    g_baseGameTime = t;
}

double CooldownRemainingMs(int spellId) {
    if (spellId <= 0) return -1.0;
    void* L = RL::Game::Addr::LuaState();
    if (!L) return -1.0;
    return RL::Lua::SpellCooldownMs((lua_State*)L, spellId);
}

} // namespace RL::Game::GameTime
