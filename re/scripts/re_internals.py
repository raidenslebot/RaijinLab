"""Trace internal state functions so the runtime can read authoritative state
directly (no Lua, no HW flag, no crash):
  0x540670  - shared spell-name/id resolver (check for HW flag gate)
  0x806030  - IsCurrentSpell internal (player current-spell id check)
  0x7fe130  - auto-repeat spell getter (called by IsAutoRepeatSpell)
  0x7fe180  - second auto-repeat getter
  0x4cfd20  - shared spell-object resolver (IsUsableSpell/IsSpellInRange)
  0x5d3390  - 'can use spell' internal
  0x7fdcd0  - SpellIsTargeting (reads global 0xd3f4e4)  [already seen]
Also find UnitCastingInfo/UnitChannelInfo handlers from the handlers dump.
"""
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

def dump(va, n=70, maxlen=420):
    print(f"\n=== {hex(va)} ===")
    try:
        off = va_to_off(va)
    except Exception:
        print("  <no mapping>")
        return
    chunk = data[off:off+maxlen]
    for i, insn in enumerate(md.disasm(chunk, va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n:
            break

for va in [0x00540670, 0x00806030, 0x007fe130, 0x007fe180,
           0x004cfd20, 0x005d3390]:
    dump(va, 60, 380)
