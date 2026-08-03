#include "ObjectManager.h"
#include "Offsets.h"
#include "AddressDB.h"
#include "GameTime.h"
#include "Guard.h"
#include "Mem.h"
#include "core/Config.h"
#include "core/Log.h"
#include "lua/Lua.h"
#include <mutex>
#include <cmath>
#include <algorithm>
#include <cstdio>
#include <Windows.h>

namespace RL::Game::OM {
namespace {

// Forward: used by FillPod before the full multi-method definition below.
Vec3 ReadPosOffsets(uintptr_t ptr, bool isLocal = false);

using fnGetActive = uint64_t(__cdecl*)();
// 3.3.5: ObjectPtr(guid, typeMask) - typeMask -1 = any type
using fnObjectPtr = uintptr_t(__cdecl*)(uint64_t, int);
// Callback: (guidLow,guidHigh as uint64, userArg) - 3 dwords on stack, caller cleans 0xC
using fnEnum = void(__cdecl*)(int(__cdecl*)(uint64_t, void*), void*);
using fnGetCamera = uintptr_t(__cdecl*)();
using fnCTM = void(__thiscall*)(uintptr_t, uint32_t, uint64_t*, Vec3*, float);
// Spell_C_CastSpell: __cdecl (spellId, itemId, guidLo, guidHi, isTrade)
using fnCastSpell = int(__cdecl*)(int /*spellId*/, int /*itemId*/,
                                  uint32_t /*guidLo*/, uint32_t /*guidHi*/, int /*isTrade*/);
using fnIntersect = bool(__cdecl*)(Vec3*, Vec3*, Vec3*, float*, uint32_t, uintptr_t);

std::mutex g_mu;
std::vector<Object> g_all;
std::vector<Object> g_byType[8];
ULONGLONG g_lastRefresh = 0;

// 2026-08-01 (0x512B07 crash fix): object enumeration must NOT run inside the
// game's Lua VM call chain (it writes to objects mid-walk and, under the deep
// Lua_IsLinuxClient -> Dispatch -> OM stack, corrupts the VM's stack/TValues ->
// later "Lua calls 0x512B00 with garbage" crash). Set true by the bridge around
// every RuntimeCall; enumeration is deferred while set. Thread-local is fine -
// the bridge and the rotation all run on the game main thread.
static thread_local bool g_inLuaContext = false;

// After one AV, never re-enter EnumVisibleObjects for this process inject.
// (Previously SafeEnumVisible swallowed the AV, Refresh "succeeded", and every
//  frame retried -> thousands of 0xC0000005 log lines and possible heap damage.)
bool g_enumDead = false;
bool g_enumDeadLogged = false;
int g_lastEnumRc = 1;

// POD-only staging buffer filled from the enum callback.
// MUST NOT use C++ types with destructors here - the callback runs under SEH.
// If an AV aborts mid-callback, abandoned std::string/vector state corrupts the heap.
struct Pod {
    uint64_t guid;
    uintptr_t ptr;
    int type;
    int entry;
    float x, y, z;
    float facing;
    int health;
    int maxHealth;
    int level;
    uint32_t unitFlags;
    uint32_t dynamicFlags;
    int faction;
    uint64_t unitTarget;
    float scale;
    uint32_t goBytes1;
    uint32_t npcFlags;
    int creatureType; // CREATURE_TYPE_* (8 = CRITTER); -1 unknown (players/GO)
};
static constexpr size_t kMaxEnum = 2048;
Pod g_pods[kMaxEnum];
size_t g_podCount = 0;

fnGetActive GetActive() { return reinterpret_cast<fnGetActive>(Offsets::F().ClntObjMgrGetActivePlayer); }
// ObjectPtr(guidLo, guidHi, typeMask) - 3 args on x86
using fnObjectPtr3 = uintptr_t(__cdecl*)(uint32_t, uint32_t, int);
fnObjectPtr ObjPtr() {
    // Adapter: our old typedef was (uint64, int); keep GetActive path via SafeObjectPtr
    return reinterpret_cast<fnObjectPtr>(Offsets::F().ClntObjMgrObjectPtr);
}
fnEnum EnumVis() { return reinterpret_cast<fnEnum>(Offsets::F().ClntObjMgrEnumVisibleObjects); }
fnGetCamera Cam() { return reinterpret_cast<fnGetCamera>(Offsets::F().GetCamera); }
fnCTM CTM() { return reinterpret_cast<fnCTM>(Offsets::F().ClickToMove); }
fnCastSpell CastSpellFn() {
    uintptr_t a = Offsets::F().Spell_C_CastSpell;
    if (!a) a = 0x0080DA40;
    return reinterpret_cast<fnCastSpell>(a);
}
fnIntersect Intersect() { return reinterpret_cast<fnIntersect>(Offsets::F().WorldIntersect); }

// Decode TypeID from a raw dword that may be TypeID (0..7) or TypeMask (bitfield).
int TypeFromRaw(uint32_t raw) {
    if (raw <= 7) return (int)raw;
    // TypeMask form (classic): bit0=Object bit1=Item bit2=Container bit3=Unit bit4=Player bit5=GO ...
    if (raw & 0x10) return (int)ObjectType::Player;       // TYPEMASK_PLAYER
    if (raw & 0x08) return (int)ObjectType::Unit;         // TYPEMASK_UNIT (also set on players)
    if (raw & 0x20) return (int)ObjectType::GameObject;   // TYPEMASK_GAMEOBJECT
    if (raw & 0x40) return (int)ObjectType::DynamicObject;
    if (raw & 0x80) return (int)ObjectType::Corpse;
    if (raw & 0x04) return (int)ObjectType::Container;
    if (raw & 0x02) return (int)ObjectType::Item;
    return (int)ObjectType::None;
}

// 3.3.5 high-guid type - try both Trinity (>>48) and high-dword top16 layouts.
// Ascension/private builds vary creature hiparts; treat known creature-ish
// F1xx ranges as Unit so OM classification does not drop NPCs.
int TypeFromGuid(uint64_t guid) {
    uint32_t hi48 = (uint32_t)(guid >> 48);
    uint32_t hi32 = (uint32_t)(guid >> 32);
    uint32_t hiTop = hi32 >> 16;
    uint32_t candidates[3] = { hi48, hiTop, hi32 & 0xFFFF };
    for (uint32_t hi : candidates) {
        switch (hi) {
        case 0x0000:
            // Only treat as player when the upper 32 bits are fully zero (standard player GUID)
            if (hi32 == 0 && (uint32_t)guid != 0) return (int)ObjectType::Player;
            break;
        case 0x0001: // some clients use type-1 player/pet variants
            if ((uint32_t)guid != 0) return (int)ObjectType::Player;
            break;
        case 0x4000: return (int)ObjectType::Item;
        case 0xF130: case 0xF131: case 0xF140: case 0xF141:
        case 0xF150: case 0xF151: case 0xF160: case 0xF161:
        case 0xF170: // vehicle / unit variants seen on private forks
            return (int)ObjectType::Unit;
        case 0xF110: case 0xF111: case 0xF120: case 0xF121:
        case 0x1FC0: case 0x1FC1:
            return (int)ObjectType::GameObject;
        case 0xF100: return (int)ObjectType::DynamicObject;
        case 0xF101: return (int)ObjectType::Corpse;
        default:
            // Broad creature band: 0xF1xx excluding known non-units above.
            if ((hi & 0xFF00) == 0xF100 && hi != 0xF100 && hi != 0xF101
                && hi != 0xF110 && hi != 0xF111 && hi != 0xF120 && hi != 0xF121)
                return (int)ObjectType::Unit;
            break;
        }
    }
    return (int)ObjectType::None;
}

// CRASH ELIMINATED (2026-08-01): a "get object type" thiscall was pointed at
// 0x004D3A40 — but disassembly shows 0x4D3A40 is the EPILOGUE of a SETTER
// that WRITES [esi+0x2D0]/[esi+0x2D4] (esi = the object). Calling it on a
// freed object was the exact AV_WRITE UAF at 0x004D3A40 (fault = obj+0x2D0)
// seen on 01:11 and 01:34. The object type is read safely from ptr+0x14 and
// the GUID hipart below — no game-function call needed.

int ResolveType(uintptr_t ptr, uint64_t guid) {
    // 1) Single byte / dword at classic Type offset 0x14 (TypeID or TypeMask)
    uint32_t raw14 = Mem::Read<uint32_t>(ptr + 0x14);
    int t = TypeFromRaw(raw14 & 0xFF); // prefer low byte as TypeID
    if (t == (int)ObjectType::None) t = TypeFromRaw(raw14);

    // 3) GUID hipart
    int gtype = TypeFromGuid(guid);
    if (gtype != (int)ObjectType::None) {
        // Prefer GUID for unit/player/go when field said Object/None
        if (t == (int)ObjectType::None || t == 0)
            t = gtype;
        else if (gtype == (int)ObjectType::Unit && t != (int)ObjectType::Player)
            t = gtype; // recover NPCs mislabeled as GO/Item
    }

    // 4) Heuristic: unit-like position + non-zero health descriptor -> Unit/Player
    if (t == (int)ObjectType::None || t == 0) {
        float x = Mem::Read<float>(ptr + Offsets::O().Position);
        float y = Mem::Read<float>(ptr + Offsets::O().Position + 4);
        uintptr_t d = Mem::Read<uintptr_t>(ptr + Offsets::O().Descriptor);
        int hp = 0, mhp = 0;
        if (d && Mem::Readable(d)) {
            hp = Mem::Read<int>(d + Offsets::D().Health);
            mhp = Mem::Read<int>(d + Offsets::D().MaxHealth);
        }
        if ((x != 0.f || y != 0.f) && x > -50000.f && x < 50000.f && mhp > 0) {
            t = (gtype == (int)ObjectType::Player) ? (int)ObjectType::Player : (int)ObjectType::Unit;
        } else if ((x != 0.f || y != 0.f) && x > -50000.f && x < 50000.f) {
            // Has world position but no HP -> likely GO
            t = (int)ObjectType::GameObject;
        }
    }

    if (t < 0 || t > 7) t = (int)ObjectType::None;
    return t;
}

// Offset-only field fill - NO thiscalls here (runs under enum SEH).
// Live samples (1.4.4): raw14 is TypeID (1=Item, 2=Container, 4=Player, 5=GO).
void FillPod(Pod* o) {
    if (!o || !o->ptr) return;

    uint32_t raw14 = Mem::Read<uint32_t>(o->ptr + 0x14);
    int t = (int)(raw14 & 0xFF);
    if (t < 0 || t > 7) t = TypeFromRaw(raw14);
    if (t < 0 || t > 7) t = TypeFromGuid(o->guid);
    o->type = t;

    uintptr_t d = Mem::Read<uintptr_t>(o->ptr + Offsets::O().Descriptor);
    if (d && Mem::Readable(d)) {
        o->entry = Mem::Read<int>(d + Offsets::D().Entry);
        o->health = Mem::Read<int>(d + Offsets::D().Health);
        o->maxHealth = Mem::Read<int>(d + Offsets::D().MaxHealth);
        o->level = Mem::Read<int>(d + Offsets::D().Level);
        // Per-type descriptor fields - o->type is resolved just above. Reading
        // the unit offsets on a gameobject lands outside its descriptor entirely
        // (see Offsets.h), which fed the object list garbage dynamic flags.
        if (o->type == (int)ObjectType::GameObject) {
            o->unitFlags = Mem::Read<uint32_t>(d + Offsets::D().GoFlags);
            o->dynamicFlags = Mem::Read<uint32_t>(d + Offsets::D().GoDynamic) & 0xFFFF;
            o->faction = 0;
            o->unitTarget = 0;
            o->goBytes1 = Mem::Read<uint32_t>(d + Offsets::D().GoBytes1);
            o->npcFlags = 0;
            o->creatureType = -1;
        } else if (o->type == (int)ObjectType::Unit || o->type == (int)ObjectType::Player) {
            o->unitFlags = Mem::Read<uint32_t>(d + Offsets::D().Flags);
            o->dynamicFlags = Mem::Read<uint32_t>(d + Offsets::D().DynamicFlags);
            // Only unit/player descriptors are long enough for these fields.
            o->faction = Mem::Read<int>(d + Offsets::D().FactionTemplate);
            o->unitTarget = Mem::Read<uint64_t>(d + 0x48); // UNIT_FIELD_TARGET
            o->npcFlags = Mem::Read<uint32_t>(d + 0x10C);  // UNIT_FIELD_NPC_FLAGS (pinned)
            o->goBytes1 = 0;
            // CREATURE TYPE (2026-08-02): the client's CGUnit_C::GetCreatureType
            // reads [unit+0xD0] -> byte [ptr+0x1D3] (verified disasm 0x71F300,
            // the same path lua_UnitCreatureType uses). CREATURE_TYPE_CRITTER=8.
            // Critters must NEVER appear in AuraSearch/NearbyHostiles — the
            // old faction-only hostile filter let them through (critters have
            // a non-player faction -> "different faction => hostile").
            o->creatureType = -1;
            if (o->type == (int)ObjectType::Unit && o->ptr) {
                uintptr_t ctPtr = Mem::Read<uintptr_t>(o->ptr + 0xD0);
                if (ctPtr && Mem::Readable(ctPtr)) {
                    o->creatureType = Mem::Read<uint8_t>(ctPtr + 0x1D3);
                }
            }
        } else {
            // Item/container/etc.: do NOT read unit descriptor tails (load crash).
            o->unitFlags = 0;
            o->dynamicFlags = 0;
            o->faction = 0;
            o->unitTarget = 0;
            o->goBytes1 = 0;
            o->npcFlags = 0;
            o->creatureType = -1;
        }
        o->scale = Mem::Read<float>(d + Offsets::D().Scale);
        if (o->scale <= 0.f) o->scale = 1.f;
        // GUID from descriptors if missing
        if (!o->guid)
            o->guid = Mem::Read<uint64_t>(d); // OBJECT_FIELD_GUID
    } else {
        o->scale = 1.f;
        o->faction = 0;
        o->unitTarget = 0;
    }

    // Position during enum/list: FIXED offsets only. Full ReadPosOffsets brute
    // scan (0x40..0x900) on every object at world entry AVs/lags character load.
    // Single-guid Position() still uses the multi-method path (no NPC brute).
    if (t == (int)ObjectType::Unit || t == (int)ObjectType::Player ||
        t == (int)ObjectType::GameObject || t == (int)ObjectType::Corpse ||
        t == (int)ObjectType::DynamicObject) {
        float x = Mem::Read<float>(o->ptr + Offsets::O().Position);
        float y = Mem::Read<float>(o->ptr + Offsets::O().Position + 4);
        float z = Mem::Read<float>(o->ptr + Offsets::O().Position + 8);
        // Ascension: many units store XYZ at obj+0xE8 (live scan). Prefer when
        // classic Position is zero/garbage so multi-dot packs have real yards.
        auto looks = [](float px, float py) -> bool {
            return (px != 0.f || py != 0.f) && px > -20000.f && px < 20000.f
                && py > -20000.f && py < 20000.f;
        };
        if (!looks(x, y)) {
            float ex = Mem::Read<float>(o->ptr + 0xE8);
            float ey = Mem::Read<float>(o->ptr + 0xEC);
            float ez = Mem::Read<float>(o->ptr + 0xF0);
            if (looks(ex, ey)) { x = ex; y = ey; z = ez; }
        }
        if (!looks(x, y)) {
            // MovementInfo* +0xD8 common layout (no scan).
            uintptr_t mov = Mem::Read<uintptr_t>(o->ptr + 0xD8);
            if (mov && Mem::Readable(mov)) {
                x = Mem::Read<float>(mov + 0x10);
                y = Mem::Read<float>(mov + 0x14);
                z = Mem::Read<float>(mov + 0x18);
            }
        }
        o->x = x; o->y = y; o->z = z;
        o->facing = Mem::Read<float>(o->ptr + Offsets::O().Facing);
        if (o->facing == 0.f)
            o->facing = Mem::Read<float>(o->ptr + 0x7A4);
    }
}

// OM list / enum discovery (Ascension Live)
constexpr uintptr_t kClientConnection = 0x00C79CE0;
constexpr uintptr_t kObjMgrGlobal     = 0x00CD87A8; // SDK g_objectManager
constexpr uintptr_t kObjMgrOff        = 0x2ED0;
constexpr uintptr_t kFirstObjOff      = 0xAC;
constexpr uintptr_t kNextObjOff       = 0x3C;
constexpr uintptr_t kObjGuidOff       = 0x30;
// SDK alternate EnumVisibleObjects (our primary is 0x4D4B30 - misses units)
constexpr uintptr_t kEnumVisAlt       = 0x004D3D50;

int g_objPtrMiss = 0;
int g_listDiagConn = 0, g_listDiagMgr = 0, g_listDiagFirst = 0, g_listDiagIters = 0;

// ============================================================
// OM probe / diagnostic (1.7)
//
// Fires once per Refresh when the "om.probe" config flag is "1", or when the
// first Refresh after inject shows units==0 while enum callbacks arrived.
// Records first-N guids received via enum, per-guid ObjectPtr attempts, and
// list-walker candidate matrix. Used to converge the OM ceiling live.
// ============================================================
static constexpr size_t kProbeMax = 16;
struct ProbeEntry {
    uint64_t guid;
    uintptr_t ptrMinus1;    // ObjectPtr(guid, -1)
    uintptr_t ptrMaskFFFF;  // ObjectPtr(guid, 0xFFFF)
    uintptr_t ptrMaskUnit;  // ObjectPtr(guid, 0x18)  units
    uintptr_t ptrMaskPlyr;  // ObjectPtr(guid, 0x10)  players
    uintptr_t ptrMaskGO;    // ObjectPtr(guid, 0x20)  gameobjects
};
static ProbeEntry g_probeEntries[kProbeMax];
static size_t g_probeCount = 0;
static bool g_probeArmed = false;
static int g_enumCbCallCount = 0;    // total callback invocations for the current Refresh
static int g_enumCbSeenGuids = 0;    // callbacks with non-zero guid

// Forward: AcceptObjPtr / TLS mgr defined with SafeObjectPtr below.
static uintptr_t AcceptObjPtr(uintptr_t p);
static uintptr_t ClntObjMgrFromTls();

// ObjectPtr(guidLo, guidHi, typeMask) - 3 args (disasm @ 0x4D4DB0)
uintptr_t ObjectPtrOne(uint64_t guid, int mask) {
    auto fn = reinterpret_cast<fnObjectPtr3>(Offsets::F().ClntObjMgrObjectPtr);
    if (!fn || !guid) return 0;
    uintptr_t p = 0;
    {
        Guard::Scope g;
        if (!g.Caught()) {
            p = fn((uint32_t)guid, (uint32_t)(guid >> 32), mask);
        }
    }
    // NEVER VirtualQuery (Committed) here: enum calls this 100s of times/frame
    // and that alone tanks FPS. NEVER reject high-2GB heap (LAA) — units live
    // there; Mem::Committed / old high-address reject left units=0 forever
    // (only mouseover tokens worked). Accept + SEH on later reads is enough.
    return AcceptObjPtr(p);
}

// Forward: full resolver (masks + hash).
uintptr_t SafeObjectPtr(uint64_t guid);

// ---- Snapshot-first object access (2026-08-02) ----------------------------
// The rotation's per-unit reads (position / combat reach / bounding radius /
// facing / type / flags) all target GUIDs that came FROM this snapshot. Read
// them from the cached g_all instead of calling ObjectPtr (a game call that
// AVs on stale GUIDs and corrupts the stack — the Guard-recovery crash vector,
// live 1.10.69 RVA 0x788A while the addon scanned units per-tick).
//
// SAFETY: g_all is written ONLY on the game main thread (Refresh/SoftRefresh
// via the bridge) and every accessor below is also main-thread, so a lock-free
// scan is safe — and it avoids recursive-lock deadlocks (OmWalkAllowed calls
// Position while BuildUnitSnapshotLocked holds g_mu). These are defined here
// (before the packers) so AuraSearchPacked / NearbyHostilesPacked / SoftRefresh
// use snapshot-only pointers too — never the ObjectPtr game call from the VM.
static const Object* SnapByGuid(uint64_t guid) {
    if (!guid) return nullptr;
    const std::vector<Object>& v = g_all;
    for (size_t i = 0; i < v.size(); ++i)
        if (v[i].guid == guid) return &v[i];
    return nullptr;
}

// Snapshot-only object pointer for descriptor reads. The pointer is the
// snapshot's cached ptr; subsequent descriptor reads are all VirtualQuery-
// guarded Mem::Read (pure memory, can never AV). Returns 0 for GUIDs not in
// the snapshot — callers treat 0/unknown as "no measurement" (never a hard
// block, never a game call).
static uintptr_t SnapPtr(uint64_t guid) {
    if (const Object* o = SnapByGuid(guid)) return o->ptr;
    return 0;
}

uintptr_t ObjectPtrMulti(uint64_t guid) {
    // Enum hot path ONLY — never CallHashLookup here (world-entry AV risk).
    // Hash remains available via SafeObjectPtr for single-guid accessors.
    if (!guid) return 0;
    if (uintptr_t p = ObjectPtrOne(guid, -1)) return p;
    if (uintptr_t p = ObjectPtrOne(guid, 0x18)) return p; // UNIT|PLAYER
    if (uintptr_t p = ObjectPtrOne(guid, 0x08)) return p; // UNIT
    if (uintptr_t p = ObjectPtrOne(guid, 0x10)) return p; // PLAYER
    if (uintptr_t p = ObjectPtrOne(guid, 0xFFFF)) return p;
    return 0;
}

void PushPodAt(uintptr_t cur, uint64_t guidHint) {
    if (g_podCount >= kMaxEnum) return;
    if (!cur || !Mem::Readable(cur)) return;
    Pod* o = &g_pods[g_podCount];
    o->guid = guidHint;
    o->ptr = cur;
    o->type = 0;
    o->entry = 0;
    o->x = o->y = o->z = 0.f;
    o->facing = 0.f;
    o->health = o->maxHealth = o->level = 0;
    o->unitFlags = o->dynamicFlags = 0;
    o->faction = 0;
    o->unitTarget = 0;
    o->scale = 1.f;
    if (!o->guid && Mem::Readable(cur + kObjGuidOff))
        o->guid = Mem::Read<uint64_t>(cur + kObjGuidOff);
    FillPod(o);
    if (o->type >= 0 && o->type <= 7)
        ++g_podCount;
}

// Returns objects found this walk (into cleared g_pods). Reads are
// VirtualQuery-guarded (Mem::Read) — SEH does not dispatch in this stealth
// module, so the walk must never fault. The __try remains only as a belt-and-
// suspenders net for game-function callers, not as the safety mechanism.
int WalkListIntoPods(uintptr_t mgr, uintptr_t firstOff, uintptr_t nextOff) {
    g_podCount = 0;
    if (!mgr || !Mem::Readable(mgr)) return -3;
    // Checkpoint so an AV mid-walk does not leave partially-populated slots
    // that PodsToVectors would then hand out as "valid" garbage pointers.
    const size_t checkpoint = g_podCount;
    uintptr_t cur = 0;
    cur = Mem::Read<uintptr_t>(mgr + firstOff);
    g_listDiagFirst = (int)cur;
    int iter = 0;
    while (cur && cur != 0xFFFFFFFFu && iter < 8000 && g_podCount < kMaxEnum) {
        ++iter;
        if (!Mem::Readable(cur) || !Mem::Readable(cur + 0x40)) break;
        PushPodAt(cur, 0);
        uintptr_t next = Mem::Read<uintptr_t>(cur + nextOff);
        if (next == cur) break;
        cur = next;
    }
    g_listDiagIters = iter;
    return (int)g_podCount;
}

// Keep best single list walk (most objects). Staging buffer for candidate.
Pod g_listBest[kMaxEnum];
size_t g_listBestN = 0;

void ConsiderListCandidate() {
    if (g_podCount > g_listBestN) {
        g_listBestN = g_podCount;
        for (size_t i = 0; i < g_listBestN; ++i)
            g_listBest[i] = g_pods[i];
    }
}

// Cached winning list offsets - NEVER brute-force 5?4?2 walks every refresh
// (that was a main-thread freeze / crash risk on world entry).
static uintptr_t g_listMgr = 0;
static uintptr_t g_listFirstOff = 0xAC;
static uintptr_t g_listNextOff = 0x3C;
static bool g_listOffsetsKnown = false;
static bool g_listProbeDone = false;

int SafeWalkObjectList() {
    g_podCount = 0;
    g_listBestN = 0;
    g_listDiagConn = g_listDiagMgr = g_listDiagFirst = g_listDiagIters = 0;

    // ONLY ClientConnection+0x2ED0 (proven). TLS ClntObjMgr + multi-offset probe
    // crashed character load on this client (2026-07-31). EnumVisibleObjects
    // supplies world units; list walk is a complement, not a matrix search.
    uintptr_t mgrA = 0;
    if (Mem::Readable(kClientConnection)) {
        uintptr_t conn = Mem::Read<uintptr_t>(kClientConnection);
        g_listDiagConn = (int)conn;
        if (conn && Mem::Readable(conn + kObjMgrOff))
            mgrA = Mem::Read<uintptr_t>(conn + kObjMgrOff);
    }
    g_listDiagMgr = (int)mgrA;
    if (!mgrA || !Mem::Readable(mgrA)) return -1;

    // Classic first@0xAC next@0x3C only — never probe alternate heads at load.
    g_listMgr = mgrA;
    g_listFirstOff = 0xAC;
    g_listNextOff = 0x3C;
    g_listOffsetsKnown = true;
    g_listProbeDone = true;

    int n = WalkListIntoPods(mgrA, 0xAC, 0x3C);
    if (n <= 0) return -1;
    g_listBestN = g_podCount;
    for (size_t i = 0; i < g_listBestN; ++i)
        g_listBest[i] = g_pods[i];
    return 1;
}

int EnumCbBody(uint64_t guid) {
    ++g_enumCbCallCount;
    if (!guid) return 1;
    ++g_enumCbSeenGuids;
    if (g_podCount >= kMaxEnum) return 0;
    if (!ObjPtr()) return 1;

    // Probe: JUST COLLECT the guid here. Actually calling ObjectPtr with
    // different masks from inside the enum callback re-enters the game's OM
    // lookup machinery while the outer EnumVisibleObjects is still walking
    // the OM linked list - that reentrancy AV'd the client on Ascension.
    // The mask probe runs after enum returns (see Refresh below).
    if (g_probeArmed && g_probeCount < kProbeMax) {
        g_probeEntries[g_probeCount].guid = guid;
        g_probeEntries[g_probeCount].ptrMinus1 = 0;
        g_probeEntries[g_probeCount].ptrMaskFFFF = 0;
        g_probeEntries[g_probeCount].ptrMaskUnit = 0;
        g_probeEntries[g_probeCount].ptrMaskPlyr = 0;
        g_probeEntries[g_probeCount].ptrMaskGO = 0;
        ++g_probeCount;
    }

    uintptr_t ptr = ObjectPtrMulti(guid);
    if (!ptr) {
        ++g_objPtrMiss;
        return 1;
    }
    PushPodAt(ptr, guid);
    return 1;
}

// Run the mask trial for each probed guid AFTER SafeEnumVisible has returned.
// Called from Refresh when g_probeArmed. Safe: no OM iterator is active.
void RunProbeMaskTrials() {
    for (size_t i = 0; i < g_probeCount; ++i) {
        ProbeEntry& pe = g_probeEntries[i];
        if (!pe.guid) continue;
        pe.ptrMinus1   = ObjectPtrOne(pe.guid, -1);
        pe.ptrMaskFFFF = ObjectPtrOne(pe.guid, 0xFFFF);
        pe.ptrMaskUnit = ObjectPtrOne(pe.guid, 0x18);
        pe.ptrMaskPlyr = ObjectPtrOne(pe.guid, 0x10);
        pe.ptrMaskGO   = ObjectPtrOne(pe.guid, 0x20);
    }
}

int __cdecl EnumCb(uint64_t guid, void*) {
    return EnumCbBody(guid);
}

// ---- EnumVisibleObjects VEH longjmp guard (2026-08-01, permanent) ----------
// EnumVisibleObjects is a game function that WRITES to every visible object
// while walking the OM (incl. object+0x2D0). A mob freed mid-walk => AV_WRITE
// UAF at 0x004D3A40. SEH (__try) is a DEAD guard in this stealth module (PEB
// unlink + header wipe => RtlIsValidHandler fails), so the AV propagated into
// the game's Lua protected-call wrapper (0x858A16) which surfaced as the
// "addon blocked" dialog and froze the rotation. Guard.h's VEH longjmp guard
// catches the AV here, abandons the walk (the faulting write never landed),
// marks the enum dead and retries later, and returns EXCEPTION_CONTINUE_
// EXECUTION so the game's Lua wrapper NEVER sees the fault.
// Module-level retry timestamp so the guard can schedule the retry.
static ULONGLONG g_enumRetryAt = 0;

int SafeEnumVisibleAt(uintptr_t fnAddr) {
    if (!fnAddr) return -1;
    int rc = 1;
    {
        Guard::Scope g;
        if (!g.Caught()) {
            auto fn = reinterpret_cast<fnEnum>(fnAddr);
            fn(&EnumCb, reinterpret_cast<void*>(static_cast<intptr_t>(-1)));
        } else {
            rc = g.Code();
        }
        if (g.Caught()) {
            if (!g_enumDeadLogged) {
                g_enumDeadLogged = true;
                RL::Log::Error(
                    "EnumVisibleObjects AV 0x%08X — VEH guard, list-only until retry",
                    rc);
            }
            g_enumDead = true;
            g_enumRetryAt = GetTickCount64() + 10000ull;
            g_podCount = 0;
        }
    }
    g_lastEnumRc = rc;
    return rc;
}

int SafeEnumVisible() {
    if (g_enumDead) return g_lastEnumRc ? g_lastEnumRc : (int)0xC0000005;
    g_objPtrMiss = 0;
    g_enumCbCallCount = 0;
    g_enumCbSeenGuids = 0;
    g_probeCount = 0;
    // Primary only - dual-enum doubled main-thread work and alt VA can AV mid-load.
    int rc = SafeEnumVisibleAt(Offsets::F().ClntObjMgrEnumVisibleObjects);
    (void)kEnumVisAlt;
    g_lastEnumRc = rc;
    return rc;
}

uint64_t SafeGetActive() {
    // 2026-08-02 (CRASH FIX — "GetActivePlayer storm inside the Lua VM"):
    // SafeGetActive is called by LocalGuid() from EVERY bridge accessor
    // (Position/Facing/Reach/Health...), i.e. once per bridge call. GetActive
    // is a GAME function (TLS->ClntObjMgr->hash) executing inside the Lua VM
    // C-closure; the post-cast burst ran it 30+ times in ~15ms. A transient AV
    // there (or in the old dead-`__try` MainThread path) propagated into the
    // game's Lua protected-call wrapper 0x858A16 -> closure-table corruption ->
    // the garbage-eip crash family (frame=0 ret=0x00858A16). The active player
    // GUID does not change mid-session, so cache it ~120ms: the game call now
    // runs ~8/sec instead of once per bridge call, and it stays VEH-guarded.
    static ULONGLONG s_t = 0;
    static uint64_t s_g = 0;
    ULONGLONG now = GetTickCount64();
    if ((now - s_t) < 120ull) return s_g;
    s_t = now;
    Guard::Scope g;
    uint64_t r = 0;
    if (!g.Caught()) r = GetActive()();
    if (r) s_g = r;
    return r;
}

// TLS -> ClntObjMgr* (same path stock ObjectPtr uses at 0x4D4DB0).
// (Defined here; forward-declared near ObjectPtrOne for list walk.)
static uintptr_t ClntObjMgrFromTls() {
    // Reads are VirtualQuery-guarded (Mem::Read) — no __try dependency.
    uint32_t tlsIndex = Mem::Read<uint32_t>(0x00D439BC);
    uintptr_t teb = __readfsdword(0x2C);
    if (!teb) return 0;
    uintptr_t slot = Mem::Read<uintptr_t>(teb + tlsIndex * 4);
    if (!slot) return 0;
    uintptr_t mgr = Mem::Read<uintptr_t>(slot + 8);
    return (mgr && Mem::Readable(mgr)) ? mgr : 0;
}

// PosProbe: ObjectPtr returns live CGObject* in the HIGH 2GB heap
// (e.g. 0xA1C7B050, 0xA81A9D8). The old p >= 0x7FFF0000 reject zeroed every
// hit on this LAA client. Only reject NULL page; SEH guards real reads.
static uintptr_t AcceptObjPtr(uintptr_t p) {
    if (!p || p < 0x10000u) return 0;
    return p;
}

// Stock ObjectPtr @ 0x4D4DB0. ALWAYS use this VA (offset table can drift).
// Isolated SEH - no C++ objects.
static uintptr_t CallObjectPtr3(uint32_t lo, uint32_t hi, int mask) {
    auto fn = reinterpret_cast<fnObjectPtr3>(0x004D4DB0);
    uintptr_t p = 0;
    {
        Guard::Scope g;
        if (!g.Caught()) {
            p = fn(lo, hi, mask);
        }
    }
    return AcceptObjPtr(p);
}

// Hash thiscall @ 0x4D4BB0 (pre type-mask). Exact game call layout.
static uintptr_t CallHashLookup(uintptr_t mgr, uint32_t lo, uint32_t hi) {
    if (!mgr) return 0;
    struct GuidPair { uint32_t lo; uint32_t hi; };
    GuidPair gp;
    gp.lo = lo;
    gp.hi = hi;
    using fnHash = uintptr_t(__thiscall*)(uintptr_t, uint32_t, GuidPair*);
    auto hash = reinterpret_cast<fnHash>(0x004D4BB0);
    uintptr_t p = 0;
    {
        Guard::Scope g;
        if (!g.Caught()) {
            p = hash(mgr, lo, &gp);
        }
    }
    return AcceptObjPtr(p);
}

uintptr_t SafeObjectPtr(uint64_t guid) {
    if (!guid) return 0;
    uint32_t lo = (uint32_t)guid;
    uint32_t hi = (uint32_t)(guid >> 32);

    // 1) Stock ObjectPtr mask=-1 first (PosProbe: this is the live pointer).
    if (uintptr_t p = CallObjectPtr3(lo, hi, -1)) return p;
    // 2) Player / unit masks used by game callers after GetActivePlayer
    const int masks[] = { 0x10, 0x18, 0x08, 0x1F, 0xFFFF, 0x7FFFFFFF };
    for (int m : masks) {
        if (uintptr_t p = CallObjectPtr3(lo, hi, m)) return p;
    }
    // 3) Hash without type-mask filter
    if (uintptr_t mgr = ClntObjMgrFromTls()) {
        if (uintptr_t p = CallHashLookup(mgr, lo, hi)) return p;
    }
    return 0;
}

// SafeCTM deleted with MoveTo above: it existed only to invoke ClickToMove.

// Returns 1 on call success (no AV), 0 on missing fn, -1 on exception.
// targetGuid 0 -> client uses current target / self as appropriate.
// player arg kept for API compatibility; real Spell_C_CastSpell is global cdecl.
int SafeCastSpell(uintptr_t /*player*/, int spellId, uint64_t targetGuid) {
    if (spellId <= 0) return 0;
    auto fn = CastSpellFn();
    if (!fn) return 0;
    uint32_t lo = (uint32_t)targetGuid;
    uint32_t hi = (uint32_t)(targetGuid >> 32);
    Guard::Scope g;
    if (!g.Caught()) {
        fn(spellId, 0, lo, hi, 0);
        return 1;
    }
    return -1;
}

uintptr_t SafeCamera() {
    Guard::Scope g;
    if (!g.Caught()) {
        return Cam()();
    }
    return 0;
}

// 2026-08-02 (FACING ROOT CAUSE — RE-VERIFIED LIVE). The client's own
// GetPlayerFacing handler (0x60A490) does NOT read the runtime's LocalPtr().
// It resolves the player object EXACTLY like this:
//   cam = GetCamera()                     (0x4F5960 = [[0xB7436C]+0x7E20])
//   lo  = [cam+0x88], hi = [cam+0x8C]     (player GUID cached on the camera)
//   obj = ClntObjMgrObjectPtr(lo, hi, 1)  (0x4D4DB0 — only 3 args are used)
//   fn  = [[obj]+0x34]                    (vtable slot 0x0D = GetFacing)
//   face = fn(obj)                        (0x6E6FC0 = `fld [ecx+0x7AC]; ret`)
// Live proof of the bug: runtime PlayerFacing() = 0, but the client's native
// GetPlayerFacing() = 1.4547 at the same moment. LocalPtr() returns a pointer
// whose +0x7AC is 0 (stale/other object); the camera-resolved object has the
// real live facing. So the facing read must use the CAMERA-RESOLVED pointer,
// not LocalPtr(). All reads below are VirtualQuery-guarded Mem::Read.
static uintptr_t CameraPlayerPtr() {
    uintptr_t cam = SafeCamera();
    if (!cam) return 0;
    uint32_t lo = Mem::Read<uint32_t>(cam + 0x88);
    uint32_t hi = Mem::Read<uint32_t>(cam + 0x8C);
    if (!lo && !hi) return 0;
    return CallObjectPtr3(lo, hi, 1); // mask 1 (Object) — exactly what the client uses
}

int SafeIntersect(Vec3* s, Vec3* e, Vec3* h, float* dist, uint32_t flags) {
    Guard::Scope g;
    if (!g.Caught()) {
        return Intersect()(s, e, h, dist, flags, 0) ? 1 : 0;
    }
    return -1;
}

// True when a float triple looks like a real world coord (not null-island / garbage).
// Live bug (1.8.13): scan accepted obj+0x48 ? (-0, -0, 0) and latched that as the
// permanent layout -> player pos stuck near origin while camera sat in the real
// zone -> Lua PlausiblePlayerPos rejected every frame (453+ _badpos).
//
// Live bug (1.8.21): accepted (0.0, 88.7, 87.7) because only BOTH axes <5 were
// rejected. That half-null island was pinned as the global unit layout; player
// then read garbage forever and Suite stuck on need_position while the camera
// sat correctly at Deathknell (~1840,1610). Require BOTH axes to have real
// continental magnitude.
static bool LooksLikeWorldPos(float x, float y, float z) {
    if (x != x || y != y || z != z) return false; // NaN
    // BOTH axes must be away from zero. A single non-zero component is almost
    // always a misaligned float field (scale, facing fragment, pointer low word).
    if (std::fabs(x) < 30.f || std::fabs(y) < 30.f) return false;
    if (std::fabs(x) > 200000.f || std::fabs(y) > 200000.f) return false;
    if (z < -5000.f || z > 15000.f) return false;
    if (std::fabs(x) > 1e10f || std::fabs(y) > 1e10f || std::fabs(z) > 1e10f) return false;
    return true;
}

// Cached position layout discovered live (PosProbe: 0x798 was NaN on Ascension
// while ObjectPtr was valid - live coords live in movement / other fields).
// mode: 0=unset 1=unit field off 2=mov+off 3=[[mov]+nestedOff]+posOff 4=scan field
static int g_posMode = 0;
static uintptr_t g_posA = 0; // field off / mov-relative off / scan off
static uintptr_t g_posB = 0; // nested pointer off inside MovementInfo
static uintptr_t g_posC = 0; // pos off inside nested block

static bool TryReadXYZ(uintptr_t base, uintptr_t off, float* x, float* y, float* z) {
    *x = *y = *z = 0.f;
    if (!base) return false;
    // CRASH RULE (permanent): no raw __try derefs — SEH does not dispatch in
    // this stealth module. Mem::Read is VirtualQuery-guarded (works always).
    float v0 = Mem::Read<float>(base + off);
    float v1 = Mem::Read<float>(base + off + 4);
    float v2 = Mem::Read<float>(base + off + 8);
    *x = v0; *y = v1; *z = v2;
    return LooksLikeWorldPos(*x, *y, *z);
}

static uintptr_t SafeReadPtr(uintptr_t addr) {
    uintptr_t v = Mem::Read<uintptr_t>(addr);
    return AcceptObjPtr(v);
}

// Camera at [[0xB7436C]+0x7E20]+0x08 - independent witness for layout pin.
static bool ReadCameraXY(float* cx, float* cy, float* cz) {
    *cx = *cy = *cz = 0.f;
    uintptr_t wf = Mem::Read<uintptr_t>(0x00B7436C);
    if (!wf) return false;
    uintptr_t cam = Mem::Read<uintptr_t>(wf + 0x7E20);
    if (!cam) return false;
    *cx = Mem::Read<float>(cam + 0x08);
    *cy = Mem::Read<float>(cam + 0x0C);
    *cz = Mem::Read<float>(cam + 0x10);
    return LooksLikeWorldPos(*cx, *cy, *cz);
}

// When the camera is readable, a candidate player pos must sit near it.
// Follow camera is tens of yards; 300 yd is a hard upper bound for "same place".
static bool AgreesWithCamera(float x, float y, float z) {
    float cx, cy, cz;
    if (!ReadCameraXY(&cx, &cy, &cz)) return true; // no witness -> accept
    float dx = x - cx, dy = y - cy;
    return (dx * dx + dy * dy) <= (300.f * 300.f);
}

static void ClearPosLayout() {
    g_posMode = 0;
    g_posA = g_posB = g_posC = 0;
}

static bool TryCacheRead(uintptr_t ptr, float* x, float* y, float* z) {
    if (g_posMode == 1) return TryReadXYZ(ptr, g_posA, x, y, z);
    if (g_posMode == 2) {
        uintptr_t mov = SafeReadPtr(ptr + 0xD8);
        return mov && TryReadXYZ(mov, g_posA, x, y, z);
    }
    if (g_posMode == 3) {
        uintptr_t mov = SafeReadPtr(ptr + 0xD8);
        uintptr_t nest = mov ? SafeReadPtr(mov + g_posB) : 0;
        return nest && TryReadXYZ(nest, g_posC, x, y, z);
    }
    if (g_posMode == 4) return TryReadXYZ(ptr, g_posA, x, y, z);
    return false;
}

// Multi-method unit position read.
//
// CRITICAL PERF (live 1.8.14-1.8.17): a single GLOBAL layout cache + camera
// agreement on EVERY object caused this pattern on each OM refresh:
//   pin layout for player -> next NPC fails camera check (or wrong offset) ->
//   ClearPosLayout -> brute-scan 0x40..0xB00 (~700 SEH reads) per object ->
//   Warn log line per hit -> 5000+ log lines/min and FPS collapse.
//
// Rules now:
//   * Classic offsets (0x798 / MovementInfo) use LooksLikeWorldPos only.
//   * Camera agreement is ONLY for the local player (and only to reject null-island).
//   * Brute scan is rare, logged once, never pins a global layout that fights NPCs.
//   * Do not clear a working global cache because one distant NPC failed it.
// isLocal: when true, require camera agreement before pinning/returning a hit.
// isLocal false: NPCs may be far from camera; still use LooksLikeWorldPos only.
Vec3 ReadPosOffsets(uintptr_t ptr, bool isLocal) {
    Vec3 p{};
    if (!AcceptObjPtr(ptr)) return p;
    float x = 0.f, y = 0.f, z = 0.f;

    auto accept = [&](float px, float py, float pz) -> bool {
        if (!LooksLikeWorldPos(px, py, pz)) return false;
        if (isLocal && !AgreesWithCamera(px, py, pz)) return false;
        return true;
    };

    // Fast path: shared layout if it still yields a continental triple.
    // For the LOCAL player, also require camera agreement - a pinned layout that
    // drifted to null-island must be discarded, not trusted forever.
    if (g_posMode != 0 && TryCacheRead(ptr, &x, &y, &z)) {
        if (accept(x, y, z)) {
            p.x = x; p.y = y; p.z = z; return p;
        }
        if (isLocal) {
            // Cached layout lies for the player. Drop it so rediscovery can run.
            ClearPosLayout();
        }
    }

    auto pin = [&](int mode, uintptr_t a, uintptr_t b, uintptr_t c,
                   float px, float py, float pz) {
        // Pin when: (a) local player hit already camera-checked via accept(), or
        // (b) first discovery and no layout yet. Never overwrite a good pin with
        // an NPC-only guess that was not camera-validated.
        if (isLocal) {
            g_posMode = mode; g_posA = a; g_posB = b; g_posC = c;
        } else if (g_posMode == 0) {
            // NPC-discovered layouts are provisional: require LooksLikeWorldPos
            // only (already true). Player reads will camera-validate and clear.
            g_posMode = mode; g_posA = a; g_posB = b; g_posC = c;
        }
        p.x = px; p.y = py; p.z = pz;
    };

    // 1) Classic unit field caches (live player: 0x798 works on 1.8.14+ PosProbe).
    // 0xE8: Ascension live units often store XYZ here (brute scan found it first;
    // trying it early avoids 700-read scans that hitch frames and stress SEH).
    const uintptr_t fieldOffs[] = {
        0x798, 0x790, 0x7A0, 0xE8, 0x9B8, 0x808, 0x7E0, 0xA00, 0x8F0, 0x6E0
    };
    for (uintptr_t off : fieldOffs) {
        if (TryReadXYZ(ptr, off, &x, &y, &z) && accept(x, y, z)) {
            pin(1, off, 0, 0, x, y, z);
            return p;
        }
    }

    // 2) MovementInfo* at +0xD8.
    uintptr_t mov = SafeReadPtr(ptr + 0xD8);
    if (mov) {
        const uintptr_t movOffs[] = { 0x0C, 0x10, 0x14, 0x20, 0x24, 0x28, 0x30, 0x00, 0x04 };
        for (uintptr_t off : movOffs) {
            if (TryReadXYZ(mov, off, &x, &y, &z) && accept(x, y, z)) {
                pin(2, off, 0, 0, x, y, z);
                return p;
            }
        }
        const uintptr_t nestPtrOffs[] = { 0x0C, 0x10, 0x14, 0x08, 0x18 };
        const uintptr_t nestPosOffs[] = { 0x00, 0x04, 0x10, 0x20, 0x24 };
        for (uintptr_t npo : nestPtrOffs) {
            uintptr_t nest = SafeReadPtr(mov + npo);
            if (!nest) continue;
            for (uintptr_t po : nestPosOffs) {
                if (TryReadXYZ(nest, po, &x, &y, &z) && accept(x, y, z)) {
                    pin(3, 0, npo, po, x, y, z);
                    return p;
                }
            }
        }
    }

    // 3) Alternate movement pointer slots (do not brute-scan yet).
    for (uintptr_t moff : { (uintptr_t)0xE8, (uintptr_t)0xF0, (uintptr_t)0xA0 }) {
        uintptr_t m2 = SafeReadPtr(ptr + moff);
        if (!m2) continue;
        for (uintptr_t off : { (uintptr_t)0x0C, (uintptr_t)0x10, (uintptr_t)0x00 }) {
            if (TryReadXYZ(m2, off, &x, &y, &z) && accept(x, y, z)) {
                pin(2, off, 0, 0, x, y, z);
                return p;
            }
        }
    }

    // 4) Brute scan ONLY as last resort. Cap frequency hard: full 0x40..0x900
    // walks (~700 SEH reads) on many objects = lag spikes and random AVs under load.
    // Non-local: skip brute entirely after field/mov paths fail (pod fill uses fixed
    // offsets; multi-dot does not need per-NPC Position() brute). Local player:
    // allow a rare scan (rate-limited) then camera fallback.
    static int s_scanLogs = 0;
    static ULONGLONG s_lastBruteMs = 0;
    ULONGLONG nowBrute = GetTickCount64();
    if (!isLocal) {
        // No brute for NPCs — avoid thrashing. Caller keeps last-good snapshot.
        return p;
    }
    if (s_lastBruteMs && (nowBrute - s_lastBruteMs) < 500ull) {
        // Cooldown: fall through to camera fallback below.
    } else {
        s_lastBruteMs = nowBrute;
        float bestX = 0, bestY = 0, bestZ = 0;
        uintptr_t bestOff = 0;
        float camBestX = 0, camBestY = 0, camBestZ = 0;
        uintptr_t camBestOff = 0;
        for (uintptr_t off = 0x40; off + 12 <= 0x900; off += 4) {
            if (!TryReadXYZ(ptr, off, &x, &y, &z)) continue;
            if (!bestOff) { bestX = x; bestY = y; bestZ = z; bestOff = off; }
            if (AgreesWithCamera(x, y, z)) {
                camBestX = x; camBestY = y; camBestZ = z; camBestOff = off;
                break;
            }
        }
        if (camBestOff) {
            p.x = camBestX; p.y = camBestY; p.z = camBestZ;
            g_posMode = 1; g_posA = camBestOff; g_posB = g_posC = 0;
            if (s_scanLogs < 4) {
                RL::Log::Warn("ReadPosOffsets: player scan pin obj+0x%X = %.2f,%.2f,%.2f (cam-ok)",
                              (unsigned)camBestOff, camBestX, camBestY, camBestZ);
                s_scanLogs++;
            }
            return p;
        }
        (void)bestX; (void)bestY; (void)bestZ; (void)bestOff;
    }

    // 5) LOCAL PLAYER LAST RESORT: camera position itself. Follow camera is
    // within tens of yards of the body; better to navigate from the camera
    // than to freeze the entire quest suite on need_position.
    if (isLocal) {
        float cx, cy, cz;
        if (ReadCameraXY(&cx, &cy, &cz)) {
            p.x = cx; p.y = cy; p.z = cz;
            static int s_camLogs = 0;
            if (s_camLogs < 4) {
                RL::Log::Warn("ReadPosOffsets: player fallback camera = %.2f,%.2f,%.2f",
                              cx, cy, cz);
                s_camLogs++;
            }
            return p;
        }
    }

    return p;
}

void PodsToVectors() {
    g_all.clear();
    for (auto& v : g_byType) v.clear();
    g_all.reserve(g_podCount);
    for (size_t i = 0; i < g_podCount; ++i) {
        Pod& p = g_pods[i];
        // Finalize type outside SEH (may use GetObjectType thiscall)
        p.type = ResolveType(p.ptr, p.guid);
        // Hard recovery: creature GUID or living world pos + maxHP => Unit.
        // Without this, Ascension often left units=0 (only mouseover worked).
        if (p.type != (int)ObjectType::Player && p.type != (int)ObjectType::Unit) {
            int gt = TypeFromGuid(p.guid);
            if (gt == (int)ObjectType::Unit)
                p.type = (int)ObjectType::Unit;
            else if (p.maxHealth > 0 && (p.x != 0.f || p.y != 0.f)
                     && p.type != (int)ObjectType::GameObject
                     && p.type != (int)ObjectType::Item
                     && p.type != (int)ObjectType::Container)
                p.type = (int)ObjectType::Unit;
        }

        Object o;
        o.guid = p.guid;
        o.ptr = p.ptr;
        o.type = static_cast<ObjectType>(p.type);
        o.entry = p.entry;
        o.pos.x = p.x; o.pos.y = p.y; o.pos.z = p.z;
        o.facing = p.facing;
        o.health = p.health;
        o.maxHealth = p.maxHealth;
        o.level = p.level;
        o.unitFlags = p.unitFlags;
        o.dynamicFlags = p.dynamicFlags;
        o.faction = p.faction;
        o.unitTarget = p.unitTarget;
        o.scale = p.scale > 0.f ? p.scale : 1.f;
        o.goBytes1 = p.goBytes1;
        o.npcFlags = p.npcFlags;
        o.creatureType = p.creatureType;
        int t = p.type;
        if (t >= 0 && t < 8) g_byType[t].push_back(o);
        g_all.push_back(std::move(o));
    }
}

} // namespace

// 2026-08-02 (round 22 — SYNC TARGET RESOLUTION): the client's Spell_C SYNC
// target resolution (0x80CD4A) reads the cast target GUID from
// [player+0xd0]+0x18. To write that record safely we need a VERIFIED player
// object pointer. PlayerPtr()/LocalPtr() are NOT it: the MainThread snapshot
// stores OM::LocalPtr() (garbage — FacingLive local=1e9 every session), so a
// [player+0xd0] write through them corrupts client state (round 18: false
// "charmed"). This returns the player object via the SAME verified paths
// RefreshLiveFacingCache proves correct live (obj=0x37825EE0):
//   1) SafeGetActive → ObjectPtr mask 0x10 — the object the cast wrapper
//      resolves (SafeGetActive is VEH-guarded, cached 120ms, already called
//      from every bridge accessor).
//   2) Camera path (client's exact GetPlayerFacing resolution: cam → GUID →
//      ObjectPtr mask 1).
// Returns 0 when the player can't be verified — callers MUST skip any write
// (never write through an unverified pointer). NOTE: defined OUTSIDE the
// anonymous namespace so it's exported from RL::Game::OM (the statics it
// calls — SafeGetActive/CallObjectPtr3/CameraPlayerPtr — are file-scope and
// remain in scope for the whole translation unit).
uintptr_t VerifiedPlayerPtr() {
    uint64_t active = SafeGetActive();
    if (active) {
        uintptr_t pobj = CallObjectPtr3((uint32_t)active, (uint32_t)(active >> 32), 0x10);
        if (pobj) return pobj;
    }
    return CameraPlayerPtr();
}

// 2026-08-02 (ROUND 23 — SYNC-TARGET DIAGNOSTIC EXPORTS). The cast wrapper
// 0x80DA40 resolves its player object as ObjectPtr(GetActivePlayerGUID, 0x10)
// where GetActivePlayerGUID = [ClntObjMgr+0xC0/0xC4] via the TLS chain
// (0x4d3790). These exported wrappers expose the client's exact resolution
// pieces (all VEH-guarded / VirtualQuery-guarded) so SafeNativeCast's
// CastDiag can compare cast-path player vs camera player vs the [0xd0] record
// and the player's UNIT_FIELD_FLAGS — the data that finally proves which
// player object Spell_C's sync resolution actually reads.
uintptr_t ClntObjMgrTls() { return ClntObjMgrFromTls(); }
uintptr_t ObjectPtr3Guid(uint32_t lo, uint32_t hi, int mask) { return CallObjectPtr3(lo, hi, mask); }
uintptr_t CameraPlayerPtrEx() { return CameraPlayerPtr(); }

// Live local-player facing via the client's exact resolution path (camera →
// GUID → ObjectPtr → +0x7AC). 1e9 on fail. Primary source for PlayerFacing.
//
// CRASH RULE (2026-08-02 — 0x512B07 RE-INTRODUCED BY ME, USER-CONFIRMED):
// FacingLiveLocal() MUST be a PURE CACHE READ. It is called from the Lua VM
// (PlayerFacing / Facing(localGuid) / ObjectIsFacing bridge paths), and the
// camera→ObjectPtr resolution (SafeCamera + CallObjectPtr3) is a GAME FUNCTION
// CALL. Calling game functions from inside the Lua VM corrupts the VM's
// closures → the 0x512B07 AV_READ garbage-eip crash (live: crash.fatal right
// after a clean CastQueue DRAIN; the GatherMate2/XPerl UI errors are the same
// VM-corruption cascade). The ONLY context that may resolve the player via the
// camera is the native FRAME HOOK (TickHookBody → RefreshLiveFacingCache, main
// thread, no Lua on stack). If the cache is stale here, return 1e9 (undetermined)
// — never resolve from the VM.
static volatile float g_liveFacingCache = 1e9f;
static volatile ULONGLONG g_liveFacingCacheT = 0;

// NATIVE-ONLY (frame hook / main thread, no Lua on stack). Resolves the player
// via the client's exact path and refreshes the cache every tick. This is the
// ONLY caller of CameraPlayerPtr().
void RefreshLiveFacingCache() {
    // 2026-08-02 (0x512B07 hardening): rate-limit the game-call resolution
    // (CameraPlayerPtr -> SafeCamera + ObjectPtr). This hook fires every frame
    // and previously called those game functions on EVERY tick with no limit —
    // a heavy hammer on the client's object machinery. The FacingLiveLocal TTL
    // is 250ms; refresh at 50ms keeps the cache fresh during rapid turning
    // (user directive 15:22: "more aware and in control" — a 200ms-stale face
    // made the rotation wire a spell at a target the player had already turned
    // away from). 50ms = ~4x fresher with still-5x-fewer calls than raw.
    static volatile ULONGLONG s_lastFacingMs = 0;
    ULONGLONG nowF = GetTickCount64();
    if (s_lastFacingMs && (nowF - s_lastFacingMs) < 50ull) return;
    s_lastFacingMs = nowF;
    // Throttled live diagnostic (every 5s) — a stuck cache must be attributable
    // in the log (cam=0? guid=0? obj=0? which path produced the value?).
    static volatile ULONGLONG s_lastDiag = 0;
    bool doDiag = (nowF - s_lastDiag) > 5000ull;
    if (doDiag) s_lastDiag = nowF;

    // 2026-08-02 (FACING CACHE ROBUSTNESS — live probe proved the cache went
    // stale: runtime PFRAW=1e9 while client GetPlayerFacing()=3.795). Try the
    // client's EXACT path first (camera → GUID → ObjectPtr → [obj+0x7AC]),
    // then the client's own fallback ([cam+0x11C] camera facing), then the
    // GetActive player object (the object the cast wrapper resolves).
    float f = 1e9f;
    uintptr_t cam = 0; uint32_t clo = 0, chi = 0; uintptr_t obj = 0;
    uint64_t active = 0;
    // Path 1 — client's exact GetPlayerFacing path.
    cam = SafeCamera();
    if (cam) { clo = Mem::Read<uint32_t>(cam + 0x88); chi = Mem::Read<uint32_t>(cam + 0x8C); }
    if (clo || chi) obj = CallObjectPtr3(clo, chi, 1);
    if (obj) {
        float v = Mem::Read<float>(obj + 0x7AC);
        if (!(v != v) && v >= -0.01f && v <= 6.30f) f = v;
    }
    // Path 2 — camera's own facing (the client's fallback in GetPlayerFacing).
    if (f >= 1e8f && cam) {
        float v = Mem::Read<float>(cam + 0x11C);
        if (!(v != v) && v >= -0.01f && v <= 6.30f) f = v;
    }
    // Path 3 — GetActive player object (mask 0x10 = player; same object the
    // cast wrapper resolves, guaranteed fresh).
    if (f >= 1e8f) {
        active = SafeGetActive();
        if (active) {
            uintptr_t pobj = CallObjectPtr3((uint32_t)active, (uint32_t)(active >> 32), 0x10);
            if (pobj) {
                float v = Mem::Read<float>(pobj + 0x7AC);
                if (!(v != v) && v >= -0.01f && v <= 6.30f) f = v;
            }
        }
    }
    g_liveFacingCache = f;
    g_liveFacingCacheT = nowF;
    if (doDiag) {
        // 2026-08-02 (FACING VERIFY): cross-check against the client's own
        // GetPlayerFacing-equivalent — the camera object's [obj+0x7AC] read.
        // Both are from the SAME object here, so log obj fields + whether the
        // LocalPtr path agrees, so a stuck 0.0000 is attributable live.
        float localFallback = 1e9f;
        uintptr_t lp = RL::Game::OM::LocalPtr();
        if (lp) {
            float v = RL::Game::Mem::Read<float>(lp + 0x7AC);
            if (!(v != v) && v >= -0.01f && v <= 6.30f) localFallback = v;
        }
        RL::Log::Warn("FacingLive: cam=0x%lX guid=%08X%08X obj=0x%lX face=%.4f active=0x%llX local=%.4f",
                      (unsigned long)cam, (unsigned)chi, (unsigned)clo,
                      (unsigned long)obj, f, (unsigned long long)active, localFallback);
    }
}

// PURE CACHE READ — safe to call from the Lua VM (no game calls, no re-entry).
// Returns the hook-refreshed live facing, or 1e9 (undetermined) if the cache
// is stale (hook not yet installed / cold start). NEVER calls CameraPlayerPtr.
float FacingLiveLocal() {
    ULONGLONG now = GetTickCount64();
    if ((now - g_liveFacingCacheT) < 250ull && g_liveFacingCache < 1e8f)
        return g_liveFacingCache;
    return 1e9f; // undetermined — never resolve from the VM (0x512B07 rule)
}

void Invalidate() {
    std::lock_guard<std::mutex> lock(g_mu);
    g_lastRefresh = 0;
    // Do NOT clear g_enumDead - once the enum AVs, it stays off until re-inject.
}

// 0x512B07 crash fix: mark whether we are inside the game's Lua VM call chain
// (the bridge dispatch sets this). Enumeration is deferred when true; the
// bridge reads serve the last-built snapshot instead.
void SetInLuaContext(bool inLua) { g_inLuaContext = inLua; }
bool InLuaContext() { return g_inLuaContext; }

// OM lifecycle (fundamental — do not "fix crashes" by disabling discovery):
//   g_firstPlayerMs  — first time we saw a local player THIS warm epoch
//                      (cold inject OR post-rebind; reset on OnLuaReload)
//   g_everWalkedOk   — at least one successful list walk this inject
//   g_rebindQuietUntil — brief pause after lua_State change (FrameXML mid-load)
// SoftRefresh (multi-dot) and Refresh (om.enable=1) BOTH walk the same list
// with SEH. Never leave a multi-second empty window after every /reload.
static ULONGLONG g_firstPlayerMs = 0;
static bool g_everWalkedOk = false;
static ULONGLONG g_rebindQuietUntil = 0;
static ULONGLONG g_omHardFreezeUntil = 0;
static bool g_omWasOn = false;
static int g_freezeOkTicks = 0; // consecutive ticks with player+pos after time expires
static constexpr ULONGLONG kColdSettleMs = 2000ull;   // cold inject only
static constexpr ULONGLONG kRebindQuietMs = 2000ull;  // FrameXML /reload settle
static constexpr ULONGLONG kRebindHardFreezeMs = 10000ull; // outlast medium Register (~8s) + SEAL settle
static constexpr int kFreezeOkNeeded = 3;                   // consecutive ticks with player+pos
static constexpr ULONGLONG kWalkMinIntervalMs = 100ull; // ~10 Hz max (lag: 80→50Hz thrash)
// EnumVisibleObjects mid-load (medium Register + PEW) hard-crashes the client.
// List-only until this many successful list walks OR this ms after first player
// IN THE CURRENT WARM EPOCH (must restart after every /reload).
static constexpr int kListWarmWalks = 8;
static constexpr ULONGLONG kEnumWarmMs = 5000ull;
static int g_listWarmWalks = 0;

void OnLuaReload() {
    // lua_State changed. Drop snapshot (pointers belong to old VM epoch) and
    // pause walks briefly while FrameXML reloads. Do NOT reset g_everWalkedOk
    // (that forced 6s+ of empty AuraSearch after every rebind — multi-dot dies).
    //
    // MUST reset g_firstPlayerMs. Live crash after /reload (1.10.33): list warm
    // counter was zeroed but firstPlayer stayed pre-reload → warmOk true via
    // (now - firstPlayer) >= 5s → EnumVisibleObjects mid-FrameXML → hard kill.
    // Proof: runtime.log REBIND → BRIDGE ONLINE medium bits=0xE → death.
    Invalidate();
    g_omWasOn = false;
    g_listWarmWalks = 0;
    g_firstPlayerMs = 0;
    const ULONGLONG now = GetTickCount64();
    g_rebindQuietUntil = now + kRebindQuietMs;
    g_omHardFreezeUntil = now + kRebindHardFreezeMs;
    g_freezeOkTicks = 0;
    LOG_W("om.freeze", "durMs=%llu reason=reload", (unsigned long long)kRebindHardFreezeMs);
}

// After the minimum freeze time, require player GUID + real position for
// kFreezeOkNeeded consecutive calls. No world-bit check (Ascension bits
// flicker) and no self-extending (would never clear on flickering pointers).
static bool RebindFrozen(ULONGLONG now) {
    if (!g_omHardFreezeUntil) return false;
    // Hard minimum: wall-clock freeze must fully elapse.
    if (now < g_omHardFreezeUntil) return true;
    // Simple stability: player exists and has a real position.
    uint64_t local = SafeGetActive();
    if (!local) { g_freezeOkTicks = 0; return true; }
    Vec3 pp = Position(local);
    if (std::fabs(pp.x) < 0.01f && std::fabs(pp.y) < 0.01f) {
        g_freezeOkTicks = 0;
        return true;
    }
    ++g_freezeOkTicks;
    if (g_freezeOkTicks >= kFreezeOkNeeded) {
        g_omHardFreezeUntil = 0;
        g_freezeOkTicks = 0;
        LOG_I("om.freeze_clear", "ticks=%d", kFreezeOkNeeded);
        return false;
    }
    return true; // building stable streak
}

bool IsEnabled() {
    if (RebindFrozen(GetTickCount64())) return false;
    return RL::Config::Get("om.enable", "1") != "0";
}

bool EnumIsDead() { return g_enumDead; }

std::string StatusPacked() {
    // LocalGuid outside the lock (no g_mu). Snapshot fields under lock.
    uint64_t local = LocalGuid();
    size_t total = 0, units = 0, players = 0, gos = 0;
    bool enumDead = false;
    bool refreshed = false;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        total = g_all.size();
        units = g_byType[(int)ObjectType::Unit].size();
        players = g_byType[(int)ObjectType::Player].size();
        gos = g_byType[(int)ObjectType::GameObject].size();
        enumDead = g_enumDead;
        refreshed = g_lastRefresh != 0;
    }
    const char* mode = "cold";
    if (!local) mode = "no-player";
    else if (refreshed) mode = enumDead ? "list-only" : "full";
    char buf[192];
    snprintf(buf, sizeof(buf),
             "mode=%s|total=%zu|units=%zu|players=%zu|gos=%zu|enum_dead=%d",
             mode, total, units, players, gos, enumDead ? 1 : 0);
    return buf;
}

