"""Map the client's cooldown + aura storage so we can zero the GCD and freeze
buffs CLIENT-SIDE via pure memory writes (zero packets).

This mirrors what the runtime already does at inject:
  * LiveScan.cpp scans GetSpellCooldown handler (0x00540E80) for its internal
    call targets and takes the LAST valid non-Lua target as InternalGetCooldown.
  * The aura layout is already live-verified (ObjectManager.cpp AuraWalk):
    unit+0xDD0 count (or +0xC54/+0xC58 dyn), entry 0x18 bytes, expiry +0x14.

We disassemble BOTH statically here to get the GCD storage slot + the spell-CD
table layout (TableDynIndex / TableStatic inline) with a human-readable trace.

IMPORTANT (wire-fidelity): zeroing the GCD is a CLIENT-MEMORY only change.
It does NOT emit a single packet — the client's own cast path sends the SAME
CMSG_CAST_SPELL it always sends, just without the local GCD gate. TrinityCore
enforces GCD server-side too, so this is a local-perception experiment first
and a pacing experiment second — it never mangles a packet.

Writes: tools/_disasm_gcd_aura.txt
"""
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000

HANDLER_GET_SPELL_COOLDOWN = 0x00540E80
HANDLER_GET_TIME = 0x006081F0

# Known globals that cooldown code might touch (annotate when seen).
WATCH = {
    0x00D397CC: 'kCurrentSpellUsed',
    0x00D397D0: 'kAutoRepeatSpell',
    0x00D3F4E4: 'kTargetingGlob',
}


def va_to_fo(va):
    return va - IMAGE_BASE - 0x1000 + TEXT_OFF


def collect_internal_calls(data, start_va, size=0x600):
    """Return sorted unique call targets (E8 rel32) inside the function window,
    matching the runtime's LiveScan::ScanHandlerInternalCalls heuristic."""
    import struct as _s
    fo = va_to_fo(start_va)
    buf = data[fo:fo + size]
    calls = []
    for pos in range(0, len(buf) - 5):
        if buf[pos] == 0xE8:
            rel = _s.unpack_from('<i', buf, pos + 1)[0]
            tgt = start_va + pos + 5 + rel
            calls.append(tgt)
    # dedup preserving order-ish (use set per pass)
    seen = set()
    uniq = []
    for t in calls:
        if t not in seen:
            seen.add(t)
            uniq.append(t)
    return uniq


def disasm_range(data, start_va, length, label, watch=None):
    out = ['=' * 78, '%s  start=0x%08X len=0x%X' % (label, start_va, length),
           '=' * 78]
    fo = va_to_fo(start_va)
    chunk = data[fo:fo + length]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    watch = watch or {}
    for ins in md.disasm(chunk, start_va):
        op = ins.op_str.lower()
        ann = ''
        for addr, name in watch.items():
            if ('0x%x' % addr) in op or ('0x%08x' % addr) in op:
                ann += '   <=== %s' % name
        out.append('0x%08X  %-8s %-34s ; %s%s'
                   % (ins.address, ins.mnemonic, ins.op_str,
                      ' '.join('%02X' % b for b in ins.bytes), ann))
    return out


def main():
    data = open(EXE, 'rb').read()
    out = []

    # STEP 1: internal call targets from the GetSpellCooldown handler.
    out.append('#' * 78)
    out.append('# STEP 1: GetSpellCooldown handler internal call targets (0x00540E80)')
    out.append('#' * 78)
    out += disasm_range(data, HANDLER_GET_SPELL_COOLDOWN, 0x500,
                        'GetSpellCooldown handler', WATCH)
    cds = collect_internal_calls(data, HANDLER_GET_SPELL_COOLDOWN)
    out.append('')
    out.append('InternalGetCooldown candidates (in order seen):')
    for i, t in enumerate(cds):
        out.append('  [%d] 0x%08X' % (i, t))
    # The runtime takes the LAST valid non-Lua target.
    out.append('')
    out.append('>>> Runtime pick = LAST candidate above (matches LiveScan).')

    # STEP 2: disassemble 0x809000 — the REAL cooldown reader (called directly
    # at 0x540F98 inside the handler). The runtime's LiveScan 'last candidate'
    # heuristic picked 0x5EEB70, which is a copy/container function — WRONG.
    # 0x809000 takes (spellIndex, spellId?, &dur, &start, &unk) and computes
    # remaining from the category table at 0xBE7D98 — where the GCD lives.
    out.append('')
    out.append('#' * 78)
    out.append('# STEP 2: InternalGetCooldown 0x00809000 (REAL, from handler call at 0x540F98)')
    out.append('#   category table 0x00BE7D98 (cap 0x400, count [0x00BE8DA4])')
    out.append('#   spell table     0x00BE6D88 (count [0x00BE8D98])')
    out.append('#   cooldown record start/duration/remaining computed here')
    out.append('#' * 78)
    COOLDOWN_WATCH = dict(WATCH)
    COOLDOWN_WATCH[0x00BE7D98] = 'CATEGORY table (GCD here)'
    COOLDOWN_WATCH[0x00BE6D88] = 'SPELL table'
    COOLDOWN_WATCH[0x00BE8DA4] = 'category count'
    COOLDOWN_WATCH[0x00BE8D98] = 'spell count'
    out += disasm_range(data, 0x00809000, 0x300, 'InternalGetCooldown(0x809000)', COOLDOWN_WATCH)

    # STEP 2b: also 0x540670 (GetCooldownIndex helper that fills the index).
    out.append('')
    out.append('#' * 78)
    out.append('# STEP 2b: GetCooldownIndex helper 0x00540670')
    out.append('#' * 78)
    out += disasm_range(data, 0x00540670, 0x120, 'GetCooldownIndex(0x540670)', COOLDOWN_WATCH)

    # STEP 3: GetTime internal (for the ms clock the expiry is compared against).
    times = collect_internal_calls(data, HANDLER_GET_TIME)
    out.append('')
    out.append('#' * 78)
    out.append('# STEP 3: GetTime handler (0x006081F0) internal candidates')
    out.append('#' * 78)
    for i, t in enumerate(times):
        out.append('  [%d] 0x%08X' % (i, t))
    if times:
        out += disasm_range(data, times[-1], 0x200, 'InternalGetTime', WATCH)

    txt = '\n'.join(out)
    path = r'C:\Ascension\Workspace\RaijinLab\tools\_disasm_gcd_aura.txt'
    with open(path, 'w') as f:
        f.write(txt)
    print(txt)


if __name__ == '__main__':
    main()
