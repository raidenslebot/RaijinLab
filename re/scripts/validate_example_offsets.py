"""
Validate Example Code offsets against Ascension.exe.
- Check PE image base, code at absolute addresses
- Signature-scan classic 3.3.5 patterns for OM functions
"""
import struct, hashlib
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
DUMP = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps\Ascension.exe")
path = EXE if EXE.exists() else DUMP
data = path.read_bytes()
pe = pefile.PE(data=data)
image_base = pe.OPTIONAL_HEADER.ImageBase
print(f"file={path.name} image_base={hex(image_base)} entry={hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint)}")

# Example offsets (absolute VAs assuming base 0x400000)
example = {
    "GET_PLAYER_GUID": 0x00468550,
    "GET_OBJECT_PTR": 0x00464870,
    "ENUM_VISIBLE_OBJECTS": 0x00468380,
    "GET_CAMERA": 0x004818F0,
    "MOVE_TO": 0x00611130,
    "GET_UNIT_TYPE": 0x00605570,
    "GET_UNIT_REACTION": 0x006061E0,
    "GET_GAMEOBJECT_MODEL_NAME": 0x005F8090,
}

def va_to_offset(va):
    rva = va - image_base
    return pe.get_offset_from_rva(rva)

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

print("\n=== Code at Example absolute VAs ===")
for name, va in example.items():
    try:
        off = va_to_offset(va)
        chunk = data[off:off+32]
        print(f"\n{name} VA={hex(va)} file_off={hex(off)} bytes={chunk[:16].hex()}")
        for insn in md.disasm(chunk, va):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            if insn.address > va + 20:
                break
        # Heuristic: legitimate code usually starts with push ebp / mov edi,edi / sub esp
        b0 = chunk[0]
        ok = b0 in (0x55, 0x53, 0x56, 0x57, 0x51, 0x52, 0x8B, 0x83, 0x81, 0xE9, 0xE8, 0x68, 0x6A, 0x33, 0x31, 0xA1, 0xB8, 0x64)
        print(f"  prologue_ok_heuristic={ok}")
    except Exception as e:
        print(f"{name}: FAIL {e}")

# Search for string xrefs useful for finding functions
print("\n=== Interesting strings in Ascension.exe ===")
import re
strings_of_interest = [
    b"EnumVisibleObjects",
    b"CGUnit",
    b"CGPlayer",
    b"CGGameObject",
    b"CGObject",
    b"s_currentWorldFrame",
    b"ClientConnection",
    b"FrameScript_Execute",
    b"FrameScript_GetText",
    b"lua_gettop",
    b"ClntObjMgr",
    b"ObjectManager",
    b"ClickToMove",
    b"CGWorldFrame::Intersect",
]
for s in strings_of_interest:
    idx = data.find(s)
    print(f"  {s.decode():30} -> {hex(idx) if idx>=0 else 'NOT FOUND'}")

# Classic 3.3.5 patterns (community)
# ClntObjMgrGetActivePlayer - often has distinctive code
# We'll dump .text size
for s in pe.sections:
    name = s.Name.decode(errors='replace').rstrip('\x00')
    print(f"section {name:8} va={hex(s.VirtualAddress)} vsize={hex(s.Misc_VirtualSize)} raw={hex(s.PointerToRawData)} rsize={hex(s.SizeOfRawData)}")

# Save first 16 bytes of each example function for pattern file
out = Path(r"C:\Ascension\Workspace\RaijinLab\re\example_offset_validation.txt")
lines = []
for name, va in example.items():
    try:
        off = va_to_offset(va)
        chunk = data[off:off+32]
        lines.append(f"{name}\t{hex(va)}\t{chunk.hex()}")
    except Exception as e:
        lines.append(f"{name}\t{hex(va)}\tERROR {e}")
out.write_text("\n".join(lines), encoding="utf-8")
print("wrote", out)

# Compare to common 3.3.5 retail offsets (12340)
retail = {
    "ClntObjMgrGetActivePlayer": 0x004D3790,  # varies
    "ClntObjMgrObjectPtr": 0x004D4DB0,
    "ClntObjMgrEnumVisibleObjects": 0x004D4B30,
}
print("\n=== Sample retail-ish addresses (may not match) ===")
for name, va in retail.items():
    try:
        off = va_to_offset(va)
        chunk = data[off:off+16]
        print(f"{name} {hex(va)} {chunk.hex()}")
    except Exception as e:
        print(name, e)

pe.close()
