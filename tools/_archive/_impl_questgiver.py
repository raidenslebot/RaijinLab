from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. OM: read the instance field -----------------------------------------
om = R / "runtime/src/game/ObjectManager.cpp"
s = om.read_text(encoding="utf-8", errors="ignore")
ANCH = "uint32_t Field(uint64_t guid, uint32_t byteOffset) {"
NEW = """// Quest giver dialog status. INSTANCE field on CGObject, not a descriptor
// field - which is why every descriptor-based attempt read nothing.
//
// The client stores it at CGObject+0x90, written by SetQuestGiverStatus
// (0x744400) when SMSG_QUESTGIVER_STATUS arrives and read by
// GetQuestInteractType (0x744640). Values 0..10; 7/8 = available ("!"),
// 9/10 = reward ("?").
//
// This replaces a `return PushNumber(L, 0)` stub that answered 0 for every
// object in the world. 0 is truthy in Lua, so the addon's guard passed and the
// lookup missed forever: no quest could be accepted or handed in, and the bot
// swept belief-field legs hunting npcs it was structurally blind to. The live
// contract counted 10958 queries, all zero, before this was implemented.
//
// A 0 here is still meaningful and still ambiguous: it is genuinely "no dialog
// status" AND what an out-of-range npc reads before the server has sent one.
// The addon treats 0 as UNKNOWN rather than "not a giver" for that reason.
uint32_t QuestGiverStatus(uint64_t guid) {
    uintptr_t p = Ptr(guid);
    if (!p) return 0;
    return Mem::Read<uint32_t>(p + Offsets::O().QuestGiverStatus);
}

uint32_t Field(uint64_t guid, uint32_t byteOffset) {"""
assert ANCH in s, "Field() anchor missing"
if "uint32_t QuestGiverStatus(uint64_t guid)" not in s:
    s = s.replace(ANCH, NEW, 1)
    om.write_text(s, encoding="utf-8")
    print("ObjectManager.cpp: QuestGiverStatus implemented")
else:
    print("ObjectManager.cpp: already implemented")

# ---- 2. header --------------------------------------------------------------
h = R / "runtime/src/game/ObjectManager.h"
t = h.read_text(encoding="utf-8", errors="ignore")
A2 = "uint32_t Field(uint64_t guid, uint32_t byteOffset);"
if "uint32_t QuestGiverStatus(uint64_t guid);" not in t:
    assert A2 in t
    t = t.replace(A2, "uint32_t QuestGiverStatus(uint64_t guid);\n" + A2, 1)
    h.write_text(t, encoding="utf-8")
    print("ObjectManager.h: declared")

# ---- 3. Dispatch: stop stubbing it ------------------------------------------
d = R / "runtime/src/bridge/Dispatch.cpp"
u = d.read_text(encoding="utf-8", errors="ignore")
OLD = """    if (!std::strcmp(name, "ObjectDescriptor") ||
        !std::strcmp(name, "GameObjectType") || !std::strcmp(name, "ObjectIsQuestObjective") ||
        !std::strcmp(name, "ObjectQuestGiverStatus"))
        return PushNumber(L, 0);"""
NEW3 = """    // REAL NOW. Was grouped with the stubs below and answered 0 for every object
    // in the world; the addon's contract counted 10958 consecutive zeros.
    if (!std::strcmp(name, "ObjectQuestGiverStatus"))
        return PushNumber(L, OmEnabled() ? OM::QuestGiverStatus(GuidArg(L, 2)) : 0);

    // STILL STUBS - each returns a hardcoded 0. Treat 0 from these as "unknown",
    // never as "no".
    if (!std::strcmp(name, "ObjectDescriptor") ||
        !std::strcmp(name, "GameObjectType") || !std::strcmp(name, "ObjectIsQuestObjective"))
        return PushNumber(L, 0);"""
if 'OM::QuestGiverStatus' not in u:
    assert OLD in u, "stub group not found"
    u = u.replace(OLD, NEW3, 1)
    d.write_text(u, encoding="utf-8")
    print("Dispatch.cpp: wired to OM::QuestGiverStatus")

# ---- 4. version -------------------------------------------------------------
u = d.read_text(encoding="utf-8", errors="ignore")
import re
u = re.sub(r'const char\* kVersion = "[^"]+";',
           'const char* kVersion = "1.8.15-questgiver";', u, count=1)
d.write_text(u, encoding="utf-8")
print("Dispatch.cpp: version 1.8.15-questgiver")

# ---- 5. the addon was matching the WRONG codes ------------------------------
q = R / "addon/modules/questing/QuestOM.lua"
v = q.read_text(encoding="utf-8")
OLD5 = """local DEFAULT_AVAILABLE = { [5] = true, [6] = true }          -- AVAILABLE_REP, AVAILABLE
local DEFAULT_COMPLETE  = { [7] = true, [8] = true }          -- REWARD2, REWARD"""
NEW5 = """-- CORRECTED against the client's own writer. The runtime offset table documents
-- SetQuestGiverStatus (0x744400) / GetQuestInteractType (0x744640) and the actual
-- meaning of the values on THIS core: 7/8 = available ("!"), 9/10 = reward ("?").
-- These were {5,6} and {7,8} - shifted by two - so even once the status read was
-- implemented, "available" would have matched nothing and "complete" would have
-- matched npcs that merely had a quest to GIVE. Overridable via
-- RaijinLabDB.quest.giver_status; /raijin quest givers dumps live values.
local DEFAULT_AVAILABLE = { [7] = true, [8] = true }          -- AVAILABLE / AVAILABLE_REP
local DEFAULT_COMPLETE  = { [9] = true, [10] = true }         -- REWARD / REWARD2"""
assert OLD5 in v, "status sets not found"
v = v.replace(OLD5, NEW5, 1)
q.write_text(v, encoding="utf-8")
print("QuestOM.lua: status codes corrected to 7/8 available, 9/10 reward")
