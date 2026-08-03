"""Round 12: disassemble the PLAYER_TARGET_CHANGED fire site 0x608B19 and find
its callers + any suppression gate. Goal: can we suppress the unitframe update
while we transiently register a cast victim?"""
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

# find fn start before 0x608B19
def fn_start_before(va, maxback=0x3000):
    off = va_to_off(va)
    lo = max(0x400, off - maxback)
    best = None
    for i in range(off - 5, lo, -1):
        if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
            best = i
    return base + pe.get_offset_from_rva(best) if best else None

def rva_of_off(off):
    for s in pe.sections:
        if s.PointerToRawData <= off < s.PointerToRawData + s.SizeOfRawData:
            return s.VirtualAddress + (off - s.PointerToRawData)
    return None

start_off = va_to_off(0x608B19)
best = None
for i in range(start_off - 5, max(0x400, start_off - 0x4000), -1):
    if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
        best = i
if best:
    rva = rva_of_off(best)
    fnstart = base + rva if rva else None
    print("fire fn start:", hex(fnstart) if fnstart else None)
    if fnstart:
        disasm(fnstart, 80, f"fire fn @ {hex(fnstart)}")

# find direct callers of the fire fn
text = None
for s in pe.sections:
    if s.Name.rstrip(b'\x00') == b'.text':
        text = s
        break
if text and fnstart:
    tstart = text.VirtualAddress + base
    toff = text.PointerToRawData
    tsize = text.Misc_VirtualSize
    tb = data[toff:toff+tsize]
    print(f"\n=== direct callers of {hex(fnstart)} ===")
    cnt = 0
    for i in range(len(tb) - 5):
        if tb[i] == 0xE8:
            rel = struct.unpack('<i', tb[i+1:i+5])[0]
            va = tstart + i
            if va + 5 + rel == fnstart:
                print(f"  call at {hex(va)}")
                cnt += 1
                if cnt >= 20:
                    break
    print(f"  (total {cnt})")
