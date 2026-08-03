"""Round 12: disassemble 0x60BF10 (called from 0x512B00's tail with the
GUID-struct arg + 0x90) to verify it safely handles a valid 8-byte zero GUID
struct — needed for VEH crash-recovery at 0x512B07."""
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
    try:
        for insn in md.disasm(data[off:], va):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            count += 1
            if count >= n:
                break
    except Exception as e:
        print("  err", e)

disasm(0x60BF10, 70, "0x60BF10 cleanup(GUIDstruct, 0x90)")
