#pragma once
#include <cstdint>

// Runtime-resolved (pattern) with static fallbacks for Ascension Live 3.3.5.12340-class.
// Call RL::Game::Offsets::Init() after module base known.

namespace RL::Game::Offsets {

struct FunctionTable {
    uintptr_t ClntObjMgrGetActivePlayer = 0x004D3790;
    uintptr_t ClntObjMgrObjectPtr = 0x004D4DB0;
    uintptr_t ClntObjMgrGetActivePlayerObj = 0x004D4D70; // CGPlayer* directly
    uintptr_t ClntObjMgrEnumVisibleObjects = 0x004D3D50;
    uintptr_t CGObject_GetPosition = 0x00591560; // thiscall (this, C3Vector*)
    uintptr_t GetCamera = 0x004F5960;
    uintptr_t ClickToMove = 0x00727400;
    uintptr_t Spell_C_CastSpell = 0x0080DA40;
    uintptr_t WorldIntersect = 0x007A3B70;
    uintptr_t FrameScript_Execute = 0x00819210;
    uintptr_t FrameScript_RegisterFunction = 0x00817F90;
    uintptr_t FrameScript_GetText = 0x00819D40;
    uintptr_t lua_gettop = 0x0084DBD0;
    uintptr_t lua_tolstring = 0x0084E0E0;
    uintptr_t lua_tonumber = 0x0084E030;
    uintptr_t lua_pushnumber = 0x0084E2A0;
    uintptr_t lua_pushstring = 0x0084E350;
    uintptr_t lua_pushboolean = 0x0084E4D0;
    uintptr_t lua_pushnil = 0; // filled if found
    uintptr_t lua_settop = 0x0084DBF0;
    uintptr_t g_TlsIndex = 0x00D439BC;
    uintptr_t g_WorldFrame = 0x00B7436C;
    uintptr_t g_LuaState = 0x00D3F78C;
};

struct ObjectTable {
    uintptr_t Descriptor = 0x08;
    uintptr_t Type = 0x14;
    uintptr_t Guid = 0x30;       // often CGObject+0x30 stores GUID copy
    // DialogStatus (0..10). Written by SetQuestGiverStatus @ 0x744400 from
    // SMSG_QUESTGIVER_STATUS. Read by GetQuestInteractType @ 0x744640.
    // 7/8 = available (!), 9/10 = reward (?). Instance field, not descriptor.
    uintptr_t QuestGiverStatus = 0x90;
    uintptr_t Position = 0x798;  // CGUnit C3Vector (x@0x798 y@0x79C z@0x7A0)
    uintptr_t Facing = 0x7A4;    // orientation float (z+4). NOT 0x7A0 == Z!
    uintptr_t Movement = 0xD8;   // movement info ptr on some builds — verify
    uintptr_t Speed = 0x814;
    uintptr_t BoundingRadius = 0x7D0; // approximate — verify live
    uintptr_t CombatReach = 0x7D4;
};

struct DescriptorTable {
    // byte offsets from descriptor base (classic-ish)
    uintptr_t Entry = 0x0C;
    uintptr_t Scale = 0x10;
    // Ascension / WowAutoSDK unit descriptor (byte offsets from descriptor base).
    // Was 0x58/0x70 (wrong) — that made Health read as 0, which filtered every
    // NPC as dead in om_unit_is_hostile and classified world units as GOs.
    uintptr_t Health = 0x60;
    uintptr_t MaxHealth = 0x80;
    uintptr_t Level = 0xD8;
    uintptr_t FactionTemplate = 0xDC;
    uintptr_t Flags = 0xEC;
    uintptr_t DynamicFlags = 0x13C;
    uintptr_t DisplayId = 0x108;
    uintptr_t NativeDisplayId = 0x10C;
    uintptr_t MountDisplayId = 0x114;
    // VERIFIED LIVE 2026-08-03: 0x5C reads 0x00000A05 = race 5, class 10,
    // exactly matching UnitRace/UnitClass. That is index 0x17, immediately
    // before HEALTH at index 0x18 (0x60) - the standard 3.3.5a layout.
    // It was 0xC0 (index 0x30) and read ZERO, along with everything from
    // 0xC0..0xD4. The comment said "verify" and nobody had; the shapeshift
    // gate built on Bytes2=0xCC therefore sat in that dead region and could
    // never fire.
    uintptr_t Bytes0 = 0x5C;
    // UNIT_FIELD_BYTES_2 packs [0]=sheath, [1]=pvp/flags, [2]=petFlags,
    // [3]=SHAPESHIFT FORM.
    //
    // 0 = UNKNOWN, NOT "no form". The old value 0xCC was derived from the wrong
    // Bytes0 (0xC0) and lands in a region that reads zero for every field, so
    // the shapeshift gate silently answered "unshifted" forever. Rather than
    // guess again from a recalled index - the mistake that produced eight wrong
    // offsets this session - this stays 0 and ShapeshiftForm returns nil
    // (undetermined), which the gate treats as unknown and passes.
    //
    // TO FIX: shapeshift, then scan the descriptor for a dword whose byte 3
    // equals the form id. Bytes0 = 0x5C = index 0x17 is the verified anchor.
    uintptr_t Bytes2 = 0;
    // PLAYER_VISIBLE_ITEM_1_ENTRYID, stride 8 (entry + enchantment pair).
    // RE'd live 2026-08-03 by scanning the player descriptor against
    // GetInventoryItemID ground truth; confirmed on four untransmogged slots:
    //   wrist(9)=0x4AC=499680  hands(10)=0x4B4=276082
    //   back(15)=0x4DC=559183  ranged(18)=0x4F4=824390
    // so slot N sits at VisibleItem1 + (N-1)*8, and main hand (16) = 0x4E4.
    //
    // THESE ARE DISPLAY ENTRIES, NOT ITEM IDS. Main hand read 121696 while
    // GetInventoryItemID said 4562 - the weapon is transmogged. So this field
    // answers "is something equipped in that slot" (non-zero) and must NEVER
    // be compared against an item id or used to look an item up.
    uintptr_t VisibleItem1 = 0x46C;
    uintptr_t VisibleItemStride = 0x8;

