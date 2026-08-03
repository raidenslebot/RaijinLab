"""Find FrameScript_RegisterFunction callers -> (name, handler) for key APIs."""
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

def is_str(va):
    try:
        off = va_to_off(va)
    except Exception:
        return False
    chunk = data[off:off+100]
    n = 0
    for b in chunk:
        if b == 0:
            return n > 0
        if not (32 <= b < 127):
            return False
        n += 1
    return False

def read_str(va):
    off = va_to_off(va)
    end = data.find(b'\0', off)
    return data[off:end].decode('latin1')

REGFN = 0x00817F90

def find_all_calls_to(regfn):
    """Find all E8 calls to regfn across the executable."""
    calls = []
    # iterate all executable sections
    for sec in pe.sections:
        if not (sec.Characteristics & 0x20000000):  # CODE
            continue
        s_off = sec.PointerToRawData
        s_size = sec.SizeOfRawData
        chunk = data[s_off:s_off+s_size]
        va0 = base + sec.VirtualAddress
        pos = 0
        while True:
            idx = chunk.find(b'\xE8', pos)
            if idx < 0:
                break
            if idx + 5 > len(chunk):
                break
            rel = int.from_bytes(chunk[idx+1:idx+5], 'little', signed=True)
            tgt = va0 + idx + 5 + rel
            if tgt == regfn:
                calls.append(va0 + idx)
            pos = idx + 1
    return calls

calls = find_all_calls_to(REGFN)
print(f"FrameScript_RegisterFunction @ {hex(REGFN)} has {len(calls)} call sites")

want = set(["IsCurrentSpell", "IsUsableSpell", "IsSpellInRange", "StartAttack",
            "StopAttack", "UnitCastingInfo", "IsUnitCasting", "IsUnitChanneling",
            "SpellIsTargeting", "IsAutoRepeatSpellOn", "IsAttackAction",
            "AttackTarget", "GetCurrentSpellName", "CastSpell", "CastSpellByName",
            "UseAction", "IsActionInRange", "GetActionInfo", "TargetUnit",
            "ClearTarget", "TargetLastTarget", "InteractUnit", "GetSpellInfo",
            "GetSpellCooldown", "IsCurrentAction", "GetUnitName", "UnitGUID",
            "UnitExists", "UnitIsDeadOrGhost", "UnitCanAttack", "UnitAffectingCombat",
            "UnitHealth", "UnitPower", "GetUnitPower", "IsSpellKnown", "GetTime",
            "UnitPosition", "GetPlayerFacing", "IsInCombat", "UnitInCombat",
            "UnitIsUnit", "UnitIsPlayer", "UnitIsFriend", "UnitIsEnemy",
            "UnitReaction", "UnitOnTaxi", "UnitIsFeignDeath", "UnitIsGhost",
            "UnitIsDead", "GetPetActionInfo", "GetItemCooldown", "GetSpellCharges",
            "GetCurrentKeyBinding", "GetSpellTexture", "GetSpellName",
            "GetSpellBookItemInfo", "IsCurrentAction", "GetShapeshiftForm"])

results = {}
for callva in calls:
    # disassemble 32 bytes before the call to find pushes (name, handler)
    lo = max(0, va_to_off(callva) - 40)
    hi = va_to_off(callva) + 5
    pushed = []
    for insn in md.disasm(data[lo:hi], off_to_va(lo)):
        if insn.mnemonic == 'push':
            pushed.append(insn.op_str)
    # typical: push <handler>; push <name>; call REGFN ; add esp,8
    if len(pushed) >= 2:
        name_op = pushed[-2]
        handler_op = pushed[-1]
        if name_op.startswith('0x') and handler_op.startswith('0x'):
            name_va = int(name_op, 16)
            handler_va = int(handler_op, 16)
            if is_str(name_va):
                nm = read_str(name_va)
                results[nm] = handler_va

print(f"parsed {len(results)} registrations")
for nm in sorted(results):
    if nm in want:
        print(f"  {nm:<28} -> 0x{results[nm]:08X}")

# Also dump all registration names to a file for the full picture
with open(Path(__file__).parent / "handlers_dump.txt", "w") as f:
    for nm in sorted(results):
        f.write(f"{nm}\t0x{results[nm]:08X}\n")
print("full dump -> handlers_dump.txt")
