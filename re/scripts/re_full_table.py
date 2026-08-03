"""Dump the FULL contiguous FrameScript handler tables and write all
name -> handler pairs to handlers_full.txt."""
from pathlib import Path
import pefile

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def off_to_va(off):
    return base + pe.get_rva_from_offset(off)

def is_str(va):
    try:
        off = va_to_off(va)
    except Exception:
        return False
    chunk = data[off:off+100]
    n = 0
    for b in chunk:
        if b == 0:
            return n > 0
        if not (32 <= b < 127):
            return False
        n += 1
    return False

def read_str(va):
    off = va_to_off(va)
    end = data.find(b'\0', off)
    return data[off:end].decode('latin1')

# Walk the table starting from each known anchor (0xac3e00, 0xaccd68)
# Extend forward while entries are valid; also backward.
def walk_table(anchor):
    out = {}
    # extend backward
    start = anchor
    while True:
        cand = start - 8
        try:
            np = int.from_bytes(data[va_to_off(cand):va_to_off(cand)+4], 'little')
        except Exception:
            break
        if is_str(np):
            start = cand
        else:
            break
    # walk forward
    j = start
    while True:
        try:
            off = va_to_off(j)
        except Exception:
            break
        np = int.from_bytes(data[off:off+4], 'little')
        h = int.from_bytes(data[off+4:off+8], 'little')
        if not is_str(np):
            break
        out[read_str(np)] = h
        j += 8
    return out, start

tables = {}
for anchor in [0xac3e00, 0xaccd68, 0xacc6d0, 0xaceb50, 0xb2d928]:
    t, start = walk_table(anchor)
    if t:
        tables[start] = t
        print(f"table @ {hex(start)}: {len(t)} entries "
              f"(0x{start:08X}..0x{start+8*len(t):08X})")

allmap = {}
for start, t in sorted(tables.items()):
    allmap.update(t)

print(f"\ntotal unique names: {len(allmap)}")
with open(Path(__file__).parent / "handlers_full.txt", "w") as f:
    for nm in sorted(allmap):
        f.write(f"{nm}\t0x{allmap[nm]:08X}\n")

# Show the ones we care about
want = ["IsCurrentSpell", "IsAutoRepeatSpell", "IsUsableSpell", "IsSpellInRange",
        "StartAttack", "StopAttack", "UnitCastingInfo", "UnitChannelInfo",
        "IsUnitCasting", "IsUnitChanneling", "SpellIsTargeting", "CastSpell",
        "CastSpellByName", "CastSpellByID", "UseAction", "IsActionInRange",
        "GetActionInfo", "TargetUnit", "ClearTarget", "TargetLastTarget",
        "InteractUnit", "GetSpellInfo", "GetSpellCooldown", "IsCurrentAction",
        "UnitExists", "UnitIsDeadOrGhost", "UnitCanAttack", "UnitAffectingCombat",
        "IsInCombat", "UnitInCombat", "UnitIsUnit", "UnitIsPlayer",
        "UnitIsFriend", "UnitIsEnemy", "UnitReaction", "UnitOnTaxi",
        "UnitIsFeignDeath", "UnitIsGhost", "UnitIsDead", "UnitGUID",
        "GetTime", "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax",
        "GetUnitPower", "IsSpellKnown", "UnitPosition", "GetPlayerFacing",
        "UnitTarget", "IsMounted", "GetShapeshiftForm", "GetSpellCharges",
        "GetPetActionInfo", "GetItemCooldown", "UnitIsTapRejected",
        "GetUnitPitch", "UnitAttackRange", "IsAttackAction", "GetSpellName",
        "GetSpellTexture", "GetSpellBookItemInfo", "GetNumSpellTabs",
        "HasWandEquipped", "IsAutoRepeatSpellOn", "GetCurrentSpellName"]
for nm in sorted(want):
    if nm in allmap:
        print(f"  {nm:<28} -> 0x{allmap[nm]:08X}")
    else:
        print(f"  {nm:<28} -> NOT IN TABLES")
