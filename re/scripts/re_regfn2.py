"""Dump instructions around FrameScript_RegisterFunction call sites to learn
the exact registration pattern (handler/name pushed how?)."""
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

REGFN = 0x00817F90

def find_all_calls_to(regfn):
    calls = []
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
            if tgt == regfn:
                calls.append(va0 + idx)
            pos = idx + 1
    return calls

calls = find_all_calls_to(REGFN)
print(f"{len(calls)} call sites; showing 6")

for callva in calls[:6]:
    lo = max(0, va_to_off(callva) - 40)
    hi = va_to_off(callva) + 5
    print(f"\n--- call @ {hex(callva)} ---")
    for insn in md.disasm(data[lo:hi], off_to_va(lo)):
        mark = " <<<< CALL" if insn.address == callva else ""
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}{mark}")
