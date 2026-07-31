#include "Offsets.h"
#include "AddressDB.h"
#include "core/Log.h"
#include <cstring>

namespace RL::Game::Offsets {
namespace {
FunctionTable g_f;
ObjectTable g_o;
DescriptorTable g_d;
}

FunctionTable& F() { return g_f; }
ObjectTable& O() { return g_o; }
DescriptorTable& D() { return g_d; }

void ApplyResolved(const char* name, uintptr_t address) {
    if (!name || !address) return;
    auto set = [&](uintptr_t& dst, const char* n) {
        if (std::strcmp(name, n) == 0) {
            dst = address;
            RL::Log::Info("offset apply %s -> 0x%08X", n, (unsigned)address);
        }
    };
    set(g_f.ClntObjMgrGetActivePlayer, "ClntObjMgrGetActivePlayer");
    set(g_f.ClntObjMgrObjectPtr, "ClntObjMgrObjectPtr");
    set(g_f.ClntObjMgrEnumVisibleObjects, "ClntObjMgrEnumVisibleObjects");
    set(g_f.GetCamera, "GetCamera");
    set(g_f.ClickToMove, "CGPlayer_C_ClickToMove");
    set(g_f.WorldIntersect, "CGWorldFrame_C_Intersect");
    set(g_f.FrameScript_Execute, "FrameScript_Execute");
    set(g_f.FrameScript_RegisterFunction, "FrameScript_RegisterFunction");
    set(g_f.lua_gettop, "lua_gettop");
    set(g_f.lua_tolstring, "lua_tolstring");
    set(g_f.lua_pushstring, "lua_pushstring");
}

void InitFromPatterns() {
    // Seed from AddressDB (Raijin + WowAutoSDK merge)
    g_f.ClntObjMgrGetActivePlayer = Addr::ClntObjMgrGetActivePlayer;
    g_f.ClntObjMgrObjectPtr = Addr::ClntObjMgrObjectPtr;
    g_f.ClntObjMgrGetActivePlayerObj = Addr::ClntObjMgrGetActivePlayerObj;
    g_f.CGObject_GetPosition = Addr::CGObject_GetPosition;
    g_f.ClntObjMgrEnumVisibleObjects = Addr::ClntObjMgrEnumVisibleObjects;
    g_f.GetCamera = Addr::GetCamera;
    g_f.ClickToMove = Addr::CGPlayer_ClickToMove;
    g_f.Spell_C_CastSpell = Addr::Spell_C_CastSpell; // 0x80DA40 cdecl (spellId,...)
    g_f.WorldIntersect = Addr::CWorld_Intersect;
    g_f.FrameScript_Execute = Addr::FrameScript_Execute;
    g_f.FrameScript_RegisterFunction = Addr::FrameScript_RegisterFunction;
    g_f.FrameScript_GetText = Addr::FrameScript_GetText;
    g_f.lua_gettop = Addr::lua_gettop;
    g_f.lua_tolstring = Addr::lua_tolstring;
    g_f.lua_tonumber = Addr::lua_tonumber;
    g_f.lua_pushnumber = Addr::lua_pushnumber;
    g_f.lua_pushstring = Addr::lua_pushstring;
    g_f.lua_pushboolean = Addr::lua_pushboolean;
    g_f.lua_pushnil = Addr::lua_pushnil;
    g_f.lua_settop = Addr::lua_settop;
    g_f.g_TlsIndex = Addr::g_TlsIndex;
    g_f.g_WorldFrame = Addr::g_WorldFrame;
    g_f.g_LuaState = Addr::g_luaState;

    g_o.Descriptor = Addr::Obj_Descriptor;
    g_o.Type = Addr::Obj_Type;
    g_o.Position = Addr::Obj_Position;
    g_o.Facing = Addr::Obj_Facing;

    RL::Log::Info("offsets: seeded from AddressDB (SDK merge + OM corrections)");
}

} // namespace RL::Game::Offsets
