#pragma once
#include "Types.h"
#include <cstdint>
#include <vector>
#include <string>

namespace RL::Game::OM {

struct Object {
    uint64_t guid = 0;
    uintptr_t ptr = 0;
    ObjectType type = ObjectType::None;
    int entry = 0;
    Vec3 pos{};
    float facing = 0.f;
    int health = 0;
    int maxHealth = 0;
    int level = 0;
    uint32_t unitFlags = 0;
    uint32_t dynamicFlags = 0;
    int faction = 0;          // UNIT_FIELD_FACTIONTEMPLATE
    uint64_t unitTarget = 0;  // UNIT_FIELD_TARGET (who they are attacking)
    float scale = 1.f;
    uint32_t goBytes1 = 0;    // GAMEOBJECT_BYTES_1 (state/type/artKit/animProgress)
    uint32_t npcFlags = 0;    // UNIT_FIELD_NPC_FLAGS (quest giver / vendor / trainer)
    int creatureType = -1;    // CREATURE_TYPE_* (8 = CRITTER); -1 unknown / non-unit
    std::string name; // optional, expensive
};

// Thread-safe snapshot with TTL cache
void Invalidate();
// /reload: freeze walks and reset settle/warm so we do not enum during FrameXML.
void OnLuaReload();
// om.enable config AND post-rebind hard freeze cleared (SoftRefresh/enum gate).
bool IsEnabled();
void Refresh(bool force = false);
// ---- Lua-context gate (2026-08-01, 0x512B07 crash fix) ---------------------
// PERMANENT RULE (documented in ObjectManager.cpp): object enumeration
// (Refresh/SoftRefresh -> BuildUnitSnapshotLocked -> EnumVisibleObjects) must
// NEVER run inside the game's Lua VM call chain. It WRITES to every visible
// object mid-walk and, under the deep Lua_IsLinuxClient -> Dispatch -> OM
// stack, the VM's stack/TValues get corrupted -> later "Lua calls 0x512B00
// with garbage" crash. The bridge therefore calls SetInLuaContext(true) around
// every RuntimeCall; enumeration is deferred when the flag is set and the
// cached snapshot is served instead. SetInLuaContext(false) after the call.
void SetInLuaContext(bool inLua);
bool InLuaContext();
// True after EnumVisibleObjects AVed once this inject — enumvis stays off;
// linked-list walk continues (list-only mode). Full OM is NOT killed.
bool EnumIsDead();
// Packed status for /raijin om and diagnostics:
// "mode=full|list-only|cold|no-player|total=N|units=N|players=N|gos=N"
std::string StatusPacked();
// Dump type histogram + one sample per type to runtime.log.
void LogTypeSamples(size_t n = 8);
// Packed "count|guid:entry:x:y:z:dist;..." of Unit objects within maxRange.
std::string NearbyUnitsPacked(float maxRange = 100.f, size_t maxN = 16);
// Rotation hostiles (runtime-first, no nameplates / UnitCanAttack):
// "n|0xGUID:entry:x:y:z:center:edge:flags:hp:mhp|..."
// Snapshot fields only after Refresh — zero per-unit ObjectPtr from Lua.
// NEVER requires om.enable (soft list-only when frozen).
std::string NearbyHostilesPacked(float maxRange = 40.f, size_t maxN = 32);

// Runtime aura table (CLEU/cast notes). Multi-dot MUST NOT use UnitDebuff tokens.
void NoteUnitAura(uint64_t guid, int spellId, int stacks, float durationSec);
void ClearUnitAura(uint64_t guid, int spellId);
bool HasUnitAura(uint64_t guid, int spellId, int* outStacks = nullptr);

// Runtime-first multi-dot discovery (no mouseover / UnitExists / UnitCanAttack):
// living attackable units in range matching aura missing (wantMissing) or present.
// "n|0xGUID:entry:center:edge:face:hp:mhp|..." sorted face then dist.
std::string AuraSearchPacked(float maxRange, int spellId, bool wantMissing, size_t maxN = 8);

// WHOLE-OM SNAPSHOT (2026-08-02): one call returns the entire cached object
// list packed as ONE string. This is the shared-memory / zero-copy pattern —
// the runtime IS the OM authority; the addon's Lua OM parses this instead of
// making ~5 bridge calls per object per tick (each an ObjectPtr game call =
// the lag + Guard-recovery crash vector). Pack format per object:
//   "0xGUID:TYPE:ENTRY:FLAGS:DYNFLAGS:LVL:HP:MHP:X:Y:Z:FACE:FACTION:0xTARGET:SCALE:GOBYTES1:NPCFLAGS"
// TYPE is the same bitmask ObjectTypeFlags returns (Object=1, Unit=32, ...).
std::string OmSnapshotPacked();

size_t Count();
size_t Count(ObjectType type);
const Object* At(size_t index1based);
const Object* AtType(ObjectType type, size_t index1based);
const Object* ByGuid(uint64_t guid);
const std::vector<Object>& All();

uint64_t LocalGuid();
uintptr_t LocalPtr();
bool InWorld();

// Field accessors (work without full snapshot)
uintptr_t Ptr(uint64_t guid);
ObjectType Type(uint64_t guid);
Vec3 Position(uint64_t guid);
// Position from a raw CGObject* (no GUID round-trip). Multi-offset + movement scan.
Vec3 PositionFromPtr(uintptr_t ptr);
// Local-player pointer path: camera agreement + camera fallback (never freezes nav).
Vec3 PositionLocalFromPtr(uintptr_t ptr);
// Pack cached position-layout discovery into buf (for PosProbe).
void PosLayoutDiag(char* buf, size_t bufN);
float Facing(uint64_t guid);
// Live local-player facing via the client's exact resolution path (camera →
// GUID → ObjectPtr → +0x7AC). 1e9 on fail. This is the RE-correct source —
// LocalPtr()+0x7AC returns 0 on this build while the client's own GetPlayerFacing
// returns a real value (verified live 2026-08-02).
float FacingLiveLocal();
// Native frame-hook refresh of the live-facing cache (main thread, no Lua on
// stack). The Lua reader prefers this cache; no game call from the VM.
void RefreshLiveFacingCache();
// Combat reach / bounding radius in yards (0 if unreadable).
// Multi-path: unit field 0x7D4/0x7D0 + descriptor UNIT_FIELD_* (0x10C/0x108).
float CombatReach(uint64_t guid);
float BoundingRadius(uint64_t guid);
float CombatReachFromPtr(uintptr_t ptr);
float BoundingRadiusFromPtr(uintptr_t ptr);
int Entry(uint64_t guid);
int Health(uint64_t guid);
int MaxHealth(uint64_t guid);
int Level(uint64_t guid);
// Unit power: current and max for a given power type (0=mana,1=rage,3=energy,6=runic).
// Returns -1 if the unit or descriptor is unreadable.
int UnitPower(uint64_t guid, int powerType);
int UnitMaxPower(uint64_t guid, int powerType);
// Power type from descriptor Bytes0 field (byte 3). Returns -1 if unreadable.
int UnitPowerType(uint64_t guid);
// Returns 1 if UNIT_FIELD_FLAGS has IN_COMBAT (0x80000), 0 if not, -1 unreadable.
int UnitCombatState(uint64_t guid);
// Creature type from descriptor. Returns -1 if unreadable.
int UnitCreatureType(uint64_t guid);
// Player casting state: returns spellId (0 if not casting), cast total ms, elapsed ms.
// Returns {-1,0,0} if unreadable. CastTotalMs = 0 means no cast in progress.
void PlayerCastState(int* outSpellId, int* outTotalMs, int* outElapsedMs);
// Mounted check: reads MountDisplayId descriptor field (0x114). Non-zero = mounted.
int IsUnitMounted(uint64_t guid);
// Movement-impairing flags from UNIT_FIELD_FLAGS: stunned/disarmed/fleeing/confused.
// Returns 0 if none, or a bitmask of impairment flags. -1 if unreadable.
int UnitMovementImpairing(uint64_t guid);
// Packed player state string: "combat=X|mounted=X|dead=X|ghost=X|stealth=X|caster=X"
// Uses descriptor reads + Lua UnitAura pcall for stealth. X is 0/1/-1 (unknown).
std::string PlayerStatePacked();
// Unit's current target GUID from UNIT_FIELD_TARGET descriptor (verified 0x48).
// Returns 0 if unreadable or no target.
uint64_t UnitTargetGuid(uint64_t guid);
// Current shapeshift form (0=normal, 1=bear, 2=aquatic, 3=cat, 4=travel, 5=moonkin, 6=flight).
// Returns -1 if unreadable. Cached ~200ms via Lua GetShapeshiftForm() pcall.
int ShapeshiftForm();
// Unit relationship relative to local player: "self","friendly","hostile","neutral","unknown"
// Uses faction template (descriptor 0xDC) + unit flags + PvP status.
const char* UnitRelationship(uint64_t guid);
// Packed spell info string: "maxRange=F|castMs=N|powerType=N|school=N" from cached DB + Lua
std::string SpellInfoPacked(int spellId);
// Packed aura string: "n|spellId:stacks:durationMs:isDebuff|..."
// Reads all auras (buff+debuff) from client via batched Lua UnitBuff/UnitDebuff pcall.
// Cached per guid for 80ms. Returns empty "0" if no auras or unreadable.
std::string UnitAurasPacked(uint64_t guid);
// Proc / reactive event tracking (CLEU-fed). Record combat events for reactive conditions.
void NoteProcEvent(const char* eventName);
// Check if proc event occurred within windowMs. Returns remaining ms or 0.
int HasRecentProc(const char* eventName, int windowMs);
// Combo points on current target (player descriptor). Returns 0-5 or -1.
int ComboPoints();
// DK rune cooldown remaining (0-5, returns ms or -1 if unreadable/not DK).
int RuneCooldownMs(int runeIndex);
uint32_t UnitFlags(uint64_t guid);
uint32_t DynamicFlags(uint64_t guid);
uint32_t ObjectFlags(uint64_t guid);
uint32_t GameObjectBytes1(uint64_t guid);
uint32_t Field(uint64_t guid, uint32_t byteOffset);
// CGObject instance field (NOT descriptor). DialogStatus is InstanceField(g, 0x90).
uint32_t InstanceField(uint64_t guid, uint32_t byteOffset);
// UNIT_NPC_FLAGS (descriptor). QUESTGIVER bit = 0x2. Separate from dialog status.
uint32_t NpcFlags(uint64_t guid);
// Real client dialog status (DialogStatus enum): field CGObject+0x90, written by
// CGObject_C::SetQuestGiverStatus (0x744400) from SMSG_QUESTGIVER_STATUS
// (CGPlayer_C::OnQuestGiverStatus @ 0x6D11C0). Same field CGUnit_C::GetQuestInteractType
// (0x744640) reads. 0 = none / not yet received; 7/8 = available (!); 9/10 = reward (?).
int QuestGiverStatus(uint64_t guid);
// Packed diagnostic: ptr|raw90|st|interact|npcf|type|entry|qtot|...
std::string QuestGiverDiag(uint64_t guid);
float Scale(uint64_t guid);
bool Exists(uint64_t guid);

// Geometry helpers
float Distance(uint64_t a, uint64_t b);
float DistancePos(const Vec3& a, const Vec3& b);
// arcRadians = HALF-angle. Default π/2 = WotLK unit-target face (full 180° front).
bool IsFacing(uint64_t a, uint64_t b, float arcRadians = 1.5707963f);
bool IsBehind(uint64_t a, uint64_t b);

// Movement
void MoveTo(const Vec3& pos);
void FaceDirection(float radians);
void ClickPosition(const Vec3& pos);

// Spell cast via native Spell_C_CastSpell (NOT FrameScript — avoids Blizzard UI taint).
// targetGuid 0 = no explicit target (self / current). Returns true if call did not AV.
bool CastSpell(int spellId, uint64_t targetGuid = 0);

// Camera / world
Vec3 CameraPosition();
int TraceLineEx(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags);
bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hit, uint32_t flags);
bool WorldToScreen(const Vec3& world, float* sx, float* sy);

// Raw camera fields for a Lua-side world->screen projection (calibratable
// without a C++ rebuild). 12340 CGCamera layout: +0x08 position, +0x14 the 3x3
// view matrix (3 rows), +0x40 FOV. `ok` is false when the camera isn't readable.
struct CamData { Vec3 pos, fwd, right, up; float fov; bool ok; };
CamData CameraData();

// AFK / input
void ResetAfk();
bool GetKeyState(int vkey);

} // namespace RL::Game::OM
