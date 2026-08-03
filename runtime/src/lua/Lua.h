#pragma once
#include <cstdint>
#include <cstddef>

struct lua_State;

namespace RL::Lua {

void Init();
bool Ready();

int gettop(lua_State* L);
void settop(lua_State* L, int idx);
const char* tolstring(lua_State* L, int idx, size_t* len);
double tonumber(lua_State* L, int idx);
void pushnumber(lua_State* L, double n);
void pushstring(lua_State* L, const char* s);
void pushboolean(lua_State* L, int b);
void pushnil(lua_State* L);

// helpers
const char* checkstring(lua_State* L, int idx);
double optnumber(lua_State* L, int idx, double def);
uint64_t checkguid(lua_State* L, int idx); // number or string hex

int PushString(lua_State* L, const char* s);
int PushNumber(lua_State* L, double n);
int PushBool(lua_State* L, bool v);
int PushNil(lua_State* L);
int PushXYZ(lua_State* L, float x, float y, float z); // 3 returns if possible, else "x,y,z" string

// Call Lua's GetSpellCooldown(spellId) from C++. Returns remaining cooldown in
// milliseconds (0 if ready). When live-scanned internal addresses are
// available, reads the client's internal cooldown table directly (pure C++,
// zero Lua). Otherwise returns 0 (safe no-op).
double SpellCooldownMs(lua_State* L, int spellId);

// Set internal client function addresses resolved by LiveScan at inject time.
// When set, the runtime reads cooldowns/time/spell-info from the client's own
// internal C++ functions (no Lua pcall, no crash).
void SetResolvedInternals(uintptr_t getCooldownInternal, uintptr_t getTimeInternal,
                          uintptr_t getSpellInfoInternal,
                          bool cooldownOk, bool timeOk, bool spellInfoOk);

// Call Lua's GetTime() from C++. Returns game-time seconds or -1 on failure.
double GameTimeFromLua(lua_State* L);

// Call Lua's GetSpellInfo(spellId) from C++. Returns max range (yards), cast
// time (ms), and power type. Returns -1 values on failure.
void SpellInfoFromLua(lua_State* L, int spellId, float* outMaxRange, int* outCastMs, int* outPowerType);

// Call Lua's UnitCastingInfo("player"). Returns spellId (-1 if not casting) and total cast ms.
void PlayerCastInfo(int* outSpellId, int* outCastTotalMs);

// Call Lua's GetMapInfo(). Writes packed "mapId=N|mapName=X|zoneId=N|zoneName=X" into buf.
void MapInfoFromLua(char* buf, size_t bufSize);

// Call Lua's GetShapeshiftForm(). Returns form index (0=normal, 1=bear, etc.) or -1.
void ShapeshiftFormFromLua(int* outForm);

// Set HardwareEventFlag=1 then call IsSpellInRange(spellName, "target").
// Returns 1 (in range), 0 (out of range), or -1 (unreadable/error).
// Does NOT modify TaintContext — only sets the HW flag long enough for the query.
int IsSpellInRangeRuntime(lua_State* L, int spellId, float maxRange);

// Set HardwareEventFlag=1 then call IsUsableSpell(spellName).
// Returns 1 (usable), 0 (not usable), or -1 (unreadable/error).
// nomana is written to *outNomana if non-null.
int IsSpellInRangeRuntime(lua_State* L, int spellId, float maxRange);
int IsSpellUsableRuntime(lua_State* L, int spellId, int* outNomana = nullptr);

// Single definitive pre-cast validation. Reads cooldown, power, range from
// client memory. Returns packed verdict: "ok", "oor:N", "cooldown:N",
// "no_power:N", "no_player", "bad_spell".
void ValidateCast(lua_State* L, int spellId, float maxRange, char* outBuf, size_t bufSize);

// Try to resolve spell school from Lua (GetSpellInfo + school lookup). Returns -1 if unknown.
int SpellSchoolFromLua(lua_State* L, int spellId);

// Read all auras (buff+debuff) for a unit. `unitToken` is "player" or guid "0xHEX".
// Writes packed "n|spellId:stacks:durationMs:isDebuff|..." into buf.
void UnitAurasFromLua(lua_State* L, const char* unitToken, char* buf, size_t bufSize);

} // namespace RL::Lua
