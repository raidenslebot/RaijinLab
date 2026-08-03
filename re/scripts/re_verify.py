"""Verify: (1) UnitCastingInfo handler 0x00611DF0 internal & HW gate,
(2) who writes the current-spells list head 0xaf5254 (node layout),
(3) StartAttack handler 0x00523090."""
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

def dump(va, n=70, maxlen=460):
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

dump(0x00611DF0, 60, 400)   # UnitCastingInfo handler
print("\n=== xrefs writing 0xaf5254 (current-spells list head) ===")
# find instructions that write [0xaf5254]
pat = int(0xaf5254).to_bytes(4, 'little')
start = 0
shown = 0
while shown < 8:
    idx = data.find(pat, start)
    if idx < 0:
        break
    start = idx + 1
    try:
        va = off_to_va(idx)
    except Exception:
        continue
    lo = max(0, idx - 20)
    hi = min(len(data), idx + 20)
    for insn in md.disasm(data[lo:hi], off_to_va(lo)):
        if '0xaf5254' in insn.op_str and insn.address + insn.size > va:
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            shown += 1
            break

print("\n=== StartAttack handler 0x00523090 ===")
dump(0x00523090, 40, 300)
