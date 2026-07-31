"""Find lua_* helpers near FrameScript in Ascension.exe for bridge completeness."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

path = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = path.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def dis(va, n=15):
    rva = va - base
    off = pe.get_offset_from_rva(rva)
    chunk = data[off:off+48]
    out=[]
    for insn in md.disasm(chunk, va):
        out.append(f"{hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if len(out)>=n: break
    return out, chunk[:8].hex()

# FrameScript_RegisterFunction @ 0x817F90 - see what it calls
print("=== FrameScript_RegisterFunction ===")
for l in dis(0x817F90, 40)[0]:
    print(l)

# Search for string "IsLinuxClient" xrefs roughly - find who uses it
idx = data.find(b"IsLinuxClient")
print("\nIsLinuxClient string file offset", hex(idx))
# convert to VA
rva = pe.get_rva_from_offset(idx)
va = base + rva
print("VA", hex(va))

# Community lua offsets for 3.3.5 often in 0x0084xxxx
cands = {
    "lua_gettop": 0x0084DBD0,
    "lua_settop": 0x0084DBF0,
    "lua_tolstring": 0x0084E0E0,
    "lua_tonumber": 0x0084E030,
    "lua_pushnumber": 0x0084E2B0,
    "lua_pushstring": 0x0084E350,
    "lua_pushboolean": 0x0084E4D0,
    "lua_pushnil": 0x0084E2A0,
    "lua_type": 0x0084DC30,
}
print("\n=== lua candidate prologues ===")
for name, va in cands.items():
    try:
        lines, hx = dis(va, 4)
        print(f"{name} {hex(va)} {hx}")
        for l in lines: print(" ", l)
    except Exception as e:
        print(name, e)

# Better: search for distinctive lua_gettop pattern in many builds:
# 8B 4C 24 04 8B 41 08 2B 41 0C  # mov ecx,[esp+4]; mov eax,[ecx+8]; sub eax,[ecx+C]
pat = bytes.fromhex("8B4C24048B41082B410C")
start = 0
hits=[]
while True:
    i = data.find(pat, start)
    if i < 0: break
    # to VA
    try:
        rva = pe.get_rva_from_offset(i)
        hits.append(base+rva)
    except: pass
    start = i+1
print("\nlua_gettop-like pattern hits:", [hex(h) for h in hits[:20]], "count", len(hits))
