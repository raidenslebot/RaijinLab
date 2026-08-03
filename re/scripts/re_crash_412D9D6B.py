"""RE the 02:15 crash: eip=0x412D9D6B AV_READ fault=4, Lua VM stack,
edi=0x5DB22C8C = our DLL + 0x32C8C. Disassemble the game crash site."""
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

def dump(va, n=50, maxlen=400, label=""):
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

# crash eip
dump(0x412D9D60, 40, 300, "crash eip 0x412D9D6B region")
# what function contains it? walk back for prologue
print("\n=== find function containing 0x412D9D6B ===")
off = va_to_off(0x412D9D6B)
for back in range(0x2000, 0, -1):
    pos = off - back
    if data[pos] == 0x55 and data[pos+1] == 0x8B and data[pos+2] == 0xEC:
        prev = data[pos-1] if pos > 0 else 0
        if prev in (0x90, 0xCC, 0xC3, 0x00, 0x55):
            print(f"  prologue @ {hex(off_to_va(pos))}")
            dump(off_to_va(pos), 60, 500, f"function @ {hex(off_to_va(pos))}")
            break