void LogTypeSamples(size_t n) {
    std::lock_guard<std::mutex> lock(g_mu);
    // Type histogram + ObjectPtr miss count + list diag
    int hist[8] = {};
    for (size_t i = 0; i < g_podCount; ++i) {
        int t = g_pods[i].type;
        if (t >= 0 && t < 8) hist[t]++;
    }
    RL::Log::Info("OM hist none=%d item=%d cont=%d unit=%d player=%d go=%d dyn=%d corpse=%d | ptrMiss=%d list(conn=%08X mgr=%08X first=%08X iters=%d best=%zu)",
                  hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7],
                  g_objPtrMiss,
                  (unsigned)g_listDiagConn, (unsigned)g_listDiagMgr,
                  (unsigned)g_listDiagFirst, g_listDiagIters, g_listBestN);

    // One sample per type (prefer unit/player/go), then fill remaining slots
    bool seen[8] = {};
    size_t logged = 0;
    auto logOne = [&](size_t i) {
        const Pod& p = g_pods[i];
        uint32_t raw14 = Mem::Read<uint32_t>(p.ptr + 0x14);
        uint32_t hi = (uint32_t)(p.guid >> 48);
        RL::Log::Info("OM sample t=%d guid=0x%llX hi=%04X ptr=0x%lX entry=%d raw14=%08X pos=(%.2f,%.2f,%.2f)",
                      p.type, (unsigned long long)p.guid, hi, (unsigned long)p.ptr, p.entry, raw14,
                      p.x, p.y, p.z);
        logged++;
    };
    // Prefer interesting types first
    const int prefer[] = { 3, 4, 5, 6, 7, 2, 1, 0 };
    for (int want : prefer) {
        if (logged >= n) break;
        for (size_t i = 0; i < g_podCount; ++i) {
            if (g_pods[i].type == want && !seen[want]) {
                seen[want] = true;
                logOne(i);
                break;
            }
        }
    }
    for (size_t i = 0; i < g_podCount && logged < n; ++i) {
        int t = g_pods[i].type;
        if (t >= 0 && t < 8 && !seen[t]) {
            seen[t] = true;
            logOne(i);
        }
    }
}

