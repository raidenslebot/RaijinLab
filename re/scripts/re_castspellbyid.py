"""Disassemble the FrameScript CastSpellByID handler (0x53E177) to see the
EXACT call layout it uses into 0x80DA40 / 0x80CCE0 — ground truth for
how the client casts by spell id (guidHi=0 vs guid record)."""
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

def dump_range(start, end, label=""):
    print(f"\n=== {label or hex(start)} .. {hex(end)} ===")
    off = va_to_off(start)
    for insn in md.disasm(data[off:off + (end - start)], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

# Find xrefs to 0x80DA40 and 0x80CCE0 across .text
targets = {0x80DA40: "Spell_C wrapper", 0x80CCE0: "Spell_C real"}
import struct
print("=== XREFS to 0x80DA40 / 0x80CCE0 ===")
text_off = pe.get_offset_from_rva(0x401000 - base)
text_len = 0x9DE3B2 - 0x401000
text = data[text_off:text_off+text_len]
for tgt, name in targets.items():
    pat = struct.pack('<I', tgt)
    idx = 0
    found = []
    while True:
        idx = text.find(pat, idx)
        if idx < 0: break
        found.append(0x401000 + idx)
        idx += 1
    print(f"  {name} {hex(tgt)}: {len(found)} direct refs -> {[hex(x-5) for x in found[:20]]}")

# dump the CastSpellByID handler
dump_range(0x53E177, 0x53E400, "0x53E177 CastSpellByID FS handler")
