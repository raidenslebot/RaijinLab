"""Find UnitCastingInfo / UnitChannelInfo / UnitExists handlers by locating
the string pointers in the registration tables, then disassemble them to find
the player casting-state field. Also confirm player+0xA20 = attack GUID from
0x806030 tail."""
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

def find_handler(name):
    """Find the name string, then every pointer to it in .rdata, and for each
    check if the 4 bytes after the pointer look like a .text handler address
    (valid prologue)."""
    sva = None
    idx = data.find(name.encode())
    if idx < 0:
        print(f"  '{name}' string not found")
        return None
    sva = off_to_va(idx)
    pat = sva.to_bytes(4, 'little')
    hits = []
    start = 0
    while True:
        i = data.find(pat, start)
        if i < 0:
            break
        start = i + 1
        # candidate handler = 4 bytes after the pointer
        h = int.from_bytes(data[i+4:i+8], 'little')
        # valid text address?
        if 0x00401000 <= h <= 0x009DE3B3:
            # check prologue bytes
            try:
                off = va_to_off(h)
                b0 = data[off]
                if b0 in (0x55, 0x8B, 0x83, 0xE8, 0x56, 0x57, 0x53):
                    hits.append((off_to_va(i), h))
            except Exception:
                pass
    return hits

for name in ["UnitCastingInfo", "UnitChannelInfo", "UnitExists", "UnitIsUnit",
             "UnitCanAttack", "UnitIsDeadOrGhost", "UnitAffectingCombat",
             "IsInCombat", "UnitGUID", "UnitPosition", "UnitHealth",
             "UnitPower", "UnitTarget", "UnitIsEnemy", "IsMounted",
             "GetPlayerFacing", "UnitOnTaxi", "TargetUnit", "ClearTarget",
             "UseAction", "IsActionInRange", "IsCurrentAction", "InteractUnit",
             "StartAttack", "StopAttack", "IsAutoRepeatSpellOn",
             "GetCurrentSpellName", "GetActionInfo"]:
    res = find_handler(name)
    if res:
        for (ptr_va, h) in res[:3]:
            print(f"  {name:<22} ptr@{hex(ptr_va)} -> handler 0x{h:08X}")
    else:
        print(f"  {name:<22} not found")

print()
print("=== 0x806030 tail (confirm player+0xA20 = attack GUID) ===")
try:
    off = va_to_off(0x008060df)
    for i, insn in enumerate(md.disasm(data[off:off+240], 0x008060df)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= 50:
            break
except Exception as e:
    print(e)
