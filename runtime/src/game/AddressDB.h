#pragma once
#include <cstdint>

// Canonical Ascension Live addresses (RaijinLab rev3 + WowAutoSDK merge).
// Prefer these over raw wow_addresses_12340.h for OM/CTM.

namespace RL::Game::Addr {

// --- Globals ---
constexpr uintptr_t g_luaState          = 0x00D3F78C;
constexpr uintptr_t g_InWorld           = 0x00D3F60C;
constexpr uintptr_t g_TlsIndex          = 0x00D439BC;
constexpr uintptr_t g_WorldFrame        = 0x00B7436C;
constexpr uintptr_t TaintContext        = 0x00D4139C;
constexpr uintptr_t ExecCounter         = 0x00D413A0;
constexpr uintptr_t CombatLockdown      = 0x00D413A4;
constexpr uintptr_t EventHandlerPtr     = 0x00D413B0;
constexpr uintptr_t HardwareEventFlag   = 0x00BEAF4C;

// --- FrameScript ---
constexpr uintptr_t FrameScript_Execute          = 0x00819210;
constexpr uintptr_t FrameScript_RegisterFunction = 0x00817F90;
constexpr uintptr_t FrameScript_UnregisterFunction = 0x00817FD0;
constexpr uintptr_t FrameScript_GetText          = 0x0081A350;
constexpr uintptr_t FrameScript_SetGlobal        = 0x008191F0;

// --- Lua C API (SDK verified) ---
constexpr uintptr_t lua_gettop        = 0x0084DBD0;
constexpr uintptr_t lua_settop        = 0x0084DBF0;
constexpr uintptr_t lua_insert        = 0x0084DCC0;
constexpr uintptr_t lua_type          = 0x0084DEB0;
constexpr uintptr_t lua_pushvalue     = 0x0084DE50;
constexpr uintptr_t lua_isnumber      = 0x0084DF20;
constexpr uintptr_t lua_isstring      = 0x0084DF60;
constexpr uintptr_t lua_tonumber      = 0x0084E030;
constexpr uintptr_t lua_toboolean     = 0x0084E0B0;
constexpr uintptr_t lua_tolstring     = 0x0084E0E0;
constexpr uintptr_t lua_touserdata    = 0x0084E1C0;
constexpr uintptr_t lua_pushnil       = 0x0084E280;
constexpr uintptr_t lua_pushnumber    = 0x0084E2A0;
constexpr uintptr_t lua_pushinteger   = 0x0084E2D0;
constexpr uintptr_t lua_pushstring    = 0x0084E350;
constexpr uintptr_t lua_pushlstring   = 0x0084E3D0;
constexpr uintptr_t lua_pushcclosure  = 0x0084E400;
constexpr uintptr_t lua_pushboolean   = 0x0084E4D0;
constexpr uintptr_t lua_gettable      = 0x0084E600;
constexpr uintptr_t lua_getfield      = 0x0084E670;
constexpr uintptr_t lua_createtable   = 0x0084E6E0;
constexpr uintptr_t lua_settable      = 0x0084E8D0;
constexpr uintptr_t lua_rawset        = 0x0084E970;
constexpr uintptr_t lua_rawseti       = 0x0084EA00;
constexpr uintptr_t lua_pcall         = 0x0084EC50;
constexpr uintptr_t lua_setfield      = 0x0084F7A0;
constexpr uintptr_t luaL_loadbuffer   = 0x0084F860;

// --- Object Manager (disasm 2026-07-21) ---
// GetActivePlayer 0x4D3790: TLS → guid EDX:EAX
// ObjectPtr        0x4D4DB0: (guidLo, guidHi, typeMask) → CGObject*
// 0x4D4B30 is NOT ObjectPtr (callback helper)
constexpr uintptr_t ClntObjMgrGetActivePlayer    = 0x004D3790;
constexpr uintptr_t ClntObjMgrObjectPtr          = 0x004D4DB0;
// Corrected to CTX ground truth (0x4D4B30). The prior value 0x4D3D50 is a
// helper with a different stack layout — calling it with our
// (int(*)(guidLo,guidHigh,void*), -1) signature dispatched into a routine
// that read torn args as GUIDs, then AV'd inside ObjectPtr's TLS lookup.
constexpr uintptr_t ClntObjMgrEnumVisibleObjects = 0x004D4B30;
constexpr uintptr_t ClntObjMgrEnumVisibleObjectsAlt = 0x004D3D50;
constexpr uintptr_t ClntObjMgrGetActivePlayerObj = 0x004D4D70;

// --- Game ---
constexpr uintptr_t GetCamera               = 0x004F5960;
constexpr uintptr_t CGPlayer_ClickToMove    = 0x00727400;
constexpr uintptr_t CWorld_Intersect        = 0x007A3B70;
constexpr uintptr_t CGObject_GetPosition    = 0x00591560;
constexpr uintptr_t CGUnit_GetHealth        = 0x0065CFF0;
constexpr uintptr_t CGUnit_GetMaxHealth     = 0x0065D030;
constexpr uintptr_t CGUnit_GetLevel         = 0x00736140;
// Real Spell_C_CastSpell: cdecl (spellId, itemId, guidLo, guidHi, isTrade).
// Verified: xrefs from FrameScript CastSpellByID (0x53E177) / CastSpellByName.
// NOT 0x6FD6B0 (unrelated thiscall, no stack args) or 0x6FDA00 (its epilogue).
constexpr uintptr_t Spell_C_CastSpell       = 0x0080DA40;

// --- Taint patches (from lua_unlocker / SDK) ---
constexpr uintptr_t EventHandlerSet     = 0x0052A95E;
constexpr uintptr_t EventHandlerClear   = 0x0052A96C;
constexpr uintptr_t TaintErrorReporter  = 0x00513530;
constexpr uintptr_t VMTaintSkip1        = 0x00857493;
constexpr uintptr_t VMTaintSkip2        = 0x00857317;

// --- Object field offsets ---
constexpr uintptr_t Obj_Descriptor = 0x08;
constexpr uintptr_t Obj_Type       = 0x14;
constexpr uintptr_t Obj_Position   = 0x798;   // C3Vector: x@0x798 y@0x79C z@0x7A0
// Orientation float is z+4 = 0x7A4. It was 0x7A0 (== Z!), so FaceDirection's
// Write<float>(p+Facing, heading) stomped the character's Z with the heading
// value and dropped it through the world. Root cause of every "under the map".
constexpr uintptr_t Obj_Facing     = 0x7A4;

// Implemented in AddressDB.cpp (SEH-safe)
bool InWorld();              // GUID proxy first, then g_InWorld flag
void* LuaState();
uint64_t ActivePlayerGuid(); // ClntObjMgrGetActivePlayer
// PURE memory read of the g_InWorld flag (NO client-function call). Safe to
// poll from the worker thread — a read can't block/deadlock the way calling
// ClntObjMgrGetActivePlayer cross-thread does during a world load. Returns
// 1 = in world, 0 = not, -1 = address unreadable.
int InWorldFlag();

} // namespace RL::Game::Addr


