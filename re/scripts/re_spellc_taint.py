"""Check whether Spell_C (0x80CCE0) or the movement natives reference the
taint/hardware-event flag or are protected (secure-action gated)."""
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

def scan_refs(va, end, taints):
    """Scan .text region for direct references to taint globals."""
    off = va_to_off(va)
    endoff = va_to_off(end)
    region = data[off:endoff]
    for t in taints:
        tb = t.to_bytes(4, "little")
        cnt = region.count(tb)
        if cnt:
            print(f"  refs to {hex(t)} ({cnt}) found in {hex(va)}-{hex(end)}")

# relevant addresses
SPELL_C = 0x80CCE0
SPELL_C_WRAP = 0x80DA40
TAINT_GLOBALS = [0x00C21000, 0x00D4139C, 0x00D397D0]
HW = 0x00C21000

for name, va, end in [("Spell_C real 0x80CCE0", SPELL_C, 0x80DA40),
                      ("Spell_C wrapper 0x80DA40", SPELL_C_WRAP, 0x80E000)]:
    print(f"=== {name} ===")
    scan_refs(va, end, TAINT_GLOBALS)

# movement natives: are they protected? look for HW flag refs near them
MOVES = [0x005FC250, 0x005FC360, 0x005FC890]  # MoveForwardStop, TurnLeftStop, MouselookStop
for m in MOVES:
    try:
        off = va_to_off(m)
    except Exception:
        print(f"{hex(m)}: no mapping"); continue
    # check a small window for HW/taint refs
    region = data[off:off+0x60]
    for t in TAINT_GLOBALS:
        if region.count(t.to_bytes(4,"little")):
            print(f"{hex(m)}: refs {hex(t)}")
print("done")
