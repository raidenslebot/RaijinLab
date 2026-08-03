"""RE: authoritative auto-attack / busy / casting state for RaijinLab.

Find the Lua handler addresses for:
  - IsCurrentSpell           (detect if player's current spell == 6603 auto-attack)
  - IsAutoRepeatSpellOn      (wand / ranged auto-repeat)
  - IsAttackAction / IsAttackAction? (action bar attack state)
  - UnitCastingInfo          (player casting state for busy)
  - IsUnitCastingOrChanneling (player busy check)
  - IsUsableSpell            (HW-gated; we need its REAL internal logic)
  - IsSpellInRange           (HW-gated; REAL internal logic)
  - StartAttack              (real auto-attack engage function)
  - StopAttack / StopAutoRepeatSpell
Then disassemble the REAL internal logic of Spell_C_CastSpell (0x80CCE0).

Approach: locate the string in .rdata, find xrefs (lea/mov of the string ptr
followed by a call to FrameScript_RegisterFunction @ 0x817F90), read the
handler address pushed on the stack just before the call.
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

def dis(va, n=30, maxlen=120):
    try:
        off = va_to_off(va)
    except Exception:
        return [f"<no mapping for {hex(va)}>"]
    chunk = data[off:off+maxlen]
    out = []
    for insn in md.disasm(chunk, va):
        out.append(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if len(out) >= n:
            break
    return out

def find_string(s):
    idx = data.find(s.encode())
    if idx < 0:
        return None
    return off_to_va(idx)

def find_xrefs(va, radius=0x1000):
    """Find code that references va (absolute push/lea/mov). Crude: scan all
    executable sections for the 4-byte little-endian address, then report the
    instruction that uses it."""
    hits = []
    pat = int(va).to_bytes(4, 'little')
    start = 0
    while True:
        idx = data.find(pat, start)
        if idx < 0:
            break
        # Only consider hits in executable section
        try:
            sec_va = off_to_va(idx)
        except Exception:
            start = idx + 1
            continue
        # back up a bit to capture the instruction that embeds this imm
        lo = max(0, idx - 16)
        hi = min(len(data), idx + 16)
        for pos in range(lo, hi):
            try:
                for insn in md.disasm(data[pos:pos+20], off_to_va(pos)):
                    if insn.address + insn.size <= off_to_va(idx) + 4 and \
                       insn.address + insn.size > off_to_va(idx):
                        hits.append((insn.address, insn.mnemonic, insn.op_str))
                    if insn.address > off_to_va(idx) + 4:
                        break
            except Exception:
                pass
        start = idx + 1
    return hits

def find_register_call_for_string(s, regfn=0x00817F90):
    """Find 'push <handler>; push <str>; call FrameScript_RegisterFunction'
    pattern near the string xrefs. Returns (handler_va, call_site) or None."""
    sva = find_string(s)
    if sva is None:
        print(f"  [string '{s}' NOT FOUND]")
        return None
    print(f"  string '{s}' @ {hex(sva)}")
    # search for the string address being pushed / moved near a call to regfn
    pat = int(sva).to_bytes(4, 'little')
    start = 0
    found = []
    while True:
        idx = data.find(pat, start)
        if idx < 0:
            break
        start = idx + 1
        # window: the push of this string +- 32 bytes should contain a call to regfn
        lo = max(0, idx - 64)
        hi = min(len(data), idx + 64)
        win = data[lo:hi]
        regpat = int(regfn).to_bytes(4, 'little')
        if regpat in win:
            # find the call site and the handler push before it
            try:
                for pos in range(lo, hi):
                    for insn in md.disasm(data[pos:pos+24], off_to_va(pos)):
                        if insn.mnemonic == 'call' and insn.op_str.startswith('0x'):
                            tgt = int(insn.op_str, 16)
                            if tgt == regfn:
                                found.append((off_to_va(pos), insn.address))
                        if insn.mnemonic == 'push' and insn.op_str.startswith('0x'):
                            pass
                        if insn.address > off_to_va(hi):
                            break
            except Exception:
                pass
    if not found:
        return None
    # Now scan backward from each call site for the last push before it
    results = []
    for (pos, callva) in found:
        # disassemble 40 bytes before call
        lo = max(0, va_to_off(callva) - 40)
        pushed = []
        for insn in md.disasm(data[lo:va_to_off(callva)+5], off_to_va(lo)):
            if insn.mnemonic == 'push':
                pushed.append(insn.op_str)
        results.append((callva, pushed))
    return results

if __name__ == "__main__":
    print("=" * 70)
    print("STEP 1: find Lua handler addresses via FrameScript registration")
    print("=" * 70)
    for name in ["IsCurrentSpell", "IsAutoRepeatSpellOn", "IsAttackAction",
                 "UnitCastingInfo", "IsUnitCastingOrChanneling", "IsUsableSpell",
                 "IsSpellInRange", "StartAttack", "StopAttack",
                 "StopAutoRepeatSpell", "AttackTarget", "GetCurrentSpellName",
                 "IsUnitChanneling", "IsUnitCasting", "SpellIsTargeting"]:
        res = find_register_call_for_string(name)
        if res:
            for (callva, pushed) in res:
                print(f"  -> register call @ {hex(callva)}  pushes: {pushed}")
        else:
            print(f"  -> no direct register call found (may be table-based)")

    print()
    print("=" * 70)
    print("STEP 2: Spell_C_CastSpell wrapper 0x80DA40 -> real logic")
    print("=" * 70)
    for l in dis(0x0080DA40, 40, 140):
        print(l)

    print()
    print("=" * 70)
    print("STEP 3: Spell_C real logic 0x80CCE0 (first 80 insns)")
    print("=" * 70)
    for l in dis(0x0080CCE0, 80, 300):
        print(l)
