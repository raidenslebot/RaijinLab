"""Extract the FrameScript handler table (name, handler) pairs from Ascension.exe.

The registration is table-based: an array of {const char* name; handler} (8 bytes
per entry) somewhere in .rdata. We find the table by locating the pointer to a
known string (e.g. "IsCurrentSpell" @ 0xa0ad4c) and reading back 8-byte entries
until we hit a name pointer that is not a valid string (end of table).
"""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def off_to_va(off):
    return base + pe.get_rva_from_offset(off)

def is_valid_name_ptr(va):
    """True if va points to a printable ASCII string < 128 chars."""
    try:
        off = va_to_off(va)
    except Exception:
        return False
    if off < 0 or off + 128 > len(data):
        return False
    chunk = data[off:off+128]
    n = 0
    for b in chunk:
        if b == 0:
            return n > 0
        if not (32 <= b < 127):
            return False
        n += 1
        if n > 100:
            return False
    return False

def read_name(va):
    off = va_to_off(va)
    end = data.find(b'\0', off)
    return data[off:end].decode('latin1')

# Known string VA of a handler name to anchor the table
anchor_name = b"IsCurrentSpell"
idx = data.find(anchor_name)
anchor_str_va = off_to_va(idx)
print(f"anchor string '{anchor_name.decode()}' @ {hex(anchor_str_va)}")

# Find every 4-byte little-endian pointer to anchor_str_va
pat = anchor_str_va.to_bytes(4, 'little')
hits = []
start = 0
while True:
    i = data.find(pat, start)
    if i < 0:
        break
    start = i + 1
    hits.append(i)

print(f"found {len(hits)} pointer(s) to anchor string")
for i in hits:
    va = off_to_va(i)
    print(f"  ptr @ {hex(va)} (file off {hex(i)})")

# For each hit, check if it looks like a table entry: ptr-4 and ptr+4 are strings
found_tables = []
for i in hits:
    # entry layout: [name_ptr][handler_ptr]
    entry_va = off_to_va(i)
    # check previous entries and next entries for name-pointer pattern
    table_ok = True
    count = 0
    for delta in range(0, 0x200, 8):
        cand = off_to_va(i - delta)
        if is_valid_name_ptr(cand):
            count += 1
    print(f"  hit @ {hex(entry_va)}: prev-valid-name-entries={count}")
    # walk back to table start
    if count > 3:
        found_tables.append(entry_va)

# For the most promising hit, dump the whole table region and map names
def dump_table(entry_va, name_set):
    # walk back while name pointer valid
    i = va_to_off(entry_va)
    start_i = i
    while True:
        cand = off_to_va(start_i - 8)
        if is_valid_name_ptr(cand):
            start_i -= 8
        else:
            break
    out = []
    j = start_i
    while True:
        name_ptr = int.from_bytes(data[j:j+4], 'little')
        handler = int.from_bytes(data[j+4:j+8], 'little')
        if not is_valid_name_ptr(name_ptr):
            break
        nm = read_name(name_ptr)
        out.append((nm, handler))
        j += 8
        if len(out) > 2000:
            break
    return out

# Use the first hit that had >3 valid prev entries
for entry_va in found_tables[:1]:
    table = dump_table(entry_va, set())
    print(f"\n=== table @ region of {hex(entry_va)}: {len(table)} entries ===")
    want = ["IsCurrentSpell", "IsUsableSpell", "IsSpellInRange", "StartAttack",
            "StopAttack", "UnitCastingInfo", "IsUnitCasting", "IsUnitChanneling",
            "SpellIsTargeting", "IsAutoRepeatSpellOn", "IsAttackAction",
            "AttackTarget", "GetCurrentSpellName", "CastSpell", "CastSpellByName",
            "UseAction", "IsActionInRange", "GetActionInfo", "TargetUnit",
            "ClearTarget", "TargetLastTarget", "InteractUnit", "GetSpellInfo",
            "GetSpellCooldown", "IsCurrentAction", "GetUnitName", "UnitGUID",
            "UnitExists", "UnitIsDeadOrGhost", "UnitCanAttack", "UnitAffectingCombat",
            "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax",
            "GetUnitPower", "UnitCastingInfo", "IsSpellKnown", "GetTime",
            "GetCombatRating", "UnitAttackPower", "GetPlayerFacing", "UnitPosition",
            "GetPlayerTarget", "UnitCanAssist", "IsInCombat", "UnitInCombat",
            "UnitClassification", "GetAutoQuestPopUp", "IsAutoRepeatSpellOn",
            "UnitIsUnit", "UnitIsPlayer", "UnitIsFriend", "UnitIsEnemy",
            "UnitReaction", "UnitIsTapRejected", "GetGUID", "UnitOnTaxi",
            "UnitIsFeignDeath", "UnitIsGhost", "UnitIsDead", "HasPetUI",
            "GetPetActionInfo", "GetItemCooldown", "GetSpellCharges"]
    wanted = set(want)
    shown = 0
    for nm, handler in table:
        if nm in wanted:
            print(f"  {nm:<28} -> 0x{handler:08X}")
            wanted.discard(nm)
            shown += 1
    missing = sorted(wanted)
    if missing:
        print("  MISSING (not in table):")
        for m in missing:
            print(f"    {m}")
