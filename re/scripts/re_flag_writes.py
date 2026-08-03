"""Find WRITES to 0xbd1af0 / 0xbd1ae0 / 0xbd1afc / 0xbd1aec (mov [imm], reg/imm)."""
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

text_off = pe.get_offset_from_rva(0x401000 - base)
text = data[text_off:pe.get_offset_from_rva(0x9DE3B2 - base) - text_off]

for target in (0xBD1AF0, 0xBD1AE0, 0xBD1AFC, 0xBD1AEC):
    addr = struct.pack('<I', target)
    print(f"=== writes to {hex(target)} ===")
    for i in range(len(text) - 6):
        if text[i:i+4] != addr: continue
        # candidate: byte before addr is opcode of a [imm] memory op
        op = text[i-1] if i >= 1 else 0
        # mov [imm], eax/ecx/edx/ebx/esi/edi/esp/ebp = 89 05 / 89 0D / 89 15 / 89 1D / 89 35 / 89 3D / 89 25 / 89 2D
        # mov [imm], al = A2 / A3? no: A2=moffs8 al, A3=moffs32 eax
        # mov dword ptr [imm], imm32 = C7 05
        # mov byte ptr [imm], imm8 = C6 05
        if op in (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D) and i >= 2 and text[i-2] == 0x89:
            va = 0x401000 + i - 2
            off = va_to_off(va)
            for insn in md.disasm(text[off-text_off:off-text_off+12], va):
                print(f"  WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0x05 and i >= 2 and text[i-2] == 0xC7:
            va = 0x401000 + i - 2
            off = va_to_off(va)
            for insn in md.disasm(text[off-text_off:off-text_off+14], va):
                print(f"  WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0x05 and i >= 2 and text[i-2] == 0xC6:
            va = 0x401000 + i - 2
            off = va_to_off(va)
            for insn in md.disasm(text[off-text_off:off-text_off+12], va):
                print(f"  WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0xA2:  # mov [imm], al
            va = 0x401000 + i - 1
            off = va_to_off(va)
            for insn in md.disasm(text[off-text_off:off-text_off+7], va):
                print(f"  WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
        elif op == 0xA3:  # mov [imm], eax
            va = 0x401000 + i - 1
            off = va_to_off(va)
            for insn in md.disasm(text[off-text_off:off-text_off+7], va):
                print(f"  WRITE {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                break
