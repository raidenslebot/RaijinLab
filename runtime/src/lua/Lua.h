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
// milliseconds (0 if ready or unreadable). Thread-safe only on main thread.
// L must be the current lua_State (readable from Dispatch context).
double SpellCooldownMs(lua_State* L, int spellId);

} // namespace RL::Lua
