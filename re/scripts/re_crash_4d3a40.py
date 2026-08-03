"""RE the 01:11:45 crash: eip=0x004D3A40 AV_WRITE fault=0xD0377AA8 (heap),
called from 0x00858A16, Lua VM stack. Disassemble the crash site + caller."""
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

def off_to_va(off):
    return base + pe.get_rva_from_offset(off)

def dump(va, n=40, maxlen=400, label=""):
    print(f"\n=== {label or hex(va)} ===")
    try:
        off = va_to_off(va)
    except Exception:
        print("  <no mapping>")
        return
    chunk = data[off:off+maxlen]
    for i, insn in enumerate(md.disasm(chunk, va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n:
            break

# crash site eip
dump(0x004D3A40, 40, 400, "crash eip 0x004D3A40")
# caller (frame 0 ret = 0x00858A16 -> call site just before)
dump(0x00858A00, 30, 300, "caller 0x00858A16 region")
# frame1 ret 0x008567E7 -> Lua VM caller
dump(0x008567D0, 20, 200, "Lua VM caller 0x008567E7 region")
