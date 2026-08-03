"""RE Spell_C_CastSpell real logic 0x80CCE0: find the busy/action-in-progress
check and the error-code returns (SPELL_FAILED_*). Also trace UnitCastingInfo
handler 0x00611DF0 internal and StartAttack handler 0x00523090."""
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

def dis_all(va, n=800, maxlen=5000):
    try:
        off = va_to_off(va)
    except Exception:
        return []
    chunk = data[off:off+maxlen]
    out = []
    for insn in md.disasm(chunk, va):
        out.append((insn.address, insn.mnemonic, insn.op_str))
        if len(out) >= n:
            break
    return out

print("=== Spell_C real logic 0x80CCE0: error-code pushes & interesting calls ===")
for a, m, o in dis_all(0x0080CCE0, 1200, 9000):
    # look for pushes of small immediates (error codes), calls, and ret
    if m == 'push' and o.startswith('0x'):
        try:
            v = int(o, 16)
            if 0 < v <= 300:
                print(f"  {hex(a)}: push {v}   <-- possible error/state code")
        except Exception:
            pass
    elif m == 'call':
        print(f"  {hex(a)}: call {o}")
    elif m == 'ret':
        pass
