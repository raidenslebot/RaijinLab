#pragma once
#include <cstdint>
#include <cstddef>

struct lua_State;

namespace RL::Lua {

void Init();
bool Ready();

int gettop(lua_State* L);
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
// milliseconds (0 if ready, -1 if unreadable). Thread-safe only on main thread.
double SpellCooldownMs(lua_State* L, int spellId);

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

// Try to resolve spell school from Lua (GetSpellInfo + school lookup). Returns -1 if unknown.
int SpellSchoolFromLua(lua_State* L, int spellId);

// Read all auras (buff+debuff) for a unit. `unitToken` is "player" or guid "0xHEX".
// Writes packed "n|spellId:stacks:durationMs:isDebuff|..." into buf.
void UnitAurasFromLua(lua_State* L, const char* unitToken, char* buf, size_t bufSize);

} // namespace RL::Lua
