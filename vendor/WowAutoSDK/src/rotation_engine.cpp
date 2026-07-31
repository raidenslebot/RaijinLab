/**
 * Engine DLL - Lua extension module
 *
 * Provides Lua-callable functions for:
 *   - Object Manager enumeration (nearby enemies, unit counts)
 *   - Direct distance calculation via position reads
 *   - Face target (set player facing toward a unit)
 *   - Direct spell cast on GUID
 *   - Player/unit position queries
 *
 * Build (MSVC x86):
 *   cl /LD /O2 /GS- rotation_engine.cpp user32.lib kernel32.lib /Fe:rotation_engine.dll
 *
 * Build (MinGW x86):
 *   i686-w64-mingw32-g++ -shared -O2 -s -o rotation_engine.dll rotation_engine.cpp -luser32 -lkernel32
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdlib>

// ============================================================
// Runtime address loader — resolves from JSON next to exe
// Each DLL needs ADDR_LOADER_IMPL since they're separate binaries
// ============================================================
#define ADDR_LOADER_IMPL
#include "addr_loader.h"

// Backward-compatible macros for ADDR_* references remaining in code
#define ADDR_g_luaState           addr::g_luaState
#define ADDR_g_InWorld            addr::g_InWorld
#define ADDR_g_clientConnection   addr::g_clientConnection
#define ADDR_g_localPlayer        addr::g_localPlayer
#define ADDR_g_objectManager      addr::g_objectManager
#define ADDR_MoveForwardStart     addr::MoveForwardStart
#define ADDR_MoveForwardStop      addr::MoveForwardStop
#define ADDR_MoveBackwardStart    addr::MoveBackwardStart
#define ADDR_MoveBackwardStop     addr::MoveBackwardStop
#define ADDR_StrafeLeftStart      addr::StrafeLeftStart
#define ADDR_StrafeLeftStop       addr::StrafeLeftStop
#define ADDR_StrafeRightStart     addr::StrafeRightStart
#define ADDR_StrafeRightStop      addr::StrafeRightStop
#define ADDR_JumpOrAscendStart    addr::JumpOrAscendStart
#define ADDR_AscendStop           addr::AscendStop
#define ADDR_CGObject_GetObjectType addr::CGObject_GetObjectType
#define ADDR_g_currentMapId       0  // TODO: find real address via binary scan

// Descriptor offsets (struct layout, not addresses — these are version-stable)
static constexpr uint32_t OBJECT_FIELD_GUID       = 0x0000;
static constexpr uint32_t OBJECT_FIELD_TYPE       = 0x0008;
static constexpr uint32_t OBJECT_FIELD_ENTRY      = 0x000C;
static constexpr uint32_t UNIT_FIELD_TARGET       = 0x0048;
static constexpr uint32_t UNIT_FIELD_HEALTH       = 0x0060;
static constexpr uint32_t UNIT_FIELD_MAXHEALTH    = 0x0080;
static constexpr uint32_t UNIT_FIELD_LEVEL        = 0x0088;
static constexpr uint32_t UNIT_FIELD_FACTIONTEMPLATE = 0x008C;
static constexpr uint32_t UNIT_FIELD_FLAGS        = 0x00EC;
static constexpr uint32_t UNIT_FIELD_FLAGS_2      = 0x00F0;
static constexpr uint32_t UNIT_FIELD_AURASTATE    = 0x00F4;

// Object type masks
static constexpr uint32_t TYPEMASK_OBJECT        = 0x0001;
static constexpr uint32_t TYPEMASK_ITEM          = 0x0002;
static constexpr uint32_t TYPEMASK_CONTAINER     = 0x0004;
static constexpr uint32_t TYPEMASK_UNIT          = 0x0008;
static constexpr uint32_t TYPEMASK_PLAYER        = 0x0010;
static constexpr uint32_t TYPEMASK_GAMEOBJECT    = 0x0020;
static constexpr uint32_t TYPEMASK_DYNAMICOBJECT = 0x0040;
static constexpr uint32_t TYPEMASK_CORPSE        = 0x0080;

// Unit flags
static constexpr uint32_t UNIT_FLAG_NON_ATTACKABLE  = 0x00000002;
static constexpr uint32_t UNIT_FLAG_NOT_SELECTABLE  = 0x02000000;
static constexpr uint32_t UNIT_FLAG_SKINNABLE       = 0x04000000;
static constexpr uint32_t UNIT_FLAG_IN_COMBAT       = 0x00080000;

// NPC flags (from UNIT_NPC_FLAGS descriptor)
static constexpr uint32_t UNIT_NPC_FLAGS_OFFSET     = 0x00DC;
static constexpr uint32_t NPC_FLAG_GOSSIP           = 0x00000001;
static constexpr uint32_t NPC_FLAG_QUESTGIVER       = 0x00000002;
static constexpr uint32_t NPC_FLAG_TRAINER          = 0x00000010;
static constexpr uint32_t NPC_FLAG_VENDOR           = 0x00000080;
static constexpr uint32_t NPC_FLAG_REPAIR           = 0x00001000;
static constexpr uint32_t NPC_FLAG_FLIGHTMASTER     = 0x00002000;
static constexpr uint32_t NPC_FLAG_INNKEEPER        = 0x00010000;
static constexpr uint32_t NPC_FLAG_BANKER           = 0x00020000;
static constexpr uint32_t NPC_FLAG_AUCTIONEER       = 0x00200000;
static constexpr uint32_t NPC_FLAG_STABLEMASTER     = 0x00400000;

// GameObject descriptor offsets (byte offsets from descriptor base)
static constexpr uint32_t GO_DISPLAYID              = 0x0020;
static constexpr uint32_t GO_FLAGS                  = 0x0024;
static constexpr uint32_t GO_PARENTROT              = 0x0028; // 4 floats
static constexpr uint32_t GO_DYNAMIC                = 0x0038;
static constexpr uint32_t GO_FACTION                = 0x003C;
static constexpr uint32_t GO_LEVEL                  = 0x0040;
static constexpr uint32_t GO_BYTES1                 = 0x0044; // type(b0), state(b1), artkit(b2), anim(b3)

// Game Object types (GO_BYTES1 & 0xFF)
static constexpr uint8_t GO_TYPE_DOOR               = 0;
static constexpr uint8_t GO_TYPE_BUTTON             = 1;
static constexpr uint8_t GO_TYPE_QUESTGIVER         = 2;
static constexpr uint8_t GO_TYPE_CHEST              = 3;
static constexpr uint8_t GO_TYPE_BINDER             = 4;
static constexpr uint8_t GO_TYPE_GENERIC            = 5;
static constexpr uint8_t GO_TYPE_TRAP               = 6;
static constexpr uint8_t GO_TYPE_CHAIR              = 7;
static constexpr uint8_t GO_TYPE_SPELL_FOCUS        = 8;
static constexpr uint8_t GO_TYPE_TEXT               = 9;
static constexpr uint8_t GO_TYPE_GOOBER             = 10;
static constexpr uint8_t GO_TYPE_TRANSPORT          = 11;
static constexpr uint8_t GO_TYPE_AREADAMAGE         = 12;
static constexpr uint8_t GO_TYPE_CAMERA             = 13;
static constexpr uint8_t GO_TYPE_MAP_OBJECT         = 14;
static constexpr uint8_t GO_TYPE_CAPTURE_POINT      = 29;

// Game Object state (GO_BYTES1 >> 8 & 0xFF)
static constexpr uint8_t GO_STATE_ACTIVE            = 0;
static constexpr uint8_t GO_STATE_READY             = 1;
static constexpr uint8_t GO_STATE_ACTIVE_ALT        = 2;

// Unit struct offsets (used for direct memory reads)
static constexpr uint32_t UNIT_POS_X_OFFSET         = 0x798;
static constexpr uint32_t UNIT_POS_Y_OFFSET         = 0x79C;
static constexpr uint32_t UNIT_POS_Z_OFFSET         = 0x7A0;
static constexpr uint32_t UNIT_FACING_OFFSET        = 0x7A4;
static constexpr uint32_t UNIT_MOVINFO_OFFSET       = 0xD8;
static constexpr uint32_t MOVINFO_FLAGS_OFFSET      = 0x00;
static constexpr uint32_t MOVINFO_FACING_OFFSET     = 0x18;

// Creature name cache offsets (3.3.5a standard)
static constexpr uint32_t UNIT_NAME_CACHE_PTR       = 0x964;
static constexpr uint32_t NAME_CACHE_NAME_OFFSET    = 0x05C;

// ClickToMove types
static constexpr int CTM_MOVE               = 0x04;
static constexpr int CTM_FACE               = 0x02;
static constexpr int CTM_STOP               = 0x0D;
static constexpr int CTM_FACE_TARGET_GUID   = 0x01;

// Object manager iteration offsets (3.3.5a standard)
static constexpr uint32_t OBJ_MGR_OFFSET     = 0x2ED0;
static constexpr uint32_t FIRST_OBJ_OFFSET   = 0xAC;
static constexpr uint32_t NEXT_OBJ_OFFSET    = 0x3C;
static constexpr uint32_t OBJ_TYPE_OFFSET    = 0x08;
static constexpr uint32_t OBJ_GUID_OFFSET    = 0x30;
static constexpr uint32_t OBJ_DESCRIPTORS    = 0x08;

// ============================================================
// Structs
// ============================================================

#pragma pack(push, 1)
struct WGUID {
    uint32_t Low;
    uint32_t High;
    bool operator==(const WGUID& o) const { return Low == o.Low && High == o.High; }
    bool operator!=(const WGUID& o) const { return !(*this == o); }
    bool IsZero() const { return Low == 0 && High == 0; }
};

struct C3Vector {
    float X, Y, Z;
};

struct SpellCastTargets {
    uint32_t targetMask;
    WGUID    unitTarget;
    WGUID    itemTarget;
    C3Vector srcPosition;
    C3Vector dstPosition;
    float    elevation;
    float    speed;
};
#pragma pack(pop)

// ============================================================
// Typedefs & function pointers
// ============================================================

typedef struct lua_State lua_State;
typedef int  (__cdecl *lua_CFunction)(lua_State* L);
typedef void (__cdecl *FrameScript_Register_t)(const char*, lua_CFunction);
typedef void (__cdecl *FrameScript_Unregister_t)(const char*);
typedef int  (__cdecl *FrameScript_Execute_t)(const char*, const char*, int);
typedef const char* (__cdecl *FrameScript_GetText_t)(const char*, int);

// Raw Lua C API
typedef int    (__cdecl *lua_gettop_t)(lua_State*);
typedef void   (__cdecl *lua_settop_t)(lua_State*, int);
typedef int    (__cdecl *lua_type_t)(lua_State*, int);
typedef double (__cdecl *lua_tonumber_t)(lua_State*, int);
typedef const char* (__cdecl *lua_tolstring_t)(lua_State*, int, size_t*);
typedef void   (__cdecl *lua_pushnumber_t)(lua_State*, double);
typedef void   (__cdecl *lua_pushstring_t)(lua_State*, const char*);
typedef void   (__cdecl *lua_pushnil_t)(lua_State*);
typedef void   (__cdecl *lua_pushboolean_t)(lua_State*, int);
typedef void   (__cdecl *lua_createtable_t)(lua_State*, int, int);
typedef void   (__cdecl *lua_settable_t)(lua_State*, int);
typedef void   (__cdecl *lua_rawseti_t)(lua_State*, int, int);
typedef int    (__cdecl *lua_pcall_t)(lua_State*, int, int, int);

// Game functions
typedef int  (__cdecl *EnumVisibleObjects_t)(int(__cdecl*)(WGUID, void*), void*);
typedef void*(__cdecl *ObjectPtr_t)(WGUID, int);
typedef void*(__cdecl *GetActivePlayerObj_t)(void);
typedef WGUID(__cdecl *GetActivePlayer_t)(void);
typedef void (__thiscall *GetPosition_t)(void*, C3Vector*);
typedef int  (__thiscall *GetHealth_t)(void*);
typedef int  (__thiscall *GetMaxHealth_t)(void*);
typedef float(__thiscall *GetHealthPct_t)(void*);
typedef int  (__thiscall *GetLevel_t)(void*);
typedef int  (__thiscall *CastSpell_t)(void*, int, WGUID*);
typedef bool (__thiscall *ClickToMove_t)(void*, int, WGUID*, C3Vector*, float);
typedef const char* (__cdecl *GetSpellName_t)(int);

// Collision: bool __cdecl CWorld::Intersect(start, end, collFlags, hitPoint, dist, flags2)
typedef bool (__cdecl *CWorld_Intersect_t)(
    C3Vector* start, C3Vector* end,
    int collisionFlags, C3Vector* hitPoint, float* distance, uint32_t flags2);

// CGUnit_C::IsIndoors(this) -> bool (thiscall)
typedef bool (__thiscall *IsIndoors_t)(void*);

// ============================================================
// Function pointer macros — evaluate at call time (after addr::Init)
// Using macros instead of static auto const avoids capturing
// zero values during static initialization before Init() runs.
// ============================================================

#define r_FSReg         ((FrameScript_Register_t)  addr::FrameScript_RegisterFunction)
#define r_FSUnreg       ((FrameScript_Unregister_t)addr::FrameScript_UnregisterFunction)
#define r_FSExec        ((FrameScript_Execute_t)   addr::FrameScript_Execute)
#define r_FSGetText     ((FrameScript_GetText_t)   addr::FrameScript_GetText)
#define r_EnumObjs      ((EnumVisibleObjects_t)    addr::ClntObjMgrEnumVisObjs)
#define r_ObjPtr        ((ObjectPtr_t)             addr::ClntObjMgrObjectPtr)
#define r_GetPlayerObj  ((GetActivePlayerObj_t)    addr::ClntObjMgrGetActivePlayerObj)
#define r_GetPlayerGUID ((GetActivePlayer_t)       addr::ClntObjMgrGetActivePlayer)
#define r_GetPosition   ((GetPosition_t)           addr::CGObject_GetPosition)
#define r_GetHealth     ((GetHealth_t)             addr::CGUnit_GetHealth)
#define r_GetMaxHealth  ((GetMaxHealth_t)          addr::CGUnit_GetMaxHealth)
#define r_GetHealthPct  ((GetHealthPct_t)          addr::CGUnit_GetHealthPct)
#define r_GetLevel      ((GetLevel_t)              addr::CGUnit_GetLevel)
#define r_CastSpell     ((CastSpell_t)             addr::Spell_C_CastSpell)
#define r_ClickToMove   ((ClickToMove_t)           addr::CGPlayer_ClickToMove)
#define r_GetSpellName  ((GetSpellName_t)          addr::Spell_C_GetSpellName)
#define r_Intersect     ((CWorld_Intersect_t)      addr::CWorld_Intersect)
#define r_IsIndoors     ((IsIndoors_t)             addr::CGUnit_IsIndoors)

// Lua C API
#define L_gettop        ((lua_gettop_t)     addr::lua_gettop)
#define L_settop        ((lua_settop_t)     addr::lua_settop)
#define L_type          ((lua_type_t)       addr::lua_type)
#define L_tonumber      ((lua_tonumber_t)   addr::lua_tonumber)
#define L_tolstring     ((lua_tolstring_t)  addr::lua_tolstring)
#define L_pushnumber    ((lua_pushnumber_t) addr::lua_pushnumber)
#define L_pushstring    ((lua_pushstring_t) addr::lua_pushstring)
#define L_pushnil       ((lua_pushnil_t)    addr::lua_pushnil)
#define L_pushboolean   ((lua_pushboolean_t)addr::lua_pushboolean)
#define L_createtable   ((lua_createtable_t)addr::lua_createtable)
#define L_settable      ((lua_settable_t)   addr::lua_settable)
#define L_rawseti       ((lua_rawseti_t)    addr::lua_rawseti)
#define L_pcall         ((lua_pcall_t)      addr::lua_pcall)

static FILE*     g_log     = nullptr;
static bool      g_active  = false;
static HMODULE   g_hModule = nullptr;

// ============================================================
// Helpers
// ============================================================

static void Log(const char* fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fflush(g_log);
}

static bool InWorld() {
    // Check FrameScript active flag at ADDR_g_InWorld
    __try {
        if (*(volatile uint8_t*)ADDR_g_InWorld) return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Fallback: if g_luaState is non-NULL, FrameScript environment exists
    __try {
        if (*(volatile uint32_t*)ADDR_g_luaState != 0) return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return false;
}

static lua_State* GetLuaState() {
    return *(lua_State**)ADDR_g_luaState;
}

static void* GetLocalPlayerPtr() {
    // Method 1: Direct game function
    __try {
        void* p = r_GetPlayerObj();
        if (p) return p;
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 2: Get GUID then look up via ObjectPtr
    __try {
        WGUID guid = r_GetPlayerGUID();
        if (!guid.IsZero()) {
            void* p = r_ObjPtr(guid, 0xFFFF);
            if (p) return p;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 3: Object manager local player GUID at objMgr+0xC0
    __try {
        uint32_t conn = *(uint32_t*)ADDR_g_clientConnection;
        if (conn) {
            uint32_t objMgr = *(uint32_t*)(conn + OBJ_MGR_OFFSET);
            if (objMgr) {
                WGUID localGuid;
                localGuid.Low = *(uint32_t*)(objMgr + 0xC0);
                localGuid.High = *(uint32_t*)(objMgr + 0xC4);
                if (!localGuid.IsZero()) {
                    void* p = r_ObjPtr(localGuid, 0xFFFF);
                    if (p) return p;
                }
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return nullptr;
}

static void GetPlayerPosition(C3Vector* out) {
    void* player = GetLocalPlayerPtr();
    if (!player) { out->X = out->Y = out->Z = 0; return; }
    uintptr_t base = (uintptr_t)player;
    // Method 1: Direct struct offset (CGPlayer position cache at 0x798)
    __try {
        float x = *(float*)(base + UNIT_POS_X_OFFSET);
        float y = *(float*)(base + UNIT_POS_Y_OFFSET);
        float z = *(float*)(base + UNIT_POS_Z_OFFSET);
        if ((x != 0 || y != 0) && x > -50000 && x < 50000) {
            out->X = x; out->Y = y; out->Z = z;
            return;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 2: MovementInfo inline position (unit+0xD8+0x0C)
    __try {
        float x = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x0C);
        float y = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x10);
        float z = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x14);
        if ((x != 0 || y != 0) && x > -50000 && x < 50000) {
            out->X = x; out->Y = y; out->Z = z;
            return;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 3: CGObject::GetPosition
    __try { r_GetPosition(player, out); }
    __except(EXCEPTION_EXECUTE_HANDLER) { out->X = out->Y = out->Z = 0; }
}

static float Distance3D(const C3Vector& a, const C3Vector& b) {
    float dx = a.X - b.X, dy = a.Y - b.Y, dz = a.Z - b.Z;
    return sqrtf(dx*dx + dy*dy + dz*dz);
}

static float Distance2D(const C3Vector& a, const C3Vector& b) {
    float dx = a.X - b.X, dy = a.Y - b.Y;
    return sqrtf(dx*dx + dy*dy);
}

// Read a descriptor field (uint32) from an object
static uint32_t ReadDescriptor(void* obj, uint32_t offset) {
    __try {
        // In 3.3.5a, descriptors pointer is at object + 0x08
        uint32_t* desc = *(uint32_t**)((uintptr_t)obj + OBJ_DESCRIPTORS);
        if (!desc) return 0;
        return desc[offset / 4];
    } __except(EXCEPTION_EXECUTE_HANDLER) { return 0; }
}

// Get object type mask from object
static uint32_t GetObjTypeMask(void* obj) {
    __try {
        return *(uint32_t*)((uintptr_t)obj + OBJ_TYPE_OFFSET);
    } __except(EXCEPTION_EXECUTE_HANDLER) { return 0; }
}

// Get GUID from object
static WGUID GetObjectGUID(void* obj) {
    WGUID g = {0, 0};
    __try {
        uint32_t* desc = *(uint32_t**)((uintptr_t)obj + OBJ_DESCRIPTORS);
        if (desc) {
            g.Low  = desc[OBJECT_FIELD_GUID / 4];
            g.High = desc[(OBJECT_FIELD_GUID + 4) / 4];
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return g;
}

// Check if unit is dead (health == 0)
static bool IsUnitDead(void* unit) {
    __try { return r_GetHealth(unit) <= 0; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return true; }
}

// Check if unit is attackable (not flagged non-attackable or not-selectable)
static bool IsUnitAttackable(void* unit) {
    uint32_t flags = ReadDescriptor(unit, UNIT_FIELD_FLAGS);
    if (flags & UNIT_FLAG_NON_ATTACKABLE) return false;
    if (flags & UNIT_FLAG_NOT_SELECTABLE) return false;
    return true;
}

// Check if unit is in combat
static bool IsUnitInCombat(void* unit) {
    uint32_t flags = ReadDescriptor(unit, UNIT_FIELD_FLAGS);
    return (flags & UNIT_FLAG_IN_COMBAT) != 0;
}

// Get unit position (with fallback offset reads)
static void GetUnitPosition(void* unit, C3Vector* out) {
    uintptr_t base = (uintptr_t)unit;
    // Try direct struct offset first
    __try {
        float x = *(float*)(base + UNIT_POS_X_OFFSET);
        float y = *(float*)(base + UNIT_POS_Y_OFFSET);
        float z = *(float*)(base + UNIT_POS_Z_OFFSET);
        if ((x != 0 || y != 0) && x > -50000 && x < 50000) {
            out->X = x; out->Y = y; out->Z = z;
            return;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Try MovementInfo offset
    __try {
        float x = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x0C);
        float y = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x10);
        float z = *(float*)(base + UNIT_MOVINFO_OFFSET + 0x14);
        if ((x != 0 || y != 0) && x > -50000 && x < 50000) {
            out->X = x; out->Y = y; out->Z = z;
            return;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Fallback: CGObject::GetPosition
    __try { r_GetPosition(unit, out); }
    __except(EXCEPTION_EXECUTE_HANDLER) { out->X = out->Y = out->Z = 0; }
}

// Get unit health percent
static float GetUnitHealthPct(void* unit) {
    __try { return r_GetHealthPct(unit); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return 0.0f; }
}

// Get unit level
static int GetUnitLevel(void* unit) {
    __try { return r_GetLevel(unit); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return 0; }
}

// ============================================================
// Collision & Environment helpers
// ============================================================

// TraceLine: Cast a ray from start to end. Returns true if the ray is BLOCKED
// (i.e., something is between start and end). hitPoint receives the impact location.
// collisionFlags: 0x100111 = terrain+WMO (static geometry), 0x100171 = +doodads
static bool TraceLine(const C3Vector& start, const C3Vector& end,
                      int collisionFlags, C3Vector* hitPoint, float* hitDistance) {
    __try {
        C3Vector s = start, e = end;
        C3Vector hp = {0,0,0};
        float dist = 1.0f;
        bool hit = r_Intersect(&s, &e, collisionFlags, &hp, &dist, 0);
        if (hitPoint) *hitPoint = hp;
        if (hitDistance) *hitDistance = dist;
        return hit;
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Check line-of-sight between two points (returns true if CLEAR, false if blocked)
static bool HasLineOfSight(const C3Vector& from, const C3Vector& to) {
    // Slight height offset to avoid ground clipping
    C3Vector a = from; a.Z += 1.5f;
    C3Vector b = to;   b.Z += 1.5f;
    return !TraceLine(a, b, 0x100111, nullptr, nullptr);
}

// Check if a point is walkable (cast ray downward to find terrain)
static bool GetTerrainHeight(float x, float y, float testZ, float* outZ) {
    C3Vector above = { x, y, testZ + 50.0f };
    C3Vector below = { x, y, testZ - 200.0f };
    C3Vector hit;
    float dist;
    bool gotHit = TraceLine(above, below, 0x100111, &hit, &dist);
    if (gotHit && outZ) {
        *outZ = hit.Z;
        return true;
    }
    return false;
}

// Check if direction is walkable from current position (2D raycast at foot level)
// Returns: 0 = clear, positive = distance to obstacle
static float ProbeDirectionObstacle(const C3Vector& origin, float angle, float probeLen) {
    C3Vector start = origin;
    start.Z += 0.8f; // knee height - catches tables, fences, low walls
    C3Vector end;
    end.X = start.X + probeLen * cosf(angle);
    end.Y = start.Y + probeLen * sinf(angle);
    end.Z = start.Z;

    C3Vector hit;
    float dist;
    // 0x100171 = terrain + WMO + M2 doodads (catches trees, furniture, signs, etc.)
    bool blocked = TraceLine(start, end, 0x100171, &hit, &dist);
    if (blocked) {
        return dist * probeLen; // approximate distance to obstacle
    }
    return 0.0f; // clear
}

// Check if player is indoors
static bool PlayerIsIndoors() {
    void* player = GetLocalPlayerPtr();
    if (!player) return false;
    __try { return r_IsIndoors(player); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Get GO type from GAMEOBJECT_BYTES_1
static uint8_t GetGOType(void* goObj) {
    uint32_t bytes1 = ReadDescriptor(goObj, GO_BYTES1);
    return (uint8_t)(bytes1 & 0xFF);
}

// Get GO state from GAMEOBJECT_BYTES_1
static uint8_t GetGOState(void* goObj) {
    uint32_t bytes1 = ReadDescriptor(goObj, GO_BYTES1);
    return (uint8_t)((bytes1 >> 8) & 0xFF);
}

// Get GO name from string cache (GameObjects have a different cache layout)
// GO name pointer chain: obj+0x1F4 -> +0x00 -> name string
static constexpr uint32_t GO_NAME_CACHE_PTR  = 0x1F4;
static constexpr uint32_t GO_NAME_OFFSET     = 0x000; // first entry in the cache struct

static const char* GetGameObjectName(void* go) {
    __try {
        uint32_t cachePtr = *(uint32_t*)((uintptr_t)go + GO_NAME_CACHE_PTR);
        if (cachePtr) {
            const char* name = (const char*)(*(uint32_t*)(cachePtr + GO_NAME_OFFSET));
            if (name && name[0] > 0x1F && name[0] < 0x7F) {
                for (int i = 0; i < 64 && name[i]; i++) {
                    if ((unsigned char)name[i] < 0x20 && name[i] != 0) return nullptr;
                }
                return name;
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return nullptr;
}

// ============================================================
// Object manager traversal using linked list
// ============================================================

struct UnitData {
    WGUID    guid;
    C3Vector pos;
    float    hpPct;
    int      health;
    int      maxHealth;
    int      level;
    uint32_t flags;
    float    dist;
    bool     inCombat;
    bool     isPlayer;
};

static constexpr int MAX_NEARBY = 128;
static UnitData g_nearbyEnemies[MAX_NEARBY];
static int      g_nearbyCount = 0;

// AutoQuester data structures - nearby units (ALL types, not just enemies)
struct NearbyUnit {
    WGUID    guid;
    C3Vector pos;
    float    facing;
    float    hpPct;
    int      health;
    int      maxHealth;
    int      level;
    uint32_t entryId;
    uint32_t unitFlags;
    uint32_t npcFlags;
    uint32_t factionTemplate;
    float    dist;
    bool     isDead;
    bool     isPlayer;
};

struct NearbyGameObject {
    WGUID    guid;
    C3Vector pos;
    uint32_t entryId;
    uint32_t displayId;
    uint32_t goFlags;
    uint8_t  goType;
    uint8_t  goState;
    float    dist;
    const char* name;  // cached from GO name cache
};

static constexpr int MAX_NEARBY_UNITS = 256;
static NearbyUnit g_nearbyUnits[MAX_NEARBY_UNITS];
static int g_nearbyUnitCount = 0;

static constexpr int MAX_NEARBY_OBJECTS = 128;
static NearbyGameObject g_nearbyObjList[MAX_NEARBY_OBJECTS];
static int g_nearbyObjCount = 0;

// Helper: get creature name from name cache (best-effort)
static const char* GetCreatureName(void* unit) {
    __try {
        uint32_t cachePtr = *(uint32_t*)((uintptr_t)unit + UNIT_NAME_CACHE_PTR);
        if (cachePtr) {
            const char* name = (const char*)(*(uint32_t*)(cachePtr + NAME_CACHE_NAME_OFFSET));
            if (name && name[0] > 0x1F && name[0] < 0x7F) {
                // Validate: check first 32 bytes are printable ASCII or null
                for (int i = 0; i < 32 && name[i]; i++) {
                    if ((unsigned char)name[i] < 0x20 && name[i] != 0) return nullptr;
                }
                return name;
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return nullptr;
}

// Enumerate ALL nearby units (NPCs, players, everything)
static void EnumerateAllUnits(float maxRange) {
    g_nearbyUnitCount = 0;
    if (!InWorld()) return;

    C3Vector playerPos;
    GetPlayerPosition(&playerPos);
    if (playerPos.X == 0 && playerPos.Y == 0 && playerPos.Z == 0) return;

    WGUID playerGUID;
    __try { playerGUID = r_GetPlayerGUID(); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }

    uint32_t connPtr = *(uint32_t*)ADDR_g_clientConnection;
    if (!connPtr) return;

    uint32_t objMgr;
    __try { objMgr = *(uint32_t*)(connPtr + OBJ_MGR_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }
    if (!objMgr) return;

    uint32_t curObj;
    __try { curObj = *(uint32_t*)(objMgr + FIRST_OBJ_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }

    int iterations = 0;
    while (curObj != 0 && curObj != 0xFFFFFFFF && iterations < 8000) {
        iterations++;
        __try {
            uint32_t objType = *(uint32_t*)(curObj + OBJ_TYPE_OFFSET);

            if (objType & TYPEMASK_UNIT) {
                void* unitPtr = (void*)curObj;
                WGUID unitGuid = GetObjectGUID(unitPtr);
                if (unitGuid == playerGUID) goto next_au;

                C3Vector unitPos;
                GetUnitPosition(unitPtr, &unitPos);
                float dist = Distance3D(playerPos, unitPos);
                if (dist > maxRange) goto next_au;
                if (g_nearbyUnitCount >= MAX_NEARBY_UNITS) goto next_au;

                NearbyUnit& u = g_nearbyUnits[g_nearbyUnitCount];
                u.guid = unitGuid;
                u.pos = unitPos;
                u.facing = *(float*)((uintptr_t)unitPtr + UNIT_FACING_OFFSET);
                u.health = r_GetHealth(unitPtr);
                u.maxHealth = r_GetMaxHealth(unitPtr);
                u.hpPct = (u.maxHealth > 0) ? (100.0f * u.health / u.maxHealth) : 0;
                u.level = r_GetLevel(unitPtr);
                u.entryId = ReadDescriptor(unitPtr, OBJECT_FIELD_ENTRY);
                u.unitFlags = ReadDescriptor(unitPtr, UNIT_FIELD_FLAGS);
                u.npcFlags = ReadDescriptor(unitPtr, UNIT_NPC_FLAGS_OFFSET);
                u.factionTemplate = ReadDescriptor(unitPtr, UNIT_FIELD_FACTIONTEMPLATE);
                u.dist = dist;
                u.isDead = (u.health <= 0);
                u.isPlayer = (objType & TYPEMASK_PLAYER) != 0;

                g_nearbyUnitCount++;
            }

            next_au:
            curObj = *(uint32_t*)(curObj + NEXT_OBJ_OFFSET);
        } __except(EXCEPTION_EXECUTE_HANDLER) { break; }
    }
}

// Enumerate nearby game objects
static void EnumerateNearbyGO(float maxRange) {
    g_nearbyObjCount = 0;
    if (!InWorld()) return;

    C3Vector playerPos;
    GetPlayerPosition(&playerPos);
    if (playerPos.X == 0 && playerPos.Y == 0 && playerPos.Z == 0) return;

    uint32_t connPtr = *(uint32_t*)ADDR_g_clientConnection;
    if (!connPtr) return;

    uint32_t objMgr;
    __try { objMgr = *(uint32_t*)(connPtr + OBJ_MGR_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }
    if (!objMgr) return;

    uint32_t curObj;
    __try { curObj = *(uint32_t*)(objMgr + FIRST_OBJ_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }

    int iterations = 0;
    while (curObj != 0 && curObj != 0xFFFFFFFF && iterations < 8000) {
        iterations++;
        __try {
            uint32_t objType = *(uint32_t*)(curObj + OBJ_TYPE_OFFSET);

            if (objType & TYPEMASK_GAMEOBJECT) {
                void* goPtr = (void*)curObj;
                C3Vector goPos;
                r_GetPosition(goPtr, &goPos);
                float dist = Distance3D(playerPos, goPos);
                if (dist > maxRange) goto next_go;
                if (g_nearbyObjCount >= MAX_NEARBY_OBJECTS) goto next_go;

                NearbyGameObject& go = g_nearbyObjList[g_nearbyObjCount];
                go.guid = GetObjectGUID(goPtr);
                go.pos = goPos;
                go.entryId = ReadDescriptor(goPtr, OBJECT_FIELD_ENTRY);
                go.displayId = ReadDescriptor(goPtr, GO_DISPLAYID);
                go.goFlags = ReadDescriptor(goPtr, GO_FLAGS);
                go.goType = GetGOType(goPtr);
                go.goState = GetGOState(goPtr);
                go.dist = dist;
                go.name = GetGameObjectName(goPtr);

                g_nearbyObjCount++;
            }

            next_go:
            curObj = *(uint32_t*)(curObj + NEXT_OBJ_OFFSET);
        } __except(EXCEPTION_EXECUTE_HANDLER) { break; }
    }
}

// Enumerate objects via the linked-list approach (original enemy-only version)
static void EnumerateNearbyEnemies(float maxRange) {
    g_nearbyCount = 0;
    if (!InWorld()) return;

    C3Vector playerPos;
    GetPlayerPosition(&playerPos);
    if (playerPos.X == 0 && playerPos.Y == 0 && playerPos.Z == 0) return;

    WGUID playerGUID;
    __try { playerGUID = r_GetPlayerGUID(); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }

    uint32_t connPtr = *(uint32_t*)ADDR_g_clientConnection;
    if (!connPtr) return;

    uint32_t objMgr;
    __try { objMgr = *(uint32_t*)(connPtr + OBJ_MGR_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }
    if (!objMgr) return;

    uint32_t curObj;
    __try { curObj = *(uint32_t*)(objMgr + FIRST_OBJ_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return; }

    int iterations = 0;
    while (curObj != 0 && curObj != 0xFFFFFFFF && iterations < 8000) {
        iterations++;
        __try {
            uint32_t objType = *(uint32_t*)(curObj + OBJ_TYPE_OFFSET);

            // Check if it's a unit or player
            if (objType & TYPEMASK_UNIT) {
                void* unitPtr = (void*)curObj;
                WGUID unitGuid = GetObjectGUID(unitPtr);

                // Skip self
                if (unitGuid == playerGUID) goto next;

                // Skip dead
                int hp = r_GetHealth(unitPtr);
                if (hp <= 0) goto next;

                // Skip non-attackable
                if (!IsUnitAttackable(unitPtr)) goto next;

                // Get position and check range
                C3Vector unitPos;
                GetUnitPosition(unitPtr, &unitPos);
                float dist = Distance3D(playerPos, unitPos);
                if (dist > maxRange) goto next;

                // Store
                if (g_nearbyCount < MAX_NEARBY) {
                    UnitData& ud = g_nearbyEnemies[g_nearbyCount];
                    ud.guid      = unitGuid;
                    ud.pos       = unitPos;
                    ud.health    = hp;
                    ud.maxHealth = r_GetMaxHealth(unitPtr);
                    ud.hpPct     = (ud.maxHealth > 0) ?
                                   (100.0f * hp / ud.maxHealth) : 0.0f;
                    ud.level     = r_GetLevel(unitPtr);
                    ud.flags     = ReadDescriptor(unitPtr, UNIT_FIELD_FLAGS);
                    ud.dist      = dist;
                    ud.inCombat  = (ud.flags & UNIT_FLAG_IN_COMBAT) != 0;
                    ud.isPlayer  = (objType & TYPEMASK_PLAYER) != 0;
                    g_nearbyCount++;
                }
            }

        next:
            curObj = *(uint32_t*)(curObj + NEXT_OBJ_OFFSET);
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            break;
        }
    }
}

// ============================================================
// LUA C FUNCTIONS (registered into the game's Lua environment)
// ============================================================

// AREngine_GetNearbyEnemies(range)
//   Scans object manager, returns count of hostile units within range.
//   Also builds the serialized data for AREngine_GetEnemyData().
static int Lua_GetNearbyEnemies(lua_State* L) {
    float range = 40.0f;
    if (L_gettop(L) >= 1) {
        range = (float)L_tonumber(L, 1);
    }
    if (range < 1.0f) range = 1.0f;
    if (range > 200.0f) range = 200.0f;

    EnumerateNearbyEnemies(range);
    L_pushnumber(L, (double)g_nearbyCount);
    return 1;
}

// AREngine_GetEnemyInfo(index)
//   Returns info about enemy at index (1-based):
//   guidLow, guidHigh, x, y, z, hpPct, level, dist, inCombat, isPlayer
static int Lua_GetEnemyInfo(lua_State* L) {
    int idx = (int)L_tonumber(L, 1) - 1; // 1-based to 0-based
    if (idx < 0 || idx >= g_nearbyCount) {
        L_pushnil(L);
        return 1;
    }

    const UnitData& ud = g_nearbyEnemies[idx];
    L_pushnumber(L, (double)ud.guid.Low);
    L_pushnumber(L, (double)ud.guid.High);
    L_pushnumber(L, (double)ud.pos.X);
    L_pushnumber(L, (double)ud.pos.Y);
    L_pushnumber(L, (double)ud.pos.Z);
    L_pushnumber(L, (double)ud.hpPct);
    L_pushnumber(L, (double)ud.level);
    L_pushnumber(L, (double)ud.dist);
    L_pushboolean(L, ud.inCombat ? 1 : 0);
    L_pushboolean(L, ud.isPlayer ? 1 : 0);
    return 10;
}

// AREngine_GetPlayerPos()
//   Returns x, y, z, facing
static int Lua_GetPlayerPos(lua_State* L) {
    if (!InWorld()) { L_pushnil(L); return 1; }

    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    C3Vector pos;
    GetPlayerPosition(&pos);

    // Read facing from the unit struct (offset 0x7A4 in CGUnit_C)
    float facing = 0.0f;
    __try { facing = *(float*)((uintptr_t)player + 0x7A4); }
    __except(EXCEPTION_EXECUTE_HANDLER) {}

    L_pushnumber(L, (double)pos.X);
    L_pushnumber(L, (double)pos.Y);
    L_pushnumber(L, (double)pos.Z);
    L_pushnumber(L, (double)facing);
    return 4;
}

// AREngine_GetUnitPos(guidLow, guidHigh)
//   Returns x, y, z for a specific unit by GUID
static int Lua_GetUnitPos(lua_State* L) {
    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 1);
    guid.High = (uint32_t)L_tonumber(L, 2);

    void* obj = r_ObjPtr(guid, 0xFFFF); // any type mask
    if (!obj) { L_pushnil(L); return 1; }

    C3Vector pos;
    GetUnitPosition(obj, &pos);
    L_pushnumber(L, (double)pos.X);
    L_pushnumber(L, (double)pos.Y);
    L_pushnumber(L, (double)pos.Z);
    return 3;
}

// AREngine_GetDistance(guidLow, guidHigh)
//   Returns distance from player to unit
static int Lua_GetDistance(lua_State* L) {
    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 1);
    guid.High = (uint32_t)L_tonumber(L, 2);

    void* obj = r_ObjPtr(guid, 0xFFFF);
    if (!obj) { L_pushnumber(L, 999.0); return 1; }

    C3Vector playerPos, unitPos;
    GetPlayerPosition(&playerPos);
    GetUnitPosition(obj, &unitPos);

    L_pushnumber(L, (double)Distance3D(playerPos, unitPos));
    return 1;
}

// AREngine_FaceUnit(guidLow, guidHigh)
//   Sets player facing toward the given unit. Returns 1 on success, nil on fail.
static int Lua_FaceUnit(lua_State* L) {
    if (!InWorld()) { L_pushnil(L); return 1; }

    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 1);
    guid.High = (uint32_t)L_tonumber(L, 2);

    void* target = r_ObjPtr(guid, 0xFFFF);
    if (!target) { L_pushnil(L); return 1; }

    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    C3Vector playerPos, targetPos;
    GetPlayerPosition(&playerPos);
    GetUnitPosition(target, &targetPos);

    // Calculate angle from player to target
    float angle = atan2f(targetPos.Y - playerPos.Y, targetPos.X - playerPos.X);

    // Set facing directly via the player struct (position offset + facing offset)
    __try {
        // Player facing is at CGUnit_C offset 0x7A4
        *(float*)((uintptr_t)player + 0x7A4) = angle;
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_FaceDirection(angle)
//   Sets player facing to a specific angle (radians)
static int Lua_FaceDirection(lua_State* L) {
    float angle = (float)L_tonumber(L, 1);
    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    __try {
        *(float*)((uintptr_t)player + 0x7A4) = angle;
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_GetObjectCount()
//   Returns total visible object count
static int Lua_GetObjectCount(lua_State* L) {
    if (!InWorld()) { L_pushnumber(L, 0); return 1; }

    uint32_t connPtr = *(uint32_t*)ADDR_g_clientConnection;
    if (!connPtr) { L_pushnumber(L, 0); return 1; }

    uint32_t objMgr;
    __try { objMgr = *(uint32_t*)(connPtr + OBJ_MGR_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { L_pushnumber(L, 0); return 1; }
    if (!objMgr) { L_pushnumber(L, 0); return 1; }

    uint32_t curObj;
    __try { curObj = *(uint32_t*)(objMgr + FIRST_OBJ_OFFSET); }
    __except(EXCEPTION_EXECUTE_HANDLER) { L_pushnumber(L, 0); return 1; }

    int count = 0;
    while (curObj != 0 && curObj != 0xFFFFFFFF && count < 10000) {
        count++;
        __try { curObj = *(uint32_t*)(curObj + NEXT_OBJ_OFFSET); }
        __except(EXCEPTION_EXECUTE_HANDLER) { break; }
    }

    L_pushnumber(L, (double)count);
    return 1;
}

// AREngine_CastSpellOn(spellId, guidLow, guidHigh)
//   Directly calls Spell_C_CastSpell on a specific GUID target
static int Lua_CastSpellOn(lua_State* L) {
    int spellId = (int)L_tonumber(L, 1);
    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 2);
    guid.High = (uint32_t)L_tonumber(L, 3);

    void* player = GetLocalPlayerPtr();
    if (!player || !InWorld()) { L_pushnil(L); return 1; }

    __try {
        int result = r_CastSpell(player, spellId, &guid);
        L_pushnumber(L, (double)result);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_ClickToMove(x, y, z)
//   Issues a click-to-move command
static int Lua_ClickToMove(lua_State* L) {
    C3Vector dest;
    dest.X = (float)L_tonumber(L, 1);
    dest.Y = (float)L_tonumber(L, 2);
    dest.Z = (float)L_tonumber(L, 3);

    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    WGUID nullGuid = {0, 0};
    __try {
        r_ClickToMove(player, CTM_MOVE, &nullGuid, &dest, 0.5f);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_StopMoving()
//   Stops click-to-move
static int Lua_StopMoving(lua_State* L) {
    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    C3Vector pos;
    GetPlayerPosition(&pos);
    WGUID nullGuid = {0, 0};
    __try {
        r_ClickToMove(player, CTM_STOP, &nullGuid, &pos, 0.5f);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_GetUnitHealth(guidLow, guidHigh)
//   Returns current health, max health, health percent
static int Lua_GetUnitHealth(lua_State* L) {
    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 1);
    guid.High = (uint32_t)L_tonumber(L, 2);

    void* obj = r_ObjPtr(guid, 0xFFFF);
    if (!obj) { L_pushnil(L); return 1; }

    __try {
        int hp    = r_GetHealth(obj);
        int maxHp = r_GetMaxHealth(obj);
        float pct = (maxHp > 0) ? (100.0f * hp / maxHp) : 0.0f;
        L_pushnumber(L, (double)hp);
        L_pushnumber(L, (double)maxHp);
        L_pushnumber(L, (double)pct);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
        return 1;
    }
    return 3;
}

// AREngine_GetUnitFlags(guidLow, guidHigh)
//   Returns unit flags and unit flags2
static int Lua_GetUnitFlags(lua_State* L) {
    WGUID guid;
    guid.Low  = (uint32_t)L_tonumber(L, 1);
    guid.High = (uint32_t)L_tonumber(L, 2);

    void* obj = r_ObjPtr(guid, 0xFFFF);
    if (!obj) { L_pushnil(L); return 1; }

    uint32_t flags  = ReadDescriptor(obj, UNIT_FIELD_FLAGS);
    uint32_t flags2 = ReadDescriptor(obj, UNIT_FIELD_FLAGS_2);
    L_pushnumber(L, (double)flags);
    L_pushnumber(L, (double)flags2);
    return 2;
}

// AREngine_GetSpellName(spellId)
//   Returns spell name from the game's spell database
static int Lua_GetSpellNameById(lua_State* L) {
    int spellId = (int)L_tonumber(L, 1);
    __try {
        const char* name = r_GetSpellName(spellId);
        if (name && name[0]) {
            L_pushstring(L, name);
        } else {
            L_pushnil(L);
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_IsLoaded()
//   Returns true - used by the addon to detect if the engine DLL is loaded
static int Lua_IsLoaded(lua_State* L) {
    L_pushboolean(L, 1);
    return 1;
}

// AREngine_GetVersion()
//   Returns engine version string
static int Lua_GetVersion(lua_State* L) {
    L_pushstring(L, "6.1.0");
    return 1;
}

// ============================================================
// AutoQuester: Movement control via game input handlers
// ============================================================

// Movement handler type - same signature as FrameScript Lua C functions
typedef int (__cdecl *LuaHandler_t)(lua_State*);

// Macro to define movement control functions that call the game's input handlers
#define DEFINE_MOVEMENT_FUNC(funcName, handlerAddr)                     \
static int funcName(lua_State* L) {                                     \
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }                  \
    int top = L_gettop(L);                                              \
    __try { ((LuaHandler_t)(handlerAddr))(L); }                         \
    __except(EXCEPTION_EXECUTE_HANDLER) {                               \
        L_settop(L, top); L_pushboolean(L, 0); return 1;               \
    }                                                                   \
    L_settop(L, top);                                                   \
    L_pushboolean(L, 1);                                                \
    return 1;                                                           \
}

DEFINE_MOVEMENT_FUNC(Lua_MoveForwardStart,  ADDR_MoveForwardStart)
DEFINE_MOVEMENT_FUNC(Lua_MoveForwardStop,   ADDR_MoveForwardStop)
DEFINE_MOVEMENT_FUNC(Lua_MoveBackwardStart, ADDR_MoveBackwardStart)
DEFINE_MOVEMENT_FUNC(Lua_MoveBackwardStop,  ADDR_MoveBackwardStop)
DEFINE_MOVEMENT_FUNC(Lua_StrafeLeftStart,   ADDR_StrafeLeftStart)
DEFINE_MOVEMENT_FUNC(Lua_StrafeLeftStop,    ADDR_StrafeLeftStop)
DEFINE_MOVEMENT_FUNC(Lua_StrafeRightStart,  ADDR_StrafeRightStart)
DEFINE_MOVEMENT_FUNC(Lua_StrafeRightStop,   ADDR_StrafeRightStop)
DEFINE_MOVEMENT_FUNC(Lua_Jump,              ADDR_JumpOrAscendStart)

// AREngine_SetPlayerFacing(angle)
//   Writes facing angle to player struct + MovementInfo for server sync.
//   Facing syncs to server on next movement packet (start/stop/heartbeat).
static int Lua_SetPlayerFacing(lua_State* L) {
    float angle = (float)L_tonumber(L, 1);
    // Normalize to [0, 2*PI)
    while (angle < 0) angle += 6.2831853f;
    while (angle >= 6.2831853f) angle -= 6.2831853f;

    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushboolean(L, 0); return 1; }

    __try {
        // Write facing to the visual facing field
        *(float*)((uintptr_t)player + UNIT_FACING_OFFSET) = angle;
        // Also write to MovementInfo facing for packet sync
        *(float*)((uintptr_t)player + UNIT_MOVINFO_OFFSET + MOVINFO_FACING_OFFSET) = angle;
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_GetPlayerFacing()
//   Returns current facing angle in radians [0, 2*PI)
static int Lua_GetPlayerFacing(lua_State* L) {
    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnil(L); return 1; }

    __try {
        float facing = *(float*)((uintptr_t)player + UNIT_FACING_OFFSET);
        L_pushnumber(L, (double)facing);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_GetMovementFlags()
//   Returns movement flags from the player's MovementInfo struct
static int Lua_GetMovementFlags(lua_State* L) {
    void* player = GetLocalPlayerPtr();
    if (!player) { L_pushnumber(L, 0); return 1; }

    __try {
        uint32_t flags = *(uint32_t*)((uintptr_t)player + UNIT_MOVINFO_OFFSET + MOVINFO_FLAGS_OFFSET);
        L_pushnumber(L, (double)flags);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnumber(L, 0);
    }
    return 1;
}

// AREngine_GetMapId()
//   Returns the current continent/map ID
static int Lua_GetMapId(lua_State* L) {
    if (ADDR_g_currentMapId == 0) {
        // Address not yet found — use Lua API fallback
        __try {
            r_FSExec("_cu_mid = tostring(GetCurrentMapAreaID() or -1)", "cu_gm", 0);
            const char* val = r_FSGetText("_cu_mid", 0);
            if (val) {
                L_pushnumber(L, (double)atoi(val));
                return 1;
            }
        } __except(EXCEPTION_EXECUTE_HANDLER) {}
        L_pushnumber(L, -1);
        return 1;
    }
    __try {
        int mapId = *(int*)ADDR_g_currentMapId;
        L_pushnumber(L, (double)mapId);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushnumber(L, -1);
    }
    return 1;
}

// ============================================================
// AutoQuester: Object enumeration Lua functions
// ============================================================

// AREngine_ScanNearbyUnits(range)
//   Scans all units (NPCs, players, mobs) within range. Returns count.
static int Lua_ScanNearbyUnits(lua_State* L) {
    float range = (float)L_tonumber(L, 1);
    if (range <= 0) range = 100.0f;
    if (range > 500.0f) range = 500.0f;

    EnumerateAllUnits(range);
    L_pushnumber(L, (double)g_nearbyUnitCount);
    return 1;
}

// AREngine_GetScannedUnit(index)
//   Returns full details for a scanned unit (1-based index).
//   Returns: guidLow, guidHigh, x, y, z, facing, hpPct, level,
//            entryId, npcFlags, unitFlags, factionTemplate, dist, isDead, isPlayer
static int Lua_GetScannedUnit(lua_State* L) {
    int idx = (int)L_tonumber(L, 1) - 1;
    if (idx < 0 || idx >= g_nearbyUnitCount) { L_pushnil(L); return 1; }

    NearbyUnit& u = g_nearbyUnits[idx];
    L_pushnumber(L, (double)u.guid.Low);       // 1
    L_pushnumber(L, (double)u.guid.High);      // 2
    L_pushnumber(L, (double)u.pos.X);          // 3
    L_pushnumber(L, (double)u.pos.Y);          // 4
    L_pushnumber(L, (double)u.pos.Z);          // 5
    L_pushnumber(L, (double)u.facing);         // 6
    L_pushnumber(L, (double)u.hpPct);          // 7
    L_pushnumber(L, (double)u.level);          // 8
    L_pushnumber(L, (double)u.entryId);        // 9
    L_pushnumber(L, (double)u.npcFlags);       // 10
    L_pushnumber(L, (double)u.unitFlags);      // 11
    L_pushnumber(L, (double)u.factionTemplate);// 12
    L_pushnumber(L, (double)u.dist);           // 13
    L_pushboolean(L, u.isDead ? 1 : 0);       // 14
    L_pushboolean(L, u.isPlayer ? 1 : 0);     // 15
    return 15;
}

// AREngine_GetScannedUnitName(index)
//   Returns creature name from name cache (best-effort, may return nil)
static int Lua_GetScannedUnitName(lua_State* L) {
    int idx = (int)L_tonumber(L, 1) - 1;
    if (idx < 0 || idx >= g_nearbyUnitCount) { L_pushnil(L); return 1; }

    NearbyUnit& u = g_nearbyUnits[idx];
    void* obj = r_ObjPtr(u.guid, 0xFFFF);
    if (!obj) { L_pushnil(L); return 1; }

    const char* name = GetCreatureName(obj);
    if (name) {
        L_pushstring(L, name);
    } else {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_ScanNearbyObjects(range)
//   Scans all game objects within range. Returns count.
static int Lua_ScanNearbyObjects(lua_State* L) {
    float range = (float)L_tonumber(L, 1);
    if (range <= 0) range = 100.0f;
    if (range > 500.0f) range = 500.0f;

    EnumerateNearbyGO(range);
    L_pushnumber(L, (double)g_nearbyObjCount);
    return 1;
}

// AREngine_GetScannedObject(index)
//   Returns: guidLow, guidHigh, x, y, z, entryId, displayId, flags, dist, goType, goState, name
static int Lua_GetScannedObject(lua_State* L) {
    int idx = (int)L_tonumber(L, 1) - 1;
    if (idx < 0 || idx >= g_nearbyObjCount) { L_pushnil(L); return 1; }

    NearbyGameObject& go = g_nearbyObjList[idx];
    L_pushnumber(L, (double)go.guid.Low);      // 1
    L_pushnumber(L, (double)go.guid.High);     // 2
    L_pushnumber(L, (double)go.pos.X);         // 3
    L_pushnumber(L, (double)go.pos.Y);         // 4
    L_pushnumber(L, (double)go.pos.Z);         // 5
    L_pushnumber(L, (double)go.entryId);       // 6
    L_pushnumber(L, (double)go.displayId);     // 7
    L_pushnumber(L, (double)go.goFlags);       // 8
    L_pushnumber(L, (double)go.dist);          // 9
    L_pushnumber(L, (double)go.goType);        // 10
    L_pushnumber(L, (double)go.goState);       // 11
    if (go.name) L_pushstring(L, go.name);     // 12
    else L_pushnil(L);
    return 12;
}

// AREngine_FacingPulse()
//   Brief MoveForwardStart + MoveForwardStop to sync facing with server
//   Use after SetPlayerFacing while stationary to send the facing packet
static int Lua_FacingPulse(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    int top = L_gettop(L);
    __try {
        ((LuaHandler_t)ADDR_MoveForwardStart)(L);
        L_settop(L, top);
        ((LuaHandler_t)ADDR_MoveForwardStop)(L);
        L_settop(L, top);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_settop(L, top);
        L_pushboolean(L, 0);
        return 1;
    }
    L_pushboolean(L, 1);
    return 1;
}

// ============================================================
// Collision & Environment Lua functions
// ============================================================

// AREngine_TraceLine(x1, y1, z1, x2, y2, z2 [, flags])
//   Returns: hit (bool), hitX, hitY, hitZ, hitDist
//   flags default = 0x100111 (terrain + WMO), use 0x100171 to include doodads
static int Lua_TraceLine(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    C3Vector start, end;
    start.X = (float)L_tonumber(L, 1);
    start.Y = (float)L_tonumber(L, 2);
    start.Z = (float)L_tonumber(L, 3);
    end.X   = (float)L_tonumber(L, 4);
    end.Y   = (float)L_tonumber(L, 5);
    end.Z   = (float)L_tonumber(L, 6);
    int flags = (L_gettop(L) >= 7) ? (int)L_tonumber(L, 7) : 0x100111;

    C3Vector hit;
    float dist;
    bool blocked = TraceLine(start, end, flags, &hit, &dist);
    L_pushboolean(L, blocked ? 1 : 0);  // 1
    L_pushnumber(L, (double)hit.X);      // 2
    L_pushnumber(L, (double)hit.Y);      // 3
    L_pushnumber(L, (double)hit.Z);      // 4
    L_pushnumber(L, (double)dist);       // 5
    return 5;
}

// AREngine_HasLineOfSight(x1, y1, z1, x2, y2, z2)
//   Returns: true if clear line-of-sight between two points
static int Lua_HasLOS(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    C3Vector from, to;
    from.X = (float)L_tonumber(L, 1);
    from.Y = (float)L_tonumber(L, 2);
    from.Z = (float)L_tonumber(L, 3);
    to.X   = (float)L_tonumber(L, 4);
    to.Y   = (float)L_tonumber(L, 5);
    to.Z   = (float)L_tonumber(L, 6);
    bool los = HasLineOfSight(from, to);
    L_pushboolean(L, los ? 1 : 0);
    return 1;
}

// AREngine_ProbeDirection(angle, distance)
//   Casts collision ray from player position in given direction at knee height
//   Returns: obstacleDist (0 = clear)
static int Lua_ProbeDirection(lua_State* L) {
    if (!InWorld()) { L_pushnumber(L, 0); return 1; }
    float angle = (float)L_tonumber(L, 1);
    float dist  = (float)L_tonumber(L, 2);
    if (dist <= 0) dist = 5.0f;

    C3Vector playerPos;
    GetPlayerPosition(&playerPos);
    if (playerPos.X == 0 && playerPos.Y == 0 && playerPos.Z == 0) {
        L_pushnumber(L, 0); return 1;
    }
    float obsDist = ProbeDirectionObstacle(playerPos, angle, dist);
    L_pushnumber(L, (double)obsDist);
    return 1;
}

// AREngine_ProbeMulti(numRays, distance)
//   Casts numRays evenly spaced around the player, returns one number per ray
//   Each value = distance to obstacle (0 = clear up to 'distance')
//   Useful for building an obstacle map around the player
static int Lua_ProbeMulti(lua_State* L) {
    if (!InWorld()) { L_pushnumber(L, 0); return 1; }
    int numRays = (int)L_tonumber(L, 1);
    float dist  = (float)L_tonumber(L, 2);
    if (numRays < 1) numRays = 8;
    if (numRays > 36) numRays = 36;
    if (dist <= 0) dist = 6.0f;

    C3Vector playerPos;
    GetPlayerPosition(&playerPos);
    if (playerPos.X == 0 && playerPos.Y == 0 && playerPos.Z == 0) {
        for (int i = 0; i < numRays; i++) L_pushnumber(L, 0);
        return numRays;
    }

    float step = 6.2831853f / (float)numRays;
    for (int i = 0; i < numRays; i++) {
        float angle = (float)i * step;
        float obsDist = ProbeDirectionObstacle(playerPos, angle, dist);
        L_pushnumber(L, (double)obsDist);
    }
    return numRays;
}

// AREngine_GetTerrainHeight(x, y, testZ)
//   Returns: terrainZ (or nil if no terrain found)
static int Lua_GetTerrainHeight(lua_State* L) {
    if (!InWorld()) { L_pushnil(L); return 1; }
    float x  = (float)L_tonumber(L, 1);
    float y  = (float)L_tonumber(L, 2);
    float tz = (float)L_tonumber(L, 3);
    float outZ;
    if (GetTerrainHeight(x, y, tz, &outZ)) {
        L_pushnumber(L, (double)outZ);
    } else {
        L_pushnil(L);
    }
    return 1;
}

// AREngine_IsIndoors()
//   Returns: true/false
static int Lua_IsIndoors(lua_State* L) {
    L_pushboolean(L, PlayerIsIndoors() ? 1 : 0);
    return 1;
}

// AREngine_InteractObject(guidLow, guidHigh)
//   Interacts with a game object by GUID via ClickToMove
static int Lua_InteractObject(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    WGUID target;
    target.Low  = (uint32_t)L_tonumber(L, 1);
    target.High = (uint32_t)L_tonumber(L, 2);
    if (target.IsZero()) { L_pushboolean(L, 0); return 1; }

    __try {
        void* player = GetLocalPlayerPtr();
        if (player) {
            C3Vector dest = {0,0,0};
            // CTM interact action = 0x07 (interact with game object)
            r_ClickToMove(player, 0x07, &target, &dest, 0.5f);
            L_pushboolean(L, 1);
        } else {
            L_pushboolean(L, 0);
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_UseQuestItem(bagSlot, slot)
//   Uses a container item (for quest items that need to be used in the world)
static int Lua_UseQuestItem(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    int bag = (int)L_tonumber(L, 1);
    int slot = (int)L_tonumber(L, 2);
    char buf[128];
    snprintf(buf, sizeof(buf), "UseContainerItem(%d,%d)", bag, slot);
    __try {
        r_FSExec(buf, "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// ============================================================
// AutoQuester: Interaction helpers via FrameScript_Execute
// ============================================================

// AREngine_Diagnose()
//   Returns diagnostic string showing engine state
static int Lua_Diagnose(lua_State* L) {
    char buf[1024];
    int off = 0;

    // InWorld global flag
    bool flagVal = false;
    __try { flagVal = *(bool*)ADDR_g_InWorld; } __except(EXCEPTION_EXECUTE_HANDLER) {}
    off += sprintf(buf + off, "InWorldFlag=%d", (int)flagVal);

    // Client connection
    uint32_t connPtr = 0;
    __try { connPtr = *(uint32_t*)ADDR_g_clientConnection; } __except(EXCEPTION_EXECUTE_HANDLER) {}
    off += sprintf(buf + off, " Conn=0x%X", connPtr);

    // Object manager
    uint32_t objMgr = 0;
    if (connPtr) {
        __try { objMgr = *(uint32_t*)(connPtr + OBJ_MGR_OFFSET); } __except(EXCEPTION_EXECUTE_HANDLER) {}
    }
    off += sprintf(buf + off, " ObjMgr=0x%X", objMgr);

    // First object
    uint32_t firstObj = 0;
    if (objMgr) {
        __try { firstObj = *(uint32_t*)(objMgr + FIRST_OBJ_OFFSET); } __except(EXCEPTION_EXECUTE_HANDLER) {}
    }
    off += sprintf(buf + off, " FirstObj=0x%X", firstObj);

    // Player pointer methods
    void* p1 = nullptr;
    __try { p1 = r_GetPlayerObj(); } __except(EXCEPTION_EXECUTE_HANDLER) {}
    off += sprintf(buf + off, " GetPlayerObj=%p", p1);

    WGUID pguid = {0,0};
    __try { pguid = r_GetPlayerGUID(); } __except(EXCEPTION_EXECUTE_HANDLER) {}
    off += sprintf(buf + off, " GUID=%X:%X", pguid.High, pguid.Low);

    void* p2 = nullptr;
    if (!pguid.IsZero()) {
        __try { p2 = r_ObjPtr(pguid, 0xFFFF); } __except(EXCEPTION_EXECUTE_HANDLER) {}
    }
    off += sprintf(buf + off, " ObjPtr=%p", p2);

    // Local player GUID from objMgr+0xC0
    if (objMgr) {
        WGUID localG = {0,0};
        __try {
            localG.Low = *(uint32_t*)(objMgr + 0xC0);
            localG.High = *(uint32_t*)(objMgr + 0xC4);
        } __except(EXCEPTION_EXECUTE_HANDLER) {}
        off += sprintf(buf + off, " ObjMgrGUID=%X:%X", localG.High, localG.Low);
    }

    // Position from GetLocalPlayerPtr
    void* finalPlayer = GetLocalPlayerPtr();
    off += sprintf(buf + off, " FinalPlayer=%p", finalPlayer);
    if (finalPlayer) {
        C3Vector pos = {0,0,0};
        GetPlayerPosition(&pos);
        off += sprintf(buf + off, " Pos=%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z);
    }

    L_pushstring(L, buf);
    Log("Diagnose: %s\n", buf);
    return 1;
}

// AREngine_InteractTarget()
//   Interacts with current target via FrameScript (bypasses taint completely)
static int Lua_InteractTarget(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    __try {
        r_FSExec("InteractUnit('target')", "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_AttackTarget()
//   Starts auto-attack on current target via FrameScript
static int Lua_AttackTarget(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    __try {
        r_FSExec("AttackTarget()", "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_TargetByName(name)
//   Targets a unit by name via FrameScript (bypasses taint)
static int Lua_TargetByName(lua_State* L) {
    size_t len = 0;
    const char* name = L_tolstring(L, 1, &len);
    if (!name || !InWorld()) { L_pushboolean(L, 0); return 1; }
    // Sanitize name to prevent Lua injection
    char safeName[256];
    int j = 0;
    for (size_t i = 0; i < len && j < 250; i++) {
        char c = name[i];
        if (c >= 0x20 && c <= 0x7E && c != '\\' && c != ']') {
            safeName[j++] = c;
        }
    }
    safeName[j] = 0;
    char buf[512];
    snprintf(buf, sizeof(buf), "TargetUnit([[%s]])", safeName);
    __try {
        r_FSExec(buf, "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_ClearTarget()
//   Clears current target
static int Lua_ClearTarget(lua_State* L) {
    if (!InWorld()) { L_pushboolean(L, 0); return 1; }
    __try {
        r_FSExec("ClearTarget()", "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// AREngine_RunProtected(code)
//   Execute Lua code via FrameScript_Execute (fully taint-free)
static int Lua_RunProtected(lua_State* L) {
    size_t len = 0;
    const char* code = L_tolstring(L, 1, &len);
    if (!code || len == 0) { L_pushboolean(L, 0); return 1; }
    __try {
        r_FSExec(code, "*", 0);
        L_pushboolean(L, 1);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        L_pushboolean(L, 0);
    }
    return 1;
}

// ============================================================
// Registration
// ============================================================

struct LuaFunc {
    const char*    baseName;   // Base name without prefix (e.g. "GetNearbyEnemies")
    lua_CFunction  func;
};

// Configurable prefix — loaded from config JSON at init time.
// Default is something innocuous that blends with normal addon APIs.
// The addon Lua code must use the same prefix.
static char g_funcPrefix[64] = "CU_";  // default prefix - overridden from config

static const LuaFunc g_funcs[] = {
    // Original functions
    { "GetNearbyEnemies", Lua_GetNearbyEnemies },
    { "GetEnemyInfo",     Lua_GetEnemyInfo },
    { "GetPlayerPos",     Lua_GetPlayerPos },
    { "GetUnitPos",       Lua_GetUnitPos },
    { "GetDistance",      Lua_GetDistance },
    { "FaceUnit",         Lua_FaceUnit },
    { "FaceDirection",    Lua_FaceDirection },
    { "GetObjectCount",   Lua_GetObjectCount },
    { "CastSpellOn",     Lua_CastSpellOn },
    { "ClickToMove",      Lua_ClickToMove },
    { "StopMoving",       Lua_StopMoving },
    { "GetUnitHealth",    Lua_GetUnitHealth },
    { "GetUnitFlags",     Lua_GetUnitFlags },
    { "GetSpellName",     Lua_GetSpellNameById },
    { "IsLoaded",         Lua_IsLoaded },
    { "GetVersion",       Lua_GetVersion },
    // Movement control (direct input handler calls)
    { "MoveForwardStart",  Lua_MoveForwardStart },
    { "MoveForwardStop",   Lua_MoveForwardStop },
    { "MoveBackwardStart", Lua_MoveBackwardStart },
    { "MoveBackwardStop",  Lua_MoveBackwardStop },
    { "StrafeLeftStart",   Lua_StrafeLeftStart },
    { "StrafeLeftStop",    Lua_StrafeLeftStop },
    { "StrafeRightStart",  Lua_StrafeRightStart },
    { "StrafeRightStop",   Lua_StrafeRightStop },
    { "Jump",              Lua_Jump },
    // Facing and movement state
    { "SetPlayerFacing",   Lua_SetPlayerFacing },
    { "GetPlayerFacing",   Lua_GetPlayerFacing },
    { "GetMovementFlags",  Lua_GetMovementFlags },
    { "GetMapId",          Lua_GetMapId },
    { "FacingPulse",       Lua_FacingPulse },
    // Object enumeration (AutoQuester)
    { "ScanNearbyUnits",   Lua_ScanNearbyUnits },
    { "GetScannedUnit",    Lua_GetScannedUnit },
    { "GetScannedUnitName",Lua_GetScannedUnitName },
    { "ScanNearbyObjects", Lua_ScanNearbyObjects },
    { "GetScannedObject",  Lua_GetScannedObject },
    // Interaction helpers (AutoQuester v2)
    { "Diagnose",          Lua_Diagnose },
    { "InteractTarget",    Lua_InteractTarget },
    { "AttackTarget",      Lua_AttackTarget },
    { "TargetByName",      Lua_TargetByName },
    { "ClearTarget",       Lua_ClearTarget },
    { "RunProtected",      Lua_RunProtected },
    // Collision & environment (AutoQuester v3)
    { "TraceLine",         Lua_TraceLine },
    { "HasLineOfSight",    Lua_HasLOS },
    { "ProbeDirection",    Lua_ProbeDirection },
    { "ProbeMulti",        Lua_ProbeMulti },
    { "GetTerrainHeight",  Lua_GetTerrainHeight },
    { "IsIndoors",         Lua_IsIndoors },
    { "InteractObject",    Lua_InteractObject },
    { "UseQuestItem",      Lua_UseQuestItem },
    { nullptr, nullptr },
};

static int RegisterAll() {
    int count = 0;
    int fail = 0;
    for (int i = 0; g_funcs[i].baseName; i++) {
        char fullName[128];
        snprintf(fullName, sizeof(fullName), "%s%s", g_funcPrefix, g_funcs[i].baseName);
        __try {
            r_FSReg(fullName, g_funcs[i].func);
            count++;
        }
        __except(EXCEPTION_EXECUTE_HANDLER) {
            Log("  EXCEPTION registering: %s  (GetLastError=%lu)\n",
                fullName, GetLastError());
            fail++;
        }
    }
    Log("  RegisterAll: %d OK, %d FAIL\n", count, fail);
    return count;
}

// Verify that a specific function is visible in the Lua global namespace.
// Uses FrameScript_GetText to read back a type() check.
// funcName should be the fully-qualified name (prefix + baseName).
static bool VerifyRegistration(const char* funcName) {
    __try {
        // Set a temp variable to the type of the function
        char buf[256];
        snprintf(buf, sizeof(buf),
            "_cuv = type(%s) == 'function' and '1' or '0'", funcName);
        r_FSExec(buf, "cv", 0);

        // Read it back
        const char* result = r_FSGetText("_cuv", 0);
        if (result && result[0] == '1') return true;

        Log("  VerifyRegistration(%s): FSGetText returned '%s'\n",
            funcName, result ? result : "(null)");
        return false;
    }
    __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  VerifyRegistration(%s): EXCEPTION\n", funcName);
        return false;
    }
}

// Set a beacon that the addon can check to know init code ran,
// even if C function registration didn't work.
static void SetBeacon(const char* stage) {
    __try {
        char buf[256];
        snprintf(buf, sizeof(buf),
            "_CUE_bcn = '%s'; _CUE_bcn_t = GetTime()", stage);
        r_FSExec(buf, "cub", 0);
        Log("  Beacon set: '%s'\n", stage);
    }
    __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  Beacon set FAILED (exception)\n");
    }
}

// ============================================================
// Watchdog — re-registers every 15s so context transitions don't lose functions
// ============================================================

static volatile bool g_watchdogRunning = false;
static volatile uintptr_t g_lastLuaState = 0; // Track lua state pointer for change detection

static DWORD WINAPI WatchdogThread(LPVOID) {
    Log("[Watchdog] Started\n");
    g_watchdogRunning = true;

    while (g_active) {
        Sleep(5000); // Check every 5 seconds

        // Check InWorld flag — don't register in GlueXML (login/char select)
        uint8_t iwFlag = 0;
        __try { iwFlag = *(volatile uint8_t*)ADDR_g_InWorld; } __except(EXCEPTION_EXECUTE_HANDLER) {}

        uintptr_t currentL = 0;
        __try { currentL = *(volatile uintptr_t*)ADDR_g_luaState; } __except(EXCEPTION_EXECUTE_HANDLER) {}

        if (!iwFlag || !currentL) {
            // Not in world or no Lua state — clear tracking so we re-register when back
            if (g_lastLuaState != 0) {
                Log("[Watchdog] Lost world context (InWorld=%d luaState=0x%08X) — will re-register when ready\n",
                    iwFlag, currentL);
                g_lastLuaState = 0;
            }
            continue;
        }

        // Both InWorld and LuaState are valid — check if state changed
        if (currentL != g_lastLuaState) {
            Log("[Watchdog] Lua state changed: 0x%08X -> 0x%08X (InWorld=%d) — re-registering\n",
                g_lastLuaState, currentL, iwFlag);

            // Brief settle — let the new Lua state finish initialization
            Sleep(2000);

            // Re-verify BOTH conditions haven't changed
            uintptr_t checkL = 0;
            uint8_t checkIW = 0;
            __try { checkL = *(volatile uintptr_t*)ADDR_g_luaState; } __except(EXCEPTION_EXECUTE_HANDLER) {}
            __try { checkIW = *(volatile uint8_t*)ADDR_g_InWorld; } __except(EXCEPTION_EXECUTE_HANDLER) {}
            if (checkL != currentL || !checkIW) {
                Log("[Watchdog] State changed during settle (L=0x%08X IW=%d), retrying next cycle\n",
                    checkL, checkIW);
                continue;
            }

            __try {
                int n = RegisterAll();
                Log("[Watchdog] Re-registered: %d functions\n", n);
                g_lastLuaState = currentL;

                // Set beacon for addon detection
                SetBeacon("watchdog_reregister");
            }
            __except(EXCEPTION_EXECUTE_HANDLER) {
                Log("[Watchdog] RegisterAll exception\n");
            }
        }
    }

    Log("[Watchdog] Stopped\n");
    g_watchdogRunning = false;
    return 0;
}

static void UnregisterAll() {
    for (int i = 0; g_funcs[i].baseName; i++) {
        char fullName[128];
        snprintf(fullName, sizeof(fullName), "%s%s", g_funcPrefix, g_funcs[i].baseName);
        __try { r_FSUnreg(fullName); }
        __except(EXCEPTION_EXECUTE_HANDLER) {}
    }
}

// ============================================================
// DLL entry
// ============================================================

// Diagnostic: dump raw bytes at key addresses
static void DumpDiagnostics() {
    // EXE base address (should be 0x00400000 for no-ASLR 32-bit)
    HMODULE hExe = GetModuleHandleA(NULL);
    Log("  EXE base: %p\n", hExe);

    // Raw bytes at InWorld address
    __try {
        uint8_t  byteVal  = *(volatile uint8_t*)ADDR_g_InWorld;
        uint32_t dwordVal = *(volatile uint32_t*)ADDR_g_InWorld;
        Log("  [0x%08X] InWorld: byte=0x%02X dword=0x%08X\n",
            ADDR_g_InWorld, byteVal, dwordVal);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  [0x%08X] InWorld: ACCESS VIOLATION\n", ADDR_g_InWorld);
    }

    // Lua state pointer
    __try {
        uint32_t luaVal = *(volatile uint32_t*)ADDR_g_luaState;
        Log("  [0x%08X] LuaState: 0x%08X\n", ADDR_g_luaState, luaVal);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  [0x%08X] LuaState: ACCESS VIOLATION\n", ADDR_g_luaState);
    }

    // Client connection
    __try {
        uint32_t connVal = *(volatile uint32_t*)ADDR_g_clientConnection;
        Log("  [0x%08X] ClientConnection: 0x%08X\n", ADDR_g_clientConnection, connVal);
        if (connVal) {
            __try {
                uint32_t objMgr = *(uint32_t*)(connVal + OBJ_MGR_OFFSET);
                Log("    ObjMgr (conn+0x%X): 0x%08X\n", OBJ_MGR_OFFSET, objMgr);
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                Log("    ObjMgr: ACCESS VIOLATION\n");
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  [0x%08X] ClientConnection: ACCESS VIOLATION\n", ADDR_g_clientConnection);
    }

    // Local player
    __try {
        uint32_t playerVal = *(volatile uint32_t*)ADDR_g_localPlayer;
        Log("  [0x%08X] LocalPlayer: 0x%08X\n", ADDR_g_localPlayer, playerVal);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        Log("  [0x%08X] LocalPlayer: ACCESS VIOLATION\n", ADDR_g_localPlayer);
    }
}

static DWORD WINAPI InitThread(LPVOID param) {
    // Open log in the GAME's Logs directory
    char logPath[MAX_PATH];
    GetModuleFileNameA(NULL, logPath, MAX_PATH);
    char* lastSlash = strrchr(logPath, '\\');
    if (lastSlash) {
        strcpy(lastSlash + 1, "Logs\\ext.log");
    }
    {
        char logsDir[MAX_PATH];
        GetModuleFileNameA(NULL, logsDir, MAX_PATH);
        char* ls2 = strrchr(logsDir, '\\');
        if (ls2) { strcpy(ls2 + 1, "Logs"); CreateDirectoryA(logsDir, nullptr); }
    }
    g_log = fopen(logPath, "w");
    Log("ext v6.1.0 initializing...\n");

    // Load addresses from JSON before any game memory access
    if (addr::Init()) {
        Log("[+] Runtime addresses loaded (build %d)\n", addr::GetBuild());
    } else {
        Log("[!] Runtime address loading failed — using compile-time fallbacks\n");
    }

    // Load function prefix from config (engine_config.json next to exe)
    // Format: {"prefix": "CU_"} — if not found, uses default g_funcPrefix
    {
        char cfgPath[MAX_PATH];
        GetModuleFileNameA(NULL, cfgPath, MAX_PATH);
        char* ls = strrchr(cfgPath, '\\');
        if (ls) strcpy(ls + 1, "engine_config.json");
        FILE* cfgFile = fopen(cfgPath, "r");
        if (cfgFile) {
            char cfgBuf[512];
            size_t n = fread(cfgBuf, 1, sizeof(cfgBuf) - 1, cfgFile);
            cfgBuf[n] = '\0';
            fclose(cfgFile);
            // Simple parse: find "prefix" : "value"
            const char* pk = strstr(cfgBuf, "\"prefix\"");
            if (pk) {
                const char* colon = strchr(pk + 8, ':');
                if (colon) {
                    const char* q1 = strchr(colon, '"');
                    if (q1) {
                        q1++;
                        const char* q2 = strchr(q1, '"');
                        if (q2 && (q2 - q1) < (int)sizeof(g_funcPrefix) - 1) {
                            memcpy(g_funcPrefix, q1, q2 - q1);
                            g_funcPrefix[q2 - q1] = '\0';
                        }
                    }
                }
            }
            Log("[+] Function prefix: '%s'\n", g_funcPrefix);
        } else {
            Log("[*] No engine_config.json — using default prefix '%s'\n", g_funcPrefix);
        }
    }

    Log("  Log path: %s\n", logPath);
    Log("  DLL base: %p\n", g_hModule);
    Log("  PID: %lu  TID: %lu\n", GetCurrentProcessId(), GetCurrentThreadId());
    Log("  g_luaState addr: 0x%08X\n", (uintptr_t)ADDR_g_luaState);
    Log("  g_InWorld addr:  0x%08X\n", (uintptr_t)ADDR_g_InWorld);
    Log("  lua_pushstring:  0x%08X\n", addr::lua_pushstring);

    // Dump initial diagnostics
    Log("--- Initial diagnostics ---\n");
    DumpDiagnostics();
    Log("--- End diagnostics ---\n");

    // ---- Phase 1: Wait for InWorld=1 AND g_luaState != NULL ----
    // MUST have BOTH conditions:
    //   - InWorld flag = 1 means FrameXML is active (not GlueXML login screen)
    //   - g_luaState != NULL means Lua environment exists
    // Registering in GlueXML Lua state causes crash during GlueXML→FrameXML transition
    // because lua_close() destroys the state while our closures are registered.
    Log("[Phase 1] Waiting for InWorld=1 AND g_luaState != NULL...\n");
    lua_State* firstL = nullptr;
    bool gotInWorld = false;
    for (int i = 0; i < 6000; i++) { // max 10 minutes
        if (!gotInWorld) {
            __try {
                if (*(volatile uint8_t*)ADDR_g_InWorld) {
                    Log("  InWorld=1 after %d ms\n", i * 100);
                    gotInWorld = true;
                }
            } __except(EXCEPTION_EXECUTE_HANDLER) {}
        }

        if (gotInWorld && !firstL) {
            __try {
                firstL = *(lua_State* volatile*)ADDR_g_luaState;
                if (firstL) {
                    Log("  g_luaState=%p after %d ms\n", firstL, i * 100);
                }
            } __except(EXCEPTION_EXECUTE_HANDLER) {}
        }

        if (gotInWorld && firstL) break;

        // Log diagnostics every 10 seconds
        if (i > 0 && (i % 100) == 0) {
            uint8_t iwFlag = 0;
            uint32_t luaVal = 0;
            __try { iwFlag = *(volatile uint8_t*)ADDR_g_InWorld; } __except(EXCEPTION_EXECUTE_HANDLER) {}
            __try { luaVal = *(volatile uint32_t*)ADDR_g_luaState; } __except(EXCEPTION_EXECUTE_HANDLER) {}
            Log("  Still waiting (%d s) InWorld=%d luaState=0x%08X\n", i / 10, iwFlag, luaVal);
            if (i % 300 == 0) DumpDiagnostics(); // full dump every 30s
        }

        Sleep(100);
    }

    if (!gotInWorld || !firstL) {
        Log("FATAL: Timed out. InWorld=%d luaState=%p. Launching watchdog for recovery.\n",
            gotInWorld, firstL);
        DumpDiagnostics();
        // Still launch watchdog — it will handle registration when conditions are met
        g_active = true;
        g_lastLuaState = 0;
        CreateThread(nullptr, 0, WatchdogThread, nullptr, 0, nullptr);
        Log("[Watchdog] Spawned (timeout recovery mode)\n");
        Log("Init complete (deferred to watchdog).\n");
        return 0;
    }

    // ---- Phase 2: Settle ----
    // Wait for FrameXML to fully initialize and addons to load
    Log("[Phase 2] Settling 3 seconds for FrameXML init...\n");
    Sleep(3000);

    Log("--- Pre-register diagnostics ---\n");
    DumpDiagnostics();
    Log("--- End diagnostics ---\n");

    // ---- Phase 3: Register with retries ----
    // Require BOTH InWorld=1 AND LuaState != NULL before each attempt.
    Log("[Phase 3] Registering functions...\n");
    int regCount = 0;
    for (int attempt = 0; attempt < 5; attempt++) {
        // Re-verify both conditions
        uint8_t iwFlag = 0;
        lua_State* Lcheck = nullptr;
        __try { iwFlag = *(volatile uint8_t*)ADDR_g_InWorld; } __except(EXCEPTION_EXECUTE_HANDLER) {}
        __try { Lcheck = *(lua_State* volatile*)ADDR_g_luaState; } __except(EXCEPTION_EXECUTE_HANDLER) {}
        if (!iwFlag || !Lcheck) {
            Log("  Attempt %d: InWorld=%d LuaState=%p — not ready, waiting 3s...\n",
                attempt + 1, iwFlag, Lcheck);
            Sleep(3000);
            continue;
        }
        Log("  Attempt %d: InWorld=1 LuaState=%p, registering...\n", attempt + 1, Lcheck);
        __try {
            regCount = RegisterAll();
            if (regCount > 0) {
                Log("  Attempt %d: %d functions registered OK\n", attempt + 1, regCount);
                break;
            }
        }
        __except(EXCEPTION_EXECUTE_HANDLER) {
            Log("  Attempt %d: EXCEPTION (code 0x%08X)\n",
                attempt + 1, GetExceptionCode());
        }
        Log("  Attempt %d: retrying in 3s...\n", attempt + 1);
        Sleep(3000);
    }

    if (regCount > 0) {
        Log("SUCCESS: %d functions registered.\n", regCount);
        g_active = true;
        g_lastLuaState = (uintptr_t)firstL; // Track initial state for watchdog
        CreateThread(nullptr, 0, WatchdogThread, nullptr, 0, nullptr);
        Log("[Watchdog] Spawned (tracking luaState=0x%08X)\n", g_lastLuaState);
    } else {
        Log("WARN: Initial registration failed. Watchdog will keep trying.\n");
        g_active = true;
        g_lastLuaState = 0; // Will trigger re-register on first watchdog cycle
        CreateThread(nullptr, 0, WatchdogThread, nullptr, 0, nullptr);
        Log("[Watchdog] Spawned (recovery mode)\n");
    }

    Log("Init complete.\n");
    return 0;
}

// ============================================================
// PEB hiding — unlink DLL from module lists so Warden can't find it
// ============================================================

static void HideFromPEB(HMODULE hMod) {
#ifdef _MSC_VER
    __asm {
        mov eax, fs:[0x30]
        mov eax, [eax + 0x0C]
        mov esi, [eax + 0x0C]
        mov edx, esi
    next_mod:
        mov eax, [esi + 0x18]
        cmp eax, hMod
        je  found_mod
        mov esi, [esi]
        cmp esi, edx
        jne next_mod
        jmp done
    found_mod:
        mov eax, [esi]
        mov ecx, [esi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
        lea edi, [esi + 8]
        mov eax, [edi]
        mov ecx, [edi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
        lea edi, [esi + 16]
        mov eax, [edi]
        mov ecx, [edi + 4]
        mov [ecx], eax
        mov [eax + 4], ecx
    done:
    }
#endif
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    switch (reason) {
    case DLL_PROCESS_ATTACH: {
        g_hModule = hModule;
        DisableThreadLibraryCalls(hModule);

        // Pin this DLL so nothing can unload it (ref count -> permanent)
        HMODULE hPin = nullptr;
        GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            (LPCSTR)&DllMain, &hPin);

        // Unlink from PEB so Warden module enumeration can't find us
        HideFromPEB(hModule);

        CreateThread(nullptr, 0, InitThread, nullptr, 0, nullptr);
        break;
    }

    case DLL_PROCESS_DETACH:
        if (g_active) {
            UnregisterAll();
            g_active = false;
        }
        if (g_log) {
            Log("ext unloading.\n");
            fclose(g_log);
            g_log = nullptr;
        }
        break;
    }
    return TRUE;
}
