"""Find the start of the function containing 0x4D3A40 and all callers."""
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

# Walk back from 0x4D3A40 to find function prologue
print("=== walk back from 0x4D3A40 ===")
start = None
off = va_to_off(0x004D3A40)
# scan back up to 0x600 bytes for a prologue at an instruction boundary
for back in range(0x600, 0, -1):
    pos = off - back
    # look for push ebp (0x55) followed by mov ebp,esp (0x8B 0xEC)
    b = data[pos]
    if b == 0x55 and data[pos+1] == 0x8B and data[pos+2] == 0xEC:
        # verify this is a function boundary: previous bytes should be padding/ret/int3
        prev = data[pos-1] if pos > 0 else 0
        if prev in (0x90, 0xCC, 0xC3, 0x00, 0x55):
            start = pos
            print(f"  prologue candidate: push ebp @ {hex(off_to_va(pos))}")
            break
    # also push esi/push edi style thunks
    if b == 0x56 and data[pos+1] == 0x8B and data[pos+2] == 0xFF:
        prev = data[pos-1] if pos > 0 else 0
        if prev in (0x90, 0xCC, 0xC3, 0x00, 0x55):
            start = pos
            print(f"  thunk candidate: push esi; mov edi,edi @ {hex(off_to_va(pos))}")
            break

if start:
    func_va = off_to_va(start)
    dump(func_va, 80, 600, f"function start {hex(func_va)} (body)")
    # find callers
    print(f"\n=== callers of {hex(func_va)} ===")
    import struct
    count = 0
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
            if tgt == func_va:
                print(f"  E8 caller {hex(va0 + idx)}")
                count += 1
            pos = idx + 1
    print(f"  total direct E8 callers: {count}")
else:
    print("  no prologue found")
    dump(0x004D3700, 60, 500, "0x4D3700 window")
