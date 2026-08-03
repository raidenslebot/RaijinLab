#include "Lua.h"
#include "game/AddressDB.h"
#include "game/Offsets.h"
#include "game/ObjectManager.h"
#include "game/Actions.h"
#include "game/Guard.h"
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
void settop(lua_State* L, int idx) { if (p_settop) p_settop(L, idx); }
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

// ---- Internal client function addresses (live-scanned at inject) ----------
// These are the client's OWN C++ functions that back the Lua handlers:
//   GetSpellCooldown handler 0x00540E80 calls InternalGetCooldown
//   GetTime handler          0x006081F0 calls InternalGetTime
//   GetSpellInfo handler     0x00540A30 calls InternalGetSpellInfo
// Calling them directly = pure C++, zero Lua, no stack corruption.

using fnGetCooldownInternal = void(__cdecl*)(uint32_t spellId, uint32_t tableType,
    uint32_t* outDurationMs, uint32_t* outStartMs, uint32_t* outUnk);
using fnGetTimeInternal = uint32_t(__cdecl*)();
using fnGetSpellInfoInternal = int(__cdecl*)(uint32_t spellId, void* out);

static uintptr_t s_getCooldown = 0;
static uintptr_t s_getTime = 0;
static uintptr_t s_getSpellInfo = 0;
static bool s_cooldownOk = false;
static bool s_timeOk = false;
static bool s_spellInfoOk = false;

void SetResolvedInternals(uintptr_t getCooldownInternal, uintptr_t getTimeInternal,
                          uintptr_t getSpellInfoInternal,
                          bool cooldownOk, bool timeOk, bool spellInfoOk) {
    s_getCooldown = getCooldownInternal;
    s_getTime = getTimeInternal;
    s_getSpellInfo = getSpellInfoInternal;
    s_cooldownOk = cooldownOk;
    s_timeOk = timeOk;
    s_spellInfoOk = spellInfoOk;
    RL::Log::Info("Lua internals: CD=0x%08X(%d) Time=0x%08X(%d) Info=0x%08X(%d)",
                  (unsigned)s_getCooldown, (int)s_cooldownOk,
                  (unsigned)s_getTime, (int)s_timeOk,
                  (unsigned)s_getSpellInfo, (int)s_spellInfoOk);
}

double SpellCooldownMs(lua_State* L, int spellId) {
    (void)L;
    if (spellId <= 0 || !s_cooldownOk || !s_timeOk) return 0.0;
    auto pGetCD = reinterpret_cast<fnGetCooldownInternal>(s_getCooldown);
    auto pGetTime = reinterpret_cast<fnGetTimeInternal>(s_getTime);

    // Query spell-specific cooldown table, then category table.
    // VEH longjmp guards: a dead __try under stealth let an AV in these
    // internal client calls propagate into the game's Lua VM.
    uint32_t durMs = 0, startMs = 0, unk = 0;
    {
        RL::Game::Guard::Scope g;
        if (!g.Caught())
            pGetCD((uint32_t)spellId, 0, &durMs, &startMs, &unk);
    }
    if (durMs == 0) {
        RL::Game::Guard::Scope g;
        if (!g.Caught())
            pGetCD((uint32_t)spellId, 1, &durMs, &startMs, &unk);
    }
    if (durMs == 0) return 0.0; // not on cooldown

    uint32_t nowMs = 0;
    {
        RL::Game::Guard::Scope g;
        if (!g.Caught())
            nowMs = pGetTime();
    }

    int64_t endMs = (int64_t)startMs + (int64_t)durMs;
    int64_t remMs = endMs - (int64_t)nowMs;
    if (remMs <= 0) return 0.0;
    return (double)remMs;
}

// ---- IsSpellInRange / IsSpellUsable — PURE C++ memory reads ---------------
// ZERO Lua pcall. Spell range passed from Lua's cached spell_meta.
// Only ObjectManager descriptor reads + SoftHardwareUnlock.

