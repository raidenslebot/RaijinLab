"""Full disassembly of the crash function 0x512B00 + its helpers + the
frame-0 caller 0x856370, to identify WHAT the client is resolving when the
crash happens."""
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

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

disasm(0x512B00, 40, "0x512B00 crash fn (GUID->Object resolver)")
disasm(0x512AB0, 40, "0x512AB0 helper called with guidPtr")
disasm(0x715500, 30, "0x715500 method called on resolved object")
disasm(0x856370, 40, "0x856370 (frame-0/8 caller)")
disasm(0x8562E0, 25, "0x8562E0 (called just before 0x856370 at 0x8567C5)")
disasm(0x857CA0, 30, "0x857CA0 (frame-1 caller target)")
