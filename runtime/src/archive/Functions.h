#pragma once
#include <cstdint>
#include "Offsets.h"
#include "Types.h"

// Ascension / 3.3.5.12340 calling conventions (stock-style)

// Returns active player GUID in EDX:EAX
using fpGetActivePlayer = uint64_t(__cdecl*)();

// CGObject* from GUID (two dwords on stack)
using fpObjectPtr = uintptr_t(__cdecl*)(uint64_t guid);

// Enumerate visible objects. Stock callback is typically:
//   int __cdecl cb(uint64_t guid, void* user)
// returning 1 continue / 0 stop — verify if enum stalls.
using ObjectEnumCallback = int(__cdecl*)(uint64_t guid, void* user);
using fpEnumVisibleObjects = void(__cdecl*)(ObjectEnumCallback cb, int filter);

using fpGetCamera = uintptr_t(__cdecl*)();

// ClickToMove on player object (thiscall)
// clickType: 4 = move, others interact variants
using fpClickToMove = void(__thiscall*)(uintptr_t player, uint32_t clickType, uint64_t* interactGuid,
                                        Vec3* pos, float precision);

// TraceLine / world intersect
using fpWorldIntersect = bool(__cdecl*)(Vec3* start, Vec3* end, Vec3* hit, float* dist,
                                        uint32_t flags, uintptr_t ignore);

// FrameScript
using fpFrameScript_Execute = void(__cdecl*)(const char* code, const char* name);
using fpFrameScript_RegisterFunction = void(__cdecl*)(const char* name, void* luaCFunction);

namespace Functions {

inline fpGetActivePlayer GetActivePlayer =
    reinterpret_cast<fpGetActivePlayer>(Offsets::Functions::ClntObjMgrGetActivePlayer);

inline fpObjectPtr ObjectPtr =
    reinterpret_cast<fpObjectPtr>(Offsets::Functions::ClntObjMgrObjectPtr);

inline fpEnumVisibleObjects EnumVisibleObjects =
    reinterpret_cast<fpEnumVisibleObjects>(Offsets::Functions::ClntObjMgrEnumVisibleObjects);

inline fpGetCamera GetCamera =
    reinterpret_cast<fpGetCamera>(Offsets::Functions::GetCamera);

inline fpClickToMove ClickToMove =
    reinterpret_cast<fpClickToMove>(Offsets::Functions::CGPlayer_C_ClickToMove);

inline fpWorldIntersect WorldIntersect =
    reinterpret_cast<fpWorldIntersect>(Offsets::Functions::CGWorldFrame_C_Intersect);

inline fpFrameScript_Execute FrameScript_Execute =
    reinterpret_cast<fpFrameScript_Execute>(Offsets::Functions::FrameScript_Execute);

inline fpFrameScript_RegisterFunction FrameScript_RegisterFunction =
    reinterpret_cast<fpFrameScript_RegisterFunction>(Offsets::Functions::FrameScript_RegisterFunction);

} // namespace Functions
