"""Round 12: disassemble the CALLER of 0x512B00 (ret=0x858A16, so call at
~0x858A11) plus the recursive cycle frames seen in the round-11 crash stack
(frames 1-8 = 0x8567E7, 0x84EC46, 0x855B33, 0x8569A9, 0x84EC9F, 0x8549A9,
0x85651C, 0x85898A). Goal: find where the garbage GUID-struct pointer (arg0
of 0x512B00) comes from."""
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

# Caller of 0x512B00: ret=0x858A16 -> call at 0x858A11. Disassemble a window.
disasm(0x858950, 90, "0x858950.. caller region (call to 0x512B00 near 0x858A11)")
# Recursion cycle call sites
disasm(0x8567C0, 60, "0x8567C0 (frame-1 ret 0x8567E7)")
disasm(0x84EC20, 60, "0x84EC20 (frame-2 ret 0x84EC46)")
disasm(0x855B10, 60, "0x855B10 (frame-3 ret 0x855B33)")
disasm(0x856980, 60, "0x856980 (frame-4 ret 0x8569A9)")
disasm(0x84EC80, 60, "0x84EC80 (frame-5 ret 0x84EC9F)")
disasm(0x854980, 60, "0x854980 (frame-6 ret 0x8549A9)")
disasm(0x8564F0, 60, "0x8564F0 (frame-7 ret 0x85651C)")
disasm(0x858960, 60, "0x858960 (frame-8 ret 0x85898A)")
