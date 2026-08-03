"""Final RE: (1) who WRITES the current-spells list head 0xaf5254 (confirm
population & node layout), (2) GetSpellCooldown handler 0x00540E80 for HW gate,
(3) 0x86ae20 GetTime, (4) current spell setters around 0xd397cc."""
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

def dump(va, n=50, maxlen=400):
    print(f"\n=== {hex(va)} ===")
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

# 1. Writers of 0xaf5254: scan for "mov [0xaf5254], reg" or "mov dword ptr [0xaf5254], imm"
print("=== writers of current-spells list head 0xaf5254 ===")
pat = int(0xaf5254).to_bytes(4, 'little')
start = 0
count = 0
while count < 12:
    idx = data.find(pat, start)
    if idx < 0:
        break
    start = idx + 1
    lo = max(0, idx - 24)
    hi = min(len(data), idx + 12)
    for insn in md.disasm(data[lo:hi], off_to_va(lo)):
        if '0xaf5254' in insn.op_str and insn.mnemonic == 'mov' and insn.address + insn.size > off_to_va(idx):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            count += 1
            break

# 2. GetSpellCooldown handler — HW gate?
print("\n=== GetSpellCooldown 0x00540E80 (first 40) ===")
dump(0x00540E80, 40, 300)

# 3. GetTime function
print("\n=== 0x86ae20 (GetTime) ===")
dump(0x0086ae20, 12, 60)

# 4. writers of 0xd397cc / 0xd397d0
for g in [0xd397cc, 0xd397d0]:
    print(f"\n=== writers of {hex(g)} ===")
    pat = int(g).to_bytes(4, 'little')
    s2 = 0
    c2 = 0
    while c2 < 6:
        idx = data.find(pat, s2)
        if idx < 0:
            break
        s2 = idx + 1
        lo = max(0, idx - 24)
        hi = min(len(data), idx + 12)
        for insn in md.disasm(data[lo:hi], off_to_va(lo)):
            if ('0x%x' % g) in insn.op_str.lower() and insn.mnemonic == 'mov' and insn.address + insn.size > off_to_va(idx):
                print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
                c2 += 1
                break