// Forward: defined below with hostiles soft path (list-only, no enum).
static void SoftRefreshListOnlyForHostiles();

// ---- Snapshot epoch (2026-08-02) ----
// Generational epoch: bumped ONLY when the unit list content actually changes
// (cheap content signature). NearbyHostiles/NearbyUnits packers key their
// string caches on (epoch, player pos/face quantized, range, maxN, faction) —
// while the player is stationary and the world is unchanged, repeated reads
// are O(1) cache hits: zero refresh, zero walk, zero vector alloc, zero sort,
// zero format. This is the guide's "generational epoch + cache coherence"
// pattern applied to OM reads.
static volatile ULONGLONG g_snapGen = 0;
static uint64_t g_snapSig = 0;
static uint64_t SnapSignatureLocked() {
    uint64_t sig = 0x9E3779B97F4A7C15ull;
    for (size_t i = 0; i < g_podCount; ++i) {
        sig = (sig << 5) | (sig >> 59);
        sig ^= g_pods[i].guid;
        sig ^= (uint64_t)(g_pods[i].entry & 0xFFFF) << 21;
    }
    sig ^= (uint64_t)g_podCount * 0x9E3779B97F4A7C15ull;
    return sig;
}

// Read the local player's CACHED snapshot state (no game calls, no ObjectPtr).
// Returns false when the snapshot has no local-player entry yet (cold start) —
// callers then fall through to the live path.
static bool SnapshotPlayerState(uint64_t local, Vec3* pos, float* face, int* fac) {
    if (!local) return false;
    std::lock_guard<std::mutex> lock(g_mu);
    for (const auto& o : g_all) {
        if (o.guid == local && o.type == ObjectType::Player) {
            if (pos) *pos = o.pos;
            if (face) *face = o.facing;
            if (fac) *fac = o.faction;
            return true;
        }
    }
    return false;
}

