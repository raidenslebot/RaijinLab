"""Find all xrefs to 0xbd1af0 (secure-execution flag) and 0xbd1ae0 (popup gate)
to understand who sets/clears them and how to set them safely around a cast."""
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

def find_refs(target):
    """Find direct absolute refs to target (mov/cmp [target], ...) and
    lea/imm uses. Returns list of VAs."""
    pat = struct.pack('<I', target)
    refs = []
    idx = 0
    text_off = pe.get_offset_from_rva(0x401000 - base)
    text = data[text_off:pe.get_offset_from_rva(0x9DE3B2 - base) - text_off]
    while True:
        idx = text.find(pat, idx)
        if idx < 0: break
        refs.append(0x401000 + idx)
        idx += 1
    return refs

for g in (0xBD1AF0, 0xBD1AE0, 0xBD1AEC, 0xBD1AFC):
    refs = find_refs(g)
    print(f"=== refs to {hex(g)} ({len(refs)}) ===")
    for r in refs[:40]:
        off = va_to_off(r - 4)
        for insn in md.disasm(data[off:off+16], r - 4):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            break  # just the instruction containing the ref
