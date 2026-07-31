"""
Deep offset discovery for Ascension 3.3.5-class client.
Verify known 12340 community offsets and extract ClntObjMgr globals.
"""
from pathlib import Path
import struct
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

path = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = path.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def rva_off(rva):
    return pe.get_offset_from_rva(rva)

def va_off(va):
    return rva_off(va - base)

def disasm(va, n=24):
    off = va_off(va)
    chunk = data[off:off+64]
    lines = []
    for insn in md.disasm(chunk, va):
        lines.append(f"{hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if len(lines) >= n: break
    return lines, chunk[:16].hex()

# Community 3.3.5.12340 offsets (common set)
cand = {
    # Object manager
    "ClntObjMgrGetActivePlayer": 0x004D3790,
    "ClntObjMgrGetActivePlayerObj": 0x004D3910,  # alt names
    "ClntObjMgrObjectPtr": 0x004D4DB0,
    "ClntObjMgrEnumVisibleObjects": 0x004D4B30,
    "ClntObjMgrGetUnitFromName": 0x0060E000,  # guess skip
    # CTM / movement
    "CGPlayer_C__ClickToMove": 0x00727400,  # often around here
    "CGUnit_C__GetFacing": 0x007B9DE0,
    # World
    "CGWorldFrame_C__Intersect": 0x007A3B70,
    "GetCamera": 0x004F5960,
    # Lua
    "FrameScript_Execute": 0x00819210,
    "FrameScript_GetText": 0x00819D40,
    "FrameScript_RegisterFunction": 0x00817F90,
    "GetLuaState": 0x00817D90,
    # name
    "CGUnit_C__GetUnitName": 0x0067A7B0,
    "CGGameObject_C__GetName": 0x005F8A90,
}

print("=== Candidate validation ===")
results = {}
for name, va in cand.items():
    try:
        lines, hx = disasm(va, 8)
        first = lines[0] if lines else ""
        good = any(x in first for x in ["push ebp", "mov edi, edi", "sub esp", "mov eax", "push", "mov ecx"])
        # better: starts with 55 8B EC or 64 A1 or 8B 0D
        off = va_off(va)
        b = data[off:off+3]
        good2 = b[:2] == b'\x55\x8b' or b[:2] == b'\x64\xa1' or b[0] in (0x56, 0x53, 0x57, 0x51, 0xA1, 0x8B, 0x83, 0xE9)
        results[name] = {"va": hex(va), "bytes": hx, "good": good2, "disasm": lines[:6]}
        print(f"{'OK' if good2 else '??'} {name:40} {hex(va)} {hx}")
        for l in lines[:4]:
            print("   ", l)
    except Exception as e:
        print(f"FAIL {name}: {e}")
        results[name] = {"error": str(e)}

# At EnumVisibleObjects, extract global object manager pointer from code
print("\n=== Analyze EnumVisibleObjects @ 0x4D4B30 ===")
lines, _ = disasm(0x4D4B30, 40)
for l in lines:
    print(l)

print("\n=== Analyze ObjectPtr @ 0x4D4DB0 ===")
lines, _ = disasm(0x4D4DB0, 40)
for l in lines:
    print(l)

print("\n=== Analyze GetActivePlayer @ 0x4D3790 ===")
lines, _ = disasm(0x4D3790, 30)
for l in lines:
    print(l)

# Search for pattern: push ebp; mov ebp, esp; mov eax, [imm32] near "Object" related
# Find FrameScript by searching for known lua API register patterns
# Search "Script_" strings
import re
for s in [b"ScriptErrors", b"FrameScript", b"scriptErrors", b"RunScript", b"DEFAULT_CHAT_FRAME",
          b"IsLinuxClient", b"lua_", b"LUA_"]:
    positions = []
    start = 0
    while True:
        i = data.find(s, start)
        if i < 0: break
        positions.append(i)
        start = i+1
        if len(positions) > 5: break
    print(f"str {s}: {[hex(p) for p in positions[:5]]}")

# Write JSON results
import json
out = Path(r"C:\Ascension\Workspace\RaijinLab\runtime\offsets\discovery_raw.json")
# make serializable
ser = {}
for k,v in results.items():
    ser[k] = {kk:vv for kk,vv in v.items()}
out.write_text(json.dumps(ser, indent=2), encoding="utf-8")
print("wrote", out)
pe.close()