// Packed nearby units for /raijin nearby: "n|guid:entry:x:y:z:dist|..."
std::string NearbyUnitsPacked(float maxRange, size_t maxN) {
    // Soft list-only when om frozen — same rule as hostiles (rotation needs units).
    uint64_t localGuid = SafeGetActive();
    if (!localGuid) return "0";

    // EPOCH CACHE (2026-08-02) — same pattern as NearbyHostilesPacked: O(1)
    // return while the player is stationary and the snapshot is unchanged.
    static std::string s_cacheOut;
    static ULONGLONG s_cacheGen = (ULONGLONG)-1;
    static ULONGLONG s_cacheT = 0;
    static uint64_t s_cacheLocal = 0;
    static float s_cacheX = 1e30f, s_cacheY = 1e30f;
    static float s_cacheRange = 0.f;
    static size_t s_cacheMaxN = 0;
    Vec3 cPos{};
    float cFace = 0.f;
    int cFac = -1;
    if (SnapshotPlayerState(localGuid, &cPos, &cFace, &cFac)) {
        ULONGLONG nowC = GetTickCount64();
        if (s_cacheGen == g_snapGen && s_cacheLocal == localGuid
            && (nowC - s_cacheT) < 250ull
            && std::fabs(s_cacheX - cPos.x) < 1.5f
            && std::fabs(s_cacheY - cPos.y) < 1.5f
            && std::fabs(s_cacheRange - maxRange) < 0.5f
            && s_cacheMaxN == maxN
            && !s_cacheOut.empty())
            return s_cacheOut;
    }

    if (IsEnabled())
        Refresh(false);
    else
        SoftRefreshListOnlyForHostiles();
    Vec3 playerPos{};
    bool havePlayer = false;
    if (localGuid) {
        playerPos = Position(localGuid); // uses ObjectPtr path, no g_mu
        if (playerPos.x != 0.f || playerPos.y != 0.f) havePlayer = true;
    }

    // Copy the small subset we care about (Unit-typed) out from under g_mu,
    // then do all sorting/distance work lock-free. Prior code held g_mu for
    // the whole loop AND the insertion sort - every bridge accessor waiting
    // on g_mu blocked for the full duration, which under load exceeded the
    // frame watchdog and drove the reported AC dispatch AV.
    struct Hit { uint64_t g; int entry; float x, y, z, d; };
    std::vector<Hit> candidates;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (!havePlayer) {
            for (const auto& o : g_all) {
                if (o.type == ObjectType::Player && (o.pos.x != 0.f || o.pos.y != 0.f)) {
                    if (localGuid && o.guid == localGuid) { playerPos = o.pos; havePlayer = true; break; }
                    if (!havePlayer) { playerPos = o.pos; havePlayer = true; }
                }
            }
        }
        candidates.reserve(g_byType[(int)ObjectType::Unit].size());
        for (const auto& o : g_byType[(int)ObjectType::Unit]) {
            candidates.push_back({ o.guid, o.entry, o.pos.x, o.pos.y, o.pos.z, 0.f });
        }
    }

    // Distance + range cull (out of lock)
    size_t write = 0;
    for (size_t i = 0; i < candidates.size(); ++i) {
        auto& h = candidates[i];
        if (havePlayer) {
            float dx = h.x - playerPos.x, dy = h.y - playerPos.y, dz = h.z - playerPos.z;
            h.d = std::sqrt(dx * dx + dy * dy + dz * dz);
            if (h.d > maxRange) continue;
        }
        candidates[write++] = h;
    }
    candidates.resize(write);

    // partial_sort - O(n log k) instead of the previous O(n^2) insertion
    // sort that could stall main thread on 200+ unit BGs.
    size_t nh = candidates.size();
    if (nh > maxN) nh = maxN;
    std::partial_sort(candidates.begin(),
                      candidates.begin() + nh,
                      candidates.end(),
                      [](const Hit& a, const Hit& b) { return a.d < b.d; });
    Hit hits[64];
    if (nh > 64) nh = 64;
    for (size_t i = 0; i < nh; ++i) hits[i] = candidates[i];

    char out[2048];
    size_t off = 0;
    off += (size_t)snprintf(out + off, sizeof(out) - off, "%zu", nh);
    for (size_t i = 0; i < nh && off + 80 < sizeof(out); ++i) {
        off += (size_t)snprintf(out + off, sizeof(out) - off,
                                "|0x%llX:%d:%.2f:%.2f:%.2f:%.1f",
                                (unsigned long long)hits[i].g, hits[i].entry,
                                hits[i].x, hits[i].y, hits[i].z, hits[i].d);
    }
    s_cacheOut.assign(out, off);
    s_cacheGen = g_snapGen;
    s_cacheT = GetTickCount64();
    s_cacheLocal = localGuid;
    s_cacheX = cPos.x; s_cacheY = cPos.y;
    s_cacheRange = maxRange; s_cacheMaxN = maxN;
    return s_cacheOut;
}

// UNIT_FIELD_FLAGS bits we treat as non-hostile / unusable.
static constexpr uint32_t kUF_NON_ATTACKABLE = 0x00000002u;
static constexpr uint32_t kUF_NOT_ATTACKABLE_1 = 0x00000080u;
static constexpr uint32_t kUF_IMMUNE_TO_PC = 0x00000100u;
static constexpr uint32_t kUF_NOT_SELECTABLE = 0x02000000u;
static constexpr uint32_t kDYN_DEAD = 0x00000020u;
static constexpr uint32_t kDYN_DEAD2 = 0x00000040u;

// Cast-facing (WotLK 3.3.5 / Trinity client rule)
// -----------------------------------------------
// Spell::CheckCast for a PLAYER casting at a UNIT target:
//   caster->HasInArc(M_PI, target)  // FULL cone width = 180°
// HasInArc treats its argument as full width, so half-angle = M_PI/2 = 90°.
// Pass |heading_error| <= half-angle. That is the front HEMISPHERE, not a
// narrow 90° "aim cone". Total acceptance = 180° centered on player facing.
//
// NOT every ability uses this:
//   - ground self-AoE (Consecration), self buffs, no unit target: no face check
//   - NPC casters often skip face check; we only gate player casts
// This constant is ONLY the half-angle of the unit-target face test.
static constexpr float kDefaultCastFaceArc = 1.5707963f; // π/2 rad = 90° half-angle
static inline bool LooksLikeFacingEarly(float f) {
    if (f != f) return false;
    if (f < -6.30f || f > 12.60f) return false;
    return true;
}
static float AngleDiffRad(float from, float to) {
    float diff = std::fmod(to - from + 3.14159265f, 6.2831853f);
    if (diff < 0.f) diff += 6.2831853f;
    return diff - 3.14159265f;
}
// arc = HALF-angle (radians). Default π/2 => |err|<=90° => 180° front cone.
// 2026-08-02 (18:16 FACING CONVENTION FIX — the root of every facing error):
// std::atan2 returns 0 = +X axis (east), increasing counter-clockwise, while
// the client's facing (0x7AC / GetPlayerFacing) is 0 = +Y axis (north),
// increasing CLOCKWISE. The two conventions are offset by 90°: a point due
// east has facing_wow = π/2 = 1.5708 but atan2(0, +) = 0. The runtime compared
// them directly, so targets the player FACED were reported NOT-facing (the
// "wait facing:Blood Strike x82 at edge=0yd" freeze) and targets at a rotated
// angle were reported facing (wired -> client "Out of range"/"in front of
// you" refusals). Correct conversion: facing_wow = π/2 - atan2(dy, dx) (mod
// 2π). AngleDiffRad normalizes.
static bool IsFacingPos(float face, float ax, float ay, float bx, float by, float arc) {
    if (arc <= 0.f) arc = kDefaultCastFaceArc;
    if (!LooksLikeFacingEarly(face)) return false;
    float ang = 1.5707963f - std::atan2(by - ay, bx - ax);
    return std::fabs(AngleDiffRad(face, ang)) <= arc;
}

// UNIT_FLAG_IN_COMBAT (3.3.5)
static constexpr uint32_t kUF_IN_COMBAT = 0x00080000u;
static constexpr uint32_t kUF_PACIFIED = 0x00020000u;
static constexpr uint32_t kUF_TAXI = 0x00100000u;
static constexpr uint32_t kUF_PLAYER_CONTROLLED = 0x01000000u;

// Strict hostile filter for multi-dot / AoE counts. FAIL-CLOSED on friendlies:
// same faction as player => never a combat hostile. "Invalid target" spam was
// casting Icy Touch on quest NPCs / vendors that only failed flag checks.
//
// Accepted if attackable by flags AND any of:
//   - different faction template (typical hostile NPC)
//   - in combat
//   - currently targeting the local player
static int s_playerFaction = 0;

static bool SnapshotLooksHostileNpc(const Object& o, uint64_t localGuid) {
    if (!o.guid || o.guid == localGuid) return false;
    if (o.type == ObjectType::Player || o.type == ObjectType::Item
        || o.type == ObjectType::Container || o.type == ObjectType::GameObject
        || o.type == ObjectType::DynamicObject || o.type == ObjectType::Corpse)
        return false;
    if (o.type != ObjectType::Unit && o.type != ObjectType::None) {
        if (o.entry <= 0 && o.maxHealth <= 0 && o.health <= 0) return false;
    }
    if (o.pos.x == 0.f && o.pos.y == 0.f) return false;
    if (o.maxHealth > 0 && o.health <= 0) return false;
    if (o.dynamicFlags & (kDYN_DEAD | kDYN_DEAD2)) return false;
    // 2026-08-02 (CRITTER FIX): CREATURE_TYPE_CRITTER (8) is never a combat
    // hostile. The client's own GetCreatureType read ([unit+0xD0]→[ptr+0x1D3],
    // disasm 0x71F300) is authoritative. Critters have a NON-player faction,
    // so the faction-only hostile filter below let them into AuraSearch —
    // the rotation was dotting squirrels/rabbits. Unknown (-1) is allowed
    // through to the rest of the filter (players, weird custom units).
    if (o.creatureType == 8) return false; // CREATURE_TYPE_CRITTER
    uint32_t f = o.unitFlags;
    if (f & kUF_NON_ATTACKABLE) return false;
    if (f & kUF_NOT_ATTACKABLE_1) return false;
    if (f & kUF_IMMUNE_TO_PC) return false;
    if (f & kUF_NOT_SELECTABLE) return false;
    if (f & kUF_PACIFIED) return false;
    if (f & kUF_TAXI) return false;
    if (f & kUF_PLAYER_CONTROLLED) return false; // totems/pets of friendlies etc.

    // Same faction as player => friendly / allied (guards, quest givers, vendors).
    if (s_playerFaction != 0 && o.faction == s_playerFaction)
        return false;
    // Unknown faction and not in combat and not targeting us: refuse (fail-closed).
    const bool inCombat = (f & kUF_IN_COMBAT) != 0;
    const bool targetingUs = localGuid && o.unitTarget == localGuid;
    if (o.faction == 0 && !inCombat && !targetingUs)
        return false;
    // Different faction OR in combat OR targeting player => combat hostile.
    if (o.faction != 0 && s_playerFaction != 0 && o.faction != s_playerFaction)
        return true;
    if (inCombat || targetingUs)
        return true;
    // Faction known but player faction unknown: allow if entry looks like a creature.
    if (o.entry > 0 && o.faction != 0)
        return true;
    return false;
}

// VEH-guarded wrappers (Guard.h). SafeWalkObjectList is pure VQ-guarded reads
// and PodsToVectors is pure math on our buffers — they cannot fault, but the
// guard guarantees no AV ever escapes the bridge into the game's Lua VM.
static int SoftWalkSeh() {
    Guard::Scope g;
    if (!g.Caught()) {
        return SafeWalkObjectList();
    }
    return -1;
}
static int SoftPodsSeh() {
    Guard::Scope g;
    if (!g.Caught()) {
        PodsToVectors();
        return 1;
    }
    return 0;
}

// ---- Snapshot epoch bump (2026-08-02) ----
// (epoch statics + SnapSignatureLocked + SnapshotPlayerState live above, near
// the packers; BuildUnitSnapshotLocked just bumps the epoch on content change)

// Shared gate for SoftRefresh + Refresh unit discovery.
static bool OmWalkAllowed(ULONGLONG now, uint64_t local) {
    if (!local) return false;
    if (now < g_rebindQuietUntil) return false; // FrameXML rebind flicker only
    if (RebindFrozen(now)) return false;       // hard post-reload freeze
    // Player must resolve a real position (not just a GUID) before any walk.
    Vec3 pp = Position(local);
    if (std::fabs(pp.x) < 0.01f && std::fabs(pp.y) < 0.01f)
        return false;
    if (!g_firstPlayerMs) g_firstPlayerMs = now;
    // Cold inject only: short settle until first successful snapshot ever.
    if (!g_everWalkedOk && (now - g_firstPlayerMs) < kColdSettleMs)
        return false;
    return true;
}

