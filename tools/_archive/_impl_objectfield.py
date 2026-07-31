"""Implement ObjectField() for real, so a descriptor offset can be MEASURED.

Quest-giver detection is dead because ObjectQuestGiverStatus is a `return 0`
stub. The natural fix is UNIT_NPC_FLAGS (bit 0x2 = QUESTGIVER), but that offset
is not in DescriptorTable and guessing it means reading arbitrary memory.

Every offset already in DescriptorTable is index*4 against standard 3.3.5a
update-fields (0xEC = 0x3B*4 Flags, 0x13C = 0x4F*4 DynamicFlags, 0xD8 = 0x36*4
Level ...), so the table is internally consistent - but "consistent with the ones
I checked" is not the same as "I know the one I did not". That distinction is the
whole reason this project keeps getting bitten, so it is not being guessed here.

Instead: expose the same descriptor read the OM already performs safely, bounded
and generic. Mem::Read is SEH-wrapped and range-checked (returns T{} on a bad
address rather than faulting), so a wrong offset yields 0, not a crash. The addon
can then sweep candidate offsets against NPCs the client demonstrably treats as
quest givers and find the right one by measurement.
"""
from pathlib import Path

ROOT = Path(r"C:\Ascension\Workspace\RaijinLab\runtime\src")

# ---- 1. ObjectManager: bounded generic descriptor read ---------------------
om = ROOT / "game" / "ObjectManager.cpp"
s = om.read_text(encoding="utf-8", errors="ignore")
ANCH = """float Scale(uint64_t guid) {
    uintptr_t p = Ptr(guid);"""
NEW = """// Generic descriptor field read, so offsets can be MEASURED from Lua instead of
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
    uintptr_t p = Ptr(guid);
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    return d ? Mem::Read<uint32_t>(d + byteOffset) : 0;
}

float Scale(uint64_t guid) {
    uintptr_t p = Ptr(guid);"""
assert ANCH in s, "Scale anchor missing"
assert "uint32_t Field(uint64_t guid" not in s, "already implemented"
om.write_text(s.replace(ANCH, NEW, 1), encoding="utf-8")
print("ObjectManager.cpp: Field() implemented")

# ---- 2. header ------------------------------------------------------------
h = ROOT / "game" / "ObjectManager.h"
t = h.read_text(encoding="utf-8", errors="ignore")
A2 = "uint32_t DynamicFlags(uint64_t guid);"
assert A2 in t
if "uint32_t Field(uint64_t guid" not in t:
    t = t.replace(A2, A2 + "\nuint32_t Field(uint64_t guid, uint32_t byteOffset);", 1)
    h.write_text(t, encoding="utf-8")
print("ObjectManager.h: Field() declared")

# ---- 3. Dispatch: stop stubbing ObjectField --------------------------------
d = ROOT / "bridge" / "Dispatch.cpp"
u = d.read_text(encoding="utf-8", errors="ignore")
OLD = """    if (!std::strcmp(name, "ObjectDescriptor") || !std::strcmp(name, "ObjectField") ||
        !std::strcmp(name, "GameObjectType") || !std::strcmp(name, "ObjectIsQuestObjective") ||
        !std::strcmp(name, "ObjectQuestGiverStatus"))
        return PushNumber(L, 0);"""
NEW3 = """    // ObjectField is REAL now. It was grouped with the stubs below, which is how
    // ObjectQuestGiverStatus came to answer 0 for every npc in the world while
    // looking implemented from Lua - 0 is truthy there, so the caller's guard
    // passed and the lookup missed forever. A stub that returns an in-range
    // value is worse than a missing command.
    if (!std::strcmp(name, "ObjectField"))
        return PushNumber(L, OmEnabled()
            ? OM::Field(GuidArg(L, 2), (uint32_t)luaL_optnumber(L, 3, 0)) : 0);

    // STILL STUBS - each returns a hardcoded 0. Do not add callers that treat
    // the result as an answer; treat 0 from these as "unknown", never as "no".
    if (!std::strcmp(name, "ObjectDescriptor") ||
        !std::strcmp(name, "GameObjectType") || !std::strcmp(name, "ObjectIsQuestObjective") ||
        !std::strcmp(name, "ObjectQuestGiverStatus"))
        return PushNumber(L, 0);"""
assert OLD in u, "stub group not found"
d.write_text(u.replace(OLD, NEW3, 1), encoding="utf-8")
print("Dispatch.cpp: ObjectField wired to OM::Field, stubs labelled")
