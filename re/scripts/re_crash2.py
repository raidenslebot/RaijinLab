"""Identify the function containing crash site 0x4D3A40 and its callers."""
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

def dump(va, n=40, maxlen=300, label=""):
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

# 1. Find the start of the function containing 0x4D3A40 (walk back for prologue)
print("=== walking back from 0x4D3A40 for function start ===")
# 0x4D3A40 is inside a function; the two writes + cmp + ret look like an epilogue.
# The function likely starts with a prologue. Let's dump a wide window before it.
dump(0x004D38E0, 60, 400, "0x4D38E0-0x4D3A40 window (function body)")

# 2. Find callers of the function that contains 0x4D3A40.
# The function's start address: find it by looking for prologue pattern before 0x4D3A40.
# From the window, the function probably starts around 0x4D3900. Let's find the start
# by scanning backwards for a push ebp / mov ebp,esp at an instruction boundary.
# Simpler: find all E8 calls whose target <= 0x4D3A40 and target+0x60 >= 0x4D3A40.
print("\n=== calls into 0x4D38xx..0x4D3A5D range ===")
def find_calls_into(lo, hi):
    out = []
    for sec in pe.sections:
        if not (sec.Characteristics & 0x20000000):
            continue
        s_off = sec.PointerToRawData
        s_size = sec.SizeOfRawData
        chunk = data[s_off:s_off+s_size]
        va0 = base + sec.VirtualAddress
        pos = 0
        while True:
            idx = chunk.find(b'\xE8', pos)
            if idx < 0:
                break
            if idx + 5 > len(chunk):
                break
            rel = int.from_bytes(chunk[idx+1:idx+5], 'little', signed=True)
            tgt = va0 + idx + 5 + rel
            if lo <= tgt <= hi:
                out.append((va0 + idx, tgt))
            pos = idx + 1
    return out

for (caller, tgt) in find_calls_into(0x4D3900, 0x4D3A60):
    print(f"  caller {hex(caller)} -> {hex(tgt)}")
