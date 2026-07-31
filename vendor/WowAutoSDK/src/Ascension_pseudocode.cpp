/**
 * Ascension SDK - Pseudo-code Reconstruction
 * Auto-generated from disassembly analysis
 * Date: 2026-04-03 10:44:53
 *
 * NOTE: This is approximate pseudo-code reconstructed from
 * x86 disassembly. It may not be perfectly accurate.
 * For exact behavior, refer to the .asm files.
 */

#include "AscensionSDK.h"

// @ 0x00468550
bool __thiscall CGPlayer_C::ClickToMove(CGPlayer_C *this, int clickType, WGUID *targetGuid, C3Vector *pos, float precision)
{
    return /* eax */;
}

// @ 0x004D3A40
int __thiscall CGObject_C::GetObjectType(CGObject_C *this)
{
    return /* eax */;
    return /* eax */;
    return /* eax */;
}

// @ 0x004D3D50
int __cdecl ClntObjMgrEnumVisibleObjects(int (*callback)(WGUID, void*), void *param)
{
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return 0;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
}

// @ 0x004D4A80
int __cdecl CGWorldFrame__GetCurrentMapId(void)
{
    /* push "Object manager list status:" */
    /* push "    Active objects:              %u objects (%u visible)" */
    /* push "    Objects waiting to be freed: %u objects" */
    return /* eax */;
}

// @ 0x004D4B30
CGObject_C* __cdecl ClntObjMgrObjectPtr(WGUID guid, int typeMask)
{
    return /* eax */;
    return /* eax */;
}

// @ 0x004D4D70
CGPlayer_C* __cdecl ClntObjMgrGetActivePlayerObj(void)
{
    return /* eax */;
}

// @ 0x004D4DB0
WGUID __cdecl ClntObjMgrGetActivePlayer(void)
{
    return /* eax */;
}

// @ 0x00515DC0
void __thiscall CGCamera__GetPosition(CGCamera *this, C3Vector *pos)
{
    return;
}

// @ 0x00515DE0
void __thiscall CGCamera__GetForward(CGCamera *this, C3Vector *fwd)
{
    /* push "Usage: ArenaTeamLeave(team)" */
    return;
    return;
}

// @ 0x00591560
void __thiscall CGObject_C::GetPosition(CGObject_C *this, C3Vector *pos)
{
    return;
    return;
    return;
    return;
}

// @ 0x005AA780
int __thiscall ClientServices__SendPacket(void *this, CDataStore *packet)
{
    return /* eax */;
}

// @ 0x005B2DD0
int __thiscall CGGameObject_C::GetDisplayId(CGGameObject_C *this)
{
    /* push ".?AUCLIENT_ACHIEVEMENT_CRITERIA@@" */
    /* push "delete" */
    return /* eax */;
}

// @ 0x005EAED0
int __thiscall CGItem_C::GetDurability(CGItem_C *this)
{
    /* push ".\PaperDollInfoFrame.cpp" */
    /* call ClntObjMgrGetActivePlayer */
    return /* eax */;
    return /* eax */;
}

// @ 0x005EAEE0
int __thiscall CGItem_C::GetMaxDurability(CGItem_C *this)
{
    /* call ClntObjMgrGetActivePlayer */
    return /* eax */;
    return /* eax */;
}

// @ 0x00631BB0
void __cdecl ChatFrame_SendChatMessage(const char *msg, int chatType, const char *lang)
{
    return;
    /* call ClntObjMgrGetActivePlayer */
    return;
    return;
}

// @ 0x0065CFF0
int __thiscall CGUnit_C::GetHealth(CGUnit_C *this)
{
    return /* eax */;
}

// @ 0x0065D030
int __thiscall CGUnit_C::GetMaxHealth(CGUnit_C *this)
{
    return /* eax */;
}

// @ 0x0065D080
float __thiscall CGUnit_C::GetHealthPct(CGUnit_C *this)
{
    return /* eax */;
    return /* eax */;
}

// @ 0x0065D0D0
float __thiscall CGUnit_C::GetPowerPct(CGUnit_C *this, int powerType)
{
    return /* eax */;
}

// @ 0x006CBBF0
void __thiscall WorldFrame__Render(void *this)
{
    return;
}

// @ 0x006FBF60
const char* __cdecl Spell_C_GetSpellName(int spellId)
{
    return /* eax */;
}

// @ 0x006FD1B0
const char* __cdecl Spell_C_GetSpellDescription(int spellId, char *buffer, int bufferSize)
{
    return /* eax */;
    return /* eax */;
}

// @ 0x006FDA00
int __thiscall Spell_C_CastSpell(void *this, int spellId, WGUID *targetGuid)
{
    return /* eax */;
}

// @ 0x007286F0
void __thiscall MovementInfo::SetPosition(MovementInfo *this, C3Vector *pos)
{
    return;
    return;
    return;
}

// @ 0x00736140
int __thiscall CGUnit_C::GetLevel(CGUnit_C *this)
{
    /* call ClntObjMgrGetActivePlayer */
    /* push ".\Unit_C.cpp" */
    /* call ClntObjMgrGetActivePlayer */
    /* push ".\Unit_C.cpp" */
    /* call ClntObjMgrGetActivePlayer */
    return /* eax */;
    return /* eax */;
    return /* eax */;
    return /* eax */;
}

// @ 0x007633C0
void __thiscall CVar__Set(CVar *this, const char *value, int unk1, int unk2, int notify)
{
    return;
}

// @ 0x00763480
const char* __thiscall CVar__GetString(CVar *this)
{
    return /* eax */;
}

// @ 0x007637C0
CVar* __cdecl CVar__LookupByName(const char *name)
{
    return /* eax */;
}

// @ 0x00767440
int __cdecl ConsoleExec(const char *cmd)
{
    return /* eax */;
    return /* eax */;
}

// @ 0x007C2B90
void __cdecl FrameScript_RegisterFunction(const char *name, lua_CFunction func)
{
    return;
}

// @ 0x007C2BE0
void __cdecl FrameScript_UnregisterFunction(const char *name)
{
    return;
}

// @ 0x00819210
int __cdecl FrameScript_Execute(const char *luaCode, const char *source, int unused)
{
    return /* eax */;
}

// @ 0x0081A000
double __cdecl lua_tonumber(lua_State *L, int index)
{
    /* push "arg0" */
    /* push "arg0" */
    /* push "arg0" */
    /* push "event" */
    /* push "this" */
    return /* eax */;
}

// @ 0x0081A070
void __cdecl lua_pushnumber(lua_State *L, double n)
{
    /* push "arg0" */
    /* push "arg0" */
    /* push "event" */
    /* push "this" */
    return;
}

// @ 0x0081A120
void __cdecl lua_pushstring(lua_State *L, const char *s)
{
    /* push "arg0" */
    /* push "event" */
    /* push "this" */
    return;
}

// @ 0x0081A350
const char* __cdecl FrameScript_GetText(const char *varName, int unused)
{
    /* push ".?AV?$TSExplicitList@UFrameScript_EventObject@@$0?CCCCCCCD@@@" */
    /* push ".?AV?$TSExplicitList@UFrameScript_EventObject@@$0?CCCCCCCD@@@" */
    /* push ".?AV?$TSExplicitList@UFrameScript_EventObject@@$0?CCCCCCCD@@@" */
    return /* eax */;
}

// @ 0x0081A3D0
const char* __cdecl lua_tostring(lua_State *L, int index)
{
    /* push ".?AV?$TSExplicitList@UFrameScript_EventObject@@$0?CCCCCCCD@@@" */
    return /* eax */;
}