// Build g_pods from list + enum, then PodsToVectors → g_all.
// MUST hold g_mu. On failure leaves prior g_all intact.
// Foundation for multi-dot: Ascension unit discovery is primarily EnumVisibleObjects;
// list walk alone often returns 0 world units (that is why om.enum=0 killed aura_search).
//
// COLD / LOAD: NEVER call EnumVisibleObjects until list-only warm completes.
// Live crash 2026-07-31 15:41 — medium Register + PEW arm → enum mid-load → AV.
static bool BuildUnitSnapshotLocked() {
    g_podCount = 0;
    int listRc = SoftWalkSeh();
    static Pod s_listPods[kMaxEnum];
    size_t listN = 0;
    if (listRc == 1) {
        listN = g_podCount;
        if (listN > kMaxEnum) listN = kMaxEnum;
        for (size_t i = 0; i < listN; ++i) s_listPods[i] = g_pods[i];
        if (g_listWarmWalks < kListWarmWalks)
            ++g_listWarmWalks;
    }

    g_podCount = 0;
    // Enum is the primary unit source on Ascension (list alone is often empty).
    // After AV (caught by the VEH longjmp guard in SafeEnumVisibleAt): fall
    // back to list, but retry enum every 10s (not permanent death).
    ULONGLONG nowEnum = GetTickCount64();
    if (g_enumDead && nowEnum >= g_enumRetryAt) {
        g_enumDead = false;
        RL::Log::Info("EnumVisibleObjects retry after cooldown");
    }
    // CRITICAL (2026-08-01, permanent): EnumVisibleObjects must NEVER crash the
    // game when called from inside the Lua VM. It is a game function that
    // WRITES to every visible object while walking the OM (incl. object+0x2D0);
    // a mob freed mid-walk => AV_WRITE UAF at 0x004D3A40. SafeEnumVisibleAt
    // now wraps it in a VEH longjmp guard: an AV is caught, the walk is
    // abandoned, the enum is marked dead and retried later — the fault never
    // reaches the game's Lua protected-call wrapper (no crash, no "addon
    // blocked" dialog). Full unit discovery is therefore safe by default.
    const bool enumCfg = RL::Config::Get("om.enum", "1") != "0";
    // Warm gate: list-only for kListWarmWalks OR kEnumWarmMs after first player.
    const bool warmOk = (g_listWarmWalks >= kListWarmWalks)
        || (g_firstPlayerMs && (nowEnum - g_firstPlayerMs) >= kEnumWarmMs);
    // 2026-08-02 (0x512B07 ROOT CAUSE — 22:42 + 22:53 PROOF): EnumVisibleObjects
    // is a game function that WRITES to every visible object while walking. When
    // executed INSIDE the game's Lua VM call chain (Lua_IsLinuxClient ->
    // Dispatch -> OM), it corrupts the VM's TValues/closure table — the persistent
    // "Lua calls 0x512B00(GUID->object) with garbage" crash 6-16ms later, even
    // with NO descriptor write and even with VEH guarding the walk itself
    // (proven: crash on PLAIN CastSpell(guid) 22:53 with zero sync writes).
    // Enumeration must ONLY run from a NON-Lua context (the native frame hook).
    // The bridge serves the last snapshot built by the hook. List-only walk
    // (SoftWalkSeh, pure memory) is safe anywhere and stays.
    const bool inLua = InLuaContext();
    const bool wantEnum = !g_enumDead && enumCfg && warmOk && !inLua;
    int enumRc = 1;
    if (wantEnum) {
        enumRc = SafeEnumVisible(); // fills g_pods via callbacks (VEH-guarded)
        if (enumRc != 1) {
            if (!g_enumDeadLogged) {
                g_enumDeadLogged = true;
                RL::Log::Error(
                    "EnumVisibleObjects AV 0x%08X — list-only until retry",
                    enumRc);
            }
            g_enumDead = true;
            g_enumRetryAt = nowEnum + 10000ull;
            g_lastEnumRc = enumRc;
            g_podCount = 0;
        }
    } else if (!warmOk && enumCfg && !g_enumDead) {
        static ULONGLONG s_lastWarmLog = 0;
        if (nowEnum - s_lastWarmLog > 2000ull) {
            s_lastWarmLog = nowEnum;
            RL::Log::Info("OM list-only warm walks=%d/%d (enum deferred)",
                          g_listWarmWalks, kListWarmWalks);
        }
    }

    auto hasGuid = [&](uint64_t g) -> bool {
        if (!g) return false;
        for (size_t i = 0; i < g_podCount; ++i)
            if (g_pods[i].guid == g) return true;
        return false;
    };
    if (listRc == 1) {
        for (size_t i = 0; i < listN && g_podCount < kMaxEnum; ++i) {
            if (!hasGuid(s_listPods[i].guid))
                g_pods[g_podCount++] = s_listPods[i];
        }
    }

    if (g_podCount == 0)
        return false; // keep prior g_all

    if (!SoftPodsSeh())
        return false;

    // Epoch bump on real content change (2026-08-02): a re-enum that produced
    // an identical set must be FREE for the pack caches (no rebuild).
    uint64_t sig = SnapSignatureLocked();
    if (sig != g_snapSig) {
        g_snapSig = sig;
        g_snapGen++;
    }

    g_everWalkedOk = true;
    return true;
}

// Soft discovery for multi-dot (works with om.enable 0 or 1). Rate-limited.
// OOC: slower cadence (walk/loot FPS). Combat: full ~10 Hz.
static void SoftRefreshListOnlyForHostiles() {
    static ULONGLONG s_last = 0;
    ULONGLONG now = GetTickCount64();
    uint64_t local = SafeGetActive();
    if (!OmWalkAllowed(now, local)) return;
    ULONGLONG minIv = kWalkMinIntervalMs;
    // Player combat flag: throttle SoftRefresh while walking OOC.
    uintptr_t pp = SnapPtr(local); // snapshot-only (no ObjectPtr game call)
    if (pp && AcceptObjPtr(pp)) {
        uintptr_t d = Mem::Read<uintptr_t>(pp + Offsets::O().Descriptor);
        if (d && AcceptObjPtr(d)) {
            uint32_t uf = Mem::Read<uint32_t>(d + Offsets::D().Flags);
            if ((uf & kUF_IN_COMBAT) == 0)
                minIv = 280ull; // ~3.5 Hz OOC — multi-dot resumes at combat
        }
    }
    if ((now - s_last) < minIv) return;
    s_last = now;
    std::lock_guard<std::mutex> lock(g_mu);
    if (BuildUnitSnapshotLocked()) {
        g_lastRefresh = now;
        static size_t s_lastU = (size_t)-1;
        size_t u = g_byType[(int)ObjectType::Unit].size();
        if (u != s_lastU) {
            s_lastU = u;
            RL::Log::Info("OM soft discover units=%zu total=%zu enum_dead=%d",
                          u, g_all.size(), g_enumDead ? 1 : 0);
        }
    }
}

// ---- Runtime aura table (multi-dot authority; no UnitDebuff tokens) ----
struct AuraNote {
    uint64_t guid = 0;
    int spellId = 0;
    int stacks = 1;
    ULONGLONG expMs = 0;
};
static constexpr size_t kAuraCap = 512;
static AuraNote g_auras[kAuraCap];
static size_t g_auraN = 0;
static std::mutex g_auraMu;
static volatile ULONGLONG g_auraSearchGen = 1; // bump on note/clear to drop pack cache

static void AuraPruneLocked(ULONGLONG now) {
    size_t w = 0;
    for (size_t i = 0; i < g_auraN; ++i) {
        if (g_auras[i].expMs > now && g_auras[i].guid && g_auras[i].spellId > 0)
            g_auras[w++] = g_auras[i];
    }
    g_auraN = w;
}

std::string NearbyHostilesPacked(float maxRange, size_t maxN) {
    // ONE Refresh, then pure snapshot math. Lua must not ObjectPtr/ObjectHealth
    // each unit — that path crashed and lagged the client.
    //
    // FUNDAMENTAL multi-dot rule: hostiles pack MUST work without a client
    // target. Returning empty whenever om.enable=0 made aura_search blind and
    // forced the user to manually select a mob before Icy Touch would fire.
    // Soft path: list-only walk after settle even when suite froze om.enable
    // (never EnumVisibleObjects while disabled — that is the crash vector).
    uint64_t localGuid = SafeGetActive();
    if (!localGuid) return "0";

    // EPOCH CACHE (2026-08-02): stationary player + unchanged snapshot =>
    // O(1) return of the last packed string. Cache keys are read from the
    // snapshot (SnapshotPlayerState — pure memory, zero game calls). A 250ms
    // time bound guarantees the world is still refreshed even when this call
    // is the ONLY OM consumer. Epoch mismatch (real content change) is the
    // authority — it always misses.
    static std::string s_cacheOut;
    static ULONGLONG s_cacheGen = (ULONGLONG)-1;
    static ULONGLONG s_cacheT = 0;
    static uint64_t s_cacheLocal = 0;
    static float s_cacheX = 1e30f, s_cacheY = 1e30f, s_cacheFace = 1e30f;
    static float s_cacheRange = 0.f;
    static size_t s_cacheMaxN = 0;
    static int s_cacheFac = -1;
    Vec3 cPos{};
    float cFace = 0.f;
    int cFac = -1;
    if (SnapshotPlayerState(localGuid, &cPos, &cFace, &cFac)) {
        ULONGLONG nowC = GetTickCount64();
        if (s_cacheGen == g_snapGen && s_cacheLocal == localGuid
            && (nowC - s_cacheT) < 250ull
            && std::fabs(s_cacheX - cPos.x) < 1.5f
            && std::fabs(s_cacheY - cPos.y) < 1.5f
            && std::fabs(s_cacheFace - cFace) < 0.15f
            && std::fabs(s_cacheRange - maxRange) < 0.5f
            && s_cacheMaxN == maxN && s_cacheFac == cFac
            && !s_cacheOut.empty())
            return s_cacheOut;
    }

    if (IsEnabled()) {
        Refresh(false);
    } else {
        SoftRefreshListOnlyForHostiles();
    }
    // Still empty after settle skip — safe empty answer (no force Refresh).
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_all.empty() && g_byType[(int)ObjectType::Unit].empty())
            return "0";
    }
    Vec3 playerPos{};
    bool havePlayer = false;
    s_playerFaction = 0;
    if (localGuid) {
        playerPos = Position(localGuid);
        if (playerPos.x != 0.f || playerPos.y != 0.f) havePlayer = true;
        uintptr_t pp = SnapPtr(localGuid); // snapshot-only (no ObjectPtr game call)
        if (pp && AcceptObjPtr(pp)) {
            uintptr_t d = Mem::Read<uintptr_t>(pp + Offsets::O().Descriptor);
            if (d && AcceptObjPtr(d))
                s_playerFaction = Mem::Read<int>(d + Offsets::D().FactionTemplate);
        }
    }

    // Live player facing once (OM-independent field) for cast-front cone.
    float playerFace = 0.f;
    bool haveFace = false;
    if (localGuid) {
        playerFace = Facing(localGuid);
        haveFace = LooksLikeFacingEarly(playerFace);
    }

    struct Hit {
        uint64_t g;
        int entry;
        float x, y, z;
        float center; // 2D pivot distance
        float edge;   // center - 1.5 - 1.5 (default reaches; fine for pack counts)
        uint32_t flags;
        int hp, mhp;
        int face;     // 1 = in front of player (cast cone), 0 = not
    };
    std::vector<Hit> cands;
    cands.reserve(64);

    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (!havePlayer) {
            for (const auto& o : g_all) {
                if (o.type == ObjectType::Player && (o.pos.x != 0.f || o.pos.y != 0.f)) {
                    if (localGuid && o.guid == localGuid) {
                        playerPos = o.pos; havePlayer = true; break;
                    }
                    if (!havePlayer) { playerPos = o.pos; havePlayer = true; }
                }
            }
        }

        auto consider = [&](const Object& o) {
            if (!SnapshotLooksHostileNpc(o, localGuid)) return;
            float cx = 0.f, edge = 0.f;
            int face = 0;
            if (havePlayer) {
                float dx = o.pos.x - playerPos.x;
                float dy = o.pos.y - playerPos.y;
                cx = std::sqrt(dx * dx + dy * dy);
                if (cx > maxRange + 5.f) return;
                edge = cx - 3.f;
                if (edge < 0.f) edge = 0.f;
                if (haveFace)
                    face = IsFacingPos(playerFace, playerPos.x, playerPos.y,
                                       o.pos.x, o.pos.y, kDefaultCastFaceArc) ? 1 : 0;
                else
                    face = 1; // unknown facing: do not drop units from the list
            }
            cands.push_back({
                o.guid, o.entry, o.pos.x, o.pos.y, o.pos.z,
                cx, edge, o.unitFlags, o.health, o.maxHealth, face
            });
        };

        for (const auto& o : g_byType[(int)ObjectType::Unit])
            consider(o);
        if (g_byType[(int)ObjectType::Unit].empty()) {
            for (const auto& o : g_all)
                consider(o);
        }
    }

    size_t nh = cands.size();
    if (nh > maxN) nh = maxN;
    if (nh > 48) nh = 48;
    if (nh > 0) {
        // Prefer in-front hostiles, then nearest — multi-dot never picks a back
        // unit first when a front unit is available.
        std::partial_sort(cands.begin(), cands.begin() + (std::ptrdiff_t)nh, cands.end(),
                          [](const Hit& a, const Hit& b) {
                              if (a.face != b.face) return a.face > b.face;
                              return a.center < b.center;
                          });
    }

    char out[8192];
    size_t off = 0;
    off += (size_t)snprintf(out + off, sizeof(out) - off, "%zu", nh);
    for (size_t i = 0; i < nh && off + 100 < sizeof(out); ++i) {
        const Hit& h = cands[i];
        off += (size_t)snprintf(out + off, sizeof(out) - off,
                                "|0x%llX:%d:%.2f:%.2f:%.2f:%.2f:%.2f:%u:%d:%d:%d",
                                (unsigned long long)h.g, h.entry,
                                h.x, h.y, h.z, h.center, h.edge,
                                (unsigned)h.flags, h.hp, h.mhp, h.face);
    }
    s_cacheOut.assign(out, off);
    s_cacheGen = g_snapGen;
    s_cacheT = GetTickCount64();
    s_cacheLocal = localGuid;
    s_cacheX = cPos.x; s_cacheY = cPos.y; s_cacheFace = cFace;
    s_cacheRange = maxRange; s_cacheMaxN = maxN; s_cacheFac = cFac;
    return s_cacheOut;
}

void NoteUnitAura(uint64_t guid, int spellId, int stacks, float durationSec) {
    if (!guid || spellId <= 0) return;
    if (stacks < 1) stacks = 1;
    if (durationSec < 1.f) durationSec = 15.f;
    if (durationSec > 120.f) durationSec = 60.f;
    ULONGLONG now = GetTickCount64();
    ULONGLONG exp = now + (ULONGLONG)(durationSec * 1000.f);
    // Only bump g_auraSearchGen on a REAL change. Seed-every-tick + always-bump
    // killed the 80ms AuraSearch pack cache → SoftRefresh every rotation frame
    // (lag spikes + OM thrash / random hard kills). Refreshing an existing note
    // with similar stacks/exp must be free.
    std::lock_guard<std::mutex> lock(g_auraMu);
    AuraPruneLocked(now);
    for (size_t i = 0; i < g_auraN; ++i) {
        if (g_auras[i].guid == guid && g_auras[i].spellId == spellId) {
            const bool stacksChg = (g_auras[i].stacks != stacks);
            // >2s remaining change = meaningful refresh/refresh lag; ignore jitter.
            const long long dExp = (long long)exp - (long long)g_auras[i].expMs;
            const bool expChg = (dExp > 2000ll || dExp < -2000ll);
            g_auras[i].stacks = stacks;
            if (exp > g_auras[i].expMs) g_auras[i].expMs = exp; // never shorten on seed
            else if (expChg) g_auras[i].expMs = exp;
            if (stacksChg || expChg) g_auraSearchGen++;
            return;
        }
    }
    if (g_auraN >= kAuraCap) {
        // Drop oldest
        for (size_t i = 1; i < g_auraN; ++i) g_auras[i - 1] = g_auras[i];
        --g_auraN;
    }
    g_auras[g_auraN++] = { guid, spellId, stacks, exp };
    g_auraSearchGen++;
}

void ClearUnitAura(uint64_t guid, int spellId) {
    if (!guid || spellId <= 0) return;
    g_auraSearchGen++;
    std::lock_guard<std::mutex> lock(g_auraMu);
    size_t w = 0;
    for (size_t i = 0; i < g_auraN; ++i) {
        if (g_auras[i].guid == guid && g_auras[i].spellId == spellId)
            continue;
        g_auras[w++] = g_auras[i];
    }
    g_auraN = w;
}

bool HasUnitAura(uint64_t guid, int spellId, int* outStacks) {
    if (outStacks) *outStacks = 0;
    if (!guid || spellId <= 0) return false;
    ULONGLONG now = GetTickCount64();
    std::lock_guard<std::mutex> lock(g_auraMu);
    AuraPruneLocked(now);
    for (size_t i = 0; i < g_auraN; ++i) {
        if (g_auras[i].guid == guid && g_auras[i].spellId == spellId) {
            if (outStacks) *outStacks = g_auras[i].stacks;
            return true;
        }
    }
    return false;
}

std::string AuraSearchPacked(float maxRange, int spellId, bool wantMissing, size_t maxN) {
    // RUNTIME-FIRST multi-dot. Always soft-refresh capable so discovery works
    // even when om.enable is 0 or Refresh is quiet. 2026-08-02 (18:16 user:
    // "aura search extremely slow/not reactive") — cache reduced 120ms->50ms
    // so a new target is picked up within ~1-2 frames instead of ~4-5.
    if (spellId <= 0) return "0";
    static ULONGLONG s_cacheT = 0;
    static ULONGLONG s_cacheGen = 0;
    static int s_cacheSid = 0;
    static float s_cacheRange = 0.f;
    static int s_cacheMissing = -1;
    static size_t s_cacheMaxN = 0;
    static std::string s_cacheOut;
    ULONGLONG now = GetTickCount64();
    if (s_cacheSid == spellId && s_cacheMissing == (wantMissing ? 1 : 0)
        && std::fabs(s_cacheRange - maxRange) < 0.5f && s_cacheMaxN == maxN
        && s_cacheGen == g_auraSearchGen
        && s_cacheT && (now - s_cacheT) < 50ull && !s_cacheOut.empty()
        && s_cacheOut != "0") {
        return s_cacheOut;
    }

    uint64_t localGuid = SafeGetActive();
    if (!localGuid) return "0";
    // Soft list is the multi-dot backbone (works with om.enable 0 or 1).
    // Do NOT also force Refresh on the same call — SoftRefresh already ran the
    // same BuildUnitSnapshotLocked; double walks were a combat lag spike.
    SoftRefreshListOnlyForHostiles();
    const bool omOn = IsEnabled();
    // Only Refresh if soft path was quiet for a while (e.g. om just turned on).
    if (omOn && (!g_lastRefresh || (now - g_lastRefresh) >= 250ull))
        Refresh(false);

    Vec3 playerPos = Position(localGuid);
    bool havePlayer = (playerPos.x != 0.f || playerPos.y != 0.f);
    s_playerFaction = 0;
    uintptr_t pp = SnapPtr(localGuid); // snapshot-only (no ObjectPtr game call)
    if (pp && AcceptObjPtr(pp)) {
        uintptr_t d = Mem::Read<uintptr_t>(pp + Offsets::O().Descriptor);
        if (d && AcceptObjPtr(d))
            s_playerFaction = Mem::Read<int>(d + Offsets::D().FactionTemplate);
    }
    float playerFace = Facing(localGuid);
    bool haveFace = LooksLikeFacingEarly(playerFace);

    // Snapshot aura notes without nested locks during OM walk.
    struct AuraSnap { uint64_t g; int sid; };
    AuraSnap auraSnap[kAuraCap];
    size_t auraSnapN = 0;
    {
        std::lock_guard<std::mutex> alock(g_auraMu);
        AuraPruneLocked(now);
        for (size_t i = 0; i < g_auraN && auraSnapN < kAuraCap; ++i) {
            if (g_auras[i].spellId == spellId)
                auraSnap[auraSnapN++] = { g_auras[i].guid, g_auras[i].spellId };
        }
    }
    auto hasAura = [&](uint64_t g) -> bool {
        for (size_t i = 0; i < auraSnapN; ++i)
            if (auraSnap[i].g == g) return true;
        return false;
    };

    struct Hit {
        uint64_t g; int entry;
        float center, edge;
        float face_err; // |delta yaw| rad — 0 = dead center of FOV
        int face, hp, mhp;
    };
    std::vector<Hit> cands;
    cands.reserve(32);

    {
        std::lock_guard<std::mutex> lock(g_mu);
        auto consider = [&](const Object& o) {
            if (o.guid == localGuid || !o.guid) return;
            if (!SnapshotLooksHostileNpc(o, localGuid)) return;
            if (o.maxHealth > 0 && o.health <= 0) return;
            if (o.unitFlags & kUF_NOT_SELECTABLE) return;
            float cx = 999.f, edge = 999.f;
            float face_err = 3.14159265f; // worst until measured
            int face = 1;
            if (havePlayer) {
                float dx = o.pos.x - playerPos.x;
                float dy = o.pos.y - playerPos.y;
                cx = std::sqrt(dx * dx + dy * dy);
                if (cx > maxRange + 1.f) return;
                edge = cx - 3.f;
                if (edge < 0.f) edge = 0.f;
                if (haveFace) {
                    // 2026-08-02 (18:16 FACING CONVENTION — same fix as
                    // IsFacingPos): std::atan2 is 0=+X(east)/CCW, the client's
                    // facing (0x7AC / GetPlayerFacing) is 0=+Y(north)/CW — they
                    // are offset 90°. Convert: facing_wow = π/2 - atan2(dy,dx).
                    // Without this the aura-search `face` field disagrees with
                    // the client's own arc check (targets the player faces get
                    // marked not-facing and vice versa -> "in front of you"
                    // refusals on non-faced wires).
                    float ang = 1.5707963f - std::atan2(dy, dx);
                    float diff = ang - playerFace;
                    const float pi = 3.14159265f;
                    const float two = 6.2831853f;
                    while (diff > pi) diff -= two;
                    while (diff < -pi) diff += two;
                    face_err = std::fabs(diff);
                    face = (face_err <= kDefaultCastFaceArc) ? 1 : 0;
                }
            }
            bool has = hasAura(o.guid);
            if (wantMissing) { if (has) return; }
            else { if (!has) return; }
            cands.push_back({ o.guid, o.entry, cx, edge, face_err, face, o.health, o.maxHealth });
        };
        for (const auto& o : g_byType[(int)ObjectType::Unit])
            consider(o);
        if (g_byType[(int)ObjectType::Unit].empty()) {
            for (const auto& o : g_all)
                if (o.type == ObjectType::Unit || o.type == ObjectType::Player)
                    consider(o);
        }
    }

    size_t nh = cands.size();
    if (nh > maxN) nh = maxN;
    if (nh > 12) nh = 12;
    // Ranking (user): 1) closest to me  2) on distance tie, closer to FOV centre
    // (smallest |face_err|). Facing cone is NOT a hard primary key.
    if (nh > 0) {
        std::partial_sort(cands.begin(), cands.begin() + (std::ptrdiff_t)nh, cands.end(),
                          [](const Hit& a, const Hit& b) {
                              const float dist_tie = 0.75f; // yards — "same range"
                              if (std::fabs(a.center - b.center) > dist_tie)
                                  return a.center < b.center;
                              if (std::fabs(a.face_err - b.face_err) > 0.02f)
                                  return a.face_err < b.face_err;
                              return a.center < b.center;
                          });
    }
    char out[4096];
    size_t off = 0;
    off += (size_t)snprintf(out + off, sizeof(out) - off, "%zu", nh);
    for (size_t i = 0; i < nh && off + 80 < sizeof(out); ++i) {
        const Hit& h = cands[i];
        off += (size_t)snprintf(out + off, sizeof(out) - off,
                                "|0x%llX:%d:%.2f:%.2f:%d:%d:%d",
                                (unsigned long long)h.g, h.entry,
                                h.center, h.edge, h.face, h.hp, h.mhp);
    }
    s_cacheOut.assign(out, off);
    s_cacheT = now;
    s_cacheGen = g_auraSearchGen;
    s_cacheSid = spellId;
    s_cacheRange = maxRange;
    s_cacheMissing = wantMissing ? 1 : 0;
    s_cacheMaxN = maxN;
    return s_cacheOut;
}

