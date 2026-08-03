"""Disassemble the REAL Spell_C logic 0x80CCE0 to see how it consumes the
target GUID (arg3/arg4) and what it does during cast-feedback. This is what
SafeNativeCast actually drives via the 0x80DA40 wrapper."""
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

# args: cdecl -> arg1=[ebp+8] (player obj), arg2=[ebp+0xC] (spellId),
#       arg3=[ebp+0x10] (guid lo), arg4=[ebp+0x14] (guid hi), arg5=[ebp+0x18],
#       arg6=[ebp+0x1C] (0), arg7=[ebp+0x20]
disasm(0x80CCE0, 200, "0x80CCE0 real Spell_C logic (first 200 insns)")
