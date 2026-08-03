"""Dissect the canCast gate 0x5191C0: dump its jump/byte tables as data,
disassemble 0x513530 (called on the fail path), and find writers of
0xd4139c and 0xbd078c."""
from pathlib import Path
import pefile
import struct
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

# Jump table + byte table as raw dwords/bytes
print("=== 0x519250 jump table (dwords) ===")
off = va_to_off(0x519250)
for i in range(8):
    v = struct.unpack_from('<I', data, off + i*4)[0]
    print(f"  [{i}] -> 0x{v:08X}")
print("=== 0x519260 byte table ===")
off = va_to_off(0x519260)
print("  " + " ".join(f"{data[off+i]:02X}" for i in range(24)))

dump_range(0x513530, 0x513600, "0x513530 (fail-path call in 0x5191C0)")

# Find writers to 0xd4139c and 0xbd078c
def find_writers(target):
    addr = struct.pack('<I', target)
    text_off = pe.get_offset_from_rva(0x401000 - base)
    text = data[text_off:pe.get_offset_from_rva(0x9DE3B2 - base) - text_off]
    out = []
    for i in range(len(text) - 6):
        if text[i:i+4] != addr: continue
        op = text[i-1] if i >= 1 else 0
        if op in (0x05,0x0D,0x15,0x1D,0x25,0x2D,0x35,0x3D) and i >= 2 and text[i-2] == 0x89:
            va = 0x401000 + i - 2
            o = va_to_off(va)
            for insn in md.disasm(text[o-text_off:o-text_off+12], va):
                out.append(f"WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0x05 and i >= 2 and text[i-2] == 0xC7:
            va = 0x401000 + i - 2
            o = va_to_off(va)
            for insn in md.disasm(text[o-text_off:o-text_off+14], va):
                out.append(f"WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0xA3:
            va = 0x401000 + i - 1
            o = va_to_off(va)
            for insn in md.disasm(text[o-text_off:o-text_off+7], va):
                out.append(f"WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
    return out

for g in (0xD4139C, 0xBD078C):
    w = find_writers(g)
    print(f"\n=== writers of {hex(g)}: {len(w)} ===")
    for x in w[:30]:
        print("  " + x)