    // GAMEOBJECT descriptor fields.
    //
    // 3.3.5a keys update-fields PER OBJECT TYPE: every type restarts its own
    // block immediately after OBJECT_END (index 6), so a UNIT offset applied to
    // a gameobject reads far outside its descriptor. That is not a small error -
    // GAMEOBJECT_END is index 0x12 (byte 0x48), and DynamicFlags above is 0x13C.
    //
    //   GAMEOBJECT_FLAGS   = OBJECT_END(6) + 3 =  9 -> 9*4  = 0x24
    //   GAMEOBJECT_DYNAMIC = OBJECT_END(6) + 8 = 14 -> 14*4 = 0x38
    //
    // This mattered: the quest-item SPARKLE witness reads GAMEOBJECT_DYNAMIC, and
    // it is the ONLY way to find Ascension's custom quest objects - the vendored
    // database ships 0 object rows in its Ascension overlay, so no amount of data
    // lookup can see them. Reading the wrong offset made that witness test
    // whatever happened to sit 0xF4 bytes past the end of the block.
    uintptr_t GoFlags = 0x24;
    uintptr_t GoDynamic = 0x38;
    // GAMEOBJECT_BYTES_1 = OBJECT_END(6) + 0x0B = 17 -> 17*4 = 0x44.
    // Packs four bytes: [0]=state, [1]=TYPE, [2]=artKit, [3]=animProgress.
    // The TYPE byte is the one signal that identifies an interactable/lootable
    // object WITHOUT any dynamic flag - it is set on every gameobject that
    // exists, so it works even if this server never sets GAMEOBJECT_DYNAMIC.
    uintptr_t GoBytes1 = 0x44;
};

FunctionTable& F();
ObjectTable& O();
DescriptorTable& D();
void InitFromPatterns();
void ApplyResolved(const char* name, uintptr_t address);

constexpr uint32_t TRACE_LOS = 0x100111;
constexpr uint32_t TRACE_HIT = 0x100171;

} // namespace RL::Game::Offsets
