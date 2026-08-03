"""Identify [0xd4139c]: disassemble the spell-cast writer contexts
(0x48ec50/0x48ecc2/0x4931b6 regions) and 0xbd078c writers (0x5290dd/0x52aa7e)."""
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

dump_range(0x48EC20, 0x48ED20, "0x48EC20 (d4139c writer: cast start/cancel?)")
dump_range(0x493180, 0x493240, "0x493180 (d4139c writer)")
dump_range(0x5290B0, 0x529130, "0x5290B0 (bd078c writer)")
dump_range(0x52AA40, 0x52AAC0, "0x52AA40 (bd078c writer)")
