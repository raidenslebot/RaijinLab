"""RE round 9: find what the client's GetPlayerFacing ACTUALLY reads.

Handler 0x60A490: GetCamera()->[cam+0x88/0x8c]->ClntObjMgrObjectPtr(0x4D4DB0)
-> player obj -> call vtable[0x34](). The runtime instead reads player+0x7AC
directly and gets 0 while the client gets a real value.

Find the CGUnit_C vtable that contains 0x6E6FC0 (GetFacing) at slot 0x34,
then confirm the exact field offset that GetFacing/other vtbl slot reads.
Also check what vtable[0x14C] is (runtime's current assumption).
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


def dump(va, before=8, after=120, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    for ins in md.disasm(code, va - before):
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")


# 1. Find the GetFacing thunk 0x6E6FC0 and the simple getter functions around it.
print("=== GetFacing 0x6E6FC0 and neighbors ===")
dump(0x6E6F60, 0, 160)
print()

# 2. Find all references to 0x6E6FC0 (vtable entries are data refs in .rdata)
print("=== refs to 0x6E6FC0 ===")
ab = (0x6E6FC0).to_bytes(4, "little")
i = 0
refs = []
while True:
    i = data.find(ab, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    refs.append(base + rva)
    i += 1
print("  all refs:", [hex(r) for r in refs[:30]])

# 3. For each .rdata ref, dump the surrounding vtable region and identify the
#    slot index (offset from the vtable start). A vtable entry is 4 bytes; slot
#    index = byte_offset/4. Look for slot 0x34 = byte 0xD0.
print()
print("=== find vtable containing 0x6E6FC0 at slot 0x34 (byte +0xD0) ===")
for r in refs:
    off = va_to_off(r)
    # check if r - 0xD0 is a plausible vtable start (i.e., points into .rdata)
    if r - 0xD0 >= base + 0x400000:
        offs = va_to_off(r - 0xD0)
        if offs >= 0:
            # look for recognizable vtable: many entries in .rdata
            print(f"  candidate vtable start {r-0xD0:#x} (entry {r:#x} = slot 0x34)")
            for k in range(0, 0x40, 4):
                v = int.from_bytes(data[offs + k:offs + k + 4], "little")
                print(f"    v+{k:02x} (slot {k//4:02x}): {v:#x}")
            break