// ---- Whole-OM snapshot (2026-08-02) --------------------------------------
// ONE call returns the entire cached object list packed as ONE string — the
// shared-memory / zero-copy pattern from the optimization guide. The runtime
// IS the OM authority; the addon's Lua OM parses this instead of making ~5
// bridge calls per object per tick (each an ObjectPtr game call = the lag +
// Guard::Scope longjmp-recovery crash vector, live 1.10.68 RVA 0x785A).
// Pack: "count|0xGUID:TYPE:ENTRY:FLAGS:DYNFLAGS:LVL:HP:MHP:X:Y:Z:FACE:FACTION:
//        0xTARGET:SCALE:GOBYTES1:NPCFLAGS|..."
// TYPE is the same bitmask ObjectTypeFlags returns (Object=1, Unit=32,
// Player=64, GameObject=256, DynamicObject=512, Corpse=1024, ...).
// Cost: one throttled Refresh + one sequential snprintf pass over g_all
// (prefetch-friendly, zero per-object game calls, zero per-object allocs).
std::string OmSnapshotPacked() {
    // 100ms pack cache (2026-08-02): the Lua OM, corpse scan and gather all
    // call this; one pack per window regardless of callers. The underlying
    // Refresh is already throttled; this removes the redundant packing.
    static ULONGLONG s_packT = 0;
    static std::string s_packOut;
    ULONGLONG nowPack = GetTickCount64();
    if (s_packT && (nowPack - s_packT) < 100ull && !s_packOut.empty())
        return s_packOut;

    // Soft list-only when om frozen — same rule as the packers. Refresh(false)
    // returns with g_all EMPTY when om.enable=0 (the soft path owns discovery
    // while frozen); without this the Lua OM would see an empty world.
    if (IsEnabled())
        Refresh(false);
    else
        SoftRefreshListOnlyForHostiles();
    // 2026-08-02 (CRASH FIX): build into a HEAP std::string, never a huge C
    // stack array. OmSnapshotPacked runs inside the game's Lua VM call chain
    // (Lua interpreter -> Lua_IsLinuxClient -> Dispatch -> here); a ~70KB
    // `char out[4096 + 512*128]` on the C stack inside that deep chain risks
    // smashing the VM's stack (live rotation-enable crash family). The runtime
    // is a self-modifying stealth DLL — every byte of stack we burn is a byte
    // of frame budget the game's Lua VM does not have. Object cap stays 512.
    size_t n = g_all.size();
    if (n > 512) n = 512;
    std::string out;
    out.reserve(4096 + n * 128);
    out.append(std::to_string(n));
    {
        std::lock_guard<std::mutex> lock(g_mu);
        for (size_t i = 0; i < n; ++i) {
            const Object& o = g_all[i];
            int mask = 1; // Object
            switch (o.type) {
                case ObjectType::Item:          mask |= 2;              break;
                case ObjectType::Container:     mask |= 2 | 4;          break;
                case ObjectType::Unit:          mask |= 32;             break;
                case ObjectType::Player:        mask |= 32 | 64;        break;
                case ObjectType::GameObject:    mask |= 256;            break;
                case ObjectType::DynamicObject: mask |= 512;            break;
                case ObjectType::Corpse:        mask |= 1024;           break;
                default:                                                 break;
            }
            char row[160];
            int rl = snprintf(row, sizeof(row),
                "|0x%llX:%d:%d:%u:%u:%d:%d:%d:%.1f:%.1f:%.1f:%.3f:%d:0x%llX:%.2f:%u:%u:%d",
                (unsigned long long)o.guid, mask, o.entry,
                (unsigned)o.unitFlags, (unsigned)o.dynamicFlags,
                o.level, o.health, o.maxHealth,
                o.pos.x, o.pos.y, o.pos.z, o.facing, o.faction,
                (unsigned long long)o.unitTarget, o.scale,
                (unsigned)o.goBytes1, (unsigned)o.npcFlags, o.creatureType);
            if (rl > 0) out.append(row, (size_t)rl);
        }
    }
    s_packT = nowPack;
    s_packOut.swap(out);
    return s_packOut;
}

void Refresh(bool force) {
    std::lock_guard<std::mutex> lock(g_mu);

    ULONGLONG now = GetTickCount64();
    int ttl = RL::Config::Opts().omCacheMs;
    if (ttl < (int)kWalkMinIntervalMs) ttl = (int)kWalkMinIntervalMs;
    if (!force && g_lastRefresh && (now - g_lastRefresh) < (ULONGLONG)ttl) return;

    uint64_t local = SafeGetActive();
    if (!local) {
        g_all.clear();
        for (auto& v : g_byType) v.clear();
        g_lastRefresh = now;
        return;
    }

    // 2026-08-01: enumeration is VEH-guarded (SafeEnumVisible) per the codebase
    // design. Enumeration stays allowed here (the addon needs live hostile data
    // to cast). The 0x512B07 corruption is handled by the crash-fix in
    // Dispatch/Lua_IsLinuxClient (OM::SetInLuaContext no longer gates walking -
    // that deadlocked casting when the native hook carrier was unavailable).
    const bool omOn = IsEnabled();
    if (!omOn) {
        // Soft path (SoftRefresh / AuraSearch) owns discovery while frozen.
        g_omWasOn = false;
        g_lastRefresh = now;
        return;
    }
    if (!g_omWasOn) {
        g_omWasOn = true;
        RL::Log::Info("OM enable — runtime discovery (enum+list)");
    }

    if (!OmWalkAllowed(now, local)) {
        g_lastRefresh = now;
        return;
    }

    // Same builder SoftRefresh uses — enum is required for Ascension units.
    if (BuildUnitSnapshotLocked()) {
        g_lastRefresh = now;
        static size_t s_lastU = (size_t)-1;
        size_t u = g_byType[(int)ObjectType::Unit].size();
        if (u != s_lastU) {
            s_lastU = u;
            RL::Log::Info("OM ok units=%zu total=%zu enum_dead=%d",
                          u, g_all.size(), g_enumDead ? 1 : 0);
        }
    } else {
        g_lastRefresh = now; // keep prior snapshot
    }
}

size_t Count() {
    Refresh(false);
    std::lock_guard<std::mutex> lock(g_mu);
    return g_all.size();
}
size_t Count(ObjectType type) {
    Refresh(false);
    std::lock_guard<std::mutex> lock(g_mu);
    int t = (int)type;
    return (t >= 0 && t < 8) ? g_byType[t].size() : 0;
}

const Object* At(size_t index1based) {
    Refresh(false);
    std::lock_guard<std::mutex> lock(g_mu);
    if (!index1based || index1based > g_all.size()) return nullptr;
    return &g_all[index1based - 1];
}

const Object* AtType(ObjectType type, size_t index1based) {
    Refresh(false);
    std::lock_guard<std::mutex> lock(g_mu);
    int t = (int)type;
    if (t < 0 || t >= 8 || !index1based) return nullptr;
    auto& v = g_byType[t];
    if (index1based > v.size()) return nullptr;
    return &v[index1based - 1];
}

const Object* ByGuid(uint64_t guid) {
    Refresh(false);
    std::lock_guard<std::mutex> lock(g_mu);
    for (auto& o : g_all) if (o.guid == guid) return &o;
    return nullptr;
}

const std::vector<Object>& All() { Refresh(false); return g_all; }

uint64_t LocalGuid() { return SafeGetActive(); }

// Local player object pointer — SNAPSHOT-FIRST (2026-08-02 crash fix).
// SafeObjectPtr is a GAME call (ObjectPtr -> hash) that must not run from the
// Lua VM hot path; the snapshot's cached o->ptr is pure memory and always
// contains the player once the first Refresh/SoftRefresh has run. Fall back to
// the VirtualQuery-guarded literal 0x00C7B098 (pure memory), then — ONLY as a
// cold-start last resort — the VEH-guarded SafeObjectPtr (rare, never hot).
uintptr_t LocalPtr() {
    uint64_t g = LocalGuid();
    if (g) {
        if (const Object* o = SnapByGuid(g))
            if (o->ptr) return o->ptr;
        uintptr_t p = Mem::Read<uintptr_t>(0x00C7B098);
        if (AcceptObjPtr(p)) return p;
        if (uintptr_t sp = SafeObjectPtr(g)) return sp;
    }
    uintptr_t p = Mem::Read<uintptr_t>(0x00C7B098);
    return AcceptObjPtr(p);
}

bool InWorld() { return LocalGuid() != 0 || LocalPtr() != 0; }

uintptr_t Ptr(uint64_t guid) {
    if (!guid) return 0;
    return SafeObjectPtr(guid);
}

ObjectType Type(uint64_t guid) {
    // Snapshot-only (crash fix): no ObjectPtr game-call fallback from the bridge.
    if (const Object* o = SnapByGuid(guid)) return o->type;
    return ObjectType::None;
}

Vec3 Position(uint64_t guid) {
    // LOCAL PLAYER: LIVE read via LocalPtr() — snapshot-first, then the
    // pure-memory 0x00C7B098 CGPlayer* (works BEFORE the snapshot exists), then
    // a VEH-guarded SafeObjectPtr cold fallback. ReadPosOffsets is pure memory
    // (camera-gated). This is REQUIRED by OmWalkAllowed (the walk gate reads
    // Position(localGuid) BEFORE any snapshot is built — a snapshot-only read
    // there deadlocked the whole OM: no walk -> empty g_all -> 0 positions ->
    // casting/aura_search/facing all dead, live 15:17 1.10.69-runtime).
    // NON-LOCAL: snapshot-only (o->pos) — no ObjectPtr game call from the VM.
    if (guid == LocalGuid()) {
        uintptr_t p = LocalPtr();
        if (p) {
            Vec3 v = ReadPosOffsets(p, true);
            if (v.x != 0.f || v.y != 0.f || v.z != 0.f) return v;
        }
        // Cold/validation only (OmWalkAllowed gate, pre-snapshot, rate-limited):
        // LocalPtr's pure-memory 0xC7B098 may be stale/garbage on this client —
        // fall back to the VEH-guarded live ObjectPtr so the OM walk can ever
        // start. This is NOT the per-call Lua hot path (that hits the snapshot).
        if (uintptr_t sp = SafeObjectPtr(guid)) {
            Vec3 v = ReadPosOffsets(sp, true);
            if (v.x != 0.f || v.y != 0.f || v.z != 0.f) return v;
        }
        if (const Object* o = SnapByGuid(guid)) return o->pos;
        return {};
    }
    if (const Object* o = SnapByGuid(guid)) return o->pos;
    return {};
}

Vec3 PositionFromPtr(uintptr_t ptr) {
    // Unknown object: non-local rules (no camera gate, no poison pin).
    return ReadPosOffsets(ptr, false);
}

// Local player by pointer: always use local (camera-gated) rules.
Vec3 PositionLocalFromPtr(uintptr_t ptr) {
    return ReadPosOffsets(ptr, true);
}

// Diagnostic: which pos layout is cached after ReadPosOffsets.
void PosLayoutDiag(char* buf, size_t bufN) {
    if (!buf || !bufN) return;
    snprintf(buf, bufN, "mode=%d|a=0x%X|b=0x%X|c=0x%X",
             g_posMode, (unsigned)g_posA, (unsigned)g_posB, (unsigned)g_posC);
}

// A facing is an angle in radians: anything outside roughly [-2pi, 4pi] (or NaN)
// is a bad read, not an orientation. Returning it unchecked is what let the
// LOCAL PLAYER report 4.5e20 in every single heartbeat sample.
static inline bool LooksLikeFacing(float f) {
    if (f != f) return false;                       // NaN
    if (f < -6.30f || f > 12.60f) return false;     // ~[-2pi, 4pi] with slack
    return true;
}

float Facing(uint64_t guid) {
    // LOCAL PLAYER: LIVE 0x7AC via LocalPtr() (works before the snapshot exists,
    // same as Position). NON-LOCAL: snapshot o->facing only (no ObjectPtr game
    // call from the VM). Unknown -> 0.f = "no measurement".
    if (guid == LocalGuid()) {
        // 2026-08-02 (FACING ROOT CAUSE — RE-VERIFIED LIVE): LocalPtr()+0x7AC
        // reads 0 on this build (live: runtime PlayerFacing()=0 while the
        // client's own GetPlayerFacing()=1.4547 at the same instant). The client
        // resolves the player via camera → GUID → ClntObjMgrObjectPtr and reads
        // [obj+0x7AC]. Use that RE-correct path FIRST; LocalPtr only as fallback.
        float live = FacingLiveLocal();
        if (live < 1e8f) return live;
        uintptr_t p = LocalPtr();
        if (p) {
            float f = Mem::Read<float>(p + 0x7AC);
            if (LooksLikeFacing(f)) return f;
        }
        if (const Object* o = SnapByGuid(guid)) {
            if (LooksLikeFacing(o->facing)) return o->facing;
        }
        return 0.f;
    }
    if (const Object* o = SnapByGuid(guid)) {
        if (LooksLikeFacing(o->facing)) return o->facing;
    }
    return 0.f;
}

// Trinity/MaNGOS defaults when descriptor field is 0.
static constexpr float kDefaultCombatReach = 1.5f;
static constexpr float kDefaultBoundingRadius = 0.5f;

// Strict: real hitbox radii only. Reject NaN/Inf, position-bleed, and junk
// from the old unit-field window scan (pReach was 2.7-3.5 and moving).
static bool LooksLikeReach(float r, bool combat) {
    if (r != r) return false;
    if (r < 0.05f) return false;
    // Combat reach can be huge on bosses; bounding is smaller but still large
    // on giant models. Cap only absurd floats (coords / garbage).
    if (combat) {
        if (r > 100.f) return false;
    } else {
        if (r > 80.f) return false;
    }
    return true;
}

// Reject floats that are clearly world positions (PosProbe: u7d4 == pos.x).
static bool LooksLikeWorldCoord(float v) {
    if (v != v) return true;
    float a = v < 0.f ? -v : v;
    // Azeroth pivots are thousands of yards; hitbox radii never are.
    return a > 200.f;
}

// Authoritative hitbox read (AscensionDescriptors + Trinity defaults).
// NO unit-body window scan - that mixed in facing/speed/position and made
// every EDGE/WW calculation wrong (live: pReach 2.7-3.5, tReach 5.36 junk).
//
// combat=true  -> UNIT_FIELD_COMBATREACH @ desc+0x10C, default 1.5
// combat=false -> UNIT_FIELD_BOUNDINGRADIUS @ desc+0x108, default 0.5
//
// Optional classic CGUnit caches at +0x7D4 / +0x7D0 only when they pass
// strict validation and do not match the unit's position components.
static float ReadReachField(uintptr_t ptr, bool combat) {
    if (!AcceptObjPtr(ptr)) return 0.f;

    float px = Mem::Read<float>(ptr + 0x798);
    float py = Mem::Read<float>(ptr + 0x79C);
    float pz = Mem::Read<float>(ptr + 0x7A0);

    auto accept = [&](float r) -> bool {
        if (!LooksLikeReach(r, combat)) return false;
        if (LooksLikeWorldCoord(r)) return false;
        // Bleed of position cache into adjacent fields
        if (px == r || py == r || pz == r) return false;
        if (px == -r || py == -r || pz == -r) return false;
        return true;
    };

    // 1) Descriptor fields (authoritative for 3.3.5 / Ascension).
    uintptr_t desc = Mem::Read<uintptr_t>(ptr + Offsets::O().Descriptor);
    if (AcceptObjPtr(desc)) {
        float r = Mem::Read<float>(desc + (combat ? 0x10Cu : 0x108u));
        if (accept(r)) return r;
    }

    // 2) Classic CGUnit float cache (only the single known slot, no scan).
    {
        float r = Mem::Read<float>(ptr + (combat ? 0x7D4u : 0x7D0u));
        if (accept(r)) return r;
    }

    return 0.f; // caller applies Trinity default
}

float CombatReachFromPtr(uintptr_t ptr) {
    if (!AcceptObjPtr(ptr)) return 0.f;
    float r = ReadReachField(ptr, true);
    // Trinity: GetCombatReach() returns DEFAULT (1.5) when field is 0.
    return (r > 0.f) ? r : kDefaultCombatReach;
}

float BoundingRadiusFromPtr(uintptr_t ptr) {
    if (!AcceptObjPtr(ptr)) return 0.f;
    float r = ReadReachField(ptr, false);
    return (r > 0.f) ? r : kDefaultBoundingRadius;
}

float CombatReach(uint64_t guid) {
    // Snapshot-only (crash fix): the ObjectPtr game-call fallback is deleted.
    // Callers apply the Trinity 1.5 default when 0 is returned.
    if (const Object* o = SnapByGuid(guid))
        return CombatReachFromPtr(o->ptr);
    return 0.f;
}

float BoundingRadius(uint64_t guid) {
    // Snapshot-only (crash fix): no ObjectPtr game-call fallback.
    if (const Object* o = SnapByGuid(guid))
        return BoundingRadiusFromPtr(o->ptr);
    return 0.f;
}

int Entry(uint64_t guid) {
    if (const Object* o = SnapByGuid(guid)) return o->entry;
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<int>(d + Offsets::D().Entry) : 0;
}

