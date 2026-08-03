"""Disassemble the key Lua handlers and trace their internal (post-flag-check)
logic so the runtime can call the REAL functions directly (bypassing the
HardwareEventFlag gate that crashes when written).

Handlers (from re_table_dump.py):
  IsCurrentSpell   0x00541500
  IsAutoRepeatSpell 0x005415D0
  IsUsableSpell    0x00541680
  IsSpellInRange   0x00541C60
  SpellIsTargeting 0x007FDCD0
  CastSpell        0x00541250
  GetSpellInfo     0x00540A30
  GetTime          0x006081F0
"""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def off_to_va(off):
    return base + pe.get_rva_from_offset(off)

def dis(va, n=60, maxlen=400):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  <no mapping {hex(va)}>")
        return []
    chunk = data[off:off+maxlen]
    out = []
    for insn in md.disasm(chunk, va):
        out.append((insn.address, insn.mnemonic, insn.op_str))
        if len(out) >= n:
            break
    return out

def dump(va, n=60, maxlen=400):
    print(f"\n=== {hex(va)} ===")
    for a, m, o in dis(va, n, maxlen):
        print(f"  {hex(a)}: {m} {o}")

def find_calls(va, n=80, maxlen=500):
    """List all call targets within the first n instructions at va."""
    out = []
    for a, m, o in dis(va, n, maxlen):
        if m == 'call':
            out.append((a, o))
    return out

def find_hw_flag_check(va, n=80, maxlen=500):
    """Look for reads of the HardwareEventFlag global (0x00C21000) and the
    branch that follows it."""
    out = []
    for a, m, o in dis(va, n, maxlen):
        if '0xc21000' in o.lower() or '0x00c21000' in o.lower():
            out.append((a, m, o))
    return out

handlers = {
    "IsCurrentSpell": 0x00541500,
    "IsAutoRepeatSpell": 0x005415D0,
    "IsUsableSpell": 0x00541680,
    "IsSpellInRange": 0x00541C60,
    "SpellIsTargeting": 0x007FDCD0,
    "CastSpell": 0x00541250,
    "GetSpellInfo": 0x00540A30,
}

for name, va in handlers.items():
    dump(va, 50, 320)
    print(f"  -- HW-flag refs in {name}:")
    for r in find_hw_flag_check(va):
        print(f"     {hex(r[0])}: {r[1]} {r[2]}")
    print(f"  -- calls in {name}:")
    for (a, o) in find_calls(va):
        print(f"     {hex(a)}: call {o}")
