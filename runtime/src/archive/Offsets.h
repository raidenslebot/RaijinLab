#pragma once
#include <cstdint>

// Ascension Live (3.3.5.12340-class) — function VAs validated statically 2026-07-20
// against Ascension.exe (image base 0x400000). Object field offsets are classic 3.3.5
// community values — verify live before relying on position/speed writes.
//
// Example Code under Workspace/Example Code used TurtleWoW offsets — DO NOT use those.

namespace Offsets {

namespace Functions {
    // Object manager (TLS-based, matches stock 12340 layout)
    constexpr uintptr_t ClntObjMgrGetActivePlayer   = 0x004D3790; // -> GUID in EDX:EAX
    constexpr uintptr_t ClntObjMgrObjectPtr         = 0x004D4DB0; // __cdecl/stdcall GUID -> CGObject*
    constexpr uintptr_t ClntObjMgrEnumVisibleObjects = 0x004D4B30;

    // World / camera / movement
    constexpr uintptr_t GetCamera                   = 0x004F5960; // -> camera* via [0xB7436C]+0x7E20
    constexpr uintptr_t CGPlayer_C_ClickToMove      = 0x00727400;
    constexpr uintptr_t CGWorldFrame_C_Intersect   = 0x007A3B70;

    // FrameScript / Lua
    constexpr uintptr_t FrameScript_Execute         = 0x00819210;
    constexpr uintptr_t FrameScript_GetText         = 0x00819D40;
    constexpr uintptr_t FrameScript_RegisterFunction = 0x00817F90;

    // Lua C API (validated via FrameScript_RegisterFunction callees + prologues)
    constexpr uintptr_t lua_gettop                  = 0x0084DBD0;
    constexpr uintptr_t lua_tolstring               = 0x0084E0E0;
    constexpr uintptr_t lua_tonumber                = 0x0084E030;
    constexpr uintptr_t lua_pushstring              = 0x0084E350;
    constexpr uintptr_t lua_pushboolean             = 0x0084E4D0;
    constexpr uintptr_t lua_pushcclosure            = 0x0084E400; // used by RegisterFunction
    // lua_pushnumber @ 0x84E2A0 (fld qword) — classic layout
    constexpr uintptr_t lua_pushnumber              = 0x0084E2A0;

    // Globals (absolute)
    constexpr uintptr_t g_TlsIndex_ClntObjMgr       = 0x00D439BC; // used by OM funcs
    constexpr uintptr_t g_WorldFramePtr             = 0x00B7436C; // camera parent chain
    constexpr uintptr_t g_FrameScript_LuaState      = 0x00D3F78C; // L used by RegisterFunction
}

namespace Object {
    // CGObject
    constexpr uintptr_t Descriptor = 0x08;
    constexpr uintptr_t Type       = 0x14;
    // CGUnit / CGPlayer world position (classic 3.3.5)
    constexpr uintptr_t Position   = 0x798;
    constexpr uintptr_t Facing     = 0x7A0;
    constexpr uintptr_t Speed      = 0x814; // transport/unit movement — verify live
    constexpr uintptr_t SpeedMod   = 0x81C;
}

namespace Descriptor {
    // Byte offsets from descriptor base (field index * 4 for some; these are common byte offs)
    constexpr uintptr_t Entry      = 0x0C; // OBJECT_FIELD_ENTRY
    constexpr uintptr_t Health     = 0x58; // UNIT_FIELD_HEALTH-ish
    constexpr uintptr_t MaxHealth  = 0x70;
    constexpr uintptr_t Level      = 0xD8; // often UNIT_FIELD_LEVEL — verify
    constexpr uintptr_t Flags      = 0xEC;
    constexpr uintptr_t DynamicFlags = 0x13C;
}

namespace Camera {
    constexpr uintptr_t Position = 0x08;
}

// Trace flags for CGWorldFrame::Intersect (classic)
namespace Trace {
    constexpr uint32_t LineOfSight = 0x100011;
    constexpr uint32_t HitTest     = 0x100171;
}

} // namespace Offsets
