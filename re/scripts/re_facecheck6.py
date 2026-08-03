"""RE round 6: find the client's GetPlayerFacing Lua binding and trace the EXACT
facing field it reads, so the runtime reads the same field the client uses.

The live probe proved: runtime PlayerFacing() (player+0x7AC) == 0, while the
client's own Lua GetPlayerFacing() == 1.266 (real). So 0x7AC on our pointer is
NOT the field — either the pointer differs or the offset differs.
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


def read_cstr(va, maxlen=120):
    try:
        off = va_to_off(va)
    except Exception:
        return None
    end = data.find(b"\x00", off, off + maxlen)
    if end == -1:
        return None
    try:
        return data[off:end].decode("ascii", "replace")
    except Exception:
        return None


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


def xrefs_to(va):
    ab = (va & 0xFFFFFFFF).to_bytes(4, "little")
    refs = []
    i = 0
    while True:
        i = data.find(ab, i)
        if i == -1:
            break
        rva = pe.get_rva_from_offset(i)
        if TEXT_START <= rva < TEXT_END:
            refs.append(base + rva)
        i += 1
    return refs


print("=== 1. find 'GetPlayerFacing' string ===")
b = b"GetPlayerFacing"
i = 0
while True:
    i = data.find(b, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    print(f"  string at VA {base + rva:#x}")
    # find references to this string address (command table / registration)
    sva = base + rva
    refs = xrefs_to(sva)
    print(f"    refs: {[hex(r) for r in refs[:20]]}")
    i += 1

# 2. The Lua command table: GetPlayerFacing is a registered FrameScript command.
# The command handler resolves the player via GetActivePlayer (0x4D4DB0-ish) and
# calls CGUnit_C::GetFacing vtable. Let's find the command handler by looking for
# the classic pattern: call GetActivePlayer, test, then vtable call [eax+0x14C].
print()
print("=== 2. scan for the GetFacing vtable call pattern (call [reg+0x14C]) ===")
# pattern: 8B 0? + 8B 41 4C (mov eax,[ecx+0x14C]) or FF 51 4C (call [ecx+0x14C])
pat = bytes([0xFF, 0x51, 0x4C])   # call dword ptr [ecx+0x14C]
hits = []
i = 0
while True:
    i = data.find(pat, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    if TEXT_START <= rva < TEXT_END:
        hits.append(base + rva)
    i += 1
print("  call [ecx+0x14C] sites:", len(hits), [hex(h) for h in hits[:20]])
for h in hits[:6]:
    print(f"  --- {hex(h)} ---")
    dump(h - 40, 40, 48)
    print()

# 3. Also try FF 51 4C variants with other base regs (edx, eax)
print("=== 3. call [reg+0x14C] with other base registers ===")
for reg in [0x50, 0x52, 0x53, 0x56, 0x57]:  # eax, edx, ebx, esi, edi
    pat = bytes([0xFF, reg, 0x4C])
    hits = []
    i = 0
    while True:
        i = data.find(pat, i)
        if i == -1:
            break
        rva = pe.get_rva_from_offset(i)
        if TEXT_START <= rva < TEXT_END:
            hits.append(base + rva)
        i += 1
    print(f"  call [{chr(0x58+reg-0x50)}x+0x14C]: {len(hits)} {[hex(h) for h in hits[:12]]}")
