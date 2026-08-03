"""RE round 7: find the GetPlayerFacing command HANDLER by looking at the command
table entry at 0xAD26F0 (which references the string) and the handler it points to.
"""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CsError

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

TEXT_START, TEXT_END = 0x401000, 0x9DE3B2


def va_to_off(va):
    return pe.get_offset_from_rva(va - base)


def dump(va, before=16, after=200, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    for ins in md.disasm(code, va - before):
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")


print("=== command table entry at 0xAD26F0 ===")
off = pe.get_offset_from_rva(0xAD26F0 - base)
# The command table entries are usually: { name_ptr, handler, min_args, ... }
for i in range(0, 64, 4):
    val = int.from_bytes(data[off + i:off + i + 4], "little")
    if val:
        print(f"  +0x{i:02x}: {val:#x}")
print()

# The entry referencing the name string: name ptr, then handler ptr.
# Read 16 bytes before and after 0xAD26F0.
print("=== raw around 0xAD26F0 ===")
for rva in range(0xAD26D0, 0xAD2740, 0x10):
    off2 = pe.get_offset_from_rva(rva - base)
    words = [int.from_bytes(data[off2 + j:off2 + j + 4], "little") for j in range(0, 16, 4)]
    print(f"  {rva-base+base:#x}: {[f'{w:#x}' for w in words]}")

# Look for the FrameScript command handler table — find "GetPlayerFacing" then
# the NEXT dword is usually the handler function pointer.
print()
print("=== find handler by scanning for the name ref followed by .text ptr ===")
off_name = pe.get_offset_from_rva(0xA1EB04 - base)
name_va = 0xA1EB04
ab = (name_va).to_bytes(4, "little")
i = 0
while True:
    i = data.find(ab, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    print(f"  ref at VA {base + rva:#x} (rva {rva:#x})")
    # read the next 4 dwords after this ref
    for k in range(4, 32, 4):
        val = int.from_bytes(data[i + k:i + k + 4], "little")
        print(f"    +{k}: {val:#x}")
    i += 1