int IsSpellInRangeRuntime(lua_State* L, int spellId, float maxRange) {
    (void)L;
    if (spellId <= 0) return -1;

    RL::Game::Actions::SoftHardwareUnlock();  // re-enabled, taint disabled

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

    RL::Game::Actions::SoftHardwareUnlock();  // re-enabled, taint disabled

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

// ---- ValidateCast — single definitive pre-cast check ---------------------
// Replaces individual IsSpellInRangeRt + IsSpellUsableRt calls. One C++ call
// reads everything from client memory and returns a packed verdict string.
// Lua context builder calls this once per spell per tick.
void ValidateCast(lua_State* L, int spellId, float maxRange, char* outBuf, size_t bufSize) {
    if (!outBuf || !bufSize) return;
    outBuf[0] = 0;
    if (spellId <= 0) { snprintf(outBuf, bufSize, "bad_spell"); return; }
    if (maxRange <= 0.f) maxRange = 5.0f;

    RL::Game::Actions::SoftHardwareUnlock();

    uint64_t localGuid = RL::Game::OM::LocalGuid();
    if (!localGuid) { snprintf(outBuf, bufSize, "no_player"); return; }

    // 1. Cooldown check
    double cdMs = SpellCooldownMs(L, spellId);
    if (cdMs > 0.0) { snprintf(outBuf, bufSize, "cooldown:%.0f", cdMs); return; }

    // 2. Power check
    for (int pt = 0; pt <= 7; ++pt) {
        int maxPower = RL::Game::OM::UnitMaxPower(localGuid, pt);
        if (maxPower > 0) {
            int curPower = RL::Game::OM::UnitPower(localGuid, pt);
            if (curPower <= 0) { snprintf(outBuf, bufSize, "no_power:%d", pt); return; }
        }
    }

    // 3. Range check (if target exists)
    uint64_t targetGuid = RL::Game::OM::UnitTargetGuid(localGuid);
    if (targetGuid) {
        RL::Game::Vec3 pPos = RL::Game::OM::Position(localGuid);
        RL::Game::Vec3 tPos = RL::Game::OM::Position(targetGuid);
        if (pPos.x != 0.f || pPos.y != 0.f) {
            float dx = pPos.x - tPos.x;
            float dy = pPos.y - tPos.y;
            float center = sqrtf(dx * dx + dy * dy);
            float pReach = RL::Game::OM::CombatReach(localGuid);
            if (pReach <= 0.f) pReach = 1.5f;
            float tReach = RL::Game::OM::CombatReach(targetGuid);
            if (tReach <= 0.f) tReach = 1.5f;
            float edge = center - pReach - tReach;
            if (edge < 0.f) edge = 0.f;
            if (edge > maxRange + 0.05f) {
                snprintf(outBuf, bufSize, "oor:%.1f", edge);
                return;
            }
        }
    }

    snprintf(outBuf, bufSize, "ok");
}

double GameTimeFromLua(lua_State* L) {
    (void)L;
    // SAFE NO-OP: lua_getfield+lua_pcall from non-Lua context corrupts the
    // Lua stack in Ascension's custom VM → AV_READ crash. Game time is read
    // via the client's internal clock elsewhere (pure C++).
    return -1.0;
}

void SpellInfoFromLua(lua_State* L, int spellId, float* outMaxRange, int* outCastMs, int* outPowerType) {
    (void)L; (void)spellId;
    // CRASH RULE (permanent): nested lua_getfield+lua_pcall of GetSpellInfo
    // from inside Lua_IsLinuxClient corrupts the Lua stack → eip=0 in the
    // game VM (proven 2026-07-31). SAFE NO-OP. The addon reads spell info via
    // its own Lua GetSpellInfo (Lua→Lua, safe). Callers treat -1 as unknown.
    *outMaxRange = -1.f; *outCastMs = -1; *outPowerType = -1;
}

void PlayerCastInfo(int* outSpellId, int* outCastTotalMs) {
    // CRASH RULE (permanent): nested lua_getfield+lua_pcall of UnitCastingInfo
    // from inside the bridge corrupts the Lua stack (proven). SAFE NO-OP.
    // Callers treat (-1, 0) as "not casting / unknown".
    *outSpellId = -1; *outCastTotalMs = 0;
}

void MapInfoFromLua(char* buf, size_t bufSize) {
    if (!buf || bufSize < 8) return;
    // CRASH RULE (permanent): nested lua_getfield+lua_pcall of GetMapInfo
    // from inside the bridge corrupts the Lua stack (proven). SAFE NO-OP.
    // Callers fall back to "mapId=?|..." placeholders. The addon reads map
    // info via its own Lua GetMapInfo (Lua→Lua, safe) where it matters.
    buf[0] = '\0';
}

void ShapeshiftFormFromLua(int* outForm) {
    // CRASH RULE (permanent): nested lua_getfield+lua_pcall of
    // GetShapeshiftForm from inside the bridge corrupts the Lua stack
    // (proven). SAFE NO-OP. The addon reads GetShapeshiftForm via its own Lua
    // (Lua→Lua, safe). -1 = unknown.
    *outForm = -1;
}

// Spell school — CRASH RULE (permanent): nested GetSpellInfo lua_pcall from
// the bridge corrupts the Lua stack (proven). SAFE NO-OP. The addon resolves
// spell school via its own Lua (Lua→Lua, safe). -1 = unknown.
int SpellSchoolFromLua(lua_State* L, int spellId) {
    (void)L; (void)spellId;
    return -1;
}

} // namespace RL::Lua
