"""Dump all FrameScript registration table entries referenced by the 73
register call sites, mapping names -> handler addresses."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

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

REGFN = 0x00817F90

def find_all_calls_to(regfn):
    calls = []
    for sec in pe.sections:
        if not (sec.Characteristics & 0x20000000):
            continue
        s_off = sec.PointerToRawData
        s_size = sec.SizeOfRawData
        chunk = data[s_off:s_off+s_size]
        va0 = base + sec.VirtualAddress
        pos = 0
        while True:
            idx = chunk.find(b'\xE8', pos)
            if idx < 0:
                break
            if idx + 5 > len(chunk):
                break
            rel = int.from_bytes(chunk[idx+1:idx+5], 'little', signed=True)
            tgt = va0 + idx + 5 + rel
            if tgt == regfn:
                calls.append(va0 + idx)
            pos = idx + 1
    return calls

calls = find_all_calls_to(REGFN)

# Collect table entry base addresses: pattern mov eax,[esi+X+4]; mov ecx,[esi+X]
entries = []
for callva in calls:
    lo = max(0, va_to_off(callva) - 20)
    hi = va_to_off(callva) + 5
    import re
    movs = []
    for insn in md.disasm(data[lo:hi], off_to_va(lo)):
        m = re.match(r"eax, dword ptr \[esi \+ 0x([0-9a-fA-F]+)\]", insn.op_str)
        if m:
            movs.append(('eax', int(m.group(1), 16)))
        else:
            m = re.match(r"ecx, dword ptr \[esi \+ 0x([0-9a-fA-F]+)\]", insn.op_str)
            if m:
                movs.append(('ecx', int(m.group(1), 16)))
    # eax=[X+4], ecx=[X]
    if len(movs) >= 2:
        eax_addr = None
        ecx_addr = None
        for reg, addr in movs:
            if reg == 'eax':
                eax_addr = addr
            else:
                ecx_addr = addr
        if eax_addr is not None and ecx_addr is not None and eax_addr == ecx_addr + 4:
            entries.append(ecx_addr)

print(f"collected {len(entries)} table entry addresses")
for e in sorted(set(entries)):
    print(f"  entry @ {hex(e)}")

# Dump each referenced entry + neighbors
table = {}
for e in set(entries):
    # dump the 8-byte entry
    off = va_to_off(e)
    name_ptr = int.from_bytes(data[off:off+4], 'little')
    handler = int.from_bytes(data[off+4:off+8], 'little')
    if is_str(name_ptr):
        table[read_str(name_ptr)] = handler

want = set(["IsCurrentSpell", "IsUsableSpell", "IsSpellInRange", "StartAttack",
            "StopAttack", "UnitCastingInfo", "IsUnitCasting", "IsUnitChanneling",
            "SpellIsTargeting", "IsAutoRepeatSpellOn", "IsAttackAction",
            "AttackTarget", "GetCurrentSpellName", "CastSpell", "CastSpellByName",
            "UseAction", "IsActionInRange", "GetActionInfo", "TargetUnit",
            "ClearTarget", "TargetLastTarget", "InteractUnit", "GetSpellInfo",
            "GetSpellCooldown", "IsCurrentAction", "GetUnitName", "UnitGUID",
            "UnitExists", "UnitIsDeadOrGhost", "UnitCanAttack", "UnitAffectingCombat",
            "UnitHealth", "UnitPower", "GetUnitPower", "IsSpellKnown", "GetTime",
            "UnitPosition", "GetPlayerFacing", "IsInCombat", "UnitInCombat",
            "UnitIsUnit", "UnitIsPlayer", "UnitIsFriend", "UnitIsEnemy",
            "UnitReaction", "UnitOnTaxi", "UnitIsFeignDeath", "UnitIsGhost",
            "UnitIsDead", "GetPetActionInfo", "GetItemCooldown", "GetSpellCharges",
            "GetCurrentKeyBinding", "GetSpellTexture", "GetSpellName",
            "GetSpellBookItemInfo", "GetShapeshiftForm", "UnitTarget",
            "IsMounted", "UnitChannelInfo", "UnitCastingInfo", "UnitExists",
            "GetRaidTargetIndex", "IsCurrentAction", "GetActionCount",
            "IsAttackAction", "GetPetActionCooldown"])

print(f"\nparsed {len(table)} entries from {len(set(entries))} refs")
with open(Path(__file__).parent / "handlers_dump.txt", "w") as f:
    for nm in sorted(table):
        f.write(f"{nm}\t0x{table[nm]:08X}\n")

for nm in sorted(table):
    if nm in want:
        print(f"  {nm:<28} -> 0x{table[nm]:08X}")

# Also: the IsCurrentSpell string ptr was found at 0xaccd68 earlier.
# That's likely a DIFFERENT registration table (FrameXML names). Dump a window
# around 0xaccd68 to see entries.
print("\n=== window around 0xaccd68 (second table?) ===")
for e in range(0xaccd00, 0xacce00, 8):
    off = va_to_off(e)
    name_ptr = int.from_bytes(data[off:off+4], 'little')
    handler = int.from_bytes(data[off+4:off+8], 'little')
    if is_str(name_ptr):
        print(f"  {hex(e)}: {read_str(name_ptr):<30} 0x{handler:08X}")