int Health(uint64_t guid) {
    // Descriptor only. NEVER call CGUnit_GetHealth thiscall from the bridge:
    // live crash 2026-07-31 when suite+rotation scanned enemies — thiscall on
    // non-unit / bad ptr requested ~2.8GB and killed the client (stack:
    // RuntimeCall ObjectHealth -> om_unit_is_hostile -> collect_nearby_enemies).
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return 0;
    int hp = 0;
    __try {
        hp = Mem::Read<int>(d + Offsets::D().Health);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
    // Sanity: living units are rarely > 50M HP; garbage descriptor reads are huge.
    if (hp < 0 || hp > 50000000) return 0;
    return hp;
}

int MaxHealth(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return 0;
    int mhp = 0;
    __try {
        mhp = Mem::Read<int>(d + Offsets::D().MaxHealth);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
    if (mhp < 0 || mhp > 50000000) return 0;
    return mhp;
}

int Level(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<int>(d + Offsets::D().Level) : 0;
}

uint32_t UnitFlags(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<uint32_t>(d + Offsets::D().Flags) : 0;
}

// ---- Unit power / combat / creature-type (verified descriptor offsets) ------
// Descriptor byte offsets derived from verified Health(0x60) + MaxHealth(0x80):
// POWER1-7 are contiguous between Health and MaxHealth: 0x64,0x68,0x6C,0x70,0x74,0x78,0x7C
// MAXPOWER1-7 follow MaxHealth: 0x84,0x88,0x8C,0x90,0x94,0x98,0x9C

int UnitPower(uint64_t guid, int powerType) {
    if (powerType < 0 || powerType > 6) return -1;
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    // Power fields start at Health+4 (0x64), 4 bytes each
    static const uintptr_t kPowerBase = 0x64;
    uintptr_t off = kPowerBase + (uintptr_t)powerType * 4u;
    __try {
        int val = Mem::Read<int>(d + off);
        return (val >= 0 && val < 1000000) ? val : -1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

int UnitMaxPower(uint64_t guid, int powerType) {
    if (powerType < 0 || powerType > 6) return -1;
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    // MaxPower fields start at MaxHealth+4 (0x84), 4 bytes each
    static const uintptr_t kMaxPowerBase = 0x84;
    uintptr_t off = kMaxPowerBase + (uintptr_t)powerType * 4u;
    __try {
        int val = Mem::Read<int>(d + off);
        return (val >= 0 && val < 1000000) ? val : -1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

int UnitPowerType(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    // Bytes0 at 0xC0: byte3 = power type
    __try {
        uint32_t bytes0 = Mem::Read<uint32_t>(d + Offsets::D().Bytes0);
        return (int)((bytes0 >> 24) & 0xFF);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

int UnitCombatState(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    static constexpr uint32_t kUF_IN_COMBAT = 0x00080000u;
    __try {
        uint32_t flags = Mem::Read<uint32_t>(d + Offsets::D().Flags);
        return (flags & kUF_IN_COMBAT) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

// Player casting state — CRASH RULE (permanent): UnitCastingInfo via nested
// lua_pcall from the bridge corrupts the Lua stack (proven). SAFE: always
// reports "not casting" (-1, 0). The addon reads UnitCastingInfo via its own
// Lua (Lua→Lua, safe).
void PlayerCastState(int* outSpellId, int* outTotalMs, int* outElapsedMs) {
    *outSpellId = -1; *outTotalMs = 0; *outElapsedMs = 0;
}

// ---- Mounted / movement impairment (verified descriptor offsets) -----------
int IsUnitMounted(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    // MountDisplayId at descriptor offset 0x114 — non-zero means mounted
    __try {
        uint32_t mountId = Mem::Read<uint32_t>(d + Offsets::D().MountDisplayId);
        return (mountId != 0) ? 1 : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

int UnitMovementImpairing(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return -1;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return -1;
    static constexpr uint32_t kUF_STUNNED    = 0x00040000u;
    static constexpr uint32_t kUF_DISARMED   = 0x00200000u;
    static constexpr uint32_t kUF_CONFUSED   = 0x00000040u;
    static constexpr uint32_t kUF_FLEEING    = 0x00000800u;
    __try {
        uint32_t flags = Mem::Read<uint32_t>(d + Offsets::D().Flags);
        int result = 0;
        if (flags & kUF_STUNNED)  result |= 1;
        if (flags & kUF_DISARMED) result |= 2;
        if (flags & kUF_CONFUSED) result |= 4;
        if (flags & kUF_FLEEING)  result |= 8;
        return result;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

// Packed player state using verified descriptor fields
static int PlayerSwimFlySEH(uintptr_t pp) {
    if (!pp || !AcceptObjPtr(pp)) return -1;
    uintptr_t movPtr = Mem::Read<uintptr_t>(pp + Offsets::O().Movement);
    if (!movPtr || !AcceptObjPtr(movPtr)) return -1;
    static constexpr uint32_t MOVEF_SWIMMING = 0x00200000u;
    static constexpr uint32_t MOVEF_FLYING   = 0x00000200u;
    int result = 0;
    __try {
        uint32_t mf = Mem::Read<uint32_t>(movPtr + 0x28);
        if (mf & MOVEF_SWIMMING) result |= 1;
        if (mf & MOVEF_FLYING)   result |= 2;
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
    return result;
}

std::string PlayerStatePacked() {
    uint64_t local = SafeGetActive();
    if (!local) return "combat=-1|mounted=-1|dead=-1|swim=-1|flying=-1";

    int combat = UnitCombatState(local);
    int mounted = IsUnitMounted(local);
    int hp = Health(local);
    bool isDead = (hp == 0);
    int swim = -1, flying = -1;
    uintptr_t pp = LocalPtr();
    int sf = PlayerSwimFlySEH(pp);
    if (sf >= 0) { swim = (sf & 1) ? 1 : 0; flying = (sf & 2) ? 1 : 0; }

    char buf[128];
    snprintf(buf, sizeof(buf), "combat=%d|mounted=%d|dead=%d|swim=%d|flying=%d",
             combat, mounted, isDead ? 1 : 0, swim, flying);
    return std::string(buf);
}

// Dynamic flags, read from the field that ACTUALLY holds them for this type.

// ---- Unit target / shapeshift (verified descriptor + Lua pcall) -----------
uint64_t UnitTargetGuid(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p || !Mem::Readable(p)) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || !Mem::Readable(d)) return 0;
    __try {
        return Mem::Read<uint64_t>(d + 0x48); // UNIT_FIELD_TARGET verified
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

// CRASH RULE (permanent): GetShapeshiftForm via nested lua_pcall from the
// bridge corrupts the Lua stack (proven). SAFE: -1 = unknown. The addon reads
// GetShapeshiftForm/GetShapeshiftFormInfo via its own Lua (Lua→Lua, safe).
int ShapeshiftForm() {
    return -1;
}

// ---- Unit relationship (faction-based, verified descriptor offsets) --------
const char* UnitRelationship(uint64_t guid) {
    uint64_t local = SafeGetActive();
    if (!guid) return "unknown";
    if (guid == local) return "self";

    // Read faction template from descriptor 0xDC
    int localFaction = 0, targetFaction = 0;
    uintptr_t lp = SnapPtr(local); // snapshot-only (no ObjectPtr game call)
    if (lp && AcceptObjPtr(lp)) {
        uintptr_t ld = Mem::Read<uintptr_t>(lp + Offsets::O().Descriptor);
        if (ld && AcceptObjPtr(ld))
            localFaction = Mem::Read<int>(ld + Offsets::D().FactionTemplate);
    }
    uintptr_t tp = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (tp && AcceptObjPtr(tp)) {
        uintptr_t td = Mem::Read<uintptr_t>(tp + Offsets::O().Descriptor);
        if (td && AcceptObjPtr(td))
            targetFaction = Mem::Read<int>(td + Offsets::D().FactionTemplate);
    }

    if (localFaction == 0 || targetFaction == 0) return "unknown";

    // Same faction template → friendly/allied
    if (localFaction == targetFaction) return "friendly";

    // Different faction: check unit flags for PLAYER_CONTROLLED → PvP hostile
    uint32_t tFlags = UnitFlags(guid);
    if (tFlags & 0x01000000u) { // UNIT_FLAG_PLAYER_CONTROLLED
        // Player or player pet — different faction means hostile (PvP)
        return "hostile";
    }

    // NPC with different faction: check if attackable
    if (tFlags & 0x00000002u) return "neutral"; // NON_ATTACKABLE
    if (tFlags & 0x02000000u) return "neutral"; // NOT_SELECTABLE

    return "hostile";
}

// ---- Spell info — CRASH RULE (permanent): GetSpellInfo via nested lua_pcall
// from the bridge corrupts the Lua stack (proven). SAFE: all fields -1
// (unknown). The addon reads spell info via its own Lua (Lua→Lua, safe).
std::string SpellInfoPacked(int spellId) {
    (void)spellId;
    return "maxRange=-1|castMs=-1|powerType=-1|school=-1";
}

// ---- Runtime aura table query (zero Lua — reads g_auras directly) ----------
std::string UnitAurasPacked(uint64_t guid) {
    if (!guid) return "0";
    static ULONGLONG s_lastTime = 0;
    static uint64_t s_lastGuid = 0;
    static std::string s_lastResult;
    ULONGLONG now = GetTickCount64();
    if (s_lastGuid == guid && s_lastTime && (now - s_lastTime) < 80ull)
        return s_lastResult;

    std::lock_guard<std::mutex> lock(g_auraMu);
    // Collect matching auras from the runtime aura table
    struct AuraHit { int spellId; int stacks; ULONGLONG expMs; };
    AuraHit hits[128];
    size_t n = 0;
    for (size_t i = 0; i < g_auraN && n < 128; ++i) {
        if (g_auras[i].guid == guid && g_auras[i].spellId > 0) {
            hits[n].spellId = g_auras[i].spellId;
            hits[n].stacks  = g_auras[i].stacks;
            hits[n].expMs   = g_auras[i].expMs;
            ++n;
        }
    }
    char buf[4096];
    size_t off = 0;
    off += (size_t)snprintf(buf + off, sizeof(buf) - off, "%zu", n);
    for (size_t i = 0; i < n && off + 64 < sizeof(buf); ++i) {
        long long remMs = (long long)hits[i].expMs - (long long)now;
        if (remMs < 0) remMs = 0;
        off += (size_t)snprintf(buf + off, sizeof(buf) - off,
                                "|%d:%d:%lld", hits[i].spellId, hits[i].stacks, remMs);
    }
    s_lastGuid = guid;
    s_lastTime = now;
    s_lastResult = std::string(buf, off);
    return s_lastResult;
}

// ---- Proc / reactive event tracking (CLEU-fed) ----------------------------
struct ProcNote { char name[32]; ULONGLONG ts; };
static ProcNote g_procs[32] = {};
static size_t g_procN = 0;

void NoteProcEvent(const char* eventName) {
    if (!eventName || !eventName[0]) return;
    std::lock_guard<std::mutex> lock(g_auraMu); // reuse aura mutex
    ULONGLONG now = GetTickCount64();
    // Overwrite oldest if full
    if (g_procN >= 32) {
        for (size_t i = 1; i < 32; ++i) g_procs[i - 1] = g_procs[i];
        g_procN = 31;
    }
    ProcNote& n = g_procs[g_procN++];
    strncpy_s(n.name, eventName, 31);
    n.name[31] = '\0';
    n.ts = now;
}

int HasRecentProc(const char* eventName, int windowMs) {
    if (!eventName || !eventName[0] || windowMs <= 0) return 0;
    std::lock_guard<std::mutex> lock(g_auraMu);
    ULONGLONG now = GetTickCount64();
    for (size_t i = 0; i < g_procN; ++i) {
        if (!_stricmp(g_procs[i].name, eventName)) {
            long long elapsed = (long long)(now - g_procs[i].ts);
            if (elapsed < (long long)windowMs) {
                return (int)((long long)windowMs - elapsed);
            }
        }
    }
    return 0;
}

// ---- Combo points / DK runes (Lua pcall, cached 100ms) --------------------
int ComboPoints() {
    static int s_cached = -1;
    static ULONGLONG s_cachedAt = 0;
    ULONGLONG now = GetTickCount64();
    if (s_cachedAt && (now - s_cachedAt) < 100ull) return s_cached;
    s_cachedAt = now;
    void* L = RL::Game::Addr::LuaState();
    if (!L || !RL::Lua::Ready()) return -1;
    // Call GetComboPoints("player", "target")
    // Use the Lua wrapper pattern — one pcall
    auto rawL = (lua_State*)L;
    // Quick inline: getfield + pushstring + pcall
    typedef void(__cdecl* GF)(lua_State*,int,const char*);
    typedef void(__cdecl* PS)(lua_State*,const char*);
    typedef int(__cdecl* PC)(lua_State*,int,int,int);
    typedef int(__cdecl* GT)(lua_State*);
    typedef void(__cdecl* ST)(lua_State*,int);
    typedef double(__cdecl* TN)(lua_State*,int);
    auto gf = (GF)0x0084E670; auto ps = (PS)0x0084E350; auto pc = (PC)0x0084EC50;
    auto gt = (GT)0x0084DBD0; auto st = (ST)0x0084DBF0; auto tn = (TN)0x0084E030;
    int top = gt(rawL);
    gf(rawL, -10002, "GetComboPoints");
    ps(rawL, "player");
    ps(rawL, "target");
    int rc = pc(rawL, 2, 1, 0);
    if (rc == 0) { s_cached = (int)tn(rawL, -1); st(rawL, top); }
    else { st(rawL, top); s_cached = -1; }
    return s_cached;
}

int RuneCooldownMs(int runeIndex) {
    if (runeIndex < 1 || runeIndex > 6) return -1;
    static int s_cached[6] = {-1,-1,-1,-1,-1,-1};
    static ULONGLONG s_cachedAt = 0;
    ULONGLONG now = GetTickCount64();
    if (s_cachedAt && (now - s_cachedAt) < 100ull) return s_cached[runeIndex-1];
    s_cachedAt = now;
    void* L = RL::Game::Addr::LuaState();
    if (!L || !RL::Lua::Ready()) return -1;
    auto rawL = (lua_State*)L;
    typedef void(__cdecl* GF)(lua_State*,int,const char*);
    typedef void(__cdecl* PN)(lua_State*,double);
    typedef int(__cdecl* PC)(lua_State*,int,int,int);
    typedef int(__cdecl* GT)(lua_State*);
    typedef void(__cdecl* ST)(lua_State*,int);
    typedef double(__cdecl* TN)(lua_State*,int);
    auto gf = (GF)0x0084E670; auto pn = (PN)0x0084E2A0; auto pc = (PC)0x0084EC50;
    auto gt = (GT)0x0084DBD0; auto st = (ST)0x0084DBF0; auto tn = (TN)0x0084E030;
    int top = gt(rawL);
    // GetRuneCooldown(slot) → start, duration, isReady
    for (int i = 1; i <= 6; ++i) {
        gf(rawL, -10002, "GetRuneCooldown");
        pn(rawL, (double)i);
        int rc = pc(rawL, 1, 3, 0);
        if (rc == 0) {
            double start = tn(rawL, -3), dur = tn(rawL, -2), ready = tn(rawL, -1);
            if (ready != 0.0) s_cached[i-1] = 0;
            else { double rem = (start + dur) - RL::Game::GameTime::Now(); s_cached[i-1] = (int)(rem > 0 ? rem * 1000.0 : 0); }
            st(rawL, top);
        } else { st(rawL, top); s_cached[i-1] = -1; }
    }
    return s_cached[runeIndex-1];
}
//
// A gameobject's dynamic flags live at GAMEOBJECT_DYNAMIC (0x38), not at
// UNIT_DYNAMIC_FLAGS (0x13C) - see the derivation in Offsets.h. Using the unit
// offset for both read past the end of every gameobject descriptor, which is why
// the sparkle witness could never be trusted.
//
// GAMEOBJECT_DYNAMIC is PACKED: the low word holds the flags (hence the
// GO_DYNFLAG_LO_ naming), the high word holds path progress / despawn timer. So
// mask it - otherwise a timer bit lands on top of SPARKLE and every object in
// the world looks interactable.
uint32_t DynamicFlags(uint64_t guid) {
    if (const Object* o = SnapByGuid(guid)) return o->dynamicFlags;
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d) return 0;
    if (Type(guid) == ObjectType::GameObject)
        return Mem::Read<uint32_t>(d + Offsets::D().GoDynamic) & 0xFFFF;
    return Mem::Read<uint32_t>(d + Offsets::D().DynamicFlags);
}

// GAMEOBJECT_BYTES_1, raw. Callers extract the byte they want rather than this
// deciding for them: the addon's own GameObjectTypes enum is 1-based where 3.3.5a
// numbers DOOR=0, so any naming here would just bake in a transcription we have
// not verified. Return the dword and let the diagnostic show it.
uint32_t GameObjectBytes1(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    if (Type(guid) != ObjectType::GameObject) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<uint32_t>(d + Offsets::D().GoBytes1) : 0;
}

// Object flags, likewise per type. GAMEOBJECT_FLAGS is a separate field from
// UNIT_FIELD_FLAGS and the addon reads it through its own GameObjectFlags enum.
uint32_t ObjectFlags(uint64_t guid) {
    if (const Object* o = SnapByGuid(guid)) return o->unitFlags;
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d) return 0;
    if (Type(guid) == ObjectType::GameObject)
        return Mem::Read<uint32_t>(d + Offsets::D().GoFlags);
    return Mem::Read<uint32_t>(d + Offsets::D().Flags);
}

// Generic descriptor field read, so offsets can be MEASURED from Lua instead of
// hardcoded on faith. Bounded: a descriptor block is a few KB, and anything past
// that is a bad offset rather than a field we forgot. 4-byte aligned because
// every update-field is a dword at index*4 - an unaligned request is a caller
// bug, not a field.
//
// Safe by construction: Mem::Read is range-checked and SEH-wrapped, so a wrong
// offset returns 0 instead of taking the client down. That is what makes an
// empirical sweep for UNIT_NPC_FLAGS an acceptable thing to do at all.
uint32_t Field(uint64_t guid, uint32_t byteOffset) {
    if (byteOffset & 0x3) return 0;          // must be dword aligned
    if (byteOffset > 0x1000) return 0;        // past any plausible descriptor
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<uint32_t>(d + byteOffset) : 0;
}

// UNIT_NPC_FLAGS descriptor field. Measured candidates; pin on first QUESTGIVER.
// This is capability ("can give quests"), NOT dialog status (!/?).
static uint32_t g_npcFlagsOff = 0x10C;
static bool g_npcFlagsPinned = false;

uint32_t NpcFlags(uint64_t guid) {
    static const uint32_t kCand[] = { 0x10C, 0x110, 0xF4, 0xF0, 0x108, 0x114, 0x128, 0x130 };
    if (g_npcFlagsPinned) return Field(guid, g_npcFlagsOff);
    uint32_t best = Field(guid, g_npcFlagsOff);
    if (best & 0x2u) {
        g_npcFlagsPinned = true;
        return best;
    }
    for (uint32_t off : kCand) {
        uint32_t v = Field(guid, off);
        if (v & 0x2u) {
            g_npcFlagsOff = off;
            g_npcFlagsPinned = true;
            return v;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// ObjectQuestGiverStatus - REAL client field + REAL status query.
//
// RE (Ascension.exe live disasm 2026-07-28):
//
//   CGPlayer_C::OnQuestGiverStatus   @ 0x006D11C0
//     SMSG_QUESTGIVER_STATUS (guid + status byte)
//     ObjectPtr @ 0x004D4DB0 -> SetQuestGiverStatus @ 0x00744400
//
//   CGObject_C::SetQuestGiverStatus  @ 0x00744400
//     mov dword ptr [ecx+0x90], edx     ; DialogStatus cache
//     ret 4  (thiscall, status on stack)
//
//   CGUnit_C::GetQuestInteractType   @ 0x00744640
//     mov eax, [ecx+0x90]; cmp eax, 0x0A
//     jump-table maps status -> interact cursor type
//
//   Query send (CMSG_QUESTGIVER_STATUS_QUERY = 0x18A) @ 0x006D4D40
//     __stdcall void(uint64_t* guid, uint32_t extra)  ; ret 8 (c2 08 00)
//     PutInt32(0x18A) @ 0x47B0A0, PutGuid @ 0x47B100, PutInt32(extra),
//     Send @ 0x006B0B50
//
// DialogStatus (3.3.5 client / Trinity):
//   0 none, 1 unavailable, 2 low-level !, 3 low-level ?, 4 low-level ! rep,
//   5 incomplete (grey ?), 6 reward rep, 7 available rep, 8 available (!),
//   9 reward2, 10 reward (?)
// Yellow ! = 7/8 (and 2/4 grey). Yellow ? = 9/10 (and 3/6 grey).
//
// 1.8.10 bug: every OM object was queried (items/corpses/players). Cap filled
// with junk; real givers starved. Also raw dword at +0x90 was clamped with
// `>10 => 0`, which zeroed any dirty upper bytes even when the status byte
// itself was valid. Fix: filter to Unit/GO in range, mask low byte, log diag.
// ---------------------------------------------------------------------------
static constexpr uint32_t kQuestGiverStatusMax = 10;
// RE-verified 2026-07-29 against live Ascension.exe (.text):
//   SetQuestGiverStatus  @ 0x00744400  mov [ecx+0x90], edx ; ret 4
//   GetQuestInteractType @ 0x00744640  mov eax,[ecx+0x90] ; jump table
//   CMSG query           @ 0x006D4D40  stdcall(guid*, extra) ret 8
//   OnQuestGiverStatus   @ 0x006D11C0  calls SetQG (only 2 xrefs in binary)
static constexpr uintptr_t kQueryQuestGiverStatus = 0x006D4D40;
static constexpr uintptr_t kGetQuestInteractType = 0x00744640;
// First contact needs a fast re-query; 5s starved the fill window after SMSG.
static constexpr ULONGLONG kQgQueryCooldownMs = 1500;
static constexpr float kQgQueryMaxDist = 100.f;

// guid -> last query tick. Cap size so a long session cannot grow unbounded.
static constexpr size_t kQgQueryCap = 128;
struct QgQueryEnt { uint64_t guid; ULONGLONG t; };
static QgQueryEnt g_qgQueries[kQgQueryCap];
static size_t g_qgQueryN = 0;
static int g_qgQueryTotal = 0;
static int g_qgQueryFail = 0;
static int g_qgNonzero = 0;
static int g_qgReadTotal = 0;
static int g_qgLogLeft = 48;
// Auto-pin DialogStatus instance offset if +0x90 is empty but another nearby
// dword holds a plausible 1..10 enum (Ascension private forks have moved fields).
static uintptr_t g_qgStatusOff = 0x90;
static bool g_qgStatusPinned = false;
static int g_qgScanHits = 0;

static uint32_t ReadDialogStatus(uintptr_t p) {
    // Status is a small enum written as a dword from a movzx byte. Always take
    // the low byte - upper garbage must not collapse a real 8/10 to 0.
    if (!p) return 0;
    uint32_t raw = Mem::Read<uint32_t>(p + g_qgStatusOff);
    uint32_t st = raw & 0xFFu;
    if (st > kQuestGiverStatusMax) return 0;
    return st;
}

// When +0x90 is empty, scan a tight window of instance dwords for a 1..10 value
// that co-occurs with UNIT_NPC_FLAG_QUESTGIVER. Pin the first stable hit so a
// moved field still feeds the quest engine without inventing status codes.
static uint32_t ScanDialogStatus(uintptr_t p, uint32_t npcf) {
    if (!p) return 0;
    if (g_qgStatusPinned) return ReadDialogStatus(p);
    // Only scan real quest-capable units - random 1..10 in other fields is noise.
    if ((npcf & 0x2u) == 0) return 0;
    static const uintptr_t kOffs[] = {
        0x90, 0x8C, 0x94, 0x88, 0x98, 0x9C, 0xA0, 0x84, 0x80, 0xA4, 0xA8, 0xAC,
        0xB0, 0x78, 0x7C, 0xB4, 0xB8, 0xBC, 0xC0,
    };
    for (uintptr_t off : kOffs) {
        uint32_t raw = Mem::Read<uint32_t>(p + off);
        uint32_t st = raw & 0xFFu;
        // Require clean upper bytes: real status is a small enum dword.
        if ((raw & ~0xFFu) != 0) continue;
        if (st >= 1 && st <= kQuestGiverStatusMax) {
            g_qgStatusOff = off;
            g_qgStatusPinned = true;
            g_qgScanHits++;
            RL::Log::Warn("QG status offset pinned +0x%X st=%u (was +0x90 empty)",
                          (unsigned)off, st);
            return st;
        }
    }
    return 0;
}

static int CallGetQuestInteractType(uintptr_t p) {
    if (!p) return -1;
    using fn = int(__thiscall*)(void*, int);
    auto f = reinterpret_cast<fn>(kGetQuestInteractType);
    int r = -1;
    __try {
        r = f(reinterpret_cast<void*>(p), 0);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        r = -1;
    }
    return r;
}

static void QueryQuestGiverStatus(uint64_t guid) {
    if (!guid) return;
    // __stdcall void(uint64_t* guid, uint32_t extra) - ret 8 (disasm c2 08 00)
    using fnQuery = void(__stdcall*)(uint64_t*, uint32_t);
    auto f = reinterpret_cast<fnQuery>(kQueryQuestGiverStatus);
    if (!f) return;
    uint64_t g = guid;
    __try {
        f(&g, 0);
        g_qgQueryTotal++;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        g_qgQueryFail++;
    }
}

// Only Unit (3) / GameObject (5). Prefer near the player, but NEVER refuse a
// query solely because PositionFromPtr failed for the NPC - after the 1.8.22
// pos-layout harden, many unit positions briefly read as empty and that made
// every status query ineligible -> +0x90 stayed 0 forever -> DEAD contract with
// 14k all-zero reads while yellow !/? stood on screen.
static bool QgEligibleForQuery(uint64_t guid, uintptr_t p) {
    if (!p || !guid) return false;
    // Type id on CGObject+0x14: 3=Unit, 5=GameObject. Mask form uses bitfield.
    // Players (id 4 / TYPEMASK_PLAYER 0x10) are never status-queried.
    uint32_t raw = Mem::Read<uint32_t>(p + Offsets::O().Type);
    bool ok = false;
    if (raw <= 7) {
        ok = (raw == 3 || raw == 5);
    } else {
        if (raw & 0x10u) ok = false;                         // player mask
        else if ((raw & 0x08u) || (raw & 0x20u)) ok = true;  // unit or GO
    }
    if (!ok) return false;
    // Prefer LocalPtr + local-gated player pos (camera fallback).
    uintptr_t lp = LocalPtr();
    Vec3 pp = lp ? PositionLocalFromPtr(lp) : Vec3{};
    if (std::fabs(pp.x) < 30.f || std::fabs(pp.y) < 30.f) {
        // No usable player pos: still query (unit is in the client's object
        // list, so it is relevant enough).
        return true;
    }
    Vec3 op = PositionFromPtr(p);
    if (std::fabs(op.x) < 30.f || std::fabs(op.y) < 30.f) {
        // NPC pos unreadable: ALLOW the query. Blocking here is what starved
        // SMSG_QUESTGIVER_STATUS and left every DialogStatus at 0.
        return true;
    }
    float dx = pp.x - op.x, dy = pp.y - op.y, dz = pp.z - op.z;
    float d2 = dx * dx + dy * dy + dz * dz;
    return d2 <= (kQgQueryMaxDist * kQgQueryMaxDist);
}

static void MaybeQueryQuestGiverStatus(uint64_t guid, uintptr_t p) {
    if (!QgEligibleForQuery(guid, p)) return;
    ULONGLONG now = GetTickCount64();
    for (size_t i = 0; i < g_qgQueryN; ++i) {
        if (g_qgQueries[i].guid == guid) {
            if (now - g_qgQueries[i].t < kQgQueryCooldownMs) return;
            g_qgQueries[i].t = now;
            QueryQuestGiverStatus(guid);
            return;
        }
    }
    if (g_qgQueryN < kQgQueryCap) {
        g_qgQueries[g_qgQueryN++] = { guid, now };
    } else {
        // Ring: overwrite oldest by sliding (slot 0) - bounded, simple.
        g_qgQueries[0] = { guid, now };
    }
    QueryQuestGiverStatus(guid);
}

static uintptr_t ResolveObjPtr(uint64_t guid) {
    if (!guid) return 0;
    // SNAPSHOT-FIRST (2026-08-02): the live ObjectPtr game call is the crash
    // vector (Guard-longjmp inside the Lua VM). The snapshot's cached pointer
    // is pure memory and is refreshed at 10Hz by every OM handler.
    if (const Object* o = SnapByGuid(guid)) {
        if (o->ptr && Mem::Committed(o->ptr)) return o->ptr;
    }
    // Rare cold miss: last-resort VEH-guarded live lookup (never the hot path).
    if (uintptr_t p = Ptr(guid)) return p;
    return 0;
}

int QuestGiverStatus(uint64_t guid) {
    if (!guid) {
        static int s_noguid = 0;
        if (s_noguid < 8) {
            RL::Log::Warn("QG err=no_guid (Lua GuidArg failed / empty)");
            s_noguid++;
        }
        return 0;
    }
    // Multi-slot micro-cache: same NPCs scanned many times per suite tick and
    // across Director/OM/goals. MORE status answers per second, ~1 read per
    // GUID per TTL window instead of N. 128 slots cover a full town snapshot.
    static constexpr size_t kQgCacheN = 128;
    static constexpr ULONGLONG kQgCacheTtlMs = 120;
    struct QgC { uint64_t g; int st; ULONGLONG t; };
    static QgC s_qgC[kQgCacheN] = {};
    ULONGLONG now = GetTickCount64();
    size_t slot = (size_t)(guid ^ (guid >> 17)) & (kQgCacheN - 1);
    if (s_qgC[slot].g == guid && (now - s_qgC[slot].t) < kQgCacheTtlMs) {
        return s_qgC[slot].st;
    }
    uintptr_t p = ResolveObjPtr(guid);
    if (!p) {
        static int s_noptr = 0;
        if (s_noptr < 12) {
            RL::Log::Warn("QG err=no_ptr guid=%llX (ObjectPtr miss)",
                          (unsigned long long)guid);
            s_noptr++;
        }
        return 0;
    }
    g_qgReadTotal++;
    int st = (int)ReadDialogStatus(p);
    if (st == 0) {
        // Field empty: ask the server the same way the client does. Response
        // lands async in OnQuestGiverStatus and fills +0x90.
        MaybeQueryQuestGiverStatus(guid, p);
        st = (int)ReadDialogStatus(p);
    }
    if (st == 0) {
        // RE confirmed SetQG writes +0x90 on this binary, but Ascension private
        // forks have moved instance fields before. Scan once on QUESTGIVER units.
        uint32_t npcf = NpcFlags(guid);
        st = (int)ScanDialogStatus(p, npcf);
    }
    // Live calibration: GetQuestInteractType returned 23 with st=8 and 25 with
    // st=10. If the raw field is empty but the interact table still answers,
    // recover the DialogStatus so the suite is not blind.
    if (st == 0) {
        int interact = CallGetQuestInteractType(p);
        if (interact == 23 || interact == 24) st = 8;
        else if (interact == 25 || interact == 26) st = 10;
    }
    if (st != 0) g_qgNonzero++;
    s_qgC[slot] = { guid, st, now };
    // Logging: first N only. Cheap Info, no secondary field re-reads.
    if (g_qgLogLeft > 0 && st != 0) {
        RL::Log::Info(
            "QG guid=%llX st=%u reads=%d nz=%d pin=%d",
            (unsigned long long)guid, st, g_qgReadTotal, g_qgNonzero,
            g_qgStatusPinned ? 1 : 0);
        g_qgLogLeft--;
    }
    return static_cast<int>(st);
}

uint32_t InstanceField(uint64_t guid, uint32_t byteOffset) {
    // CGObject instance field (NOT descriptor). DialogStatus lives here at +0x90.
    if (byteOffset & 0x3) return 0;
    if (byteOffset > 0x2000) return 0;
    uintptr_t p = ResolveObjPtr(guid);
    if (!p) return 0;
    return Mem::Read<uint32_t>(p + byteOffset);
}

std::string QuestGiverDiag(uint64_t guid) {
    char buf[384];
    if (!guid) {
        snprintf(buf, sizeof(buf), "err=no_guid|qtot=%d|qfail=%d|nz=%d|reads=%d",
                 g_qgQueryTotal, g_qgQueryFail, g_qgNonzero, g_qgReadTotal);
        return buf;
    }
    uintptr_t p = ResolveObjPtr(guid);
    if (!p) {
        snprintf(buf, sizeof(buf),
                 "err=no_ptr|guid=%llX|qtot=%d|qfail=%d|nz=%d|reads=%d",
                 (unsigned long long)guid, g_qgQueryTotal, g_qgQueryFail,
                 g_qgNonzero, g_qgReadTotal);
        return buf;
    }
    uint32_t raw90 = Mem::Read<uint32_t>(p + 0x90);
    uint32_t raw8c = Mem::Read<uint32_t>(p + 0x8C);
    uint32_t raw94 = Mem::Read<uint32_t>(p + 0x94);
    uint32_t rawOff = Mem::Read<uint32_t>(p + g_qgStatusOff);
    uint32_t st = ReadDialogStatus(p);
    int interact = CallGetQuestInteractType(p);
    int typ = Mem::Read<int>(p + Offsets::O().Type);
    int entry = Entry(guid);
    uint32_t npcf = NpcFlags(guid);
    // Force one query so +1.5s re-probe can see a fill.
    if (st == 0) {
        MaybeQueryQuestGiverStatus(guid, p);
        st = ReadDialogStatus(p);
        if (st == 0) st = ScanDialogStatus(p, npcf);
    }
    // Dump a short instance window so a live giverprobe can show where status
    // actually lives when +0x90 is empty.
    uint32_t w80 = Mem::Read<uint32_t>(p + 0x80);
    uint32_t w84 = Mem::Read<uint32_t>(p + 0x84);
    uint32_t w88 = Mem::Read<uint32_t>(p + 0x88);
    uint32_t w9c = Mem::Read<uint32_t>(p + 0x9C);
    uint32_t wa0 = Mem::Read<uint32_t>(p + 0xA0);
    snprintf(buf, sizeof(buf),
             "ptr=%08X|off=%X|rawOff=%08X|raw8c=%08X|raw90=%08X|raw94=%08X|"
             "w80=%08X|w84=%08X|w88=%08X|w9c=%08X|wa0=%08X|"
             "st=%u|interact=%d|npcf=%u|type=%d|entry=%d|"
             "qtot=%d|qfail=%d|nz=%d|reads=%d|pin=%d|scans=%d|guid=%llX",
             (unsigned)p, (unsigned)g_qgStatusOff, rawOff, raw8c, raw90, raw94,
             w80, w84, w88, w9c, wa0, st, interact, npcf, typ, entry,
             g_qgQueryTotal, g_qgQueryFail, g_qgNonzero, g_qgReadTotal,
             g_qgStatusPinned ? 1 : 0, g_qgScanHits, (unsigned long long)guid);
    return buf;
}

float Scale(uint64_t guid) {
    uintptr_t p = SnapPtr(guid); // snapshot-only (no ObjectPtr game call)
    if (!p) return 1.f;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    float s = d ? Mem::Read<float>(d + Offsets::D().Scale) : 1.f;
    return s > 0.f ? s : 1.f;
}

bool Exists(uint64_t guid) { return SnapByGuid(guid) != nullptr; }

float Distance(uint64_t a, uint64_t b) { return Position(a).Dist(Position(b)); }
float DistancePos(const Vec3& a, const Vec3& b) { return a.Dist(b); }

int IsFacing(uint64_t a, uint64_t b, float arcRadians) {
    if (arcRadians <= 0.f) arcRadians = kDefaultCastFaceArc;
    Vec3 pa = Position(a), pb = Position(b);
    // 2026-08-02 (19:05 FAIL-OPEN FIX — the "aura search did not cast at all"
    // root cause): an UNMEASURED position (0,0) is NOT a confident "not
    // facing" — it is UNDETERMINED. Returning false here made the addon treat
    // every cast to a not-yet-placed unit as a confirmed not-facing and block
    // it forever ("wait facing:X" freeze + aura search dead). Return -1 so
    // the bridge pushes nil and the rotation ALLOWS the cast (client is the
    // final authority; a wrong cast is one phantom, a false freeze is forever).
    if ((pa.x == 0.f && pa.y == 0.f) || (pb.x == 0.f && pb.y == 0.f))
        return -1;
    // 2026-08-02 (18:16): with the angle-convention fix in IsFacingPos, the
    // measurement is correct at ALL distances INCLUDING point-blank — a mob
    // the player faces at 0.5yd is measured facing, a mob behind is measured
    // not-facing (the old <1yd hard-true band-aid here caused FALSE-fACING and
    // was masking the convention bug). Only a truly-degenerate heading (target
    // at EXACTLY the viewer's position, dx²+dy² < 0.01 yd²) is undefined —
    // treat that as facing (a target you are standing on cannot be "behind").
    float dx = pb.x - pa.x, dy = pb.y - pa.y;
    if ((dx * dx + dy * dy) < 0.01f) return 1;
    float face = Facing(a);
    if (!LooksLikeFacingEarly(face)) return -1;
    return IsFacingPos(face, pa.x, pa.y, pb.x, pb.y, arcRadians) ? 1 : 0;
}

bool IsBehind(uint64_t a, uint64_t b) {
    Vec3 pa = Position(a), pb = Position(b);
    // Same WoW-convention conversion as IsFacingPos (0 = +Y/north, CW).
    float ang = 1.5707963f - std::atan2(pa.y - pb.y, pa.x - pb.x);
    float face = Facing(b);
    float diff = std::fmod(ang - face + 3.14159265f, 6.2831853f);
    if (diff < 0.f) diff += 6.2831853f;
    diff -= 3.14159265f;
    return std::fabs(diff) > 1.5707963f;
}

// CLICK-TO-MOVE IS REMOVED, NOT JUST REFUSED AT THE BRIDGE.
//
// This called SafeCTM (CTM action 4, "walk to position") - click-to-move
// movement, which is forbidden project-wide: navigation is keyboard steering
// only. Dispatch.cpp refuses the command by NAME, but a name check does not
// remove a capability, and the C++ was one internal caller away from steering
// the character. The symbol is kept so the header/ABI is unchanged; the
// forbidden behaviour is gone.
void MoveTo(const Vec3&) {
    RL::Log::Warn("MoveTo refused: click-to-move is forbidden (use Navigator)");
}

void FaceDirection(float radians) {
    uintptr_t p = LocalPtr();
    if (!p) return;
    Mem::Write<float>(p + Offsets::O().Facing, radians);
}

void ClickPosition(const Vec3& pos) { MoveTo(pos); }

bool CastSpell(int spellId, uint64_t targetGuid) {
    uintptr_t player = LocalPtr();
    if (!player) {
        RL::Log::Error("CastSpell: no local player ptr");
        return false;
    }
    int rc = SafeCastSpell(player, spellId, targetGuid);
    if (rc < 0) {
        RL::Log::Error("CastSpell exception spell=%d guid=0x%llX", spellId,
                       (unsigned long long)targetGuid);
        return false;
    }
    if (rc == 0) {
        RL::Log::Error("CastSpell unavailable spell=%d", spellId);
        return false;
    }
    // Quiet success - rotation may fire often
    return true;
}

Vec3 CameraPosition() {
    uintptr_t cam = SafeCamera();
    if (!cam || !Mem::Readable(cam)) return {};
    return Mem::Read<Vec3>(cam + 0x08);
}

// Tri-state world raycast: 1 = clear, 0 = blocked, -1 = could not tell.
//
// The bool version folded "the intersect call raised an exception" into the same
// answer as "solid geometry is in the way", and returned before writing the hit
// point - so a failed raycast reported a WALL at garbage coordinates. Every
// consumer then treated a sensor failure as an obstacle: the navigator detours
// around nothing, and (worse) the same folding meant a genuine wall and a broken
// probe were indistinguishable while debugging a bot that kept hitting walls.
//
// This is the same defect family as the quest-giver stub answering 0: a value
// that is in-range and confident but means "no answer".
int TraceLineEx(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags) {
    Vec3 s = start, e = end, h{};
    float dist = 1.f;
    int rc = SafeIntersect(&s, &e, &h, &dist, flags);
    if (rc < 0) return -1;               // threw: we know nothing
    if (hit) *hit = h;
    return rc == 0 ? 1 : 0;              // 1 clear, 0 blocked
}

// Kept for existing callers that only need a boolean. Note the asymmetry: an
// unknown result answers "not clear", which is the SAFE direction for a
// line-of-sight question (do not claim a clear shot we could not verify) but the
// WRONG direction for an obstacle question. Obstacle callers must use
// TraceLineEx and handle -1 themselves.
bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags) {
    return TraceLineEx(start, end, hit, flags) == 1;
}

bool WorldToScreen(const Vec3& world, float* sx, float* sy) {
    Vec3 player = Position(LocalGuid());
    float dx = world.x - player.x;
    float dy = world.y - player.y;
    if (sx) *sx = 0.5f + dx * 0.001f;
    if (sy) *sy = 0.5f - dy * 0.001f;
    return true;
}

// Raw camera fields. GetCamera() = [[0xB7436C]+0x7E20]; struct: +0x08 position,
// +0x14 the 3x3 view matrix (rows), +0x40 FOV. POD-only so the SEH guard is safe.
CamData CameraData() {
    CamData c{};
    c.ok = false;
    uintptr_t cam = SafeCamera();
    if (!cam || !Mem::Readable(cam + 0x44)) return c;
    {
        c.pos   = Vec3{ Mem::Read<float>(cam + 0x08),
                        Mem::Read<float>(cam + 0x0C),
                        Mem::Read<float>(cam + 0x10) };
        c.fwd   = Vec3{ Mem::Read<float>(cam + 0x14),
                        Mem::Read<float>(cam + 0x18),
                        Mem::Read<float>(cam + 0x1C) };
        c.right = Vec3{ Mem::Read<float>(cam + 0x20),
                        Mem::Read<float>(cam + 0x24),
                        Mem::Read<float>(cam + 0x28) };
        c.up    = Vec3{ Mem::Read<float>(cam + 0x2C),
                        Mem::Read<float>(cam + 0x30),
                        Mem::Read<float>(cam + 0x34) };
        c.fov   = Mem::Read<float>(cam + 0x40);
        c.ok = true;
    }
    return c;
}

void ResetAfk() {
    SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
}

bool GetKeyState(int vkey) {
    return (::GetAsyncKeyState(vkey) & 0x8000) != 0;
}

} // namespace RL::Game::OM
