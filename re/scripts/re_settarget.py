"""Disassemble 0x5259E0 (the target setter the TargetUnit handler calls with a
GUID pointer) and 0x520190 (unit-string resolver) to see if 0x5259E0 can be
called directly from native code with a GUID."""
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

disasm(0x5259E0, 60, "0x5259E0 target setter (guidPtr)")
disasm(0x520190, 50, "0x520190 unit-string resolver")
